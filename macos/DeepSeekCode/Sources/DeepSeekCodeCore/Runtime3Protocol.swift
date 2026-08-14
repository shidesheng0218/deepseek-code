import Foundation

/// Stable event vocabulary for Runtime 3.0. Unknown/legacy values remain
/// representable because the persisted log must be forward compatible.
public struct SessionEventKind: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public static let turnStarted = Self(rawValue: "turn_started")
    public static let inputClaimed = Self(rawValue: "input_claimed")
    public static let stepStarted = Self(rawValue: "step_started")
    public static let modelRequestStarted = Self(rawValue: "model_request_started")
    public static let assistantChunkAppended = Self(rawValue: "assistant_chunk_appended")
    public static let assistantMessageCommitted = Self(rawValue: "assistant_message_committed")
    public static let toolRequested = Self(rawValue: "tool_requested")
    public static let toolPolicyEvaluated = Self(rawValue: "tool_policy_evaluated")
    public static let approvalRequested = Self(rawValue: "approval_requested")
    public static let approvalResolved = Self(rawValue: "approval_resolved")
    public static let toolStarted = Self(rawValue: "tool_started")
    public static let evidenceRecorded = Self(rawValue: "evidence_recorded")
    public static let toolCompleted = Self(rawValue: "tool_completed")
    public static let toolFailed = Self(rawValue: "tool_failed")
    public static let toolIndeterminate = Self(rawValue: "tool_indeterminate")
    public static let stepEnded = Self(rawValue: "step_ended")
    public static let turnEnded = Self(rawValue: "turn_ended")
    public static let verificationEvaluated = Self(rawValue: "verification_evaluated")
    public static let deliveryStateChanged = Self(rawValue: "delivery_state_changed")
}

public struct SessionEventDraft: Equatable, Sendable {
    public let aggregateID: String
    public let commandID: String
    public let causationID: String?
    public let correlationID: String?
    public let kind: SessionEventKind
    public let payload: [String: String]
    public let schemaVersion: Int

    public init(
        aggregateID: String,
        commandID: String,
        causationID: String? = nil,
        correlationID: String? = nil,
        kind: SessionEventKind,
        payload: [String: String],
        schemaVersion: Int = SessionEventEnvelope.currentSchemaVersion
    ) {
        self.aggregateID = aggregateID
        self.commandID = commandID
        self.causationID = causationID
        self.correlationID = correlationID
        self.kind = kind
        self.payload = payload
        self.schemaVersion = schemaVersion
    }
}

public struct SessionEventEnvelope: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 3

    public let eventID: UUID
    public let aggregateID: String
    public let sequence: Int
    public let commandID: String
    public let causationID: String?
    public let correlationID: String?
    public let kind: SessionEventKind
    public let payload: [String: String]
    public let timestamp: Date
    public let schemaVersion: Int

    public init(
        eventID: UUID,
        aggregateID: String,
        sequence: Int,
        commandID: String,
        causationID: String?,
        correlationID: String?,
        kind: SessionEventKind,
        payload: [String: String],
        timestamp: Date,
        schemaVersion: Int
    ) {
        self.eventID = eventID
        self.aggregateID = aggregateID
        self.sequence = sequence
        self.commandID = commandID
        self.causationID = causationID
        self.correlationID = correlationID
        self.kind = kind
        self.payload = payload
        self.timestamp = timestamp
        self.schemaVersion = schemaVersion
    }

    public var legacyEvent: SessionEvent {
        SessionEvent(
            id: eventID,
            sessionID: aggregateID,
            sequence: sequence,
            timestamp: timestamp,
            type: kind.rawValue,
            payload: payload
        )
    }
}

/// Runtime-owned append capability. Call sites receive this abstraction
/// instead of constructing competing EventStore/Repository write paths.
public final class SessionEventCommitter: @unchecked Sendable {
    private let repository: SessionRepository

    public init(repository: SessionRepository) {
        self.repository = repository
    }

    @discardableResult
    public func commit(_ draft: SessionEventDraft) throws -> SessionEventEnvelope {
        _ = try repository.appendDurable(
            sessionID: draft.aggregateID,
            type: draft.kind.rawValue,
            payload: draft.payload,
            commandID: draft.commandID,
            causationID: draft.causationID,
            correlationID: draft.correlationID,
            schemaVersion: draft.schemaVersion
        )
        guard let envelope = try repository.eventEnvelope(commandID: draft.commandID) else {
            throw SessionEventCommitterError.eventNotFound
        }
        return envelope
    }
}

public enum SessionEventCommitterError: LocalizedError, Sendable {
    case eventNotFound

    public var errorDescription: String? {
        "事件写入后无法从持久日志读取"
    }
}

public enum SessionCommandIssuer: String, Codable, CaseIterable, Sendable {
    case app
    case cli
    case controlPlane = "control_plane"
    case daemon
    case recovery
}

public enum SessionCommandBody: Codable, Equatable, Sendable {
    case admit(SessionInput)
    case start(sessionID: String)
    case steer(sessionID: String, inputID: String)
    case pause(sessionID: String)
    case resume(sessionID: String)
    case cancel(sessionID: String)
    case resolveApproval(sessionID: String, approvalID: String, decision: ApprovalDecision)
    case adoptWorkerResult(sessionID: String, workerSessionID: String)
    case evaluateDelivery(sessionID: String)
}

public struct SessionCommandEnvelope: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 3

    public let commandID: String
    public let idempotencyKey: String
    public let expectedSequence: Int
    public let issuedBy: SessionCommandIssuer
    public let deadline: Date
    public let schemaVersion: Int
    public let body: SessionCommandBody

    public init(
        commandID: String = UUID().uuidString,
        idempotencyKey: String,
        expectedSequence: Int,
        issuedBy: SessionCommandIssuer,
        deadline: Date,
        schemaVersion: Int = SessionCommandEnvelope.currentSchemaVersion,
        body: SessionCommandBody
    ) {
        self.commandID = commandID
        self.idempotencyKey = idempotencyKey
        self.expectedSequence = expectedSequence
        self.issuedBy = issuedBy
        self.deadline = deadline
        self.schemaVersion = schemaVersion
        self.body = body
    }
}

public enum CommandState: String, Codable, Equatable, Sendable {
    case accepted
    case completed
}

public struct CommandReceipt: Codable, Equatable, Sendable {
    public let commandID: String
    public let sessionID: String
    public let acceptedSequence: Int
    public let state: CommandState

    public init(commandID: String, sessionID: String, acceptedSequence: Int, state: CommandState) {
        self.commandID = commandID
        self.sessionID = sessionID
        self.acceptedSequence = acceptedSequence
        self.state = state
    }
}
