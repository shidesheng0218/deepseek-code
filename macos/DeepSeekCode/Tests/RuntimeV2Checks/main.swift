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

private struct FixtureWebFetchProvider: WebFetchProvider {
    func fetch(url: URL, context: NetworkContext) async throws -> WebFetchResponse {
        let text = "Fixture web evidence"
        return WebFetchResponse(
            sourceID: "fixture-source",
            sourceURL: url.absoluteString,
            finalURL: url.absoluteString,
            title: "Fixture",
            contentType: "text/plain",
            statusCode: 200,
            contentHash: WebEvidenceInspector.sha256(text),
            extractedText: text,
            sections: [WebSection(id: "fixture-section", title: "Fixture", text: text)],
            citationCandidates: [CitationCandidate(id: "fixture-citation", sourceID: "fixture-source", quote: text, contentHash: WebEvidenceInspector.sha256(text))]
        )
    }
}

private struct RouterProbeToolHost: ToolHost {
    func execute(tool: RegisteredTool, argumentsJSON: String, sessionID: String) async throws -> String {
        "{\"ok\":true,\"source\":\"router-probe\"}"
    }

    func cancel(invocationID: String) async {}
}

@main
struct DeepSeekCodeRuntimeV2Checks {
    static func main() async throws {
        // The GUI must not retain disabled foreground-Agent source code. It
        // is too easy for an old call site to re-enable a second runtime.
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let workspaceStoreSource = try String(
            contentsOf: packageRoot.appendingPathComponent("Sources/DeepSeekCodeCore/WorkspaceStore.swift"),
            encoding: .utf8
        )
        precondition(!workspaceStoreSource.contains("#if false"))
        precondition(WorkspaceTypography.microSize >= 10)
        precondition(WorkspaceTypography.metaSize >= 12)
        precondition(WorkspaceTypography.bodySize >= 14)
        precondition(WorkspaceDesignTokens.sidebarIdealWidth >= 280)
        precondition(WorkspaceDesignTokens.inspectorIdealWidth >= 390)
        precondition(WorkspaceDesignTokens.filesTreeRowHeight >= 32)
        // Conversation text must never collapse into a one-character-wide
        // column when CJK text is rendered inside a flexible timeline row.
        precondition(WorkspaceDesignTokens.conversationMessageMinWidth >= 320)
        precondition(AgentResponseStyle.userFacingInstruction(mode: .acceptEdits).contains("像有经验的同事"))
        precondition(AgentResponseStyle.userFacingInstruction(mode: .acceptEdits).contains("不要暴露内部工具名"))
        let mechanicalInternalResponse = ResponseQualityValidator.validate(
            "web_fetch 已完成，deepseek-v4-flash 输出 92 tokens。Delivered。",
            contract: ResponseContract(kind: .directAnswer, requiredSections: [], maximumParagraphs: 3),
            evidence: QualityEvidenceState()
        )
        precondition(!mechanicalInternalResponse.passed)
        precondition(!TaskContract.compatibility(prompt: "明天北京的天气如何").requiresDeliveryGate)
        precondition(TaskContract(goal: "修复登录", requiredChanges: ["App.swift"]).requiresDeliveryGate)
        // If one public HTML search endpoint is unavailable, the default
        // runtime must have a second no-key provider to try.
        let builtInSearchProviders = WebToolHost().searchProviders.map(\.id)
        precondition(builtInSearchProviders.contains("duckduckgo"))
        precondition(builtInSearchProviders.contains("bing"))
        let fixtureWebHost = WebToolHost(
            runtime: NetworkRuntime(policy: .default),
            fetchProvider: FixtureWebFetchProvider()
        )
        let fetchTool = AgentToolSchemas.registry.tool(named: "web_fetch")!
        let fixtureFetchOutput = try await fixtureWebHost.execute(
            tool: fetchTool,
            argumentsJSON: "{\"url\":\"https://example.com/docs\"}",
            sessionID: "fixture-session"
        )
        precondition(fixtureFetchOutput.contains("fixture-source"))
        // A direct-answer plan controls only the pre-tool fast path. Once a
        // model explicitly calls a read-only web tool it must advance to the
        // Research Grant / SSRF gate instead of being rejected by the
        // direct-answer preflight.
        let directPlan = TaskQualityPlanner.plan(route: TaskRouter.route(TaskRoutingInput(prompt: "Swift actor 是什么？", mode: .acceptEdits)))
        let explicitWebSearch = RegisteredTool(name: "web_search", description: "search", parameters: .object([:]), effect: .network, risk: .l2, timeoutMilliseconds: 10_000, maxOutputBytes: 32_000, idempotent: true, supportsCancellation: true)
        precondition(ToolDecisionPolicy.decide(for: explicitWebSearch, plan: directPlan, evidence: QualityEvidenceState()) == .execute)
        let unexpectedWrite = RegisteredTool(name: "apply_patch", description: "patch", parameters: .object([:]), effect: .workspaceWrite, risk: .l1, timeoutMilliseconds: 10_000, maxOutputBytes: 32_000, idempotent: false, supportsCancellation: true)
        precondition(ToolDecisionPolicy.decide(for: unexpectedWrite, plan: directPlan, evidence: QualityEvidenceState()) == .requestApproval(.l1))
        precondition(WebSearchRequest(query: "Swift actor", maxResults: 99).maxResults == 8)
        precondition(ToolPresentationResolver.presentation(for: "web_search").title == "联网搜索")
        precondition(ToolPresentationResolver.presentation(for: "terminal.exec").title == "终端命令")
        // The router is a pure host dispatcher. Durable lifecycle and
        // evidence events belong to ToolExecutionPipeline, never to the
        // transport/router layer.
        let routerRegistry = ToolRegistry()
        let routerTool = RegisteredTool(
            name: "router_probe",
            description: "router probe",
            parameters: .object([:]),
            effect: .readOnly,
            risk: .l0,
            timeoutMilliseconds: 1_000,
            maxOutputBytes: 1_024,
            idempotent: true,
            supportsCancellation: true
        )
        routerRegistry.register(routerTool)
        let pureRouter = ToolHostRouter(registry: routerRegistry)
        pureRouter.register(host: RouterProbeToolHost(), for: "router_probe")
        let routed = try await pureRouter.execute(tool: routerTool, argumentsJSON: "{}", sessionID: "router-probe-session")
        precondition(routed.contains("router-probe"))
        precondition(pureRouter.invocationEvents.isEmpty)
        let fetchContract = try WebContentExtractor.extract(
            data: Data(String(repeating: "x", count: 50_000).utf8),
            contentType: "text/plain",
            sourceID: "fetch-contract",
            sourceURL: "https://example.com/source",
            statusCode: 200
        )
        precondition(fetchContract.extractedText.count == 50_000)
        let continuation = ApprovalContinuation(
            approvalID: "approval-1",
            sessionID: "session-1",
            commandID: "command-1",
            callID: "call-1",
            tool: "terminal.exec",
            argumentsJSON: "{\"command\":\"pwd\"}",
            risk: .l0
        )
        precondition(continuation.matches(sessionID: "session-1", callID: "call-1", tool: "terminal.exec", argumentsJSON: "{\"command\":\"pwd\"}"))
        precondition(!continuation.matches(sessionID: "session-1", callID: "call-1", tool: "terminal.exec", argumentsJSON: "{\"command\":\"whoami\"}"))
        // GUI delegates only fully daemon-capable tasks. Browser/attachments,
        // SSH and configured extension hosts stay on the foreground path
        // until those capabilities have an equivalent durable daemon host.
        precondition(DaemonExecutionEligibility.isEligible(
            target: .local,
            parts: [.text("读取项目结构")],
            route: TaskRouter.route(TaskRoutingInput(prompt: "读取项目结构", mode: .acceptEdits, hasProject: true)),
            hasEnabledHooks: false,
            hasEnabledMCP: false
        ))
        precondition(!DaemonExecutionEligibility.isEligible(
            target: .ssh,
            parts: [.text("读取项目结构")],
            route: TaskRouter.route(TaskRoutingInput(prompt: "读取项目结构", mode: .acceptEdits, hasProject: true)),
            hasEnabledHooks: false,
            hasEnabledMCP: false
        ))
        precondition(!DaemonExecutionEligibility.isEligible(
            target: .local,
            parts: [.text("打开浏览器验证")],
            route: TaskRouter.route(TaskRoutingInput(prompt: "打开浏览器验证", mode: .acceptEdits, hasProject: true)),
            hasEnabledHooks: false,
            hasEnabledMCP: false
        ))
        precondition(!DaemonExecutionEligibility.isEligible(
            target: .local,
            parts: [.text("读取项目结构")],
            route: TaskRouter.route(TaskRoutingInput(prompt: "读取项目结构", mode: .acceptEdits, hasProject: true)),
            hasEnabledHooks: true,
            hasEnabledMCP: false
        ))
        let liveMarketRoute = TaskRouter.route(TaskRoutingInput(prompt: "今天股市行情怎么样？", mode: .acceptEdits))
        precondition(liveMarketRoute.kind == .research)
        precondition(liveMarketRoute.needsResearch)
        precondition(TaskQualityPlanner.plan(route: liveMarketRoute).requiresCitations)
        // Provider reasoning is retained in the durable event log for audit,
        // but it is not a user-facing chat message.
        let visibleParts = SessionPartProjector.project(events: [
            SessionEvent(sequence: 1, type: "user_message", payload: ["text": "今天股市行情怎么样？"]),
            SessionEvent(sequence: 2, type: "assistant_reasoning", payload: ["text": "internal analysis"]),
            SessionEvent(sequence: 3, type: "tool_requested", payload: ["tool": "web_search", "callID": "weather-search"]),
            SessionEvent(sequence: 4, type: "tool_completed", payload: ["tool": "web_search", "callID": "weather-search", "ok": "true"]),
            SessionEvent(sequence: 5, type: "assistant_text", payload: ["text": "我正在查询最新行情。"])
        ])
        precondition(!visibleParts.contains { $0.kind == .reasoning })
        // Tool executions remain durable Session Parts for Evidence, but the
        // default conversation must not expose internal names such as
        // web_search / web_fetch as chat cards.
        precondition(visibleParts.contains { $0.kind == .toolCall && $0.title == "联网搜索" })
        let primaryConversation = ConversationProjector.timeline(parts: visibleParts)
        precondition(primaryConversation.map(\.kind) == [.user, .assistant])
        precondition(primaryConversation.map(\.text) == ["今天股市行情怎么样？", "我正在查询最新行情。"])
        let noisyRuntimeConversation = ConversationProjector.timeline(events: [
            SessionEvent(sequence: 1, type: "user_message", payload: ["text": "明天北京的天气如何"]),
            SessionEvent(sequence: 2, type: "tool_requested", payload: ["tool": "web_fetch", "callID": "fetch-1"]),
            SessionEvent(sequence: 3, type: "tool_completed", payload: ["tool": "web_fetch", "callID": "fetch-1", "ok": "true"]),
            SessionEvent(sequence: 4, type: "web_search_completed", payload: ["query": "北京天气", "providerID": "bing", "resultCount": "0", "succeeded": "true"]),
            SessionEvent(sequence: 5, type: "web_fetch_completed", payload: ["url": "https://weather.com.cn", "status": "200", "succeeded": "true"]),
            SessionEvent(sequence: 6, type: "usage_recorded", payload: ["model": "deepseek-v4-flash", "output": "93"]),
            SessionEvent(sequence: 7, type: "assistant_text", payload: ["text": "目前没拿到可靠天气源，我建议换一个公开天气源再查。"]),
            SessionEvent(sequence: 8, type: "verification_gate_evaluated", payload: ["passed": "false", "missing": "Browser|CI"])
        ])
        precondition(noisyRuntimeConversation.map(\.kind) == [.user, .assistant])
        precondition(!noisyRuntimeConversation.contains { $0.text.contains("web_fetch") || $0.title.contains("交付门禁") || $0.text.contains("tokens") })
        // A failed tool card must retain a localized, actionable diagnostic
        // instead of collapsing every failure into the unhelpful “执行失败”.
        let failedSearchParts = SessionPartProjector.project(events: [
            SessionEvent(sequence: 1, type: "tool_requested", payload: ["tool": "web_search", "callID": "search-1"]),
            SessionEvent(sequence: 2, type: "tool_completed", payload: [
                "tool": "web_search",
                "callID": "search-1",
                "ok": "false",
                "code": "SEARCH_PROVIDER_UNAVAILABLE",
                "message": "搜索服务暂时不可用，请稍后重试。"
            ])
        ])
        precondition(failedSearchParts.last?.state == .failed)
        precondition(failedSearchParts.last?.text == "搜索服务暂时不可用，请稍后重试。")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("deepseek-runtime-v2-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let claudeRoot = root.appendingPathComponent("claude-project", isDirectory: true)
        let claudeFeature = claudeRoot.appendingPathComponent("Sources/Feature", isDirectory: true)
        try FileManager.default.createDirectory(at: claudeFeature, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: claudeRoot.appendingPathComponent(".claude/agents", isDirectory: true), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: claudeRoot.appendingPathComponent(".claude/skills/review", isDirectory: true), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: claudeRoot.appendingPathComponent(".claude/hooks", isDirectory: true), withIntermediateDirectories: true)
        try Data("root rule".utf8).write(to: claudeRoot.appendingPathComponent("CLAUDE.md"))
        try Data("feature rule".utf8).write(to: claudeFeature.appendingPathComponent("AGENTS.md"))
        try Data("{\"permissions\":{\"allow\":[\"Bash(git status)\"],\"ask\":[\"Bash(npm install)\"],\"deny\":[\"Bash(rm -rf /)\"]},\"model\":\"claude-fixture\",\"unknownSetting\":true}".utf8).write(to: claudeRoot.appendingPathComponent(".claude/settings.json"))
        try Data("---\nname: reviewer\ndescription: Review only\nmodel: fast\ntools: read_file,search_workspace\npermissionMode: plan\nmaxTurns: 4\n---\nRead-only review agent.".utf8).write(to: claudeRoot.appendingPathComponent(".claude/agents/reviewer.md"))
        try Data("# Review Skill\nReview the diff.".utf8).write(to: claudeRoot.appendingPathComponent(".claude/skills/review/SKILL.md"))
        try Data("#!/bin/zsh\nprintf hook".utf8).write(to: claudeRoot.appendingPathComponent(".claude/hooks/preflight.sh"))
        try Data("{\"mcpServers\":{\"docs\":{\"command\":\"docs-mcp\",\"args\":[\"--stdio\"]}}}".utf8).write(to: claudeRoot.appendingPathComponent(".mcp.json"))
        let claudeCompatibility = try ClaudeCompatibilityLoader.load(workspaceRoot: claudeRoot, workingDirectory: claudeFeature)
        precondition(claudeCompatibility.instructions.text.contains("root rule"))
        precondition(claudeCompatibility.instructions.text.contains("feature rule"))
        precondition(claudeCompatibility.settings.allowPatterns == ["Bash(git status)"])
        precondition(claudeCompatibility.settings.askPatterns == ["Bash(npm install)"])
        precondition(claudeCompatibility.settings.denyPatterns == ["Bash(rm -rf /)"])
        precondition(claudeCompatibility.settings.unsupportedFields.contains("unknownSetting"))
        precondition(claudeCompatibility.agents.first?.name == "reviewer")
        precondition(claudeCompatibility.skills.contains { $0.id == "review" && $0.scope == "claude-project" })
        precondition(claudeCompatibility.hooks.first?.trusted == false)
        precondition(claudeCompatibility.mcpServers.first?.name == "docs")
        let discoveredClaudeSkills = try SkillCatalog.discover(projectDirectory: claudeRoot)
        precondition(discoveredClaudeSkills.contains { $0.id == "review" && $0.scope == "claude-project" })

        let repository = try SessionRepository(directory: root.appendingPathComponent("db", isDirectory: true))
        let project = try repository.createProject(name: "Runtime V2", path: root.path)
        let session = try repository.createSession(projectID: project.id, title: "Part projection", mode: .acceptEdits)
        let pipelineSession = try repository.createSession(projectID: project.id, title: "Pipeline projection", mode: .acceptEdits)
        // The execution pipeline, rather than the router, owns the durable
        // lifecycle and creates a traceable Evidence record for every tool.
        let pipelineRegistry = ToolRegistry([routerTool])
        let pipelineRouter = ToolHostRouter(registry: pipelineRegistry)
        pipelineRouter.register(host: RouterProbeToolHost(), for: "router_probe")
        let pipeline = ToolExecutionPipeline(repository: repository, router: pipelineRouter)
        let pipelineResult = try await pipeline.execute(
            ToolInvocationContext(
                sessionID: pipelineSession.id,
                commandID: "pipeline-command",
                callID: "pipeline-call",
                tool: routerTool,
                argumentsJSON: "{}"
            )
        )
        precondition(pipelineResult.succeeded)
        precondition(pipelineResult.evidenceID != nil)
        let pipelineEvents = try repository.events(sessionID: pipelineSession.id)
        precondition(pipelineEvents.map(\.type).suffix(4) == ["tool_requested", "tool_started", "evidence_recorded", "tool_completed"])
        let inboxInput = try repository.enqueueSessionInput(
            sessionID: session.id,
            idempotencyKey: "foreground-input",
            delivery: .immediate,
            parts: [.text("不要提前消费")]
        )
        let consumedBeforePromotion = try repository.consumePromotedSessionInput(id: inboxInput.id)
        precondition(!consumedBeforePromotion)
        let promotedInboxInput = try repository.promoteNextSessionInput(sessionID: session.id)
        precondition(promotedInboxInput?.id == inboxInput.id)
        let consumedAfterPromotion = try repository.consumePromotedSessionInput(id: inboxInput.id)
        let duplicateConsumption = try repository.consumePromotedSessionInput(id: inboxInput.id)
        precondition(consumedAfterPromotion)
        precondition(!duplicateConsumption)
        let casApproval = try repository.createApproval(sessionID: session.id, tool: "terminal.exec", risk: .l1, arguments: "{\"command\":\"pwd\"}")
        let firstResolution = try repository.resolvePendingApproval(id: casApproval.id, decision: .allowOnce)
        let duplicateResolution = try repository.resolvePendingApproval(id: casApproval.id, decision: .allowOnce)
        precondition(firstResolution)
        precondition(!duplicateResolution)
        let traceSession = try repository.createSession(projectID: project.id, title: "Delivery trace", mode: .acceptEdits)
        let harnessSession = try repository.createSession(projectID: project.id, title: "Harness supervisor", mode: .acceptEdits)

        let daemon = LocalHarnessDaemon(repository: repository, supervisor: SessionSupervisor(repository: repository, instanceID: "daemon-check"))
        let attach = try await daemon.attachSession(harnessSession.id)
        precondition(attach.sessionID == harnessSession.id)
        precondition(attach.eventCursor == 0)
        let recovered = try await daemon.recoverAll()
        precondition(recovered.contains { $0.sessionID == harnessSession.id })

        // Runtime ownership is durable rather than an ephemeral GUI worker
        // card. A Session may change from deepseekd to the foreground App
        // when it needs a capability the daemon does not host yet; after a
        // restart, approvals must be sent to that most recent owner.
        precondition(SessionRuntimeOwnership.owner(sessionID: harnessSession.id, repository: repository) == nil)
        try SessionRuntimeOwnership.assign(
            .daemon,
            sessionID: harnessSession.id,
            repository: repository,
            instanceID: "daemon-fixture",
            commandID: "runtime-owner-daemon-fixture"
        )
        precondition(SessionRuntimeOwnership.owner(sessionID: harnessSession.id, repository: repository) == .daemon)
        try SessionRuntimeOwnership.assign(
            .foregroundApp,
            sessionID: harnessSession.id,
            repository: repository,
            instanceID: "app-fixture",
            commandID: "runtime-owner-app-fixture"
        )
        precondition(SessionRuntimeOwnership.owner(sessionID: harnessSession.id, repository: repository) == .foregroundApp)

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
        let admittedUserMessages = try repository.events(sessionID: harnessSession.id).filter { $0.type == "user_message" }
        precondition(admittedUserMessages.count == 1)
        precondition(admittedUserMessages.first?.payload["text"] == "执行 Harness 验收")
        precondition(admittedUserMessages.first?.payload["inputID"] == admitted.inputID)
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
        precondition(ConversationProjector.timeline(parts: parts?.parts ?? []).map(\.kind) == [.user, .assistant])

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
        precondition(storedChild?.state == .awaitingAdoption)
        try await childRuntime.adopt(workerSessionID: child.id)
        let adoptedChild = try repository.workerSession(id: child.id)
        precondition(adoptedChild?.state == .completed)

        let workerRoot = root.appendingPathComponent("worker-root", isDirectory: true)
        try FileManager.default.createDirectory(at: workerRoot.appendingPathComponent("Sources", isDirectory: true), withIntermediateDirectories: true)
        try Data("# Worker fixture\n".utf8).write(to: workerRoot.appendingPathComponent("README.md"))
        try Data("struct Fixture {}\n".utf8).write(to: workerRoot.appendingPathComponent("Sources/Fixture.swift"))
        let workerHelperResult = try await WorkerHelperService.execute(WorkerHelperRequest(
            workerSessionID: "helper-explore",
            sessionID: session.id,
            workerID: "explore-helper",
            workspaceRoot: workerRoot.path,
            contract: WorkerSessionContract(parentSessionID: session.id, workerKind: .explore, objective: "概览项目结构")
        ))
        let workerEnvelope = try unwrap(workerHelperResult.result)
        precondition(workerEnvelope.evidenceIDs.count == 1)
        precondition(workerEnvelope.summary.contains("README.md"))
        precondition(workerEnvelope.outputHash.count == 64)

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
        let knownFetchGrant = await network.hasResearchReadGrant(capability: .webFetch, sessionID: session.id, projectID: project.id, url: URL(string: "https://react.dev/reference/react/useEffect")!)
        let unknownFetchGrant = await network.hasResearchReadGrant(capability: .webFetch, sessionID: session.id, projectID: project.id, url: URL(string: "https://swift.org/documentation/")!)
        precondition(knownFetchGrant)
        precondition(!unknownFetchGrant)
        // Public read-only research should be low-friction: search and fetch
        // can both proceed automatically for safe public URLs, while the base
        // SSRF/private-network policy still blocks unsafe destinations.
        _ = await network.autoGrantResearchReadOnly(sessionID: traceSession.id, projectID: project.id)
        let publicSearch = await network.authorize(url: URL(string: "https://www.swift.org/documentation/")!, capability: .webSearch, operation: .read, sessionID: traceSession.id, projectID: project.id)
        let publicFetch = await network.authorize(url: URL(string: "https://www.swift.org/documentation/")!, capability: .webFetch, operation: .read, sessionID: traceSession.id, projectID: project.id)
        let privateFetch = await network.authorize(url: URL(string: "http://127.0.0.1:8080/private")!, capability: .webFetch, operation: .read, sessionID: traceSession.id, projectID: project.id)
        precondition(publicSearch == .allow)
        precondition(publicFetch == .allow)
        precondition(privateFetch == .block)
        print("DeepSeek Runtime V2 checks passed")
    }
}

private struct RuntimeV2StaticMCPTransport: MCPTransport {
    let response: String

    func request(_ request: MCPJSONRPCRequest) async throws -> MCPJSONRPCResponse {
        try MCPJSONRPCResponse.decode(line: response)
    }
}

private func unwrap<T>(_ value: T?) throws -> T {
    guard let value else { throw NSError(domain: "DeepSeekRuntimeV2Checks", code: 1) }
    return value
}
