import CryptoKit
import Foundation

/// A single invocation result used by every local, remote and extension tool host.
public struct ToolInvocationResult: Codable, Equatable, Sendable {
    public let output: String
    public let succeeded: Bool
    public let indeterminate: Bool

    public init(output: String, succeeded: Bool = true, indeterminate: Bool = false) {
        self.output = output
        self.succeeded = succeeded
        self.indeterminate = indeterminate
    }
}

/// Resolves a registered tool to a concrete host.
///
/// This type deliberately owns no business lifecycle: requested, approval,
/// started, evidence and completion events are written by
/// `ToolExecutionPipeline`. Keeping this router pure prevents a GUI/CLI/
/// daemon caller from accidentally creating a second audit trail.
public final class ToolHostRouter: @unchecked Sendable {
    private let registry: ToolRegistry
    private let lock = NSLock()
    private var exactHosts: [String: any ToolHost] = [:]
    private var prefixHosts: [(String, any ToolHost)] = []

    public init(registry: ToolRegistry, repository: SessionRepository? = nil) {
        self.registry = registry
        // Kept source-compatible while callers move to ToolExecutionPipeline.
        _ = repository
    }

    public func register(host: any ToolHost, for toolName: String) {
        lock.lock()
        if toolName.hasSuffix(".") {
            prefixHosts.removeAll { $0.0 == toolName }
            prefixHosts.append((toolName, host))
            prefixHosts.sort { $0.0.count > $1.0.count }
        } else {
            exactHosts[toolName] = host
        }
        lock.unlock()
    }

    public func register(host: any ToolHost, forPrefix prefix: String) {
        lock.lock()
        prefixHosts.removeAll { $0.0 == prefix }
        prefixHosts.append((prefix, host))
        prefixHosts.sort { $0.0.count > $1.0.count }
        lock.unlock()
    }

    public var invocationEvents: [ToolInvocationRecord] {
        []
    }

    public func execute(tool: RegisteredTool, argumentsJSON: String, sessionID: String) async throws -> String {
        _ = argumentsJSON
        _ = sessionID
        guard let host = resolveHost(for: tool.name) else {
            throw UnifiedRuntimeError.toolHostUnavailable(tool.name)
        }
        return try await host.execute(tool: tool, argumentsJSON: argumentsJSON, sessionID: sessionID)
    }

    public func cancel(invocationID: String) async {
        // Invocation ownership belongs to ToolExecutionPipeline. The router
        // cannot safely infer the tool from an opaque invocation ID.
        _ = invocationID
    }

    private func resolveHost(for name: String) -> (any ToolHost)? {
        lock.lock()
        defer { lock.unlock() }
        if let host = exactHosts[name] { return host }
        return prefixHosts.first(where: { name.hasPrefix($0.0) })?.1
    }
}

public enum UnifiedRuntimeError: LocalizedError, Sendable {
    case toolHostUnavailable(String)
    case invalidArguments
    case remote(String)
    case hookTimedOut

    public var errorDescription: String? {
        switch self {
        case let .toolHostUnavailable(tool): "没有可用的工具 Host：\(tool)"
        case .invalidArguments: "工具参数不是有效 JSON"
        case let .remote(message): message
        case .hookTimedOut: "Hook 执行超时"
        }
    }
}

public struct HookExecutionResult: Equatable, Sendable {
    public let decision: HookDecision
    public let stdout: String
    public let stderr: String
    public let exitCode: Int32

    public init(decision: HookDecision, stdout: String, stderr: String, exitCode: Int32) {
        self.decision = decision
        self.stdout = stdout
        self.stderr = stderr
        self.exitCode = exitCode
    }
}

public extension HookRunner {
    /// Runs a trusted hook with a redacted JSON payload. Hooks are never allowed to
    /// mutate global permissions; they only return a decision for this invocation.
    static func execute(
        _ hook: HookDefinition,
        payload: [String: String],
        timeout: TimeInterval = 10,
        manifest: HostCapabilityManifest? = nil
    ) async throws -> HookExecutionResult {
        guard HookPolicy.canRun(hook) else { throw HookError.notTrustedOrUnsafe }
        if let manifest, !manifest.allows(effect: .process) {
            throw HostCapabilityError.denied
        }
        let process = Process()
        let input = Pipe()
        let output = Pipe()
        let errors = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", hook.command]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        let payloadData = try JSONEncoder().encode(SecretRedactor.redact(payload))
        try input.fileHandleForWriting.write(contentsOf: payloadData)
        try input.fileHandleForWriting.close()
        let finished = await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                process.waitUntilExit()
                return true
            }
            group.addTask {
                let manifestTimeout = manifest.map { TimeInterval($0.timeoutMilliseconds) / 1_000 } ?? timeout
                try? await Task.sleep(nanoseconds: UInt64(max(min(timeout, manifestTimeout), 0.1) * 1_000_000_000))
                return false
            }
            let value = await group.next() ?? false
            group.cancelAll()
            return value
        }
        guard finished else {
            process.terminate()
            throw UnifiedRuntimeError.hookTimedOut
        }
        let maximum = manifest?.maxOutputBytes ?? .max
        let stdout = String(decoding: output.fileHandleForReading.readDataToEndOfFile().prefix(maximum), as: UTF8.self)
        let stderr = String(decoding: errors.fileHandleForReading.readDataToEndOfFile().prefix(maximum), as: UTF8.self)
        return HookExecutionResult(decision: parseDecision(output: stdout), stdout: stdout, stderr: stderr, exitCode: process.terminationStatus)
    }
}

public enum HandoffFileStateKind: String, Codable, CaseIterable, Sendable {
    case unchanged
    case incomingOnly
    case localOnly
    case cleanMerge
    case conflict
    case deleted
    case renamed
    case binary
    case externalModified
}

public struct HandoffFileState: Codable, Equatable, Identifiable, Sendable {
    public var id: String { path }
    public let path: String
    public let baseContent: String?
    public let localContent: String?
    public let incomingContent: String?
    public let localHash: String?
    public let incomingHash: String?
    public let state: HandoffFileStateKind

    public init(path: String, baseContent: String?, localContent: String?, incomingContent: String?, localHash: String?, incomingHash: String?, state: HandoffFileStateKind) {
        self.path = path
        self.baseContent = baseContent
        self.localContent = localContent
        self.incomingContent = incomingContent
        self.localHash = localHash
        self.incomingHash = incomingHash
        self.state = state
    }
}

public struct HandoffEnginePreview: Codable, Equatable, Sendable {
    public let files: [HandoffFileState]
    public let conflicts: [HandoffFileState]

    public init(files: [HandoffFileState]) {
        self.files = files
        self.conflicts = files.filter { $0.state == .conflict }
    }

    public var isClean: Bool { conflicts.isEmpty }
}

public enum HandoffApplyError: LocalizedError, Sendable {
    case externalModified(path: String)
    case conflict(path: String)

    public var errorDescription: String? {
        switch self {
        case let .externalModified(path): "Handoff 目标文件已被外部修改：\(path)"
        case let .conflict(path): "Handoff 文件存在冲突：\(path)"
        }
    }
}

/// Deterministic, filesystem-level Handoff preview and application helper.
public struct WorktreeHandoffEngine: Sendable {
    public init() {}

    public func preview(baseFiles: [String: String], localRoot: URL, incomingRoot: URL) throws -> HandoffEnginePreview {
        let localFiles = try textFiles(root: localRoot)
        let incomingFiles = try textFiles(root: incomingRoot)
        let paths = Set(baseFiles.keys).union(localFiles.keys).union(incomingFiles.keys).sorted()
        let files = paths.map { path -> HandoffFileState in
            let base = baseFiles[path]
            let local = localFiles[path]
            let incoming = incomingFiles[path]
            let state = classify(base: base, local: local, incoming: incoming)
            return HandoffFileState(path: path, baseContent: base, localContent: local, incomingContent: incoming, localHash: local.map(Self.digest), incomingHash: incoming.map(Self.digest), state: state)
        }
        return HandoffEnginePreview(files: files)
    }

    public func applyCleanFiles(_ files: [HandoffFileState], to workspace: WorkspaceToolHost, label: String = "Worktree Handoff") throws -> PatchResult {
        let applicableFiles = files.filter { [.incomingOnly, .cleanMerge, .renamed, .deleted].contains($0.state) }
        for file in applicableFiles {
            guard file.state != .conflict else { throw HandoffApplyError.conflict(path: file.path) }
            let current = try? workspace.readEditableFile(path: file.path, maxBytes: 8_000_000)
            let currentHash = current?.sha256
            if currentHash != file.localHash {
                // A missing file is valid only when the preview also saw it missing.
                if !(current == nil && file.localHash == nil) {
                    throw HandoffApplyError.externalModified(path: file.path)
                }
            }
        }
        let changes = applicableFiles.compactMap { file -> PatchChange? in
            if let incoming = file.incomingContent {
                guard file.state == .incomingOnly || file.state == .cleanMerge || file.state == .renamed else { return nil }
                return PatchChange(path: file.path, content: incoming, expectedHash: file.localHash)
            }
            guard file.state == .deleted, file.localContent != nil else { return nil }
            return PatchChange(path: file.path, content: "", expectedHash: file.localHash, isDeletion: true)
        }
        return try workspace.applyPatch(changes: changes, label: label)
    }

    public func exportPatch(_ preview: HandoffEnginePreview) -> String {
        preview.files.filter { $0.state != .unchanged }.map { file in
            let before = file.localContent ?? ""
            let after = file.incomingContent ?? ""
            return "--- a/\(file.path)\n+++ b/\(file.path)\n@@\n-\(before)\n+\(after)"
        }.joined(separator: "\n")
    }

    private func classify(base: String?, local: String?, incoming: String?) -> HandoffFileStateKind {
        if base == local && local == incoming { return .unchanged }
        if incoming == nil && local == base && base != nil { return .deleted }
        if base == local && incoming != base { return .incomingOnly }
        if base == incoming && local != base { return .localOnly }
        if local == incoming { return .cleanMerge }
        if base == nil && local == nil && incoming != nil { return .incomingOnly }
        if incoming == nil && local != nil { return .localOnly }
        if local == nil && incoming != nil { return .conflict }
        if base != nil && local == nil && incoming == nil { return .deleted }
        return .conflict
    }

    private func textFiles(root: URL) throws -> [String: String] {
        guard FileManager.default.fileExists(atPath: root.path) else { return [:] }
        let canonicalRoot = root.standardizedFileURL.resolvingSymlinksInPath()
        let enumerator = FileManager.default.enumerator(at: canonicalRoot, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
        var result: [String: String] = [:]
        while let url = enumerator?.nextObject() as? URL {
            if [".git", "node_modules", ".deepseek"].contains(url.lastPathComponent), (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                enumerator?.skipDescendants()
                continue
            }
            guard (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) != true,
                  let content = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let canonicalURL = url.standardizedFileURL.resolvingSymlinksInPath()
            let relative = canonicalURL.path.replacingOccurrences(of: canonicalRoot.path + "/", with: "")
            result[relative] = content
        }
        return result
    }

    private static func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

public struct ScheduledRunRecord: Codable, Equatable, Identifiable, Sendable {
    public enum Status: String, Codable, Sendable { case queued, running, needsAttention, completed, failed, cancelled }
    public let id: String
    public let taskID: String
    public var status: Status
    public let createdAt: Date
    public var updatedAt: Date

    public init(id: String = UUID().uuidString, taskID: String, status: Status, createdAt: Date = Date(), updatedAt: Date = Date()) {
        self.id = id
        self.taskID = taskID
        self.status = status
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public protocol ScheduledNotificationSink: Sendable {
    func notify(title: String, body: String) async
}

public struct NoopScheduledNotificationSink: ScheduledNotificationSink {
    public init() {}
    public func notify(title: String, body: String) async {}
}

public actor ScheduledTaskCoordinator {
    private let repository: SessionRepository?
    private let notifications: any ScheduledNotificationSink
    private let networkPolicy: NetworkPolicy

    public init(repository: SessionRepository? = nil, notifications: any ScheduledNotificationSink = NoopScheduledNotificationSink(), networkPolicy: NetworkPolicy = .default) {
        self.repository = repository
        self.notifications = notifications
        self.networkPolicy = networkPolicy
    }

    public func preflight(task: ScheduledTask, commands: [String]) -> Bool {
        preflight(task: task, commands: commands, networkHosts: [])
    }

    public func preflight(task: ScheduledTask, commands: [String], networkHosts: [String]) -> Bool {
        guard task.isRunnable else { return false }
        guard commands.allSatisfy({ LaunchAgentRenderer.allowsUnattended(risk: CommandPolicy.classify($0)) }) else { return false }
        let allowedHosts = Set(task.allowedNetworkHosts.map { $0.lowercased() })
        guard networkHosts.allSatisfy({ allowedHosts.contains($0.lowercased()) || networkPolicy.trustedHosts.contains($0.lowercased()) }) else { return false }
        return task.mode == .auto || task.mode == .acceptEdits
    }

    public func start(task: ScheduledTask, sessionID: String? = nil) async throws -> ScheduledRunRecord {
        let run = ScheduledRunRecord(taskID: task.id, status: .running)
        try repository?.saveScheduledRun(run)
        try repository?.append(sessionID: sessionID ?? task.id, type: "scheduled_run_started", payload: ["runID": run.id, "taskID": task.id])
        return run
    }

    public func needsAttention(_ run: ScheduledRunRecord, reason: String, sessionID: String? = nil) async -> ScheduledRunRecord {
        var updated = run
        updated.status = .needsAttention
        updated.updatedAt = Date()
        try? repository?.saveScheduledRun(updated)
        try? repository?.append(sessionID: sessionID ?? run.taskID, type: "scheduled_run_needs_attention", payload: ["runID": run.id, "reason": SecretRedactor.redact(reason)])
        await notifications.notify(title: "DeepSeek Code 需要关注", body: reason)
        return updated
    }

    public func complete(_ run: ScheduledRunRecord, succeeded: Bool, sessionID: String? = nil) async -> ScheduledRunRecord {
        var updated = run
        updated.status = succeeded ? .completed : .failed
        updated.updatedAt = Date()
        try? repository?.saveScheduledRun(updated)
        try? repository?.append(sessionID: sessionID ?? run.taskID, type: "scheduled_run_completed", payload: ["runID": run.id, "succeeded": succeeded ? "true" : "false"])
        return updated
    }
}

public protocol SSHRemoteTransport: Sendable {
    func send(_ request: RemoteToolRequest) async throws -> RemoteToolResponse
    func handshake() async throws -> SSHCapabilityHandshake
}

public struct SSHCapabilityHandshake: Codable, Equatable, Sendable {
    public let protocolVersion: Int
    public let hostVersion: String
    public let checksum: String?
    public let capabilities: [String]

    public init(protocolVersion: Int = 1, hostVersion: String = "unknown", checksum: String? = nil, capabilities: [String] = []) {
        self.protocolVersion = protocolVersion
        self.hostVersion = hostVersion
        self.checksum = checksum
        self.capabilities = capabilities
    }
}

public extension SSHRemoteTransport {
    func handshake() async throws -> SSHCapabilityHandshake { SSHCapabilityHandshake() }
}

public struct SSHToolHost: ToolHost {
    public let host: SSHHost
    public let remotePath: String
    public let transport: any SSHRemoteTransport

    public init(host: SSHHost, remotePath: String, transport: any SSHRemoteTransport) {
        self.host = host
        self.remotePath = remotePath
        self.transport = transport
    }

    public func execute(tool: RegisteredTool, argumentsJSON: String, sessionID: String) async throws -> String {
        let request = RemoteToolRequest(id: UUID().uuidString, sessionID: sessionID, tool: tool.name, argumentsJSON: argumentsJSON)
        let response = try await transport.send(request)
        if response.indeterminate { throw UnifiedRuntimeError.remote("SSH 工具执行结果未知") }
        guard response.ok else { throw UnifiedRuntimeError.remote(response.output) }
        return response.output
    }

    public func cancel(invocationID: String) async {}
}

public protocol GitHubCommandRunning: Sendable {
    func run(arguments: [String]) async throws -> String
    func runGit(arguments: [String]) async throws -> String
}

public extension GitHubCommandRunning {
    func runGit(arguments: [String]) async throws -> String {
        throw UnifiedRuntimeError.remote("当前 GitHub Runner 不支持 Git Push")
    }
}

public struct GitHubToolHost: ToolHost {
    public let runner: any GitHubCommandRunning
    public let networkRuntime: NetworkRuntime?

    public init(runner: any GitHubCommandRunning, networkRuntime: NetworkRuntime? = nil) {
        self.runner = runner
        self.networkRuntime = networkRuntime
    }

    public func execute(tool: RegisteredTool, argumentsJSON: String, sessionID: String) async throws -> String {
        guard let data = argumentsJSON.data(using: .utf8), let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw UnifiedRuntimeError.invalidArguments }
        let name = tool.name
        let arguments: [String]
        switch name {
        case "github.create_pr":
            arguments = ["pr", "create", "--title", value["title"] as? String ?? "", "--body", value["body"] as? String ?? "", "--base", value["base"] as? String ?? "main", "--head", value["head"] as? String ?? ""]
        case "github.pr_checks":
            arguments = ["pr", "checks", String(value["number"] as? Int ?? 0)]
        case "github.ci_logs":
            let runID = value["runID"] as? String ?? ""
            guard !runID.isEmpty else { throw UnifiedRuntimeError.invalidArguments }
            arguments = ["run", "view", runID, "--log-failed"]
        case "github.view_pr":
            arguments = ["pr", "view", String(value["number"] as? Int ?? 0), "--json", "number,title,state,url,headRefName,baseRefName"]
        case "github.reply_review":
            arguments = ["pr", "comment", String(value["number"] as? Int ?? 0), "--body", value["body"] as? String ?? ""]
        case "github.push":
            arguments = []
        default: throw UnifiedRuntimeError.toolHostUnavailable(name)
        }
        if name == "github.push" {
            let remote = value["remote"] as? String ?? "origin"
            let branch = value["branch"] as? String
            var gitArguments = ["push", remote]
            if let branch, !branch.isEmpty { gitArguments.append(branch) }
            let endpoint = URL(string: "https://api.github.com")!
            await networkRuntime?.recordExternalRequest(capability: .github, operation: .delivery, url: endpoint, sessionID: sessionID, projectID: nil, state: .started)
            do {
                let output = try await runner.runGit(arguments: gitArguments)
                await networkRuntime?.recordExternalRequest(capability: .github, operation: .delivery, url: endpoint, sessionID: sessionID, projectID: nil, state: .completed, statusCode: 0)
                return output
            } catch {
                await networkRuntime?.recordExternalRequest(capability: .github, operation: .delivery, url: endpoint, sessionID: sessionID, projectID: nil, state: .failed, errorMessage: error.localizedDescription)
                throw error
            }
        }
        let operation: NetworkOperation = ["github.create_pr", "github.reply_review"].contains(name) ? .delivery : .read
        let endpoint = URL(string: "https://api.github.com")!
        await networkRuntime?.recordExternalRequest(capability: .github, operation: operation, url: endpoint, sessionID: sessionID, projectID: nil, state: .started)
        do {
            let output = try await runner.run(arguments: arguments)
            await networkRuntime?.recordExternalRequest(capability: .github, operation: operation, url: endpoint, sessionID: sessionID, projectID: nil, state: .completed, statusCode: 0)
            return output
        } catch {
            await networkRuntime?.recordExternalRequest(capability: .github, operation: operation, url: endpoint, sessionID: sessionID, projectID: nil, state: .failed, errorMessage: error.localizedDescription)
            throw error
        }
    }

    public func cancel(invocationID: String) async {}
}

/// Adapter for built-in workspace tools. Keeping it as a ToolHost means local,
/// MCP, SSH and GitHub calls share exactly the same router and audit path.
public struct LocalWorkspaceToolHost: ToolHost {
    public let workspace: WorkspaceToolHost

    public init(workspace: WorkspaceToolHost) { self.workspace = workspace }

    public func execute(tool: RegisteredTool, argumentsJSON: String, sessionID: String) async throws -> String {
        guard let data = argumentsJSON.data(using: .utf8), let arguments = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw UnifiedRuntimeError.invalidArguments
        }
        switch tool.name {
        case "list_directory":
            let path = arguments["path"] as? String ?? "."
            let entries = try workspace.listDirectory(path: path).map { ["name": $0.name, "type": $0.isDirectory ? "directory" : "file"] }
            return try encode(["ok": true, "entries": entries])
        case "search_workspace":
            let query = arguments["query"] as? String ?? ""
            let matches = try workspace.searchWorkspace(query: query).map { ["path": $0.path, "line": $0.line, "text": $0.text] }
            return try encode(["ok": true, "matches": matches])
        case "read_file":
            let path = arguments["path"] as? String ?? ""
            let startLine = arguments["startLine"] as? Int ?? 1
            let maxLines = arguments["maxLines"] as? Int ?? 200
            let value = try workspace.readFile(path: path, startLine: startLine, maxLines: maxLines)
            return try encode(["ok": true, "content": value.content, "sha256": value.sha256, "truncated": value.truncated])
        case "workspace_read_evidence":
            let path = arguments["path"] as? String ?? ""
            let startLine = arguments["startLine"] as? Int ?? 1
            let maxLines = arguments["maxLines"] as? Int ?? 200
            let maxBytes = arguments["maxBytes"] as? Int ?? 32_000
            let evidence = try workspace.readEvidence(path: path, sessionID: sessionID, startLine: startLine, maxLines: maxLines, maxBytes: maxBytes)
            return try encode([
                "ok": true,
                "evidenceID": evidence.id,
                "sessionID": evidence.sessionID ?? "",
                "path": evidence.path,
                "startLine": evidence.startLine,
                "endLine": evidence.endLine,
                "content": evidence.content,
                "contentHash": evidence.contentHash,
                "truncated": evidence.truncated,
                "byteCount": evidence.byteCount,
                "warnings": evidence.warnings
            ])
        case "lsp_query":
            let path = arguments["path"] as? String ?? ""
            let method = arguments["method"] as? String ?? "definition"
            let request = LSPQuery(path: path, method: method, line: arguments["line"] as? Int, column: arguments["column"] as? Int, symbol: arguments["symbol"] as? String)
            let result = await LocalLSPService().query(request, workspaceRoot: URL(fileURLWithPath: workspace.rootPath))
            return try encode(["method": result.method, "items": result.items, "available": result.available, "warnings": result.warnings])
        case "apply_patch":
            let label = arguments["label"] as? String ?? "Agent patch"
            let rawChanges = arguments["changes"] as? [[String: Any]] ?? []
            let changes = rawChanges.compactMap { value -> PatchChange? in
                guard let path = value["path"] as? String, let content = value["content"] as? String else { return nil }
                return PatchChange(path: path, content: content, expectedHash: value["expectedHash"] as? String)
            }
            let result = try workspace.applyPatch(changes: changes, label: label)
            return try encode(["ok": true, "checkpointID": result.checkpointID.uuidString, "changedFiles": result.changedFiles])
        case "inspect_git":
            let result = try workspace.gitStatus()
            return try encode(["ok": result.exitCode == 0, "output": result.stdout, "stderr": result.stderr])
        case "run_command":
            let command = arguments["command"] as? String ?? ""
            let timeout = arguments["timeoutMs"] as? Double ?? 120_000
            let result = try workspace.run(command: command, timeout: timeout / 1_000)
            return try encode(["ok": result.exitCode == 0, "stdout": result.stdout, "stderr": result.stderr, "exitCode": result.exitCode])
        default:
            throw UnifiedRuntimeError.toolHostUnavailable(tool.name)
        }
    }

    public func cancel(invocationID: String) async {}

    private func encode(_ value: Any) throws -> String {
        guard JSONSerialization.isValidJSONObject(value) else { throw UnifiedRuntimeError.invalidArguments }
        return String(decoding: try JSONSerialization.data(withJSONObject: value), as: UTF8.self)
    }
}
