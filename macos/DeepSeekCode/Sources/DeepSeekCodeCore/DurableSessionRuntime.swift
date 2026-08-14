import Foundation

public enum SessionInputDelivery: String, Codable, CaseIterable, Sendable {
    case immediate
    case nextStep = "next_step"
    case deferred
    case contextOnly = "context_only"
}

public enum SessionInputState: String, Codable, CaseIterable, Sendable {
    case accepted
    case promoted
    case consumed
    case cancelled
}

public struct SessionInputRecord: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let sessionID: String
    public let idempotencyKey: String
    public let admittedSequence: Int
    public let delivery: SessionInputDelivery
    public var state: SessionInputState
    public let parts: [ContentPart]
    public let createdAt: Date
    public var updatedAt: Date

    public init(
        id: String = UUID().uuidString,
        sessionID: String,
        idempotencyKey: String,
        admittedSequence: Int,
        delivery: SessionInputDelivery,
        state: SessionInputState = .accepted,
        parts: [ContentPart],
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.sessionID = sessionID
        self.idempotencyKey = idempotencyKey
        self.admittedSequence = admittedSequence
        self.delivery = delivery
        self.state = state
        self.parts = parts
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

/// Inputs claimed at one persisted safe boundary. Context-only records never
/// wake an Agent by themselves; they are delivered alongside the next primary
/// message so a running session cannot lose steering constraints.
public struct SessionInputBoundary: Codable, Equatable, Sendable {
    public let primary: SessionInputRecord
    public let context: [SessionInputRecord]

    public init(primary: SessionInputRecord, context: [SessionInputRecord]) {
        self.primary = primary
        self.context = context.sorted { $0.admittedSequence < $1.admittedSequence }
    }
}

public struct SessionLease: Codable, Equatable, Sendable {
    public let sessionID: String
    public let ownerInstanceID: String
    public let heartbeat: Date
    public let expiresAt: Date

    public init(sessionID: String, ownerInstanceID: String, heartbeat: Date, expiresAt: Date) {
        self.sessionID = sessionID
        self.ownerInstanceID = ownerInstanceID
        self.heartbeat = heartbeat
        self.expiresAt = expiresAt
    }

    public func isActive(at date: Date = Date()) -> Bool {
        expiresAt > date
    }
}

public enum SessionLeaseError: LocalizedError, Sendable {
    case heldByAnotherOwner
    case notOwner

    public var errorDescription: String? {
        switch self {
        case .heldByAnotherOwner: "该 Session 正由另一个本地实例处理"
        case .notOwner: "当前实例不拥有该 Session 的执行租约"
        }
    }
}

public struct SessionProjectionSnapshot: Codable, Equatable, Sendable {
    public let sessionID: String
    public let cursorSequence: Int
    public let payload: Data
    public let updatedAt: Date

    public init(sessionID: String, cursorSequence: Int, payload: Data, updatedAt: Date = Date()) {
        self.sessionID = sessionID
        self.cursorSequence = cursorSequence
        self.payload = payload
        self.updatedAt = updatedAt
    }
}

/// Render-ready cache for a session's part-first timeline. It is always
/// rebuildable from `session_event_log`, which remains the only business
/// source of truth.
public struct SessionPartProjectionSnapshot: Codable, Equatable, Sendable {
    public let sessionID: String
    public let cursorSequence: Int
    public let parts: [SessionPart]
    public let updatedAt: Date

    public init(
        sessionID: String,
        cursorSequence: Int,
        parts: [SessionPart],
        updatedAt: Date = Date()
    ) {
        self.sessionID = sessionID
        self.cursorSequence = cursorSequence
        self.parts = parts
        self.updatedAt = updatedAt
    }
}
