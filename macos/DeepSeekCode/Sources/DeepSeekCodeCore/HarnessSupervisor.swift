import Foundation

/// A narrow execution seam owned by the durable Supervisor. The concrete
/// model/tool adapter is intentionally kept behind this protocol so UI and
/// Control Plane code cannot start or resume an Agent directly.
public protocol SessionExecutionDriver: Sendable {
    func start(sessionID: String) async throws
    func pause(sessionID: String) async throws
    func resume(sessionID: String) async throws
    func resolveApproval(sessionID: String, approvalID: String, decision: ApprovalDecision) async throws
    func cancel(sessionID: String) async throws
}

public struct SessionInput: Codable, Equatable, Sendable {
    public let id: String
    public let sessionID: String
    public let idempotencyKey: String
    public let delivery: SessionInputDelivery
    public let parts: [ContentPart]

    public init(
        id: String = UUID().uuidString,
        sessionID: String,
        idempotencyKey: String,
        delivery: SessionInputDelivery = .deferred,
        parts: [ContentPart]
    ) {
        self.id = id
        self.sessionID = sessionID
        self.idempotencyKey = idempotencyKey
        self.delivery = delivery
        self.parts = parts
    }
}

public struct AdmissionReceipt: Codable, Equatable, Sendable {
    public let inputID: String
    public let sessionID: String
    public let idempotencyKey: String
    public let commandID: String
    public let admittedSequence: Int

    public init(inputID: String, sessionID: String, idempotencyKey: String, commandID: String, admittedSequence: Int) {
        self.inputID = inputID
        self.sessionID = sessionID
        self.idempotencyKey = idempotencyKey
        self.commandID = commandID
        self.admittedSequence = admittedSequence
    }
}

public struct RecoveryResult: Codable, Equatable, Sendable {
    public let sessionID: String
    public let projectedState: ProjectedSessionState?
    public let indeterminateEventIDs: [String]
    public let needsAttention: Bool

    public init(sessionID: String, projectedState: ProjectedSessionState?, indeterminateEventIDs: [String], needsAttention: Bool) {
        self.sessionID = sessionID
        self.projectedState = projectedState
        self.indeterminateEventIDs = indeterminateEventIDs
        self.needsAttention = needsAttention
    }
}

/// A versioned, Supervisor-owned mutation request used by thin GUI/CLI
/// clients for durable projections that are not part of a model turn (for
/// example a user-attached terminal or a worktree handoff).  The transport
/// never receives repository access: deepseekd forwards this request to the
/// single SessionSupervisor actor.
public enum SessionRuntimeMutationKind: String, Codable, Sendable {
    case event
    case createHandoff
    case saveHandoffFiles
    case updateHandoff
    case saveTerminalSession
    case saveTerminalProcess
    case saveTerminalPort
    case appendTerminalEvent
    case appendTerminalHistory
    case updateWorktreeBinding
    case saveWorktree
}

public struct SessionRuntimeMutation: Codable, Equatable, Sendable {
    public let kind: SessionRuntimeMutationKind
    public let sessionID: String
    public let commandID: String
    /// Canonical JSON for the explicitly selected mutation kind. Keeping the
    /// payload opaque at the IPC boundary avoids exposing repository types to
    /// UI clients while still allowing each mutation to be schema checked by
    /// the Supervisor.
    public let payloadJSON: String

    public init(kind: SessionRuntimeMutationKind, sessionID: String, commandID: String = UUID().uuidString, payloadJSON: String) {
        self.kind = kind
        self.sessionID = sessionID
        self.commandID = commandID
        self.payloadJSON = payloadJSON
    }
}

/// Creation input accepted only by the durable Supervisor. The GUI/CLI may
/// prepare a local Worktree path, but only this Runtime transition creates the
/// Project/Session/TaskContract records and their audit events.
public struct SessionCreationRequest: Codable, Equatable, Sendable {
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

public protocol DurableSessionSupervisor: Sendable {
    func createSession(_ request: SessionCreationRequest, commandID: String) async throws -> StoredSession
    func admit(_ input: SessionInput) async throws -> AdmissionReceipt
    func start(sessionID: String) async throws
    func pause(sessionID: String) async throws
    func resume(sessionID: String) async throws
    func requestApproval(sessionID: String, tool: String, risk: CommandRisk, arguments: String, commandID: String) async throws -> ApprovalRecord
    func resolveApproval(sessionID: String, approvalID: String, decision: ApprovalDecision) async throws
    func adoptWorkerResult(sessionID: String, workerSessionID: String) async throws
    func cancel(sessionID: String) async throws
    func recover(sessionID: String) async throws -> RecoveryResult
    func evaluateDelivery(sessionID: String) async throws -> DeliveryGateResult
    func applyRuntimeMutation(_ mutation: SessionRuntimeMutation) async throws -> String
    func recordRuntimeEvent(sessionID: String, type: String, payload: [String: String], commandID: String, causationID: String?, correlationID: String?) async throws
    func persistRunState(_ state: AgentRunState) async throws
    func consumeDirectTerminalApproval(sessionID: String, approvalID: String?, risk: CommandRisk, commandHash: String) async throws -> Bool
}

public enum HarnessSupervisorError: LocalizedError, Sendable {
    case sessionNotFound
    case executionDriverUnavailable
    case approvalNotFound
    case approvalSessionMismatch
    case approvalAlreadyResolved
    case missingTaskContract
    case workerSessionMismatch
    case workerResultUnavailable
    case commandExpired
    case inputNotPromotable

    public var errorDescription: String? {
        switch self {
        case .sessionNotFound: "找不到目标 Session"
        case .executionDriverUnavailable: "当前 Session 没有可用的执行驱动"
        case .approvalNotFound: "找不到待处理审批"
        case .approvalSessionMismatch: "审批不属于当前 Session"
        case .approvalAlreadyResolved: "该审批已经处理过"
        case .missingTaskContract: "当前 Session 没有任务合同"
        case .workerSessionMismatch: "Worker 不属于当前 Session"
        case .workerResultUnavailable: "Worker 尚未产生可采纳结果"
        case .commandExpired: "命令已过期，未执行"
        case .inputNotPromotable: "输入尚未到达可提升的安全边界"
        }
    }
}
