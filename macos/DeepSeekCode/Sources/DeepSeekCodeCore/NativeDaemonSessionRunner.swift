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

/// Optional capability refinement.  Fixtures can stay transport-only while
/// the production factory receives the encrypted local attachment provider.
public protocol AttachmentAwareDaemonChatClientFactory: DaemonChatClientFactory {
    func make(
        profile: ProviderProfile,
        apiKey: String,
        attachmentProvider: (any AttachmentDataProvider)?,
        networkRuntime: NetworkRuntime,
        networkContext: NetworkContext
    ) throws -> any ChatStreaming
}

public struct DefaultDaemonChatClientFactory: AttachmentAwareDaemonChatClientFactory {
    public init() {}

    public func make(
        profile: ProviderProfile,
        apiKey: String,
        networkRuntime: NetworkRuntime,
        networkContext: NetworkContext
    ) throws -> any ChatStreaming {
        try make(
            profile: profile,
            apiKey: apiKey,
            attachmentProvider: nil,
            networkRuntime: networkRuntime,
            networkContext: networkContext
        )
    }

    public func make(
        profile: ProviderProfile,
        apiKey: String,
        attachmentProvider: (any AttachmentDataProvider)?,
        networkRuntime: NetworkRuntime,
        networkContext: NetworkContext
    ) throws -> any ChatStreaming {
        try ProviderClientFactory.make(
            profile: profile,
            apiKey: apiKey,
            attachmentProvider: attachmentProvider,
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
    private let attachmentStore: AttachmentStore?
    private let projectTrusted: Bool
    private let sandboxAvailable: Bool
    private let hooks: [HookDefinition]
    private let capabilityProfile: RuntimeProfile
    private var runtimeSupervisor: SessionSupervisor?

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
        sandboxAvailable: Bool? = nil,
        hooks: [HookDefinition] = [],
        capabilityProfile: RuntimeProfile? = nil
    ) {
        self.repository = repository
        self.eventStore = eventStore
        self.providerCatalog = providerCatalog
        self.secretStore = secretStore
        self.clientFactory = clientFactory
        self.networkRuntime = networkRuntime ?? NetworkRuntime(policy: .default, repository: repository)
        self.storageRoot = storageRoot
        self.terminalHost = terminalHost
        let resolvedAttachmentStore = try? AttachmentStore(
            directory: storageRoot.appendingPathComponent("Attachments", isDirectory: true),
            secretStore: secretStore
        )
        self.attachmentStore = resolvedAttachmentStore
        self.projectTrusted = projectTrusted
        self.sandboxAvailable = sandboxAvailable ?? SandboxRuntime.availability.available
        self.hooks = hooks.filter { $0.enabled && $0.trusted }
        self.capabilityProfile = capabilityProfile ?? (try? DaemonRuntimeProfile.make(
            terminalAvailable: terminalHost != nil,
            attachmentAvailable: resolvedAttachmentStore != nil,
            hooksAvailable: self.hooks.isEmpty == false,
            mcpAvailable: false,
            browserAvailable: false,
            sshAvailable: false
        )) ?? DaemonRuntimeProfile.conservative
    }

    public var runtimeCapabilities: RuntimeProfile { capabilityProfile }

    /// Called once while deepseekd is assembled. The runner passes this exact
    /// actor to every NativeAgentHost it creates, preserving one write owner
    /// for a daemon lifetime instead of creating a Supervisor per model turn.
    public func installRuntimeSupervisor(_ supervisor: SessionSupervisor) {
        runtimeSupervisor = supervisor
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
        let installedCapabilities = Set(capabilityProfile.capabilities)
        if installedCapabilities.contains(DaemonRuntimeProfile.webSearch) || installedCapabilities.contains(DaemonRuntimeProfile.webFetch) {
            let webHost = WebToolHost(runtime: networkRuntime, projectID: project.id)
            if installedCapabilities.contains(DaemonRuntimeProfile.webSearch) {
                router.register(host: webHost, for: "web_search")
            }
            if installedCapabilities.contains(DaemonRuntimeProfile.webFetch) {
                router.register(host: webHost, for: "web_fetch")
            }
        }
        if let terminalHost, installedCapabilities.contains(DaemonRuntimeProfile.terminal) {
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
        let context = NetworkContext(
            sessionID: session.id,
            projectID: project.id,
            purpose: .providerRequest,
            requestedBy: "deepseekd"
        )
        let client: any ChatStreaming
        if let attachmentAwareFactory = clientFactory as? any AttachmentAwareDaemonChatClientFactory {
            client = try attachmentAwareFactory.make(
                profile: profile,
                apiKey: apiKey,
                attachmentProvider: attachmentStore,
                networkRuntime: networkRuntime,
                networkContext: context
            )
        } else {
            client = try clientFactory.make(
                profile: profile,
                apiKey: apiKey,
                networkRuntime: networkRuntime,
                networkContext: context
            )
        }
        let host = NativeAgentHost(
            client: client,
            eventStore: eventStore,
            workspace: workspace,
            repository: repository,
            runtimeSupervisor: runtimeSupervisor,
            projectTrusted: projectTrusted,
            sandboxAvailable: sandboxAvailable,
            toolRouter: router,
            toolRegistry: registry,
            hooks: hooks,
            defaultPricing: profile,
            networkRuntime: networkRuntime,
            hookManifest: HostCapabilityManifest(
                hostID: "deepseekd.\(session.id)",
                allowedPaths: [workspaceURL.path],
                allowedEffects: hooks.isEmpty ? [.readOnly] : [.readOnly, .process],
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
        let installedCapabilities = Set(capabilityProfile.capabilities)
        var supportedNames: Set<String> = ["list_directory", "read_file", "search_workspace", "workspace_read_evidence", "apply_patch", "inspect_git", "lsp_query"]
        if installedCapabilities.contains(DaemonRuntimeProfile.webSearch) { supportedNames.insert("web_search") }
        if installedCapabilities.contains(DaemonRuntimeProfile.webFetch) { supportedNames.insert("web_fetch") }
        if terminalHost != nil, installedCapabilities.contains(DaemonRuntimeProfile.terminal) {
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
            case let .image(attachment), let .document(attachment):
                values.append("[附件：\(attachment.filename)，内容由 Provider 的本地附件通道读取]")
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
