import Foundation

/// Provider construction is injectable so daemon lifecycle tests never need a
/// real BYOK credential or external network access.
public protocol DaemonChatClientFactory: Sendable {
    func make(
        profile: ProviderProfile,
        apiKey: String,
        networkRuntime: NetworkRuntime,
        networkContext: NetworkContext
    ) throws -> any ChatStreaming
}

public struct DefaultDaemonChatClientFactory: DaemonChatClientFactory {
    public init() {}

    public func make(
        profile: ProviderProfile,
        apiKey: String,
        networkRuntime: NetworkRuntime,
        networkContext: NetworkContext
    ) throws -> any ChatStreaming {
        try ProviderClientFactory.make(
            profile: profile,
            apiKey: apiKey,
            networkRuntime: networkRuntime,
            networkContext: networkContext
        )
    }
}

public enum NativeDaemonSessionRunnerError: LocalizedError, Sendable {
    case projectNotFound
    case missingAPIKey
    case unsupportedAttachment

    public var errorDescription: String? {
        switch self {
        case .projectNotFound: "找不到 Session 对应的本地项目"
        case .missingAPIKey: "请先在 DeepSeek Code 配置 Base URL 和 API Key"
        case .unsupportedAttachment: "当前 daemon 运行时尚不能安全读取该附件；请在 App 中重新附加或改用文本输入"
        }
    }
}

/// Real local execution runner used by `deepseekd`. It reconstructs a bounded
/// NativeAgentHost from durable Session/Project/Provider data; the GUI and
/// CLI therefore share the same persisted messages, approvals and evidence
/// rather than each hosting a separate Agent loop.
public final class NativeDaemonSessionRunner: DaemonSessionRunner, @unchecked Sendable {
    private let repository: SessionRepository
    private let eventStore: EventStore
    private let providerCatalog: ProviderCatalog
    private let secretStore: any SecretStore
    private let clientFactory: any DaemonChatClientFactory
    private let networkRuntime: NetworkRuntime
    private let storageRoot: URL
    private let terminalHost: (any PersistentTerminalHost)?
    private let projectTrusted: Bool
    private let sandboxAvailable: Bool

    public init(
        repository: SessionRepository,
        eventStore: EventStore,
        providerCatalog: ProviderCatalog,
        secretStore: any SecretStore,
        clientFactory: any DaemonChatClientFactory = DefaultDaemonChatClientFactory(),
        networkRuntime: NetworkRuntime? = nil,
        storageRoot: URL,
        terminalHost: (any PersistentTerminalHost)? = nil,
        projectTrusted: Bool = false,
        sandboxAvailable: Bool? = nil
    ) {
        self.repository = repository
        self.eventStore = eventStore
        self.providerCatalog = providerCatalog
        self.secretStore = secretStore
        self.clientFactory = clientFactory
        self.networkRuntime = networkRuntime ?? NetworkRuntime(policy: .default, repository: repository)
        self.storageRoot = storageRoot
        self.terminalHost = terminalHost
        self.projectTrusted = projectTrusted
        self.sandboxAvailable = sandboxAvailable ?? SandboxRuntime.availability.available
    }

    public func run(session: StoredSession, input: SessionInputRecord, control: AgentRunControl) async throws {
        let prompt = try prompt(from: input.parts)
        let prepared = try makeHost(session: session, prompt: prompt)
        let request = prepared.request(parts: input.parts, control: control)
        for try await _ in prepared.host.run(request) {
            // NativeAgentHost appends all durable events itself. The daemon
            // deliberately does not maintain a second UI-only transcript.
        }
    }

    public func resume(session: StoredSession, approvalID: String, decision: ApprovalDecision, control: AgentRunControl) async throws {
        let state = try repository.runState(sessionID: session.id)
        let prompt = state?.prompt ?? session.title
        let prepared = try makeHost(session: session, prompt: prompt)
        for try await _ in prepared.host.resume(sessionID: session.id, approvalID: approvalID, decision: decision) {
            // Event persistence remains inside NativeAgentHost.
        }
    }

    private func makeHost(session: StoredSession, prompt: String) throws -> PreparedHost {
        guard let project = try repository.project(id: session.projectID) else {
            throw NativeDaemonSessionRunnerError.projectNotFound
        }
        let workspaceURL = URL(fileURLWithPath: session.worktreePath ?? project.path, isDirectory: true).standardizedFileURL
        guard FileManager.default.fileExists(atPath: workspaceURL.path) else {
            throw NativeDaemonSessionRunnerError.projectNotFound
        }
        let profile = (try providerCatalog.list()).first ?? .defaultDeepSeek
        guard let apiKey = try secretStore.load(reference: profile.apiKeyReference), !apiKey.isEmpty else {
            throw NativeDaemonSessionRunnerError.missingAPIKey
        }
        let workspace = try WorkspaceToolHost(
            root: workspaceURL,
            checkpointDirectory: storageRoot
                .appendingPathComponent("Checkpoints", isDirectory: true)
                .appendingPathComponent(session.id, isDirectory: true)
        )
        let registry = ToolRegistry(supportedTools())
        let router = ToolHostRouter(registry: registry, repository: repository)
        router.register(host: LocalWorkspaceToolHost(workspace: workspace), forPrefix: "")
        router.register(host: WebToolHost(runtime: networkRuntime, projectID: project.id), forPrefix: "web.")
        if let terminalHost {
            let terminalTools = AgentToolSchemas.registry.allTools().filter { $0.name == "run_command" || $0.name.hasPrefix("terminal.") }
            terminalTools.forEach { registry.register($0) }
            router.register(
                host: PersistentTerminalToolHost(
                    host: terminalHost,
                    repository: repository,
                    defaultCWD: workspaceURL.path,
                    sandboxRoot: workspaceURL.path,
                    sandboxScratchRoot: storageRoot.appendingPathComponent("Sandbox", isDirectory: true).path,
                    manifest: HostCapabilityManifest(
                        hostID: "deepseekd.terminal.\(session.id)",
                        allowedPaths: [workspaceURL.path, storageRoot.appendingPathComponent("Sandbox", isDirectory: true).path],
                        allowedEffects: [.readOnly, .workspaceWrite, .process, .gitWrite, .network],
                        allowedEnvironmentKeys: ["PATH", "HOME", "PWD", "TMPDIR"],
                        maxOutputBytes: 128_000,
                        timeoutMilliseconds: 120_000
                    )
                ),
                forPrefix: "terminal."
            )
            router.register(
                host: PersistentTerminalToolHost(
                    host: terminalHost,
                    repository: repository,
                    defaultCWD: workspaceURL.path,
                    sandboxRoot: workspaceURL.path,
                    sandboxScratchRoot: storageRoot.appendingPathComponent("Sandbox", isDirectory: true).path,
                    manifest: HostCapabilityManifest(
                        hostID: "deepseekd.terminal.\(session.id)",
                        allowedPaths: [workspaceURL.path, storageRoot.appendingPathComponent("Sandbox", isDirectory: true).path],
                        allowedEffects: [.readOnly, .workspaceWrite, .process, .gitWrite, .network],
                        allowedEnvironmentKeys: ["PATH", "HOME", "PWD", "TMPDIR"],
                        maxOutputBytes: 128_000,
                        timeoutMilliseconds: 120_000
                    )
                ),
                for: "run_command"
            )
        }

        var instructions = (try? InstructionResolver.resolve(
            workspaceRoot: workspaceURL,
            workingDirectory: workspaceURL
        ).text) ?? ""
        if let skill = SkillRuntime.promptSkill(
            in: prompt,
            descriptors: (try? SkillCatalog.discover(projectDirectory: workspaceURL)) ?? []
        ) {
            instructions += "\n\n[已启用 Skill：\(skill.descriptor.name)]\n\(skill.content)"
            _ = try? repository.appendDurable(
                sessionID: session.id,
                type: "skill_invoked",
                payload: ["skillID": skill.descriptor.id, "path": skill.descriptor.path],
                commandID: "daemon-skill-\(session.id)-\(skill.descriptor.id)"
            )
        }
        let taskContract = (try repository.taskContract(sessionID: session.id))
            ?? TaskContract.compatibility(prompt: prompt)
        _ = try? repository.saveTaskContract(taskContract, sessionID: session.id)
        let route = TaskRouter.route(TaskRoutingInput(
            prompt: prompt,
            mode: session.mode,
            hasProject: true
        ))
        let qualityPlan = TaskQualityPlanner.plan(route: route)
        let model = DeepSeekModelCatalog.routedModel(preferred: profile.model, route: route)
        let capabilities = DeepSeekModelCatalog.capabilities(for: model)
        let client = try clientFactory.make(
            profile: profile,
            apiKey: apiKey,
            networkRuntime: networkRuntime,
            networkContext: NetworkContext(
                sessionID: session.id,
                projectID: project.id,
                purpose: .providerRequest,
                requestedBy: "deepseekd"
            )
        )
        let host = NativeAgentHost(
            client: client,
            eventStore: eventStore,
            workspace: workspace,
            repository: repository,
            projectTrusted: projectTrusted,
            sandboxAvailable: sandboxAvailable,
            toolRouter: router,
            toolRegistry: registry,
            defaultPricing: profile,
            networkRuntime: networkRuntime,
            hookManifest: HostCapabilityManifest(
                hostID: "deepseekd.\(session.id)",
                allowedPaths: [workspaceURL.path],
                allowedEffects: [.readOnly],
                maxOutputBytes: 32_000,
                timeoutMilliseconds: 10_000
            )
        )
        return PreparedHost(
            host: host,
            sessionID: session.id,
            prompt: prompt,
            mode: session.mode,
            model: model,
            thinking: capabilities.supportsThinking && qualityPlan.modelTier == .capable,
            instructions: instructions,
            taskContract: taskContract,
            profile: profile,
            route: route,
            qualityPlan: qualityPlan
        )
    }

    private func supportedTools() -> [RegisteredTool] {
        var supportedNames: Set<String> = [
            "list_directory", "read_file", "search_workspace", "workspace_read_evidence",
            "apply_patch", "inspect_git", "lsp_query", "web_search", "web_fetch"
        ]
        if terminalHost != nil {
            supportedNames.formUnion(AgentToolSchemas.registry.allTools().map(\.name).filter { $0 == "run_command" || $0.hasPrefix("terminal.") })
        }
        return AgentToolSchemas.registry.allTools().filter { supportedNames.contains($0.name) }
    }

    private func prompt(from parts: [ContentPart]) throws -> String {
        var values: [String] = []
        for part in parts {
            switch part {
            case let .text(text): values.append(text)
            case let .codeSelection(path, startLine, endLine, text):
                values.append("[代码片段 \(path):\(startLine)-\(endLine)]\n\(text)")
            case let .browserEvidence(evidence): values.append("[浏览器证据] \(evidence.summary)")
            case let .computerEvidence(evidence): values.append("[电脑证据] \(evidence.summary)")
            case let .toolEvidence(evidence): values.append("[工具证据] \(evidence.detail)")
            case .image, .document: throw NativeDaemonSessionRunnerError.unsupportedAttachment
            }
        }
        let prompt = values.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return prompt.isEmpty ? "继续处理当前 Session" : prompt
    }

    private struct PreparedHost {
        let host: NativeAgentHost
        let sessionID: String
        let prompt: String
        let mode: AgentMode
        let model: String
        let thinking: Bool
        let instructions: String
        let taskContract: TaskContract
        let profile: ProviderProfile
        let route: TaskRoute
        let qualityPlan: TaskQualityPlan

        func request(parts: [ContentPart], control: AgentRunControl) -> AgentRunRequest {
            AgentRunRequest(
                sessionID: sessionID,
                prompt: prompt,
                parts: parts,
                budget: taskContract.budget,
                mode: mode,
                model: model,
                thinking: thinking,
                instructions: instructions,
                taskContract: taskContract,
                control: control,
                pricing: profile,
                target: .local,
                qualityRoute: route,
                qualityPlan: qualityPlan
            )
        }
    }
}
