import Foundation
import DeepSeekCodeCore

actor HarnessProbeDriver: SessionExecutionDriver {
    private(set) var started: [String] = []
    private(set) var paused: [String] = []
    private(set) var resumed: [String] = []
    private(set) var cancelled: [String] = []
    private(set) var approvalResumptions: [(String, String, ApprovalDecision)] = []

    func start(sessionID: String) async throws {
        started.append(sessionID)
    }

    func pause(sessionID: String) async throws {
        paused.append(sessionID)
    }

    func resume(sessionID: String) async throws {
        resumed.append(sessionID)
    }

    func cancel(sessionID: String) async throws {
        cancelled.append(sessionID)
    }

    func resolveApproval(sessionID: String, approvalID: String, decision: ApprovalDecision) async throws {
        approvalResumptions.append((sessionID, approvalID, decision))
    }

    func snapshot() -> (started: [String], paused: [String], resumed: [String], cancelled: [String], approvalResumptions: [(String, String, ApprovalDecision)]) {
        (started, paused, resumed, cancelled, approvalResumptions)
    }
}

actor ClosureDriverProbe {
    private(set) var events: [String] = []
    func record(_ value: String) { events.append(value) }
    func snapshot() -> [String] { events }
}

actor WorkerProbeDriver: ChildAgentExecutionDriver {
    func execute(contract: WorkerSessionContract, sessionID: String, workerID: String, workerSessionID: String) async throws -> WorkerResultEnvelope {
        WorkerResultEnvelope(
            workerID: workerID,
            sessionID: sessionID,
            summary: "只读 Worker 已完成",
            evidenceIDs: ["worker-evidence-1"],
            inputHash: "input-hash",
            outputHash: "output-hash"
        )
    }
}

struct BenchmarkFixtureProbe: HarnessBenchmarkFixture {
    let id: String
    let title: String
    func run() async throws -> HarnessBenchmarkResult {
        HarnessBenchmarkResult(fixtureID: id, title: title, passed: true, durationMilliseconds: 1, evidenceIDs: ["fixture-evidence"], failure: nil)
    }
}

@main
struct DeepSeekCodeRuntimeV2Checks {
    static func main() async throws {
        precondition(WorkspaceTypography.microSize >= 10)
        precondition(WorkspaceTypography.metaSize >= 12)
        precondition(WorkspaceTypography.bodySize >= 14)
        precondition(WorkspaceDesignTokens.sidebarIdealWidth >= 280)
        precondition(WorkspaceDesignTokens.inspectorIdealWidth >= 390)
        precondition(WorkspaceDesignTokens.filesTreeRowHeight >= 32)
        // Conversation text must never collapse into a one-character-wide
        // column when CJK text is rendered inside a flexible timeline row.
        precondition(WorkspaceDesignTokens.conversationMessageMinWidth >= 320)
        // If one public HTML search endpoint is unavailable, the default
        // runtime must have a second no-key provider to try.
        let builtInSearchProviders = WebToolHost().searchProviders.map(\.id)
        precondition(builtInSearchProviders.contains("duckduckgo"))
        precondition(builtInSearchProviders.contains("bing"))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("deepseek-runtime-v2-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let repository = try SessionRepository(directory: root.appendingPathComponent("db", isDirectory: true))
        let project = try repository.createProject(name: "Runtime V2", path: root.path)
        let session = try repository.createSession(projectID: project.id, title: "Part projection", mode: .acceptEdits)
        let traceSession = try repository.createSession(projectID: project.id, title: "Delivery trace", mode: .acceptEdits)
        let harnessSession = try repository.createSession(projectID: project.id, title: "Harness supervisor", mode: .acceptEdits)

        let daemon = LocalHarnessDaemon(repository: repository, supervisor: SessionSupervisor(repository: repository, instanceID: "daemon-check"))
        let attach = try await daemon.attachSession(harnessSession.id)
        precondition(attach.sessionID == harnessSession.id)
        precondition(attach.eventCursor == 0)
        let recovered = try await daemon.recoverAll()
        precondition(recovered.contains { $0.sessionID == harnessSession.id })

        let traceEvents = [
            SessionEvent(sessionID: session.id, sequence: 1, type: "terminal_started", payload: ["terminalID": "term-1"]),
            SessionEvent(sessionID: session.id, sequence: 2, type: "terminal_portDiscovered", payload: ["terminalID": "term-1", "port": "5173"]),
            SessionEvent(sessionID: session.id, sequence: 3, type: "browser_evidence_recorded", payload: ["browserSessionID": "browser-1"]),
            SessionEvent(sessionID: session.id, sequence: 4, type: "evidence_recorded", payload: ["id": "test-1", "kind": "test", "title": "npm test", "succeeded": "true"]),
            SessionEvent(sessionID: session.id, sequence: 5, type: "github_ci_evidence", payload: ["deliveryID": "delivery-1", "state": "passed"])
        ]
        let trace = DeliveryTrace.project(sessionID: session.id, events: traceEvents)
        precondition(trace.terminalIDs == ["term-1"])
        precondition(trace.ports == [5173])
        precondition(trace.browserEvidenceIDs == ["browser-1"])
        precondition(trace.testEvidenceIDs == ["test-1"])
        precondition(trace.ciRunIDs == ["delivery-1"])
        for event in traceEvents {
            _ = try repository.appendDurable(sessionID: traceSession.id, type: event.type, payload: event.payload, commandID: "fixture-trace-\(event.sequence)")
        }
        try repository.saveTaskContract(TaskContract.compatibility(prompt: "trace gate"), sessionID: traceSession.id)
        let traceSupervisor = SessionSupervisor(repository: repository, instanceID: "trace-gate")
        _ = try await traceSupervisor.evaluateDelivery(sessionID: traceSession.id)
        let traceGateEvent = try repository.events(sessionID: traceSession.id).last { $0.type == "verification_gate_evaluated" }
        precondition(traceGateEvent?.payload["deliveryTrace"]?.contains("term-1") == true)

        let manifest = HostCapabilityManifest(hostID: "fixture", allowedPaths: [root.path], allowedDomains: ["react.dev"], allowedEffects: [.readOnly], allowedEnvironmentKeys: ["PATH"], maxOutputBytes: 1_024, timeoutMilliseconds: 1_000)
        precondition(manifest.allows(effect: .readOnly, path: root.appendingPathComponent("file.txt").path, domain: "react.dev", environmentKey: "PATH"))
        precondition(!manifest.allows(effect: .workspaceWrite, path: root.path, domain: "react.dev", environmentKey: "PATH"))
        precondition(!manifest.allows(effect: .readOnly, path: "/tmp/outside", domain: "evil.test", environmentKey: "SECRET"))

        // A capability manifest must be enforced by every extension/process
        // host, rather than remaining an advisory data model.
        let deniedMCP = MCPToolHost(
            serverID: "blocked",
            transport: RuntimeV2StaticMCPTransport(response: "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{}}"),
            manifest: HostCapabilityManifest(hostID: "mcp.blocked", allowedEffects: [.readOnly])
        )
        let externalMCPTool = RegisteredTool(
            name: "mcp.blocked.publish",
            description: "external write",
            parameters: .objectSchema(),
            effect: .externalWrite,
            risk: .l2,
            timeoutMilliseconds: 1_000,
            maxOutputBytes: 1_024,
            idempotent: false,
            supportsCancellation: true
        )
        do {
            _ = try await deniedMCP.execute(tool: externalMCPTool, argumentsJSON: "{}", sessionID: session.id)
            preconditionFailure("MCP capability manifest allowed an external write")
        } catch HostCapabilityError.denied {
            // Expected: manifest is an enforcement boundary.
        }

        let deniedHook = HookDefinition(id: "blocked-hook", lifecycle: .preToolUse, command: "printf hook", trusted: true)
        do {
            _ = try await HookRunner.execute(
                deniedHook,
                payload: [:],
                manifest: HostCapabilityManifest(hostID: "hook.blocked", allowedEffects: [.readOnly])
            )
            preconditionFailure("Hook capability manifest allowed a process")
        } catch HostCapabilityError.denied {
            // Expected: hook commands are process effects.
        }

        let pluginRecord = PluginInstallRecord(
            manifest: PluginManifest(id: "fixture.plugin", name: "Fixture", version: "1", capabilities: [.provideMCP]),
            sourcePath: root.appendingPathComponent("plugin", isDirectory: true).path,
            contentHash: "fixture",
            state: .enabled
        )
        precondition(!PluginCapabilityBroker.allows(
            PluginCapabilityRequest(pluginID: pluginRecord.id, capability: .provideMCP, sessionID: session.id, argumentsHash: "fixture"),
            record: pluginRecord,
            manifest: HostCapabilityManifest(hostID: "plugin.blocked", allowedEffects: [.readOnly])
        ))

        let benchmark = try await HarnessBenchmarkRunner(fixtures: [
            BenchmarkFixtureProbe(id: "fixture-1", title: "Direct answer"),
            BenchmarkFixtureProbe(id: "fixture-2", title: "Research")
        ]).run()
        precondition(benchmark.total == 2)
        precondition(benchmark.passed == 2)

        // Harness 2.0 contract: all mutating lifecycle commands go through
        // the durable Supervisor and remain idempotent across retries.
        let probe = HarnessProbeDriver()
        let supervisor = SessionSupervisor(repository: repository, executionDriver: probe, instanceID: "runtime-v2-check")
        let closureProbe = ClosureDriverProbe()
        let closureDriver = ClosureSessionExecutionDriver(
            onStart: { _ in await closureProbe.record("start") },
            onPause: { _ in await closureProbe.record("pause") },
            onResume: { _ in await closureProbe.record("resume") },
            onResolveApproval: { _, _, _ in await closureProbe.record("approval") },
            onCancel: { _ in await closureProbe.record("cancel") }
        )
        try await closureDriver.start(sessionID: session.id)
        try await closureDriver.pause(sessionID: session.id)
        try await closureDriver.resume(sessionID: session.id)
        try await closureDriver.resolveApproval(sessionID: session.id, approvalID: "closure-approval", decision: .allowOnce)
        try await closureDriver.cancel(sessionID: session.id)
        let closureEvents = await closureProbe.snapshot()
        precondition(closureEvents == ["start", "pause", "resume", "approval", "cancel"])
        let admitted = try await supervisor.admit(SessionInput(
            sessionID: harnessSession.id,
            idempotencyKey: "harness-input-1",
            delivery: .immediate,
            parts: [.text("执行 Harness 验收")]
        ))
        let admittedAgain = try await supervisor.admit(SessionInput(
            sessionID: harnessSession.id,
            idempotencyKey: "harness-input-1",
            delivery: .immediate,
            parts: [.text("不得重复执行")]
        ))
        precondition(admitted.inputID == admittedAgain.inputID)
        try await supervisor.start(sessionID: harnessSession.id)
        try await supervisor.pause(sessionID: harnessSession.id)
        try await supervisor.resume(sessionID: harnessSession.id)
        try await supervisor.cancel(sessionID: harnessSession.id)
        let probeSnapshot = await probe.snapshot()
        precondition(probeSnapshot.started == [harnessSession.id])
        precondition(probeSnapshot.paused == [harnessSession.id])
        precondition(probeSnapshot.resumed == [harnessSession.id])
        precondition(probeSnapshot.cancelled == [harnessSession.id])
        let approval = try repository.createApproval(sessionID: harnessSession.id, tool: "run_command", risk: .l2, arguments: "{\"command\":\"npm test\"}")
        try await supervisor.resolveApproval(sessionID: harnessSession.id, approvalID: approval.id, decision: .allowOnce)
        let approvalEvents = try repository.events(sessionID: harnessSession.id)
        precondition(approvalEvents.contains { $0.type == "approval_resolved" && $0.payload["approvalID"] == approval.id })
        let resumedAfterApproval = await probe.snapshot()
        precondition(resumedAfterApproval.resumed.count == 1)
        precondition(resumedAfterApproval.approvalResumptions.count == 1)
        precondition(resumedAfterApproval.approvalResumptions[0].1 == approval.id)
        let supervisorEvents = try repository.events(sessionID: harnessSession.id)
        precondition(supervisorEvents.contains { $0.type == "harness_command_admitted" })
        precondition(supervisorEvents.contains { $0.type == "harness_started" })
        precondition(supervisorEvents.contains { $0.type == "harness_paused" })
        precondition(supervisorEvents.contains { $0.type == "harness_resumed" })
        precondition(supervisorEvents.contains { $0.type == "harness_cancelled" })

        _ = try repository.appendDurable(sessionID: session.id, type: "user_message", payload: ["text": "检查运行时"])
        _ = try repository.appendDurable(sessionID: session.id, type: "assistant_text", payload: ["text": "已读取"])
        _ = try repository.appendDurable(sessionID: session.id, type: "tool_requested", payload: ["tool": "read_file", "callID": "read-1"])
        _ = try repository.appendDurable(sessionID: session.id, type: "tool_completed", payload: ["tool": "read_file", "callID": "read-1", "ok": "true"])
        let parts = try repository.sessionParts(sessionID: session.id)
        precondition(parts?.parts.map(\.kind) == [.user, .assistantText, .toolCall])
        precondition(parts?.parts.last?.state == .completed)
        precondition(ConversationProjector.timeline(parts: parts?.parts ?? []).count == 3)

        let coordinator = WorkerSessionCoordinator(repository: repository)
        do {
            _ = try coordinator.create(
                parentSessionID: session.id,
                workerID: "unsafe-worker",
                contract: WorkerSessionContract(parentSessionID: session.id, workerKind: .review, objective: "must fail", allowedEffects: [.workspaceWrite])
            )
            preconditionFailure("read-only worker accepted a write capability")
        } catch WorkerSessionError.effectNotAllowed {
            // Expected: a child worker cannot broaden its effect surface.
        }
        let contract = WorkerSessionContract(parentSessionID: session.id, workerKind: .review, objective: "Read-only review")
        let worker = try coordinator.create(parentSessionID: session.id, workerID: "review-worker", contract: contract)
        let adopted = try coordinator.adopt(id: worker.id, result: WorkerResultEnvelope(workerID: "review-worker", sessionID: session.id, summary: "No P1 findings", evidenceIDs: ["review-1"], outputHash: "sha256"))
        precondition(adopted.state == .completed)

        let childRuntime = DurableChildAgentRuntime(repository: repository, driver: WorkerProbeDriver())
        let child = try await childRuntime.create(
            parentSessionID: session.id,
            workerID: "explore-child",
            contract: WorkerSessionContract(parentSessionID: session.id, workerKind: .explore, objective: "读取项目结构")
        )
        try await childRuntime.start(workerSessionID: child.id)
        let childResult = try await childRuntime.collect(workerSessionID: child.id)
        precondition(childResult.summary == "只读 Worker 已完成")
        let storedChild = try repository.workerSession(id: child.id)
        precondition(storedChild?.state == .completed)

        let planTools = ToolAvailabilityResolver.resolve(providerCapabilities: .deepSeekTextOnly, agentMode: .plan, workerKind: .main, target: .local, projectTrusted: true, sandboxAvailable: true)
        precondition(planTools.contains(where: { $0.name == "read_file" }))
        precondition(!planTools.contains(where: { $0.name == "apply_patch" }))

        let source = root.appendingPathComponent("Sources/App.swift")
        try FileManager.default.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("let token = \"ds-not-a-real-token\"\nprint(\"ok\")\n".utf8).write(to: source)
        let workspace = try WorkspaceToolHost(root: root, checkpointDirectory: root.appendingPathComponent("checkpoints", isDirectory: true))
        let evidence = try workspace.readEvidence(path: "Sources/App.swift", sessionID: session.id, startLine: 1, maxLines: 2)
        precondition(evidence.contentHash.count == 64)
        precondition(evidence.path == "Sources/App.swift")

        let route = try ProviderRouteResolver.resolve(profile: .defaultDeepSeek)
        let canonical = CanonicalLLMRequest(providerID: route.providerID, model: route.model, messages: [CanonicalMessage(role: .user, parts: [.text("ping")])], generation: GenerationPolicy(maxTokens: 16))
        let lowered = try ProviderRouteResolver.lower(canonical, route: route)
        precondition(lowered is ChatRequest)

        let autoResearch = ResearchGrant(
            sessionID: session.id,
            projectID: project.id,
            allowedDomains: ["react.dev"],
            capabilities: [.webSearch, .webFetch],
            expiresAt: Date().addingTimeInterval(600),
            autoRenewReadOnly: true
        )
        precondition(autoResearch.allows(url: URL(string: "https://react.dev/reference/react/useEffect")!, capability: .webFetch, operation: .read))
        precondition(!autoResearch.allows(url: URL(string: "https://react.dev")!, capability: .browser, operation: .read))
        let network = NetworkRuntime(policy: .default, repository: repository)
        let installedGrant = await network.autoGrantResearchReadOnly(sessionID: session.id, projectID: project.id, allowedDomains: ["react.dev"])
        precondition(installedGrant.autoRenewReadOnly)
        let allowedResearchURL = await network.authorize(url: URL(string: "https://react.dev/reference/react/useEffect")!, capability: .webFetch, operation: .read, sessionID: session.id, projectID: project.id)
        let blockedPrivateURL = await network.authorize(url: URL(string: "http://127.0.0.1:8080")!, capability: .webFetch, operation: .read, sessionID: session.id, projectID: project.id)
        precondition(allowedResearchURL == .allow)
        precondition(blockedPrivateURL == .block)
        print("DeepSeek Runtime V2 checks passed")
    }
}

private struct RuntimeV2StaticMCPTransport: MCPTransport {
    let response: String

    func request(_ request: MCPJSONRPCRequest) async throws -> MCPJSONRPCResponse {
        try MCPJSONRPCResponse.decode(line: response)
    }
}
