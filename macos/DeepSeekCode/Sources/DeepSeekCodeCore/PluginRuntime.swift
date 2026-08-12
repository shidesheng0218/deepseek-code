import CryptoKit
import Foundation

/// Permission declarations are intentionally descriptive rather than an
/// escalation mechanism. The existing ToolRegistry and PermissionBroker still
/// decide what may run in a Session.
public enum PluginPermission: String, Codable, CaseIterable, Sendable {
    case context
    case skill
    case hook
    case mcp
    case lsp
    case workspaceRead
}

public enum PluginCapability: String, Codable, CaseIterable, Sendable {
    case readWorkspace
    case contributeContext
    case provideSkill
    case provideHook
    case provideMCP
    case provideLSP
}

public struct PluginManifest: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let name: String
    public let version: String
    public let description: String
    public let permissions: [PluginPermission]
    public let skills: [String]
    public let hooks: [String]
    public let mcp: [String]
    public let capabilities: [PluginCapability]

    private enum CodingKeys: String, CodingKey {
        case id, name, version, description, permissions, skills, hooks, mcp, capabilities
    }

    public init(id: String, name: String, version: String, description: String = "", permissions: [PluginPermission] = [], skills: [String] = [], hooks: [String] = [], mcp: [String] = [], capabilities: [PluginCapability] = []) {
        self.id = id
        self.name = name
        self.version = version
        self.description = description
        self.permissions = permissions
        self.skills = skills
        self.hooks = hooks
        self.mcp = mcp
        self.capabilities = capabilities
    }

    public var isValid: Bool {
        id.range(of: "^[a-z0-9][a-z0-9._-]{1,63}$", options: .regularExpression) != nil &&
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !version.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        pathsAreRelative(skills) && pathsAreRelative(hooks) && pathsAreRelative(mcp)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        version = try container.decode(String.self, forKey: .version)
        description = try container.decodeIfPresent(String.self, forKey: .description) ?? ""
        permissions = try container.decodeIfPresent([PluginPermission].self, forKey: .permissions) ?? []
        skills = try container.decodeIfPresent([String].self, forKey: .skills) ?? []
        hooks = try container.decodeIfPresent([String].self, forKey: .hooks) ?? []
        mcp = try container.decodeIfPresent([String].self, forKey: .mcp) ?? []
        capabilities = try container.decodeIfPresent([PluginCapability].self, forKey: .capabilities) ?? []
    }

    private func pathsAreRelative(_ paths: [String]) -> Bool {
        paths.allSatisfy { path in
            !path.hasPrefix("/") && !path.split(separator: "/").contains("..") && !path.contains("\\")
        }
    }
}

public struct PluginCapabilityRequest: Codable, Equatable, Sendable {
    public let pluginID: String
    public let capability: PluginCapability
    public let sessionID: String
    public let argumentsHash: String

    public init(pluginID: String, capability: PluginCapability, sessionID: String, argumentsHash: String) {
        self.pluginID = pluginID
        self.capability = capability
        self.sessionID = sessionID
        self.argumentsHash = argumentsHash
    }
}

/// Capability gate used by plugin adapters. Plugins never receive the main
/// ToolRegistry directly and cannot dynamically import local/npm code.
public enum PluginCapabilityBroker {
    public static func allows(
        _ request: PluginCapabilityRequest,
        record: PluginInstallRecord,
        developerMode: Bool = false,
        manifest: HostCapabilityManifest? = nil
    ) -> Bool {
        guard record.state == .enabled || (developerMode && record.state == .needsTrust) else { return false }
        let declared = record.manifest.capabilities.contains(request.capability) || impliedPermission(for: request.capability).map(record.manifest.permissions.contains) == true
        guard declared else { return false }
        guard let manifest else { return true }
        return manifest.allows(effect: effect(for: request.capability))
    }

    private static func impliedPermission(for capability: PluginCapability) -> PluginPermission? {
        switch capability {
        case .readWorkspace: .workspaceRead
        case .contributeContext: .context
        case .provideSkill: .skill
        case .provideHook: .hook
        case .provideMCP: .mcp
        case .provideLSP: .lsp
        }
    }

    private static func effect(for capability: PluginCapability) -> ToolEffect {
        switch capability {
        case .readWorkspace, .contributeContext, .provideSkill, .provideLSP:
            .readOnly
        case .provideHook:
            .process
        case .provideMCP:
            .externalWrite
        }
    }
}

public enum PluginInstallState: String, Codable, CaseIterable, Sendable {
    case installed
    case enabled
    case disabled
    case needsTrust
    case invalid

    public var title: String {
        switch self {
        case .installed: "已安装"
        case .enabled: "已启用"
        case .disabled: "已停用"
        case .needsTrust: "需要信任"
        case .invalid: "无效"
        }
    }
}

public struct PluginInstallRecord: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let manifest: PluginManifest
    public let sourcePath: String
    public let contentHash: String
    public var state: PluginInstallState
    public let installedAt: Date
    public var updatedAt: Date

    public init(manifest: PluginManifest, sourcePath: String, contentHash: String, state: PluginInstallState = .needsTrust, installedAt: Date = Date(), updatedAt: Date = Date()) {
        self.id = manifest.id
        self.manifest = manifest
        self.sourcePath = sourcePath
        self.contentHash = contentHash
        self.state = state
        self.installedAt = installedAt
        self.updatedAt = updatedAt
    }
}

public enum PluginRuntimeError: LocalizedError, Sendable {
    case missingManifest
    case invalidManifest
    case invalidSignature
    case unsafeSource

    public var errorDescription: String? {
        switch self {
        case .missingManifest: "Plugin 缺少 deepseek-plugin.json"
        case .invalidManifest: "Plugin Manifest 无效"
        case .invalidSignature: "Plugin 内容哈希校验失败"
        case .unsafeSource: "Plugin 路径不安全"
        }
    }
}

/// Local-first Plugin registry. Installing does not run arbitrary code. A
/// Plugin first becomes an inspectable record; enabling is a separate, durable
/// trust choice and its declared capabilities remain bounded by product policy.
public final class PluginRegistry: @unchecked Sendable {
    private let directory: URL
    private let installsURL: URL
    private let lock = NSLock()
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(directory: URL) throws {
        self.directory = directory
        installsURL = directory.appendingPathComponent("plugins.json")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    }

    public func list() throws -> [PluginInstallRecord] {
        lock.lock(); defer { lock.unlock() }
        guard let data = try? Data(contentsOf: installsURL) else { return [] }
        return try decoder.decode([PluginInstallRecord].self, from: data)
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    @discardableResult
    public func install(from source: URL, verifySignature: Bool = true) throws -> PluginInstallRecord {
        let root = source.standardizedFileURL.resolvingSymlinksInPath()
        guard root.pathExtension != "json", FileManager.default.fileExists(atPath: root.path) else { throw PluginRuntimeError.unsafeSource }
        let manifestURL = root.appendingPathComponent("deepseek-plugin.json")
        guard let data = try? Data(contentsOf: manifestURL) else { throw PluginRuntimeError.missingManifest }
        let manifest = try decoder.decode(PluginManifest.self, from: data)
        guard manifest.isValid else { throw PluginRuntimeError.invalidManifest }
        let digest = try contentHash(root: root)
        if verifySignature {
            let signatureURL = root.appendingPathComponent("deepseek-plugin.sha256")
            if let signature = try? String(contentsOf: signatureURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), !signature.isEmpty, signature.lowercased() != digest.lowercased() {
                throw PluginRuntimeError.invalidSignature
            }
        }
        var values = try list()
        let record = PluginInstallRecord(manifest: manifest, sourcePath: root.path, contentHash: digest)
        if let index = values.firstIndex(where: { $0.id == record.id }) { values[index] = record } else { values.append(record) }
        try save(values)
        return record
    }

    public func updateState(id: String, state: PluginInstallState) throws {
        var values = try list()
        guard let index = values.firstIndex(where: { $0.id == id }) else { return }
        values[index].state = state
        values[index].updatedAt = Date()
        try save(values)
    }

    /// Only enabled, context/skill contributions are exposed without another
    /// tool-level approval. Hook and MCP declarations are displayed but require
    /// their existing individual trust flows before registration.
    public func enabledSkillDescriptors() throws -> [SkillDescriptor] {
        try list().flatMap { record in
            guard record.state == .enabled, record.manifest.permissions.contains(.skill) || record.manifest.permissions.contains(.context) else { return [SkillDescriptor]() }
            let root = URL(fileURLWithPath: record.sourcePath, isDirectory: true)
            return record.manifest.skills.compactMap { relative in
                let url = root.appendingPathComponent(relative).standardizedFileURL
                guard url.path.hasPrefix(root.path + "/"), FileManager.default.fileExists(atPath: url.path) else { return nil }
                return SkillDescriptor(id: "plugin.\(record.id).\(url.deletingPathExtension().lastPathComponent)", name: "\(record.manifest.name) · \(url.deletingPathExtension().lastPathComponent)", path: url.path, scope: "plugin", enabled: true)
            }
        }
    }

    private func save(_ values: [PluginInstallRecord]) throws {
        lock.lock(); defer { lock.unlock() }
        try encoder.encode(values).write(to: installsURL, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: installsURL.path)
    }

    private func contentHash(root: URL) throws -> String {
        let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])
        var chunks = Data()
        let files = (enumerator?.allObjects as? [URL] ?? []).sorted { $0.path < $1.path }
        for url in files {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
            let relative = url.path.replacingOccurrences(of: root.path + "/", with: "")
            guard relative != "deepseek-plugin.sha256" else { continue }
            chunks.append(Data(relative.utf8))
            chunks.append(0)
            chunks.append(try Data(contentsOf: url))
            chunks.append(0)
        }
        return SHA256.hash(data: chunks).map { String(format: "%02x", $0) }.joined()
    }
}
