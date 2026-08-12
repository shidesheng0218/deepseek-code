import CryptoKit
import Darwin
import Foundation

public enum TerminalTarget: Codable, Equatable, Sendable {
    case local
    case worktree
    case ssh(hostID: String)

    private enum CodingKeys: String, CodingKey { case kind, hostID }

    public var label: String {
        switch self {
        case .local: "Local"
        case .worktree: "Worktree"
        case let .ssh(hostID): "SSH · \(hostID)"
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .local:
            try container.encode("local", forKey: .kind)
        case .worktree:
            try container.encode("worktree", forKey: .kind)
        case let .ssh(hostID):
            try container.encode("ssh", forKey: .kind)
            try container.encode(hostID, forKey: .hostID)
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .kind) {
        case "local": self = .local
        case "worktree": self = .worktree
        case "ssh": self = .ssh(hostID: try container.decode(String.self, forKey: .hostID))
        default: self = .local
        }
    }
}

public enum TerminalSessionState: String, Codable, CaseIterable, Sendable {
    case starting
    case running
    case background
    case exited
    case stopped
    case failed
    case indeterminate
    case needsAttention
}

public enum TerminalHelperConnectionState: String, Codable, CaseIterable, Sendable {
    case idle
    case starting
    case connected
    case reconnecting
    case needsAttention
    case legacy

    public var title: String {
        switch self {
        case .idle: "Helper 未连接"
        case .starting: "Helper 启动中"
        case .connected: "Persistent Helper 已连接"
        case .reconnecting: "Helper 重连中"
        case .needsAttention: "Helper 需要确认"
        case .legacy: "Legacy Terminal"
        }
    }

    public var systemImage: String {
        switch self {
        case .idle: "circle"
        case .starting, .reconnecting: "arrow.triangle.2.circlepath"
        case .connected: "checkmark.circle.fill"
        case .needsAttention: "exclamationmark.triangle.fill"
        case .legacy: "exclamationmark.circle"
        }
    }
}

public enum TerminalSignal: String, Codable, Sendable {
    case interrupt
    case terminate
    case kill
    case eof
}

public struct TerminalLaunchSpec: Codable, Equatable, Sendable {
    public let sessionID: String
    public let target: TerminalTarget
    public let cwd: String
    public let command: String?
    public let columns: Int
    public let rows: Int
    public let background: Bool
    public let sandbox: SandboxLaunchPolicy?

    public init(
        sessionID: String,
        target: TerminalTarget,
        cwd: String,
        command: String? = nil,
        columns: Int = 120,
        rows: Int = 30,
        background: Bool = false,
        sandbox: SandboxLaunchPolicy? = nil
    ) {
        self.sessionID = sessionID
        self.target = target
        self.cwd = cwd
        self.command = command
        self.columns = max(1, columns)
        self.rows = max(1, rows)
        self.background = background
        self.sandbox = sandbox
    }
}

public struct TerminalSessionRecord: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let sessionID: String
    public let target: TerminalTarget
    public let cwd: String
    public let command: String?
    public var pid: Int32?
    public var state: TerminalSessionState
    public var columns: Int
    public var rows: Int
    public let startedAt: Date
    public var endedAt: Date?
    public var exitCode: Int32?
    public var outputHash: String?
    public var portIDs: [String]

    public init(
        id: String = UUID().uuidString,
        sessionID: String,
        target: TerminalTarget,
        cwd: String,
        command: String? = nil,
        pid: Int32? = nil,
        state: TerminalSessionState = .starting,
        columns: Int = 120,
        rows: Int = 30,
        startedAt: Date = Date(),
        endedAt: Date? = nil,
        exitCode: Int32? = nil,
        outputHash: String? = nil,
        portIDs: [String] = []
    ) {
        self.id = id
        self.sessionID = sessionID
        self.target = target
        self.cwd = cwd
        self.command = command
        self.pid = pid
        self.state = state
        self.columns = max(1, columns)
        self.rows = max(1, rows)
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.exitCode = exitCode
        self.outputHash = outputHash
        self.portIDs = portIDs
    }

    /// Terminal commands can contain credentials when pasted by a user. The
    /// durable record is intentionally a sanitized projection; the original
    /// command stays only in the live PTY process memory.
    public func redactedForPersistence() -> TerminalSessionRecord {
        TerminalSessionRecord(
            id: id,
            sessionID: sessionID,
            target: target,
            cwd: cwd,
            command: TerminalCommandSanitizer.storedValue(command),
            pid: pid,
            state: state,
            columns: columns,
            rows: rows,
            startedAt: startedAt,
            endedAt: endedAt,
            exitCode: exitCode,
            outputHash: outputHash,
            portIDs: portIDs
        )
    }
}

public enum TerminalEventKind: String, Codable, CaseIterable, Sendable {
    case requested
    case approved
    case started
    case input
    case output
    case resized
    case signaled
    case protectedInputRequired
    case protectedInputCompleted
    case completed
    case failed
    case indeterminate
    case attached
    case detached
    case portDiscovered
}

public struct TerminalAuditEvent: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let terminalID: String
    public let sessionID: String
    public let kind: TerminalEventKind
    public let detail: String
    public let protectedInput: Bool
    public let createdAt: Date

    public init(
        id: String = UUID().uuidString,
        terminalID: String,
        sessionID: String,
        kind: TerminalEventKind,
        detail: String = "",
        protectedInput: Bool = false,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.terminalID = terminalID
        self.sessionID = sessionID
        self.kind = kind
        self.detail = protectedInput ? "受保护输入已由用户完成" : SecretRedactor.redact(detail)
        self.protectedInput = protectedInput
        self.createdAt = createdAt
    }
}

public struct TerminalPortRecord: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let terminalID: String
    public let port: Int
    public let host: String
    public let discoveredAt: Date

    public init(id: String = UUID().uuidString, terminalID: String, port: Int, host: String = "localhost", discoveredAt: Date = Date()) {
        self.id = id
        self.terminalID = terminalID
        self.port = port
        self.host = host
        self.discoveredAt = discoveredAt
    }
}

public struct TerminalProcessRecord: Codable, Equatable, Sendable {
    public let terminalID: String
    public let pid: Int32?
    public let processGroup: Int32?
    public let commandHash: String
    public let cwd: String
    public let updatedAt: Date

    public init(terminalID: String, pid: Int32?, processGroup: Int32?, commandHash: String, cwd: String, updatedAt: Date = Date()) {
        self.terminalID = terminalID
        self.pid = pid
        self.processGroup = processGroup
        self.commandHash = commandHash
        self.cwd = cwd
        self.updatedAt = updatedAt
    }
}

public struct TerminalCommandHistoryRecord: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let sessionID: String
    public let terminalID: String
    public let command: String?
    public let commandHash: String
    public let risk: CommandRisk
    public let createdAt: Date

    public init(id: String = UUID().uuidString, sessionID: String, terminalID: String, command: String, risk: CommandRisk, createdAt: Date = Date()) {
        self.id = id
        self.sessionID = sessionID
        self.terminalID = terminalID
        self.command = TerminalCommandSanitizer.storedValue(command)
        self.commandHash = SHA256.hash(data: Data(command.utf8)).map { String(format: "%02x", $0) }.joined()
        self.risk = risk
        self.createdAt = createdAt
    }

    public init(id: String, sessionID: String, terminalID: String, storedCommand: String?, commandHash: String, risk: CommandRisk, createdAt: Date) {
        self.id = id
        self.sessionID = sessionID
        self.terminalID = terminalID
        self.command = storedCommand
        self.commandHash = commandHash
        self.risk = risk
        self.createdAt = createdAt
    }
}

public struct TerminalProcessInspection: Codable, Equatable, Sendable {
    public let isRunning: Bool
    public let commandMatches: Bool
    public let cwdMatches: Bool

    public init(isRunning: Bool, commandMatches: Bool, cwdMatches: Bool) {
        self.isRunning = isRunning
        self.commandMatches = commandMatches
        self.cwdMatches = cwdMatches
    }
}

public enum TerminalRecoveryPlanner {
    /// A process is never re-launched while recovering. A stale PID or a
    /// mismatched command/cwd is potentially another user's process, so it is
    /// surfaced as Needs Attention instead of being touched automatically.
    public static func recoveredRecord(_ record: TerminalSessionRecord, process: TerminalProcessInspection) -> TerminalSessionRecord {
        var recovered = record
        switch record.state {
        case .exited, .stopped, .failed, .needsAttention, .indeterminate:
            return recovered
        case .starting, .running, .background:
            guard process.isRunning else {
                recovered.state = .indeterminate
                return recovered
            }
            guard process.commandMatches, process.cwdMatches else {
                recovered.state = .needsAttention
                return recovered
            }
            if recovered.state == .starting { recovered.state = .running }
            return recovered
        }
    }
}

public enum TerminalProcessInspector {
    public static func inspect(_ record: TerminalSessionRecord) -> TerminalProcessInspection {
        guard let pid = record.pid, pid > 0 else {
            return TerminalProcessInspection(isRunning: false, commandMatches: false, cwdMatches: false)
        }
        let result = kill(pid, 0)
        guard result == 0 || errno == EPERM else {
            return TerminalProcessInspection(isRunning: false, commandMatches: false, cwdMatches: false)
        }
        let command = processCommand(pid: pid)
        let expected = record.command?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let commandMatches: Bool
        if expected.isEmpty {
            commandMatches = true
        } else if expected.hasPrefix("[SENSITIVE_COMMAND") {
            // A redacted command cannot prove identity, so the UI must not
            // auto-attach it after recovery.
            commandMatches = false
        } else {
            commandMatches = command.localizedCaseInsensitiveContains(expected)
        }
        // macOS does not offer an unprivileged, stable CWD API for every
        // process. A matching command is sufficient for classification; an
        // actual reattach still requires a live PTY descriptor.
        return TerminalProcessInspection(isRunning: true, commandMatches: commandMatches, cwdMatches: commandMatches)
    }

    private static func processCommand(pid: Int32) -> String {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-p", "\(pid)", "-o", "command="]
        process.standardOutput = output
        guard (try? process.run()) != nil else { return "" }
        process.waitUntilExit()
        return String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    }
}

/// Replays only durable terminal facts. It never launches a command or sends
/// a signal during recovery: a missing or mismatched process becomes an
/// explicit indeterminate/Needs Attention state for the user to resolve.
public struct TerminalRuntimeRecoveryCoordinator: Sendable {
    public let repository: SessionRepository

    public init(repository: SessionRepository) { self.repository = repository }

    public func recover(sessionID: String) throws -> [TerminalSessionRecord] {
        try repository.terminalSessions(sessionID: sessionID).map { record in
            let updated = TerminalRecoveryPlanner.recoveredRecord(record, process: TerminalProcessInspector.inspect(record))
            if updated.state != record.state {
                try repository.saveTerminalSession(updated)
                let kind: TerminalEventKind = updated.state == .needsAttention ? .indeterminate : .indeterminate
                try repository.appendTerminalEvent(TerminalAuditEvent(
                    terminalID: updated.id,
                    sessionID: updated.sessionID,
                    kind: kind,
                    detail: "App 重启后无法安全恢复 PTY；未自动重放"
                ))
                try repository.append(sessionID: updated.sessionID, type: "terminal_indeterminate", payload: [
                    "terminalID": updated.id,
                    "state": updated.state.rawValue,
                    "reason": "App 重启后无法安全恢复 PTY；未自动重放"
                ])
                try repository.append(sessionID: updated.sessionID, type: "session_status_changed", payload: ["status": SessionStatus.needsAttention.rawValue])
            }
            return updated
        }
    }
}

public enum TerminalPortDetector {
    public static func ports(in output: String) -> [Int] {
        let pattern = #"(?i)(?:https?://(?:localhost|127\.0\.0\.1|\[::1\])|(?:localhost|127\.0\.0\.1)):(\d{2,5})"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(output.startIndex..., in: output)
        var seen = Set<Int>()
        return regex.matches(in: output, range: range).compactMap { match in
            guard match.numberOfRanges > 1,
                  let swiftRange = Range(match.range(at: 1), in: output),
                  let port = Int(output[swiftRange]),
                  (1...65_535).contains(port),
                  seen.insert(port).inserted else { return nil }
            return port
        }
    }
}

public enum TerminalCommandSanitizer {
    private static let sensitiveTerms = ["password", "passphrase", "passcode", "token", "secret", "otp", "验证码", "密码", "私钥"]

    public static func storedValue(_ command: String?) -> String? {
        guard let command, !command.isEmpty else { return command }
        let normalized = command.lowercased()
        if sensitiveTerms.contains(where: normalized.contains) {
            let digest = SHA256.hash(data: Data(command.utf8)).map { String(format: "%02x", $0) }.joined()
            return "[SENSITIVE_COMMAND hash=\(digest)]"
        }
        return SecretRedactor.redact(command)
    }
}

public struct TerminalOutputChunk: Codable, Equatable, Sendable {
    public let sessionID: String
    public let text: String
    public let sequence: Int
    public let createdAt: Date

    public init(sessionID: String, text: String, sequence: Int, createdAt: Date = Date()) {
        self.sessionID = sessionID
        self.text = text
        self.sequence = sequence
        self.createdAt = createdAt
    }
}

public struct TerminalOutputSummary: Codable, Equatable, Sendable {
    public let sessionID: String
    public let command: String
    public let exitCode: Int32?
    public let tail: String
    public let errors: [String]
    public let ports: [Int]
    public let warnings: [String]
    public let outputHash: String

    public init(sessionID: String, command: String, exitCode: Int32?, tail: String, errors: [String] = [], ports: [Int] = [], warnings: [String] = [], outputHash: String) {
        self.sessionID = sessionID
        self.command = command
        self.exitCode = exitCode
        self.tail = tail
        self.errors = errors
        self.ports = ports
        self.warnings = warnings
        self.outputHash = outputHash
    }
}

public enum TerminalInputClassification: String, Codable, Sendable {
    case normal
    case protected
}

public enum TerminalInputGuard {
    private static let protectedTerms = [
        "password", "passphrase", "passcode", "token", "secret", "otp", "verification code",
        "密码", "口令", "验证码", "一次性验证码", "访问令牌", "私钥"
    ]

    public static func classify(_ output: String) -> TerminalInputClassification {
        let normalized = output.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return .normal }
        return protectedTerms.contains { normalized.contains($0) } ? .protected : .normal
    }
}

public struct TerminalOutputBuffer: Equatable, Sendable {
    public let capacity: Int
    private(set) public var text = ""

    public init(capacity: Int = 128_000) {
        self.capacity = max(1, capacity)
    }

    public mutating func append(_ value: String) {
        guard !value.isEmpty else { return }
        text.append(value)
        if text.count > capacity {
            text = String(text.suffix(capacity))
        }
    }

    public mutating func removeAll() {
        text.removeAll(keepingCapacity: true)
    }
}

public protocol TerminalHost: Sendable {
    func open(spec: TerminalLaunchSpec) async throws -> TerminalSessionRecord
    func write(sessionID: String, data: Data) async throws
    func resize(sessionID: String, columns: Int, rows: Int) async throws
    func signal(sessionID: String, signal: TerminalSignal) async throws
    func read(sessionID: String, maxBytes: Int) async throws -> TerminalOutputChunk
    func attach(sessionID: String) async throws
    func close(sessionID: String) async throws
}

public enum TerminalRuntimeError: LocalizedError, Equatable, Sendable {
    case sessionNotFound
    case noOutput
    case unsupportedTarget
    case protectedInputRequired
    case invalidArguments

    public var errorDescription: String? {
        switch self {
        case .sessionNotFound: "Terminal Session 不存在"
        case .noOutput: "Terminal 暂无可读取输出"
        case .unsupportedTarget: "当前 Terminal Host 不支持该目标"
        case .protectedInputRequired: "终端正在等待用户接管敏感输入"
        case .invalidArguments: "Terminal 参数无效"
        }
    }
}

/// Local PTY implementation shared by the manual terminal UI and Agent tools.
/// Output is consumed once from the PTY and then exposed through bounded chunks,
/// so a slow UI cannot block the child process or grow memory without limits.
public actor LocalTerminalHost: TerminalHost {
    private struct Entry {
        var pty: PTYSession
        var record: TerminalSessionRecord
        var buffer: TerminalOutputBuffer
        var chunks: [String]
        var nextSequence: Int
        var protectedInputRequired: Bool
    }

    private var entries: [String: Entry] = [:]
    private let persistentRegistry: PersistentTerminalRegistry?
    private let transcriptStore: TerminalTranscriptStore?
    private let socketPath: String

    public init(registry: PersistentTerminalRegistry? = nil, transcriptStore: TerminalTranscriptStore? = nil, socketPath: String = "") {
        persistentRegistry = registry
        self.transcriptStore = transcriptStore
        self.socketPath = socketPath
    }

    public func open(spec: TerminalLaunchSpec) async throws -> TerminalSessionRecord {
        switch spec.target {
        case .local, .worktree:
            break
        case .ssh:
            throw TerminalRuntimeError.unsupportedTarget
        }
        let cwd = URL(fileURLWithPath: spec.cwd, isDirectory: true)
        guard FileManager.default.fileExists(atPath: cwd.path) else {
            throw TerminalRuntimeError.invalidArguments
        }
        let preparedSandbox = try spec.sandbox.map { try SandboxRuntime.prepare(command: spec.command ?? "exec /bin/zsh -l", policy: $0) }
        let command = preparedSandbox?.command ?? spec.command ?? "exec /bin/zsh -l"
        let pty = try PTYManager().start(
            command: command,
            cwd: cwd,
            columns: spec.columns,
            rows: spec.rows,
            environment: preparedSandbox?.environment ?? [:],
            loginShell: preparedSandbox?.usesLoginShell ?? true
        )
        let state: TerminalSessionState = spec.background ? .background : .running
        let record = TerminalSessionRecord(
            sessionID: spec.sessionID,
            target: spec.target,
            cwd: cwd.path,
            command: spec.command,
            pid: pty.pid,
            state: state,
            columns: spec.columns,
            rows: spec.rows
        )
        entries[record.id] = Entry(pty: pty, record: record, buffer: TerminalOutputBuffer(), chunks: [], nextSequence: 0, protectedInputRequired: false)
        persistManifest(for: record, lastOutputSequence: -1)
        let id = record.id
        Task.detached(priority: .userInitiated) { [weak self, pty] in
            for await event in pty.events {
                await self?.ingest(id: id, event: event)
            }
        }
        return record
    }

    public func write(sessionID: String, data: Data) async throws {
        guard let entry = entries[sessionID] ?? entries.values.first(where: { $0.record.id == sessionID || $0.record.sessionID == sessionID }) else {
            throw TerminalRuntimeError.sessionNotFound
        }
        guard !entry.protectedInputRequired else { throw TerminalRuntimeError.protectedInputRequired }
        try entry.pty.write(String(decoding: data, as: UTF8.self))
    }

    /// Only the human-facing UI may call this method. Agent tool hosts never
    /// receive the method, so secrets do not cross the model/tool boundary.
    public func writeProtectedInput(sessionID: String, data: Data) async throws {
        guard var entry = entries[sessionID] ?? entries.values.first(where: { $0.record.id == sessionID || $0.record.sessionID == sessionID }) else {
            throw TerminalRuntimeError.sessionNotFound
        }
        try entry.pty.write(String(decoding: data, as: UTF8.self))
        entry.protectedInputRequired = false
        entries[entry.record.id] = entry
    }

    public func protectedInputRequired(terminalID: String) -> Bool {
        entries[terminalID]?.protectedInputRequired ?? false
    }

    public func resize(sessionID: String, columns: Int, rows: Int) async throws {
        guard var entry = entries[sessionID] ?? entries.values.first(where: { $0.record.id == sessionID || $0.record.sessionID == sessionID }) else {
            throw TerminalRuntimeError.sessionNotFound
        }
        try entry.pty.resize(columns: columns, rows: rows)
        entry.record.columns = max(1, columns)
        entry.record.rows = max(1, rows)
        entries[entry.record.id] = entry
    }

    public func signal(sessionID: String, signal: TerminalSignal) async throws {
        guard let entry = entries[sessionID] ?? entries.values.first(where: { $0.record.id == sessionID || $0.record.sessionID == sessionID }) else {
            throw TerminalRuntimeError.sessionNotFound
        }
        switch signal {
        case .interrupt: entry.pty.interrupt()
        case .terminate: entry.pty.terminate()
        case .kill: entry.pty.kill()
        case .eof: try entry.pty.eof()
        }
    }

    public func stopGracefully(sessionID: String) async throws {
        guard let entry = entries[sessionID] ?? entries.values.first(where: { $0.record.id == sessionID || $0.record.sessionID == sessionID }) else {
            throw TerminalRuntimeError.sessionNotFound
        }
        await entry.pty.stopGracefully()
    }

    public func read(sessionID: String, maxBytes: Int = 128_000) async throws -> TerminalOutputChunk {
        guard var entry = entries[sessionID] ?? entries.values.first(where: { $0.record.id == sessionID || $0.record.sessionID == sessionID }) else {
            throw TerminalRuntimeError.sessionNotFound
        }
        guard !entry.chunks.isEmpty else { throw TerminalRuntimeError.noOutput }
        var text = ""
        while let first = entry.chunks.first, text.utf8.count + first.utf8.count <= max(1, maxBytes) {
            text.append(first)
            entry.chunks.removeFirst()
        }
        if text.isEmpty, let first = entry.chunks.first {
            text = String(decoding: first.data(using: .utf8)?.prefix(max(1, maxBytes)) ?? Data(), as: UTF8.self)
            entry.chunks.removeFirst()
        }
        let sequence = max(0, entry.nextSequence - entry.chunks.count - 1)
        entries[entry.record.id] = entry
        return TerminalOutputChunk(sessionID: entry.record.sessionID, text: text, sequence: sequence)
    }

    public func attach(sessionID: String) async throws {
        guard entries[sessionID] != nil || entries.values.contains(where: { $0.record.id == sessionID || $0.record.sessionID == sessionID }) else {
            throw TerminalRuntimeError.sessionNotFound
        }
    }

    public func close(sessionID: String) async throws {
        guard let entry = entries[sessionID] ?? entries.values.first(where: { $0.record.id == sessionID || $0.record.sessionID == sessionID }) else {
            throw TerminalRuntimeError.sessionNotFound
        }
        entry.pty.terminate()
    }

    public func records(for sessionID: String) -> [TerminalSessionRecord] {
        entries.values.filter { $0.record.sessionID == sessionID }.map(\.record)
    }

    public func record(terminalID: String) -> TerminalSessionRecord? {
        entries[terminalID]?.record
    }

    public func output(terminalID: String) -> String {
        entries[terminalID]?.buffer.text ?? ""
    }

    fileprivate func updateTarget(terminalID: String, target: TerminalTarget) {
        guard var entry = entries[terminalID] else { return }
        entry.record = TerminalSessionRecord(
            id: entry.record.id,
            sessionID: entry.record.sessionID,
            target: target,
            cwd: entry.record.cwd,
            command: entry.record.command,
            pid: entry.record.pid,
            state: entry.record.state,
            columns: entry.record.columns,
            rows: entry.record.rows,
            startedAt: entry.record.startedAt,
            endedAt: entry.record.endedAt,
            exitCode: entry.record.exitCode,
            outputHash: entry.record.outputHash,
            portIDs: entry.record.portIDs
        )
        entries[terminalID] = entry
    }

    private func ingest(id: String, event: PTYEvent) {
        guard var entry = entries[id] else { return }
        switch event {
        case let .output(text):
            entry.buffer.append(text)
            entry.chunks.append(text)
            entry.nextSequence += 1
            if let transcriptStore, let persisted = try? transcriptStore.append(terminalID: id, sessionID: entry.record.sessionID, text: text) {
                persistManifest(for: entry.record, lastOutputSequence: persisted.sequence)
            }
            if TerminalInputGuard.classify(text) == .protected {
                entry.protectedInputRequired = true
            }
        case let .exited(code):
            entry.record.state = code == 0 ? .exited : .failed
            entry.record.exitCode = code
            entry.record.endedAt = Date()
            entry.record.outputHash = SHA256.hash(data: Data(entry.buffer.text.utf8)).map { String(format: "%02x", $0) }.joined()
            persistManifest(for: entry.record, lastOutputSequence: (try? transcriptStore?.lastSequence(terminalID: id)) ?? -1)
        }
        entries[id] = entry
    }

    private func persistManifest(for record: TerminalSessionRecord, lastOutputSequence: Int) {
        guard let persistentRegistry, let pid = record.pid else { return }
        let rawCommand = record.command ?? "exec /bin/zsh -l"
        let commandHash = SHA256.hash(data: Data(rawCommand.utf8)).map { String(format: "%02x", $0) }.joined()
        let manifest = TerminalProcessManifest(
            terminalID: record.id,
            sessionID: record.sessionID,
            pid: pid,
            processGroupID: pid,
            startedAt: record.startedAt,
            cwd: record.cwd,
            commandHash: commandHash,
            target: record.target,
            socketPath: socketPath,
            transcriptID: record.id,
            lastOutputSequence: lastOutputSequence,
            state: record.state
        )
        try? persistentRegistry.save(manifest)
    }
}

/// SSH PTYs are deliberately carried by the local PTY over `ssh -tt`. The
/// control plane, model credentials and audit storage remain on the Mac; the
/// remote host only receives an interactive shell stream.
public actor SSHTerminalHost: TerminalHost {
    private let local: LocalTerminalHost
    private let hosts: [String: SSHHost]

    public init(hosts: [SSHHost], localHost: LocalTerminalHost = LocalTerminalHost()) {
        self.hosts = Dictionary(uniqueKeysWithValues: hosts.map { ($0.id, $0) })
        self.local = localHost
    }

    public func open(spec: TerminalLaunchSpec) async throws -> TerminalSessionRecord {
        guard case let .ssh(hostID) = spec.target, let host = hosts[hostID], isSafe(host: host) else {
            throw TerminalRuntimeError.unsupportedTarget
        }
        let remoteShell = spec.command ?? "exec /bin/zsh -l"
        let remoteCommand = "cd \(quote(spec.cwd)) && \(remoteShell)"
        let command = "exec /usr/bin/ssh -tt -p \(host.port) \(quote("\(host.user)@\(host.hostname)")) -- \(quote(remoteCommand))"
        let localSpec = TerminalLaunchSpec(
            sessionID: spec.sessionID,
            target: .local,
            cwd: FileManager.default.currentDirectoryPath,
            command: command,
            columns: spec.columns,
            rows: spec.rows,
            background: spec.background
        )
        let record = try await local.open(spec: localSpec)
        await local.updateTarget(terminalID: record.id, target: spec.target)
        return await local.record(terminalID: record.id) ?? record
    }

    public func write(sessionID: String, data: Data) async throws { try await local.write(sessionID: sessionID, data: data) }
    public func resize(sessionID: String, columns: Int, rows: Int) async throws { try await local.resize(sessionID: sessionID, columns: columns, rows: rows) }
    public func signal(sessionID: String, signal: TerminalSignal) async throws { try await local.signal(sessionID: sessionID, signal: signal) }
    public func read(sessionID: String, maxBytes: Int) async throws -> TerminalOutputChunk { try await local.read(sessionID: sessionID, maxBytes: maxBytes) }
    public func attach(sessionID: String) async throws { try await local.attach(sessionID: sessionID) }
    public func close(sessionID: String) async throws { try await local.close(sessionID: sessionID) }

    private func isSafe(host: SSHHost) -> Bool {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        return host.port > 0 && host.port <= 65_535 && host.hostname.unicodeScalars.allSatisfy(allowed.contains) && host.user.unicodeScalars.allSatisfy(allowed.contains)
    }

    private func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

/// ToolRegistry adapter for the PTY runtime. It deliberately returns
/// structured summaries rather than pushing the raw terminal transcript into
/// the model context. The full transcript remains a local UI concern.
public struct TerminalToolHost: ToolHost {
    public let localHost: LocalTerminalHost
    public let repository: SessionRepository?
    public let defaultCWD: String?
    public let manifest: HostCapabilityManifest?

    public init(localHost: LocalTerminalHost, repository: SessionRepository? = nil, defaultCWD: String? = nil, manifest: HostCapabilityManifest? = nil) {
        self.localHost = localHost
        self.repository = repository
        self.defaultCWD = defaultCWD
        self.manifest = manifest
    }

    public func execute(tool: RegisteredTool, argumentsJSON: String, sessionID: String) async throws -> String {
        guard let data = argumentsJSON.data(using: .utf8),
              let arguments = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw TerminalRuntimeError.invalidArguments
        }
        switch tool.name {
        case "run_command", "terminal.exec":
            let command = arguments["command"] as? String ?? ""
            guard !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw TerminalRuntimeError.invalidArguments }
            let cwd = (arguments["cwd"] as? String) ?? defaultCWD ?? FileManager.default.currentDirectoryPath
            try enforceManifest(effect: tool.effect, cwd: cwd, command: command)
            let columns = arguments["columns"] as? Int ?? 120
            let rows = arguments["rows"] as? Int ?? 30
            let background = arguments["background"] as? Bool ?? false
            let record = try await open(spec: TerminalLaunchSpec(sessionID: sessionID, target: .local, cwd: cwd, command: command, columns: columns, rows: rows, background: background))
            if background {
                return try encode(["ok": true, "terminalID": record.id, "pid": record.pid as Any, "state": record.state.rawValue])
            }
            return try await waitForCompletion(record: record, command: command, timeoutMilliseconds: arguments["timeoutMs"] as? Int ?? tool.timeoutMilliseconds)
        case "terminal.open":
            let cwd = (arguments["cwd"] as? String) ?? defaultCWD ?? FileManager.default.currentDirectoryPath
            let command = arguments["command"] as? String
            try enforceManifest(effect: tool.effect, cwd: cwd, command: command)
            let background = arguments["background"] as? Bool ?? false
            let record = try await open(spec: TerminalLaunchSpec(sessionID: sessionID, target: .local, cwd: cwd, command: command, columns: arguments["columns"] as? Int ?? 120, rows: arguments["rows"] as? Int ?? 30, background: background))
            return try encode(["ok": true, "terminalID": record.id, "pid": record.pid as Any, "state": record.state.rawValue, "cwd": record.cwd])
        case "terminal.read":
            let id = terminalID(arguments, sessionID: sessionID)
            do {
                let chunk = try await localHost.read(sessionID: id, maxBytes: arguments["maxBytes"] as? Int ?? tool.maxOutputBytes)
                return try encode(["ok": true, "terminalID": id, "sequence": chunk.sequence, "text": SecretRedactor.redact(chunk.text)])
            } catch TerminalRuntimeError.noOutput {
                return try encode(["ok": true, "terminalID": id, "text": "", "state": (await localHost.record(terminalID: id))?.state.rawValue as Any])
            }
        case "terminal.write":
            let id = terminalID(arguments, sessionID: sessionID)
            guard let input = arguments["data"] as? String else { throw TerminalRuntimeError.invalidArguments }
            try await localHost.write(sessionID: id, data: Data(input.utf8))
            await persist(TerminalAuditEvent(terminalID: id, sessionID: sessionID, kind: .input, detail: "\(input.utf8.count) bytes"))
            return try encode(["ok": true, "terminalID": id])
        case "terminal.resize":
            let id = terminalID(arguments, sessionID: sessionID)
            let columns = arguments["columns"] as? Int ?? 120
            let rows = arguments["rows"] as? Int ?? 30
            try await localHost.resize(sessionID: id, columns: columns, rows: rows)
            await persist(TerminalAuditEvent(terminalID: id, sessionID: sessionID, kind: .resized, detail: "\(columns)x\(rows)"))
            return try encode(["ok": true, "terminalID": id])
        case "terminal.signal":
            let id = terminalID(arguments, sessionID: sessionID)
            guard let raw = arguments["signal"] as? String, let signal = TerminalSignal(rawValue: raw) else { throw TerminalRuntimeError.invalidArguments }
            try await localHost.signal(sessionID: id, signal: signal)
            await persist(TerminalAuditEvent(terminalID: id, sessionID: sessionID, kind: .signaled, detail: signal.rawValue))
            return try encode(["ok": true, "terminalID": id])
        case "terminal.list":
            let records = await localHost.records(for: sessionID)
            return try encode(["ok": true, "sessions": records.map { ["id": $0.id, "state": $0.state.rawValue, "cwd": $0.cwd, "pid": $0.pid as Any] }])
        case "terminal.attach":
            let id = terminalID(arguments, sessionID: sessionID)
            try await localHost.attach(sessionID: id)
            await persist(TerminalAuditEvent(terminalID: id, sessionID: sessionID, kind: .attached))
            return try encode(["ok": true, "terminalID": id])
        case "terminal.ports":
            let id = terminalID(arguments, sessionID: sessionID)
            let output = await localHost.output(terminalID: id)
            let ports = TerminalPortDetector.ports(in: output)
            return try encode(["ok": true, "terminalID": id, "ports": ports])
        case "terminal.close":
            let id = terminalID(arguments, sessionID: sessionID)
            try await localHost.close(sessionID: id)
            await persist(TerminalAuditEvent(terminalID: id, sessionID: sessionID, kind: .detached, detail: "closed"))
            return try encode(["ok": true, "terminalID": id])
        default:
            throw TerminalRuntimeError.invalidArguments
        }
    }

    public func cancel(invocationID: String) async {}

    private func open(spec: TerminalLaunchSpec) async throws -> TerminalSessionRecord {
        let record = try await localHost.open(spec: spec)
        try? repository?.saveTerminalSession(record)
        await persist(TerminalAuditEvent(terminalID: record.id, sessionID: record.sessionID, kind: .started, detail: "pid \(record.pid.map(String.init) ?? "-")"))
        return record
    }

    private func waitForCompletion(record: TerminalSessionRecord, command: String, timeoutMilliseconds: Int) async throws -> String {
        let deadline = Date().addingTimeInterval(TimeInterval(max(100, timeoutMilliseconds)) / 1_000)
        while Date() < deadline {
            while let chunk = try? await localHost.read(sessionID: record.id, maxBytes: 128_000) {
                _ = chunk
            }
            if let current = await localHost.record(terminalID: record.id), [.exited, .failed, .stopped].contains(current.state) {
                let output = await localHost.output(terminalID: record.id)
                let summary = makeSummary(record: current, command: command, output: output)
                try? repository?.saveTerminalSession(current)
                await persist(TerminalAuditEvent(terminalID: record.id, sessionID: record.sessionID, kind: current.state == .exited ? .completed : .failed, detail: "exit \(current.exitCode.map(String.init) ?? "unknown")"))
                let summaryData = try JSONEncoder().encode(summary)
                guard let summaryObject = try JSONSerialization.jsonObject(with: summaryData) as? [String: Any] else {
                    throw TerminalRuntimeError.invalidArguments
                }
                return try encode(["ok": current.exitCode == 0, "terminalID": record.id, "exitCode": current.exitCode as Any, "summary": summaryObject])
            }
            try? await Task.sleep(nanoseconds: 25_000_000)
        }
        try? await localHost.signal(sessionID: record.id, signal: .terminate)
        await persist(TerminalAuditEvent(terminalID: record.id, sessionID: record.sessionID, kind: .indeterminate, detail: "timeout"))
        return try encode(["ok": false, "terminalID": record.id, "indeterminate": true, "message": "Terminal 超时，结果未知；请在 Terminal 中检查进程"])
    }

    private func makeSummary(record: TerminalSessionRecord, command: String, output: String) -> TerminalOutputSummary {
        let errors = output.split(separator: "\n").map(String.init).filter { line in
            let value = line.lowercased()
            return value.contains("error") || value.contains("failed") || value.contains("fatal")
        }.suffix(12)
        let ports = TerminalPortDetector.ports(in: output)
        let hash = record.outputHash ?? SHA256.hash(data: Data(output.utf8)).map { String(format: "%02x", $0) }.joined()
        return TerminalOutputSummary(sessionID: record.sessionID, command: TerminalCommandSanitizer.storedValue(command) ?? "", exitCode: record.exitCode, tail: SecretRedactor.redact(String(output.suffix(4_000))), errors: errors.map(SecretRedactor.redact), ports: ports, outputHash: hash)
    }

    private func terminalID(_ arguments: [String: Any], sessionID: String) -> String {
        arguments["terminalID"] as? String ?? sessionID
    }

    private func enforceManifest(effect: ToolEffect, cwd: String, command: String?) throws {
        guard let manifest else { return }
        guard manifest.allows(effect: effect, path: cwd) else { throw HostCapabilityError.denied }
        if let command, ShellIntentAnalyzer.analyze(command).accessesNetwork,
           !manifest.allows(effect: .network) {
            throw HostCapabilityError.denied
        }
    }

    private func encode(_ value: Any) throws -> String {
        guard JSONSerialization.isValidJSONObject(value) else { throw TerminalRuntimeError.invalidArguments }
        return String(decoding: try JSONSerialization.data(withJSONObject: value), as: UTF8.self)
    }

    private func persist(_ event: TerminalAuditEvent) async {
        try? repository?.appendTerminalEvent(event)
        try? repository?.append(sessionID: event.sessionID, type: "terminal_\(event.kind.rawValue)", payload: ["terminalID": event.terminalID, "detail": event.detail])
    }
}

/// ToolRegistry adapter for a persistent Helper-backed host. It mirrors the
/// legacy TerminalToolHost contract so old `run_command` calls can migrate
/// without changing Agent schemas.
public struct PersistentTerminalToolHost: ToolHost {
    public let host: any PersistentTerminalHost
    public let repository: SessionRepository?
    public let defaultCWD: String?
    public let sandboxRoot: String?
    public let sandboxScratchRoot: String?
    public let manifest: HostCapabilityManifest?

    public init(host: any PersistentTerminalHost, repository: SessionRepository? = nil, defaultCWD: String? = nil, sandboxRoot: String? = nil, sandboxScratchRoot: String? = nil, manifest: HostCapabilityManifest? = nil) {
        self.host = host
        self.repository = repository
        self.defaultCWD = defaultCWD
        self.sandboxRoot = sandboxRoot
        self.sandboxScratchRoot = sandboxScratchRoot
        self.manifest = manifest
    }

    public func execute(tool: RegisteredTool, argumentsJSON: String, sessionID: String) async throws -> String {
        guard let data = argumentsJSON.data(using: .utf8), let arguments = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw TerminalRuntimeError.invalidArguments }
        let id = arguments["terminalID"] as? String
        switch tool.name {
        case "terminal.open":
            let cwd = arguments["cwd"] as? String ?? defaultCWD ?? FileManager.default.currentDirectoryPath
            try enforceManifest(effect: tool.effect, cwd: cwd, command: arguments["command"] as? String)
            let spec = TerminalLaunchSpec(sessionID: sessionID, target: .local, cwd: cwd, command: arguments["command"] as? String, columns: arguments["columns"] as? Int ?? 120, rows: arguments["rows"] as? Int ?? 30, background: arguments["background"] as? Bool ?? false, sandbox: sandboxPolicy(sessionID: sessionID, cwd: cwd, allowsNetwork: false))
            let record = try await host.open(spec: spec)
            persistOpened(record, command: spec.command, risk: tool.risk, sandboxed: spec.sandbox != nil)
            return try encode(["ok": true, "terminalID": record.id, "pid": record.pid as Any, "state": record.state.rawValue, "cwd": record.cwd])
        case "terminal.exec", "run_command":
            guard let command = arguments["command"] as? String, !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw TerminalRuntimeError.invalidArguments }
            let cwd = arguments["cwd"] as? String ?? defaultCWD ?? FileManager.default.currentDirectoryPath
            try enforceManifest(effect: tool.effect, cwd: cwd, command: command)
            let spec = TerminalLaunchSpec(sessionID: sessionID, target: .local, cwd: cwd, command: command, columns: arguments["columns"] as? Int ?? 120, rows: arguments["rows"] as? Int ?? 30, background: arguments["background"] as? Bool ?? false, sandbox: sandboxPolicy(sessionID: sessionID, cwd: cwd, allowsNetwork: tool.risk.rawValue >= CommandRisk.l2.rawValue))
            let record = try await host.open(spec: spec)
            persistOpened(record, command: command, risk: tool.risk, sandboxed: spec.sandbox != nil)
            if arguments["background"] as? Bool == true { return try encode(["ok": true, "terminalID": record.id, "pid": record.pid as Any, "state": record.state.rawValue]) }
            return try await waitForCompletion(record: record, command: command, timeoutMilliseconds: arguments["timeoutMs"] as? Int ?? tool.timeoutMilliseconds)
        case "terminal.read":
            let terminalID = id ?? sessionID
            let chunks = try await host.read(terminalID: terminalID, afterSequence: arguments["afterSequence"] as? Int ?? -1, maxBytes: arguments["maxBytes"] as? Int ?? tool.maxOutputBytes)
            return String(decoding: try JSONEncoder().encode(chunks), as: UTF8.self)
        case "terminal.write":
            guard let input = arguments["data"] as? String else { throw TerminalRuntimeError.invalidArguments }
            try await host.write(terminalID: id ?? sessionID, data: Data(input.utf8))
            return try encode(["ok": true, "terminalID": id ?? sessionID])
        case "terminal.resize":
            try await host.resize(terminalID: id ?? sessionID, columns: arguments["columns"] as? Int ?? 120, rows: arguments["rows"] as? Int ?? 30)
            return try encode(["ok": true, "terminalID": id ?? sessionID])
        case "terminal.signal":
            guard let raw = arguments["signal"] as? String, let signal = TerminalSignal(rawValue: raw) else { throw TerminalRuntimeError.invalidArguments }
            try await host.signal(terminalID: id ?? sessionID, signal: signal)
            return try encode(["ok": true, "terminalID": id ?? sessionID])
        case "terminal.attach":
            let receipt = try await host.attach(terminalID: id ?? sessionID)
            return String(decoding: try JSONEncoder().encode(receipt), as: UTF8.self)
        case "terminal.ports":
            let chunks = try await host.read(terminalID: id ?? sessionID, afterSequence: -1, maxBytes: tool.maxOutputBytes)
            return try encode(["ok": true, "terminalID": id ?? sessionID, "ports": TerminalPortDetector.ports(in: chunks.map(\.text).joined())])
        case "terminal.close":
            try await host.close(terminalID: id ?? sessionID)
            return try encode(["ok": true, "terminalID": id ?? sessionID])
        default:
            throw TerminalRuntimeError.invalidArguments
        }
    }

    public func cancel(invocationID: String) async {}

    private func enforceManifest(effect: ToolEffect, cwd: String, command: String?) throws {
        guard let manifest else { return }
        guard manifest.allows(effect: effect, path: cwd) else { throw HostCapabilityError.denied }
        if let command, ShellIntentAnalyzer.analyze(command).accessesNetwork,
           !manifest.allows(effect: .network) {
            throw HostCapabilityError.denied
        }
    }

    private func sandboxPolicy(sessionID: String, cwd: String, allowsNetwork: Bool) -> SandboxLaunchPolicy? {
        guard let sandboxRoot, let sandboxScratchRoot,
              SandboxRuntime.availability.available else { return nil }
        let root = URL(fileURLWithPath: sandboxRoot, isDirectory: true).resolvingSymlinksInPath().standardizedFileURL
        let candidate = URL(fileURLWithPath: cwd, isDirectory: true).standardizedFileURL
        guard candidate.path == root.path || candidate.path.hasPrefix(root.path + "/") else { return nil }
        let scratch = URL(fileURLWithPath: sandboxScratchRoot, isDirectory: true).appendingPathComponent(sessionID, isDirectory: true)
        return SandboxLaunchPolicy(sessionID: sessionID, workspacePath: root.path, scratchPath: scratch.path, allowsNetwork: allowsNetwork)
    }

    private func waitForCompletion(record: TerminalSessionRecord, command: String, timeoutMilliseconds: Int) async throws -> String {
        let deadline = Date().addingTimeInterval(TimeInterval(max(100, timeoutMilliseconds)) / 1_000)
        var sequence = -1
        var output = ""
        while Date() < deadline {
            let chunks = try await host.read(terminalID: record.id, afterSequence: sequence, maxBytes: 128_000)
            if let last = chunks.last { sequence = last.sequence; output += chunks.map(\.text).joined() }
            let receipt = try await host.attach(terminalID: record.id)
            if [.exited, .failed, .stopped].contains(receipt.state) {
                let hash = SHA256.hash(data: Data(output.utf8)).map { String(format: "%02x", $0) }.joined()
                let summary = TerminalOutputSummary(sessionID: record.sessionID, command: TerminalCommandSanitizer.storedValue(command) ?? "", exitCode: receipt.state == .exited ? 0 : nil, tail: SecretRedactor.redact(String(output.suffix(4_000))), ports: TerminalPortDetector.ports(in: output), outputHash: hash)
                persistCompletion(record, receipt: receipt, summary: summary)
                return String(decoding: try JSONEncoder().encode(summary), as: UTF8.self)
            }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        try? await host.signal(terminalID: record.id, signal: .terminate)
        try? repository?.append(sessionID: record.sessionID, type: "terminal_indeterminate", payload: ["terminalID": record.id, "detail": "Terminal 超时，未自动重放"])
        return try encode(["ok": false, "terminalID": record.id, "indeterminate": true, "message": "Terminal 超时，结果未知；请检查后台进程"])
    }

    private func persistOpened(_ record: TerminalSessionRecord, command: String?, risk: CommandRisk, sandboxed: Bool = false) {
        try? repository?.saveTerminalSession(record)
        let raw = command ?? ""
        let hash = SHA256.hash(data: Data(raw.utf8)).map { String(format: "%02x", $0) }.joined()
        try? repository?.saveTerminalProcess(TerminalProcessRecord(terminalID: record.id, pid: record.pid, processGroup: record.pid, commandHash: hash, cwd: record.cwd))
        if let command, !command.isEmpty {
            try? repository?.appendTerminalCommandHistory(TerminalCommandHistoryRecord(sessionID: record.sessionID, terminalID: record.id, command: command, risk: risk))
        }
        let event = TerminalAuditEvent(terminalID: record.id, sessionID: record.sessionID, kind: .started, detail: "pid \(record.pid.map(String.init) ?? "-")")
        try? repository?.appendTerminalEvent(event)
        try? repository?.append(sessionID: record.sessionID, type: "terminal_started", payload: ["terminalID": record.id, "detail": event.detail])
        if sandboxed {
            try? repository?.append(sessionID: record.sessionID, type: "sandbox_enforced", payload: ["terminalID": record.id, "workspace": record.cwd, "policy": "seatbelt-write-boundary"])
        }
    }

    private func persistCompletion(_ record: TerminalSessionRecord, receipt: TerminalAttachReceipt, summary: TerminalOutputSummary) {
        let completed = TerminalSessionRecord(
            id: record.id,
            sessionID: record.sessionID,
            target: record.target,
            cwd: record.cwd,
            command: record.command,
            pid: record.pid,
            state: receipt.state,
            columns: record.columns,
            rows: record.rows,
            startedAt: record.startedAt,
            endedAt: Date(),
            exitCode: summary.exitCode,
            outputHash: summary.outputHash,
            portIDs: summary.ports.map(String.init)
        )
        try? repository?.saveTerminalSession(completed)
        let kind: TerminalEventKind = receipt.state == .exited ? .completed : .failed
        let event = TerminalAuditEvent(terminalID: record.id, sessionID: record.sessionID, kind: kind, detail: "exit \(summary.exitCode.map(String.init) ?? "unknown")")
        try? repository?.appendTerminalEvent(event)
        try? repository?.append(sessionID: record.sessionID, type: "terminal_\(kind.rawValue)", payload: ["terminalID": record.id, "detail": event.detail])
        for port in summary.ports {
            let record = TerminalPortRecord(terminalID: completed.id, port: port)
            try? repository?.saveTerminalPort(record)
            try? repository?.append(sessionID: completed.sessionID, type: "terminal_portDiscovered", payload: ["terminalID": completed.id, "detail": "localhost:\(port)"])
        }
    }

    private func encode(_ value: Any) throws -> String {
        guard JSONSerialization.isValidJSONObject(value) else {
            throw TerminalRuntimeError.invalidArguments
        }
        return String(decoding: try JSONSerialization.data(withJSONObject: value), as: UTF8.self)
    }
}
