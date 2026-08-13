import Foundation

/// Read-only mapping of a Claude-style project configuration. These values
/// inform prompts and UI diagnostics, but never override system safety,
/// SecretRedactor, PermissionBroker or plugin trust.
public struct ClaudeCompatibilitySettings: Codable, Equatable, Sendable {
    public let allowPatterns: [String]
    public let askPatterns: [String]
    public let denyPatterns: [String]
    public let environmentAllowlist: [String]
    public let defaultModel: String?
    public let unsupportedFields: [String]

    public init(
        allowPatterns: [String] = [],
        askPatterns: [String] = [],
        denyPatterns: [String] = [],
        environmentAllowlist: [String] = [],
        defaultModel: String? = nil,
        unsupportedFields: [String] = []
    ) {
        self.allowPatterns = allowPatterns
        self.askPatterns = askPatterns
        self.denyPatterns = denyPatterns
        self.environmentAllowlist = environmentAllowlist
        self.defaultModel = defaultModel
        self.unsupportedFields = unsupportedFields
    }
}

public struct ClaudeAgentContract: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let name: String
    public let description: String
    public let model: String?
    public let tools: [String]
    public let permissionMode: AgentMode?
    public let maxTurns: Int?
    public let path: String
    public let prompt: String

    public init(
        id: String,
        name: String,
        description: String,
        model: String?,
        tools: [String],
        permissionMode: AgentMode?,
        maxTurns: Int?,
        path: String,
        prompt: String
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.model = model
        self.tools = tools
        self.permissionMode = permissionMode
        self.maxTurns = maxTurns
        self.path = path
        self.prompt = prompt
    }
}

public struct ClaudeCompatibilitySnapshot: Codable, Equatable, Sendable {
    public let instructions: ResolvedInstructions
    public let settings: ClaudeCompatibilitySettings
    public let agents: [ClaudeAgentContract]
    public let skills: [SkillDescriptor]
    public let hooks: [HookDefinition]
    public let mcpServers: [MCPServerConfiguration]

    public init(
        instructions: ResolvedInstructions,
        settings: ClaudeCompatibilitySettings,
        agents: [ClaudeAgentContract],
        skills: [SkillDescriptor],
        hooks: [HookDefinition],
        mcpServers: [MCPServerConfiguration]
    ) {
        self.instructions = instructions
        self.settings = settings
        self.agents = agents
        self.skills = skills
        self.hooks = hooks
        self.mcpServers = mcpServers
    }
}

public enum ClaudeCompatibilityLoader {
    public static func load(workspaceRoot: URL, workingDirectory: URL? = nil, userGlobalInstructions: String = "") throws -> ClaudeCompatibilitySnapshot {
        let root = workspaceRoot.standardizedFileURL
        let working = (workingDirectory ?? root).standardizedFileURL
        return ClaudeCompatibilitySnapshot(
            instructions: try InstructionResolver.resolve(
                workspaceRoot: root,
                workingDirectory: working,
                userGlobalInstructions: userGlobalInstructions
            ),
            settings: loadSettings(root: root),
            agents: loadAgents(root: root),
            skills: loadSkills(root: root),
            hooks: loadHooks(root: root),
            mcpServers: loadMCP(root: root)
        )
    }

    private static func loadSettings(root: URL) -> ClaudeCompatibilitySettings {
        let files = [
            root.appendingPathComponent(".claude/settings.json"),
            root.appendingPathComponent(".claude/settings.local.json")
        ]
        var merged: [String: Any] = [:]
        for file in files {
            guard let data = try? Data(contentsOf: file),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            merged.merge(object) { _, later in later }
        }
        let permissions = merged["permissions"] as? [String: Any] ?? [:]
        let supportedTopLevel: Set<String> = ["permissions", "model", "env", "environment", "mcpServers", "hooks"]
        let unsupported = merged.keys.filter { !supportedTopLevel.contains($0) }.sorted()
        return ClaudeCompatibilitySettings(
            allowPatterns: stringArray(permissions["allow"]),
            askPatterns: stringArray(permissions["ask"]),
            denyPatterns: stringArray(permissions["deny"]),
            environmentAllowlist: stringArray(merged["env"] ?? merged["environment"]),
            defaultModel: (merged["model"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
            unsupportedFields: unsupported
        )
    }

    private static func loadAgents(root: URL) -> [ClaudeAgentContract] {
        let directory = root.appendingPathComponent(".claude/agents", isDirectory: true)
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return [] }
        return files
            .filter { $0.pathExtension.lowercased() == "md" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .compactMap { file in
                guard let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
                let parsed = frontMatter(text)
                let name = nonEmpty(parsed.values["name"]) ?? file.deletingPathExtension().lastPathComponent
                let relative = relativePath(file, root: root)
                return ClaudeAgentContract(
                    id: file.deletingPathExtension().lastPathComponent,
                    name: name,
                    description: nonEmpty(parsed.values["description"]) ?? "",
                    model: nonEmpty(parsed.values["model"]),
                    tools: parsed.values["tools"]?.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty } ?? [],
                    permissionMode: parsed.values["permissionMode"].flatMap(AgentMode.init(rawValue:)),
                    maxTurns: parsed.values["maxTurns"].flatMap(Int.init),
                    path: relative,
                    prompt: parsed.body
                )
            }
    }

    private static func loadSkills(root: URL) -> [SkillDescriptor] {
        let directory = root.appendingPathComponent(".claude/skills", isDirectory: true)
        guard let entries = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { return [] }
        return entries.compactMap { entry in
            guard (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { return nil }
            let skill = entry.appendingPathComponent("SKILL.md")
            guard let content = try? String(contentsOf: skill, encoding: .utf8) else { return nil }
            let name = content.split(separator: "\n").first.map(String.init)?.trimmingCharacters(in: CharacterSet(charactersIn: "# ")) ?? entry.lastPathComponent
            return SkillDescriptor(id: entry.lastPathComponent, name: name, path: skill.path, scope: "claude-project", enabled: true)
        }.sorted { $0.id < $1.id }
    }

    private static func loadHooks(root: URL) -> [HookDefinition] {
        let directory = root.appendingPathComponent(".claude/hooks", isDirectory: true)
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else { return [] }
        return files.compactMap { file in
            guard (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { return nil }
            // Imported Claude hooks are intentionally untrusted until a user
            // enables them. A project cannot self-authorize a process hook.
            return HookDefinition(
                id: "claude-hook-\(file.lastPathComponent)",
                lifecycle: .preToolUse,
                command: "/bin/zsh \(shellQuote(file.path))",
                trusted: false,
                enabled: true
            )
        }.sorted { $0.id < $1.id }
    }

    private static func loadMCP(root: URL) -> [MCPServerConfiguration] {
        let file = root.appendingPathComponent(".mcp.json")
        guard let data = try? Data(contentsOf: file),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let servers = object["mcpServers"] as? [String: Any] else { return [] }
        return servers.compactMap { id, raw in
            guard let value = raw as? [String: Any] else { return nil }
            if let command = value["command"] as? String, !command.isEmpty {
                return MCPServerConfiguration(
                    id: id,
                    name: (value["name"] as? String) ?? id,
                    transport: .stdio(command: command, arguments: stringArray(value["args"])),
                    trusted: false
                )
            }
            if let rawURL = value["url"] as? String, URL(string: rawURL) != nil {
                return MCPServerConfiguration(
                    id: id,
                    name: (value["name"] as? String) ?? id,
                    transport: .streamableHTTP(url: rawURL),
                    trusted: false
                )
            }
            return nil
        }.sorted { $0.id < $1.id }
    }

    private static func frontMatter(_ text: String) -> (values: [String: String], body: String) {
        let lines = text.components(separatedBy: .newlines)
        guard lines.first?.trimmingCharacters(in: .whitespacesAndNewlines) == "---" else { return ([:], text) }
        guard let end = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespacesAndNewlines) == "---" }) else { return ([:], text) }
        var values: [String: String] = [:]
        for line in lines[1..<end] {
            guard let separator = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<separator]).trimmingCharacters(in: .whitespacesAndNewlines)
            let value = String(line[line.index(after: separator)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !key.isEmpty { values[key] = value }
        }
        return (values, lines[(end + 1)...].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private static func stringArray(_ value: Any?) -> [String] {
        (value as? [Any] ?? []).compactMap { ($0 as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    private static func relativePath(_ file: URL, root: URL) -> String {
        let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        return file.path.replacingOccurrences(of: prefix, with: "")
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func shellQuote(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\\"'\\\"'"))'"
    }
}
