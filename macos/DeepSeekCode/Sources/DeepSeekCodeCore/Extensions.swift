import Foundation

public struct ProjectInstructions: Sendable, Equatable {
    public let text: String
    public let sources: [String]

    public static func load(root: URL) throws -> ProjectInstructions {
        var pieces: [String] = []
        var sources: [String] = []
        for relative in ["CLAUDE.md", "AGENTS.md", ".deepseek/instructions.md"] {
            let url = root.appendingPathComponent(relative)
            if let text = try? String(contentsOf: url, encoding: .utf8) {
                pieces.append(text)
                sources.append(relative)
            }
        }
        return ProjectInstructions(text: pieces.joined(separator: "\n\n"), sources: sources)
    }
}

public struct SkillDescriptor: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let name: String
    public let path: String
    public let scope: String
    public let enabled: Bool
}

public struct SkillInvocation: Codable, Equatable, Sendable {
    public let descriptor: SkillDescriptor
    public let content: String
    public let requestedName: String

    public init(descriptor: SkillDescriptor, content: String, requestedName: String) {
        self.descriptor = descriptor
        self.content = content
        self.requestedName = requestedName
    }
}

public enum SkillRuntime {
    public static func resolve(requestedName: String, descriptors: [SkillDescriptor]) throws -> SkillInvocation {
        let normalized = requestedName.hasPrefix("/") ? String(requestedName.dropFirst()) : requestedName
        guard let descriptor = descriptors.first(where: { $0.id == normalized || $0.name == normalized }) else {
            throw SkillError.notFound(normalized)
        }
        let content = try String(contentsOfFile: descriptor.path, encoding: .utf8)
        return SkillInvocation(descriptor: descriptor, content: content, requestedName: normalized)
    }

    public static func promptSkill(in prompt: String, descriptors: [SkillDescriptor]) -> SkillInvocation? {
        guard let token = prompt.split(whereSeparator: { $0.isWhitespace }).first, token.hasPrefix("/") else { return nil }
        return try? resolve(requestedName: String(token), descriptors: descriptors)
    }
}

public enum SkillError: LocalizedError, Sendable {
    case notFound(String)
    public var errorDescription: String? {
        switch self { case let .notFound(name): "找不到 Skill：\(name)" }
    }
}

public enum SkillCatalog {
    public static func discover(globalDirectory: URL? = nil, projectDirectory: URL) throws -> [SkillDescriptor] {
        var roots: [(URL, String)] = [(projectDirectory.appendingPathComponent(".deepseek/skills", isDirectory: true), "project")]
        if let globalDirectory { roots.append((globalDirectory, "user")) }
        var result: [SkillDescriptor] = []
        for (root, scope) in roots {
            guard let entries = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { continue }
            for entry in entries where (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                let skillFile = entry.appendingPathComponent("SKILL.md")
                guard let content = try? String(contentsOf: skillFile, encoding: .utf8) else { continue }
                let name = content.split(separator: "\n").first.map(String.init)?.trimmingCharacters(in: CharacterSet(charactersIn: "# ")) ?? entry.lastPathComponent
                result.append(SkillDescriptor(id: entry.lastPathComponent, name: name, path: skillFile.path, scope: scope, enabled: true))
            }
        }
        return result.sorted { $0.id < $1.id }
    }
}

public struct MCPServerConfiguration: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public var name: String
    public var transport: Transport
    public var trusted: Bool
    public var enabled: Bool
    public var authorizationReference: String?

    public init(id: String, name: String, transport: Transport, trusted: Bool = false, enabled: Bool = true, authorizationReference: String? = nil) {
        self.id = id
        self.name = name
        self.transport = transport
        self.trusted = trusted
        self.enabled = enabled
        self.authorizationReference = authorizationReference
    }

    private enum CodingKeys: String, CodingKey { case id, name, transport, trusted, enabled, authorizationReference }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        transport = try container.decode(Transport.self, forKey: .transport)
        trusted = try container.decodeIfPresent(Bool.self, forKey: .trusted) ?? false
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        authorizationReference = try container.decodeIfPresent(String.self, forKey: .authorizationReference)
    }

    public var requiresTrust: Bool { !trusted }

    public enum Transport: Codable, Equatable, Sendable {
        case stdio(command: String, arguments: [String])
        case streamableHTTP(url: String)
    }
}

public struct HookDefinition: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let lifecycle: Lifecycle
    public let command: String
    public var trusted: Bool
    public var enabled: Bool

    public enum Lifecycle: String, Codable, Sendable {
        case sessionStart
        case beforePlan
        case preToolUse
        case approvalRequested
        case postToolUse
        case fileChanged
        case preCompact
        case postCompact
        case worktreeCreate
        case worktreeRemove
        case sessionEnd
    }

    public init(id: String, lifecycle: Lifecycle, command: String, trusted: Bool = false, enabled: Bool = true) {
        self.id = id
        self.lifecycle = lifecycle
        self.command = command
        self.trusted = trusted
        self.enabled = enabled
    }
}

public enum HookDecision: Equatable, Sendable {
    case allow
    case block(reason: String)
    case requireApproval(reason: String)
    case observe(reason: String)
}

public enum HookRunner {
    public static func parseDecision(output: String) -> HookDecision {
        guard let data = output.data(using: .utf8),
              let result = try? JSONDecoder().decode(HookResponse.self, from: data) else {
            return .allow
        }
        switch result.decision.lowercased() {
        case "block":
            return .block(reason: result.reason ?? "Hook 阻止了当前操作")
        case "require-approval", "require_approval", "requireapproval":
            return .requireApproval(reason: result.reason ?? "Hook 请求用户审批")
        case "observe":
            return .observe(reason: result.reason ?? "")
        default:
            return .allow
        }
    }

    private struct HookResponse: Decodable {
        let decision: String
        let reason: String?
    }
}

public struct SSHHost: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let hostname: String
    public let user: String
    public let port: Int
    public let fingerprint: String?
    /// Optional local key path. The key remains on the Mac; only OpenSSH reads
    /// it, never the model or the Event Store.
    public let identityFile: String?
    /// Optional pinned known-hosts file for deterministic non-interactive
    /// connections (used by loopback/CI fixtures and advanced BYOK SSH).
    public let knownHostsFile: String?

    public init(id: String, hostname: String, user: String, port: Int = 22, fingerprint: String? = nil, identityFile: String? = nil, knownHostsFile: String? = nil) {
        self.id = id
        self.hostname = hostname
        self.user = user
        self.port = port
        self.fingerprint = fingerprint
        self.identityFile = identityFile
        self.knownHostsFile = knownHostsFile
    }
}

public enum SSHClientArguments {
    public static func options(for host: SSHHost, portFlag: String = "-p") -> [String] {
        var arguments = [portFlag, "\(host.port)"]
        if let identityFile = host.identityFile, !identityFile.isEmpty {
            arguments += ["-i", identityFile, "-o", "IdentitiesOnly=yes"]
        }
        if let knownHostsFile = host.knownHostsFile, !knownHostsFile.isEmpty {
            arguments += ["-o", "UserKnownHostsFile=\(knownHostsFile)", "-o", "StrictHostKeyChecking=yes"]
        }
        return arguments
    }
}

public enum SSHCommandBuilder {
    public static func command(host: SSHHost, command: String) -> String {
        "ssh -p \(host.port) \(host.user)@\(host.hostname) -- \(command)"
    }
}

public struct ScheduledTask: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let prompt: String
    public let projectPath: String
    public let schedule: String
    public var enabled: Bool
    public var mode: AgentMode
    public var maxRuntimeMinutes: Int
    public var allowedNetworkHosts: [String]
    public var networkGrantIDs: [String]

    public init(id: String, prompt: String, projectPath: String, schedule: String, enabled: Bool, mode: AgentMode = .auto, maxRuntimeMinutes: Int = 30, allowedNetworkHosts: [String] = [], networkGrantIDs: [String] = []) {
        self.id = id
        self.prompt = prompt
        self.projectPath = projectPath
        self.schedule = schedule
        self.enabled = enabled
        self.mode = mode
        self.maxRuntimeMinutes = maxRuntimeMinutes
        self.allowedNetworkHosts = allowedNetworkHosts.map { $0.lowercased() }
        self.networkGrantIDs = networkGrantIDs
    }

    private enum CodingKeys: String, CodingKey { case id, prompt, projectPath, schedule, enabled, mode, maxRuntimeMinutes, allowedNetworkHosts, networkGrantIDs }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        prompt = try container.decode(String.self, forKey: .prompt)
        projectPath = try container.decode(String.self, forKey: .projectPath)
        schedule = try container.decode(String.self, forKey: .schedule)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        mode = try container.decodeIfPresent(AgentMode.self, forKey: .mode) ?? .auto
        maxRuntimeMinutes = try container.decodeIfPresent(Int.self, forKey: .maxRuntimeMinutes) ?? 30
        allowedNetworkHosts = (try container.decodeIfPresent([String].self, forKey: .allowedNetworkHosts) ?? []).map { $0.lowercased() }
        networkGrantIDs = try container.decodeIfPresent([String].self, forKey: .networkGrantIDs) ?? []
    }

    public var isRunnable: Bool { enabled && !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !projectPath.isEmpty }
}

/// Handoff payload written by the LaunchAgent helper. It contains no API keys
/// and is consumed by the foreground macOS app before it starts an Agent run.
public struct ScheduledTrigger: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let task: ScheduledTask
    public let createdAt: Date

    public init(id: String = UUID().uuidString, task: ScheduledTask, createdAt: Date = Date()) {
        self.id = id
        self.task = task
        self.createdAt = createdAt
    }
}

public enum ScheduledTriggerStore {
    public static func write(_ trigger: ScheduledTrigger, directory: URL) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("\(trigger.id).json")
        try JSONEncoder().encode(trigger).write(to: url, options: .atomic)
        return url
    }

    public static func read(from url: URL) throws -> ScheduledTrigger {
        try JSONDecoder().decode(ScheduledTrigger.self, from: Data(contentsOf: url))
    }

    public static func consume(from url: URL) throws -> ScheduledTrigger {
        let trigger = try read(from: url)
        try FileManager.default.removeItem(at: url)
        return trigger
    }
}

public enum HookPolicy {
    public static func canRun(_ hook: HookDefinition) -> Bool {
        hook.enabled && hook.trusted && CommandPolicy.classify(hook.command) <= .l1
    }

    public static func run(_ hook: HookDefinition, in workspace: WorkspaceToolHost) throws -> CommandOutput {
        guard canRun(hook) else { throw HookError.notTrustedOrUnsafe }
        return try workspace.run(command: hook.command)
    }
}

public enum HookError: LocalizedError {
    case notTrustedOrUnsafe
    public var errorDescription: String? { "Hook 未被信任或命令风险过高" }
}

public final class ExtensionStore: @unchecked Sendable {
    private let directory: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(directory: URL) throws {
        self.directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    public func saveMCP(_ server: MCPServerConfiguration) throws {
        var servers = try listMCP()
        if let index = servers.firstIndex(where: { $0.id == server.id }) { servers[index] = server } else { servers.append(server) }
        try encoder.encode(servers).write(to: directory.appendingPathComponent("mcp.json"), options: .atomic)
    }

    public func listMCP() throws -> [MCPServerConfiguration] {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("mcp.json")) else { return [] }
        return try decoder.decode([MCPServerConfiguration].self, from: data)
    }

    public func saveSearchProvider(_ provider: SearchProviderConfiguration) throws {
        var providers = try listSearchProviders()
        if let index = providers.firstIndex(where: { $0.id == provider.id }) { providers[index] = provider } else { providers.append(provider) }
        try encoder.encode(providers).write(to: directory.appendingPathComponent("search-providers.json"), options: .atomic)
    }

    public func listSearchProviders() throws -> [SearchProviderConfiguration] {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("search-providers.json")) else { return [] }
        return try decoder.decode([SearchProviderConfiguration].self, from: data)
    }

    public func saveScheduled(_ task: ScheduledTask) throws {
        var tasks = try listScheduled()
        if let index = tasks.firstIndex(where: { $0.id == task.id }) { tasks[index] = task } else { tasks.append(task) }
        try encoder.encode(tasks).write(to: directory.appendingPathComponent("scheduled.json"), options: .atomic)
    }

    public func listScheduled() throws -> [ScheduledTask] {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("scheduled.json")) else { return [] }
        return try decoder.decode([ScheduledTask].self, from: data)
    }

    public func saveHook(_ hook: HookDefinition) throws {
        var hooks = try listHooks()
        if let index = hooks.firstIndex(where: { $0.id == hook.id }) { hooks[index] = hook } else { hooks.append(hook) }
        try encoder.encode(hooks).write(to: directory.appendingPathComponent("hooks.json"), options: .atomic)
    }

    public func listHooks() throws -> [HookDefinition] {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("hooks.json")) else { return [] }
        return try decoder.decode([HookDefinition].self, from: data)
    }

    public func saveSSHHost(_ host: SSHHost) throws {
        var hosts = try listSSHHosts()
        if let index = hosts.firstIndex(where: { $0.id == host.id }) { hosts[index] = host } else { hosts.append(host) }
        try encoder.encode(hosts).write(to: directory.appendingPathComponent("ssh-hosts.json"), options: .atomic)
    }

    public func listSSHHosts() throws -> [SSHHost] {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("ssh-hosts.json")) else { return [] }
        return try decoder.decode([SSHHost].self, from: data)
    }

    public struct MigrationReport: Codable, Equatable, Sendable {
        public let migratedMCP: Int
        public let migratedScheduled: Int
        public let migratedHooks: Int
        public let backupDirectory: URL

        public init(migratedMCP: Int, migratedScheduled: Int, migratedHooks: Int, backupDirectory: URL) {
            self.migratedMCP = migratedMCP
            self.migratedScheduled = migratedScheduled
            self.migratedHooks = migratedHooks
            self.backupDirectory = backupDirectory
        }
    }

    public func migrateToSQLite(repository: SessionRepository) throws -> MigrationReport {
        let backup = directory.appendingPathComponent("migration-backup-\(Int(Date().timeIntervalSince1970))", isDirectory: true)
        try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: true)
        for filename in ["mcp.json", "scheduled.json", "hooks.json", "search-providers.json"] {
            let source = directory.appendingPathComponent(filename)
            if FileManager.default.fileExists(atPath: source.path) {
                try FileManager.default.copyItem(at: source, to: backup.appendingPathComponent(filename))
            }
        }
        let servers = try listMCP()
        let tasks = try listScheduled()
        let hooks = try listHooks()
        for value in servers {
            try repository.saveExtensionRecord(PersistedExtensionRecord(id: value.id, kind: "mcp", payload: ["name": value.name, "enabled": value.enabled ? "true" : "false"]), table: "mcp_servers")
        }
        for value in tasks {
            try repository.saveExtensionRecord(PersistedExtensionRecord(id: value.id, kind: "scheduled", payload: ["prompt": value.prompt, "projectPath": value.projectPath, "schedule": value.schedule]), table: "scheduled_tasks")
        }
        for value in hooks {
            try repository.saveExtensionRecord(PersistedExtensionRecord(id: value.id, kind: "hook", payload: ["command": SecretRedactor.redact(value.command), "lifecycle": value.lifecycle.rawValue]), table: "hooks")
        }
        return MigrationReport(migratedMCP: servers.count, migratedScheduled: tasks.count, migratedHooks: hooks.count, backupDirectory: backup)
    }
}
