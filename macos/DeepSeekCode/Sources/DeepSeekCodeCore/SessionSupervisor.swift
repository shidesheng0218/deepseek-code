import Foundation

/// The single writable owner for a Session. The App intentionally owns this
/// actor only while it is alive: recovery resumes from persisted checkpoints,
/// never by silently continuing an in-flight side effect after relaunch.
public actor SessionSupervisor: DurableSessionSupervisor {
    public let instanceID: String
    private let repository: SessionRepository
    private let defaultExecutionDriver: (any SessionExecutionDriver)?
    private var executionDrivers: [String: any SessionExecutionDriver] = [:]
    private var heartbeatTasks: [String: Task<Void, Never>] = [:]

    public init(repository: SessionRepository, executionDriver: (any SessionExecutionDriver)? = nil, instanceID: String = UUID().uuidString) {
        self.repository = repository
        self.defaultExecutionDriver = executionDriver
        self.instanceID = instanceID
    }

    public func installExecutionDriver(_ driver: (any SessionExecutionDriver)?, sessionID: String) {
        executionDrivers[sessionID] = driver
    }

    public func admit(_ input: SessionInput) throws -> AdmissionReceipt {
        guard try repository.session(id: input.sessionID) != nil else {
            throw HarnessSupervisorError.sessionNotFound
        }
        let record = try repository.enqueueSessionInput(
            sessionID: input.sessionID,
            idempotencyKey: input.idempotencyKey,
            delivery: input.delivery,
            parts: input.parts
        )
        let commandID = "harness-admit-\(input.idempotencyKey)"
        _ = try repository.appendDurable(
            sessionID: input.sessionID,
            type: "harness_command_admitted",
            payload: ["inputID": record.id, "delivery": input.delivery.rawValue],
            commandID: commandID,
            causationID: record.id
        )
        return AdmissionReceipt(
            inputID: record.id,
            sessionID: record.sessionID,
            idempotencyKey: record.idempotencyKey,
            commandID: commandID,
            admittedSequence: record.admittedSequence
        )
    }

    public func start(sessionID: String) async throws {
        try ensureSession(sessionID)
        _ = try claim(sessionID: sessionID)
        let inputID = try repository.sessionInputs(sessionID: sessionID)
            .last(where: { $0.state != .cancelled })?.id ?? UUID().uuidString
        let commandID = "harness-start-\(sessionID)-\(inputID)"
        let existing = try repository.events(sessionID: sessionID).contains { $0.type == "harness_started" && $0.payload["commandID"] == commandID }
        if existing { return }
        _ = try repository.appendDurable(sessionID: sessionID, type: "harness_started", payload: ["commandID": commandID], commandID: commandID)
        if let executionDriver = driver(for: sessionID) {
            do {
                try await executionDriver.start(sessionID: sessionID)
            } catch {
                _ = try? repository.appendDurable(sessionID: sessionID, type: "harness_failed", payload: ["commandID": commandID, "message": SecretRedactor.redact(error.localizedDescription)], commandID: "\(commandID)-failed")
                throw error
            }
        }
    }

    public func pause(sessionID: String) async throws {
        try ensureSession(sessionID)
        if let executionDriver = driver(for: sessionID) { try await executionDriver.pause(sessionID: sessionID) }
        _ = try repository.appendDurable(sessionID: sessionID, type: "harness_paused", payload: [:], commandID: "harness-pause-\(sessionID)")
    }

    public func resume(sessionID: String) async throws {
        try ensureSession(sessionID)
        if let executionDriver = driver(for: sessionID) { try await executionDriver.resume(sessionID: sessionID) }
        _ = try repository.appendDurable(sessionID: sessionID, type: "harness_resumed", payload: [:], commandID: "harness-resume-\(sessionID)")
    }

    public func resolveApproval(sessionID: String, approvalID: String, decision: ApprovalDecision) async throws {
        guard let approval = try repository.approval(id: approvalID) else { throw HarnessSupervisorError.approvalNotFound }
        guard approval.sessionID == sessionID else { throw HarnessSupervisorError.approvalSessionMismatch }
        guard approval.decision == .pending else { throw HarnessSupervisorError.approvalAlreadyResolved }
        if let executionDriver = driver(for: sessionID) {
            try await executionDriver.resolveApproval(sessionID: sessionID, approvalID: approvalID, decision: decision)
        }
        // Native Agent resume persists this transition itself so the resumed
        // tool call and its approval share one causal event chain. Lightweight
        // drivers used by Control Plane/tests do not, therefore the
        // Supervisor finalizes the transition only when it is still pending.
        if let refreshed = try repository.approval(id: approvalID), refreshed.decision == .pending {
            try repository.resolveApproval(id: approvalID, decision: decision)
            _ = try repository.appendDurable(
                sessionID: sessionID,
                type: "approval_resolved",
                payload: ["approvalID": approvalID, "decision": decision.rawValue],
                commandID: "harness-approval-\(approvalID)-\(decision.rawValue)",
                causationID: approvalID
            )
        }
    }

    public func cancel(sessionID: String) async throws {
        try ensureSession(sessionID)
        if let executionDriver = driver(for: sessionID) { try await executionDriver.cancel(sessionID: sessionID) }
        _ = try repository.appendDurable(sessionID: sessionID, type: "harness_cancelled", payload: [:], commandID: "harness-cancel-\(sessionID)")
    }

    public func recover(sessionID: String) throws -> RecoveryResult {
        let projected = try RepositoryRecoveryCoordinator(repository: repository).recover(sessionID: sessionID)
        let events = try repository.events(sessionID: sessionID)
        let indeterminate = events.filter { event in
            ["tool_indeterminate", "ssh_tool_indeterminate", "mcp_tool_indeterminate", "github_indeterminate", "github_push_indeterminate", "github_pr_indeterminate"].contains(event.type)
        }.map { $0.id.uuidString }
        let needsAttention = projected?.session.status == .needsAttention || !indeterminate.isEmpty
        _ = try repository.appendDurable(
            sessionID: sessionID,
            type: "harness_recovered",
            payload: ["needsAttention": needsAttention ? "true" : "false", "indeterminateCount": "\(indeterminate.count)"],
            commandID: "harness-recover-\(sessionID)-\(events.last?.sequence ?? 0)"
        )
        return RecoveryResult(sessionID: sessionID, projectedState: projected, indeterminateEventIDs: indeterminate, needsAttention: needsAttention)
    }

    public func evaluateDelivery(sessionID: String) throws -> DeliveryGateResult {
        guard let contract = try repository.taskContract(sessionID: sessionID) else { throw HarnessSupervisorError.missingTaskContract }
        let events = try repository.events(sessionID: sessionID)
        let graph = VerificationGraph.project(taskID: sessionID, events: events)
        let hasDiff = graph.evidenceRecords.contains { $0.kind == .diff && $0.succeeded }
        let pending = events.filter { $0.type == "approval_requested" }.count - events.filter { $0.type == "approval_resolved" }.count
        let indeterminate = events.filter { event in
            ["tool_indeterminate", "ssh_tool_indeterminate", "mcp_tool_indeterminate", "github_indeterminate", "github_push_indeterminate", "github_pr_indeterminate"].contains(event.type)
        }.count
        let result = DeliveryGate.evaluate(contract: contract, graph: graph, hasDiff: hasDiff, pendingApprovals: max(0, pending), indeterminateSideEffects: indeterminate)
        let trace = DeliveryTrace.project(sessionID: sessionID, events: events)
        let traceJSON = (try? JSONEncoder().encode(trace)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        _ = try repository.appendDurable(
            sessionID: sessionID,
            type: "verification_gate_evaluated",
            payload: [
                "passed": result.passed ? "true" : "false",
                "missing": result.missingRequirements.joined(separator: "|"),
                "risks": result.unresolvedRisks.joined(separator: "|"),
                "deliveryTrace": traceJSON
            ],
            commandID: "harness-gate-\(sessionID)-\(events.last?.sequence ?? 0)"
        )
        return result
    }

    private func ensureSession(_ sessionID: String) throws {
        guard try repository.session(id: sessionID) != nil else { throw HarnessSupervisorError.sessionNotFound }
    }

    private func driver(for sessionID: String) -> (any SessionExecutionDriver)? {
        executionDrivers[sessionID] ?? defaultExecutionDriver
    }

    @discardableResult
    public func claim(sessionID: String) throws -> SessionLease {
        let lease = try repository.acquireSessionLease(sessionID: sessionID, ownerInstanceID: instanceID)
        if heartbeatTasks[sessionID] == nil {
            heartbeatTasks[sessionID] = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 5_000_000_000)
                    guard !Task.isCancelled else { return }
                    await self?.renewIfOwned(sessionID: sessionID)
                }
            }
        }
        return lease
    }

    @discardableResult
    public func heartbeat(sessionID: String) throws -> SessionLease {
        try repository.renewSessionLease(sessionID: sessionID, ownerInstanceID: instanceID)
    }

    public func release(sessionID: String) {
        heartbeatTasks[sessionID]?.cancel()
        heartbeatTasks.removeValue(forKey: sessionID)
        try? repository.releaseSessionLease(sessionID: sessionID, ownerInstanceID: instanceID)
    }

    public func enqueue(
        sessionID: String,
        idempotencyKey: String,
        delivery: SessionInputDelivery,
        parts: [ContentPart]
    ) throws -> SessionInputRecord {
        try repository.enqueueSessionInput(
            sessionID: sessionID,
            idempotencyKey: idempotencyKey,
            delivery: delivery,
            parts: parts
        )
    }

    public func promoteNextInput(sessionID: String) throws -> SessionInputRecord? {
        try repository.promoteNextSessionInput(sessionID: sessionID)
    }

    public func consumeInput(id: String) {
        try? repository.markSessionInputConsumed(id: id)
    }

    public func recover(sessionID: String) throws -> ProjectedSessionState? {
        try RepositoryRecoveryCoordinator(repository: repository).recover(sessionID: sessionID)
    }

    private func renewIfOwned(sessionID: String) {
        _ = try? repository.renewSessionLease(sessionID: sessionID, ownerInstanceID: instanceID)
    }
}
