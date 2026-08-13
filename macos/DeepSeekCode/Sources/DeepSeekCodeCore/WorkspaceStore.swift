import CryptoKit
import Foundation
import Observation
#if os(macOS)
import ApplicationServices
import CoreGraphics
#endif

@MainActor
@Observable
public final class WorkspaceStore {
    public struct ActivityItem: Identifiable, Equatable, Sendable {
        public let id: UUID
        public let title: String
        public let detail: String
        public let state: String

        public init(id: UUID = UUID(), title: String, detail: String, state: String) {
            self.id = id
            self.title = title
            self.detail = detail
            self.state = state
        }
    }

    public struct EditorTab: Identifiable, Equatable, Sendable {
        public let id: String
        public let path: String
        public var title: String
        public var content: String
        public var originalContent: String
        public var originalHash: String
        public var isDirty: Bool
        public var isReadOnly: Bool
        public var encoding: String
        public var lineCount: Int
        public var byteCount: Int
        public var isBinary: Bool
        public var isLargeFile: Bool
        public var gitStatus: GitFileStatus?

        public init(snapshot: EditableFileSnapshot, gitStatus: GitFileStatus? = nil) {
            id = snapshot.path
            path = snapshot.path
            title = URL(fileURLWithPath: snapshot.path).lastPathComponent
            content = snapshot.content
            originalContent = snapshot.content
            originalHash = snapshot.sha256
            isDirty = false
            isReadOnly = snapshot.isBinary || snapshot.isLargeFile
            encoding = snapshot.encoding
            lineCount = snapshot.lineCount
            byteCount = snapshot.byteCount
            isBinary = snapshot.isBinary
            isLargeFile = snapshot.isLargeFile
            self.gitStatus = gitStatus
        }
    }

    public var projects: [ProjectRecord] = []
    public var sessions: [Session] = []
    public var selectedSessionID = ""
    public var executionTarget: SessionTarget = .local
    public var mode: AgentMode = .acceptEdits
    public var projectPath = ""
    public var prompt = ""
    public var isSettingsPresented = false
    public var isProjectPickerPresented = false
    public var isAttachmentPickerPresented = false
    public var isSessionRestorePickerPresented = false
    public var statusMessage = "选择一个本地项目以开始"
    public var selectedRightPanel: RightPanel = .changes
    public var isInspectorVisible = false
    public var activeSection: WorkspaceSection = .projects
    public var providerName = "DeepSeek"
    public var providerBaseURL = DeepSeekModelCatalog.defaultBaseURL
    public var providerModel = DeepSeekModelCatalog.fastModel
    public var providerProtocol: ProviderProtocol = .openAICompatible
    public var providerCapabilities = ProviderCapabilities.deepSeekTextOnly
    public var visionAdapterEnabled = false
    public var visionAdapterBaseURL = ""
    public var visionAdapterModel = ""
    public var visionAdapterAPIKey = ""
    public var sessionBudget = SessionBudget()
    public var providerAPIKey = ""
    public var providerStatus = ""
    public var composerAttachments: [AttachmentRef] = []
    public var attachmentStatusMessage = ""
    public var computerPermissionStatus = "未检查 Computer Use 权限"
    public let transcript = TranscriptBuffer()
    public var conversationMessages: [ConversationMessage] = []
    public var conversationTimeline: [ConversationEntry] = []
    public var usageSummary = UsageSummary()
    public var usageLedger = UsageLedger()
    public var verificationGraph = VerificationGraph(taskID: "")
    public var activeTaskContract: TaskContract?
    public var deliveryGateResult: DeliveryGateResult?
    public var reviewFindings: [ReviewFinding] = []
    public var reviewIsRunning = false
    public var reviewUpdatedAt: Date?
    public var githubDeliveries: [GitHubDeliveryRecord] = []
    public var ciFailureEvidence: CIFailureEvidence?
    public var ciLogOutput = ""
    public var terminalCommand = "git status"
    public var terminalOutput = ""
    public var terminalRunning = false
    public var terminalSessions: [TerminalSessionRecord] = []
    public var activeTerminalID: String?
    public var terminalTarget: TerminalTarget = .local
    public var terminalSSHHostID = ""
    public var terminalPorts: [TerminalPortRecord] = []
    public var terminalProtectedInputRequired = false
    public var terminalPendingApproval: ApprovalRecord?
    public var terminalHelperConnectionState: TerminalHelperConnectionState = .idle
    public var gitDiffOutput = ""
    public var gitStatusEntries: [GitStatusEntry] = []
    public var gitLogOutput = ""
    public var gitCommitMessage = ""
    public var browserURL = "http://localhost:5173"
    private var browserSourceTerminalID: String?
    public var discoveredSkills: [SkillDescriptor] = []
    public var plugins: [PluginInstallRecord] = []
    public var mcpServers: [MCPServerConfiguration] = []
    public var searchProviders: [SearchProviderConfiguration] = []
    public var scheduledTasks: [ScheduledTask] = []
    public var scheduledRuns: [ScheduledRunRecord] = []
    public var searchProviderHealth: [String: SearchProviderHealth] = [:]
    public var hooks: [HookDefinition] = []
    public var networkGrants: [NetworkGrant] = []
    public var networkRequests: [NetworkRequestRecord] = []
    public var networkStatusMessage = "网络策略：外部域名默认需要审批"
    public var sshHosts: [SSHHost] = []
    public var sshConnectionStatus: [String: SSHConnectionState] = [:]
    public var activityItems: [ActivityItem] = []
    public var agentWorkers: [AgentWorkerRecord] = []
    public var selectedAgentWorkerID: String?
    public var agentReplyDraft = ""
    public private(set) var controlPlanePairing: ControlPlanePairing?
    public var pendingApproval: PendingToolApproval?

    // 防抖缓冲区，用于减少流式更新频率
    private var streamingBuffer = ""
    private var streamingTask: Task<Void, Never>?
    private let streamingDebounceInterval: TimeInterval = 0.05  // 50ms

    public var workspaceEntries: [WorkspaceDirectoryEntry] = []
    public var fileTree: [WorkspaceFileNode] = []
    public var expandedFilePaths: Set<String> = []
    public var openEditorTabs: [EditorTab] = []
    public var selectedEditorTabID: String?
    public var editorBuffer = "" {
        didSet {
            guard !isSyncingEditorBuffer, let selectedEditorTabID, let index = openEditorTabs.firstIndex(where: { $0.id == selectedEditorTabID }) else { return }
            openEditorTabs[index].content = editorBuffer
            openEditorTabs[index].isDirty = editorBuffer != openEditorTabs[index].originalContent
            editorIsDirty = openEditorTabs[index].isDirty
        }
    }
    public var editorOriginalHash: String?
    public var editorIsDirty = false
    public var editorStatusMessage = "选择一个文件开始编辑"
    public var handoffPreview: HandoffEnginePreview?
    public var activeHandoffID: String?
    public var handoffStatusMessage = ""

    private let providerCatalog: ProviderCatalog?
    private let secretStore: (any SecretStore)?
    private let attachmentStore: AttachmentStore?
    private let eventStore: EventStore?
    private let repository: SessionRepository?
    private let sessionSupervisor: SessionSupervisor?
    private let harnessDaemon: LocalHarnessDaemon?
    private var connectedDaemonClient: DeepSeekDaemonClient?
    private var controlPlane: LocalControlPlane?
    private var controlPlaneEventObserverID: UUID?
    private let networkRuntime: NetworkRuntime
    private let sandboxPreflight: SandboxPreflightResult
    private let extensionStore: ExtensionStore?
    private let pluginRegistry: PluginRegistry?
    private let agentWorkerRegistry: AgentWorkerRegistry
    private let workerSessionCoordinator: WorkerSessionCoordinator?
    private let storageDirectory: URL
    private var selectedProjectID: String?
    private let localTerminalHost: LocalTerminalHost
    private let terminalBroker: PersistentTerminalSessionBroker
    private let terminalRegistry: PersistentTerminalRegistry?
    private let terminalTranscriptStore: TerminalTranscriptStore?
    private let terminalHelperManager: TerminalHelperProcessManager?
    private var terminalReadTasks: [String: Task<Void, Never>] = [:]
    private var terminalOutputBuffers: [String: TerminalOutputBuffer] = [:]
    private var agentRunControls: [String: AgentRunControl] = [:]
    private var agentRunTasks: [String: Task<Void, Never>] = [:]
    private var isSyncingEditorBuffer = false
    private let sshConnectionManager = SSHConnectionManager()
    private var cachedSelectedSessionID: String?
    private var cachedSelectedSessionEventCount = -1
    private var cachedSelectedSessionEvents: [SessionEvent] = []

    public enum RightPanel: String, CaseIterable, Identifiable, Sendable {
        case changes
        case files
        case browser
        case review
        case terminal

        public var id: String { rawValue }
        public var title: String { rawValue.capitalized }
    }

    public enum WorkspaceSection: String, CaseIterable, Identifiable, Sendable {
        case projects
        case sessions
        case agents
        case scheduled
        case skills
        case mcp
        case network
        case usage

        public var id: String { rawValue }
        public var title: String { rawValue.capitalized }
    }

    public init(storageDirectory customStorageDirectory: URL? = nil, secretStore providedSecretStore: (any SecretStore)? = nil, migrateElectronData shouldMigrateElectronData: Bool = true) {
        storageDirectory = customStorageDirectory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?.appendingPathComponent("DeepSeekCode", isDirectory: true) ?? FileManager.default.temporaryDirectory.appendingPathComponent("DeepSeekCode", isDirectory: true)
        _ = try? SessionMigrationCoordinator.backupLegacyStorageIfNeeded(root: storageDirectory)
        providerCatalog = try? ProviderCatalog(directory: storageDirectory)
        eventStore = try? EventStore(directory: storageDirectory.appendingPathComponent("LegacyEvents", isDirectory: true))
        repository = try? SessionRepository(directory: storageDirectory.appendingPathComponent("Database", isDirectory: true))
        if let repository {
            let supervisor = SessionSupervisor(repository: repository)
            sessionSupervisor = supervisor
            harnessDaemon = LocalHarnessDaemon(repository: repository, supervisor: supervisor)
        } else {
            sessionSupervisor = nil
            harnessDaemon = nil
        }
        agentWorkerRegistry = AgentWorkerRegistry(repository: repository)
        workerSessionCoordinator = repository.map { WorkerSessionCoordinator(repository: $0) }
        networkRuntime = NetworkRuntime(policy: .default, repository: repository)
        sandboxPreflight = SandboxRuntime.availability
        extensionStore = try? ExtensionStore(directory: storageDirectory.appendingPathComponent("Extensions", isDirectory: true))
        pluginRegistry = try? PluginRegistry(directory: storageDirectory.appendingPathComponent("Plugins", isDirectory: true))
        if let providedSecretStore {
            secretStore = providedSecretStore
        } else {
#if os(macOS)
            let fallbackDirectory = storageDirectory.appendingPathComponent("Secrets", isDirectory: true)
            if let localFallback = try? LocalFileSecretStore(directory: fallbackDirectory) {
                secretStore = ResilientSecretStore(
                    primary: KeychainSecretStore(allowsAuthenticationUI: false),
                    fallback: localFallback
                )
            } else {
                secretStore = KeychainSecretStore(allowsAuthenticationUI: false)
            }
#else
            secretStore = InMemorySecretStore()
#endif
        }
        attachmentStore = try? AttachmentStore(
            directory: storageDirectory.appendingPathComponent("Attachments", isDirectory: true),
            secretStore: secretStore ?? InMemorySecretStore()
        )
        let terminalRoot = storageDirectory.appendingPathComponent("TerminalRuntime", isDirectory: true)
        terminalRegistry = try? PersistentTerminalRegistry(root: terminalRoot)
        terminalTranscriptStore = try? TerminalTranscriptStore(root: terminalRoot, secretStore: secretStore ?? InMemorySecretStore())
        localTerminalHost = LocalTerminalHost(
            registry: terminalRegistry,
            transcriptStore: terminalTranscriptStore,
            socketPath: terminalRoot.appendingPathComponent("host.sock", isDirectory: false).path
        )
        if let helperBinary = Bundle.main.url(forResource: "DeepSeekCodeToolHost", withExtension: nil) {
            terminalHelperManager = TerminalHelperProcessManager(
                executableURL: helperBinary,
                root: terminalRoot.appendingPathComponent("Helper", isDirectory: true)
            )
        } else {
            terminalHelperManager = nil
        }
        let persistentHost: any PersistentTerminalHost
        if let terminalHelperManager {
            persistentHost = ProcessPersistentTerminalHost(manager: terminalHelperManager)
            terminalHelperConnectionState = .starting
        } else if let service = try? PersistentTerminalService(root: terminalRoot.appendingPathComponent("Fallback", isDirectory: true), secretStore: secretStore ?? InMemorySecretStore(), socketPath: terminalRoot.appendingPathComponent("fallback.sock").path) {
            persistentHost = service
            terminalHelperConnectionState = .legacy
        } else {
            persistentHost = LegacyPersistentTerminalHost(local: localTerminalHost)
            terminalHelperConnectionState = .legacy
        }
        let sshManager = sshConnectionManager
        terminalBroker = PersistentTerminalSessionBroker(
            localHost: persistentHost,
            sshResolver: { hostID in try await sshManager.persistentTerminalHost(hostID: hostID) }
        )
        if shouldMigrateElectronData { migrateElectronDataIfNeeded() }
        migrateLegacyJSONLEventsIfNeeded()
        if let catalog = providerCatalog, let profiles = try? catalog.list(), let profile = profiles.first {
            providerName = profile.name
            providerBaseURL = Self.normalizeProviderBaseURL(profile.baseURL)
            providerModel = DeepSeekModelCatalog.normalizedModel(profile.model)
            providerProtocol = profile.protocolName
            providerCapabilities = profile.capabilities
            visionAdapterEnabled = profile.visionAdapter?.enabled ?? false
            visionAdapterBaseURL = profile.visionAdapter?.baseURL ?? ""
            visionAdapterModel = profile.visionAdapter?.model ?? ""
        }
        reloadWorkspace()
        refreshExtensions()
        refreshNetworkState()
        recoverPersistedTerminals()
    }

    public var hasActiveSession: Bool { sessions.contains { $0.id == selectedSessionID } }
    public var selectedSession: Session { sessions.first(where: { $0.id == selectedSessionID }) ?? Session(id: "", title: "新建任务", target: .local, branch: "", status: .waiting, cost: "—") }
    public var activeTerminal: TerminalSessionRecord? {
        guard let activeTerminalID else { return terminalSessions.last }
        return terminalSessions.first(where: { $0.id == activeTerminalID })
    }
    public var activeTerminalOutput: String {
        guard let id = activeTerminal?.id else { return terminalOutput }
        return terminalOutputBuffers[id]?.text ?? terminalOutput
    }
    public var selectedEditorTab: EditorTab? { openEditorTabs.first(where: { $0.id == selectedEditorTabID }) }
    public var projectName: String {
        isScratchProject ? "快速对话" : (projectPath.split(separator: "/").last.map(String.init) ?? "未选择项目")
    }
    public var isScratchProject: Bool {
        !projectPath.isEmpty && URL(fileURLWithPath: projectPath).standardizedFileURL.path == scratchProjectURL.standardizedFileURL.path
    }
    public var isProjectTrusted: Bool { !projectPath.isEmpty && UserDefaults.standard.bool(forKey: trustKey) }
    public var autoModeAvailable: Bool { isProjectTrusted && sandboxAvailable }
    public var selectedSessionWorktreePath: String? { selectedSessionRecord?.worktreePath }
    public var selectedSessionBaselineRevision: String? { selectedSessionRecord?.baselineRevision }

    private var selectedSessionRecord: StoredSession? {
        guard let repository else { return nil }
        return try? repository.session(id: selectedSessionID)
    }

    public func chooseProject(_ path: String) {
        let normalized = URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true).standardizedFileURL.path
        projectPath = normalized
        guard let repository else {
            statusMessage = "项目已打开，但本地数据库不可用"
            return
        }
        do {
            if let existing = projects.first(where: { $0.path == normalized }) {
                selectedProjectID = existing.id
            } else {
                let project = try repository.createProject(name: projectName, path: normalized)
                selectedProjectID = project.id
            }
            reloadWorkspace()
            refreshFiles()
            Task { await refreshFileTree() }
            refreshGitStatus()
            refreshExtensions()
            statusMessage = sessions.isEmpty ? "项目已打开，输入任务以创建第一个 Session" : "项目已打开"
        } catch {
            statusMessage = "打开项目失败：\(error.localizedDescription)"
        }
    }

    public func setProjectTrusted(_ trusted: Bool) {
        guard !projectPath.isEmpty else { return }
        UserDefaults.standard.set(trusted, forKey: trustKey)
        statusMessage = trusted ? "项目已信任；Auto 仍需通过沙箱预检" : "项目已取消信任；Auto 已降级"
    }

    public func refreshComputerPermissionStatus() {
#if os(macOS)
        let accessibility = AXIsProcessTrusted()
        let screenCapture = CGPreflightScreenCaptureAccess()
        computerPermissionStatus = "辅助功能：\(accessibility ? "已授权" : "未授权") · 屏幕录制：\(screenCapture ? "已授权" : "未授权")"
#else
        computerPermissionStatus = "当前平台不支持 Computer Use"
#endif
    }

    public func refreshExtensions() {
        mcpServers = (try? extensionStore?.listMCP()) ?? []
        searchProviders = (try? extensionStore?.listSearchProviders()) ?? []
        scheduledTasks = (try? extensionStore?.listScheduled()) ?? []
        scheduledRuns = (try? repository?.scheduledRuns()) ?? []
        hooks = (try? extensionStore?.listHooks()) ?? []
        plugins = (try? pluginRegistry?.list()) ?? []
        sshHosts = (try? extensionStore?.listSSHHosts()) ?? []
        if !projectPath.isEmpty {
            discoveredSkills = (try? SkillCatalog.discover(projectDirectory: URL(fileURLWithPath: activeWorkspacePath, isDirectory: true))) ?? []
            discoveredSkills += (try? pluginRegistry?.enabledSkillDescriptors()) ?? []
        } else {
            discoveredSkills = []
        }
    }

    public func installPlugin(from url: URL) {
        do {
            let record = try pluginRegistry?.install(from: url)
            refreshExtensions()
            statusMessage = "Plugin 已安装，启用前请确认权限：\(record?.manifest.name ?? "")"
        } catch { statusMessage = "Plugin 安装失败：\(error.localizedDescription)" }
    }

    public func togglePlugin(id: String) {
        guard let current = plugins.first(where: { $0.id == id }) else { return }
        let next: PluginInstallState = current.state == .enabled ? .disabled : .enabled
        do {
            try pluginRegistry?.updateState(id: id, state: next)
            refreshExtensions()
            statusMessage = next == .enabled ? "Plugin 已启用；工具仍受现有权限链控制" : "Plugin 已停用"
        } catch { statusMessage = "Plugin 更新失败：\(error.localizedDescription)" }
    }

    public func refreshNetworkState() {
        networkGrants = (try? repository?.networkGrants()) ?? []
        networkRequests = (try? repository?.networkRequests(sessionID: hasActiveSession ? selectedSessionID : nil)) ?? []
        let pending = networkRequests.filter { $0.state == .requested || $0.state == .started }.count
        networkStatusMessage = pending == 0
            ? "网络策略：外部域名默认需要审批"
            : "网络执行中：\(pending) 个请求"
    }

    public func grantNetworkDomain(_ domain: String, capability: NetworkScope = .webFetch, operation: NetworkOperation = .read, scope: NetworkGrantScope = .session) {
        let normalized = domain.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty, !normalized.contains("/"), !normalized.contains(" "), !NetworkPolicy.isUnsafeHost(normalized) else {
            statusMessage = "域名格式无效"
            return
        }
        let grant = NetworkGrant(
            domain: normalized,
            capability: capability,
            operation: operation,
            scope: scope,
            sessionID: scope == .session || scope == .once ? selectedSessionID : nil,
            projectID: scope == .project ? selectedProjectID : nil
        )
        Task {
            await networkRuntime.addGrant(grant)
            refreshNetworkState()
            statusMessage = "已允许 \(normalized)（\(scope.rawValue)）"
        }
    }

    public func revokeNetworkGrant(id: String) {
        Task {
            await networkRuntime.revokeGrant(id: id)
            refreshNetworkState()
            statusMessage = "网络授权已撤销"
        }
    }

    public func toggleMCPServer(id: String) {
        guard let index = mcpServers.firstIndex(where: { $0.id == id }) else { return }
        mcpServers[index].enabled.toggle()
        try? extensionStore?.saveMCP(mcpServers[index])
        statusMessage = mcpServers[index].enabled ? "MCP Server 已启用" : "MCP Server 已停用"
    }

    public func saveSearchProvider(_ provider: SearchProviderConfiguration) {
        do {
            try extensionStore?.saveSearchProvider(provider)
            refreshExtensions()
            statusMessage = "Search Provider 已保存"
        } catch {
            statusMessage = "Search Provider 保存失败：\(error.localizedDescription)"
        }
    }

    public func toggleSearchProvider(id: String) {
        guard let index = searchProviders.firstIndex(where: { $0.id == id }) else { return }
        searchProviders[index].enabled.toggle()
        do {
            try extensionStore?.saveSearchProvider(searchProviders[index])
            statusMessage = searchProviders[index].enabled ? "Search Provider 已启用" : "Search Provider 已停用"
        } catch {
            statusMessage = "Search Provider 更新失败：\(error.localizedDescription)"
        }
    }

    public func testSearchProvider(id: String) {
        guard let configuration = searchProviders.first(where: { $0.id == id }) else { return }
        Task {
            do {
                let provider = try HTTPJSONSearchProvider(configuration: configuration, runtime: networkRuntime, secretStore: secretStore)
                let health = await provider.healthCheck()
                searchProviderHealth[id] = health
                statusMessage = health.reachable ? "Search Provider 可用：\(health.detail)" : "Search Provider 不可用：\(health.detail)"
            } catch {
                let health = SearchProviderHealth(providerID: id, reachable: false, detail: error.localizedDescription)
                searchProviderHealth[id] = health
                statusMessage = "Search Provider 测试失败：\(error.localizedDescription)"
            }
        }
    }

    public func saveSSHHost(_ host: SSHHost) {
        do {
            try extensionStore?.saveSSHHost(host)
            refreshExtensions()
            statusMessage = "SSH Host 已保存；首次连接需要核对 Host Key 指纹"
        } catch {
            statusMessage = "保存 SSH Host 失败：\(error.localizedDescription)"
        }
    }

    public func connectSSHHost(id: String, observedFingerprint: String, remotePath: String) {
        guard let host = sshHosts.first(where: { $0.id == id }) else {
            statusMessage = "找不到 SSH Host"
            return
        }
        statusMessage = "正在连接 SSH \(host.user)@\(host.hostname)…"
        Task {
            do {
                let transport = ProcessSSHRemoteTransport(host: host, remotePath: remotePath)
                _ = try await sshConnectionManager.connect(host: host, observedFingerprint: observedFingerprint, remotePath: remotePath, transport: transport)
                let state = await sshConnectionManager.state(hostID: host.id)
                sshConnectionStatus[host.id] = state
                statusMessage = "SSH \(host.hostname) 已连接；远程工具已注册"
            } catch {
                let state = await sshConnectionManager.state(hostID: host.id)
                sshConnectionStatus[host.id] = state
                statusMessage = "SSH 连接失败：\(error.localizedDescription)"
            }
        }
    }

    public func installAndConnectSSHHost(id: String, observedFingerprint: String) {
        guard let host = sshHosts.first(where: { $0.id == id }) else {
            statusMessage = "找不到 SSH Host"
            return
        }
        guard let binaryURL = Bundle.main.url(forResource: "DeepSeekCodeToolHost", withExtension: nil) else {
            statusMessage = "当前安装包未包含 SSH Tool Host；请重新安装完整 App"
            return
        }
        statusMessage = "正在校验并安装 SSH Tool Host 到 \(host.hostname)…"
        Task {
            do {
                let (_, receipt) = try await sshConnectionManager.installAndConnect(
                    host: host,
                    observedFingerprint: observedFingerprint,
                    binaryURL: binaryURL,
                    version: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
                )
                try? repository?.saveExtensionRecord(
                    PersistedExtensionRecord(
                        id: "\(host.id)-\(receipt.version)",
                        kind: "ssh-installation",
                        sessionID: host.id,
                        payload: ["remotePath": receipt.remotePath, "checksum": receipt.checksum, "hostVersion": receipt.handshake.hostVersion]
                    ),
                    table: "ssh_installations"
                )
                let state = await sshConnectionManager.state(hostID: host.id)
                sshConnectionStatus[host.id] = state
                statusMessage = "SSH Tool Host 已校验安装并完成握手：\(host.hostname)"
            } catch {
                let state = await sshConnectionManager.state(hostID: host.id)
                sshConnectionStatus[host.id] = state
                statusMessage = "SSH 安装失败：\(error.localizedDescription)"
            }
        }
    }

    public func createScheduledTask(prompt taskPrompt: String = "检查项目测试") {
        guard !projectPath.isEmpty else { isProjectPickerPresented = true; return }
        let allowedHosts = networkGrants
            .filter { $0.scope == .project || $0.scope == .user }
            .map(\.domain)
        let task = ScheduledTask(id: "daily-\(UUID().uuidString.prefix(8))", prompt: taskPrompt, projectPath: projectPath, schedule: "daily", enabled: true, allowedNetworkHosts: allowedHosts, networkGrantIDs: networkGrants.map(\.id))
        do {
            try extensionStore?.saveScheduled(task)
            let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/Library/DeepSeekCodeScheduler").path
            _ = try LaunchAgentManager().install(task: task, schedulerExecutable: helper)
            refreshExtensions()
            statusMessage = "已安装本地定时任务；未授权操作会停止并提醒"
        } catch {
            statusMessage = "创建定时任务失败：\(error.localizedDescription)"
        }
    }

    public func consumeScheduledTriggerFromLaunchArguments() {
        guard let index = CommandLine.arguments.firstIndex(of: "--scheduled-trigger"),
              CommandLine.arguments.indices.contains(index + 1) else { return }
        consumeScheduledTrigger(at: URL(fileURLWithPath: CommandLine.arguments[index + 1]))
    }

    public func consumeScheduledTrigger(at url: URL) {
        Task { @MainActor in
            do {
                let trigger = try ScheduledTriggerStore.consume(from: url)
                let task = trigger.task
                var scheduledRun = ScheduledRunRecord(id: trigger.id, taskID: task.id, status: task.isRunnable ? .running : .needsAttention)
                try? repository?.saveScheduledRun(scheduledRun)
                guard task.isRunnable else {
                    statusMessage = "定时任务配置无效，已停止"
                    return
                }
                executionTarget = .worktree
                mode = task.mode
                chooseProject(task.projectPath)
                guard !projectPath.isEmpty else { return }
                let allowed = task.allowedNetworkHosts
                let coordinator = ScheduledTaskCoordinator(repository: repository, networkPolicy: networkRuntime.policy)
                let safe = await coordinator.preflight(task: task, commands: ["git status"], networkHosts: allowed)
                guard safe else {
                    scheduledRun.status = .needsAttention
                    scheduledRun.updatedAt = Date()
                    try? repository?.saveScheduledRun(scheduledRun)
                    _ = await coordinator.needsAttention(scheduledRun, reason: "定时任务包含未授权联网或命令")
                    statusMessage = "定时任务包含未授权联网或命令，已暂停"
                    return
                }
                createSession(title: "Scheduled · \(task.prompt)")
                guard hasActiveSession else { return }
                try? repository?.append(sessionID: selectedSessionID, type: "scheduled_trigger_consumed", payload: ["runID": trigger.id, "taskID": task.id])
                sessionBudget = SessionBudget(maxToolTurns: 40, maxWallClockSeconds: max(30, task.maxRuntimeMinutes * 60), maxInputTokens: 120_000, maxOutputTokens: 24_000)
                await runAgent(promptOverride: task.prompt, sessionIDOverride: selectedSessionID)
                refreshSelectedSession()
                let succeeded = selectedSession.status == .completed || selectedSession.status == .delivered
                if succeeded {
                    scheduledRun.status = .completed
                    scheduledRun.updatedAt = Date()
                    try? repository?.saveScheduledRun(scheduledRun)
                    _ = await coordinator.complete(scheduledRun, succeeded: true, sessionID: selectedSessionID)
                } else {
                    _ = await coordinator.needsAttention(scheduledRun, reason: "定时任务未完成验证或等待用户审批", sessionID: selectedSessionID)
                }
                refreshExtensions()
            } catch {
                statusMessage = "读取定时任务触发器失败：\(error.localizedDescription)"
            }
        }
    }

    public func toggleScheduledTask(id: String) {
        guard let index = scheduledTasks.firstIndex(where: { $0.id == id }) else { return }
        scheduledTasks[index].enabled.toggle()
        do {
            try extensionStore?.saveScheduled(scheduledTasks[index])
            if scheduledTasks[index].enabled {
                let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/Library/DeepSeekCodeScheduler").path
                _ = try LaunchAgentManager().install(task: scheduledTasks[index], schedulerExecutable: helper)
            } else {
                try LaunchAgentManager().uninstall(taskID: scheduledTasks[index].id)
            }
            statusMessage = scheduledTasks[index].enabled ? "定时任务已恢复" : "定时任务已暂停"
        } catch {
            statusMessage = "更新定时任务失败：\(error.localizedDescription)"
        }
    }

    public func refreshSelectedSession() {
        guard let repository, hasActiveSession else {
            pendingApproval = nil
            usageSummary = UsageSummary()
            usageLedger = UsageLedger()
            verificationGraph = VerificationGraph(taskID: "")
            activeTaskContract = nil
            deliveryGateResult = nil
            reviewFindings = []
            reviewUpdatedAt = nil
            githubDeliveries = []
            ciFailureEvidence = nil
            ciLogOutput = ""
            activityItems = []
            agentWorkers = []
            selectedAgentWorkerID = nil
            conversationMessages = []
            conversationTimeline = []
            cachedSelectedSessionID = nil
            cachedSelectedSessionEventCount = -1
            cachedSelectedSessionEvents = []
            terminalSessions = []
            activeTerminalID = nil
            terminalOutputBuffers = [:]
            terminalProtectedInputRequired = false
            return
        }
        let eventCount = (try? repository.eventCount(sessionID: selectedSessionID)) ?? 0
        if cachedSelectedSessionID == selectedSessionID && cachedSelectedSessionEventCount == eventCount {
            return
        }
        let events: [SessionEvent]
        if cachedSelectedSessionID == selectedSessionID,
           cachedSelectedSessionEventCount >= 0,
           eventCount >= cachedSelectedSessionEventCount,
           cachedSelectedSessionEvents.count == cachedSelectedSessionEventCount {
            let sequence = cachedSelectedSessionEvents.last?.sequence ?? 0
            let delta = (try? repository.events(sessionID: selectedSessionID, afterSequence: sequence)) ?? []
            events = cachedSelectedSessionEvents + delta
        } else {
            events = (try? repository.events(sessionID: selectedSessionID)) ?? []
        }
        conversationMessages = ConversationProjector.project(events: events)
        if let partSnapshot = try? repository.sessionParts(sessionID: selectedSessionID),
           partSnapshot.cursorSequence == eventCount {
            conversationTimeline = ConversationProjector.timeline(parts: partSnapshot.parts)
        } else if let partSnapshot = try? repository.refreshPartProjection(sessionID: selectedSessionID) {
            conversationTimeline = ConversationProjector.timeline(parts: partSnapshot.parts)
        } else {
            conversationTimeline = ConversationProjector.timeline(events: events)
        }
        agentWorkers = agentWorkerRegistry.records(sessionID: selectedSessionID)
        if selectedAgentWorkerID == nil || !agentWorkers.contains(where: { $0.id == selectedAgentWorkerID }) {
            selectedAgentWorkerID = agentWorkers.first?.id
        }
        executionTarget = selectedSession.target
        let storedTerminals = (try? repository.terminalSessions(sessionID: selectedSessionID)) ?? []
        if activeTerminalID == nil || !terminalSessions.contains(where: { $0.sessionID == selectedSessionID }) {
            terminalSessions = storedTerminals
            Task { await terminalBroker.register(records: storedTerminals) }
            activeTerminalID = storedTerminals.last?.id
            terminalTarget = storedTerminals.last?.target ?? (selectedSession.target == .worktree ? .worktree : .local)
        }
        let graph = VerificationGraph.project(taskID: selectedSessionID, events: events)
        verificationGraph = graph
        if let reviewEvent = events.last(where: { $0.type == "review_completed" }),
           let encodedFindings = reviewEvent.payload["findings"]?.data(using: .utf8),
           let findings = try? JSONDecoder().decode([ReviewFinding].self, from: encodedFindings) {
            reviewFindings = findings
            reviewUpdatedAt = reviewEvent.timestamp
        } else {
            reviewFindings = []
            reviewUpdatedAt = nil
        }
        if let stored = (try? repository.session(id: selectedSessionID)) ?? nil {
            let projection = (try? SessionProjector.project(session: stored, events: events)) ?? ProjectedSessionState(session: stored)
            usageLedger = UsageLedger.project(events: events, pricing: currentProfile)
            usageSummary = usageLedger.total
            updateSelectedSessionListEntry(storedSession: stored, projected: projection)
        }
        pendingApproval = ((try? repository.runState(sessionID: selectedSessionID)) ?? nil)?.pendingApproval
        activeTaskContract = try? repository.taskContract(sessionID: selectedSessionID)
        githubDeliveries = (try? repository.githubDeliveries(sessionID: selectedSessionID)) ?? []
        if let ciEvent = events.last(where: { $0.type == "ci_failure_evidence" }),
           let encoded = ciEvent.payload["evidence"],
           let data = encoded.data(using: .utf8) {
            ciFailureEvidence = try? JSONDecoder().decode(CIFailureEvidence.self, from: data)
        } else {
            ciFailureEvidence = nil
        }
        deliveryGateResult = evaluateDeliveryGate()
        activityItems = events.suffix(40).compactMap { event in
            switch event.type {
            case "tool_completed": ActivityItem(title: event.payload["tool"] ?? "工具", detail: "工具调用完成", state: event.payload["ok"] == "true" ? "完成" : "失败")
            case "tool_blocked": ActivityItem(title: event.payload["tool"] ?? "工具", detail: "权限策略阻止", state: "已阻止")
            case "approval_requested": ActivityItem(title: event.payload["tool"] ?? "工具", detail: "需要 L\(event.payload["risk"] ?? "?") 审批", state: "等待审批")
            case "approval_resolved": ActivityItem(title: "审批", detail: event.payload["decision"] ?? "", state: "已处理")
            default: nil
            }
        }
        cachedSelectedSessionID = selectedSessionID
        cachedSelectedSessionEventCount = events.count
        cachedSelectedSessionEvents = events
    }

    public func recoverPersistedTerminals() {
        guard let repository, !selectedSessionID.isEmpty else { return }
        if terminalHelperManager != nil { terminalHelperConnectionState = .reconnecting }
        do {
            terminalSessions = try TerminalRuntimeRecoveryCoordinator(repository: repository).recover(sessionID: selectedSessionID)
            Task { await terminalBroker.register(records: terminalSessions) }
            activeTerminalID = terminalSessions.last?.id
            terminalTarget = terminalSessions.last?.target ?? (selectedSession.target == .worktree ? .worktree : .local)
            terminalOutputBuffers = [:]
            for record in terminalSessions {
                let chunks = (try? terminalTranscriptStore?.read(terminalID: record.id, afterSequence: -1, maxBytes: 128_000)) ?? []
                var buffer = TerminalOutputBuffer()
                chunks.forEach { buffer.append($0.text) }
                if !buffer.text.isEmpty { terminalOutputBuffers[record.id] = buffer }
            }
            terminalPorts = terminalSessions.flatMap { record in
                (try? repository.terminalPorts(terminalID: record.id)) ?? []
            }
            syncLegacyTerminalProjection()
            if terminalSessions.contains(where: { [.indeterminate, .needsAttention].contains($0.state) }) {
                statusMessage = "检测到上次 Terminal 状态未知；未自动重放，请检查 Needs attention"
            }
            if let terminalHelperManager {
                let recoverySessionID = selectedSessionID
                Task { [weak self] in
                    let helperHost = ProcessPersistentTerminalHost(manager: terminalHelperManager)
                    do {
                        let recovered = try await PersistentTerminalRecoveryCoordinator(repository: repository, host: helperHost).recover(sessionID: recoverySessionID)
                        var replayedOutput: [String: String] = [:]
                        for record in recovered {
                            if let chunks = try? await helperHost.read(terminalID: record.id, afterSequence: -1, maxBytes: 128_000) {
                                replayedOutput[record.id] = chunks.map(\.text).joined()
                            }
                        }
                        await self?.terminalBroker.register(records: recovered)
                        await MainActor.run {
                            guard let self, self.selectedSessionID == recoverySessionID else { return }
                            self.terminalHelperConnectionState = .connected
                            self.terminalSessions = recovered
                            self.activeTerminalID = recovered.last?.id
                            for record in recovered {
                                var buffer = TerminalOutputBuffer()
                                buffer.append(replayedOutput[record.id] ?? "")
                                if !buffer.text.isEmpty { self.terminalOutputBuffers[record.id] = buffer }
                            }
                            self.syncLegacyTerminalProjection()
                            if recovered.contains(where: { $0.state == .needsAttention }) {
                                self.statusMessage = "Terminal Helper 已返回状态，但有终端需要确认；未自动重放"
                            }
                        }
                    } catch {
                        await MainActor.run { [weak self] in
                            guard let self, self.selectedSessionID == recoverySessionID else { return }
                            self.terminalHelperConnectionState = .needsAttention
                            self.statusMessage = "Terminal Helper 恢复失败：\(error.localizedDescription)；未自动重放"
                        }
                    }
                }
            }
        } catch {
            statusMessage = "恢复 Terminal 状态失败：\(error.localizedDescription)"
        }
    }

    public func createSession(title: String? = nil) {
        guard let repository else {
            statusMessage = "本地 Session 数据库不可用"
            return
        }
        do {
            if selectedProjectID == nil {
                let scratch = try ensureScratchProject(repository: repository)
                selectedProjectID = scratch.id
                projectPath = scratch.path
            }
            guard let selectedProjectID else { return }
            let text = (title ?? prompt).trimmingCharacters(in: .whitespacesAndNewlines)
            let titleText = text.isEmpty ? "新建对话" : String(text.prefix(60))
            let branch = executionTarget == .local ? "main" : "deepseek/\(slug(titleText))"
            var worktreePath: String?
            var baselineRevision: String?
            let git = isScratchProject ? nil : try? GitService(root: URL(fileURLWithPath: projectPath, isDirectory: true))
            baselineRevision = try? git?.currentRevision()
            if executionTarget == .worktree {
                let worktreeRoot = storageDirectory.appendingPathComponent("Worktrees", isDirectory: true)
                let path = worktreeRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
                guard let git else { throw GitError(command: "worktree", detail: "项目不是 Git 仓库") }
                guard let baselineRevision, !baselineRevision.isEmpty else {
                    throw GitError(command: "worktree", detail: "Worktree 必须基于已有 Commit；请先提交仓库初始版本")
                }
                _ = try git.createWorktree(path: path, branch: branch, base: baselineRevision)
                worktreePath = path.path
            }
            let session = try repository.createSession(projectID: selectedProjectID, title: titleText, mode: mode, target: executionTarget, branch: branch, worktreePath: worktreePath, baselineRevision: baselineRevision)
            let contract = TaskContract.compatibility(prompt: titleText, budget: sessionBudget)
            try repository.saveTaskContract(contract, sessionID: session.id)
            try repository.append(sessionID: session.id, type: "task_contract_created", payload: [
                "goal": contract.goal,
                "requiredChanges": "\(contract.requiredChanges.count)",
                "requiredTests": "\(contract.requiredTests.count)"
            ])
            if let worktreePath, let baselineRevision {
                try repository.saveWorktree(WorktreeRecord(sessionID: session.id, baseRevision: baselineRevision, branch: branch, worktreePath: worktreePath))
            }
            selectedSessionID = session.id
            reloadWorkspace()
            refreshSelectedSession()
            statusMessage = isScratchProject ? "已创建快速对话" : "已创建 Session"
        } catch {
            statusMessage = "创建 Session 失败：\(error.localizedDescription)"
        }
    }

    public func renameSelectedSession(to title: String) {
        guard let repository, hasActiveSession, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        do {
            try repository.renameSession(id: selectedSessionID, title: title.trimmingCharacters(in: .whitespacesAndNewlines))
            reloadWorkspace()
        } catch {
            statusMessage = "重命名失败：\(error.localizedDescription)"
        }
    }

    public func archiveSelectedSession() {
        guard let repository, hasActiveSession else { return }
        do {
            try repository.archiveSession(id: selectedSessionID)
            reloadWorkspace()
            statusMessage = "Session 已归档"
        } catch {
            statusMessage = "归档失败：\(error.localizedDescription)"
        }
    }

    public func deleteSelectedSession() {
        guard let repository, hasActiveSession else { return }
        let sessionID = selectedSessionID
        do {
            let backupDirectory = storageDirectory.appendingPathComponent("DeletedSessions", isDirectory: true)
            let receipt = try repository.deleteSession(id: sessionID, backupDirectory: backupDirectory)
            cachedSelectedSessionID = nil
            cachedSelectedSessionEventCount = -1
            cachedSelectedSessionEvents = []
            reloadWorkspace()
            refreshSelectedSession()
            statusMessage = "Session 已删除；本地备份保留在 \(receipt.backupURL.lastPathComponent)"
        } catch {
            statusMessage = "删除 Session 失败：\(error.localizedDescription)"
        }
    }

    public func restoreDeletedSession(from backupURL: URL) {
        guard let repository else { return }
        do {
            let restored = try repository.restoreSession(from: backupURL)
            selectedSessionID = restored.id
            reloadWorkspace()
            refreshSelectedSession()
            statusMessage = "Session 已从本地备份恢复"
        } catch {
            statusMessage = "恢复 Session 失败：\(error.localizedDescription)"
        }
    }

    public func forkSelectedSession() {
        guard let repository, hasActiveSession else { return }
        do {
            let fork = try repository.forkSession(id: selectedSessionID, title: "\(selectedSession.title) · Fork")
            selectedSessionID = fork.id
            reloadWorkspace()
            statusMessage = "已创建 Fork Session"
        } catch {
            statusMessage = "Fork 失败：\(error.localizedDescription)"
        }
    }

    public func prepareHandoff() {
        guard let repository, hasActiveSession, selectedSession.target == .worktree, let worktreePath = selectedSessionWorktreePath else {
            handoffStatusMessage = "只有 Worktree Session 可以执行 Handoff"
            return
        }
        guard let baseline = selectedSessionBaselineRevision else {
            handoffStatusMessage = "缺少 Worktree 基线 Commit"
            return
        }
        let localRoot = URL(fileURLWithPath: projectPath, isDirectory: true)
        let incomingRoot = URL(fileURLWithPath: worktreePath, isDirectory: true)
        Task {
            do {
                let baseFiles = try await Task.detached(priority: .userInitiated) {
                    let git = try GitService(root: localRoot)
                    return try git.textFiles(revision: baseline)
                }.value
                let preview = try WorktreeHandoffEngine().preview(baseFiles: baseFiles, localRoot: localRoot, incomingRoot: incomingRoot)
                let transaction = try repository.createHandoff(sessionID: selectedSessionID, destination: .local, baseRevision: baseline)
                handoffPreview = preview
                activeHandoffID = transaction.id
                try repository.saveHandoffFiles(handoffID: transaction.id, files: preview.files)
                handoffStatusMessage = preview.isClean ? "Handoff 已准备，可应用无冲突文件" : "发现 \(preview.conflicts.count) 个冲突，请先解决"
                try repository.append(sessionID: selectedSessionID, type: "handoff_previewed", payload: ["handoffID": transaction.id, "conflicts": "\(preview.conflicts.count)"])
            } catch {
                handoffStatusMessage = "Handoff 预览失败：\(error.localizedDescription)"
            }
        }
    }

    public func applyHandoff(paths: Set<String>? = nil) {
        guard let repository, let handoffPreview, let activeHandoffID, let workspace = try? toolHost() else { return }
        let selected = handoffPreview.files.filter { paths == nil || paths?.contains($0.path) == true }
        guard selected.allSatisfy({ $0.state != .conflict }) else {
            handoffStatusMessage = "冲突文件不能自动应用"
            return
        }
        Task {
            do {
                try repository.updateHandoff(id: activeHandoffID, state: .applying)
                let result = try WorktreeHandoffEngine().applyCleanFiles(selected, to: workspace)
                try repository.updateHandoff(id: activeHandoffID, state: .applied)
                try repository.append(sessionID: selectedSessionID, type: "handoff_applied", payload: ["handoffID": activeHandoffID, "checkpointID": result.checkpointID.uuidString, "files": result.changedFiles.joined(separator: ",")])
                let evidence = EvidenceRecord(taskID: selectedSessionID, kind: .checkpoint, title: "Handoff", detail: "已应用 \(result.changedFiles.count) 个文件；Checkpoint \(result.checkpointID.uuidString)", succeeded: true)
                verificationGraph = VerificationGraph(
                    taskID: selectedSessionID,
                    nodes: verificationGraph.nodes + [VerificationNode(title: "Handoff", state: .passed, evidenceIDs: [evidence.id])],
                    evidenceRecords: verificationGraph.evidenceRecords + [evidence]
                )
                try repository.append(sessionID: selectedSessionID, type: "evidence_recorded", payload: [
                    "id": evidence.id,
                    "kind": evidence.kind.rawValue,
                    "title": evidence.title,
                    "detail": evidence.detail,
                    "succeeded": "true"
                ])
                handoffStatusMessage = "已应用 \(result.changedFiles.count) 个文件，Checkpoint \(result.checkpointID.uuidString.prefix(8))"
                refreshGitStatus()
            } catch {
                try? repository.updateHandoff(id: activeHandoffID, state: .indeterminate)
                handoffStatusMessage = "Handoff 应用失败：\(error.localizedDescription)"
            }
        }
    }

    public func abortHandoff() {
        guard let repository, let activeHandoffID else { return }
        try? repository.updateHandoff(id: activeHandoffID, state: .aborted)
        handoffPreview = nil
        handoffStatusMessage = "已放弃 Handoff；Worktree 保留"
    }

    public func sendTask() {
        let outgoingPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !outgoingPrompt.isEmpty || !composerAttachments.isEmpty else { return }
        let effectivePrompt = outgoingPrompt.isEmpty ? "请分析这些附件，并根据结果完成任务。" : outgoingPrompt
        if !hasActiveSession { createSession(title: effectivePrompt) }
        guard hasActiveSession else { return }
        let sessionID = selectedSessionID
        let outgoingAttachments = composerAttachments
        let outgoingParts = [ContentPart.text(effectivePrompt)] + outgoingAttachments.map { attachment in
            switch attachment.kind {
            case .image, .browserSnapshot, .computerSnapshot: return ContentPart.image(attachment)
            default: return ContentPart.document(attachment)
            }
        }
        let message = ConversationMessage(role: .user, text: effectivePrompt, attachments: outgoingAttachments)
        conversationMessages.append(message)
        // The Supervisor owns the durable user_message event. This temporary
        // card gives the composer immediate feedback and is replaced by the
        // projection once input admission returns a stable event ID.
        let optimisticEntryID = "pending-user-\(UUID().uuidString)"
        conversationTimeline = ConversationProjector.deduplicatedTimeline(
            conversationTimeline + [ConversationEntry(id: optimisticEntryID, kind: .user, text: effectivePrompt, attachments: outgoingAttachments)]
        )
        prompt = ""
        composerAttachments.removeAll()
        attachmentStatusMessage = ""
        if agentWorkers.contains(where: { $0.sessionID == sessionID && $0.kind == .main && $0.isLive }) {
            let idempotencyKey = UUID().uuidString
            statusMessage = "正在加入本轮结束后的输入队列…"
            if let sessionSupervisor {
                Task { [weak self] in
                    do {
                        _ = try await sessionSupervisor.admit(SessionInput(
                            sessionID: sessionID,
                            idempotencyKey: idempotencyKey,
                            delivery: .deferred,
                            parts: outgoingParts
                        ))
                        self?.statusMessage = "已加入本轮结束后的输入队列"
                    } catch {
                        self?.statusMessage = "补充任务入队失败：\(error.localizedDescription)"
                    }
                }
            } else {
                do {
                    _ = try repository?.enqueueSessionInput(
                        sessionID: sessionID,
                        idempotencyKey: idempotencyKey,
                        delivery: .deferred,
                        parts: outgoingParts
                    )
                    statusMessage = "已加入本轮结束后的输入队列"
                } catch {
                    statusMessage = "补充任务入队失败：\(error.localizedDescription)"
                }
            }
            return
        }
        statusMessage = "Agent 正在准备…"
        updateSelectedSessionStatus(.running)
        let route = TaskRouter.route(TaskRoutingInput(
            prompt: effectivePrompt,
            mode: mode,
            hasAttachments: outgoingParts.contains { if case .text = $0 { return false }; return true },
            hasProject: !isScratchProject
        ))
        if DaemonExecutionEligibility.isEligible(
            target: executionTarget,
            parts: outgoingParts,
            route: route,
            hasEnabledHooks: hooks.contains { $0.enabled && $0.trusted },
            hasEnabledMCP: mcpServers.contains { $0.enabled && $0.trusted }
        ) {
            startDaemonAgentRun(sessionID: sessionID, parts: outgoingParts)
            return
        }
        if let sessionSupervisor {
            Task { [weak self] in
                guard let self else { return }
                do {
                    if let repository = self.repository {
                        try SessionRuntimeOwnership.assign(
                            .foregroundApp,
                            sessionID: sessionID,
                            repository: repository,
                            instanceID: "DeepSeekCodeApp-\(ProcessInfo.processInfo.processIdentifier)",
                            commandID: "runtime-owner-foreground-\(sessionID)-\(UUID().uuidString)"
                        )
                    }
                    _ = try await sessionSupervisor.admit(SessionInput(
                        sessionID: sessionID,
                        idempotencyKey: "send-\(UUID().uuidString)",
                        delivery: .immediate,
                        parts: outgoingParts
                    ))
                    if let next = try await sessionSupervisor.promoteNextInput(sessionID: sessionID) {
                        await sessionSupervisor.consumeInput(id: next.id)
                    }
                    self.startAgentRun(promptOverride: effectivePrompt, partsOverride: outgoingParts, sessionIDOverride: sessionID)
                } catch {
                    self.statusMessage = "任务入队失败：\(error.localizedDescription)"
                    self.updateSelectedSessionStatus(.failed)
                }
            }
        } else {
            startAgentRun(promptOverride: effectivePrompt, partsOverride: outgoingParts, sessionIDOverride: sessionID)
        }
    }

    /// Sends supported GUI tasks through the same `deepseekd` Supervisor as
    /// the CLI. Foreground-only capabilities are intentionally screened by
    /// `DaemonExecutionEligibility` before reaching this method.
    private func startDaemonAgentRun(sessionID: String, parts: [ContentPart]) {
        let worker = agentWorkerRegistry.create(sessionID: sessionID, prompt: parts.plainText, kind: .main)
        agentWorkerRegistry.transition(
            id: worker.id,
            state: .running,
            detail: "由 deepseekd 执行",
            checkpoint: AgentWorkerCheckpoint(title: "Runtime", detail: "已交给本地 daemon")
        )
        agentWorkers = agentWorkerRegistry.records(sessionID: sessionID)
        selectedAgentWorkerID = worker.id
        agentRunTasks[sessionID] = Task { [weak self] in
            guard let self else { return }
            do {
                let client = try await self.daemonClient()
                let receipt = try await self.sendDaemon(
                    .inputAdmit,
                    payload: DeepSeekDaemonInputPayload(
                        sessionID: sessionID,
                        idempotencyKey: "gui-daemon-\(UUID().uuidString)",
                        delivery: .immediate,
                        parts: parts
                    ),
                    client: client
                )
                _ = receipt
                _ = try await self.sendDaemon(
                    .sessionStart,
                    payload: DeepSeekDaemonSessionPayload(sessionID: sessionID),
                    client: client
                )
                await self.followDaemonSession(sessionID: sessionID, workerID: worker.id, client: client)
            } catch {
                self.agentWorkerRegistry.transition(id: worker.id, state: .needsAttention, detail: "deepseekd 不可用", errorMessage: error.localizedDescription)
                self.agentWorkers = self.agentWorkerRegistry.records(sessionID: sessionID)
                self.statusMessage = "本地 Runtime 启动失败：\(error.localizedDescription)"
                self.updateSelectedSessionStatus(.needsAttention)
            }
        }
    }

    private func daemonClient() async throws -> DeepSeekDaemonClient {
        if let connectedDaemonClient,
           let response = try? await connectedDaemonClient.send(DeepSeekDaemonRequest(method: .handshake)),
           response.ok {
            return connectedDaemonClient
        }
        let client = try await DeepSeekDaemonLauncher.connect(storageRoot: storageDirectory)
        connectedDaemonClient = client
        return client
    }

    private func sendDaemon<T: Encodable>(
        _ method: DeepSeekDaemonMethod,
        payload: T,
        client: DeepSeekDaemonClient
    ) async throws -> DeepSeekDaemonResponse {
        let encoded = String(decoding: try DeepSeekDaemonJSON.encoder.encode(payload), as: UTF8.self)
        let response = try await client.send(DeepSeekDaemonRequest(method: method, payload: encoded))
        guard response.ok else { throw UnifiedRuntimeError.remote(response.output) }
        return response
    }

    private func followDaemonSession(sessionID: String, workerID: String, client: DeepSeekDaemonClient) async {
        var cursor = (try? repository?.events(sessionID: sessionID).last?.sequence) ?? 0
        let deadline = Date().addingTimeInterval(600)
        while Date() < deadline, !Task.isCancelled {
            do {
                let eventsResponse = try await sendDaemon(
                    .sessionEvents,
                    payload: DeepSeekDaemonEventsPayload(sessionID: sessionID, afterSequence: cursor),
                    client: client
                )
                let events = try DeepSeekDaemonJSON.decoder.decode([SessionEvent].self, from: Data(eventsResponse.output.utf8))
                if let last = events.last { cursor = max(cursor, last.sequence) }
                refreshSelectedSession()
                let receiptResponse = try await sendDaemon(
                    .sessionAttach,
                    payload: DeepSeekDaemonSessionPayload(sessionID: sessionID),
                    client: client
                )
                let receipt = try DeepSeekDaemonJSON.decoder.decode(SessionAttachReceipt.self, from: Data(receiptResponse.output.utf8))
                if receipt.status == .awaitingToolApproval || receipt.status == .awaitingApproval {
                    agentWorkerRegistry.transition(id: workerID, state: .waitingApproval, detail: "等待用户审批")
                    pendingApproval = (try? repository?.runState(sessionID: sessionID))??.pendingApproval
                    statusMessage = "任务等待审批"
                    break
                }
                if [.completed, .delivered, .needsRepair, .needsAttention, .failed].contains(receipt.status) {
                    let state: AgentWorkerState = receipt.status == .failed || receipt.status == .needsAttention ? .needsAttention : .completed
                    agentWorkerRegistry.transition(id: workerID, state: state, detail: receipt.status.title)
                    finalizeTaskContract(sessionID: sessionID)
                    break
                }
                try await Task.sleep(nanoseconds: 150_000_000)
            } catch {
                agentWorkerRegistry.transition(id: workerID, state: .needsAttention, detail: "daemon 连接中断", errorMessage: error.localizedDescription)
                statusMessage = "本地 Runtime 连接中断：\(error.localizedDescription)"
                break
            }
        }
        agentRunTasks[sessionID] = nil
        agentWorkers = agentWorkerRegistry.records(sessionID: sessionID)
        refreshSelectedSession()
    }

    /// Starts a supervised Agent run and keeps a cancellable control handle so
    /// the run remains visible and manageable from the Agents view.
    public func startAgentRun(promptOverride: String? = nil, partsOverride: [ContentPart] = [], sessionIDOverride: String? = nil) {
        let runSessionID = sessionIDOverride ?? selectedSessionID
        let userPrompt = (promptOverride ?? prompt).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !runSessionID.isEmpty, !userPrompt.isEmpty else { return }
        if let existing = agentWorkers.first(where: { $0.sessionID == runSessionID && $0.kind == .main && $0.isLive }) {
            statusMessage = "该 Session 已有 Agent 在运行：\(existing.detail)"
            return
        }
        let worker = agentWorkerRegistry.create(sessionID: runSessionID, prompt: userPrompt, kind: .main)
        let control = AgentRunControl()
        agentRunControls[runSessionID] = control
        agentWorkerRegistry.transition(id: worker.id, state: .running, detail: "准备上下文", checkpoint: AgentWorkerCheckpoint(title: "准备上下文", detail: "等待模型请求"))
        agentWorkers = agentWorkerRegistry.records(sessionID: runSessionID)
        selectedAgentWorkerID = worker.id
        let executionDriver = ClosureSessionExecutionDriver(
            onStart: { [weak self] sessionID in
                guard let self else { return }
                await self.runAgent(promptOverride: userPrompt, partsOverride: partsOverride, sessionIDOverride: sessionID, workerID: worker.id, control: control)
            },
            onPause: { [weak self] sessionID in
                await self?.requestPauseForSupervisor(sessionID: sessionID)
            },
            onResume: { [weak self] sessionID in
                await self?.requestResumeForSupervisor(sessionID: sessionID)
            },
            onResolveApproval: { [weak self] sessionID, approvalID, decision in
                await self?.resumeAgentApprovalForSupervisor(sessionID: sessionID, approvalID: approvalID, decision: decision)
            },
            onCancel: { [weak self] sessionID in
                await self?.requestCancelForSupervisor(sessionID: sessionID)
            }
        )
        let task = Task<Void, Never> { [weak self] in
            guard let self else { return }
            if let supervisor = self.sessionSupervisor {
                do {
                    await supervisor.installExecutionDriver(executionDriver, sessionID: runSessionID)
                    try await supervisor.start(sessionID: runSessionID)
                } catch {
                    self.agentWorkerRegistry.transition(
                        id: worker.id,
                        state: .needsAttention,
                        detail: "无法取得 Session 写入租约",
                        errorMessage: error.localizedDescription
                    )
                    self.agentWorkers = self.agentWorkerRegistry.records(sessionID: runSessionID)
                    self.statusMessage = error.localizedDescription
                    return
                }
                let pendingApproval = self.repository.flatMap { try? $0.runState(sessionID: runSessionID) }?.pendingApproval
                if pendingApproval == nil,
                   let next = try? await supervisor.promoteNextInput(sessionID: runSessionID) {
                    await supervisor.consumeInput(id: next.id)
                    await supervisor.release(sessionID: runSessionID)
                    self.statusMessage = "正在处理已排队的补充任务…"
                    self.startAgentRun(promptOverride: next.parts.plainText, partsOverride: next.parts, sessionIDOverride: runSessionID)
                } else {
                    await supervisor.release(sessionID: runSessionID)
                }
            } else {
                await self.runAgent(promptOverride: userPrompt, partsOverride: partsOverride, sessionIDOverride: runSessionID, workerID: worker.id, control: control)
            }
        }
        agentRunTasks[runSessionID] = task
    }

    private func requestPauseForSupervisor(sessionID: String) async {
        if let control = agentRunControls[sessionID] {
            await control.requestPause()
        }
    }

    private func requestResumeForSupervisor(sessionID: String) async {
        if let control = agentRunControls[sessionID] {
            await control.resume()
        }
    }

    private func requestCancelForSupervisor(sessionID: String) async {
        if let control = agentRunControls[sessionID] {
            await control.requestStop()
        }
    }

    private func resumeAgentApprovalForSupervisor(sessionID: String, approvalID: String, decision: ApprovalDecision) async {
        print("→ [APPROVAL] resumeAgentApprovalForSupervisor called: sessionID=\(sessionID), approvalID=\(approvalID)")

        guard let eventStore else {
            print("❌ [APPROVAL] eventStore is nil")
            return
        }
        guard let apiKey = loadAPIKey() else {
            print("❌ [APPROVAL] apiKey is nil")
            return
        }

        let profile = currentProfile
        let workerID = agentWorkers.first(where: { $0.sessionID == sessionID && $0.kind == .main && $0.state == .waitingApproval })?.id

        do {
            let client = try ProviderClientFactory.make(
                profile: profile,
                apiKey: apiKey,
                attachmentProvider: attachmentStore,
                networkRuntime: networkRuntime,
                networkContext: NetworkContext(sessionID: sessionID, projectID: selectedProjectID, purpose: .providerRequest, requestedBy: "supervisor-approval-resume")
            )
            let workspaceHost = isScratchProject ? nil : try? toolHost()
            let runtime = makeToolRuntime(workspace: workspaceHost)
            await prepareMCPRuntime(registry: runtime.registry, router: runtime.router)
            let host = NativeAgentHost(
                client: client,
                eventStore: eventStore,
                workspace: workspaceHost,
                repository: repository,
                projectTrusted: isProjectTrusted,
                sandboxAvailable: sandboxAvailable,
                toolRouter: runtime.router,
                toolRegistry: runtime.registry,
                hooks: hooks,
                defaultPricing: profile,
                networkRuntime: networkRuntime,
                hookManifest: hookManifest(sessionID: sessionID)
            )
            let orchestrator = NativeSessionOrchestrator(host: host)
            pendingApproval = nil

            print("→ [APPROVAL] Starting Agent resume stream...")
            var eventCount = 0
            for try await event in orchestrator.resume(sessionID: sessionID, approvalID: approvalID, decision: decision) {
                eventCount += 1
                print("→ [APPROVAL] Event #\(eventCount): \(event)")
                apply(event: event, profile: profile)
                if let workerID { updateAgentWorker(for: workerID, event: event) }
            }
            print("✅ [APPROVAL] Agent resume completed, received \(eventCount) events")

            refreshGitStatus()
            finalizeTaskContract(sessionID: sessionID)
        } catch {
            print("❌ [APPROVAL] Resume failed with error: \(error)")
            statusMessage = "审批恢复失败：\(error.localizedDescription)"
            _ = try? repository?.appendDurable(sessionID: sessionID, type: "harness_approval_resume_failed", payload: ["approvalID": approvalID, "message": SecretRedactor.redact(error.localizedDescription)])
        }
    }

    public func pauseAgent(workerID: String) {
        guard let worker = agentWorkers.first(where: { $0.id == workerID }), let control = agentRunControls[worker.sessionID] else { return }
        agentWorkerRegistry.transition(id: workerID, state: .pausing, detail: "暂停请求已提交；将在安全检查点暂停")
        try? repository?.append(sessionID: worker.sessionID, type: "agent_worker_pause_requested", payload: ["workerID": workerID])
        Task { await control.requestPause() }
        agentWorkers = agentWorkerRegistry.records(sessionID: worker.sessionID)
    }

    public func resumeAgent(workerID: String) {
        guard let worker = agentWorkers.first(where: { $0.id == workerID }) else { return }
        if let control = agentRunControls[worker.sessionID] {
            agentWorkerRegistry.transition(id: workerID, state: .running, detail: "恢复运行")
            Task { await control.resume() }
        } else if !worker.prompt.isEmpty {
            startAgentRun(promptOverride: worker.pendingReply ?? worker.prompt, sessionIDOverride: worker.sessionID)
        }
        agentWorkers = agentWorkerRegistry.records(sessionID: worker.sessionID)
    }

    public func stopAgent(workerID: String) {
        guard let worker = agentWorkers.first(where: { $0.id == workerID }) else { return }
        if let control = agentRunControls[worker.sessionID] { Task { await control.requestStop() } }
        agentWorkerRegistry.transition(id: workerID, state: .stopped, detail: "用户已停止")
        try? repository?.append(sessionID: worker.sessionID, type: "agent_worker_stop_requested", payload: ["workerID": workerID])
        agentWorkers = agentWorkerRegistry.records(sessionID: worker.sessionID)
    }

    public func replyToAgent(workerID: String) {
        let reply = agentReplyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !reply.isEmpty, let worker = agentWorkers.first(where: { $0.id == workerID }) else { return }
        agentWorkerRegistry.setPendingReply(id: workerID, reply: nil)
        agentReplyDraft = ""
        if selectedSessionID != worker.sessionID { selectedSessionID = worker.sessionID; refreshSelectedSession() }
        prompt = reply
        sendTask()
    }

    public func forkAgent(workerID: String) {
        guard let worker = agentWorkers.first(where: { $0.id == workerID }), let repository else { return }
        do {
            let fork = try repository.forkSession(id: worker.sessionID, title: "\(worker.title) · Fork")
            selectedSessionID = fork.id
            reloadWorkspace()
            refreshSelectedSession()
            statusMessage = "已从 Agent Worker Fork 新 Session"
        } catch { statusMessage = "Fork 失败：\(error.localizedDescription)" }
    }

    public func addAttachment(at url: URL) {
        guard let attachmentStore else {
            attachmentStatusMessage = "附件存储不可用"
            return
        }
        Task {
            do {
                let attachment = try await Task.detached(priority: .userInitiated) {
                    try attachmentStore.importFile(at: url)
                }.value
                composerAttachments.append(attachment)
                attachmentStatusMessage = "已添加 \(attachment.filename)"
            } catch {
                attachmentStatusMessage = "附件添加失败：\(error.localizedDescription)"
            }
        }
    }

    public func removeAttachment(id: String) {
        guard let index = composerAttachments.firstIndex(where: { $0.id == id }) else { return }
        let attachment = composerAttachments.remove(at: index)
        try? attachmentStore?.delete(attachment)
    }

    public func startLocalControlPlane() {
        guard controlPlane == nil else { return }
        let plane = LocalControlPlane(secretStore: secretStore) { [weak self] request in
            guard let self else { return ControlPlaneResponse(status: 503, body: Data("{\"error\":\"workspace unavailable\"}".utf8)) }
            return await self.handleControlPlane(request)
        }
        do {
            controlPlanePairing = try plane.start()
            controlPlane = plane
            if let repository {
                controlPlaneEventObserverID = repository.observeEvents { [weak plane] event in
                    plane?.publish(event: event)
                }
            }
            statusMessage = "本机 Control Plane 已启动：\(controlPlanePairing?.url.absoluteString ?? "")"
        } catch {
            statusMessage = "本机 Control Plane 启动失败：\(error.localizedDescription)"
        }
    }

    public func stopLocalControlPlane() {
        if let observerID = controlPlaneEventObserverID {
            repository?.removeEventObserver(observerID)
            controlPlaneEventObserverID = nil
        }
        controlPlane?.stop()
        controlPlane = nil
        controlPlanePairing = nil
    }

    private func handleControlPlane(_ request: ControlPlaneRequest) async -> ControlPlaneResponse {
        let parsedURL = URLComponents(string: "http://127.0.0.1\(request.path)")
        let path = parsedURL?.path ?? request.path.split(separator: "?").first.map(String.init) ?? request.path
        let afterSequence = parsedURL?.queryItems?.first(where: { $0.name == "afterSequence" })?.value.flatMap(Int.init)
        if request.method == "GET", path == "/v1/sessions" {
            return ControlPlaneResponse.json((try? repository?.sessions()) ?? [])
        }
        if request.method == "GET", path.hasPrefix("/v1/sessions/"), path.hasSuffix("/events") {
            let parts = path.split(separator: "/")
            guard parts.count >= 4, let repository else {
                return ControlPlaneResponse(status: 404, body: Data("{\"error\":\"session not found\"}".utf8))
            }
            let events = (try? repository.events(sessionID: String(parts[2]), afterSequence: afterSequence ?? 0)) ?? []
            return ControlPlaneResponse.json(events)
        }
        if request.method == "GET", path.hasPrefix("/v1/sessions/"), path.hasSuffix("/parts") {
            let parts = path.split(separator: "/")
            guard parts.count >= 4, let repository,
                  let snapshot = try? repository.sessionParts(sessionID: String(parts[2])) else {
                return ControlPlaneResponse(status: 404, body: Data("{\"error\":\"session parts not found\"}".utf8))
            }
            return ControlPlaneResponse.json(snapshot)
        }
        if request.method == "GET", path.hasPrefix("/v1/sessions/"), path.hasSuffix("/workers") {
            let parts = path.split(separator: "/")
            guard parts.count >= 4, let repository else {
                return ControlPlaneResponse(status: 404, body: Data("{\"error\":\"session workers not found\"}".utf8))
            }
            return ControlPlaneResponse.json((try? repository.workerSessions(parentSessionID: String(parts[2]))) ?? [])
        }
        if request.method == "GET", path.hasPrefix("/v1/sessions/"), path.hasSuffix("/terminals") {
            let parts = path.split(separator: "/")
            guard parts.count >= 4, let repository else {
                return ControlPlaneResponse(status: 404, body: Data("{\"error\":\"session terminals not found\"}".utf8))
            }
            // Deliberately exposes metadata only. Full transcripts can contain
            // sensitive terminal output and stay inside the main app's local
            // protected viewer.
            return ControlPlaneResponse.json((try? repository.terminalSessions(sessionID: String(parts[2]))) ?? [])
        }
        if request.method == "GET", path.hasPrefix("/v1/workers/") {
            let workerSessionID = String(path.dropFirst("/v1/workers/".count))
            guard let repository, let worker = try? repository.workerSession(id: workerSessionID) else {
                return ControlPlaneResponse(status: 404, body: Data("{\"error\":\"worker not found\"}".utf8))
            }
            return ControlPlaneResponse.json(worker)
        }
        if request.method == "POST", path.hasPrefix("/v1/workers/"), path.hasSuffix("/adopt") {
            let parts = path.split(separator: "/")
            guard parts.count >= 4, let coordinator = workerSessionCoordinator,
                  let result = try? JSONDecoder().decode(WorkerResultEnvelope.self, from: request.body) else {
                return ControlPlaneResponse(status: 400, body: Data("{\"error\":\"invalid worker result\"}".utf8))
            }
            do {
                let worker = try coordinator.adopt(id: String(parts[2]), result: result)
                return ControlPlaneResponse.json(worker)
            } catch {
                return ControlPlaneResponse(status: 409, body: Data("{\"error\":\"worker evidence could not be adopted\"}".utf8))
            }
        }
        if request.method == "POST", path.hasPrefix("/v1/approvals/") {
            let approvalID = String(path.dropFirst("/v1/approvals/".count))
            guard let repository,
                  let payload = try? JSONDecoder().decode([String: String].self, from: request.body),
                  let rawDecision = payload["decision"],
                  let decision = ApprovalDecision(rawValue: rawDecision),
                  decision != .pending else {
                return ControlPlaneResponse(status: 400, body: Data("{\"error\":\"invalid approval decision\"}".utf8))
            }
            do {
                guard let approval = try repository.approval(id: approvalID) else { throw RepositoryError.sessionNotFound }
                if let harnessDaemon {
                    try await harnessDaemon.resolveApproval(
                        sessionID: approval.sessionID,
                        approvalID: approvalID,
                        decision: decision
                    )
                } else {
                    try repository.resolveApproval(id: approvalID, decision: decision)
                    try repository.appendDurable(sessionID: approval.sessionID, type: "approval_resolved", payload: ["approvalID": approvalID, "decision": decision.rawValue])
                }
                return ControlPlaneResponse.json(["ok": "true", "approvalID": approvalID, "decision": decision.rawValue])
            } catch {
                return ControlPlaneResponse(status: 409, body: Data("{\"error\":\"approval could not be resolved\"}".utf8))
            }
        }
        if request.method == "GET", path.hasPrefix("/v1/sessions/") {
            let sessionID = String(path.dropFirst("/v1/sessions/".count))
            guard let repository,
                  let session = try? repository.session(id: sessionID) else {
                return ControlPlaneResponse(status: 404, body: Data("{\"error\":\"session not found\"}".utf8))
            }
            return ControlPlaneResponse.json(session)
        }
        if request.method == "POST", path.hasPrefix("/v1/sessions/"), path.hasSuffix("/start") {
            let parts = path.split(separator: "/")
            guard parts.count >= 4, let harnessDaemon else {
                return ControlPlaneResponse(status: 404, body: Data("{\"error\":\"session supervisor unavailable\"}".utf8))
            }
            do {
                try await harnessDaemon.startSession(String(parts[2]))
                return ControlPlaneResponse.json(["ok": "true", "sessionID": String(parts[2]), "state": "started"])
            } catch {
                return ControlPlaneResponse(status: 409, body: Data("{\"error\":\"session could not start\"}".utf8))
            }
        }
        if request.method == "POST", path.hasPrefix("/v1/sessions/"), path.hasSuffix("/pause") {
            let parts = path.split(separator: "/")
            guard parts.count >= 4, let harnessDaemon else {
                return ControlPlaneResponse(status: 404, body: Data("{\"error\":\"session supervisor unavailable\"}".utf8))
            }
            do {
                try await harnessDaemon.pauseSession(String(parts[2]))
                return ControlPlaneResponse.json(["ok": "true", "sessionID": String(parts[2]), "state": "paused"])
            } catch {
                return ControlPlaneResponse(status: 409, body: Data("{\"error\":\"session could not pause\"}".utf8))
            }
        }
        if request.method == "POST", path.hasPrefix("/v1/sessions/"), path.hasSuffix("/resume") {
            let parts = path.split(separator: "/")
            guard parts.count >= 4, let harnessDaemon else {
                return ControlPlaneResponse(status: 404, body: Data("{\"error\":\"session supervisor unavailable\"}".utf8))
            }
            do {
                try await harnessDaemon.resumeSession(String(parts[2]))
                return ControlPlaneResponse.json(["ok": "true", "sessionID": String(parts[2]), "state": "resumed"])
            } catch {
                return ControlPlaneResponse(status: 409, body: Data("{\"error\":\"session could not resume\"}".utf8))
            }
        }
        if request.method == "POST", path.hasPrefix("/v1/sessions/"), path.hasSuffix("/cancel") {
            let parts = path.split(separator: "/")
            guard parts.count >= 4, let harnessDaemon else {
                return ControlPlaneResponse(status: 404, body: Data("{\"error\":\"session supervisor unavailable\"}".utf8))
            }
            do {
                try await harnessDaemon.cancelSession(String(parts[2]))
                return ControlPlaneResponse.json(["ok": "true", "sessionID": String(parts[2]), "state": "cancelled"])
            } catch {
                return ControlPlaneResponse(status: 409, body: Data("{\"error\":\"session could not cancel\"}".utf8))
            }
        }
        if request.method == "POST", path.hasPrefix("/v1/sessions/"), path.hasSuffix("/inputs") {
            let components = path.split(separator: "/")
            guard components.count >= 4, let repository else {
                return ControlPlaneResponse(status: 404, body: Data("{\"error\":\"session not found\"}".utf8))
            }
            let sessionID = String(components[2])
            let payload = (try? JSONDecoder().decode(ControlPlaneInputPayload.self, from: request.body)) ?? ControlPlaneInputPayload(text: "")
            guard !payload.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return ControlPlaneResponse(status: 400, body: Data("{\"error\":\"text is required\"}".utf8))
            }
            do {
                let input: SessionInputRecord
                if let sessionSupervisor {
                    let receipt = try await sessionSupervisor.admit(SessionInput(
                        sessionID: sessionID,
                        idempotencyKey: payload.idempotencyKey ?? UUID().uuidString,
                        delivery: .deferred,
                        parts: [.text(payload.text)]
                    ))
                    guard let admitted = try repository.sessionInputs(sessionID: sessionID).first(where: { $0.id == receipt.inputID }) else {
                        throw RepositoryError.sessionNotFound
                    }
                    input = admitted
                } else {
                    input = try repository.enqueueSessionInput(
                        sessionID: sessionID,
                        idempotencyKey: payload.idempotencyKey ?? UUID().uuidString,
                        delivery: .deferred,
                        parts: [.text(payload.text)]
                    )
                }
                return ControlPlaneResponse.json(input, status: 202)
            } catch {
                return ControlPlaneResponse(status: 409, body: Data("{\"error\":\"input could not be queued\"}".utf8))
            }
        }
        return ControlPlaneResponse(status: 404, body: Data("{\"error\":\"not found\"}".utf8))
    }

    public func runAgent(promptOverride: String? = nil, partsOverride: [ContentPart] = [], sessionIDOverride: String? = nil, workerID: String? = nil, control: AgentRunControl? = nil) async {
        let userPrompt = (promptOverride ?? prompt).trimmingCharacters(in: .whitespacesAndNewlines)
        let runSessionID = sessionIDOverride ?? selectedSessionID
        guard hasActiveSession, !userPrompt.isEmpty else { return }
        guard let apiKey = loadAPIKey() else {
            let failureMessage = "请先在 Settings 配置 Base URL 和 API Key"
            statusMessage = failureMessage
            conversationTimeline.append(ConversationEntry(kind: .verification, title: "执行失败", text: failureMessage, state: .failed))
            try? repository?.append(sessionID: runSessionID, type: "agent_failed", payload: ["message": failureMessage])
            isSettingsPresented = true
            return
        }
        guard let eventStore else {
            statusMessage = "无法打开本地 Session 事件库"
            updateSelectedSessionStatus(.failed)
            return
        }
        let profile = currentProfile
        do {
            let client = try ProviderClientFactory.make(
                profile: profile,
                apiKey: apiKey,
                attachmentProvider: attachmentStore,
                networkRuntime: networkRuntime,
                networkContext: NetworkContext(sessionID: runSessionID, projectID: selectedProjectID, purpose: .providerRequest, requestedBy: "main-agent")
            )
            let quickChat = isScratchProject
            let workspaceHost = quickChat ? nil : try? toolHost()
            // Quick Chat still uses the same network-capable registry. It has
            // no workspace write host, but web/MCP/browser-safe capabilities
            // must not disappear just because no repository is selected.
            let runtime = makeToolRuntime(workspace: quickChat ? nil : workspaceHost)
            await prepareMCPRuntime(registry: runtime.registry, router: runtime.router)
            let host = NativeAgentHost(client: client, eventStore: eventStore, workspace: workspaceHost, repository: repository, projectTrusted: isProjectTrusted, sandboxAvailable: sandboxAvailable, toolRouter: runtime.router, toolRegistry: runtime.registry, hooks: quickChat ? [] : hooks, defaultPricing: profile, networkRuntime: networkRuntime, hookManifest: hookManifest(sessionID: runSessionID))
            let orchestrator = NativeSessionOrchestrator(host: host)
            transcript.reset()
            activityItems = []
            pendingApproval = nil
            usageSummary = UsageSummary()
            statusMessage = mode == .auto && !autoModeAvailable ? "Auto 已降级为受控模式：项目未信任或沙箱不可用" : "Agent 正在执行…"
            let qualityPlan = TaskQualityPlanner.plan(TaskRoutingInput(
                prompt: userPrompt,
                mode: mode,
                hasAttachments: partsOverride.contains { if case .text = $0 { return false }; return true },
                hasProject: !quickChat
            ))
            let routedModel = DeepSeekModelCatalog.routedModel(preferred: profile.model, route: qualityPlan.route)
            let modelCapabilities = DeepSeekModelCatalog.capabilities(for: routedModel)
            let thinking = modelCapabilities.supportsThinking && (qualityPlan.modelTier == .capable || (mode != .plan && userPrompt.count > 180))
            var instructions = (try? InstructionResolver.resolve(
                workspaceRoot: URL(fileURLWithPath: activeWorkspacePath, isDirectory: true),
                workingDirectory: URL(fileURLWithPath: activeWorkspacePath, isDirectory: true)
            ).text) ?? ""
            if let skill = SkillRuntime.promptSkill(in: userPrompt, descriptors: discoveredSkills) {
                instructions += "\n\n[已启用 Skill：\(skill.descriptor.name)]\n\(skill.content)"
                try? repository?.append(sessionID: runSessionID, type: "skill_invoked", payload: ["skillID": skill.descriptor.id, "path": skill.descriptor.path])
            }
            let preparedParts = try await prepareContentParts(partsOverride.isEmpty ? [.text(userPrompt)] : partsOverride, profile: profile)
            let contract = activeTaskContract ?? (try? repository?.taskContract(sessionID: runSessionID)) ?? TaskContract.compatibility(prompt: userPrompt, budget: sessionBudget)
            activeTaskContract = contract
            try? repository?.saveTaskContract(contract, sessionID: runSessionID)
            try? repository?.append(sessionID: runSessionID, type: "session_status_changed", payload: ["status": SessionStatus.executing.rawValue])
            let request = AgentRunRequest(sessionID: runSessionID, prompt: userPrompt, parts: preparedParts, budget: contract.budget, mode: mode, model: routedModel, thinking: thinking, instructions: instructions, taskContract: contract, control: control, pricing: profile, target: executionTarget, qualityRoute: qualityPlan.route, qualityPlan: qualityPlan)
            let extensionRuntime = NativeExtensionRuntime(repository: repository, hooks: hooks)
            try await extensionRuntime.prepare(sessionID: runSessionID, projectRoot: URL(fileURLWithPath: activeWorkspacePath, isDirectory: true))
            updateSelectedSessionStatus(.running)
            if let workerID { agentWorkerRegistry.transition(id: workerID, state: .running, detail: "Agent 正在执行", checkpoint: AgentWorkerCheckpoint(title: "执行中", detail: "\(routedModel)")) }
            for try await event in orchestrator.run(request) {
                apply(event: event, profile: profile)
                if let workerID { updateAgentWorker(for: workerID, event: event) }
            }
            await extensionRuntime.finish(sessionID: runSessionID)
            refreshGitStatus()
            finalizeTaskContract(sessionID: runSessionID)
        } catch is CancellationError {
            if let workerID {
                let requestedState = await control?.currentState()
                let stopped = requestedState == .stopRequested || requestedState == .stopped
                agentWorkerRegistry.transition(id: workerID, state: stopped ? .stopped : .paused, detail: stopped ? "已停止" : "已在安全检查点暂停")
                try? repository?.append(sessionID: runSessionID, type: stopped ? "agent_worker_stopped" : "agent_worker_paused", payload: ["workerID": workerID])
            }
            let finalControlState = await control?.currentState()
            statusMessage = (finalControlState == .stopRequested || finalControlState == .stopped) ? "Agent 已停止" : "Agent 已暂停"
        } catch {
            let failureMessage = error.localizedDescription
            statusMessage = "Agent 失败：\(failureMessage)"
            updateSelectedSessionStatus(.failed)
            conversationTimeline.append(ConversationEntry(kind: .verification, title: "执行失败", text: failureMessage, state: .failed))
            try? repository?.append(sessionID: runSessionID, type: "agent_failed", payload: ["message": failureMessage])
            if let workerID { agentWorkerRegistry.transition(id: workerID, state: .failed, detail: "执行失败", errorMessage: failureMessage) }
        }
        if let workerID, agentWorkers.contains(where: { $0.id == workerID }), agentWorkerRegistry.records(sessionID: runSessionID).first(where: { $0.id == workerID })?.state == .running {
            agentWorkerRegistry.transition(id: workerID, state: .completed, detail: "本轮完成")
        }
        agentRunTasks[runSessionID] = nil
        agentRunControls[runSessionID] = nil
        agentWorkers = agentWorkerRegistry.records(sessionID: runSessionID)
        transcript.flush()
        refreshSelectedSession()
    }

    /// Evaluates delivery from persisted evidence rather than the Agent's final text.
    @discardableResult
    public func evaluateDeliveryGate() -> DeliveryGateResult? {
        guard let contract = activeTaskContract, hasActiveSession else { return nil }
        guard contract.requiresDeliveryGate else {
            deliveryGateResult = nil
            return nil
        }
        let hasDiff = !gitDiffOutput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || verificationGraph.evidenceRecords.contains { $0.kind == .diff && $0.succeeded }
        let indeterminate = repository.map { repo in
            ((try? repo.events(sessionID: selectedSessionID)) ?? []).filter { $0.type == "tool_indeterminate" || $0.type == "tool_indeterminate" || $0.type == "ssh_tool_indeterminate" || $0.type == "mcp_tool_indeterminate" }.count
        } ?? 0
        let result = DeliveryGate.evaluate(contract: contract, graph: verificationGraph, hasDiff: hasDiff, pendingApprovals: pendingApproval == nil ? 0 : 1, indeterminateSideEffects: indeterminate, reviewFindings: reviewFindings)
        deliveryGateResult = result
        return result
    }

    private func finalizeTaskContract(sessionID: String) {
        guard sessionID == selectedSessionID, let result = evaluateDeliveryGate(), let repository else { return }
        let payload: [String: String] = [
            "passed": result.passed ? "true" : "false",
            "missing": result.missingRequirements.joined(separator: "|"),
            "failed": result.failedEvidence.joined(separator: "|"),
            "risks": result.unresolvedRisks.joined(separator: "|")
        ]
        try? repository.append(sessionID: sessionID, type: "verification_gate_evaluated", payload: payload)
        let nextStatus: SessionStatus = result.passed ? .delivered : (result.unresolvedRisks.isEmpty ? .needsRepair : .needsAttention)
        try? repository.append(sessionID: sessionID, type: "session_status_changed", payload: ["status": nextStatus.rawValue])
        if var value = try? repository.runState(sessionID: sessionID) {
            value.deliveryGateResult = result
            try? repository.saveRunState(value)
        }
        statusMessage = result.passed ? "任务已通过交付门禁" : "任务未完成：\(result.missingRequirements.joined(separator: "、"))"
    }

    public func resolvePendingApproval(_ decision: ApprovalDecision) {
        guard let pending = pendingApproval else {
            print("❌ [APPROVAL] pendingApproval is nil")
            statusMessage = "错误：没有待处理的审批"
            return
        }
        guard let sessionSupervisor else {
            print("❌ [APPROVAL] sessionSupervisor is nil")
            statusMessage = "错误：SessionSupervisor 未初始化"
            return
        }

        print("✅ [APPROVAL] Starting: tool=\(pending.tool), approvalID=\(pending.id), decision=\(decision)")

        Task {
            do {
                if let request = networkApprovalDetails(for: pending), decision == .allowOnce || decision == .allowSession {
                    if pending.tool == "web_search" || pending.tool == "web_fetch" {
                        // A research approval covers the bounded read-only
                        // Search → Fetch chain for this Session. It does not
                        // grant browser control, uploads, login or any write.
                        let grants = await networkRuntime.rememberResearchApproval(
                            sessionID: selectedSessionID,
                            projectID: selectedProjectID,
                            scope: .session
                        )
                        _ = try? repository?.appendDurable(sessionID: selectedSessionID, type: "web_research_session_granted", payload: [
                            "approvalID": pending.id,
                            "requestedTool": pending.tool,
                            "grantIDs": grants.map(\.id).joined(separator: ","),
                            "scope": "session",
                            "reason": decision == .allowOnce ? "本次联网研究需要连续搜索与读取，已限制为当前 Session" : "用户允许当前 Session 联网研究"
                        ])
                    } else {
                        _ = await networkRuntime.rememberApproval(
                            url: request.url,
                            capability: request.capability,
                            operation: request.operation,
                            sessionID: selectedSessionID,
                            projectID: selectedProjectID,
                            scope: decision == .allowOnce ? .once : .session
                        )
                    }
                }
                pendingApproval = nil
                if isDaemonOwnedSession(selectedSessionID),
                   let client = try? await daemonClient() {
                    print("→ [APPROVAL] Using Daemon path")
                    let payload = DeepSeekDaemonApprovalPayload(
                        sessionID: selectedSessionID,
                        approvalID: pending.id,
                        decision: decision
                    )
                    _ = try await sendDaemon(.approvalResolve, payload: payload, client: client)
                    // followDaemonSession exits when it sees an approval; the
                    // resolve above resumes the run, so polling must restart
                    // or the GUI never sees the remaining events.
                    if let worker = agentWorkers.first(where: { $0.sessionID == selectedSessionID && $0.kind == .main }),
                       agentRunTasks[selectedSessionID] == nil {
                        let workerID = worker.id
                        let sessionID = selectedSessionID
                        agentRunTasks[sessionID] = Task { [weak self] in
                            guard let self else { return }
                            await self.followDaemonSession(sessionID: sessionID, workerID: workerID, client: client)
                        }
                    }
                } else {
                    print("→ [APPROVAL] Using Supervisor path")
                    // 直接调用恢复逻辑，确保 Agent 能够继续执行
                    await resumeAgentApprovalForSupervisor(
                        sessionID: selectedSessionID,
                        approvalID: pending.id,
                        decision: decision
                    )
                    // 同步更新数据库状态
                    try? await sessionSupervisor.resolveApproval(
                        sessionID: selectedSessionID,
                        approvalID: pending.id,
                        decision: decision
                    )
                }
                print("✅ [APPROVAL] Completed successfully")
                statusMessage = "审批已处理，继续执行"
            } catch {
                print("❌ [APPROVAL] Failed: \(error)")
                statusMessage = "恢复任务失败：\(error.localizedDescription)"
            }
        }
    }

    private func isDaemonOwnedSession(_ sessionID: String) -> Bool {
        let hasLiveDaemonWorker = agentWorkers.contains {
            $0.sessionID == sessionID &&
            $0.kind == .main &&
            ($0.detail.contains("deepseekd") || $0.checkpoint?.detail.contains("本地 daemon") == true)
        }
        if hasLiveDaemonWorker { return true }
        // Worker cards are deliberately ephemeral. After an App relaunch,
        // recover the runtime owner from the append-only event log so an
        // outstanding daemon approval never falls back into the foreground
        // Agent runtime.
        guard let repository else { return false }
        return SessionRuntimeOwnership.owner(sessionID: sessionID, repository: repository) == .daemon
    }

    private func networkApprovalDetails(for pending: PendingToolApproval) -> (url: URL, capability: NetworkScope, operation: NetworkOperation)? {
        let object: [String: Any]
        if let data = pending.argumentsJSON.data(using: .utf8), let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            object = value
        } else {
            object = [:]
        }
        switch pending.tool {
        case "web_fetch":
            guard let raw = object["url"] as? String, let url = URL(string: raw) else { return nil }
            return (url, .webFetch, .read)
        case "web_search":
            let endpoint = searchProviders.first(where: { $0.enabled })?.endpoint ?? "https://www.bing.com/search"
            guard let url = URL(string: endpoint) else { return nil }
            return (url, .webSearch, .read)
        case "browser.open":
            guard let raw = object["url"] as? String, let url = URL(string: raw) else { return nil }
            return (url, .browser, .read)
        case "github.create_pr", "github.push", "github.reply_review":
            return (URL(string: "https://api.github.com")!, .github, .delivery)
        case "github.pr_checks", "github.view_pr", "github.ci_logs":
            return (URL(string: "https://api.github.com")!, .github, .read)
        default:
            if pending.tool.hasPrefix("mcp.") {
                let serverID = pending.tool.split(separator: ".").dropFirst().first.map(String.init)
                if let server = mcpServers.first(where: { $0.id == serverID }),
                   case let .streamableHTTP(rawURL) = server.transport,
                   let url = URL(string: rawURL) {
                    return (url, .mcp, .read)
                }
            }
            if pending.tool == "ssh.execute",
               let hostID = object["hostID"] as? String,
               let host = sshHosts.first(where: { $0.id == hostID }),
               let url = URL(string: "https://\(host.hostname):\(host.port)") {
                return (url, .ssh, .tunnel)
            }
            return nil
        }
    }

    public func saveProvider() {
        let reference = "keychain://deepseek-default"
        do {
            if !providerAPIKey.isEmpty { try secretStore?.save(reference: reference, value: providerAPIKey) }
            if !visionAdapterAPIKey.isEmpty { try secretStore?.save(reference: "keychain://deepseek-vision", value: visionAdapterAPIKey) }
            providerBaseURL = Self.normalizeProviderBaseURL(providerBaseURL)
            providerModel = Self.normalizedProviderModel(providerModel)
            try providerCatalog?.save(currentProfile)
            providerAPIKey = ""
            visionAdapterAPIKey = ""
            providerStatus = "已保存到本机安全存储，正在验证连接与能力…"
            Task { [weak self] in
                await self?.testProvider()
            }
        } catch {
            providerStatus = "保存失败：\(error.localizedDescription)"
        }
    }

    public func testProvider() async {
        providerStatus = "正在进行真实低成本能力测试…"
        guard let key = loadAPIKey() else {
            providerStatus = "请先填写 API Key"
            return
        }
        let result = await ProviderCapabilityTester.test(profile: currentProfile, apiKey: key, networkRuntime: networkRuntime)
        providerCapabilities = result.capabilities
        if result.succeeded { try? providerCatalog?.save(currentProfile) }
        providerStatus = result.detail
    }

    public func runTerminalCommand() {
        guard !projectPath.isEmpty else { isProjectPickerPresented = true; return }
        let command = terminalCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty else { statusMessage = "请输入要运行的命令"; return }
        let risk = CommandPolicy.classify(command)
        if risk >= .l2 {
            requestTerminalApproval(command: command, risk: risk)
            return
        }
        launchTerminal(command: command, background: false)
    }

    public func stopTerminalCommand() {
        interruptActiveTerminal()
    }

    public func openTerminal() {
        guard !projectPath.isEmpty else { isProjectPickerPresented = true; return }
        if case let .ssh(configuredHostID) = terminalTarget {
            let hostID = configuredHostID.isEmpty
                ? (terminalSSHHostID.isEmpty ? sshHosts.first(where: { sshConnectionStatus[$0.id] == .connected })?.id : terminalSSHHostID)
                : configuredHostID
            guard let hostID, sshConnectionStatus[hostID] == .connected else {
                statusMessage = "SSH Terminal 需要先完成 Host 指纹校验和连接"
                return
            }
            terminalSSHHostID = hostID
            launchTerminal(command: nil, background: false, target: .ssh(hostID: hostID))
        } else {
            launchTerminal(command: nil, background: false, target: terminalTarget)
        }
    }

    public func selectTerminal(id: String) {
        guard terminalSessions.contains(where: { $0.id == id }) else { return }
        activeTerminalID = id
        syncLegacyTerminalProjection()
        startTerminalReader(id: id)
    }

    public func launchBackgroundTerminal() {
        guard !projectPath.isEmpty else { isProjectPickerPresented = true; return }
        let command = terminalCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty else { return }
        let risk = CommandPolicy.classify(command)
        if risk >= .l2 { requestTerminalApproval(command: command, risk: risk, background: true) }
        else { launchTerminal(command: command, background: true) }
    }

    public func approvePendingTerminalCommand(_ decision: ApprovalDecision = .allowOnce) {
        guard let pending = terminalPendingApproval else { return }
        terminalPendingApproval = nil
        if let repository { try? repository.resolveApproval(id: pending.id, decision: decision) }
        guard decision == .allowOnce || decision == .allowSession else {
            statusMessage = "已拒绝终端命令"
            return
        }
        let command = pending.arguments
            .data(using: .utf8)
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            .flatMap { $0["command"] as? String } ?? terminalCommand
        let background = pending.arguments
            .data(using: .utf8)
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            .flatMap { $0["background"] as? Bool } ?? false
        launchTerminal(command: command, background: background)
    }

    public func sendTerminalInput(_ data: Data) {
        guard let active = activeTerminal else { return }
        if terminalProtectedInputRequired {
            statusMessage = "终端正在等待用户接管敏感输入"
            return
        }
        Task {
            do {
                try await terminalBroker.write(sessionID: active.id, data: data)
                appendTerminalEvent(active, kind: .input, detail: "\(data.count) bytes")
            } catch {
                statusMessage = "终端输入失败：\(error.localizedDescription)"
            }
        }
    }

    public func sendProtectedTerminalInput(_ data: Data) {
        guard let active = activeTerminal else { return }
        Task {
            do {
                try await terminalBroker.writeProtectedInput(sessionID: active.id, data: data)
                terminalProtectedInputRequired = false
                appendTerminalEvent(active, kind: .protectedInputCompleted, detail: "受保护输入已由用户完成", protectedInput: true)
            } catch {
                statusMessage = "敏感输入失败：\(error.localizedDescription)"
            }
        }
    }

    public func resizeTerminal(columns: Int, rows: Int) {
        guard let active = activeTerminal else { return }
        Task {
            try? await terminalBroker.resize(sessionID: active.id, columns: columns, rows: rows)
            appendTerminalEvent(active, kind: .resized, detail: "\(columns)x\(rows)")
        }
    }

    public func interruptActiveTerminal() {
        guard let active = activeTerminal else { return }
        Task {
            try? await terminalBroker.stopGracefully(sessionID: active.id)
            appendTerminalEvent(active, kind: .signaled, detail: "SIGINT → SIGTERM → SIGKILL")
            statusMessage = "已停止 Terminal 进程组"
        }
    }

    public func eofActiveTerminal() {
        guard let active = activeTerminal else { return }
        Task { try? await terminalBroker.signal(sessionID: active.id, signal: .eof) }
    }

    public func closeActiveTerminal() {
        guard let active = activeTerminal else { return }
        Task {
            try? await terminalBroker.close(sessionID: active.id)
            appendTerminalEvent(active, kind: .detached, detail: "closed")
        }
    }

    public func openTerminalPortInBrowser(_ port: Int) {
        guard (1...65_535).contains(port) else { return }
        browserURL = "http://localhost:\(port)"
        browserSourceTerminalID = terminalPorts.last(where: { $0.port == port })?.terminalID
        selectedRightPanel = .browser
        isInspectorVisible = true
        if let terminalID = browserSourceTerminalID {
            try? repository?.append(sessionID: selectedSessionID, type: "terminal_browser_linked", payload: ["terminalID": terminalID, "port": "\(port)", "url": browserURL])
        }
        statusMessage = "已将 localhost:\(port) 交给 Browser 验证"
    }

    private func requestTerminalApproval(command: String, risk: CommandRisk, background: Bool = false) {
        let arguments = "{\"command\":\(jsonString(command)),\"background\":\(background ? "true" : "false")}"
        let approval = (try? repository?.createApproval(sessionID: selectedSessionID, tool: "terminal.exec", risk: risk, arguments: arguments)) ?? nil
        terminalPendingApproval = approval
        statusMessage = "终端命令需要 L\(risk.rawValue) 审批"
        if let approval {
            try? repository?.append(sessionID: selectedSessionID, type: "approval_requested", payload: ["approvalID": approval.id, "tool": "terminal.exec", "risk": "L\(risk.rawValue)", "arguments": SecretRedactor.redact(arguments)])
        }
    }

    private func launchTerminal(command: String?, background: Bool, target explicitTarget: TerminalTarget? = nil) {
        let sessionID = selectedSessionID.isEmpty ? "default" : selectedSessionID
        let workspacePath = activeWorkspacePath.isEmpty ? projectPath : activeWorkspacePath
        let rootPath = (workspacePath as NSString).expandingTildeInPath
        let target = explicitTarget ?? terminalTarget
        let spec = TerminalLaunchSpec(sessionID: sessionID, target: target, cwd: rootPath, command: command, background: background)
        statusMessage = command == nil ? "Terminal 启动中…" : "命令执行中…"
        Task {
            do {
                terminalHelperConnectionState = terminalHelperManager == nil ? .legacy : .starting
                let record = try await terminalBroker.open(spec: spec)
                terminalHelperConnectionState = terminalHelperManager == nil ? .legacy : .connected
                terminalSessions.append(record)
                terminalOutputBuffers[record.id] = TerminalOutputBuffer()
                activeTerminalID = record.id
                terminalTarget = record.target
                try? repository?.saveTerminalSession(record)
                let commandHash = SHA256.hash(data: Data((command ?? "").utf8)).map { String(format: "%02x", $0) }.joined()
                try? repository?.saveTerminalProcess(TerminalProcessRecord(
                    terminalID: record.id,
                    pid: record.pid,
                    processGroup: record.pid,
                    commandHash: commandHash,
                    cwd: record.cwd
                ))
                if let command {
                    try? repository?.appendTerminalCommandHistory(TerminalCommandHistoryRecord(
                        sessionID: record.sessionID,
                        terminalID: record.id,
                        command: command,
                        risk: CommandPolicy.classify(command)
                    ))
                }
                appendTerminalEvent(record, kind: .started, detail: "pid \(record.pid.map(String.init) ?? "-")")
                startTerminalReader(id: record.id)
                syncLegacyTerminalProjection()
            } catch {
                terminalHelperConnectionState = terminalHelperManager == nil ? .legacy : .needsAttention
                terminalRunning = false
                statusMessage = "Terminal 启动失败：\(error.localizedDescription)"
            }
        }
    }

    private func startTerminalReader(id: String) {
        terminalReadTasks[id]?.cancel()
        terminalReadTasks[id] = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                do {
                    let chunk = try await terminalBroker.read(sessionID: id, maxBytes: 64_000)
                    await MainActor.run { self.ingestTerminalChunk(id: id, text: chunk.text) }
                } catch TerminalRuntimeError.noOutput {
                    let record = await terminalBroker.record(terminalID: id)
                    let protected = await terminalBroker.protectedInputRequired(terminalID: id)
                    await MainActor.run {
                        if let record { self.updateTerminalRecord(record) }
                        if protected, id == self.activeTerminalID { self.terminalProtectedInputRequired = true }
                        if let record, [.exited, .failed, .stopped].contains(record.state) { self.terminalReadTasks[id] = nil }
                    }
                    if let record, [.exited, .failed, .stopped].contains(record.state) { break }
                    try? await Task.sleep(nanoseconds: 33_000_000)
                } catch {
                    await MainActor.run {
                        if self.terminalHelperManager != nil { self.terminalHelperConnectionState = .needsAttention }
                        self.statusMessage = "Terminal 读取失败：\(error.localizedDescription)"
                    }
                    break
                }
            }
        }
    }

    private func ingestTerminalChunk(id: String, text: String) {
        var buffer = terminalOutputBuffers[id] ?? TerminalOutputBuffer()
        buffer.append(text)
        terminalOutputBuffers[id] = buffer
        terminalProtectedInputRequired = TerminalInputGuard.classify(text) == .protected || terminalProtectedInputRequired
        if id == activeTerminalID { syncLegacyTerminalProjection() }
        if let record = terminalSessions.first(where: { $0.id == id }) {
            appendTerminalEvent(record, kind: .output, detail: "\(text.utf8.count) bytes")
            for port in TerminalPortDetector.ports(in: text) where !terminalPorts.contains(where: { $0.terminalID == id && $0.port == port }) {
                let discovered = TerminalPortRecord(terminalID: id, port: port)
                terminalPorts.append(discovered)
                try? repository?.saveTerminalPort(discovered)
                appendTerminalEvent(record, kind: .portDiscovered, detail: "localhost:\(port)")
            }
        }
    }

    private func updateTerminalRecord(_ record: TerminalSessionRecord) {
        let previous = terminalSessions.first(where: { $0.id == record.id })
        if let index = terminalSessions.firstIndex(where: { $0.id == record.id }) { terminalSessions[index] = record }
        else { terminalSessions.append(record) }
        if record.id == activeTerminalID { syncLegacyTerminalProjection() }
        if let repository { try? repository.saveTerminalSession(record) }
        let becameFinal = [.exited, .failed, .stopped].contains(record.state) && ![.exited, .failed, .stopped].contains(previous?.state ?? .starting)
        if becameFinal {
            let command = record.command ?? "Interactive Terminal"
            let tail = terminalOutputBuffers[record.id]?.text.suffix(800) ?? ""
            recordCommandEvidence(command: command, detail: "exit \(record.exitCode.map(String.init) ?? "unknown")\(tail.isEmpty ? "" : "；\(tail)")", succeeded: record.exitCode == 0)
            appendTerminalEvent(record, kind: record.state == .exited ? .completed : .failed, detail: "exit \(record.exitCode.map(String.init) ?? "unknown")")
            statusMessage = record.exitCode == 0 ? "Terminal 命令完成" : "Terminal 退出码：\(record.exitCode.map(String.init) ?? "unknown")"
        }
    }

    private func syncLegacyTerminalProjection() {
        guard let active = activeTerminal else {
            terminalRunning = false
            return
        }
        terminalOutput = terminalOutputBuffers[active.id]?.text ?? ""
        terminalRunning = [.starting, .running, .background].contains(active.state)
    }

    private func appendTerminalEvent(_ record: TerminalSessionRecord, kind: TerminalEventKind, detail: String, protectedInput: Bool = false) {
        let event = TerminalAuditEvent(terminalID: record.id, sessionID: record.sessionID, kind: kind, detail: detail, protectedInput: protectedInput)
        try? repository?.appendTerminalEvent(event)
        try? repository?.append(sessionID: record.sessionID, type: "terminal_\(kind.rawValue)", payload: ["terminalID": record.id, "detail": event.detail])
        if kind == .output {
            try? repository?.append(sessionID: record.sessionID, type: "terminal_output_persisted", payload: ["terminalID": record.id, "detail": event.detail])
        }
    }

    public func refreshGitDiff() {
        refreshGitStatus()
    }

    public func runReview() async {
        let diff = gitDiffOutput
        guard !diff.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !reviewIsRunning else {
            statusMessage = "当前没有可审查的 Diff"
            return
        }

        reviewIsRunning = true
        let workerContext = beginReadOnlyWorker(kind: .review, objective: "审查当前 Session 的代码 Diff")
        statusMessage = "Review Worker 正在审查 Diff…"
        let findings = await Task.detached(priority: .userInitiated) {
            ReviewEngine.scan(diff: diff)
        }.value
        reviewFindings = findings
        reviewUpdatedAt = Date()
        reviewIsRunning = false

        let evidence = EvidenceRecord(
            taskID: selectedSessionID,
            kind: .review,
            title: "代码审查",
            detail: findings.isEmpty ? "未发现自动扫描问题" : "发现 \(findings.count) 个问题",
            succeeded: true
        )
        verificationGraph = VerificationGraph(
            taskID: selectedSessionID,
            nodes: verificationGraph.nodes,
            evidenceRecords: verificationGraph.evidenceRecords + [evidence]
        )
        if let repository, !selectedSessionID.isEmpty {
            let encodedFindings = (try? JSONEncoder().encode(findings)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
            try? repository.append(
                sessionID: selectedSessionID,
                type: "review_completed",
                payload: [
                    "findings": encodedFindings,
                    "count": "\(findings.count)"
                ]
            )
            try? repository.append(
                sessionID: selectedSessionID,
                type: "evidence_recorded",
                payload: [
                    "id": evidence.id,
                    "kind": evidence.kind.rawValue,
                    "title": evidence.title,
                    "detail": evidence.detail,
                    "succeeded": "true"
                ]
            )
        }
        if let workerContext {
            let hash = SHA256.hash(data: Data((findings.isEmpty ? "通过" : "发现问题").utf8)).map { String(format: "%02x", $0) }.joined()
            let result = WorkerResultEnvelope(workerID: workerContext.worker.id, sessionID: selectedSessionID, summary: findings.isEmpty ? "未发现自动扫描问题" : "发现 \(findings.count) 个问题", evidenceIDs: [evidence.id], outputHash: hash)
            _ = try? workerSessionCoordinator?.adopt(id: workerContext.session.id, result: result)
            _ = agentWorkerRegistry.transition(id: workerContext.worker.id, state: .completed, detail: "Review 已完成")
        }
        activityItems.append(ActivityItem(title: "代码审查", detail: evidence.detail, state: findings.isEmpty ? "通过" : "需处理"))
        statusMessage = findings.isEmpty ? "Review 完成：未发现问题" : "Review 完成：发现 \(findings.count) 个问题"
    }

    private func beginReadOnlyWorker(kind: AgentWorkerKind, objective: String) -> (worker: AgentWorkerRecord, session: WorkerSessionRecord)? {
        guard kind != .main, let coordinator = workerSessionCoordinator, !selectedSessionID.isEmpty else { return nil }
        let worker = agentWorkerRegistry.create(sessionID: selectedSessionID, prompt: objective, kind: kind)
        let contract = WorkerSessionContract(parentSessionID: selectedSessionID, workerKind: kind, objective: objective)
        do {
            let session = try coordinator.create(parentSessionID: selectedSessionID, workerID: worker.id, contract: contract)
            _ = agentWorkerRegistry.transition(id: worker.id, state: .running, detail: "只读 Worker 执行中")
            agentWorkers = agentWorkerRegistry.records(sessionID: selectedSessionID)
            return (worker, session)
        } catch {
            _ = agentWorkerRegistry.transition(id: worker.id, state: .needsAttention, detail: "Child Session 创建失败", errorMessage: error.localizedDescription)
            return nil
        }
    }

    public func runSemanticReview() async {
        let diff = gitDiffOutput
        guard !diff.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !reviewIsRunning else {
            statusMessage = "当前没有可审查的 Diff"
            return
        }
        guard let apiKey = loadAPIKey() else {
            statusMessage = "请先在 Settings 配置 Base URL 和 API Key"
            isSettingsPresented = true
            return
        }

        reviewIsRunning = true
        let workerContext = beginReadOnlyWorker(kind: .review, objective: "使用 DeepSeek 语义审查当前 Diff")
        statusMessage = "DeepSeek Review Worker 正在审查…"
        let profile = currentProfile
        let model = DeepSeekModelCatalog.proModel
        do {
            let client = try ProviderClientFactory.make(
                profile: profile,
                apiKey: apiKey,
                networkRuntime: networkRuntime,
                networkContext: NetworkContext(sessionID: selectedSessionID, projectID: selectedProjectID, purpose: .providerRequest, requestedBy: "review-worker")
            )
            let worker = DeepSeekReviewWorker(client: client, model: model)
            var semanticFindings: [ReviewFinding] = []
            var inputTokens = 0
            var cachedInputTokens = 0
            var outputTokens = 0
            var latencyMilliseconds = 0
            for try await event in worker.run(diff: diff) {
                switch event {
                case .textDelta:
                    continue
                case let .usage(input, cachedInput, output, latency):
                    inputTokens = input
                    cachedInputTokens = cachedInput
                    outputTokens = output
                    latencyMilliseconds = latency
                case let .completed(findings):
                    semanticFindings = findings
                }
            }
            let localFindings = ReviewEngine.scan(diff: diff)
            var merged = localFindings
            for finding in semanticFindings where !merged.contains(where: { $0.file == finding.file && $0.startLine == finding.startLine && $0.title == finding.title }) {
                merged.append(finding)
            }
            reviewFindings = merged.sorted { lhs, rhs in
                if lhs.severity.rawValue != rhs.severity.rawValue { return lhs.severity.rawValue < rhs.severity.rawValue }
                return lhs.file < rhs.file
            }
            reviewUpdatedAt = Date()
            reviewIsRunning = false
            if inputTokens > 0 || outputTokens > 0 {
                var pricedProfile = profile
                pricedProfile.model = model
                let beforeCost = usageSummary.estimatedCost
                usageSummary.record(input: inputTokens, cachedInput: cachedInputTokens, output: outputTokens, pricing: pricedProfile)
                usageLedger.record(UsageRecord(
                    feature: .reviewWorker,
                    model: model,
                    inputTokens: inputTokens,
                    cachedInputTokens: cachedInputTokens,
                    outputTokens: outputTokens,
                    latencyMilliseconds: latencyMilliseconds,
                    estimatedCost: max(0, usageSummary.estimatedCost - beforeCost),
                    succeeded: true
                ))
            }
            let evidence = EvidenceRecord(
                taskID: selectedSessionID,
                kind: .review,
                title: "DeepSeek Review Worker",
                detail: semanticFindings.isEmpty ? "模型未发现额外问题；已合并本地规则结果" : "模型发现 \(semanticFindings.count) 个问题",
                succeeded: true
            )
            verificationGraph = VerificationGraph(
                taskID: selectedSessionID,
                nodes: verificationGraph.nodes,
                evidenceRecords: verificationGraph.evidenceRecords + [evidence]
            )
            if let repository, !selectedSessionID.isEmpty {
                try? repository.append(sessionID: selectedSessionID, type: "usage_recorded", payload: [
                    "feature": UsageFeature.reviewWorker.rawValue,
                    "model": model,
                    "input": "\(inputTokens)",
                    "cached_input": "\(cachedInputTokens)",
                    "output": "\(outputTokens)",
                    "latency_ms": "\(latencyMilliseconds)",
                    "succeeded": "true"
                ])
                let encodedFindings = (try? JSONEncoder().encode(reviewFindings)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
                try? repository.append(sessionID: selectedSessionID, type: "review_completed", payload: ["findings": encodedFindings, "count": "\(reviewFindings.count)", "worker": "deepseek"])
                try? repository.append(sessionID: selectedSessionID, type: "evidence_recorded", payload: [
                    "id": evidence.id,
                    "kind": evidence.kind.rawValue,
                    "title": evidence.title,
                    "detail": evidence.detail,
                    "succeeded": "true"
                ])
            }
            if let workerContext {
                let result = WorkerResultEnvelope(
                    workerID: workerContext.worker.id,
                    sessionID: selectedSessionID,
                    summary: evidence.detail,
                    evidenceIDs: [evidence.id],
                    outputHash: SHA256.hash(data: Data(evidence.detail.utf8)).map { String(format: "%02x", $0) }.joined()
                )
                _ = try? workerSessionCoordinator?.adopt(id: workerContext.session.id, result: result)
                _ = agentWorkerRegistry.transition(id: workerContext.worker.id, state: .completed, detail: "语义 Review 已完成")
            }
            activityItems.append(ActivityItem(title: evidence.title, detail: evidence.detail, state: reviewFindings.isEmpty ? "通过" : "需处理"))
            statusMessage = reviewFindings.isEmpty ? "DeepSeek Review 通过" : "DeepSeek Review：发现 \(reviewFindings.count) 个问题"
        } catch {
            reviewIsRunning = false
            if let workerContext {
                _ = try? workerSessionCoordinator?.transition(id: workerContext.session.id, state: .failed)
                _ = agentWorkerRegistry.transition(id: workerContext.worker.id, state: .failed, detail: "语义 Review 失败", errorMessage: error.localizedDescription)
            }
            statusMessage = "DeepSeek Review 失败：\(error.localizedDescription)"
        }
    }

    public func recordBrowserSnapshot(_ snapshot: BrowserSnapshot) {
        recordBrowserEvidence(BrowserEvidenceBundle(
            url: snapshot.url,
            title: snapshot.title,
            domSummary: snapshot.domText,
            accessibilityTree: snapshot.accessibilityTree,
            consoleErrors: snapshot.consoleErrors,
            networkFailures: snapshot.networkFailures,
            actions: [BrowserActionRecord(tool: "browser.snapshot", snapshotVersion: snapshot.snapshotVersion, succeeded: true)]
        ))
    }

    public func recordBrowserEvidence(_ bundle: BrowserEvidenceBundle) {
        let effectiveBundle: BrowserEvidenceBundle
        if bundle.sourceTerminalID == nil, let browserSourceTerminalID {
            effectiveBundle = BrowserEvidenceBundle(
                url: bundle.url,
                title: bundle.title,
                domSummary: bundle.domSummary,
                accessibilityTree: bundle.accessibilityTree,
                consoleErrors: bundle.consoleErrors,
                networkFailures: bundle.networkFailures,
                screenshotPath: bundle.screenshotPath,
                actions: bundle.actions,
                passedAssertions: bundle.passedAssertions,
                failedAssertions: bundle.failedAssertions,
                sourceTerminalID: browserSourceTerminalID,
                capturedAt: bundle.capturedAt
            )
        } else {
            effectiveBundle = bundle
        }
        let terminalDetail = effectiveBundle.sourceTerminalID.map { "；关联 Terminal \($0)" } ?? ""
        let detail = "\(effectiveBundle.title.isEmpty ? effectiveBundle.url : effectiveBundle.title)；控制台错误 \(effectiveBundle.consoleErrors.count)，网络失败 \(effectiveBundle.networkFailures.count)，断言通过 \(effectiveBundle.passedAssertions.count)，失败 \(effectiveBundle.failedAssertions.count)\(terminalDetail)"
        let evidence = EvidenceRecord(
            taskID: selectedSessionID,
            kind: .browser,
            title: "浏览器验证",
            detail: detail,
            succeeded: effectiveBundle.succeeded
        )
        verificationGraph = VerificationGraph(
            taskID: selectedSessionID,
            nodes: verificationGraph.nodes + [VerificationNode(title: "浏览器验证", state: evidence.succeeded ? .passed : .failed, evidenceIDs: [evidence.id])],
            evidenceRecords: verificationGraph.evidenceRecords + [evidence]
        )
        if let repository, !selectedSessionID.isEmpty {
            let bundleJSON = (try? JSONEncoder().encode(effectiveBundle)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
            try? repository.append(sessionID: selectedSessionID, type: "browser_evidence_recorded", payload: ["bundle": bundleJSON])
            try? repository.append(
                sessionID: selectedSessionID,
                type: "evidence_recorded",
                payload: [
                    "id": evidence.id,
                    "kind": evidence.kind.rawValue,
                    "title": evidence.title,
                    "detail": evidence.detail,
                    "succeeded": evidence.succeeded ? "true" : "false"
                ]
            )
            for assertionID in bundle.passedAssertions {
                try? repository.append(sessionID: selectedSessionID, type: "evidence_recorded", payload: [
                    "id": UUID().uuidString,
                    "kind": EvidenceKind.browser.rawValue,
                    "title": "Browser assertion:\(assertionID)",
                    "detail": "浏览器断言已通过",
                    "succeeded": "true"
                ])
            }
            for assertionID in bundle.failedAssertions {
                try? repository.append(sessionID: selectedSessionID, type: "evidence_recorded", payload: [
                    "id": UUID().uuidString,
                    "kind": EvidenceKind.browser.rawValue,
                    "title": "Browser assertion:\(assertionID)",
                    "detail": "浏览器断言未通过",
                    "succeeded": "false"
                ])
            }
        }
        activityItems.append(ActivityItem(title: evidence.title, detail: evidence.detail, state: evidence.succeeded ? "通过" : "需处理"))
        statusMessage = evidence.succeeded ? "浏览器验证通过" : "浏览器发现 \(bundle.consoleErrors.count + bundle.networkFailures.count + bundle.failedAssertions.count) 个问题"
    }

    public func recordCommandEvidence(command: String, detail: String, succeeded: Bool) {
        let kind = VerificationEvidenceClassifier.kind(
            tool: "run_command",
            argumentsJSON: "{\"command\":\(jsonString(command))}"
        )
        let evidence = EvidenceRecord(
            taskID: selectedSessionID,
            kind: kind,
            title: command,
            detail: detail,
            succeeded: succeeded
        )
        verificationGraph = VerificationGraph(
            taskID: selectedSessionID,
            nodes: verificationGraph.nodes,
            evidenceRecords: verificationGraph.evidenceRecords + [evidence]
        )
        if let repository, !selectedSessionID.isEmpty {
            try? repository.append(
                sessionID: selectedSessionID,
                type: "evidence_recorded",
                payload: [
                    "id": evidence.id,
                    "kind": evidence.kind.rawValue,
                    "title": evidence.title,
                    "detail": evidence.detail,
                    "succeeded": evidence.succeeded ? "true" : "false"
                ]
            )
        }
    }

    public func refreshGitStatus() {
        guard !projectPath.isEmpty else { isProjectPickerPresented = true; return }
        if isScratchProject {
            gitStatusEntries = []
            gitDiffOutput = "快速对话不使用 Git 仓库。选择一个项目后，这里会显示真实 Changes。"
            gitLogOutput = ""
            statusMessage = "快速对话不使用 Git"
            return
        }
        let rootPath = (activeWorkspacePath as NSString).expandingTildeInPath
        statusMessage = "正在读取 Git 状态…"
        Task {
            let result = await Task.detached(priority: .userInitiated) { () -> (entries: [GitStatusEntry], diff: String, log: String, error: String?) in
                do {
                    let service = try GitService(root: URL(fileURLWithPath: rootPath, isDirectory: true))
                    let entries = try service.statusEntries()
                    let diff = try service.diff()
                    let log = (try? service.log(limit: 8)) ?? ""
                    return (entries, diff.isEmpty ? "工作区没有未提交的 Git Diff。" : diff, log, nil)
                } catch {
                    return ([], error.localizedDescription, "", error.localizedDescription)
                }
            }.value
            if result.error == nil {
                gitStatusEntries = result.entries
                gitDiffOutput = result.diff
                gitLogOutput = result.log
                statusMessage = "Git 状态已刷新"
            } else {
                gitStatusEntries = []
                gitDiffOutput = result.diff
                gitLogOutput = ""
                statusMessage = "Git 状态读取失败"
            }
        }
    }

    public func stageGitPath(_ path: String) {
        runGitAction(label: "Stage") { service in
            try service.stage(path: path)
        }
    }

    public func unstageGitPath(_ path: String) {
        runGitAction(label: "Unstage") { service in
            try service.unstage(path: path)
        }
    }

    public func commitGitChanges() {
        let message = gitCommitMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else {
            statusMessage = "请输入 Commit Message"
            return
        }
        runGitAction(label: "Commit") { service in
            try service.commit(message: message)
        } onSuccess: {
            self.gitCommitMessage = ""
        }
    }

    public func createPullRequest() {
        guard hasActiveSession, !selectedSession.branch.isEmpty else {
            statusMessage = "请先创建任务分支后再创建 Pull Request"
            return
        }
        let root = URL(fileURLWithPath: activeWorkspacePath, isDirectory: true)
        let title = selectedSession.title
        let body = "由 DeepSeek Code 创建。验证与审计记录保存在 Session 中。"
        Task {
            do {
                let coordinator = GitHubDeliveryCoordinator(runner: ProcessGitHubCommandRunner(workingDirectory: root), repository: repository, networkRuntime: networkRuntime)
                let delivery = try await coordinator.createPullRequest(sessionID: selectedSessionID, title: title, body: body, base: "main", head: selectedSession.branch, approved: true)
                refreshSelectedSession()
                statusMessage = delivery.pullRequestURL.map { "已创建 Pull Request：\($0)" } ?? "Pull Request 已创建"
            } catch {
                statusMessage = "创建 Pull Request 失败：\(error.localizedDescription)"
            }
        }
    }

    public func refreshPullRequestChecks() {
        guard let repository, hasActiveSession, var delivery = githubDeliveries.first,
              let number = delivery.pullRequestNumber else {
            statusMessage = "当前 Session 没有可查询的 Pull Request 编号"
            return
        }
        let root = URL(fileURLWithPath: activeWorkspacePath, isDirectory: true)
        Task {
            do {
                let coordinator = GitHubDeliveryCoordinator(runner: ProcessGitHubCommandRunner(workingDirectory: root), repository: repository, networkRuntime: networkRuntime)
                try await coordinator.refreshChecks(sessionID: selectedSessionID, delivery: &delivery, number: number)
                githubDeliveries[githubDeliveries.firstIndex(where: { $0.id == delivery.id }) ?? 0] = delivery
                ciLogOutput = delivery.lastEvidence ?? ""
                refreshSelectedSession()
                statusMessage = delivery.ciState == "passed" ? "GitHub CI 已通过" : "GitHub CI：\(delivery.ciState ?? "pending")"
            } catch {
                statusMessage = "读取 GitHub CI 失败：\(error.localizedDescription)"
            }
        }
    }

    public func fetchCIFailureLogs(runID: String) {
        guard let repository, hasActiveSession else { return }
        let root = URL(fileURLWithPath: activeWorkspacePath, isDirectory: true)
        let number = githubDeliveries.first?.pullRequestNumber ?? 0
        Task {
            do {
                let coordinator = GitHubDeliveryCoordinator(runner: ProcessGitHubCommandRunner(workingDirectory: root), repository: repository, networkRuntime: networkRuntime)
                let failure = try await coordinator.fetchCILogs(sessionID: selectedSessionID, runID: runID, repositoryName: projectName, pullRequestNumber: number)
                ciFailureEvidence = failure
                ciLogOutput = failure.logExcerpt
                refreshSelectedSession()
                statusMessage = "已记录 CI 失败证据：\(failure.failedStep)"
            } catch {
                statusMessage = "读取 CI 失败日志失败：\(error.localizedDescription)"
            }
        }
    }

    public func createCIFixSession() {
        guard let repository, hasActiveSession, let failure = ciFailureEvidence, let contract = activeTaskContract, let selectedProjectID else {
            statusMessage = "缺少 CI 失败证据或任务合同"
            return
        }
        Task {
            do {
                let coordinator = GitHubDeliveryCoordinator(runner: ProcessGitHubCommandRunner(workingDirectory: URL(fileURLWithPath: activeWorkspacePath, isDirectory: true)), repository: repository, networkRuntime: networkRuntime)
                let session = try await coordinator.createFixSession(from: selectedSessionID, projectID: selectedProjectID, failure: failure, contract: contract)
                let localRoot = URL(fileURLWithPath: projectPath, isDirectory: true)
                let git = try GitService(root: localRoot)
                let baseline = try git.currentRevision()
                let worktreePath = storageDirectory
                    .appendingPathComponent("Worktrees", isDirectory: true)
                    .appendingPathComponent(session.id, isDirectory: true)
                _ = try git.createWorktree(path: worktreePath, branch: session.branch, base: baseline)
                try repository.updateWorktreeBinding(sessionID: session.id, branch: session.branch, worktreePath: worktreePath.path, baselineRevision: baseline)
                try repository.saveWorktree(WorktreeRecord(sessionID: session.id, baseRevision: baseline, branch: session.branch, worktreePath: worktreePath.path))
                try repository.append(sessionID: session.id, type: "worktree_created", payload: ["path": worktreePath.path, "baseRevision": baseline, "branch": session.branch])
                selectedSessionID = session.id
                reloadWorkspace()
                refreshSelectedSession()
                statusMessage = "已创建 CI 修复 Session：\(session.title)"
            } catch {
                statusMessage = "创建 CI 修复 Session 失败：\(error.localizedDescription)"
            }
        }
    }

    public func refreshFiles() {
        guard !projectPath.isEmpty else {
            workspaceEntries = []
            return
        }
        let rootPath = (activeWorkspacePath as NSString).expandingTildeInPath
        let checkpointPath = storageDirectory.appendingPathComponent("Checkpoints", isDirectory: true).appendingPathComponent("file-browser", isDirectory: true)
        Task {
            let result = await Task.detached(priority: .userInitiated) { () -> [WorkspaceDirectoryEntry] in
                (try? WorkspaceToolHost(root: URL(fileURLWithPath: rootPath, isDirectory: true), checkpointDirectory: checkpointPath).listDirectory()) ?? []
            }.value
            workspaceEntries = result
        }
    }

    public func refreshFileTree() async {
        guard !projectPath.isEmpty else {
            fileTree = []
            workspaceEntries = []
            return
        }
        let rootPath = (activeWorkspacePath as NSString).expandingTildeInPath
        let expanded = expandedFilePaths
        let checkpointPath = storageDirectory.appendingPathComponent("Checkpoints", isDirectory: true).appendingPathComponent("file-editor", isDirectory: true)
        let result = await Task.detached(priority: .userInitiated) { () -> Result<[WorkspaceFileNode], Error> in
            do {
                let root = URL(fileURLWithPath: rootPath, isDirectory: true)
                let statuses = (try? GitService(root: root).statusEntries()) ?? []
                let statusMap = Dictionary(uniqueKeysWithValues: statuses.map { ($0.path, $0.fileStatus) })
                let workspace = try WorkspaceToolHost(root: root, checkpointDirectory: checkpointPath)
                return .success(try workspace.listTree(path: ".", expanded: expanded, maxDepth: 8, maxEntries: 1_500, gitStatuses: statusMap))
            } catch {
                return .failure(error)
            }
        }.value
        switch result {
        case let .success(nodes):
            fileTree = nodes
            workspaceEntries = nodes.filter { $0.depth == 0 }.map { WorkspaceDirectoryEntry(name: $0.name, isDirectory: $0.isDirectory) }
            editorStatusMessage = nodes.isEmpty ? "没有可显示的文件" : "文件树已刷新"
        case let .failure(error):
            fileTree = []
            editorStatusMessage = "文件树读取失败：\(error.localizedDescription)"
        }
    }

    public func toggleDirectory(path: String) {
        if expandedFilePaths.contains(path) {
            expandedFilePaths.remove(path)
        } else {
            expandedFilePaths.insert(path)
        }
        Task { await refreshFileTree() }
    }

    public func openFile(path: String) async {
        guard !projectPath.isEmpty else {
            isProjectPickerPresented = true
            return
        }
        if openEditorTabs.contains(where: { $0.id == path }) {
            selectEditorTab(id: path)
            return
        }
        let rootPath = (activeWorkspacePath as NSString).expandingTildeInPath
        let checkpointPath = storageDirectory.appendingPathComponent("Checkpoints", isDirectory: true).appendingPathComponent(selectedSessionID.isEmpty ? "editor" : selectedSessionID, isDirectory: true)
        let result = await Task.detached(priority: .userInitiated) { () -> Result<EditableFileSnapshot, Error> in
            do {
                let workspace = try WorkspaceToolHost(root: URL(fileURLWithPath: rootPath, isDirectory: true), checkpointDirectory: checkpointPath)
                return .success(try workspace.readEditableFile(path: path))
            } catch {
                return .failure(error)
            }
        }.value
        switch result {
        case let .success(snapshot):
            let gitStatus = fileTree.first(where: { $0.path == snapshot.path })?.gitStatus
            let tab = EditorTab(snapshot: snapshot, gitStatus: gitStatus)
            openEditorTabs.append(tab)
            selectEditorTab(id: tab.id)
            if snapshot.isBinary {
                editorStatusMessage = "二进制文件不可编辑"
            } else if snapshot.isLargeFile {
                editorStatusMessage = "大文件已以只读方式打开"
            } else {
                editorStatusMessage = "已打开 \(snapshot.path)"
            }
        case let .failure(error):
            editorStatusMessage = "打开文件失败：\(error.localizedDescription)"
        }
    }

    public func selectEditorTab(id: String) {
        guard let tab = openEditorTabs.first(where: { $0.id == id }) else { return }
        selectedEditorTabID = id
        syncEditorBuffer(from: tab)
    }

    public func closeEditorTab(id: String) {
        guard let index = openEditorTabs.firstIndex(where: { $0.id == id }) else { return }
        if openEditorTabs[index].isDirty {
            editorStatusMessage = "有未保存修改，保存或回滚后再关闭"
            return
        }
        openEditorTabs.remove(at: index)
        if selectedEditorTabID == id {
            selectedEditorTabID = openEditorTabs.indices.contains(index) ? openEditorTabs[index].id : openEditorTabs.last?.id
            if let selectedEditorTab {
                syncEditorBuffer(from: selectedEditorTab)
            } else {
                syncEditorBuffer(from: nil)
            }
        }
    }

    public func saveSelectedFile() async {
        guard let selectedEditorTabID, let index = openEditorTabs.firstIndex(where: { $0.id == selectedEditorTabID }) else { return }
        let tab = openEditorTabs[index]
        guard !tab.isReadOnly else {
            editorStatusMessage = "只读文件不能保存"
            return
        }
        let rootPath = (activeWorkspacePath as NSString).expandingTildeInPath
        let checkpointPath = storageDirectory.appendingPathComponent("Checkpoints", isDirectory: true).appendingPathComponent(selectedSessionID.isEmpty ? "editor" : selectedSessionID, isDirectory: true)
        let content = editorBuffer
        let expectedHash = tab.originalHash
        let path = tab.path
        let result = await Task.detached(priority: .userInitiated) { () -> Result<EditableFileSnapshot, Error> in
            do {
                let workspace = try WorkspaceToolHost(root: URL(fileURLWithPath: rootPath, isDirectory: true), checkpointDirectory: checkpointPath)
                return .success(try workspace.saveEditableFile(path: path, content: content, expectedHash: expectedHash))
            } catch {
                return .failure(error)
            }
        }.value
        switch result {
        case let .success(snapshot):
            let updated = EditorTab(snapshot: snapshot, gitStatus: tab.gitStatus)
            openEditorTabs[index] = updated
            syncEditorBuffer(from: updated)
            editorStatusMessage = "已保存 \(snapshot.path)"
            refreshGitStatus()
            await refreshFileTree()
        case let .failure(error):
            editorStatusMessage = "保存失败：\(error.localizedDescription)"
        }
    }

    public func revertSelectedFile() {
        guard let selectedEditorTabID, let index = openEditorTabs.firstIndex(where: { $0.id == selectedEditorTabID }) else { return }
        openEditorTabs[index].content = openEditorTabs[index].originalContent
        openEditorTabs[index].isDirty = false
        syncEditorBuffer(from: openEditorTabs[index])
        editorStatusMessage = "已回滚未保存修改"
    }

    public func reloadSelectedFileIfUnchanged() async {
        guard let selectedEditorTab, !selectedEditorTab.isDirty else {
            editorStatusMessage = "有未保存修改，未自动重新加载"
            return
        }
        closeEditorTab(id: selectedEditorTab.id)
        await openFile(path: selectedEditorTab.path)
    }

    public func createNewFile(named name: String = "untitled.txt") async {
        guard !projectPath.isEmpty else {
            isProjectPickerPresented = true
            return
        }
        let rootPath = (activeWorkspacePath as NSString).expandingTildeInPath
        let checkpointPath = storageDirectory.appendingPathComponent("Checkpoints", isDirectory: true).appendingPathComponent(selectedSessionID.isEmpty ? "editor" : selectedSessionID, isDirectory: true)
        let result = await Task.detached(priority: .userInitiated) { () -> Result<Void, Error> in
            do {
                let workspace = try WorkspaceToolHost(root: URL(fileURLWithPath: rootPath, isDirectory: true), checkpointDirectory: checkpointPath)
                _ = try workspace.applyPatch(changes: [PatchChange(path: name, content: "", expectedHash: nil)], label: "create file")
                return .success(())
            } catch {
                return .failure(error)
            }
        }.value
        switch result {
        case .success:
            editorStatusMessage = "已创建 \(name)"
            await refreshFileTree()
        case let .failure(error):
            editorStatusMessage = "创建文件失败：\(error.localizedDescription)"
        }
    }

    public func createNewFolder(named name: String = "New Folder") async {
        guard !projectPath.isEmpty else {
            isProjectPickerPresented = true
            return
        }
        let rootPath = (activeWorkspacePath as NSString).expandingTildeInPath
        let result = await Task.detached(priority: .userInitiated) { () -> Result<Void, Error> in
            do {
                try FileManager.default.createDirectory(at: URL(fileURLWithPath: rootPath, isDirectory: true).appendingPathComponent(name, isDirectory: true), withIntermediateDirectories: true)
                return .success(())
            } catch {
                return .failure(error)
            }
        }.value
        switch result {
        case .success:
            editorStatusMessage = "已创建文件夹 \(name)"
            await refreshFileTree()
        case let .failure(error):
            editorStatusMessage = "创建文件夹失败：\(error.localizedDescription)"
        }
    }

    private var currentProfile: ProviderProfile {
        let model = Self.normalizedProviderModel(providerModel)
        return ProviderProfile(
            name: providerName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "DeepSeek" : providerName,
            baseURL: providerBaseURL,
            model: model,
            protocolName: providerProtocol,
            apiKeyReference: "keychain://deepseek-default",
            capabilities: providerCapabilities,
            visionAdapter: Self.currentVisionAdapterConfiguration(
                enabled: visionAdapterEnabled,
                baseURL: visionAdapterBaseURL,
                model: visionAdapterModel
            )
        )
    }

    private static func normalizedProviderModel(_ value: String) -> String {
        let normalized = DeepSeekModelCatalog.normalizedModel(value)
        return normalized.isEmpty ? DeepSeekModelCatalog.fastModel : normalized
    }

    private static func currentVisionAdapterConfiguration(enabled: Bool, baseURL: String, model: String) -> VisionAdapterConfiguration? {
        guard enabled else { return nil }
        let trimmedBaseURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedBaseURL.isEmpty, !trimmedModel.isEmpty else { return nil }
        return VisionAdapterConfiguration(enabled: true, baseURL: trimmedBaseURL, model: trimmedModel, apiKeyReference: "keychain://deepseek-vision")
    }

    private func prepareContentParts(_ parts: [ContentPart], profile: ProviderProfile) async throws -> [ContentPart] {
        guard let attachmentStore else { return parts }
        var prepared: [ContentPart] = []
        for part in parts {
            switch part {
            case let .image(attachment) where !profile.capabilities.imageInput:
                if let configuration = profile.visionAdapter,
                   configuration.enabled,
                   !configuration.baseURL.isEmpty,
                   !configuration.model.isEmpty,
                   let apiKey = loadSecret(reference: configuration.apiKeyReference),
                   !apiKey.isEmpty {
                    let adapter = try OpenAICompatibleVisionAdapter(
                        baseURL: configuration.baseURL,
                        apiKey: apiKey,
                        model: configuration.model,
                        attachmentProvider: attachmentStore
                    )
                    let observation = try await adapter.observe(attachment: attachment, task: "请分析此图片与当前编码任务的关系，并指出可验证的 UI、错误或布局信息。")
                    let json = String(data: try JSONEncoder().encode(observation), encoding: .utf8) ?? observation.summary
                    prepared.append(.text("[视觉适配器观察 \(attachment.filename)]\n\(json)"))
                    continue
                }
                let extraction = try await Task.detached(priority: .userInitiated) {
                    try attachmentStore.extractText(from: attachment)
                }.value
                prepared.append(.text("[附件 \(attachment.filename) 的本地 OCR 结果]\n\(extraction.text)"))
            case let .document(attachment):
                let extraction = try await Task.detached(priority: .userInitiated) {
                    try attachmentStore.extractText(from: attachment)
                }.value
                prepared.append(.text("[附件 \(attachment.filename) 的本地提取结果]\n\(extraction.text)"))
            default:
                prepared.append(part)
            }
        }
        return prepared
    }

    private static func normalizeProviderBaseURL(_ value: String) -> String {
        guard let url = URL(string: value.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.host?.lowercased() == "api.deepseek.com" else { return value }
        let path = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased()
        return path == "v1" || path.isEmpty ? "https://api.deepseek.com" : value
    }

    private var activeWorkspacePath: String {
        if let repository, let stored = (try? repository.session(id: selectedSessionID)) ?? nil, let worktreePath = stored.worktreePath, !worktreePath.isEmpty {
            return worktreePath
        }
        return projectPath
    }

    private var scratchProjectURL: URL {
        storageDirectory.appendingPathComponent("QuickChat", isDirectory: true).standardizedFileURL
    }

    private func ensureScratchProject(repository: SessionRepository) throws -> ProjectRecord {
        let scratchURL = scratchProjectURL
        try FileManager.default.createDirectory(at: scratchURL, withIntermediateDirectories: true)
        if let existing = try repository.project(path: scratchURL.path) { return existing }
        return try repository.createProject(name: "快速对话", path: scratchURL.path)
    }

    private func slug(_ value: String) -> String {
        let normalized = value.lowercased().replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return normalized.isEmpty ? "task" : String(normalized.prefix(48))
    }

    private var sandboxAvailable: Bool { sandboxPreflight.available }
    private var trustKey: String { "DeepSeekCode.trustedProject.\(projectPath)" }

    private func loadAPIKey() -> String? {
        if !providerAPIKey.isEmpty { return providerAPIKey }
        return loadSecret(reference: "keychain://deepseek-default")
    }

    private func loadSecret(reference: String) -> String? {
        guard let secretStore else { return nil }
        return try? secretStore.load(reference: reference)
    }

    private func migrateElectronDataIfNeeded() {
        let migrationKey = "DeepSeekCode.electronMigration.v1"
        guard !UserDefaults.standard.bool(forKey: migrationKey), let repository, let providerCatalog else { return }
        let applicationSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        let candidates = [
            applicationSupport?.appendingPathComponent("deepseek-code-desktop/deepseek-code.sqlite"),
            applicationSupport?.appendingPathComponent("DeepSeek Code/deepseek-code.sqlite"),
            applicationSupport?.appendingPathComponent("DeepSeekCode Desktop/deepseek-code.sqlite")
        ].compactMap { $0 }
        guard let source = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) else { return }
        do {
            let report = try ElectronDataMigrator.migrate(sourceDatabase: source, destination: repository, providerCatalog: providerCatalog)
            UserDefaults.standard.set(true, forKey: migrationKey)
            if report.importedSessions > 0 || report.importedProviders > 0 {
                statusMessage = "已迁移 \(report.importedSessions) 个 Electron Session；请重新填写 Base URL 和 API Key"
            }
        } catch {
            statusMessage = "旧版数据迁移失败：\(error.localizedDescription)"
        }
    }

    /// Imports legacy JSONL only once after the durable SQLite tables exist.
    /// The old files remain untouched for export/recovery, but new runtime
    /// writes never go back to them.
    private func migrateLegacyJSONLEventsIfNeeded() {
        guard let repository else { return }
        let legacyRoot = storageDirectory.appendingPathComponent("LegacyEvents", isDirectory: true)
        let markerDirectory = storageDirectory.appendingPathComponent("Migrations", isDirectory: true)
        let marker = markerDirectory.appendingPathComponent("jsonl-durable-v1.imported")
        guard !FileManager.default.fileExists(atPath: marker.path),
              let files = try? FileManager.default.contentsOfDirectory(at: legacyRoot, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return }
        do {
            try FileManager.default.createDirectory(at: markerDirectory, withIntermediateDirectories: true)
            for file in files where file.pathExtension == "jsonl" {
                let data = try Data(contentsOf: file)
                for line in data.split(separator: 0x0A) {
                    guard let event = try? JSONDecoder().decode(SessionEvent.self, from: Data(line)),
                          try repository.session(id: event.sessionID) != nil else { continue }
                    try repository.importEvent(event)
                }
                _ = try? repository.refreshProjection(sessionID: file.deletingPathExtension().lastPathComponent)
                _ = try? repository.refreshPartProjection(sessionID: file.deletingPathExtension().lastPathComponent)
            }
            try Data("1\n".utf8).write(to: marker, options: .atomic)
        } catch {
            // Leave the marker absent so a later launch can retry from the
            // untouched legacy files; do not partially delete or rewrite them.
            return
        }
    }

    private func reloadWorkspace() {
        guard let repository else { return }
        projects = (try? repository.projects()) ?? []
        if selectedProjectID == nil || !projects.contains(where: { $0.id == selectedProjectID }) {
            selectedProjectID = projects.first?.id
        }
        if let selectedProjectID, let project = projects.first(where: { $0.id == selectedProjectID }) {
            projectPath = project.path
            let stored = (try? repository.sessions(projectID: selectedProjectID)) ?? []
            sessions = stored.map { storedSession in
                let events = (try? repository.events(sessionID: storedSession.id)) ?? []
                let projected = (try? SessionProjector.project(session: storedSession, events: events)) ?? ProjectedSessionState(session: storedSession)
                let cost = projected.usage.estimatedCost > 0 ? String(format: "¥%.4f", projected.usage.estimatedCost) : "—"
                return Session(id: storedSession.id, title: storedSession.title, target: storedSession.target, branch: storedSession.branch.isEmpty ? storedSession.mode.title : storedSession.branch, status: projected.session.status, cost: cost)
            }
        } else {
            sessions = []
            workspaceEntries = []
        }
        if !sessions.contains(where: { $0.id == selectedSessionID }) {
            selectedSessionID = sessions.first?.id ?? ""
        }
    }

    private func updateSelectedSessionListEntry(storedSession: StoredSession, projected: ProjectedSessionState) {
        let cost = projected.usage.estimatedCost > 0 ? String(format: "¥%.4f", projected.usage.estimatedCost) : "—"
        let summary = Session(
            id: storedSession.id,
            title: storedSession.title,
            target: storedSession.target,
            branch: storedSession.branch.isEmpty ? storedSession.mode.title : storedSession.branch,
            status: projected.session.status,
            cost: cost
        )
        if let index = sessions.firstIndex(where: { $0.id == summary.id }) {
            sessions[index] = summary
            if index > 0 {
                let updated = sessions.remove(at: index)
                sessions.insert(updated, at: 0)
            }
        } else {
            sessions.insert(summary, at: 0)
        }
    }

    private func updateSelectedSessionStatus(_ status: SessionStatus) {
        guard let index = sessions.firstIndex(where: { $0.id == selectedSessionID }) else { return }
        sessions[index].status = status
        if index > 0 {
            let updated = sessions.remove(at: index)
            sessions.insert(updated, at: 0)
        }
    }

    private func updateAgentWorker(for workerID: String, event: AgentEvent) {
        let current = agentWorkerRegistry.records().first(where: { $0.id == workerID })
        guard current != nil else { return }
        switch event {
        case .started:
            _ = agentWorkerRegistry.transition(id: workerID, state: .running, detail: "Agent 正在推理", checkpoint: AgentWorkerCheckpoint(title: "模型推理", detail: "等待模型输出"))
        case let .toolRequested(name):
            _ = agentWorkerRegistry.transition(id: workerID, state: .running, detail: "正在调用 \(name)", checkpoint: AgentWorkerCheckpoint(title: "工具调用", detail: name))
        case let .toolCompleted(name, succeeded):
            _ = agentWorkerRegistry.transition(id: workerID, state: .running, detail: succeeded ? "已完成 \(name)" : "\(name) 失败", checkpoint: AgentWorkerCheckpoint(title: "工具完成", detail: succeeded ? name : "失败：\(name)"))
        case let .approvalRequired(tool, _):
            _ = agentWorkerRegistry.transition(id: workerID, state: .waitingApproval, detail: "等待 \(tool) 审批", checkpoint: AgentWorkerCheckpoint(title: "等待审批", detail: tool))
        case .assistantDelta, .usage:
            break
        case .completed:
            _ = agentWorkerRegistry.transition(id: workerID, state: .completed, detail: "本轮完成", checkpoint: AgentWorkerCheckpoint(title: "完成", detail: "已生成最终结果"))
            if let sessionID = current?.sessionID {
                let summary = current?.detail ?? "Worker 已完成"
                let outputHash = SHA256.hash(data: Data(summary.utf8)).map { String(format: "%02x", $0) }.joined()
                agentWorkerRegistry.setResult(
                    id: workerID,
                    result: WorkerResultEnvelope(workerID: workerID, sessionID: sessionID, summary: summary, outputHash: outputHash)
                )
            }
        case let .failed(message):
            _ = agentWorkerRegistry.transition(id: workerID, state: .failed, detail: "执行失败", errorMessage: message)
            if let sessionID = current?.sessionID {
                agentWorkerRegistry.setResult(
                    id: workerID,
                    result: WorkerResultEnvelope(workerID: workerID, sessionID: sessionID, summary: "Worker 执行失败", errorMessage: message)
                )
            }
        }
        if let sessionID = current?.sessionID { agentWorkers = agentWorkerRegistry.records(sessionID: sessionID) }
    }

    private func apply(event: AgentEvent, profile: ProviderProfile) {
        switch event {
        case .started:
            statusMessage = "Agent 正在推理…"
            updateSelectedSessionStatus(.running)
        case let .assistantDelta(text):
            transcript.append(text)
            if let index = conversationMessages.lastIndex(where: { $0.role == .assistant }), index == conversationMessages.count - 1 {
                conversationMessages[index].text += text
            } else {
                conversationMessages.append(ConversationMessage(role: .assistant, text: text))
            }
            appendLiveAssistantDelta(text)
        case let .toolRequested(name):
            statusMessage = "Agent 请求工具：\(name)"
            activityItems.append(ActivityItem(title: name, detail: "Agent 请求执行", state: "进行中"))
        case let .toolCompleted(name, succeeded):
            statusMessage = succeeded ? "工具完成：\(name)" : "工具失败：\(name)"
            activityItems.append(ActivityItem(title: name, detail: succeeded ? "执行完成" : "执行失败", state: succeeded ? "完成" : "失败"))
        case let .approvalRequired(tool, risk):
        pendingApproval = ((try? repository?.runState(sessionID: selectedSessionID)) ?? nil)?.pendingApproval
        refreshNetworkState()
            updateSelectedSessionStatus(.awaitingToolApproval)
            statusMessage = "需要审批：\(tool)（L\(risk.rawValue)）"
            activityItems.append(ActivityItem(title: tool, detail: "风险等级 L\(risk.rawValue)", state: "等待审批"))
            conversationTimeline.append(ConversationEntry(
                kind: .approval,
                title: ConversationProjector.approvalTitle(for: tool),
                text: ConversationProjector.approvalText(tool: tool, risk: "L\(risk.rawValue)"),
                state: .waiting
            ))
        case let .usage(input, cachedInput, output, latencyMilliseconds):
            let beforeCost = usageSummary.estimatedCost
            usageSummary.record(input: input, cachedInput: cachedInput, output: output, pricing: profile)
            let routedModel = DeepSeekModelCatalog.routedModel(preferred: profile.model, mode: mode, prompt: prompt)
            usageLedger.record(UsageRecord(
                feature: .mainAgent,
                model: routedModel,
                inputTokens: input,
                cachedInputTokens: cachedInput,
                reasoningTokens: 0,
                outputTokens: output,
                latencyMilliseconds: latencyMilliseconds,
                estimatedCost: max(0, usageSummary.estimatedCost - beforeCost),
                succeeded: true
            ))
        case .completed:
            flushStreamingBuffer()
            transcript.flush()
            statusMessage = "Agent 已完成本轮"
        case let .failed(message):
            statusMessage = "Agent 失败：\(message)"
            updateSelectedSessionStatus(.failed)
        }
    }

    private func appendLiveAssistantDelta(_ text: String) {
        // 直接追加到 timeline，不使用防抖
        // 防抖逻辑在多线程环境下容易出问题
        if let index = conversationTimeline.indices.last, conversationTimeline[index].kind == .assistant {
            conversationTimeline[index].text += text
        } else {
            conversationTimeline.append(ConversationEntry(kind: .assistant, title: "DeepSeek", text: text))
        }
    }

    private func flushStreamingBuffer() {
        // 清理状态（虽然不再使用防抖，但保留方法以防其他地方调用）
        streamingTask?.cancel()
        streamingTask = nil
        streamingBuffer = ""
    }

    private func toolHost() throws -> WorkspaceToolHost {
        let path = (activeWorkspacePath as NSString).expandingTildeInPath
        let root = URL(fileURLWithPath: path, isDirectory: true)
        return try WorkspaceToolHost(root: root, checkpointDirectory: storageDirectory.appendingPathComponent("Checkpoints", isDirectory: true).appendingPathComponent(selectedSessionID.isEmpty ? "default" : selectedSessionID, isDirectory: true))
    }

    private func makeToolRuntime(workspace: WorkspaceToolHost?) -> (registry: ToolRegistry, router: ToolHostRouter) {
        let registry = ToolRegistry(AgentToolSchemas.registry.allTools())
        let router = ToolHostRouter(registry: registry, repository: repository)
        if let workspace {
            // Empty prefix is the safe fallback for built-in tools. Extension
            // hosts can later register a longer prefix and take precedence.
            router.register(host: LocalWorkspaceToolHost(workspace: workspace), forPrefix: "")
        }
        if let terminalHelperManager {
            let terminalManifest = terminalCapabilityManifest()
            let terminalHost = PersistentTerminalToolHost(
                host: ProcessPersistentTerminalHost(manager: terminalHelperManager),
                repository: repository,
                defaultCWD: activeWorkspacePath,
                sandboxRoot: activeWorkspacePath,
                sandboxScratchRoot: storageDirectory.appendingPathComponent("Sandbox", isDirectory: true).path,
                manifest: terminalManifest
            )
            router.register(host: terminalHost, forPrefix: "terminal.")
            router.register(host: terminalHost, for: "run_command")
        } else {
            let terminalHost = TerminalToolHost(localHost: localTerminalHost, repository: repository, defaultCWD: activeWorkspacePath, manifest: terminalCapabilityManifest())
            router.register(host: terminalHost, forPrefix: "terminal.")
            // Backward-compatible alias: the legacy run_command tool now uses the
            // same PTY runtime and evidence path as terminal.exec.
            router.register(host: terminalHost, for: "run_command")
        }
        let githubTools = [
            RegisteredTool(name: "github.create_pr", description: "创建 GitHub Pull Request", parameters: .objectSchema(), effect: .externalWrite, risk: .l2, timeoutMilliseconds: 60_000, maxOutputBytes: 32_000, idempotent: false, supportsCancellation: true),
            RegisteredTool(name: "github.pr_checks", description: "查看 Pull Request CI", parameters: .objectSchema(), effect: .network, risk: .l2, timeoutMilliseconds: 60_000, maxOutputBytes: 32_000, idempotent: true, supportsCancellation: true),
            RegisteredTool(name: "github.ci_logs", description: "读取失败 CI 日志摘要", parameters: .objectSchema(), effect: .network, risk: .l1, timeoutMilliseconds: 60_000, maxOutputBytes: 64_000, idempotent: true, supportsCancellation: true),
            RegisteredTool(name: "github.view_pr", description: "读取 Pull Request 状态", parameters: .objectSchema(), effect: .network, risk: .l1, timeoutMilliseconds: 30_000, maxOutputBytes: 32_000, idempotent: true, supportsCancellation: true),
            RegisteredTool(name: "github.push", description: "推送当前分支到 GitHub", parameters: .objectSchema(), effect: .externalWrite, risk: .l2, timeoutMilliseconds: 60_000, maxOutputBytes: 32_000, idempotent: false, supportsCancellation: true),
            RegisteredTool(name: "github.reply_review", description: "回复 Pull Request Review 评论", parameters: .objectSchema(), effect: .externalWrite, risk: .l2, timeoutMilliseconds: 60_000, maxOutputBytes: 32_000, idempotent: false, supportsCancellation: true)
        ]
        githubTools.forEach { registry.register($0) }
        router.register(host: GitHubToolHost(runner: ProcessGitHubCommandRunner(workingDirectory: URL(fileURLWithPath: activeWorkspacePath, isDirectory: true)), networkRuntime: networkRuntime), forPrefix: "github.")
        router.register(host: BrowserAutomationBridge.shared, forPrefix: "browser.")
        let configuredProviders: [any SearchProvider] = searchProviders
            .filter { $0.enabled }
            .compactMap { configuration in
                try? HTTPJSONSearchProvider(configuration: configuration, runtime: networkRuntime, secretStore: secretStore)
            }
        let webHost = WebToolHost(runtime: networkRuntime, searchProviders: configuredProviders, projectID: selectedProjectID)
        router.register(host: webHost, for: "web_search")
        router.register(host: webHost, for: "web_fetch")
        router.register(host: SSHDispatchToolHost(manager: sshConnectionManager, networkRuntime: networkRuntime), for: "ssh.execute")
        #if os(macOS)
        router.register(host: ComputerToolHost(), forPrefix: "computer.")
        #endif
        return (registry, router)
    }

    private func prepareMCPRuntime(registry: ToolRegistry, router: ToolHostRouter) async {
        guard !mcpServers.isEmpty else { return }
        var manifests: [String: HostCapabilityManifest] = [:]
        for server in mcpServers where server.enabled {
            let domain: String?
            switch server.transport {
            case let .streamableHTTP(url): domain = URL(string: url)?.host
            case .stdio: domain = nil
            }
            manifests[server.id] = HostCapabilityManifest(
                hostID: "mcp.\(server.id)",
                allowedDomains: domain.map { [$0] } ?? [],
                allowedEffects: [.readOnly, .network, .externalWrite],
                maxOutputBytes: 128_000,
                timeoutMilliseconds: 30_000
            )
        }
        let manager = DefaultMCPManager(registry: registry, manifests: manifests)
        for server in mcpServers where server.enabled {
            guard server.trusted else {
                statusMessage = "MCP \(server.name) 等待项目/用户信任"
                continue
            }
            do {
                let transport: any MCPTransport
                switch server.transport {
                case let .stdio(command, arguments):
                    transport = StdioMCPTransport(command: command, arguments: arguments)
                case let .streamableHTTP(url):
                    guard let endpoint = URL(string: url) else { continue }
                    transport = StreamableHTTPMCPTransport(
                        endpoint: endpoint,
                        authorizationReference: server.authorizationReference,
                        secretStore: secretStore,
                        runtime: networkRuntime
                    )
                }
                try await manager.connect(serverID: server.id, transport: transport)
            } catch {
                statusMessage = "MCP \(server.name) 连接失败：\(error.localizedDescription)"
            }
        }
        await manager.installRoutes(on: router)
    }

    private func terminalCapabilityManifest() -> HostCapabilityManifest {
        var paths = [activeWorkspacePath]
        paths.append(storageDirectory.appendingPathComponent("Sandbox", isDirectory: true).path)
        return HostCapabilityManifest(
            hostID: "terminal.\(selectedSessionID)",
            allowedPaths: paths,
            allowedEffects: [.readOnly, .workspaceWrite, .process, .gitWrite, .network],
            allowedEnvironmentKeys: ["PATH", "HOME", "PWD", "TMPDIR"],
            maxOutputBytes: 128_000,
            timeoutMilliseconds: 120_000
        )
    }

    private func hookManifest(sessionID: String) -> HostCapabilityManifest {
        HostCapabilityManifest(
            hostID: "hooks.\(sessionID)",
            allowedPaths: [activeWorkspacePath],
            allowedEffects: [.process],
            allowedEnvironmentKeys: ["PATH", "PWD", "TMPDIR"],
            maxOutputBytes: 32_000,
            timeoutMilliseconds: 10_000
        )
    }

    private func syncEditorBuffer(from tab: EditorTab?) {
        isSyncingEditorBuffer = true
        editorBuffer = tab?.content ?? ""
        editorOriginalHash = tab?.originalHash
        editorIsDirty = tab?.isDirty ?? false
        isSyncingEditorBuffer = false
    }

    private func runGitAction(label: String, operation: @escaping @Sendable (GitService) throws -> Void, onSuccess: @escaping @MainActor () -> Void = {}) {
        guard !projectPath.isEmpty else { isProjectPickerPresented = true; return }
        let rootPath = (activeWorkspacePath as NSString).expandingTildeInPath
        statusMessage = "\(label) 执行中…"
        Task {
            let result = await Task.detached(priority: .userInitiated) { () -> String? in
                do {
                    let service = try GitService(root: URL(fileURLWithPath: rootPath, isDirectory: true))
                    try operation(service)
                    return nil
                } catch {
                    return error.localizedDescription
                }
            }.value
            if let result {
                statusMessage = "\(label) 失败：\(result)"
            } else {
                onSuccess()
                statusMessage = "\(label) 完成"
                refreshGitStatus()
            }
        }
    }

    private func jsonString(_ value: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [value]),
              let encoded = String(data: data, encoding: .utf8) else { return "\"\"" }
        return String(encoded.dropFirst().dropLast())
    }
}
