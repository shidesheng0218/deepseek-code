import Foundation

/// Small bridge used while concrete hosts are assembled by the App layer.
/// The Supervisor owns the lifecycle; callers provide only the execution
/// closures and cannot bypass the lifecycle events.
public final class ClosureSessionExecutionDriver: SessionExecutionDriver, @unchecked Sendable {
    private let onStart: @Sendable (String) async throws -> Void
    private let onPause: @Sendable (String) async throws -> Void
    private let onResume: @Sendable (String) async throws -> Void
    private let onResolveApproval: @Sendable (String, String, ApprovalDecision) async throws -> Void
    private let onCancel: @Sendable (String) async throws -> Void

    public init(
        onStart: @escaping @Sendable (String) async throws -> Void,
        onPause: @escaping @Sendable (String) async throws -> Void,
        onResume: @escaping @Sendable (String) async throws -> Void,
        onResolveApproval: @escaping @Sendable (String, String, ApprovalDecision) async throws -> Void = { _, _, _ in },
        onCancel: @escaping @Sendable (String) async throws -> Void
    ) {
        self.onStart = onStart
        self.onPause = onPause
        self.onResume = onResume
        self.onResolveApproval = onResolveApproval
        self.onCancel = onCancel
    }

    public func start(sessionID: String) async throws { try await onStart(sessionID) }
    public func pause(sessionID: String) async throws { try await onPause(sessionID) }
    public func resume(sessionID: String) async throws { try await onResume(sessionID) }
    public func resolveApproval(sessionID: String, approvalID: String, decision: ApprovalDecision) async throws {
        try await onResolveApproval(sessionID, approvalID, decision)
    }
    public func cancel(sessionID: String) async throws { try await onCancel(sessionID) }
}
