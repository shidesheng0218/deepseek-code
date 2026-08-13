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
        print("DeepSeek Harness checks passed")
    }

    private static func unwrap<T>(_ value: T?) throws -> T {
        guard let value else { throw NSError(domain: "DeepSeekHarnessChecks", code: 1) }
        return value
    }
}
