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

public protocol DurableSessionSupervisor: Sendable {
    func admit(_ input: SessionInput) async throws -> AdmissionReceipt
    func start(sessionID: String) async throws
    func pause(sessionID: String) async throws
    func resume(sessionID: String) async throws
    func resolveApproval(sessionID: String, approvalID: String, decision: ApprovalDecision) async throws
    func cancel(sessionID: String) async throws
    func recover(sessionID: String) async throws -> RecoveryResult
    func evaluateDelivery(sessionID: String) async throws -> DeliveryGateResult
}

public enum HarnessSupervisorError: LocalizedError, Sendable {
    case sessionNotFound
    case executionDriverUnavailable
    case approvalNotFound
    case approvalSessionMismatch
    case approvalAlreadyResolved
    case missingTaskContract

    public var errorDescription: String? {
        switch self {
        case .sessionNotFound: "找不到目标 Session"
        case .executionDriverUnavailable: "当前 Session 没有可用的执行驱动"
        case .approvalNotFound: "找不到待处理审批"
        case .approvalSessionMismatch: "审批不属于当前 Session"
        case .approvalAlreadyResolved: "该审批已经处理过"
        case .missingTaskContract: "当前 Session 没有任务合同"
        }
    }
}
