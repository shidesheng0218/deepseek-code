import Foundation

public enum WorkerTaskMessageKind: String, Codable, CaseIterable, Sendable {
    case evidence
    case finding
    case question
    case challenge
}

/// A durable, parent-session-scoped worker contribution. It is intentionally
/// evidence-only: publishing a message never mutates the workspace or the
/// main Agent context. The Supervisor decides when a Worker result is adopted.
public struct WorkerTaskMessage: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let parentSessionID: String
    public let workerSessionID: String
    public let workerID: String
    public let kind: WorkerTaskMessageKind
    public let summary: String
    public let evidenceIDs: [String]
    public let references: [String]
    public let confidence: Double
    public let createdAt: Date

    public init(
        id: String = UUID().uuidString,
        parentSessionID: String,
        workerSessionID: String,
        workerID: String,
        kind: WorkerTaskMessageKind,
        summary: String,
        evidenceIDs: [String] = [],
        references: [String] = [],
        confidence: Double,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.parentSessionID = parentSessionID
        self.workerSessionID = workerSessionID
        self.workerID = workerID
        self.kind = kind
        self.summary = SecretRedactor.redact(summary)
        self.evidenceIDs = evidenceIDs
        self.references = references
        self.confidence = min(1, max(0, confidence))
        self.createdAt = createdAt
    }
}

public final class WorkerTaskGraph: @unchecked Sendable {
    private let repository: SessionRepository
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(repository: SessionRepository) {
        self.repository = repository
    }

    @discardableResult
    public func publish(_ message: WorkerTaskMessage) throws -> SessionEventEnvelope {
        guard !message.parentSessionID.isEmpty,
              !message.workerSessionID.isEmpty,
              !message.workerID.isEmpty else {
            throw WorkerTaskGraphError.invalidMessage
        }
        let encoded = String(decoding: try encoder.encode(message), as: UTF8.self)
        return try SessionEventCommitter(repository: repository).commit(SessionEventDraft(
            aggregateID: message.parentSessionID,
            commandID: "worker-task-message-\(message.id)",
            causationID: message.workerSessionID,
            correlationID: message.parentSessionID,
            kind: SessionEventKind(rawValue: "worker_task_message"),
            payload: ["message": encoded, "kind": message.kind.rawValue, "workerID": message.workerID]
        ))
    }

    public func messages(parentSessionID: String) throws -> [WorkerTaskMessage] {
        try repository.eventEnvelopes(sessionID: parentSessionID)
            .filter { $0.kind == SessionEventKind(rawValue: "worker_task_message") }
            .compactMap { event in
                guard let encoded = event.payload["message"] else { return nil }
                return try? decoder.decode(WorkerTaskMessage.self, from: Data(encoded.utf8))
            }
    }
}

public enum WorkerTaskGraphError: LocalizedError, Sendable {
    case invalidMessage

    public var errorDescription: String? {
        "Worker TaskGraph 消息缺少必要身份字段"
    }
}
