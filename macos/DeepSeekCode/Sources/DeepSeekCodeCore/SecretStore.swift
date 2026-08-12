import Foundation

public protocol SecretStore: Sendable {
    func save(reference: String, value: String) throws
    func load(reference: String) throws -> String?
    func remove(reference: String) throws
}

public final class InMemorySecretStore: SecretStore, @unchecked Sendable {
    private var values: [String: String] = [:]
    private let lock = NSLock()

    public init() {}

    public func save(reference: String, value: String) throws {
        lock.lock()
        values[reference] = value
        lock.unlock()
    }

    public func load(reference: String) throws -> String? {
        lock.lock()
        defer { lock.unlock() }
        return values[reference]
    }

    public func remove(reference: String) throws {
        lock.lock()
        values.removeValue(forKey: reference)
        lock.unlock()
    }
}

public final class LocalFileSecretStore: SecretStore, @unchecked Sendable {
    private struct Envelope: Codable {
        var values: [String: String]
    }

    private let fileURL: URL
    private let lock = NSLock()

    public init(directory: URL, filename: String = "local-secrets.json") throws {
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: directory.path
        )
        fileURL = directory.appendingPathComponent(filename, isDirectory: false)
    }

    public func save(reference: String, value: String) throws {
        lock.lock()
        defer { lock.unlock() }
        var values = try readUnlocked()
        values[reference] = value
        try writeUnlocked(values)
    }

    public func load(reference: String) throws -> String? {
        lock.lock()
        defer { lock.unlock() }
        return try readUnlocked()[reference]
    }

    public func remove(reference: String) throws {
        lock.lock()
        defer { lock.unlock() }
        var values = try readUnlocked()
        values.removeValue(forKey: reference)
        try writeUnlocked(values)
    }

    private func readUnlocked() throws -> [String: String] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [:] }
        let data = try Data(contentsOf: fileURL)
        return try JSONDecoder().decode(Envelope.self, from: data).values
    }

    private func writeUnlocked(_ values: [String: String]) throws {
        let data = try JSONEncoder().encode(Envelope(values: values))
        try data.write(to: fileURL, options: [.atomic])
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: fileURL.path
        )
    }
}

/// Secret store used only by the standalone Terminal Helper. A launchd/SSH
/// helper is deliberately headless: synchronously consulting the login
/// Keychain can block Security.framework while the user session is locked,
/// which would stall PTY output ingestion and make reconnects time out. The
/// helper therefore keeps only its transcript-encryption key in a 0700/0600
/// local store. Provider credentials and other app secrets never use this
/// store and remain Keychain-backed in the main App.
public final class TerminalHelperSecretStore: SecretStore, @unchecked Sendable {
    private let local: LocalFileSecretStore

    public init(root: URL) throws {
        local = try LocalFileSecretStore(directory: root.appendingPathComponent("Secrets", isDirectory: true))
    }

    public func save(reference: String, value: String) throws {
        try local.save(reference: reference, value: value)
    }

    public func load(reference: String) throws -> String? {
        try local.load(reference: reference)
    }

    public func remove(reference: String) throws {
        try local.remove(reference: reference)
    }
}

public final class ResilientSecretStore: SecretStore, @unchecked Sendable {
    private let primary: any SecretStore
    private let fallback: any SecretStore

    public init(primary: any SecretStore, fallback: any SecretStore) {
        self.primary = primary
        self.fallback = fallback
    }

    public func save(reference: String, value: String) throws {
        var primaryError: Error?
        do {
            try primary.save(reference: reference, value: value)
        } catch {
            primaryError = error
        }

        do {
            try fallback.save(reference: reference, value: value)
            return
        } catch {
            if primaryError == nil { throw error }
        }

        if let primaryError { throw primaryError }
    }

    public func load(reference: String) throws -> String? {
        if let value = try? primary.load(reference: reference), !value.isEmpty {
            return value
        }
        return try fallback.load(reference: reference)
    }

    public func remove(reference: String) throws {
        var primaryError: Error?
        do {
            try primary.remove(reference: reference)
        } catch {
            primaryError = error
        }
        do {
            try fallback.remove(reference: reference)
        } catch {
            if primaryError == nil { throw error }
        }
        if let primaryError { throw primaryError }
    }
}

#if os(macOS)
import LocalAuthentication
import Security

public final class KeychainSecretStore: SecretStore, @unchecked Sendable {
    private let service: String
    private let allowsAuthenticationUI: Bool
    private let cacheLock = NSLock()
    private var cache: [String: String] = [:]

    public init(service: String = "com.deepseekcode.desktop", allowsAuthenticationUI: Bool = false) {
        self.service = service
        self.allowsAuthenticationUI = allowsAuthenticationUI
    }

    public func save(reference: String, value: String) throws {
        let data = Data(value.utf8)
        // Use the user's login Keychain as the portable macOS default. The
        // Data Protection Keychain requires an application entitlement that
        // an unsigned/local development build does not have; attempting to
        // write there produces errSecMissingEntitlement (-34018).
        let query: [String: Any] = keychainOperationQuery(loginKeychainQuery(reference: reference))
        let updateStatus = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if updateStatus == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            let status = SecItemAdd(item as CFDictionary, nil)
            guard status == errSecSuccess else { throw KeychainError(status: status) }
        } else if updateStatus != errSecSuccess {
            throw KeychainError(status: updateStatus)
        }
        cacheLock.lock()
        cache[reference] = value
        cacheLock.unlock()
    }

    public func load(reference: String) throws -> String? {
        cacheLock.lock()
        if let value = cache[reference] {
            cacheLock.unlock()
            return value
        }
        cacheLock.unlock()

        let query: [String: Any] = loginKeychainQuery(reference: reference).merging([
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]) { _, new in new }
        if let value = try read(query: query) {
            cacheLock.lock()
            cache[reference] = value
            cacheLock.unlock()
            return value
        }

        // Older development builds briefly attempted to use the Data
        // Protection Keychain. Treat that item as an optional migration
        // source. On an unsigned build this query can return -34018; it must
        // not prevent the normal login-Keychain path from working.
        do {
            let protectedQuery: [String: Any] = dataProtectionQuery(reference: reference).merging([
                kSecReturnData as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne
            ]) { _, new in new }
            if let value = try read(query: protectedQuery) {
                try? save(reference: reference, value: value)
                cacheLock.lock()
                cache[reference] = value
                cacheLock.unlock()
                return value
            }
        } catch let error as KeychainError where error.status == errSecMissingEntitlement {
            // Expected for local/unsigned macOS builds.
        }
        return nil
    }

    public func remove(reference: String) throws {
        let query = keychainOperationQuery(loginKeychainQuery(reference: reference))
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
        // Best-effort cleanup for items written by the older implementation.
        _ = SecItemDelete(keychainOperationQuery(dataProtectionQuery(reference: reference)) as CFDictionary)
        cacheLock.lock()
        cache.removeValue(forKey: reference)
        cacheLock.unlock()
    }

    private func loginKeychainQuery(reference: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: reference
        ]
    }

    private func dataProtectionQuery(reference: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: reference,
            kSecUseDataProtectionKeychain as String: true
        ]
    }

    private func keychainOperationQuery(_ query: [String: Any]) -> [String: Any] {
        guard !allowsAuthenticationUI else { return query }
        var query = query
        let context = LAContext()
        context.interactionNotAllowed = true
        query[kSecUseAuthenticationContext as String] = context
        return query
    }

    private func read(query: [String: Any]) throws -> String? {
        var result: CFTypeRef?
        let status = SecItemCopyMatching(keychainOperationQuery(query) as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw KeychainError(status: status) }
        return String(data: data, encoding: .utf8)
    }
}

public struct KeychainError: LocalizedError, Sendable {
    public let status: OSStatus
    public var errorDescription: String? {
        #if os(macOS)
        if status == errSecMissingEntitlement {
            return "当前应用没有可用的 Keychain entitlement，请更新到最新版后重试"
        }
        #endif
        return "Keychain error \(status)"
    }
}
#endif
