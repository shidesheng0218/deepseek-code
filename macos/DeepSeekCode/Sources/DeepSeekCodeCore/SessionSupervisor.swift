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

    /// The only Runtime-owned Project/Session creation transition. Its command
    /// ID is durable, so a reconnecting GUI/CLI request receives the original
    /// Session instead of creating another branch, worktree binding or task
    /// contract.
    public func createSession(_ request: SessionCreationRequest, commandID: String) throws -> StoredSession {
        let eventCommandID = "supervisor-session-create-\(commandID)"
        if let existing = try repository.eventEnvelope(commandID: eventCommandID),
           let sessionID = existing.payload["sessionID"],
           let session = try repository.session(id: sessionID) {
            return session
        }
        let projectPath = URL(fileURLWithPath: request.projectPath, isDirectory: true).standardizedFileURL.path
        let title = request.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let requestedProjectName = request.projectName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let project = try repository.project(path: projectPath)
            ?? repository.createProject(
                name: requestedProjectName?.isEmpty == false
                    ? requestedProjectName!
                    : URL(fileURLWithPath: projectPath).lastPathComponent,
                path: projectPath
            )
        let branch = request.branch.isEmpty
            ? (request.target == .local ? "main" : "deepseek/\(sessionBranchSlug(title))")
            : request.branch
        let session = try repository.createSession(
            projectID: project.id,
            title: title.isEmpty ? "新建对话" : title,
            mode: request.mode,
            target: request.target,
            branch: branch,
            worktreePath: request.worktreePath,
            baselineRevision: request.baselineRevision
        )
        let contract = TaskContract.compatibility(prompt: session.title, budget: request.budget)
        try repository.saveTaskContract(contract, sessionID: session.id)
        if request.target == .worktree,
           let worktreePath = request.worktreePath,
           let baselineRevision = request.baselineRevision {
            try repository.saveWorktree(WorktreeRecord(
                sessionID: session.id,
                baseRevision: baselineRevision,
                branch: branch,
                worktreePath: worktreePath
            ))
        }
        _ = try SessionEventCommitter(repository: repository).commit(SessionEventDraft(
            aggregateID: session.id,
            commandID: eventCommandID,
            causationID: commandID,
            correlationID: commandID,
            kind: SessionEventKind(rawValue: "session_created"),
            payload: [
                "sessionID": session.id,
                "projectID": project.id,
                "target": request.target.rawValue,
                "branch": branch
            ]
        ))
        _ = try SessionEventCommitter(repository: repository).commit(SessionEventDraft(
            aggregateID: session.id,
            commandID: "\(eventCommandID)-task-contract",
            causationID: commandID,
            correlationID: commandID,
            kind: SessionEventKind(rawValue: "task_contract_created"),
            payload: [
                "goal": contract.goal,
                "requiredChanges": "\(contract.requiredChanges.count)",
                "requiredTests": "\(contract.requiredTests.count)"
            ]
        ))
        return session
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
        let findings: [ReviewFinding]
        if let review = events.last(where: { $0.type == "review_completed" }),
           let data = review.payload["findings"]?.data(using: .utf8),
           let decoded = try? JSONDecoder().decode([ReviewFinding].self, from: data) {
            findings = decoded
        } else {
            findings = []
        }
        let result = DeliveryGate.evaluate(
            contract: contract,
            graph: graph,
            hasDiff: hasDiff,
            pendingApprovals: max(0, pending),
            indeterminateSideEffects: indeterminate,
            reviewFindings: findings
        )
        let trace = DeliveryTrace.project(sessionID: sessionID, events: events)
        let traceJSON = (try? JSONEncoder().encode(trace)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        let resultJSON = (try? JSONEncoder().encode(result)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        _ = try SessionEventCommitter(repository: repository).commit(SessionEventDraft(
            aggregateID: sessionID,
            commandID: "supervisor-delivery-gate-\(sessionID)-\(events.last?.sequence ?? 0)",
            causationID: events.last?.id.uuidString,
            correlationID: sessionID,
            kind: SessionEventKind(rawValue: "verification_gate_evaluated"),
            payload: [
                "passed": result.passed ? "true" : "false",
                "missing": result.missingRequirements.joined(separator: "|"),
                "failed": result.failedEvidence.joined(separator: "|"),
                "risks": result.unresolvedRisks.joined(separator: "|"),
                "deliveryTrace": traceJSON,
                "result": resultJSON
            ]
        ))
        let nextStatus: SessionStatus = result.passed
            ? .delivered
            : (result.unresolvedRisks.isEmpty ? .needsRepair : .needsAttention)
        _ = try SessionEventCommitter(repository: repository).commit(SessionEventDraft(
            aggregateID: sessionID,
            commandID: "supervisor-delivery-state-\(sessionID)-\(events.last?.sequence ?? 0)",
            causationID: events.last?.id.uuidString,
            correlationID: sessionID,
            kind: .deliveryStateChanged,
            payload: ["status": nextStatus.rawValue]
        ))
        _ = try SessionEventCommitter(repository: repository).commit(SessionEventDraft(
            aggregateID: sessionID,
            commandID: "supervisor-session-status-\(sessionID)-\(events.last?.sequence ?? 0)",
            causationID: events.last?.id.uuidString,
            correlationID: sessionID,
            kind: SessionEventKind(rawValue: "session_status_changed"),
            payload: ["status": nextStatus.rawValue]
        ))
        if var state = try repository.runState(sessionID: sessionID) {
            state.deliveryGateResult = result
            try repository.saveRunState(state)
        }
        return result
    }

    /// The only non-model mutation entry point exposed to daemon clients.
    /// Each request is schema-checked, idempotent by command ID, and ends in
    /// a Runtime 3 envelope so UI-only features cannot create a parallel
    /// SQLite write path.
    public func applyRuntimeMutation(_ mutation: SessionRuntimeMutation) throws -> String {
        try ensureSession(mutation.sessionID)
        let receiptCommandID = "supervisor-runtime-mutation-\(mutation.commandID)"
        if let existing = try repository.eventEnvelope(commandID: receiptCommandID) {
            return existing.payload["result"] ?? "{}"
        }

        let decoder = DeepSeekDaemonJSON.decoder
        let encoder = DeepSeekDaemonJSON.encoder
        let payload = Data(mutation.payloadJSON.utf8)
        let result: String
        switch mutation.kind {
        case .event:
            let event = try decoder.decode(RuntimeEventMutation.self, from: payload)
            try recordRuntimeEvent(
                sessionID: mutation.sessionID,
                type: event.type,
                payload: event.payload,
                commandID: event.commandID ?? mutation.commandID,
                causationID: event.causationID,
                correlationID: event.correlationID
            )
            result = "{}"
        case .createHandoff:
            let request = try decoder.decode(RuntimeCreateHandoffMutation.self, from: payload)
            let handoff = try repository.createHandoff(
                sessionID: mutation.sessionID,
                destination: request.destination,
                baseRevision: request.baseRevision
            )
            result = String(decoding: try encoder.encode(handoff), as: UTF8.self)
        case .saveHandoffFiles:
            let request = try decoder.decode(RuntimeHandoffFilesMutation.self, from: payload)
            try repository.saveHandoffFiles(handoffID: request.handoffID, files: request.files)
            result = "{}"
        case .updateHandoff:
            let request = try decoder.decode(RuntimeHandoffStateMutation.self, from: payload)
            try repository.updateHandoff(id: request.handoffID, state: request.state)
            result = "{}"
        case .saveTerminalSession:
            try repository.saveTerminalSession(try decoder.decode(TerminalSessionRecord.self, from: payload))
            result = "{}"
        case .saveTerminalProcess:
            try repository.saveTerminalProcess(try decoder.decode(TerminalProcessRecord.self, from: payload))
            result = "{}"
        case .saveTerminalPort:
            try repository.saveTerminalPort(try decoder.decode(TerminalPortRecord.self, from: payload))
            result = "{}"
        case .appendTerminalEvent:
            let event = try decoder.decode(TerminalAuditEvent.self, from: payload)
            try repository.appendTerminalEvent(event)
            try recordRuntimeEvent(
                sessionID: mutation.sessionID,
                type: "terminal_\(event.kind.rawValue)",
                payload: ["terminalID": event.terminalID, "detail": SecretRedactor.redact(event.detail)],
                commandID: "\(mutation.commandID)-timeline",
                causationID: event.id,
                correlationID: event.terminalID
            )
            if event.kind == .output {
                try recordRuntimeEvent(
                    sessionID: mutation.sessionID,
                    type: "terminal_output_persisted",
                    payload: ["terminalID": event.terminalID, "detail": SecretRedactor.redact(event.detail)],
                    commandID: "\(mutation.commandID)-output",
                    causationID: event.id,
                    correlationID: event.terminalID
                )
            }
            result = "{}"
        case .appendTerminalHistory:
            try repository.appendTerminalCommandHistory(try decoder.decode(TerminalCommandHistoryRecord.self, from: payload))
            result = "{}"
        case .updateWorktreeBinding:
            let request = try decoder.decode(RuntimeWorktreeBindingMutation.self, from: payload)
            try repository.updateWorktreeBinding(
                sessionID: mutation.sessionID,
                branch: request.branch,
                worktreePath: request.worktreePath,
                baselineRevision: request.baselineRevision
            )
            result = "{}"
        case .saveWorktree:
            try repository.saveWorktree(try decoder.decode(WorktreeRecord.self, from: payload))
            result = "{}"
        }

        _ = try SessionEventCommitter(repository: repository).commit(SessionEventDraft(
            aggregateID: mutation.sessionID,
            commandID: receiptCommandID,
            causationID: mutation.commandID,
            correlationID: mutation.sessionID,
            kind: SessionEventKind(rawValue: "runtime_mutation_applied"),
            payload: ["kind": mutation.kind.rawValue, "result": SecretRedactor.redact(result)]
        ))
        return result
    }

    public func recordRuntimeEvent(
        sessionID: String,
        type: String,
        payload: [String: String],
        commandID: String,
        causationID: String? = nil,
        correlationID: String? = nil
    ) throws {
        try ensureSession(sessionID)
        _ = try SessionEventCommitter(repository: repository).commit(SessionEventDraft(
            aggregateID: sessionID,
            commandID: "supervisor-event-\(commandID)",
            causationID: causationID,
            correlationID: correlationID ?? sessionID,
            kind: SessionEventKind(rawValue: type),
            payload: SecretRedactor.redact(payload)
        ))
    }

    public func persistRunState(_ state: AgentRunState) throws {
        try ensureSession(state.sessionID)
        try repository.saveRunState(state)
    }

    /// Validates the direct-terminal continuation and consumes allow-once
    /// approval through the same Supervisor audit chain as model tool calls.
    public func consumeDirectTerminalApproval(
        sessionID: String,
        approvalID: String?,
        risk: CommandRisk,
        commandHash: String
    ) throws -> Bool {
        guard let approvalID else { return false }
        guard let approval = try repository.approval(id: approvalID),
              approval.sessionID == sessionID,
              approval.tool == "terminal.exec",
              approval.risk == risk,
              approval.decision == .allowOnce || approval.decision == .allowSession,
              let data = approval.arguments.data(using: .utf8),
              let metadata = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              metadata["source"] as? String == "deepseekd-direct-terminal",
              metadata["commandHash"] as? String == commandHash else {
            throw HarnessSupervisorError.approvalAlreadyResolved
        }
        let consumed = try repository.events(sessionID: sessionID).contains {
            $0.type == "terminal_approval_consumed" && $0.payload["approvalID"] == approvalID
        }
        guard !consumed else { throw HarnessSupervisorError.approvalAlreadyResolved }
        if approval.decision == .allowOnce {
            try recordRuntimeEvent(
                sessionID: sessionID,
                type: "terminal_approval_consumed",
                payload: ["approvalID": approvalID, "decision": "allow_once"],
                commandID: "terminal-direct-consume-\(approvalID)",
                causationID: approvalID,
                correlationID: approvalID
            )
        }
        return true
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

    private func sessionBranchSlug(_ title: String) -> String {
        let normalized = title.lowercased().unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) ? Character(String(scalar)) : "-"
        }
        let compact = String(normalized).split(separator: "-", omittingEmptySubsequences: true).joined(separator: "-")
        return compact.isEmpty ? "session" : String(compact.prefix(48))
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

private struct RuntimeEventMutation: Codable, Sendable {
    let type: String
    let payload: [String: String]
    let commandID: String?
    let causationID: String?
    let correlationID: String?
}

private struct RuntimeCreateHandoffMutation: Codable, Sendable {
    let destination: HandoffDestination
    let baseRevision: String
}

private struct RuntimeHandoffFilesMutation: Codable, Sendable {
    let handoffID: String
    let files: [HandoffFileState]
}

private struct RuntimeHandoffStateMutation: Codable, Sendable {
    let handoffID: String
    let state: HandoffState
}

private struct RuntimeWorktreeBindingMutation: Codable, Sendable {
    let branch: String
    let worktreePath: String
    let baselineRevision: String
}
