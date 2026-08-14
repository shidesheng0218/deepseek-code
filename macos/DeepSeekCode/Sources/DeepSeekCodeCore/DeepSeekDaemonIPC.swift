import CryptoKit
import Foundation

/// Versioned, local-only command protocol shared by the macOS App, the CLI
/// and the standalone `deepseekd` process. Requests are intentionally small:
/// state changes are commands to the Supervisor, never raw SQL mutations.
public enum DeepSeekDaemonProtocol {
    public static let version = 1
}

public enum DeepSeekDaemonMethod: String, Codable, CaseIterable, Sendable {
    case handshake
    case sessionCreate = "session.create"
    case sessionList = "session.list"
    case sessionAttach = "session.attach"
    case sessionEvents = "session.events"
    case sessionStart = "session.start"
    case sessionPause = "session.pause"
    case sessionResume = "session.resume"
    case sessionCancel = "session.cancel"
    case approvalRequest = "approval.request"
    case approvalResolve = "approval.resolve"
    case inputAdmit = "input.admit"
    case sessionRecover = "session.recover"
    case deliveryEvaluate = "delivery.evaluate"
    case workerCreate = "worker.create"
    case workerList = "worker.list"
    case workerStart = "worker.start"
    case workerCancel = "worker.cancel"
    case workerCollect = "worker.collect"
    case workerAdopt = "worker.adopt"
    case terminalOpen = "terminal.open"
    case terminalExec = "terminal.exec"
    case terminalList = "terminal.list"
    case terminalAttach = "terminal.attach"
    case terminalRead = "terminal.read"
    case terminalWrite = "terminal.write"
    case terminalResize = "terminal.resize"
    case terminalSignal = "terminal.signal"
    case terminalPorts = "terminal.ports"
    case terminalClose = "terminal.close"
}

public struct DeepSeekDaemonRequest: Codable, Equatable, Sendable {
    public let protocolVersion: Int
    public let id: String
    public let token: String
    public let method: DeepSeekDaemonMethod
    public let payload: String

    public init(
        protocolVersion: Int = DeepSeekDaemonProtocol.version,
        id: String = UUID().uuidString,
        token: String = "",
        method: DeepSeekDaemonMethod,
        payload: String = "{}"
    ) {
        self.protocolVersion = protocolVersion
        self.id = id
        self.token = token
        self.method = method
        self.payload = payload
    }
}

public struct DeepSeekDaemonResponse: Codable, Equatable, Sendable {
    public let protocolVersion: Int
    public let id: String
    public let ok: Bool
    public let output: String
    public let code: String?
    public let indeterminate: Bool

    public init(
        protocolVersion: Int = DeepSeekDaemonProtocol.version,
        id: String,
        ok: Bool,
        output: String,
        code: String? = nil,
        indeterminate: Bool = false
    ) {
        self.protocolVersion = protocolVersion
        self.id = id
        self.ok = ok
        self.output = output
        self.code = code
        self.indeterminate = indeterminate
    }
}

public struct DeepSeekDaemonHandshake: Codable, Equatable, Sendable {
    public let protocolVersion: Int
    public let instanceID: String
    public let startedAt: Date

    public init(protocolVersion: Int = DeepSeekDaemonProtocol.version, instanceID: String, startedAt: Date) {
        self.protocolVersion = protocolVersion
        self.instanceID = instanceID
        self.startedAt = startedAt
    }
}

public struct DeepSeekDaemonSessionSummary: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let projectID: String
    public let title: String
    public let status: SessionStatus
    public let target: SessionTarget
    public let updatedAt: Date

    public init(session: StoredSession) {
        id = session.id
        projectID = session.projectID
        title = session.title
        status = session.status
        target = session.target
        updatedAt = session.updatedAt
    }
}

public struct DeepSeekDaemonSessionPayload: Codable, Equatable, Sendable {
    public let sessionID: String

    public init(sessionID: String) {
        self.sessionID = sessionID
    }
}

public struct DeepSeekDaemonCreateSessionPayload: Codable, Equatable, Sendable {
    public let projectPath: String
    public let projectName: String?
    public let title: String
    public let mode: AgentMode
    public let target: SessionTarget
    public let branch: String
    public let worktreePath: String?
    public let baselineRevision: String?
    public let budget: SessionBudget

    public init(
        projectPath: String,
        projectName: String? = nil,
        title: String,
        mode: AgentMode = .acceptEdits,
        target: SessionTarget = .local,
        branch: String = "",
        worktreePath: String? = nil,
        baselineRevision: String? = nil,
        budget: SessionBudget = SessionBudget()
    ) {
        self.projectPath = projectPath
        self.projectName = projectName
        self.title = title
        self.mode = mode
        self.target = target
        self.branch = branch
        self.worktreePath = worktreePath
        self.baselineRevision = baselineRevision
        self.budget = budget
    }
}

public struct DeepSeekDaemonEventsPayload: Codable, Equatable, Sendable {
    public let sessionID: String
    public let afterSequence: Int

    public init(sessionID: String, afterSequence: Int = 0) {
        self.sessionID = sessionID
        self.afterSequence = max(0, afterSequence)
    }
}

public struct DeepSeekDaemonInputPayload: Codable, Equatable, Sendable {
    public let sessionID: String
    public let idempotencyKey: String
    public let delivery: SessionInputDelivery
    public let parts: [ContentPart]

    public init(sessionID: String, idempotencyKey: String, delivery: SessionInputDelivery, parts: [ContentPart]) {
        self.sessionID = sessionID
        self.idempotencyKey = idempotencyKey
        self.delivery = delivery
        self.parts = parts
    }
}

public struct DeepSeekDaemonApprovalPayload: Codable, Equatable, Sendable {
    public let sessionID: String
    public let approvalID: String
    public let decision: ApprovalDecision

    public init(sessionID: String, approvalID: String, decision: ApprovalDecision) {
        self.sessionID = sessionID
        self.approvalID = approvalID
        self.decision = decision
    }
}

/// Generic, idempotent approval creation request. The client never writes an
/// approval row; deepseekd forwards this to SessionSupervisor and returns the
/// persisted record required for the UI's approval sheet.
public struct DeepSeekDaemonApprovalRequestPayload: Codable, Equatable, Sendable {
    public let sessionID: String
    public let tool: String
    public let risk: CommandRisk
    public let arguments: String
    public let idempotencyKey: String

    public init(
        sessionID: String,
        tool: String,
        risk: CommandRisk,
        arguments: String,
        idempotencyKey: String
    ) {
        self.sessionID = sessionID
        self.tool = tool
        self.risk = risk
        self.arguments = arguments
        self.idempotencyKey = idempotencyKey
    }
}

public struct DeepSeekDaemonWorkerCreatePayload: Codable, Equatable, Sendable {
    public let parentSessionID: String
    public let workerID: String
    public let workerKind: AgentWorkerKind
    public let objective: String
    public let maxOutputBytes: Int
    public let budget: SessionBudget

    public init(
        parentSessionID: String,
        workerID: String = UUID().uuidString,
        workerKind: AgentWorkerKind,
        objective: String,
        maxOutputBytes: Int = 128_000,
        budget: SessionBudget = SessionBudget()
    ) {
        self.parentSessionID = parentSessionID
        self.workerID = workerID
        self.workerKind = workerKind
        self.objective = objective
        self.maxOutputBytes = maxOutputBytes
        self.budget = budget
    }
}

public struct DeepSeekDaemonWorkerPayload: Codable, Equatable, Sendable {
    public let workerSessionID: String

    public init(workerSessionID: String) {
        self.workerSessionID = workerSessionID
    }
}

/// A direct Terminal request comes from a paired local client (GUI or CLI),
/// never from the model. The daemon resolves its workspace from the durable
/// Session instead of accepting an unrestricted working directory.
public struct DeepSeekDaemonTerminalOpenPayload: Codable, Equatable, Sendable {
    public let sessionID: String
    public let cwd: String?
    public let command: String?
    public let columns: Int
    public let rows: Int
    public let background: Bool

    public init(
        sessionID: String,
        cwd: String? = nil,
        command: String? = nil,
        columns: Int = 120,
        rows: Int = 30,
        background: Bool = false
    ) {
        self.sessionID = sessionID
        self.cwd = cwd
        self.command = command
        self.columns = max(1, columns)
        self.rows = max(1, rows)
        self.background = background
    }
}

public struct DeepSeekDaemonTerminalExecPayload: Codable, Equatable, Sendable {
    public let sessionID: String
    public let command: String
    public let cwd: String?
    public let columns: Int
    public let rows: Int
    public let background: Bool
    public let timeoutMilliseconds: Int
    /// For L2/L3 commands, the caller resolves the durable approval and then
    /// retries the exact command with this one-time approval ID.
    public let approvalID: String?

    public init(
        sessionID: String,
        command: String,
        cwd: String? = nil,
        columns: Int = 120,
        rows: Int = 30,
        background: Bool = false,
        timeoutMilliseconds: Int = 120_000,
        approvalID: String? = nil
    ) {
        self.sessionID = sessionID
        self.command = command
        self.cwd = cwd
        self.columns = max(1, columns)
        self.rows = max(1, rows)
        self.background = background
        self.timeoutMilliseconds = max(100, timeoutMilliseconds)
        self.approvalID = approvalID
    }
}

public struct DeepSeekDaemonTerminalIDPayload: Codable, Equatable, Sendable {
    public let terminalID: String

    public init(terminalID: String) {
        self.terminalID = terminalID
    }
}

public struct DeepSeekDaemonTerminalReadPayload: Codable, Equatable, Sendable {
    public let terminalID: String
    public let afterSequence: Int
    public let maxBytes: Int

    public init(terminalID: String, afterSequence: Int = -1, maxBytes: Int = 64_000) {
        self.terminalID = terminalID
        self.afterSequence = max(-1, afterSequence)
        self.maxBytes = max(1_024, maxBytes)
    }
}

public struct DeepSeekDaemonTerminalWritePayload: Codable, Equatable, Sendable {
    public let terminalID: String
    public let data: String
    public let protectedInput: Bool

    public init(terminalID: String, data: String, protectedInput: Bool = false) {
        self.terminalID = terminalID
        self.data = data
        self.protectedInput = protectedInput
    }
}

public struct DeepSeekDaemonTerminalResizePayload: Codable, Equatable, Sendable {
    public let terminalID: String
    public let columns: Int
    public let rows: Int

    public init(terminalID: String, columns: Int, rows: Int) {
        self.terminalID = terminalID
        self.columns = max(1, columns)
        self.rows = max(1, rows)
    }
}

public struct DeepSeekDaemonTerminalSignalPayload: Codable, Equatable, Sendable {
    public let terminalID: String
    public let signal: TerminalSignal

    public init(terminalID: String, signal: TerminalSignal) {
        self.terminalID = terminalID
        self.signal = signal
    }
}

public struct DeepSeekDaemonTerminalApprovalRequired: Codable, Equatable, Sendable {
    public let approvalID: String
    public let risk: CommandRisk
    public let message: String

    public init(approvalID: String, risk: CommandRisk, message: String) {
        self.approvalID = approvalID
        self.risk = risk
        self.message = message
    }
}

public enum DeepSeekDaemonTerminalError: LocalizedError, Sendable {
    case unavailable
    case sessionNotFound
    case unsupportedTarget
    case approvalRequired
    case approvalInvalid
    case permanentlyBlocked

    public var errorDescription: String? {
        switch self {
        case .unavailable: "deepseekd 的 Persistent Terminal Helper 不可用"
        case .sessionNotFound: "找不到 Terminal 对应的 Session"
        case .unsupportedTarget: "当前 deepseekd 只支持 Local 和 Worktree Persistent Terminal；SSH 必须使用已配置的远程 Helper"
        case .approvalRequired: "此终端命令需要用户确认"
        case .approvalInvalid: "终端确认无效、已过期，或与当前命令不匹配"
        case .permanentlyBlocked: "L4 终端命令被永久阻止"
        }
    }
}

public enum DeepSeekDaemonJSON {
    public static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return encoder
    }

    public static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }
}

/// The daemon command router is intentionally usable without a socket. That
/// keeps the durable command semantics testable and lets the Unix-socket
/// server remain a thin authenticated transport layer.
public actor DeepSeekDaemonCommandRouter {
    private let repository: SessionRepository
    private let supervisor: any DurableSessionSupervisor
    private let harness: LocalHarnessDaemon
    private let instanceID: String
    private let startedAt: Date
    private let workerRuntime: (any ChildAgentRuntime)?
    private let terminalHost: (any PersistentTerminalHost)?

    public init(
        repository: SessionRepository,
        supervisor: any DurableSessionSupervisor,
        workerRuntime: (any ChildAgentRuntime)? = nil,
        terminalHost: (any PersistentTerminalHost)? = nil,
        instanceID: String = "deepseekd-\(UUID().uuidString)",
        startedAt: Date = Date()
    ) {
        self.repository = repository
        self.supervisor = supervisor
        harness = LocalHarnessDaemon(repository: repository, supervisor: supervisor)
        self.workerRuntime = workerRuntime
        self.terminalHost = terminalHost
        self.instanceID = instanceID
        self.startedAt = startedAt
    }

    public func handle(_ request: DeepSeekDaemonRequest) async -> DeepSeekDaemonResponse {
        guard request.protocolVersion == DeepSeekDaemonProtocol.version else {
            return DeepSeekDaemonResponse(
                id: request.id,
                ok: false,
                output: "Daemon 协议版本不兼容",
                code: "PROTOCOL_VERSION_MISMATCH"
            )
        }
        do {
            switch request.method {
            case .handshake:
                return try response(request.id, DeepSeekDaemonHandshake(instanceID: instanceID, startedAt: startedAt))
            case .sessionCreate:
                let payload = try decode(DeepSeekDaemonCreateSessionPayload.self, from: request.payload)
                let path = URL(fileURLWithPath: payload.projectPath, isDirectory: true).standardizedFileURL.path
                let projectName = payload.projectName?.trimmingCharacters(in: .whitespacesAndNewlines)
                let project = try repository.project(path: path)
                    ?? repository.createProject(
                        name: (projectName?.isEmpty == false ? projectName! : URL(fileURLWithPath: path).lastPathComponent),
                        path: path
                    )
                let branch = payload.branch.isEmpty
                    ? (payload.target == .local ? "main" : "deepseek/\(branchSlug(payload.title))")
                    : payload.branch
                let session = try repository.createSession(
                    projectID: project.id,
                    title: payload.title,
                    mode: payload.mode,
                    target: payload.target,
                    branch: branch,
                    worktreePath: payload.worktreePath,
                    baselineRevision: payload.baselineRevision
                )
                let contract = TaskContract.compatibility(prompt: payload.title, budget: payload.budget)
                try repository.saveTaskContract(contract, sessionID: session.id)
                _ = try SessionEventCommitter(repository: repository).commit(SessionEventDraft(
                    aggregateID: session.id,
                    commandID: "session-create-contract-\(session.id)",
                    causationID: request.id,
                    correlationID: request.id,
                    kind: SessionEventKind(rawValue: "task_contract_created"),
                    payload: [
                        "goal": contract.goal,
                        "requiredChanges": "\(contract.requiredChanges.count)",
                        "requiredTests": "\(contract.requiredTests.count)"
                    ]
                ))
                if payload.target == .worktree,
                   let worktreePath = payload.worktreePath,
                   let baselineRevision = payload.baselineRevision {
                    try repository.saveWorktree(WorktreeRecord(
                        sessionID: session.id,
                        baseRevision: baselineRevision,
                        branch: branch,
                        worktreePath: worktreePath
                    ))
                }
                return try response(request.id, session)
            case .sessionList:
                let sessions = try repository.sessions().filter { !$0.archived }.map(DeepSeekDaemonSessionSummary.init(session:))
                return try response(request.id, sessions)
            case .sessionAttach:
                let payload = try decode(DeepSeekDaemonSessionPayload.self, from: request.payload)
                return try response(request.id, try await harness.attachSession(payload.sessionID))
            case .sessionEvents:
                let payload = try decode(DeepSeekDaemonEventsPayload.self, from: request.payload)
                let events = try repository.events(sessionID: payload.sessionID).filter { $0.sequence > payload.afterSequence }
                return try response(request.id, events)
            case .sessionStart:
                let payload = try decode(DeepSeekDaemonSessionPayload.self, from: request.payload)
                try SessionRuntimeOwnership.assign(
                    .daemon,
                    sessionID: payload.sessionID,
                    repository: repository,
                    instanceID: instanceID,
                    commandID: "runtime-owner-deepseekd-\(payload.sessionID)-\(UUID().uuidString)"
                )
                try await harness.startSession(payload.sessionID)
                return DeepSeekDaemonResponse(id: request.id, ok: true, output: "{}")
            case .sessionPause:
                let payload = try decode(DeepSeekDaemonSessionPayload.self, from: request.payload)
                try await harness.pauseSession(payload.sessionID)
                return DeepSeekDaemonResponse(id: request.id, ok: true, output: "{}")
            case .sessionResume:
                let payload = try decode(DeepSeekDaemonSessionPayload.self, from: request.payload)
                try await harness.resumeSession(payload.sessionID)
                return DeepSeekDaemonResponse(id: request.id, ok: true, output: "{}")
            case .sessionCancel:
                let payload = try decode(DeepSeekDaemonSessionPayload.self, from: request.payload)
                try await harness.cancelSession(payload.sessionID)
                return DeepSeekDaemonResponse(id: request.id, ok: true, output: "{}")
            case .approvalRequest:
                let payload = try decode(DeepSeekDaemonApprovalRequestPayload.self, from: request.payload)
                let approval = try await supervisor.requestApproval(
                    sessionID: payload.sessionID,
                    tool: payload.tool,
                    risk: payload.risk,
                    arguments: payload.arguments,
                    commandID: "daemon-approval-request-\(payload.idempotencyKey)"
                )
                return try response(request.id, approval)
            case .approvalResolve:
                let payload = try decode(DeepSeekDaemonApprovalPayload.self, from: request.payload)
                if try isDirectTerminalApproval(approvalID: payload.approvalID, sessionID: payload.sessionID) {
                    guard payload.decision != .pending else { throw DeepSeekDaemonTerminalError.approvalInvalid }
                    // Direct Terminal approvals still use the same Supervisor
                    // CAS and continuation boundary as Agent approvals. The
                    // Router only identifies the direct-terminal contract;
                    // it never changes approval state or appends a parallel
                    // resolution event.
                    try await supervisor.resolveApproval(
                        sessionID: payload.sessionID,
                        approvalID: payload.approvalID,
                        decision: payload.decision
                    )
                } else {
                    try await harness.resolveApproval(sessionID: payload.sessionID, approvalID: payload.approvalID, decision: payload.decision)
                }
                return DeepSeekDaemonResponse(id: request.id, ok: true, output: "{}")
            case .inputAdmit:
                let payload = try decode(DeepSeekDaemonInputPayload.self, from: request.payload)
                let receipt = try await supervisor.admit(SessionInput(
                    sessionID: payload.sessionID,
                    idempotencyKey: payload.idempotencyKey,
                    delivery: payload.delivery,
                    parts: payload.parts
                ))
                return try response(request.id, receipt)
            case .sessionRecover:
                let payload = try decode(DeepSeekDaemonSessionPayload.self, from: request.payload)
                return try response(request.id, try await supervisor.recover(sessionID: payload.sessionID))
            case .deliveryEvaluate:
                let payload = try decode(DeepSeekDaemonSessionPayload.self, from: request.payload)
                return try response(request.id, try await supervisor.evaluateDelivery(sessionID: payload.sessionID))
            case .workerCreate:
                guard let workerRuntime else { throw ChildAgentRuntimeError.failed("Worker Runtime 不可用") }
                let payload = try decode(DeepSeekDaemonWorkerCreatePayload.self, from: request.payload)
                guard payload.workerKind != .main else { throw WorkerSessionError.mainAgentCannotBeChild }
                let contract = WorkerSessionContract(
                    parentSessionID: payload.parentSessionID,
                    workerKind: payload.workerKind,
                    objective: payload.objective,
                    maxOutputBytes: payload.maxOutputBytes,
                    budget: payload.budget
                )
                return try response(request.id, try await workerRuntime.create(parentSessionID: payload.parentSessionID, workerID: payload.workerID, contract: contract))
            case .workerList:
                let payload = try decode(DeepSeekDaemonSessionPayload.self, from: request.payload)
                return try response(request.id, try repository.workerSessions(parentSessionID: payload.sessionID))
            case .workerStart:
                guard let workerRuntime else { throw ChildAgentRuntimeError.failed("Worker Runtime 不可用") }
                let payload = try decode(DeepSeekDaemonWorkerPayload.self, from: request.payload)
                try await workerRuntime.start(workerSessionID: payload.workerSessionID)
                return DeepSeekDaemonResponse(id: request.id, ok: true, output: "{}")
            case .workerCancel:
                guard let workerRuntime else { throw ChildAgentRuntimeError.failed("Worker Runtime 不可用") }
                let payload = try decode(DeepSeekDaemonWorkerPayload.self, from: request.payload)
                try await workerRuntime.cancel(workerSessionID: payload.workerSessionID)
                return DeepSeekDaemonResponse(id: request.id, ok: true, output: "{}")
            case .workerCollect:
                guard let workerRuntime else { throw ChildAgentRuntimeError.failed("Worker Runtime 不可用") }
                let payload = try decode(DeepSeekDaemonWorkerPayload.self, from: request.payload)
                return try response(request.id, try await workerRuntime.collect(workerSessionID: payload.workerSessionID))
            case .workerAdopt:
                let payload = try decode(DeepSeekDaemonWorkerPayload.self, from: request.payload)
                guard let worker = try repository.workerSession(id: payload.workerSessionID) else {
                    throw ChildAgentRuntimeError.notFound
                }
                try await supervisor.adoptWorkerResult(
                    sessionID: worker.parentSessionID,
                    workerSessionID: payload.workerSessionID
                )
                return DeepSeekDaemonResponse(id: request.id, ok: true, output: "{}")
            case .terminalOpen:
                let payload = try decode(DeepSeekDaemonTerminalOpenPayload.self, from: request.payload)
                let session = try terminalSession(payload.sessionID)
                let host = try terminalToolHost(for: session, cwd: payload.cwd)
                let tool = try terminalTool(named: "terminal.open")
                let arguments = try terminalJSON([
                    "cwd": resolvedTerminalCWD(session: session, requested: payload.cwd),
                    "command": payload.command as Any,
                    "columns": payload.columns,
                    "rows": payload.rows,
                    "background": payload.background
                ])
                let registry = ToolRegistry([tool])
                let router = ToolHostRouter(registry: registry)
                router.register(host: host, for: tool.name)
                let callID = UUID().uuidString
                let result = try await ToolExecutionPipeline(repository: repository, router: router).execute(
                    ToolInvocationContext(
                        sessionID: session.id,
                        commandID: "terminal-open-\(session.id)-\(callID)",
                        callID: callID,
                        tool: tool,
                        argumentsJSON: arguments,
                        projectID: session.projectID
                    )
                )
                return DeepSeekDaemonResponse(id: request.id, ok: true, output: result.output)
            case .terminalExec:
                let payload = try decode(DeepSeekDaemonTerminalExecPayload.self, from: request.payload)
                let session = try terminalSession(payload.sessionID)
                let risk = CommandPolicy.classify(payload.command)
                guard risk != .l4 else { throw DeepSeekDaemonTerminalError.permanentlyBlocked }
                let tool = try terminalTool(named: "terminal.exec", risk: risk)
                let arguments = try terminalJSON([
                    "command": payload.command,
                    "cwd": resolvedTerminalCWD(session: session, requested: payload.cwd),
                    "columns": payload.columns,
                    "rows": payload.rows,
                    "background": payload.background,
                    "timeoutMs": payload.timeoutMilliseconds
                ])
                let approvedDirectCommand = try directTerminalApprovalAllows(payload, risk: risk)
                if risk >= .l2, !approvedDirectCommand {
                    let hash = commandHash(payload.command)
                    let approval = try repository.createApproval(
                        sessionID: session.id,
                        tool: "terminal.exec",
                        risk: risk,
                        arguments: try terminalJSON([
                            "source": "deepseekd-direct-terminal",
                            "commandHash": hash,
                            "cwd": resolvedTerminalCWD(session: session, requested: payload.cwd),
                            "background": payload.background
                        ])
                    )
                    let router = ToolHostRouter(registry: ToolRegistry([tool]))
                    let pipeline = ToolExecutionPipeline(repository: repository, router: router)
                    let context = ToolInvocationContext(
                        sessionID: session.id,
                        commandID: "terminal-direct-\(session.id)-\(approval.id)",
                        callID: approval.id,
                        tool: tool,
                        argumentsJSON: arguments,
                        projectID: session.projectID
                    )
                    try pipeline.begin(context)
                    try pipeline.recordApprovalRequested(context, approvalID: approval.id)
                    _ = try SessionEventCommitter(repository: repository).commit(SessionEventDraft(
                        aggregateID: session.id,
                        commandID: "terminal-direct-request-\(approval.id)",
                        causationID: approval.id,
                        correlationID: context.traceID,
                        kind: SessionEventKind(rawValue: "terminal_requested"),
                        payload: ["approvalID": approval.id, "risk": "L\(risk.rawValue)", "commandHash": hash]
                    ))
                    return try response(
                        request.id,
                        DeepSeekDaemonTerminalApprovalRequired(
                            approvalID: approval.id,
                            risk: risk,
                            message: "终端命令需要 L\(risk.rawValue) 用户确认；运行 deepseek approve \(session.id) \(approval.id) 后重试原命令并传入 --approval \(approval.id)"
                        ),
                        ok: false,
                        code: "APPROVAL_REQUIRED"
                    )
                }
                let host = try terminalToolHost(for: session, cwd: payload.cwd)
                let registry = ToolRegistry([tool])
                let router = ToolHostRouter(registry: registry)
                router.register(host: host, for: tool.name)
                let callID = payload.approvalID ?? UUID().uuidString
                let context = ToolInvocationContext(
                    sessionID: session.id,
                    commandID: "terminal-direct-\(session.id)-\(callID)",
                    callID: callID,
                    tool: tool,
                    argumentsJSON: arguments,
                    projectID: session.projectID
                )
                let result = try await ToolExecutionPipeline(repository: repository, router: router).execute(context)
                return DeepSeekDaemonResponse(id: request.id, ok: true, output: result.output)
            case .terminalList:
                let payload = try decode(DeepSeekDaemonSessionPayload.self, from: request.payload)
                _ = try terminalSession(payload.sessionID)
                return try response(request.id, try repository.terminalSessions(sessionID: payload.sessionID))
            case .terminalAttach:
                let payload = try decode(DeepSeekDaemonTerminalIDPayload.self, from: request.payload)
                let host = try terminalHostOrThrow()
                return try response(request.id, try await host.attach(terminalID: payload.terminalID))
            case .terminalRead:
                let payload = try decode(DeepSeekDaemonTerminalReadPayload.self, from: request.payload)
                let host = try terminalHostOrThrow()
                return try response(request.id, try await host.read(terminalID: payload.terminalID, afterSequence: payload.afterSequence, maxBytes: payload.maxBytes))
            case .terminalWrite:
                let payload = try decode(DeepSeekDaemonTerminalWritePayload.self, from: request.payload)
                let host = try terminalHostOrThrow()
                if payload.protectedInput {
                    guard let interactive = host as? any PersistentTerminalInteractiveHost else { throw TerminalRuntimeError.protectedInputRequired }
                    try await interactive.writeProtectedInput(terminalID: payload.terminalID, data: Data(payload.data.utf8))
                } else {
                    try await host.write(terminalID: payload.terminalID, data: Data(payload.data.utf8))
                }
                return DeepSeekDaemonResponse(id: request.id, ok: true, output: "{}")
            case .terminalResize:
                let payload = try decode(DeepSeekDaemonTerminalResizePayload.self, from: request.payload)
                let host = try terminalHostOrThrow()
                try await host.resize(terminalID: payload.terminalID, columns: payload.columns, rows: payload.rows)
                return DeepSeekDaemonResponse(id: request.id, ok: true, output: "{}")
            case .terminalSignal:
                let payload = try decode(DeepSeekDaemonTerminalSignalPayload.self, from: request.payload)
                let host = try terminalHostOrThrow()
                try await host.signal(terminalID: payload.terminalID, signal: payload.signal)
                return DeepSeekDaemonResponse(id: request.id, ok: true, output: "{}")
            case .terminalPorts:
                let payload = try decode(DeepSeekDaemonTerminalIDPayload.self, from: request.payload)
                let host = try terminalHostOrThrow()
                let chunks = try await host.read(terminalID: payload.terminalID, afterSequence: -1, maxBytes: 128_000)
                return try response(request.id, TerminalPortDetector.ports(in: chunks.map(\.text).joined()))
            case .terminalClose:
                let payload = try decode(DeepSeekDaemonTerminalIDPayload.self, from: request.payload)
                let host = try terminalHostOrThrow()
                try await host.close(terminalID: payload.terminalID)
                return DeepSeekDaemonResponse(id: request.id, ok: true, output: "{}")
            }
        } catch {
            return failure(for: request, error: error)
        }
    }

    private func decode<T: Decodable>(_ type: T.Type, from payload: String) throws -> T {
        try DeepSeekDaemonJSON.decoder.decode(T.self, from: Data(payload.utf8))
    }

    private func response<T: Encodable>(_ requestID: String, _ value: T, ok: Bool = true, code: String? = nil) throws -> DeepSeekDaemonResponse {
        DeepSeekDaemonResponse(id: requestID, ok: ok, output: String(decoding: try DeepSeekDaemonJSON.encoder.encode(value), as: UTF8.self), code: code)
    }

    private func terminalSession(_ sessionID: String) throws -> StoredSession {
        guard let session = try repository.session(id: sessionID) else { throw DeepSeekDaemonTerminalError.sessionNotFound }
        guard session.target != .ssh else { throw DeepSeekDaemonTerminalError.unsupportedTarget }
        return session
    }

    private func terminalHostOrThrow() throws -> any PersistentTerminalHost {
        guard let terminalHost else { throw DeepSeekDaemonTerminalError.unavailable }
        return terminalHost
    }

    private func terminalToolHost(for session: StoredSession, cwd: String?) throws -> PersistentTerminalToolHost {
        let host = try terminalHostOrThrow()
        let workspace = resolvedTerminalCWD(session: session, requested: cwd)
        return PersistentTerminalToolHost(
            host: host,
            repository: repository,
            defaultCWD: workspace,
            sandboxRoot: workspace,
            sandboxScratchRoot: FileManager.default.temporaryDirectory
                .appendingPathComponent("DeepSeekCodeDaemonSandbox", isDirectory: true)
                .path,
            manifest: HostCapabilityManifest(
                hostID: "deepseekd.terminal.\(session.id)",
                allowedPaths: [workspace],
                allowedEffects: [.readOnly, .workspaceWrite, .process, .gitWrite, .network],
                allowedEnvironmentKeys: ["PATH", "HOME", "PWD", "TMPDIR"],
                maxOutputBytes: 128_000,
                timeoutMilliseconds: 120_000
            )
        )
    }

    private func terminalTool(named name: String, risk: CommandRisk? = nil) throws -> RegisteredTool {
        guard let base = AgentToolSchemas.registry.tool(named: name) else { throw DeepSeekDaemonTerminalError.unavailable }
        guard let risk else { return base }
        return RegisteredTool(
            name: base.name,
            description: base.description,
            parameters: base.parameters,
            effect: base.effect,
            risk: risk,
            timeoutMilliseconds: base.timeoutMilliseconds,
            maxOutputBytes: base.maxOutputBytes,
            idempotent: base.idempotent,
            supportsCancellation: base.supportsCancellation
        )
    }

    private func resolvedTerminalCWD(session: StoredSession, requested: String?) -> String {
        let fallback: String
        if let project = try? repository.project(id: session.projectID) {
            fallback = session.worktreePath ?? project.path
        } else {
            fallback = FileManager.default.currentDirectoryPath
        }
        guard let requested, !requested.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return fallback }
        let workspace = URL(fileURLWithPath: fallback, isDirectory: true).resolvingSymlinksInPath().standardizedFileURL
        let candidate = URL(fileURLWithPath: requested, isDirectory: true).resolvingSymlinksInPath().standardizedFileURL
        guard candidate.path == workspace.path || candidate.path.hasPrefix(workspace.path + "/") else { return fallback }
        return candidate.path
    }

    private func directTerminalApprovalAllows(_ payload: DeepSeekDaemonTerminalExecPayload, risk: CommandRisk) throws -> Bool {
        guard let approvalID = payload.approvalID else { return false }
        guard let approval = try repository.approval(id: approvalID),
              approval.sessionID == payload.sessionID,
              approval.tool == "terminal.exec",
              approval.risk == risk,
              approval.decision == .allowOnce || approval.decision == .allowSession,
              let data = approval.arguments.data(using: .utf8),
              let metadata = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              metadata["source"] as? String == "deepseekd-direct-terminal",
              metadata["commandHash"] as? String == commandHash(payload.command) else {
            if payload.approvalID != nil { throw DeepSeekDaemonTerminalError.approvalInvalid }
            return false
        }
        let consumed = try repository.events(sessionID: payload.sessionID).contains {
            $0.type == "terminal_approval_consumed" && $0.payload["approvalID"] == approvalID
        }
        guard !consumed else { throw DeepSeekDaemonTerminalError.approvalInvalid }
        if approval.decision == .allowOnce {
            _ = try repository.appendDurable(
                sessionID: payload.sessionID,
                type: "terminal_approval_consumed",
                payload: ["approvalID": approvalID, "decision": "allow_once"],
                commandID: "terminal-direct-consume-\(approvalID)",
                causationID: approvalID
            )
        }
        return true
    }

    private func isDirectTerminalApproval(approvalID: String, sessionID: String) throws -> Bool {
        guard let approval = try repository.approval(id: approvalID), approval.sessionID == sessionID,
              let data = approval.arguments.data(using: .utf8),
              let metadata = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        return approval.tool == "terminal.exec" && metadata["source"] as? String == "deepseekd-direct-terminal"
    }

    private func commandHash(_ command: String) -> String {
        SHA256.hash(data: Data(command.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func branchSlug(_ title: String) -> String {
        let normalized = title.lowercased().unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) ? Character(String(scalar)) : "-"
        }
        let compact = String(normalized).split(separator: "-", omittingEmptySubsequences: true).joined(separator: "-")
        return compact.isEmpty ? "session" : String(compact.prefix(48))
    }

    private func terminalJSON(_ value: [String: Any]) throws -> String {
        guard JSONSerialization.isValidJSONObject(value) else { throw UnifiedRuntimeError.invalidArguments }
        return String(decoding: try JSONSerialization.data(withJSONObject: value), as: UTF8.self)
    }

    private func failure(for request: DeepSeekDaemonRequest, error: Error) -> DeepSeekDaemonResponse {
        let code: String
        let indeterminate: Bool
        switch error {
        case HarnessSupervisorError.sessionNotFound:
            code = "SESSION_NOT_FOUND"
            indeterminate = false
        case HarnessSupervisorError.approvalNotFound, HarnessSupervisorError.approvalSessionMismatch, HarnessSupervisorError.approvalAlreadyResolved:
            code = "APPROVAL_INVALID"
            indeterminate = false
        case DeepSeekDaemonTerminalError.unavailable:
            code = "TERMINAL_UNAVAILABLE"
            indeterminate = false
        case DeepSeekDaemonTerminalError.unsupportedTarget:
            code = "TERMINAL_TARGET_UNSUPPORTED"
            indeterminate = false
        case DeepSeekDaemonTerminalError.approvalInvalid:
            code = "APPROVAL_INVALID"
            indeterminate = false
        case DeepSeekDaemonTerminalError.permanentlyBlocked:
            code = "POLICY_BLOCKED"
            indeterminate = false
        default:
            code = "COMMAND_FAILED"
            indeterminate = false
        }
        return DeepSeekDaemonResponse(
            id: request.id,
            ok: false,
            output: SecretRedactor.redact(error.localizedDescription),
            code: code,
            indeterminate: indeterminate
        )
    }
}
