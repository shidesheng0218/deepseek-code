import Foundation

public struct CapabilityID: RawRepresentable, Codable, Hashable, Comparable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(_ rawValue: String) {
        self.init(rawValue: rawValue)
    }

    public static func < (lhs: CapabilityID, rhs: CapabilityID) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

public struct CapabilityDefinition: Codable, Equatable, Sendable {
    public let id: CapabilityID
    public let version: String
    public let dependencies: [CapabilityID]
    public let allowedEffects: Set<ToolEffect>

    public init(id: CapabilityID, version: String, dependencies: [CapabilityID], allowedEffects: Set<ToolEffect>) {
        self.id = id
        self.version = version
        self.dependencies = dependencies
        self.allowedEffects = allowedEffects
    }
}

public final class CapabilityRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var definitions: [CapabilityID: CapabilityDefinition] = [:]

    public init() {}

    public func register(_ definition: CapabilityDefinition) {
        lock.lock()
        definitions[definition.id] = definition
        lock.unlock()
    }

    public func definition(for id: CapabilityID) -> CapabilityDefinition? {
        lock.lock()
        defer { lock.unlock() }
        return definitions[id]
    }

    public func all() -> [CapabilityDefinition] {
        lock.lock()
        defer { lock.unlock() }
        return definitions.values.sorted { $0.id < $1.id }
    }
}

public enum PermissionMode: String, Codable, CaseIterable, Sendable {
    case trustedWorkspace = "trusted_workspace"
    case reviewWrites = "review_writes"
    case planOnly = "plan_only"
}

public struct WorkerPolicy: Codable, Equatable, Sendable {
    public let maxConcurrent: Int
    public let allowNestedWorkers: Bool

    public init(maxConcurrent: Int = 3, allowNestedWorkers: Bool = false) {
        self.maxConcurrent = max(1, maxConcurrent)
        self.allowNestedWorkers = allowNestedWorkers
    }
}

public struct RuntimeProfile: Codable, Equatable, Sendable {
    public let capabilities: [CapabilityID]
    public let providerRoutes: [ProviderRoute]
    public let permissionMode: PermissionMode
    public let workerPolicy: WorkerPolicy

    public init(
        capabilities: [CapabilityID],
        providerRoutes: [ProviderRoute] = [],
        permissionMode: PermissionMode = .trustedWorkspace,
        workerPolicy: WorkerPolicy = WorkerPolicy()
    ) {
        self.capabilities = capabilities
        self.providerRoutes = providerRoutes
        self.permissionMode = permissionMode
        self.workerPolicy = workerPolicy
    }
}

public enum RuntimeAssemblerError: LocalizedError, Sendable {
    case missingCapability(CapabilityID)
    case dependencyCycle(CapabilityID)

    public var errorDescription: String? {
        switch self {
        case let .missingCapability(id): "缺少能力依赖：\(id.rawValue)"
        case let .dependencyCycle(id): "能力依赖存在循环：\(id.rawValue)"
        }
    }
}

public final class RuntimeAssembler: @unchecked Sendable {
    private let registry: CapabilityRegistry

    public init(registry: CapabilityRegistry) {
        self.registry = registry
    }

    public func assemble(_ profile: RuntimeProfile) throws -> RuntimeProfile {
        var ordered: [CapabilityID] = []
        var visiting: Set<CapabilityID> = []
        var visited: Set<CapabilityID> = []

        func visit(_ id: CapabilityID) throws {
            if visited.contains(id) { return }
            guard let definition = registry.definition(for: id) else {
                throw RuntimeAssemblerError.missingCapability(id)
            }
            guard !visiting.contains(id) else {
                throw RuntimeAssemblerError.dependencyCycle(id)
            }
            visiting.insert(id)
            for dependency in definition.dependencies.sorted() {
                try visit(dependency)
            }
            visiting.remove(id)
            visited.insert(id)
            ordered.append(id)
        }

        for id in profile.capabilities.sorted() {
            try visit(id)
        }
        return RuntimeProfile(
            capabilities: ordered,
            providerRoutes: profile.providerRoutes,
            permissionMode: profile.permissionMode,
            workerPolicy: profile.workerPolicy
        )
    }
}

public struct PermissionLeaseKey: Codable, Equatable, Hashable, Sendable {
    public let projectID: String?
    public let sessionID: String?
    public let effect: ToolEffect
    public let toolName: String

    public init(projectID: String?, sessionID: String?, effect: ToolEffect, toolName: String) {
        self.projectID = projectID
        self.sessionID = sessionID
        self.effect = effect
        self.toolName = toolName
    }
}

public struct PermissionLease: Codable, Equatable, Sendable {
    public let id: String
    public let key: PermissionLeaseKey
    public let grantedAt: Date
    public let expiresAt: Date
    public let revokedAt: Date?

    public init(id: String = UUID().uuidString, key: PermissionLeaseKey, grantedAt: Date = Date(), expiresAt: Date, revokedAt: Date? = nil) {
        self.id = id
        self.key = key
        self.grantedAt = grantedAt
        self.expiresAt = expiresAt
        self.revokedAt = revokedAt
    }

    public func isActive(at date: Date = Date()) -> Bool {
        revokedAt == nil && expiresAt > date
    }
}

public final class PermissionLeaseStore: @unchecked Sendable {
    private let lock = NSLock()
    private var leases: [PermissionLeaseKey: PermissionLease] = [:]
    private let repository: SessionRepository?

    public init(repository: SessionRepository? = nil) {
        self.repository = repository
    }

    @discardableResult
    public func grant(key: PermissionLeaseKey, duration: TimeInterval, now: Date = Date()) throws -> PermissionLease {
        let lease = PermissionLease(key: key, grantedAt: now, expiresAt: now.addingTimeInterval(max(1, duration)))
        lock.lock()
        leases[key] = lease
        lock.unlock()
        try repository?.savePermissionLease(lease)
        return lease
    }

    public func isActive(key: PermissionLeaseKey, at date: Date = Date()) -> Bool {
        lock.lock()
        let cached = leases[key]
        lock.unlock()
        if let cached { return cached.isActive(at: date) }
        let persisted: PermissionLease?
        do {
            persisted = try repository?.permissionLease(key: key) ?? nil
        } catch {
            return false
        }
        guard let persisted else { return false }
        lock.lock()
        leases[key] = persisted
        lock.unlock()
        return persisted.isActive(at: date)
    }

    @discardableResult
    public func revoke(key: PermissionLeaseKey, at date: Date = Date()) -> Bool {
        lock.lock()
        let cached = leases[key]
        lock.unlock()
        let current = cached ?? ((try? repository?.permissionLease(key: key)) ?? nil)
        guard let current, current.revokedAt == nil else { return false }
        let revoked = PermissionLease(id: current.id, key: current.key, grantedAt: current.grantedAt, expiresAt: current.expiresAt, revokedAt: date)
        lock.lock()
        leases[key] = revoked
        lock.unlock()
        try? repository?.savePermissionLease(revoked)
        return true
    }
}
