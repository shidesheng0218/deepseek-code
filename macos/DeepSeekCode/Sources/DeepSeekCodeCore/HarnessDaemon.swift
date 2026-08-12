import Foundation

/// Receipt returned when a UI or loopback client reattaches to a durable
/// session. The daemon exposes state only; tool execution remains owned by
/// the Supervisor and its per-session execution driver.
public struct SessionAttachReceipt: Codable, Equatable, Sendable {
    public let sessionID: String
    public let eventCursor: Int
    public let status: SessionStatus
    public let pendingApprovalID: String?
    public let needsAttention: Bool

    public init(sessionID: String, eventCursor: Int, status: SessionStatus, pendingApprovalID: String?, needsAttention: Bool) {
        self.sessionID = sessionID
        self.eventCursor = eventCursor
        self.status = status
        self.pendingApprovalID = pendingApprovalID
        self.needsAttention = needsAttention
    }
}

public protocol HarnessDaemon: Sendable {
    func startSession(_ sessionID: String) async throws
    func pauseSession(_ sessionID: String) async throws
    func resumeSession(_ sessionID: String) async throws
    func attachSession(_ sessionID: String) async throws -> SessionAttachReceipt
    func cancelSession(_ sessionID: String) async throws
    func resolveApproval(sessionID: String, approvalID: String, decision: ApprovalDecision) async throws
    func recoverAll() async throws -> [RecoveryResult]
}

/// Local daemon façade for the persistent harness. It is intentionally an
/// actor so loopback clients and SwiftUI cannot race the session lifecycle.
/// The next deployment can host this same API in a LaunchAgent without
/// changing any caller contracts.
public actor LocalHarnessDaemon: HarnessDaemon {
    private let repository: SessionRepository
    private let supervisor: any DurableSessionSupervisor

    public init(repository: SessionRepository, supervisor: any DurableSessionSupervisor) {
        self.repository = repository
        self.supervisor = supervisor
    }

    public func startSession(_ sessionID: String) async throws {
        try await supervisor.start(sessionID: sessionID)
    }

    public func pauseSession(_ sessionID: String) async throws {
        try await supervisor.pause(sessionID: sessionID)
    }

    public func resumeSession(_ sessionID: String) async throws {
        try await supervisor.resume(sessionID: sessionID)
    }

    public func cancelSession(_ sessionID: String) async throws {
        try await supervisor.cancel(sessionID: sessionID)
    }

    public func resolveApproval(sessionID: String, approvalID: String, decision: ApprovalDecision) async throws {
        try await supervisor.resolveApproval(sessionID: sessionID, approvalID: approvalID, decision: decision)
    }

    public func attachSession(_ sessionID: String) throws -> SessionAttachReceipt {
        guard let session = try repository.session(id: sessionID) else {
            throw HarnessSupervisorError.sessionNotFound
        }
        let events = try repository.events(sessionID: sessionID)
        let projected = try SessionProjector.project(session: session, events: events)
        let needsAttention = projected.session.status == .needsAttention || events.contains {
            ["tool_indeterminate", "ssh_tool_indeterminate", "mcp_tool_indeterminate", "github_indeterminate", "github_push_indeterminate", "github_pr_indeterminate"].contains($0.type)
        }
        return SessionAttachReceipt(
            sessionID: sessionID,
            eventCursor: events.last?.sequence ?? 0,
            status: projected.session.status,
            pendingApprovalID: projected.pendingApprovalID,
            needsAttention: needsAttention
        )
    }

    public func recoverAll() async throws -> [RecoveryResult] {
        let sessions = try repository.sessions()
        var results: [RecoveryResult] = []
        for session in sessions where !session.archived {
            results.append(try await supervisor.recover(sessionID: session.id))
        }
        return results
    }
}
