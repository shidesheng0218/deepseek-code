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

    public func execute(_ command: SessionCommandEnvelope) async throws -> CommandReceipt {
        guard command.deadline > Date() else { throw HarnessSupervisorError.commandExpired }
        let sessionID = commandSessionID(command.body)
        let receiptCommandID = "session-command-\(command.commandID)"
        if let existing = try repository.eventEnvelope(commandID: receiptCommandID) {
            return CommandReceipt(
                commandID: command.commandID,
                sessionID: existing.payload["sessionID"] ?? sessionID,
                acceptedSequence: Int(existing.payload["acceptedSequence"] ?? "\(existing.sequence)") ?? existing.sequence,
                state: CommandState(rawValue: existing.payload["state"] ?? "") ?? .completed
            )
        }

        let acceptedSequence: Int
        switch command.body {
        case let .admit(input):
            acceptedSequence = try admit(input).admittedSequence
        case .start:
            try await start(sessionID: sessionID)
            acceptedSequence = try repository.eventCount(sessionID: sessionID)
        case let .steer(_, inputID):
            guard let promoted = try repository.promoteNextSessionInput(sessionID: sessionID), promoted.id == inputID else {
                throw HarnessSupervisorError.inputNotPromotable
            }
            acceptedSequence = promoted.admittedSequence
        case .pause:
            try await pause(sessionID: sessionID)
            acceptedSequence = try repository.eventCount(sessionID: sessionID)
        case .resume:
            try await resume(sessionID: sessionID)
            acceptedSequence = try repository.eventCount(sessionID: sessionID)
        case .cancel:
            try await cancel(sessionID: sessionID)
            acceptedSequence = try repository.eventCount(sessionID: sessionID)
        case let .resolveApproval(_, approvalID, decision):
            try await resolveApproval(sessionID: sessionID, approvalID: approvalID, decision: decision)
            acceptedSequence = try repository.eventCount(sessionID: sessionID)
        case let .adoptWorkerResult(_, workerSessionID):
            try adoptWorkerResult(sessionID: sessionID, workerSessionID: workerSessionID)
            acceptedSequence = try repository.eventCount(sessionID: sessionID)
        case .evaluateDelivery:
            _ = try evaluateDelivery(sessionID: sessionID)
            acceptedSequence = try repository.eventCount(sessionID: sessionID)
        }
        _ = try SessionEventCommitter(repository: repository).commit(SessionEventDraft(
            aggregateID: sessionID,
            commandID: receiptCommandID,
            causationID: command.commandID,
            correlationID: command.commandID,
            kind: SessionEventKind(rawValue: "session_command_completed"),
            payload: [
                "sessionID": sessionID,
                "acceptedSequence": "\(acceptedSequence)",
                "state": CommandState.completed.rawValue,
                "issuedBy": command.issuedBy.rawValue
            ]
        ))
        return CommandReceipt(commandID: command.commandID, sessionID: sessionID, acceptedSequence: acceptedSequence, state: .completed)
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
        // Inbox admission is also the single durable source for the user
        // timeline. The deterministic command ID prevents a retried client
        // request from creating a duplicate conversation turn.
        let attachments = input.parts.compactMap { part -> AttachmentRef? in
            switch part {
            case let .image(attachment), let .document(attachment): return attachment
            default: return nil
            }
        }
        let attachmentsJSON = (try? String(data: JSONEncoder().encode(attachments), encoding: .utf8)) ?? "[]"
        _ = try repository.appendDurable(
            sessionID: input.sessionID,
            type: "user_message",
            payload: [
                "inputID": record.id,
                "text": SecretRedactor.redact(input.parts.plainText),
                "attachments": attachments.map(\.id).joined(separator: ","),
                "attachmentsJSON": attachmentsJSON
            ],
            commandID: "harness-user-message-\(record.id)",
            causationID: record.id
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

    /// Creates the durable approval record and its event as one Supervisor-
    /// owned transition. UI/CLI callers submit the decision later; they do
    /// not insert approval rows or synthesize audit events themselves.
    public func requestApproval(
        sessionID: String,
        tool: String,
        risk: CommandRisk,
        arguments: String,
        commandID: String = UUID().uuidString
    ) throws -> ApprovalRecord {
        try ensureSession(sessionID)
        let eventCommandID = "supervisor-approval-request-\(commandID)"
        if let existing = try repository.eventEnvelope(commandID: eventCommandID),
           let approvalID = existing.payload["approvalID"],
           let approval = try repository.approval(id: approvalID) {
            return approval
        }
        let approval = try repository.createApproval(
            sessionID: sessionID,
            tool: tool,
            risk: risk,
            // The continuation needs the original JSON to validate and
            // resume exactly one tool call. It is never copied into the
            // event payload; only its stable hash is audited below.
            arguments: arguments
        )
        _ = try SessionEventCommitter(repository: repository).commit(SessionEventDraft(
            aggregateID: sessionID,
            commandID: eventCommandID,
            causationID: approval.id,
            correlationID: approval.id,
            kind: .approvalRequested,
            payload: [
                "approvalID": approval.id,
                "tool": tool,
                "risk": "L\(risk.rawValue)",
                "argumentsHash": ApprovalContinuation.hash(arguments)
            ]
        ))
        return approval
    }

    public func resolveApproval(sessionID: String, approvalID: String, decision: ApprovalDecision) async throws {
        print("→ [SUPERVISOR] resolveApproval called: sessionID=\(sessionID), approvalID=\(approvalID), decision=\(decision)")

        guard let approval = try repository.approval(id: approvalID) else {
            print("❌ [SUPERVISOR] Approval not found")
            throw HarnessSupervisorError.approvalNotFound
        }
        guard approval.sessionID == sessionID else {
            print("❌ [SUPERVISOR] Session ID mismatch")
            throw HarnessSupervisorError.approvalSessionMismatch
        }
        guard approval.decision == .pending else {
            print("❌ [SUPERVISOR] Approval already resolved")
            throw HarnessSupervisorError.approvalAlreadyResolved
        }

        if let executionDriver = driver(for: sessionID) {
            print("→ [SUPERVISOR] ExecutionDriver found, calling resolveApproval")
            try await executionDriver.resolveApproval(sessionID: sessionID, approvalID: approvalID, decision: decision)
        } else {
            print("⚠️ [SUPERVISOR] ExecutionDriver is nil - only updating database")
        }

        // Native Agent resume persists this transition itself so the resumed
        // tool call and its approval share one causal event chain. Lightweight
        // drivers used by Control Plane/tests do not, therefore the
        // Supervisor finalizes the transition only when it is still pending.
        if let refreshed = try repository.approval(id: approvalID), refreshed.decision == .pending {
            guard try repository.resolvePendingApproval(id: approvalID, decision: decision) else {
                throw HarnessSupervisorError.approvalAlreadyResolved
            }
            _ = try repository.appendDurable(
                sessionID: sessionID,
                type: "approval_resolved",
                payload: ["approvalID": approvalID, "decision": decision.rawValue],
                commandID: "harness-approval-\(approvalID)-\(decision.rawValue)",
                causationID: approvalID
            )
            print("✅ [SUPERVISOR] Database updated successfully")
        } else {
            print("→ [SUPERVISOR] Approval already resolved by driver, skipping database update")
        }
    }

    public func adoptWorkerResult(sessionID: String, workerSessionID: String) throws {
        try ensureSession(sessionID)
        guard let worker = try repository.workerSession(id: workerSessionID) else {
            throw HarnessSupervisorError.workerResultUnavailable
        }
        guard worker.parentSessionID == sessionID else {
            throw HarnessSupervisorError.workerSessionMismatch
        }
        if worker.state == .completed { return }
        guard worker.state == .awaitingAdoption, let result = worker.result else {
            throw HarnessSupervisorError.workerResultUnavailable
        }
        _ = try WorkerSessionCoordinator(repository: repository).adopt(id: workerSessionID, result: result)
        _ = try SessionEventCommitter(repository: repository).commit(SessionEventDraft(
            aggregateID: sessionID,
            commandID: "supervisor-worker-adopt-\(sessionID)-\(workerSessionID)",
            causationID: workerSessionID,
            correlationID: sessionID,
            kind: SessionEventKind(rawValue: "worker_result_adopted"),
            payload: [
                "workerSessionID": workerSessionID,
                "workerID": worker.workerID,
                "evidenceIDs": result.evidenceIDs.joined(separator: ","),
                "outputHash": result.outputHash
            ]
        ))
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

    private func commandSessionID(_ body: SessionCommandBody) -> String {
        switch body {
        case let .admit(input): input.sessionID
        case let .start(sessionID), let .pause(sessionID), let .resume(sessionID), let .cancel(sessionID), let .evaluateDelivery(sessionID): sessionID
        case let .steer(sessionID, _), let .resolveApproval(sessionID, _, _), let .adoptWorkerResult(sessionID, _): sessionID
        }
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

    /// Foreground clients may only consume a message that was first promoted
    /// at a persisted safe boundary. The boolean reports whether this caller
    /// won the one-shot completion race.
    @discardableResult
    public func consumePromotedInput(id: String) throws -> Bool {
        try repository.consumePromotedSessionInput(id: id)
    }

    public func recover(sessionID: String) throws -> ProjectedSessionState? {
        try RepositoryRecoveryCoordinator(repository: repository).recover(sessionID: sessionID)
    }

    private func renewIfOwned(sessionID: String) {
        _ = try? repository.renewSessionLease(sessionID: sessionID, ownerInstanceID: instanceID)
    }
}
