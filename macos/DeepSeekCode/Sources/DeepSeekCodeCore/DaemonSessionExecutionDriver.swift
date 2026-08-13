import Foundation

/// The only execution seam used by `deepseekd`. It separates durable inbox /
/// lifecycle handling from the concrete Provider + Tool host, so tests can
/// exercise recovery and idempotency without a live model credential.
public protocol DaemonSessionRunner: Sendable {
    func run(session: StoredSession, input: SessionInputRecord, control: AgentRunControl) async throws
    func resume(session: StoredSession, approvalID: String, decision: ApprovalDecision, control: AgentRunControl) async throws
}

/// Converts Supervisor lifecycle commands into one bounded execution task per
/// Session. The task identity is kept separately from the `Task` handle so a
/// very fast runner cannot leave a stale handle behind while it is finishing.
public actor DaemonSessionExecutionDriver: SessionExecutionDriver {
    private let repository: SessionRepository
    private let runner: any DaemonSessionRunner
    private var controls: [String: AgentRunControl] = [:]
    private var tasks: [String: Task<Void, Never>] = [:]
    private var activeRunIDs: [String: String] = [:]

    public init(repository: SessionRepository, runner: any DaemonSessionRunner) {
        self.repository = repository
        self.runner = runner
    }

    public func start(sessionID: String) async throws {
        guard activeRunIDs[sessionID] == nil else { return }
        guard let session = try repository.session(id: sessionID) else { throw HarnessSupervisorError.sessionNotFound }
        guard let input = try nextRunnableInput(sessionID: sessionID) else {
            // Starting an empty Session is idempotent and remains at a safe
            // boundary. It must not synthesize a prompt or replay old work.
            return
        }
        let control = controls[sessionID] ?? AgentRunControl()
        controls[sessionID] = control
        let runID = UUID().uuidString
        activeRunIDs[sessionID] = runID
        tasks[sessionID] = Task { [weak self] in
            await self?.execute(
                runID: runID,
                session: session,
                input: input,
                control: control
            )
        }
    }

    public func pause(sessionID: String) async throws {
        guard let control = controls[sessionID] else { return }
        await control.requestPause()
    }

    public func resume(sessionID: String) async throws {
        guard let control = controls[sessionID] else { return }
        await control.resume()
    }

    public func resolveApproval(sessionID: String, approvalID: String, decision: ApprovalDecision) async throws {
        guard activeRunIDs[sessionID] == nil else { return }
        guard let session = try repository.session(id: sessionID) else { throw HarnessSupervisorError.sessionNotFound }
        let control = controls[sessionID] ?? AgentRunControl()
        controls[sessionID] = control
        await control.resume()
        let runID = UUID().uuidString
        activeRunIDs[sessionID] = runID
        tasks[sessionID] = Task { [weak self] in
            await self?.executeApprovalResume(
                runID: runID,
                session: session,
                approvalID: approvalID,
                decision: decision,
                control: control
            )
        }
    }

    public func cancel(sessionID: String) async throws {
        guard let control = controls[sessionID] else { return }
        // Do not cancel the child task mid-tool-call. The control is checked
        // at the Agent's persisted safe boundaries, preventing an unknown
        // file/Git/network side effect from being auto-replayed.
        await control.requestStop()
    }

    /// Test/support hook. UI and CLI read projections/events rather than this
    /// method; it only waits until a known daemon command reaches a boundary.
    public func waitForIdle(sessionID: String, timeout: TimeInterval = 5) async throws {
        let deadline = Date().addingTimeInterval(max(0.1, timeout))
        while activeRunIDs[sessionID] != nil {
            guard Date() < deadline else { throw ChildAgentRuntimeError.timedOut }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    private func nextRunnableInput(sessionID: String) throws -> SessionInputRecord? {
        let inputs = try repository.sessionInputs(sessionID: sessionID)
        if let promoted = inputs.first(where: { $0.state == .promoted }) { return promoted }
        return try repository.promoteNextSessionInput(sessionID: sessionID)
    }

    private func execute(runID: String, session: StoredSession, input: SessionInputRecord, control: AgentRunControl) async {
        do {
            try await runner.run(session: session, input: input, control: control)
            _ = try? repository.markSessionInputConsumed(id: input.id)
            _ = try? repository.appendDurable(
                sessionID: session.id,
                type: "daemon_input_consumed",
                payload: ["inputID": input.id],
                commandID: "daemon-consume-\(input.id)",
                causationID: input.id
            )
        } catch is CancellationError {
            // A stopped run must never leave its input promoted, otherwise the
            // next start would silently replay the cancelled prompt and the
            // newest user message could never run.
            _ = try? repository.cancelSessionInput(id: input.id)
            _ = try? repository.appendDurable(
                sessionID: session.id,
                type: "daemon_execution_stopped",
                payload: ["reason": "cancelled_at_safe_boundary"],
                commandID: "daemon-stop-\(runID)"
            )
        } catch {
            // A failed run also consumes its input so a retry does not replay
            // the failed prompt while newer user messages are pending.
            _ = try? repository.markSessionInputConsumed(id: input.id)
            _ = try? repository.appendDurable(
                sessionID: session.id,
                type: "agent_failed",
                payload: ["message": SecretRedactor.redact(error.localizedDescription)],
                commandID: "daemon-failed-\(runID)"
            )
            _ = try? repository.appendDurable(
                sessionID: session.id,
                type: "session_status_changed",
                payload: ["status": SessionStatus.failed.rawValue],
                commandID: "daemon-failed-status-\(runID)"
            )
        }
        finish(sessionID: session.id, runID: runID)
    }

    private func executeApprovalResume(
        runID: String,
        session: StoredSession,
        approvalID: String,
        decision: ApprovalDecision,
        control: AgentRunControl
    ) async {
        do {
            try await runner.resume(session: session, approvalID: approvalID, decision: decision, control: control)
        } catch is CancellationError {
            _ = try? repository.appendDurable(
                sessionID: session.id,
                type: "daemon_execution_stopped",
                payload: ["reason": "approval_resume_cancelled"],
                commandID: "daemon-approval-stop-\(runID)"
            )
        } catch {
            _ = try? repository.appendDurable(
                sessionID: session.id,
                type: "agent_failed",
                payload: ["message": SecretRedactor.redact(error.localizedDescription)],
                commandID: "daemon-approval-failed-\(runID)",
                causationID: approvalID
            )
        }
        finish(sessionID: session.id, runID: runID)
    }

    private func finish(sessionID: String, runID: String) {
        guard activeRunIDs[sessionID] == runID else { return }
        activeRunIDs.removeValue(forKey: sessionID)
        tasks.removeValue(forKey: sessionID)
        // A stopped control can never be resumed; drop it so the next start
        // builds a fresh control instead of failing at the first boundary.
        controls.removeValue(forKey: sessionID)
    }
}
