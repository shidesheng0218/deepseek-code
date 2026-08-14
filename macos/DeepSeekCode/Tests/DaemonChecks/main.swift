import Foundation
import DeepSeekCodeCore

@main
struct DeepSeekCodeDaemonChecks {
    static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("deepseek-daemon-checks-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let repository = try SessionRepository(directory: root.appendingPathComponent("Database", isDirectory: true))
        let project = try repository.createProject(name: "Daemon", path: root.path)
        let session = try repository.createSession(projectID: project.id, title: "Daemon Session", mode: .acceptEdits)
        let router = DeepSeekDaemonCommandRouter(
            repository: repository,
            supervisor: SessionSupervisor(repository: repository, instanceID: "daemon-check")
        )

        let handshake = await router.handle(DeepSeekDaemonRequest(method: .handshake))
        precondition(handshake.ok)
        let handshakePayload = try decode(DeepSeekDaemonHandshake.self, from: handshake.output)
        precondition(handshakePayload.protocolVersion == DeepSeekDaemonProtocol.version)

        let list = await router.handle(DeepSeekDaemonRequest(method: .sessionList))
        let summaries = try decode([DeepSeekDaemonSessionSummary].self, from: list.output)
        precondition(summaries.contains { $0.id == session.id && $0.title == "Daemon Session" })

        let createdProjectPath = root.appendingPathComponent("created-project", isDirectory: true)
        let created = await router.handle(DeepSeekDaemonRequest(
            method: .sessionCreate,
            payload: try encode(DeepSeekDaemonCreateSessionPayload(
                projectPath: createdProjectPath.path,
                title: "Created from daemon"
            ))
        ))
        let createdSession = try decode(StoredSession.self, from: created.output)
        precondition(created.ok)
        _ = try repository.appendDurable(sessionID: createdSession.id, type: "assistant_text", payload: ["text": "event stream"])
        let eventResponse = await router.handle(DeepSeekDaemonRequest(
            method: .sessionEvents,
            payload: try encode(DeepSeekDaemonEventsPayload(sessionID: createdSession.id))
        ))
        let streamedEvents = try decode([SessionEvent].self, from: eventResponse.output)
        precondition(streamedEvents.contains { $0.payload["text"] == "event stream" })

        let inputPayload = DeepSeekDaemonInputPayload(
            sessionID: session.id,
            idempotencyKey: "daemon-input-1",
            delivery: .immediate,
            parts: [.text("检查 daemon 幂等")]
        )
        let admitted = await router.handle(DeepSeekDaemonRequest(method: .inputAdmit, payload: try encode(inputPayload)))
        precondition(admitted.ok)
        let admittedAgain = await router.handle(DeepSeekDaemonRequest(method: .inputAdmit, payload: try encode(inputPayload)))
        precondition(admittedAgain.ok)
        let firstReceipt = try decode(AdmissionReceipt.self, from: admitted.output)
        let secondReceipt = try decode(AdmissionReceipt.self, from: admittedAgain.output)
        precondition(firstReceipt.inputID == secondReceipt.inputID)

        let sessionPayload = DeepSeekDaemonSessionPayload(sessionID: session.id)
        let encodedSessionPayload = try encode(sessionPayload)
        let firstStart = await router.handle(DeepSeekDaemonRequest(method: .sessionStart, payload: encodedSessionPayload))
        let repeatedStart = await router.handle(DeepSeekDaemonRequest(method: .sessionStart, payload: encodedSessionPayload))
        precondition(firstStart.ok)
        precondition(repeatedStart.ok)
        let events = try repository.events(sessionID: session.id)
        precondition(events.filter { $0.type == "harness_started" }.count == 1)
        precondition(events.contains {
            $0.type == "runtime_owner_changed" &&
            $0.payload["runtime"] == "deepseekd" &&
            $0.payload["sessionID"] == session.id
        })

        let attached = await router.handle(DeepSeekDaemonRequest(method: .sessionAttach, payload: try encode(sessionPayload)))
        let receipt = try decode(SessionAttachReceipt.self, from: attached.output)
        precondition(receipt.sessionID == session.id)
        precondition(receipt.eventCursor == events.last?.sequence)

        let executionSession = try repository.createSession(projectID: project.id, title: "Daemon execution", mode: .acceptEdits)
        let runner = DaemonRunnerProbe()
        let driver = DaemonSessionExecutionDriver(repository: repository, runner: runner)
        let executionSupervisor = SessionSupervisor(repository: repository, executionDriver: driver, instanceID: "daemon-execution-check")
        _ = try await executionSupervisor.admit(SessionInput(
            sessionID: executionSession.id,
            idempotencyKey: "execute-once",
            delivery: .immediate,
            parts: [.text("通过 daemon 执行")]
        ))
        try await executionSupervisor.start(sessionID: executionSession.id)
        try await driver.waitForIdle(sessionID: executionSession.id)
        try await executionSupervisor.start(sessionID: executionSession.id)
        try await driver.waitForIdle(sessionID: executionSession.id)
        let startedSessionIDs = await runner.startedSessionIDs()
        let executionInputState = try repository.sessionInputs(sessionID: executionSession.id).last?.state
        precondition(startedSessionIDs == [executionSession.id])
        precondition(executionInputState == .consumed)

        let providerCatalog = try ProviderCatalog(directory: root.appendingPathComponent("Providers", isDirectory: true))
        let profile = ProviderProfile(
            id: "daemon-fixture",
            name: "Fixture",
            baseURL: "https://example.invalid/v1/",
            model: "fixture-model",
            protocolName: .openAICompatible,
            apiKeyReference: "keychain://daemon-fixture"
        )
        try providerCatalog.save(profile)
        let secrets = InMemorySecretStore()
        try secrets.save(reference: profile.apiKeyReference, value: "fixture-key")
        let daemonAttachmentSource = root.appendingPathComponent("daemon-attachment.txt")
        try Data("daemon attachment evidence".utf8).write(to: daemonAttachmentSource)
        let daemonAttachmentStore = try AttachmentStore(
            directory: root.appendingPathComponent("Attachments", isDirectory: true),
            secretStore: secrets
        )
        let daemonAttachment = try daemonAttachmentStore.importFile(at: daemonAttachmentSource)
        let nativeSession = try repository.createSession(projectID: project.id, title: "Native daemon execution", mode: .acceptEdits)
        let nativeRunner = NativeDaemonSessionRunner(
            repository: repository,
            eventStore: try EventStore(directory: root.appendingPathComponent("DaemonEvents", isDirectory: true)),
            providerCatalog: providerCatalog,
            secretStore: secrets,
            clientFactory: StaticDaemonClientFactory(events: [.textDelta("daemon agent response"), .done]),
            storageRoot: root
        )
        let nativeDriver = DaemonSessionExecutionDriver(repository: repository, runner: nativeRunner)
        let nativeSupervisor = SessionSupervisor(repository: repository, executionDriver: nativeDriver, instanceID: "native-daemon-check")
        _ = try await nativeSupervisor.admit(SessionInput(
            sessionID: nativeSession.id,
            idempotencyKey: "native-daemon-input",
            delivery: .immediate,
            parts: [.text("回答一个问题"), .document(daemonAttachment)]
        ))
        try await nativeSupervisor.start(sessionID: nativeSession.id)
        try await nativeDriver.waitForIdle(sessionID: nativeSession.id)
        let nativeEvents = try repository.events(sessionID: nativeSession.id)
        precondition(nativeEvents.contains { $0.type == "assistant_text" && $0.payload["text"] == "daemon agent response" })

        // Regression: daemon model execution must use the same persistent PTY
        // host as the GUI. This intentionally exercises a real shell command,
        // not a mocked ToolHost response.
        let terminalRoot = root.appendingPathComponent("TerminalRuntime", isDirectory: true)
        let terminalSecrets = InMemorySecretStore()
        let terminalHost = try PersistentTerminalService(
            root: terminalRoot,
            secretStore: terminalSecrets,
            socketPath: terminalRoot.appendingPathComponent("host.sock").path
        )
        let terminalSession = try repository.createSession(projectID: project.id, title: "Daemon terminal", mode: .auto)
        let terminalRunner = NativeDaemonSessionRunner(
            repository: repository,
            eventStore: try EventStore(directory: root.appendingPathComponent("TerminalEvents", isDirectory: true)),
            providerCatalog: providerCatalog,
            secretStore: secrets,
            clientFactory: SequencedDaemonClientFactory(batches: [
                [.toolCall(id: "terminal-call", name: "terminal_exec", argumentsJSON: "{\"command\":\"printf daemon-terminal-ok\",\"timeoutMs\":5000}"), .done],
                [.textDelta("终端执行已完成"), .done]
            ]),
            networkRuntime: NetworkRuntime(policy: .default, repository: repository),
            storageRoot: root,
            terminalHost: terminalHost,
            projectTrusted: true,
            sandboxAvailable: true
        )
        let terminalDriver = DaemonSessionExecutionDriver(repository: repository, runner: terminalRunner)
        let terminalSupervisor = SessionSupervisor(repository: repository, executionDriver: terminalDriver, instanceID: "daemon-terminal-check")
        _ = try await terminalSupervisor.admit(SessionInput(
            sessionID: terminalSession.id,
            idempotencyKey: "daemon-terminal-input",
            delivery: .immediate,
            parts: [.text("运行终端检查")]
        ))
        try await terminalSupervisor.start(sessionID: terminalSession.id)
        try await terminalDriver.waitForIdle(sessionID: terminalSession.id)
        let terminalEvents = try repository.events(sessionID: terminalSession.id)
        precondition(terminalEvents.contains { $0.type == "terminal_started" })
        precondition(terminalEvents.contains { $0.type == "terminal_completed" })
        precondition(terminalEvents.contains { $0.type == "assistant_text" && $0.payload["text"] == "终端执行已完成" })

        let terminalRouter = DeepSeekDaemonCommandRouter(
            repository: repository,
            supervisor: SessionSupervisor(repository: repository, instanceID: "daemon-direct-terminal-check"),
            terminalHost: terminalHost,
            instanceID: "daemon-direct-terminal-router"
        )
        let approvalResponse = await terminalRouter.handle(DeepSeekDaemonRequest(
            method: .terminalExec,
            payload: try encode(DeepSeekDaemonTerminalExecPayload(sessionID: terminalSession.id, command: "curl --version", timeoutMilliseconds: 5_000))
        ))
        precondition(!approvalResponse.ok && approvalResponse.code == "APPROVAL_REQUIRED")
        let approval = try decode(DeepSeekDaemonTerminalApprovalRequired.self, from: approvalResponse.output)
        let approvalResolution = await terminalRouter.handle(DeepSeekDaemonRequest(
            method: .approvalResolve,
            payload: try encode(DeepSeekDaemonApprovalPayload(sessionID: terminalSession.id, approvalID: approval.approvalID, decision: .allowOnce))
        ))
        precondition(approvalResolution.ok)
        let firstApproved = await terminalRouter.handle(DeepSeekDaemonRequest(
            method: .terminalExec,
            payload: try encode(DeepSeekDaemonTerminalExecPayload(sessionID: terminalSession.id, command: "curl --version", timeoutMilliseconds: 5_000, approvalID: approval.approvalID))
        ))
        precondition(firstApproved.ok)
        let repeatedApproved = await terminalRouter.handle(DeepSeekDaemonRequest(
            method: .terminalExec,
            payload: try encode(DeepSeekDaemonTerminalExecPayload(sessionID: terminalSession.id, command: "curl --version", timeoutMilliseconds: 5_000, approvalID: approval.approvalID))
        ))
        precondition(!repeatedApproved.ok && repeatedApproved.code == "APPROVAL_INVALID")

        let workerRuntime = DurableChildAgentRuntime(repository: repository, driver: DaemonWorkerProbe())
        let workerRouter = DeepSeekDaemonCommandRouter(
            repository: repository,
            supervisor: SessionSupervisor(repository: repository, instanceID: "daemon-worker-check"),
            workerRuntime: workerRuntime
        )
        let workerCreate = await workerRouter.handle(DeepSeekDaemonRequest(
            method: .workerCreate,
            payload: try encode(DeepSeekDaemonWorkerCreatePayload(
                parentSessionID: session.id,
                workerID: "daemon-explore",
                workerKind: .explore,
                objective: "读取项目结构"
            ))
        ))
        precondition(workerCreate.ok)
        let workerRecord = try decode(WorkerSessionRecord.self, from: workerCreate.output)
        let workerStart = await workerRouter.handle(DeepSeekDaemonRequest(method: .workerStart, payload: try encode(DeepSeekDaemonWorkerPayload(workerSessionID: workerRecord.id))))
        precondition(workerStart.ok)
        let workerResult = try await waitForWorkerResult(workerRuntime, id: workerRecord.id)
        precondition(workerResult.summary == "只读 Worker 已完成")
        let beforeAdopt = try repository.workerSession(id: workerRecord.id)
        precondition(beforeAdopt?.state == .awaitingAdoption)
        let workerAdopt = await workerRouter.handle(DeepSeekDaemonRequest(method: .workerAdopt, payload: try encode(DeepSeekDaemonWorkerPayload(workerSessionID: workerRecord.id))))
        precondition(workerAdopt.ok)
        let adoptedWorker = try repository.workerSession(id: workerRecord.id)
        precondition(adoptedWorker?.state == .completed)
        print("DeepSeek daemon checks passed")
    }

    private static func encode<T: Encodable>(_ value: T) throws -> String {
        String(decoding: try DeepSeekDaemonJSON.encoder.encode(value), as: UTF8.self)
    }

    private static func decode<T: Decodable>(_ type: T.Type, from text: String) throws -> T {
        try DeepSeekDaemonJSON.decoder.decode(T.self, from: Data(text.utf8))
    }

    private static func waitForWorkerResult(_ runtime: DurableChildAgentRuntime, id: String) async throws -> WorkerResultEnvelope {
        try await runtime.collect(workerSessionID: id)
    }
}

private actor DaemonRunnerProbe: DaemonSessionRunner {
    private var started: [String] = []

    func run(session: StoredSession, input: SessionInputRecord, control: AgentRunControl) async throws {
        started.append(session.id)
    }

    func resume(session: StoredSession, approvalID: String, decision: ApprovalDecision, control: AgentRunControl) async throws {}

    func startedSessionIDs() -> [String] { started }
}

private struct DaemonWorkerProbe: ChildAgentExecutionDriver {
    func execute(
        contract: WorkerSessionContract,
        sessionID: String,
        workerID: String,
        workerSessionID: String
    ) async throws -> WorkerResultEnvelope {
        WorkerResultEnvelope(
            workerID: workerID,
            sessionID: sessionID,
            summary: "只读 Worker 已完成",
            evidenceIDs: ["daemon-worker-evidence"],
            inputHash: "daemon-input",
            outputHash: "daemon-output"
        )
    }
}

private struct StaticDaemonClientFactory: DaemonChatClientFactory {
    let events: [ProviderStreamEvent]

    func make(profile: ProviderProfile, apiKey: String, networkRuntime: NetworkRuntime, networkContext: NetworkContext) throws -> any ChatStreaming {
        StaticDaemonChatClient(events: events)
    }
}

private struct SequencedDaemonClientFactory: DaemonChatClientFactory {
    let batches: [[ProviderStreamEvent]]

    func make(profile: ProviderProfile, apiKey: String, networkRuntime: NetworkRuntime, networkContext: NetworkContext) throws -> any ChatStreaming {
        SequencedDaemonChatClient(batches: batches)
    }
}

private final class SequencedDaemonChatClient: ChatStreaming, @unchecked Sendable {
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

private final class StaticDaemonChatClient: ChatStreaming, @unchecked Sendable {
    private let events: [ProviderStreamEvent]

    init(events: [ProviderStreamEvent]) {
        self.events = events
    }

    func stream(_ request: ChatRequest) -> AsyncThrowingStream<ProviderStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            for event in events { continuation.yield(event) }
            continuation.finish()
        }
    }
}
