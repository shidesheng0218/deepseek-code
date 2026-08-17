import Foundation
import DeepSeekCodeCore

private final class ScriptedChatClient: ChatStreaming, @unchecked Sendable {
    private let batches: [[ProviderStreamEvent]]
    private let lock = NSLock()
    private var index = 0

    init(batches: [[ProviderStreamEvent]]) {
        self.batches = batches
    }

    func stream(_ request: ChatRequest) -> AsyncThrowingStream<ProviderStreamEvent, Error> {
        lock.lock()
        let batch = index < batches.count ? batches[index] : [.done]
        index += 1
        lock.unlock()
        return AsyncThrowingStream { continuation in
            for event in batch { continuation.yield(event) }
            continuation.finish()
        }
    }
}

private struct MemoryToolHost: ToolHost {
    func execute(tool: RegisteredTool, argumentsJSON: String, sessionID: String) async throws -> String {
        "{\"ok\":true,\"query\":\"Swift actor\",\"provider\":\"fixture\",\"results\":[]}"
    }

    func cancel(invocationID: String) async {}
}

private struct FailingSearchToolHost: ToolHost {
    func execute(tool: RegisteredTool, argumentsJSON: String, sessionID: String) async throws -> String {
        throw UnifiedRuntimeError.remote("搜索服务暂时不可用，请稍后重试。")
    }

    func cancel(invocationID: String) async {}
}

@main
struct DeepSeekCodeHarnessChecks {
    static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("deepseek-harness-checks-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let repository = try SessionRepository(directory: root.appendingPathComponent("Database", isDirectory: true))
        let agentSupervisor = SessionSupervisor(repository: repository, instanceID: "harness-check-agent-supervisor")
        let project = try repository.createProject(name: "Harness", path: root.path)
        let session = try repository.createSession(projectID: project.id, title: "Public search", mode: .acceptEdits)
        let events = try EventStore(directory: root.appendingPathComponent("LegacyEvents", isDirectory: true))
        let network = NetworkRuntime(policy: .default, repository: repository)
        let webSearch = try unwrap(AgentToolSchemas.registry.tool(named: "web_search"))
        let webFetch = try unwrap(AgentToolSchemas.registry.tool(named: "web_fetch"))
        let registry = ToolRegistry([webSearch, webFetch])
        let router = ToolHostRouter(registry: registry, repository: repository)
        let memoryWebHost = MemoryToolHost()
        router.register(host: memoryWebHost, for: "web_search")
        router.register(host: memoryWebHost, for: "web_fetch")
        let host = NativeAgentHost(
            client: ScriptedChatClient(batches: [
                [.toolCall(id: "public-search", name: "web_search", argumentsJSON: "{\"query\":\"Swift actor\"}"), .done],
                [.textDelta("搜索完成。"), .done]
            ]),
            eventStore: events,
            repository: repository,
            runtimeSupervisor: agentSupervisor,
            toolRouter: router,
            toolRegistry: registry,
            networkRuntime: network
        )

        var received: [AgentEvent] = []
        for try await event in host.run(AgentRunRequest(sessionID: session.id, prompt: "Swift actor 是什么？", mode: .acceptEdits, model: "deepseek-chat")) {
            received.append(event)
        }

        precondition(!received.contains { if case .approvalRequired = $0 { return true }; return false })
        precondition(received.contains(.toolCompleted(name: "web_search", succeeded: true)))
        let audit = try repository.events(sessionID: session.id)
        precondition(audit.contains { $0.type == "web_research_auto_grant_created" })
        let runtime3Audit = try repository.eventEnvelopes(sessionID: session.id)
        precondition(runtime3Audit.filter { $0.kind == .turnStarted }.count == 1)
        precondition(runtime3Audit.filter { $0.kind == .stepStarted }.count == 2)
        precondition(runtime3Audit.filter { $0.kind == .modelRequestStarted }.count == 2)
        precondition(runtime3Audit.filter { $0.kind == .assistantMessageCommitted }.count == 2)
        precondition(runtime3Audit.filter { $0.kind == .stepEnded }.count == 2)
        precondition(runtime3Audit.filter { $0.kind == .turnEnded }.count == 1)
        let turnCorrelationIDs = Set(runtime3Audit.compactMap { event -> String? in
            guard [
                SessionEventKind.turnStarted,
                .stepStarted,
                .modelRequestStarted,
                .assistantMessageCommitted,
                .stepEnded,
                .turnEnded
            ].contains(event.kind) else { return nil }
            return event.correlationID
        })
        precondition(turnCorrelationIDs.count == 1)

        let fetchSession = try repository.createSession(projectID: project.id, title: "Public fetch", mode: .acceptEdits)
        let fetchRegistry = ToolRegistry([webSearch, webFetch])
        let fetchRouter = ToolHostRouter(registry: fetchRegistry, repository: repository)
        let fetchMemoryHost = MemoryToolHost()
        fetchRouter.register(host: fetchMemoryHost, for: "web_search")
        fetchRouter.register(host: fetchMemoryHost, for: "web_fetch")
        let fetchHost = NativeAgentHost(
            client: ScriptedChatClient(batches: [
                [.toolCall(id: "public-fetch", name: "web_fetch", argumentsJSON: "{\"url\":\"https://example.com/weather/beijing\"}"), .done],
                [.textDelta("公开网页读取完成。"), .done]
            ]),
            eventStore: events,
            repository: repository,
            runtimeSupervisor: agentSupervisor,
            toolRouter: fetchRouter,
            toolRegistry: fetchRegistry,
            networkRuntime: network
        )

        var fetchEvents: [AgentEvent] = []
        for try await event in fetchHost.run(AgentRunRequest(sessionID: fetchSession.id, prompt: "明天北京的天气如何？", mode: .acceptEdits, model: "deepseek-chat")) {
            fetchEvents.append(event)
        }

        precondition(!fetchEvents.contains { if case .approvalRequired = $0 { return true }; return false })
        precondition(fetchEvents.contains(.toolCompleted(name: "web_fetch", succeeded: true)))
        let fetchAudit = try repository.events(sessionID: fetchSession.id)
        precondition(fetchAudit.contains { $0.type == "web_research_grant_used" && $0.payload["capability"] == "webFetch" })
        let persistedFetchGrants = try repository.networkGrants().filter {
            $0.sessionID == fetchSession.id && $0.capability == .webFetch && $0.operation == .read
        }
        precondition(!persistedFetchGrants.isEmpty)

        let failingSession = try repository.createSession(projectID: project.id, title: "Search failure diagnostics", mode: .acceptEdits)
        let failingRegistry = ToolRegistry([webSearch])
        let failingRouter = ToolHostRouter(registry: failingRegistry, repository: repository)
        failingRouter.register(host: FailingSearchToolHost(), for: "web_search")
        let failingHost = NativeAgentHost(
            client: ScriptedChatClient(batches: [
                [.toolCall(id: "failed-search", name: "web_search", argumentsJSON: "{\"query\":\"今天股市行情\"}"), .done],
                [.textDelta("暂时无法获取。"), .done]
            ]),
            eventStore: events,
            repository: repository,
            runtimeSupervisor: agentSupervisor,
            toolRouter: failingRouter,
            toolRegistry: failingRegistry,
            networkRuntime: network
        )
        for try await _ in failingHost.run(AgentRunRequest(sessionID: failingSession.id, prompt: "今天股市行情怎么样？", mode: .acceptEdits, model: "deepseek-chat")) {}
        let failureEvent = try repository.events(sessionID: failingSession.id).first { event in
            event.type == "tool_completed" && event.payload["tool"] == "web_search"
        }
        precondition(failureEvent?.payload["message"] == "搜索服务暂时不可用，请稍后重试。")

        let multiSearchSession = try repository.createSession(projectID: project.id, title: "Multi-search protocol", mode: .acceptEdits)
        let multiSearchRegistry = ToolRegistry([webSearch])
        let multiSearchRouter = ToolHostRouter(registry: multiSearchRegistry, repository: repository)
        let multiSearchMemoryHost = MemoryToolHost()
        multiSearchRouter.register(host: multiSearchMemoryHost, for: "web_search")
        multiSearchRouter.register(host: multiSearchMemoryHost, for: "web_fetch")
        let multiSearchHost = NativeAgentHost(
            client: ScriptedChatClient(batches: [
                [
                    .toolCall(id: "search-1", name: "web_search", argumentsJSON: "{\"query\":\"沪深300 最新行情\"}"),
                    .toolCall(id: "search-2", name: "web_search", argumentsJSON: "{\"query\":\"上证指数 最新行情\"}"),
                    .done
                ],
                [.textDelta("两项搜索均已完成。"), .done]
            ]),
            eventStore: events,
            repository: repository,
            runtimeSupervisor: agentSupervisor,
            toolRouter: multiSearchRouter,
            toolRegistry: multiSearchRegistry,
            networkRuntime: network
        )
        for try await _ in multiSearchHost.run(AgentRunRequest(sessionID: multiSearchSession.id, prompt: "今天股市行情怎么样？", mode: .acceptEdits, model: "deepseek-chat")) {}
        let multiSearchState = try repository.runState(sessionID: multiSearchSession.id)
        let multiSearchToolResponses = multiSearchState?.messages.filter { $0.role == "tool" }
        precondition(multiSearchToolResponses?.map(\.toolCallID) == ["search-1", "search-2"])
        let multiSearchAssistantCalls = multiSearchState?.messages
            .filter { $0.role == "assistant" }
            .flatMap { $0.toolCalls ?? [] }
            .map(\.id)
        precondition(multiSearchAssistantCalls == ["search-1", "search-2"])

        // allowSession creates a durable PermissionLease. A second matching
        // call in the same Session must continue without another approval,
        // even though the underlying tool remains L2/external-write.
        let leaseSession = try repository.createSession(projectID: project.id, title: "Permission lease", mode: .acceptEdits)
        let publishTool = RegisteredTool(
            name: "external_publish",
            description: "fixture external publish",
            parameters: .object([:]),
            effect: .externalWrite,
            risk: .l2,
            timeoutMilliseconds: 1_000,
            maxOutputBytes: 4_096,
            idempotent: false,
            supportsCancellation: true
        )
        let leaseRegistry = ToolRegistry([publishTool])
        let leaseRouter = ToolHostRouter(registry: leaseRegistry, repository: repository)
        leaseRouter.register(host: MemoryToolHost(), for: publishTool.name)
        let leaseHost = NativeAgentHost(
            client: ScriptedChatClient(batches: [
                [.toolCall(id: "publish-1", name: publishTool.name, argumentsJSON: "{}"), .done],
                [.toolCall(id: "publish-2", name: publishTool.name, argumentsJSON: "{}"), .done],
                [.textDelta("两次发布调用均已处理。"), .done]
            ]),
            eventStore: events,
            repository: repository,
            runtimeSupervisor: agentSupervisor,
            toolRouter: leaseRouter,
            toolRegistry: leaseRegistry
        )
        var firstLeaseRun: [AgentEvent] = []
        for try await event in leaseHost.run(AgentRunRequest(sessionID: leaseSession.id, prompt: "执行两次发布", mode: .acceptEdits, model: "deepseek-chat")) {
            firstLeaseRun.append(event)
        }
        precondition(firstLeaseRun.contains { if case .approvalRequired = $0 { return true }; return false })
        let leaseApprovalID = try unwrap(repository.events(sessionID: leaseSession.id).last { $0.type == "approval_requested" }?.payload["approvalID"])
        var resumedLeaseRun: [AgentEvent] = []
        for try await event in leaseHost.resume(sessionID: leaseSession.id, approvalID: leaseApprovalID, decision: .allowSession) {
            resumedLeaseRun.append(event)
        }
        precondition(!resumedLeaseRun.contains { if case .approvalRequired = $0 { return true }; return false })
        precondition(resumedLeaseRun.filter { if case .toolCompleted(name: "external_publish", succeeded: true) = $0 { return true }; return false }.count == 2)
        let persistedPublishLease = try repository.permissionLease(key: PermissionLeaseKey(projectID: project.id, sessionID: leaseSession.id, effect: .externalWrite, toolName: publishTool.name))
        precondition(persistedPublishLease?.isActive() == true)
        print("DeepSeek Harness checks passed")
    }

    private static func unwrap<T>(_ value: T?) throws -> T {
        guard let value else { throw NSError(domain: "DeepSeekHarnessChecks", code: 1) }
        return value
    }
}
