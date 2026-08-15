import SwiftUI
import UniformTypeIdentifiers
import WebKit
import AppKit
import DeepSeekCodeCore
import SwiftTerm

// SwiftTerm exports an AppKit terminal `Color` type. Keep the existing
// SwiftUI view code unambiguous while referring to SwiftTerm types explicitly.
private typealias Color = SwiftUI.Color

struct ContentView: View {
    @Environment(WorkspaceStore.self) private var store

    var body: some View {
        @Bindable var store = store

        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(
                    min: WorkspaceDesignTokens.sidebarMinWidth,
                    ideal: WorkspaceDesignTokens.sidebarIdealWidth,
                    max: WorkspaceDesignTokens.sidebarMaxWidth
                )
        } detail: {
            if store.activeSection == .projects || store.activeSection == .sessions {
                GeometryReader { proxy in
                    let metrics = WorkspaceLayoutMetrics.forDetailWidth(
                        proxy.size.width,
                        inspectorContent: store.selectedRightPanel.workspaceInspectorContent,
                        inspectorVisible: store.isInspectorVisible
                    )

                    Group {
                        if store.hasActiveSession {
                            if !store.isInspectorVisible {
                                ConversationView(
                                    contentPadding: metrics.contentPadding,
                                    contentMaxWidth: metrics.conversationContentMaxWidth
                                )
                                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                            } else if metrics.usesStackedInspector {
                                VSplitView {
                                    ConversationView(
                                        contentPadding: metrics.contentPadding,
                                        contentMaxWidth: metrics.conversationContentMaxWidth
                                    )
                                        .frame(minHeight: 420, idealHeight: 560)
                                    RightPanelView()
                                        .frame(minHeight: 240, idealHeight: 300)
                                }
                            } else {
                                HSplitView {
                                    ConversationView(
                                        contentPadding: metrics.contentPadding,
                                        contentMaxWidth: metrics.conversationContentMaxWidth
                                    )
                                        .frame(
                                            minWidth: metrics.conversationMinWidth,
                                            idealWidth: metrics.conversationIdealWidth,
                                            maxWidth: .infinity
                                        )
                                    RightPanelView()
                                        .frame(
                                            minWidth: metrics.rightPanelMinWidth,
                                            idealWidth: metrics.rightPanelIdealWidth,
                                            maxWidth: metrics.rightPanelMaxWidth
                                        )
                                }
                            }
                        } else {
                            WelcomeWorkspaceView()
                        }
                    }
                    .background(AppTheme.canvas)
                    .safeAreaInset(edge: .bottom, spacing: 0) {
                        VStack(spacing: 0) {
                            if !store.hasActiveSession {
                                HomeComposerDock()
                            }
                            BottomStatusBar()
                        }
                    }
                }
            } else if store.activeSection == .agents {
                AgentWorkersPanel()
                    .background(AppTheme.canvas)
            } else {
                ExtensionPanel(section: store.activeSection)
                    .background(AppTheme.canvas)
            }
        }
        .navigationSplitViewStyle(.balanced)
        .navigationTitle("")
        .environment(\.font, .system(size: WorkspaceTypography.bodySize))
        .toolbar { ToolbarItemGroup(placement: .primaryAction) { ToolbarButtons() } }
        .onChange(of: store.selectedSessionID) { _, _ in store.refreshSelectedSession() }
        .sheet(isPresented: $store.isSettingsPresented) { SettingsView() }
        .fileImporter(isPresented: $store.isProjectPickerPresented, allowedContentTypes: [.folder], allowsMultipleSelection: false) { result in
            if case let .success(urls) = result, let url = urls.first {
                store.chooseProject(url.path)
            }
        }
        .fileImporter(
            isPresented: $store.isAttachmentPickerPresented,
            allowedContentTypes: [.image, .pdf, .text, .data],
            allowsMultipleSelection: true
        ) { result in
            if case let .success(urls) = result {
                urls.forEach { store.addAttachment(at: $0) }
            }
        }
        .fileImporter(
            isPresented: $store.isSessionRestorePickerPresented,
            allowedContentTypes: [.json],
            allowsMultipleSelection: false
        ) { result in
            if case let .success(urls) = result, let url = urls.first {
                store.restoreDeletedSession(from: url)
            }
        }
    }
}

private struct SidebarView: View {
    @Environment(WorkspaceStore.self) private var store

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 9) {
                Image(systemName: "sparkles")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text("DeepSeek Code")
                    .font(.system(size: WorkspaceTypography.titleSize, weight: .semibold))
                Spacer()
                Button { store.isSettingsPresented = true } label: {
                    Image(systemName: "gearshape")
                }
                .buttonStyle(AppIconButtonStyle())
                .help("设置")
            }
            .padding(.horizontal, 14)
            .padding(.top, 16)
            .padding(.bottom, 12)

            SidebarModePill()
                .padding(.horizontal, 11)
                .padding(.top, 1)

            Button { store.createSession() } label: {
                HStack(spacing: 8) {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 18)
                    Text("New session")
                        .font(.system(size: WorkspaceTypography.labelSize, weight: .medium))
                    Spacer()
                    Text("⌘N")
                        .font(.system(size: WorkspaceTypography.microSize, weight: .medium, design: .rounded))
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 8)
                .frame(height: WorkspaceDesignTokens.sidebarActionHeight)
                .contentShape(Rectangle())
            }
            .buttonStyle(AppSidebarActionButtonStyle())
            .padding(.horizontal, 11)
            .padding(.top, 9)

            Button { store.isSettingsPresented = true } label: {
                HStack(spacing: 8) {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 10, weight: .semibold))
                        .frame(width: 18)
                    Text("Customize")
                        .font(.system(size: WorkspaceTypography.metaSize, weight: .medium))
                    Spacer()
                }
                .padding(.horizontal, 8)
                .frame(height: WorkspaceDesignTokens.sidebarActionHeight)
                .contentShape(Rectangle())
            }
            .buttonStyle(AppSidebarActionButtonStyle())
            .padding(.horizontal, 11)
            .padding(.top, 2)
            .padding(.bottom, 10)

            SidebarNavItem(title: "Network", icon: "network", selected: store.activeSection == .network) {
                store.activeSection = .network
                store.refreshNetworkState()
            }
            .padding(.horizontal, 11)

            SidebarNavItem(
                title: "Agents",
                icon: "sparkles",
                selected: store.activeSection == .agents,
                badge: store.agentWorkers.filter(\.isLive).isEmpty ? nil : "\(store.agentWorkers.filter(\.isLive).count)"
            ) {
                store.activeSection = .agents
                store.refreshSelectedSession()
            }
            .padding(.horizontal, 11)

            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    SidebarProjectSection()
                    SidebarRecentSessionsSection()
                }
                .padding(.horizontal, 10)
                .padding(.top, 12)
                .padding(.bottom, 14)
            }
            Divider()
            SidebarFooter()
        }
        .background(AppTheme.sidebar)
    }
}

/// A quiet sidebar action that behaves like a navigation row rather than a
/// large card. Keeping hover and pressed states here makes the New session and
/// Customize affordances consistent with the rest of the sidebar.
private struct AppSidebarActionButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        AppSidebarActionButtonBody(label: configuration.label, isPressed: configuration.isPressed)
    }
}

private struct AppSidebarActionButtonBody<Label: View>: View {
    let label: Label
    let isPressed: Bool
    @State private var isHovered = false

    var body: some View {
        label
            .foregroundStyle(isPressed || isHovered ? .primary : .secondary)
            .background(
                isPressed
                    ? Color.primary.opacity(0.11)
                    : (isHovered ? AppTheme.hover : Color.clear),
                in: RoundedRectangle(cornerRadius: 7, style: .continuous)
            )
            .contentShape(Rectangle())
            .onHover { isHovered = $0 }
            .animation(.easeOut(duration: 0.12), value: isHovered)
    }
}

private struct SidebarModePill: View {
    @State private var isCoworkHovered = false
    @State private var isCodeHovered = false

    var body: some View {
        HStack(spacing: 1) {
            HStack(spacing: 7) {
                Image(systemName: "checklist")
                    .font(.system(size: 11, weight: .semibold))
                Text("Cowork")
                    .font(.system(size: WorkspaceTypography.labelSize, weight: .medium))
            }
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .frame(height: 31)
            .background(isCoworkHovered ? AppTheme.hover : Color.clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .onHover { isCoworkHovered = $0 }
            HStack(spacing: 7) {
                Image(systemName: "chevron.left.forwardslash.chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                Text("Code")
                    .font(.system(size: WorkspaceTypography.labelSize, weight: .semibold))
            }
            .foregroundStyle(isCodeHovered ? .primary : .secondary)
            .frame(maxWidth: .infinity)
            .frame(height: 31)
            .background(isCodeHovered ? AppTheme.hover : AppTheme.elevated, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(AppTheme.border.opacity(0.52), lineWidth: 1)
            }
            .onHover { isCodeHovered = $0 }
        }
        .padding(2)
        .background(Color.primary.opacity(0.028), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

private struct SidebarProjectSection: View {
    @Environment(WorkspaceStore.self) private var store
    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text("Projects")
                    .appSectionTitle()
                Spacer()
                Button { store.isProjectPickerPresented = true } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(AppIconButtonStyle())
                .help("打开项目")
            }
            Button { store.isProjectPickerPresented = true } label: {
                HStack(spacing: 8) {
                    Image(systemName: "folder")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(store.projectName.isEmpty ? "选择一个项目" : store.projectName)
                            .font(.system(size: WorkspaceTypography.labelSize, weight: .medium))
                            .lineLimit(1)
                        Text(store.projectPath.isEmpty ? "本地工作区" : store.projectPath)
                            .font(.system(size: WorkspaceTypography.microSize))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 9)
                .frame(height: WorkspaceDesignTokens.sidebarProjectRowHeight)
                .background(store.projectPath.isEmpty ? (isHovered ? AppTheme.hover : Color.clear) : (isHovered ? AppTheme.hover : AppTheme.selected), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { isHovered = $0 }
            .animation(.easeOut(duration: 0.12), value: isHovered)
        }
    }
}

private struct SidebarRecentSessionsSection: View {
    @Environment(WorkspaceStore.self) private var store

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text("Recent sessions")
                    .appSectionTitle()
                Spacer()
                Text("\(store.sessions.count)")
                    .font(.system(size: WorkspaceTypography.microSize, weight: .medium, design: .rounded))
                    .foregroundStyle(.tertiary)
            }
            if store.sessions.isEmpty {
                Text("还没有任务")
                    .font(.system(size: WorkspaceTypography.metaSize))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
            } else {
                ForEach(store.sessions) { session in
                    SidebarSessionRow(session: session, selected: session.id == store.selectedSessionID) {
                        store.selectedSessionID = session.id
                        store.activeSection = .sessions
                    }
                }
            }
        }
    }
}

private struct SidebarSection<Content: View, Accessory: View>: View {
    let title: String
    let accessory: Accessory
    @ViewBuilder let content: Content

    init(title: String, @ViewBuilder accessory: () -> Accessory = { EmptyView() }, @ViewBuilder content: () -> Content) {
        self.title = title
        self.accessory = accessory()
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                    .appSectionTitle()
                Spacer()
                accessory
            }
            .padding(.horizontal, 4)
            VStack(spacing: 4) { content }
        }
    }
}

private struct SidebarNavItem: View {
    let title: String
    let icon: String
    var selected = false
    var badge: String?
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(selected ? .primary : .secondary)
                    .frame(width: 18, height: 18)
                    .background((selected ? Color.primary.opacity(0.06) : Color.primary.opacity(0.035)), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                Text(title)
                    .font(.system(size: 12, weight: selected ? .semibold : .medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer()
                if let badge {
                    Text(badge)
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 32)
            .foregroundStyle(selected ? .primary : .secondary)
            .background(selected ? AppTheme.selected : (isHovered ? AppTheme.hover : Color.clear), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovered)
        .help(title)
    }
}

private struct SidebarSessionRow: View {
    let session: Session
    let selected: Bool
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                AppStatusDot(color: statusColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.title)
                        .font(.system(size: WorkspaceTypography.labelSize, weight: selected ? .semibold : .medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    HStack(spacing: 5) {
                        Text(session.target.title)
                        Text("·")
                        Text(session.status.title)
                    }
                    .font(.system(size: WorkspaceTypography.microSize))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                }
                Spacer(minLength: 6)
                Text(session.cost)
                    .font(.system(size: WorkspaceTypography.microSize, weight: .medium, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 8)
            .frame(height: WorkspaceDesignTokens.sidebarSessionRowHeight)
            .background(selected ? AppTheme.selected : (isHovered ? AppTheme.hover : Color.clear), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovered)
        .help(session.title)
    }

    private var statusColor: Color {
        switch session.status {
        case .created, .planning, .verifying, .awaitingPlanApproval: .blue
        case .executing: .mint
        case .running: .mint
        case .awaitingToolApproval, .awaitingApproval, .needsReview, .handoffReady, .awaitingDeliveryApproval: .orange
        case .delivering: .purple
        case .needsRepair: .red
        case .needsAttention, .failed: .red
        case .delivered, .completed: .green
        case .waiting: .secondary
        }
    }
}

private struct SidebarFooter: View {
    @Environment(WorkspaceStore.self) private var store

    var body: some View {
        HStack(spacing: 8) {
            Button { store.statusMessage = "当前执行目标：\(store.executionTarget.title)" } label: {
                InteractiveBadgeLabel(title: store.executionTarget.title, systemImage: "lock.shield", tint: .secondary)
            }
            .buttonStyle(.plain)
            Spacer()
            Button { store.isSettingsPresented = true } label: {
                Image(systemName: "gearshape")
            }
            .buttonStyle(AppIconButtonStyle())
            .help("Settings")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(AppTheme.chrome.opacity(0.72))
    }
}

private struct ConversationView: View {
    @Environment(WorkspaceStore.self) private var store
    let contentPadding: Double
    let contentMaxWidth: Double

    init(contentPadding: Double = 24, contentMaxWidth: Double = WorkspaceDesignTokens.conversationMaxWidth) {
        self.contentPadding = contentPadding
        self.contentMaxWidth = contentMaxWidth
    }

    var body: some View {
        @Bindable var store = store

        VStack(spacing: 0) {
            ConversationHeader()
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: WorkspaceDesignTokens.sectionSpacing) {
                        if store.conversationTimeline.isEmpty {
                            PlanCard()
                        }
                        ActivityFeed()
                        Color.clear.frame(height: 1).id("conversation-bottom")
                    }
                    .frame(maxWidth: contentMaxWidth, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.horizontal, contentPadding)
                    .padding(.vertical, 20)
                }
                .onChange(of: store.conversationTimeline.count) { _, _ in
                    withAnimation(.easeOut(duration: 0.18)) {
                        proxy.scrollTo("conversation-bottom", anchor: .bottom)
                    }
                }
            }
            VStack(spacing: 0) {
                ComposerView(
                    prompt: $store.prompt,
                    mode: $store.mode,
                    showsTopDivider: false
                ) {
                    store.sendTask()
                }
                .frame(maxWidth: contentMaxWidth)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, contentPadding)
                .padding(.vertical, 4)
            }
            .background(AppTheme.canvas)
        }
        .background(AppTheme.canvas)
    }
}

private struct ConversationHeader: View {
    @Environment(WorkspaceStore.self) private var store
    @State private var showsDeleteSessionConfirmation = false

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: "sparkles")
                .font(.system(size: WorkspaceTypography.metaSize, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 26, height: 26)
                .background(Color.accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            Text(store.selectedSession.title)
                .font(.system(size: WorkspaceTypography.titleSize, weight: .semibold, design: .rounded))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            ConversationStatusPill(status: store.selectedSession.status)
            if !store.gitStatusEntries.isEmpty {
                Button {
                    store.selectedRightPanel = .changes
                    store.isInspectorVisible = true
                } label: {
                    HStack(spacing: 5) {
                        AppStatusDot(color: .orange)
                        Text("\(store.gitStatusEntries.count)")
                            .font(.system(size: WorkspaceTypography.microSize, weight: .semibold, design: .rounded))
                    }
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 7)
                    .frame(height: 24)
                    .background(Color.primary.opacity(0.05), in: Capsule(style: .continuous))
                }
                .buttonStyle(.plain)
                .help("查看变更")
            }
            AppToolbarIconButton(
                title: store.isInspectorVisible ? "隐藏侧栏" : "显示侧栏",
                systemImage: "sidebar.right"
            ) {
                store.isInspectorVisible.toggle()
            }
            AppToolbarIconButton(title: "打开终端", systemImage: "terminal") {
                store.selectedRightPanel = .terminal
                store.isInspectorVisible = true
            }
            Menu {
                Button("Fork Session", systemImage: "arrow.triangle.branch") { store.forkSelectedSession() }
                    .disabled(!store.hasActiveSession)
                if !store.isScratchProject && !store.selectedSession.branch.isEmpty && store.selectedSession.branch != "main" {
                    Button("Create PR", systemImage: "arrow.up.right.square") { store.createPullRequest() }
                }
                Divider()
                Button("归档 Session", systemImage: "archivebox") { store.archiveSelectedSession() }
                Button("永久删除 Session", systemImage: "trash", role: .destructive) {
                    showsDeleteSessionConfirmation = true
                }
                Divider()
                Button(store.isProjectTrusted ? "取消信任项目" : "信任此项目", systemImage: store.isProjectTrusted ? "shield.slash" : "checkmark.shield") {
                    store.setProjectTrusted(!store.isProjectTrusted)
                }
            } label: {
                Image(systemName: "ellipsis")
            }
            .buttonStyle(AppIconButtonStyle())
        }
        .padding(.horizontal, 16)
        .frame(height: 56)
        .background(AppTheme.canvas)
        .confirmationDialog(
            "永久删除这个 Session？",
            isPresented: $showsDeleteSessionConfirmation,
            titleVisibility: .visible
        ) {
            Button("删除并保留本地备份", role: .destructive) {
                store.deleteSelectedSession()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("对话、审批、证据和任务记录会从应用数据库删除；可通过本机自动备份恢复。执行中的 Session 需要先停止。")
        }
    }
}

private struct ConversationStatusPill: View {
    let status: SessionStatus

    var body: some View {
        let descriptor = ConversationStatusPresentation.descriptor(for: status)
        HStack(spacing: 5) {
            Image(systemName: descriptor.systemImage)
                .font(.system(size: WorkspaceTypography.microSize, weight: .bold))
            Text(descriptor.title)
                .font(.system(size: WorkspaceTypography.microSize, weight: .semibold, design: .rounded))
        }
        .foregroundStyle(conversationTint(descriptor.colorToken))
        .padding(.horizontal, 8)
        .frame(height: 24)
        .background(conversationTint(descriptor.colorToken).opacity(0.09), in: Capsule(style: .continuous))
        .overlay {
            Capsule(style: .continuous)
                .stroke(conversationTint(descriptor.colorToken).opacity(0.16), lineWidth: 1)
        }
        .accessibilityLabel("任务状态：\(descriptor.title)")
    }
}

private func conversationTint(_ token: String) -> Color {
    switch token {
    case "blue": .blue
    case "mint": .mint
    case "amber": .orange
    case "purple": .purple
    case "red": .red
    case "green": .green
    default: .secondary
    }
}

private struct PlanCard: View {
    @Environment(WorkspaceStore.self) private var store

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            AppSectionHeader(title: "Plan", systemImage: "list.bullet.rectangle")
            Text(store.mode == .plan ? "Agent 会先只读探索仓库，计划写入当前 Session，批准后进入执行。" : "当前 Session 尚未生成结构化计划；切换到 Plan 模式可先只读探索仓库。")
                .font(.system(size: WorkspaceTypography.bodySize))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("计划、审批和工具活动会持久化到本机 Session 数据库。")
                .font(.system(size: WorkspaceTypography.metaSize))
                .foregroundStyle(.tertiary)
        }
        .appPanel()
    }
}

private struct ActivityFeed: View {
    @Environment(WorkspaceStore.self) private var store

    var body: some View {
        VStack(alignment: .leading, spacing: WorkspaceDesignTokens.compactSpacing) {
            ForEach(store.conversationTimeline) { entry in
                ConversationTimelineRow(entry: entry)
            }
            if store.conversationTimeline.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Image(systemName: "bolt.circle")
                        .font(.system(size: 20, weight: .regular))
                        .foregroundStyle(.secondary)
                    Text("等待任务开始")
                        .font(.system(size: WorkspaceTypography.titleSize, weight: .semibold))
                    Text("发送任务后，这里会显示真实模型输出、工具调用与审批记录。")
                        .font(.system(size: WorkspaceTypography.metaSize))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 30)
                .appPanel()
            }
        }
    }
}

private struct ConversationTimelineRow: View {
    let entry: ConversationEntry

    var body: some View {
        switch entry.kind {
        case .user:
            HStack(alignment: .top, spacing: 10) {
                Spacer(minLength: 52)
                VStack(alignment: .leading, spacing: 7) {
                    Text(entry.text)
                        .font(.system(size: WorkspaceTypography.bodySize))
                        .foregroundStyle(.primary)
                        .textSelection(.enabled)
                    if !entry.attachments.isEmpty {
                        HStack(spacing: 5) {
                            ForEach(entry.attachments) { attachment in
                                Label(attachment.filename, systemImage: attachment.kind == .image ? "photo" : "doc")
                                    .font(.system(size: WorkspaceTypography.microSize, weight: .medium))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .padding(.horizontal, 7)
                                    .frame(height: 22)
                                    .background(Color.primary.opacity(0.06), in: Capsule())
                            }
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(Color.accentColor.opacity(0.075), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Color.accentColor.opacity(0.18), lineWidth: 1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        case .assistant:
            HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "sparkles")
                    .font(.system(size: WorkspaceTypography.metaSize, weight: .semibold))
                    .frame(width: 24, height: 24)
                    .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 7) {
                    HStack(spacing: 6) {
                        Text(entry.title.isEmpty ? "DeepSeek" : entry.title)
                            .font(.system(size: WorkspaceTypography.metaSize, weight: .semibold, design: .rounded))
                            .foregroundStyle(.secondary)
                        if entry.state == .running {
                            ProgressView()
                                .controlSize(.mini)
                        }
                    }
                    Text(try! AttributedString(markdown: entry.text, options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
                        .font(.system(size: WorkspaceTypography.bodySize))
                        .foregroundStyle(.primary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(
                    minWidth: WorkspaceDesignTokens.conversationMessageMinWidth,
                    maxWidth: .infinity,
                    alignment: .leading
                )
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .id(entry.id + "_" + String(entry.text.count))
        case .tool, .verification:
            ConversationEventRow(entry: entry)
        case .approval:
            ConversationApprovalRow(entry: entry)
        }
    }
}

private struct ConversationEventRow: View {
    let entry: ConversationEntry
    @State private var isExpanded = false
    @State private var isHovered = false

    private var tint: Color { conversationTint(colorToken) }
    private var colorToken: String {
        switch entry.state {
        case .running: "blue"
        case .waiting: "amber"
        case .completed: "green"
        case .failed: "red"
        case .info, .idle: "secondary"
        }
    }
    private var icon: String {
        if entry.kind == .verification { return entry.state == .completed ? "checkmark.seal" : "checklist" }
        return switch entry.state {
        case .running: "wrench.and.screwdriver"
        case .completed: "checkmark"
        case .failed: "xmark"
        case .waiting: "clock"
        case .idle, .info: "circle"
        }
    }

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            Text(entry.text)
                .font(.system(size: WorkspaceTypography.metaSize, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 3)
                .padding(.leading, 32)
        } label: {
            HStack(spacing: 9) {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 20, height: 20)
                    .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                Text(entry.title)
                    .font(.system(size: WorkspaceTypography.metaSize, weight: .medium, design: entry.kind == .tool ? .monospaced : .default))
                    .lineLimit(1)
                Text(entry.text)
                    .font(.system(size: WorkspaceTypography.metaSize))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                if entry.state == .running {
                    ProgressView()
                        .controlSize(.mini)
                } else {
                    Text(eventStateTitle)
                        .font(.system(size: WorkspaceTypography.microSize, weight: .medium))
                        .foregroundStyle(tint)
                }
            }
            .contentShape(Rectangle())
        }
        .tint(tint)
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(isHovered ? AppTheme.hover : Color.clear, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .stroke(isHovered ? AppTheme.border.opacity(WorkspaceDesignTokens.hoverBorderOpacity) : Color.clear, lineWidth: 1)
        }
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovered)
    }

    private var eventStateTitle: String {
        switch entry.state {
        case .completed: "已完成"
        case .failed: "失败"
        case .waiting: "待处理"
        case .running: "运行中"
        case .idle, .info: "记录"
        }
    }
}

private struct ConversationApprovalRow: View {
    @Environment(WorkspaceStore.self) private var store
    let entry: ConversationEntry
    @State private var isHovered = false

    private var approval: PendingToolApproval? {
        guard entry.state == .waiting,
              let pending = store.pendingApproval else { return nil }
        return pending
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                Image(systemName: entry.state == .waiting ? "hand.raised.fill" : (entry.state == .completed ? "checkmark" : "xmark"))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(entry.state == .waiting ? .orange : (entry.state == .completed ? .green : .red))
                    .frame(width: 24, height: 24)
                    .background((entry.state == .waiting ? Color.orange : (entry.state == .completed ? Color.green : Color.red)).opacity(0.10), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.title)
                        .font(.system(size: 12, weight: .semibold))
                    Text(entry.text)
                        .font(.system(size: WorkspaceTypography.metaSize))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                AppBadge(title: entry.state == .waiting ? "待处理" : (entry.state == .completed ? "已允许" : "已拒绝"), tint: entry.state == .waiting ? .orange : (entry.state == .completed ? .green : .red))
            }

            if approval != nil {
                HStack(spacing: 7) {
                    Button("拒绝") { store.resolvePendingApproval(.deny) }
                        .buttonStyle(AppSecondaryButtonStyle())
                    Spacer()
                    Button("本 Session 允许") { store.resolvePendingApproval(.allowSession) }
                        .buttonStyle(AppSecondaryButtonStyle())
                    Button("允许一次") { store.resolvePendingApproval(.allowOnce) }
                        .buttonStyle(AppPrimaryButtonStyle())
                }
            } else if entry.state == .waiting {
                Text("审批正在恢复；恢复前不会执行任何副作用操作。")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .background(isHovered ? Color.orange.opacity(0.065) : Color.orange.opacity(0.04), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.orange.opacity(isHovered ? 0.32 : 0.20), lineWidth: 1)
        }
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovered)
    }
}

private struct WelcomeWorkspaceView: View {
    @Environment(WorkspaceStore.self) private var store

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .center, spacing: 12) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 25, weight: .semibold))
                        .foregroundStyle(.orange)
                    Text("今天想推进什么？")
                        .font(.system(size: 28, weight: .semibold))
                        .foregroundStyle(.primary)
                }
                Text("描述目标后，DeepSeek Code 会将任务拆成计划、修改、验证和交付。")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 38)
                    .padding(.top, 10)

                HomeActivityCard()
                    .padding(.top, 34)

                if !store.sessions.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("最近任务")
                                .font(.system(size: 12, weight: .semibold))
                            Spacer()
                            Text("\(store.sessions.count)")
                                .font(.system(size: 10, weight: .medium, design: .rounded))
                                .foregroundStyle(.tertiary)
                        }
                        ForEach(store.sessions.prefix(3)) { session in
                            HomeRecentSessionRow(session: session) {
                                store.selectedSessionID = session.id
                                store.activeSection = .sessions
                            }
                        }
                    }
                    .frame(maxWidth: WorkspaceDesignTokens.homeOverviewCardWidth, alignment: .leading)
                    .padding(.top, 24)
                }
            }
            .frame(maxWidth: WorkspaceDesignTokens.homeContentMaxWidth, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.horizontal, 40)
            .padding(.top, 72)
            .padding(.bottom, 28)
        }
        .scrollIndicators(.hidden)
        .background(AppTheme.canvas)
    }
}

private struct HomeFilterButton: View {
    let title: String
    let selected: Bool
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: selected ? .semibold : .medium))
                .foregroundStyle(selected || isHovered ? .primary : .secondary)
                .padding(.horizontal, 9)
                .frame(height: 24)
                .background(selected ? AppTheme.elevated : (isHovered ? AppTheme.hover : Color.clear), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay {
                    if selected || isHovered {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .stroke(AppTheme.border.opacity(selected ? 0.45 : WorkspaceDesignTokens.hoverBorderOpacity), lineWidth: 1)
                    }
                }
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovered)
    }
}

private struct HomeMetricCard: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text(value)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    }
}

private struct HomeActivityCard: View {
    @Environment(WorkspaceStore.self) private var store
    @State private var selectedSection: HomeOverviewSection = .overview
    @State private var selectedRange: HomeActivityRange = .all

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                HStack(spacing: 16) {
                    HomeFilterButton(title: HomeOverviewSection.overview.title, selected: selectedSection == .overview) {
                        selectedSection = .overview
                    }
                    HomeFilterButton(title: HomeOverviewSection.models.title, selected: selectedSection == .models) {
                        selectedSection = .models
                    }
                }
                Spacer()
                HStack(spacing: 3) {
                    ForEach(HomeActivityRange.allCases) { range in
                        HomeFilterButton(title: range.title, selected: selectedRange == range) {
                            selectedRange = range
                        }
                    }
                }
            }
            if selectedSection == .overview {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 4), spacing: 6) {
                    HomeMetricCard(title: "Tasks", value: "\(store.sessions.count)")
                    HomeMetricCard(title: "Running", value: "\(store.sessions.filter { $0.status == .running }.count)")
                    HomeMetricCard(title: "Needs review", value: "\(store.sessions.filter { $0.status == .needsReview }.count)")
                    HomeMetricCard(title: "Completed", value: "\(store.sessions.filter { $0.status == .completed }.count)")
                }
                HomeActivityGrid()
                Text(HomeCopy.activityHint(hasSessions: !store.sessions.isEmpty, range: selectedRange))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            } else {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 2), spacing: 6) {
                    HomeMetricCard(title: "Runtime", value: "\(store.providerName) · \(store.providerModel)")
                    HomeMetricCard(title: "Connection", value: store.providerStatus.isEmpty ? "Ready" : store.providerStatus)
                    HomeMetricCard(title: "Estimated cost", value: String(format: "¥%.4f", store.usageSummary.estimatedCost))
                    HomeMetricCard(title: "Target", value: store.executionTarget.title)
                }
                Text(HomeCopy.modelHint(range: selectedRange))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(maxWidth: WorkspaceDesignTokens.homeOverviewCardWidth, alignment: .leading)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(AppTheme.border.opacity(0.55), lineWidth: 1)
        }
    }
}

private struct HomeRecentSessionRow: View {
    let session: Session
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                AppStatusDot(color: statusColor)
                Text(session.title)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Text(session.status.title)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background(isHovered ? AppTheme.hover : Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovered)
    }

    private var statusColor: Color {
        switch session.status {
        case .created, .planning, .verifying, .awaitingPlanApproval: .blue
        case .executing: .mint
        case .running: .mint
        case .awaitingToolApproval, .awaitingApproval, .needsReview, .handoffReady, .awaitingDeliveryApproval: .orange
        case .delivering: .purple
        case .needsRepair: .red
        case .needsAttention, .failed: .red
        case .delivered, .completed: .green
        case .waiting: .secondary
        }
    }
}

private struct HomeActivityGrid: View {
    private let activeCells: Set<Int> = [21, 22, 23, 45, 46, 47, 69, 92, 93, 116, 117, 118, 141, 142]

    var body: some View {
        LazyVGrid(
            columns: Array(
                repeating: GridItem(.fixed(CGFloat(WorkspaceDesignTokens.homeHeatmapCellSize)), spacing: CGFloat(WorkspaceDesignTokens.homeHeatmapGap)),
                count: 24
            ),
            spacing: CGFloat(WorkspaceDesignTokens.homeHeatmapGap)
        ) {
            ForEach(0..<144, id: \.self) { index in
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(activeCells.contains(index) ? Color.accentColor.opacity(activeOpacity(for: index)) : Color.primary.opacity(0.055))
                    .frame(width: CGFloat(WorkspaceDesignTokens.homeHeatmapCellSize), height: CGFloat(WorkspaceDesignTokens.homeHeatmapCellSize))
            }
        }
        .padding(.vertical, 2)
        .accessibilityHidden(true)
    }

    private func activeOpacity(for index: Int) -> Double {
        0.42 + Double(index % 4) * 0.12
    }
}

private struct HomeComposerDock: View {
    @Environment(WorkspaceStore.self) private var store

    var body: some View {
        @Bindable var store = store

        ComposerView(prompt: $store.prompt, mode: $store.mode, showsTopDivider: false, isHome: true) {
            store.sendTask()
        }
        .frame(maxWidth: WorkspaceDesignTokens.homeComposerMaxWidth)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, CGFloat(WorkspaceDesignTokens.homeDockHorizontalPadding))
        .padding(.bottom, 4)
        .padding(.top, 2)
        .background(AppTheme.canvas)
    }
}

private struct ComposerView: View {
    @Environment(WorkspaceStore.self) private var store
    @Binding var prompt: String
    @Binding var mode: AgentMode
    var showsTopDivider = true
    var isHome = false
    let send: () -> Void
    @State private var isModeMenuHovered = false
    @State private var isSendHovered = false

    var body: some View {
        VStack(spacing: 0) {
            if showsTopDivider {
                Divider()
            }
            VStack(alignment: .leading, spacing: 4) {
                if ConversationChromeCopy.showsContextRow(isHome: isHome) {
                    HStack(spacing: 4) {
                        Menu {
                            Button("Local", systemImage: "laptopcomputer") {
                                store.executionTarget = .local
                                store.statusMessage = "执行目标：Local"
                            }
                            Button("Worktree", systemImage: "square.stack.3d.up") {
                                store.executionTarget = .worktree
                                store.statusMessage = "执行目标：Worktree（下一次 Session 将隔离）"
                            }
                        } label: {
                            ComposerChipLabel(title: store.executionTarget.title, systemImage: store.executionTarget == .worktree ? "square.stack.3d.up" : "laptopcomputer")
                        }
                        .menuStyle(.borderlessButton)
                        if !store.projectPath.isEmpty || isHome {
                            Button { store.isProjectPickerPresented = true } label: {
                                ComposerChipLabel(title: store.projectPath.isEmpty ? "快速对话" : store.projectName, systemImage: store.projectPath.isEmpty ? "bubble.left" : "folder")
                            }
                            .buttonStyle(.plain)
                        }
                        if !store.selectedSession.branch.isEmpty {
                            Button { store.statusMessage = "当前分支：\(store.selectedSession.branch)" } label: {
                                ComposerChipLabel(title: store.selectedSession.branch, systemImage: "arrow.triangle.branch")
                            }
                            .buttonStyle(.plain)
                        }
                        Spacer()
                        Text("¥\(store.usageSummary.estimatedCost, specifier: "%.4f")")
                            .font(.system(size: WorkspaceTypography.microSize, design: .monospaced))
                            .foregroundStyle(.tertiary)
                    }
                    .frame(height: 22)
                }

                ZStack(alignment: .topLeading) {
                    ComposerTextEditor(text: $prompt, onSubmit: send)
                        .frame(
                            minHeight: CGFloat(isHome ? WorkspaceDesignTokens.homeComposerInputMinHeight : WorkspaceDesignTokens.conversationComposerInputMinHeight),
                            maxHeight: CGFloat(isHome ? WorkspaceDesignTokens.homeComposerInputMaxHeight : WorkspaceDesignTokens.conversationComposerInputMaxHeight)
                        )
                    if prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text(isHome ? "描述任务，或向 DeepSeek 提问…" : "继续描述下一步…")
                            .font(.system(size: WorkspaceTypography.bodySize))
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 13)
                            .padding(.top, 15)
                            .allowsHitTesting(false)
                    }
                }
                .onDrop(of: [UTType.fileURL.identifier, UTType.image.identifier], isTargeted: nil) { providers in
                    for provider in providers {
                        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                            let url: URL?
                            if let itemURL = item as? URL {
                                url = itemURL
                            } else if let data = item as? Data {
                                url = URL(dataRepresentation: data, relativeTo: nil)
                            } else {
                                url = nil
                            }
                            if let url {
                                Task { @MainActor in store.addAttachment(at: url) }
                            }
                        }
                    }
                    return true
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 3)
                .background(AppTheme.elevated, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(AppTheme.border.opacity(0.7), lineWidth: 1)
                }
                HStack(spacing: 8) {
                    Button {
                        store.isAttachmentPickerPresented = true
                    } label: {
                        Image(systemName: "paperclip")
                            .font(.system(size: 12, weight: .semibold))
                            .frame(width: 26, height: 26)
                    }
                    .buttonStyle(AppIconButtonStyle())
                    .help("添加图片、PDF 或文件")
                    if !store.composerAttachments.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 5) {
                                ForEach(store.composerAttachments) { attachment in
                                    HStack(spacing: 4) {
                                        Image(systemName: attachment.kind == .image ? "photo" : "doc")
                                            .font(.system(size: 10, weight: .semibold))
                                        Text(attachment.filename)
                                            .lineLimit(1)
                                        Button {
                                            store.removeAttachment(id: attachment.id)
                                        } label: {
                                            Image(systemName: "xmark")
                                                .font(.system(size: WorkspaceTypography.microSize, weight: .bold))
                                        }
                                        .buttonStyle(.plain)
                                    }
                                    .font(.system(size: WorkspaceTypography.microSize, weight: .medium))
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 7)
                                    .frame(height: WorkspaceDesignTokens.composerChipHeight)
                                    .background(Color.primary.opacity(0.06), in: Capsule())
                                }
                            }
                        }
                        .frame(maxWidth: 300)
                    }
                    if !store.attachmentStatusMessage.isEmpty {
                        Text(store.attachmentStatusMessage)
                            .font(.system(size: WorkspaceTypography.microSize))
                            .foregroundStyle(.secondary)
                        .lineLimit(1)
                    }
                    // Agent mode is exposed once, in the dock toolbar, rather than
                    // duplicated above the editor on the home screen.
                    Menu {
                        ForEach(AgentMode.allCases) { item in
                            Button(item.title) { mode = item }
                        }
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "slider.horizontal.3")
                            Text(mode.title)
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.system(size: WorkspaceTypography.microSize, weight: .semibold))
                        }
                        .font(.system(size: WorkspaceTypography.metaSize, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .frame(height: CGFloat(WorkspaceDesignTokens.composerActionHeight))
                        .background(Color.primary.opacity(isModeMenuHovered ? WorkspaceDesignTokens.menuHoverOpacity : 0.05), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .stroke(isModeMenuHovered ? AppTheme.border.opacity(WorkspaceDesignTokens.hoverBorderOpacity) : Color.clear, lineWidth: 1)
                        }
                        .onHover { isModeMenuHovered = $0 }
                        .animation(.easeOut(duration: 0.12), value: isModeMenuHovered)
                    }
                    .menuStyle(.borderlessButton)
                    Button { store.isSettingsPresented = true } label: {
                        InteractiveBadgeLabel(title: store.providerModel, systemImage: "cpu")
                    }
                    .buttonStyle(.plain)
                    Label("权限受控", systemImage: "checkmark.shield")
                        .font(.system(size: WorkspaceTypography.microSize, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 7)
                        .frame(height: CGFloat(WorkspaceDesignTokens.composerActionHeight))
                        .background(Color.primary.opacity(0.04), in: Capsule(style: .continuous))
                        .help("低风险工作区操作可自动执行；联网、写入与交付会按策略请求审批")
                    Spacer(minLength: 4)
                    Text("↩ 发送 · ⇧↩ 换行")
                        .font(.system(size: WorkspaceTypography.microSize, weight: .medium, design: .monospaced))
                        .foregroundStyle(.tertiary)
                    Button(action: send) {
                        Image(systemName: "arrow.up")
                            .font(.system(size: WorkspaceTypography.labelSize, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 28, height: 28)
                            .background(
                                prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                    ? Color.secondary.opacity(0.35)
                                    : Color.accentColor.opacity(isSendHovered ? 0.84 : 1),
                                in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                            )
                    }
                    .buttonStyle(.plain)
                    .onHover { isSendHovered = $0 }
                    .animation(.easeOut(duration: 0.12), value: isSendHovered)
                    .disabled(prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && store.composerAttachments.isEmpty)
                    .help("回车发送；Shift+回车换行")
                }
                .frame(height: WorkspaceDesignTokens.composerActionHeight)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 2)
            .background(AppTheme.canvas)
        }
    }
}

private struct ComposerTextEditor: NSViewRepresentable {
    @Binding var text: String
    let onSubmit: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true

        let textView = ComposerNSTextView()
        textView.delegate = context.coordinator
        textView.onSubmit = onSubmit
        textView.string = text
        textView.font = .systemFont(ofSize: 13)
        textView.textColor = .labelColor
        textView.backgroundColor = .clear
        textView.drawsBackground = false
        textView.isEditable = true
        textView.isSelectable = true
        textView.isRichText = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainerInset = NSSize(width: 7, height: 6)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)

        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? ComposerNSTextView else { return }
        textView.onSubmit = onSubmit
        if textView.string != text {
            textView.string = text
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        private var parent: ComposerTextEditor

        init(_ parent: ComposerTextEditor) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            if parent.text != textView.string {
                parent.text = textView.string
            }
        }
    }
}

private final class ComposerNSTextView: NSTextView {
    var onSubmit: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        let isReturn = event.keyCode == 36 || event.keyCode == 76
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let action = ComposerKeyHandling.action(
            isReturn: isReturn,
            hasMarkedText: hasMarkedText(),
            hasShift: flags.contains(.shift)
        )
        switch action {
        case .submit:
            onSubmit?()
        case .insertNewline, .deferToTextView:
            super.keyDown(with: event)
        }
    }
}

private struct ComposerChipLabel: View {
    let title: String
    var systemImage: String
    var isMuted: Bool = true
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: systemImage)
                .font(.system(size: WorkspaceTypography.microSize, weight: .semibold))
            Text(title)
                .font(.system(size: WorkspaceTypography.microSize, weight: .medium))
                .lineLimit(1)
        }
        .foregroundStyle(isMuted ? .secondary : .primary)
        .padding(.horizontal, 8)
        .frame(height: CGFloat(WorkspaceDesignTokens.composerChipHeight))
        .background(isHovered ? AppTheme.hover : (isMuted ? Color.primary.opacity(0.04) : Color.primary.opacity(0.06)), in: Capsule(style: .continuous))
        .overlay {
            Capsule(style: .continuous)
                .stroke(isHovered ? AppTheme.border.opacity(WorkspaceDesignTokens.hoverBorderOpacity) : (isMuted ? AppTheme.border.opacity(0.45) : AppTheme.border.opacity(0.65)), lineWidth: 1)
        }
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovered)
    }
}

private struct RightPanelView: View {
    @Environment(WorkspaceStore.self) private var store

    var body: some View {
        @Bindable var store = store

        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text("Inspector")
                    .font(.system(size: WorkspaceTypography.labelSize, weight: .semibold))
                    .foregroundStyle(.primary)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 2) {
                        ForEach(WorkspaceStore.RightPanel.allCases) { panel in
                            InspectorTabButton(panel: panel, selected: store.selectedRightPanel == panel) {
                                store.selectedRightPanel = panel
                            }
                        }
                    }
                    .padding(2)
                }
                Spacer()
            }
            .frame(height: WorkspaceDesignTokens.inspectorHeaderHeight)
            .padding(.horizontal, WorkspaceDesignTokens.inspectorContentPadding)
            .background(AppTheme.canvas)
            Group {
                switch store.selectedRightPanel {
                case .changes: ChangesPanel()
                case .files: FilesPanel()
                case .browser: BrowserPanel()
                case .review: ReviewPanel()
                case .terminal: TerminalView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .background(AppTheme.canvas)
    }
}

private struct WorkspacePanelHeader<Accessory: View, Detail: View>: View {
    let icon: String
    let eyebrow: String
    let title: String
    let subtitle: String
    @ViewBuilder let accessory: () -> Accessory
    @ViewBuilder let detail: () -> Detail

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 9) {
                Image(systemName: icon)
                    .font(.system(size: WorkspaceTypography.metaSize, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
                VStack(alignment: .leading, spacing: 3) {
                    Text(eyebrow)
                        .font(.system(size: WorkspaceTypography.microSize, weight: .medium))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                    Text(title)
                        .font(.system(size: WorkspaceTypography.titleSize, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.system(size: WorkspaceTypography.metaSize))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                Spacer(minLength: 10)
                accessory()
            }
            detail()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(AppTheme.canvas)
    }
}

private extension WorkspaceStore.RightPanel {
    var workspaceInspectorContent: WorkspaceInspectorContent {
        switch self {
        case .changes: .changes
        case .files: .files
        case .browser: .browser
        case .review: .review
        case .terminal: .terminal
        }
    }
}

private extension GitFileStatus {
    var label: String {
        switch self {
        case .untracked: "Untracked"
        case .modified: "Modified"
        case .staged: "Staged"
        case .deleted: "Deleted"
        case .renamed: "Renamed"
        case .conflict: "Conflict"
        }
    }
}

private struct InspectorTabButton: View {
    let panel: WorkspaceStore.RightPanel
    let selected: Bool
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: WorkspaceTypography.microSize, weight: .medium))
                Text(panel.title)
                    .font(.system(size: WorkspaceTypography.metaSize, weight: selected ? .semibold : .medium))
            }
            .foregroundStyle(selected ? .primary : .secondary)
            .padding(.horizontal, 9)
            .frame(height: WorkspaceDesignTokens.inspectorTabHeight - 4)
            .background(selected ? AppTheme.elevated : (isHovered ? AppTheme.hover : Color.clear), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay {
                if selected || isHovered {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(AppTheme.border.opacity(selected ? 0.75 : WorkspaceDesignTokens.hoverBorderOpacity), lineWidth: 1)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovered)
        .help(panel.title)
        .accessibilityLabel(panel.title)
    }

    private var icon: String {
        switch panel {
        case .changes: "arrow.triangle.branch"
        case .files: "folder"
        case .browser: "globe"
        case .review: "checkmark.shield"
        case .terminal: "terminal"
        }
    }
}

private struct AgentWorkersPanel: View {
    @Environment(WorkspaceStore.self) private var store

    var body: some View {
        @Bindable var store = store
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Agents")
                        .font(.system(size: 22, weight: .semibold))
                    Text("后台运行、审批、暂停与恢复都在这里集中管理")
                        .font(.system(size: WorkspaceTypography.bodySize))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("返回工作区") { store.activeSection = .projects }
                    .buttonStyle(AppSecondaryButtonStyle())
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 18)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if store.agentWorkers.isEmpty {
                        InspectorCard {
                            Label("当前没有后台 Agent", systemImage: "sparkles")
                                .foregroundStyle(.secondary)
                            Text("发送一条任务后，这里会显示主 Agent 的实时状态和检查点。")
                                .font(.system(size: WorkspaceTypography.bodySize))
                                .foregroundStyle(.tertiary)
                        }
                    } else {
                        ForEach(store.agentWorkers) { worker in
                            AgentWorkerCard(worker: worker)
                        }
                    }
                }
                .frame(maxWidth: 820, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(24)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct AgentWorkerCard: View {
    @Environment(WorkspaceStore.self) private var store
    let worker: AgentWorkerRecord

    var body: some View {
        @Bindable var store = store
        InspectorCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 9) {
                    Image(systemName: worker.kind.systemImage)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(workerTint)
                        .frame(width: 24, height: 24)
                        .background(workerTint.opacity(0.12), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(worker.title)
                            .font(.system(size: 13, weight: .semibold))
                        Text(worker.prompt.isEmpty ? "无任务描述" : worker.prompt)
                            .font(.system(size: WorkspaceTypography.metaSize))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    Spacer()
                    AppBadge(title: worker.state.title, systemImage: worker.state == .running ? "waveform.path.ecg" : "circle.fill", tint: workerTint)
                }
                HStack(spacing: 7) {
                    Text(worker.detail)
                        .font(.system(size: WorkspaceTypography.metaSize))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    if let checkpoint = worker.checkpoint {
                        Text("· \(checkpoint.title)")
                            .font(.system(size: WorkspaceTypography.microSize, design: .monospaced))
                            .foregroundStyle(.tertiary)
                    }
                    Spacer()
                    Button("Peek") { store.selectedSessionID = worker.sessionID; store.activeSection = .sessions; store.refreshSelectedSession() }
                        .buttonStyle(AppTextButtonStyle())
                    Button("Fork") { store.forkAgent(workerID: worker.id) }
                        .buttonStyle(AppTextButtonStyle())
                }
                if worker.state == .needsInput || worker.state == .paused || worker.state == .needsAttention {
                    HStack(spacing: 7) {
                        TextField("回复这个 Agent…", text: $store.agentReplyDraft)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: WorkspaceTypography.metaSize))
                        Button("Reply") { store.replyToAgent(workerID: worker.id) }
                            .buttonStyle(AppSecondaryButtonStyle())
                    }
                }
                HStack(spacing: 6) {
                    if worker.state == .running || worker.state == .pausing {
                        Button("Pause") { store.pauseAgent(workerID: worker.id) }
                            .buttonStyle(AppSecondaryButtonStyle())
                        Button("Stop") { store.stopAgent(workerID: worker.id) }
                            .buttonStyle(AppTextButtonStyle())
                    } else if worker.state == .paused || worker.state == .needsAttention {
                        Button("Resume") { store.resumeAgent(workerID: worker.id) }
                            .buttonStyle(AppSecondaryButtonStyle())
                        Button("Stop") { store.stopAgent(workerID: worker.id) }
                            .buttonStyle(AppTextButtonStyle())
                    }
                    Spacer()
                    Text(worker.sessionID.prefix(8))
                        .font(.system(size: WorkspaceTypography.microSize, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    private var workerTint: Color {
        conversationTint(worker.state.colorToken)
    }
}

private struct ExtensionPanel: View {
    @Environment(WorkspaceStore.self) private var store
    let section: WorkspaceStore.WorkspaceSection

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text(section.title)
                        .font(.system(size: 22, weight: .semibold))
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("返回工作区") { store.activeSection = .projects }
                    .buttonStyle(AppSecondaryButtonStyle())
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 18)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    switch section {
                    case .agents:
                        EmptyView()
                    case .scheduled:
                        ExtensionCard(title: "Scheduled Tasks", subtitle: "本地后台任务、预算和审批中断", systemImage: "clock.arrow.circlepath") {
                            if store.scheduledTasks.isEmpty {
                                Label("还没有定时任务", systemImage: "clock")
                            } else {
                                ForEach(store.scheduledTasks) { task in
                                    Button {
                                        store.toggleScheduledTask(id: task.id)
                                    } label: {
                                        HStack {
                                            Label(task.prompt, systemImage: task.enabled ? "play.circle" : "pause.circle")
                                            Spacer()
                                            Text(task.schedule)
                                                .font(.system(size: 10, design: .monospaced))
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            Label("默认在独立 Worktree 运行；L2/L3 自动 Needs attention", systemImage: "exclamationmark.shield")
                            Divider()
                            Text("运行收件箱")
                                .font(.system(size: 11, weight: .semibold))
                            if store.scheduledRuns.isEmpty {
                                Text("还没有运行记录")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                            } else {
                                ForEach(store.scheduledRuns.prefix(12)) { run in
                                    HStack(spacing: 7) {
                                        AppStatusDot(color: scheduledRunColor(run.status))
                                        Text(run.taskID)
                                            .font(.system(size: 10, design: .monospaced))
                                        Spacer()
                                        Text(scheduledRunTitle(run.status))
                                            .font(.system(size: 10, weight: .medium))
                                            .foregroundStyle(run.status == .needsAttention ? .orange : .secondary)
                                    }
                                }
                            }
                            Button("新建定时任务") { store.createScheduledTask() }
                                .buttonStyle(AppSecondaryButtonStyle())
                        }
                    case .skills:
                        ExtensionCard(title: "Skills", subtitle: "项目级与用户级标准工作流", systemImage: "sparkles") {
                            if store.discoveredSkills.isEmpty {
                                Label("当前项目没有已发现的 Skill", systemImage: "sparkles")
                            } else {
                                ForEach(store.discoveredSkills) { skill in
                                    Label(skill.name, systemImage: skill.enabled ? "checkmark.circle" : "pause.circle")
                                }
                            }
                            Label("规则只进入上下文，不能覆盖权限策略", systemImage: "lock.shield")
                            Button("扫描项目 Skills") { store.statusMessage = "已扫描项目 Skills（仅信任后可执行）" }
                                .buttonStyle(AppSecondaryButtonStyle())
                            Divider()
                            Text("Plugins")
                                .font(.system(size: 11, weight: .semibold))
                            if store.plugins.isEmpty {
                                Text("还没有本地 Plugin；Plugin 不会自动执行，启用后仍经过 ToolRegistry 和权限审批")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                            } else {
                                ForEach(store.plugins) { plugin in
                                    HStack(spacing: 8) {
                                        Image(systemName: plugin.state == .enabled ? "puzzlepiece.fill" : "puzzlepiece")
                                            .foregroundStyle(plugin.state == .enabled ? .green : .secondary)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(plugin.manifest.name)
                                                .font(.system(size: 11, weight: .medium))
                                            Text("v\(plugin.manifest.version) · \(plugin.state.title)")
                                                .font(.system(size: 10))
                                                .foregroundStyle(.secondary)
                                        }
                                        Spacer()
                                        Button(plugin.state == .enabled ? "停用" : "启用") { store.togglePlugin(id: plugin.id) }
                                            .buttonStyle(AppTextButtonStyle())
                                    }
                                }
                            }
                            Label("安装来源、内容哈希和声明权限会持久化；Hook/MCP 仍需各自信任", systemImage: "lock.shield")
                                .font(.system(size: 10))
                        }
                    case .mcp:
                        ExtensionCard(title: "MCP Servers", subtitle: "受信任的外部工具服务器", systemImage: "wrench.and.screwdriver") {
                            if store.mcpServers.isEmpty {
                                Label("还没有 MCP Server", systemImage: "externaldrive")
                            } else {
                                ForEach(store.mcpServers) { server in
                                    Button {
                                        store.toggleMCPServer(id: server.id)
                                    } label: {
                                        HStack {
                                            Label(server.name, systemImage: server.enabled ? "checkmark.circle" : "pause.circle")
                                            Spacer()
                                            Text(server.trusted ? "Trusted" : "Needs trust")
                                                .font(.system(size: 10))
                                                .foregroundStyle(server.trusted ? .green : .orange)
                                        }
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            Label("支持 stdio 与 Streamable HTTP；逐工具审计", systemImage: "lock.shield")
                            Button("添加 MCP Server") { store.statusMessage = "MCP 配置会保存到本机扩展库" }
                                .buttonStyle(AppSecondaryButtonStyle())
                        }
                    case .network:
                        NetworkExtensionCard()
                    case .usage:
                        ExtensionCard(title: "Usage", subtitle: "按 Session 与功能记录 Token、缓存、费用与模型延迟", systemImage: "chart.bar.xaxis") {
                            Grid(alignment: .leading, horizontalSpacing: 28, verticalSpacing: 10) {
                                GridRow { Text("输入 Token"); Text("\(store.usageSummary.inputTokens)").font(.system(size: 12, design: .monospaced)) }
                                GridRow { Text("缓存 Token"); Text("\(store.usageSummary.cachedInputTokens)").font(.system(size: 12, design: .monospaced)) }
                                GridRow { Text("输出 Token"); Text("\(store.usageSummary.outputTokens)").font(.system(size: 12, design: .monospaced)) }
                                GridRow { Text("估算费用"); Text("¥\(store.usageSummary.estimatedCost, specifier: "%.6f")").font(.system(size: 12, design: .monospaced)) }
                            }
                            .font(.system(size: 12))
                            if !store.usageLedger.allRecords.isEmpty {
                                Divider()
                                Text("本次 Session")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(.primary)
                                ForEach(UsageFeature.allCases) { feature in
                                    let records = store.usageLedger.records(for: feature)
                                    if !records.isEmpty {
                                        let averageLatency = records.reduce(0) { $0 + $1.latencyMilliseconds } / records.count
                                        HStack(spacing: 8) {
                                            Text(feature.title)
                                                .frame(maxWidth: .infinity, alignment: .leading)
                                            Text("\(records.reduce(0) { $0 + $1.outputTokens }) out")
                                                .font(.system(size: 10, design: .monospaced))
                                                .foregroundStyle(.secondary)
                                            Text("\(averageLatency) ms")
                                                .font(.system(size: 10, design: .monospaced))
                                                .foregroundStyle(.secondary)
                                            Text("¥\(records.reduce(0.0) { $0 + $1.estimatedCost }, specifier: "%.4f")")
                                                .font(.system(size: 10, design: .monospaced))
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                }
                            }
                        }
                    case .projects, .sessions:
                        EmptyView()
                    }
                }
                .frame(maxWidth: 760, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(24)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(AppTheme.canvas)
    }

    private var subtitle: String {
        switch section {
        case .agents: "后台 Agent、检查点、审批和恢复"
        case .scheduled: "本地后台任务、预算和审批中断"
        case .skills: "用户级和项目级标准工作流"
        case .mcp: "受信任的外部工具服务器"
        case .network: "域名授权、联网请求、预算和失败证据"
        case .usage: "按 Session 与功能记录 Token、缓存和费用"
        case .projects, .sessions: ""
        }
    }

    private func scheduledRunTitle(_ status: ScheduledRunRecord.Status) -> String {
        switch status {
        case .queued: "排队"
        case .running: "运行中"
        case .needsAttention: "需要关注"
        case .completed: "完成"
        case .failed: "失败"
        case .cancelled: "已取消"
        }
    }

    private func scheduledRunColor(_ status: ScheduledRunRecord.Status) -> Color {
        switch status {
        case .queued: .secondary
        case .running: .blue
        case .needsAttention: .orange
        case .completed: .green
        case .failed: .red
        case .cancelled: .secondary
        }
    }
}

private struct NetworkExtensionCard: View {
    @Environment(WorkspaceStore.self) private var store
    @State private var domain = ""
    @State private var capability: NetworkScope = .webFetch
    @State private var operation: NetworkOperation = .read
    @State private var grantScope: NetworkGrantScope = .session
    @State private var sshID = ""
    @State private var sshHost = ""
    @State private var sshUser = ""
    @State private var sshPort = "22"
    @State private var sshFingerprint = ""
    @State private var sshRemotePath = "~/.local/share/deepseek-code/host/current/DeepSeekCodeToolHost"
    @State private var searchID = ""
    @State private var searchName = ""
    @State private var searchEndpoint = ""
    @State private var searchQueryParameter = "q"
    @State private var searchAuthReference = ""

    var body: some View {
        ExtensionCard(title: "Network Access", subtitle: "所有外部请求统一经过权限、预算和审计", systemImage: "network") {
            HStack(spacing: 8) {
                AppStatusDot(color: .green)
                Text(store.networkStatusMessage)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("刷新") { store.refreshNetworkState() }
                    .buttonStyle(AppTextButtonStyle())
            }

            VStack(alignment: .leading, spacing: 7) {
                Text("添加域名授权")
                    .font(.system(size: 11, weight: .semibold))
                HStack(spacing: 6) {
                    TextField("docs.example.com", text: $domain)
                        .textFieldStyle(.roundedBorder)
                        .frame(minWidth: 180)
                    Picker("能力", selection: $capability) {
                        ForEach([NetworkScope.webSearch, .webFetch, .browser, .mcp, .github, .ssh], id: \.self) { value in
                            Text(networkScopeTitle(value)).tag(value)
                        }
                    }
                    .frame(width: 120)
                    Picker("范围", selection: $grantScope) {
                        ForEach(NetworkGrantScope.allCases, id: \.self) { value in
                            Text(networkGrantScopeTitle(value)).tag(value)
                        }
                    }
                    .frame(width: 110)
                    Picker("操作", selection: $operation) {
                        Text("读取").tag(NetworkOperation.read)
                        Text("写入").tag(NetworkOperation.write)
                        Text("交付").tag(NetworkOperation.delivery)
                    }
                    .frame(width: 90)
                    Button("允许") {
                        store.grantNetworkDomain(domain, capability: capability, operation: operation, scope: grantScope)
                        domain = ""
                    }
                    .buttonStyle(AppSecondaryButtonStyle())
                }
            }

            if store.networkGrants.isEmpty {
                Label("暂无持久化域名授权；首次外部访问会显示审批卡片", systemImage: "checkmark.shield")
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 5) {
                    Text("已授权域名")
                        .font(.system(size: 11, weight: .semibold))
                    ForEach(store.networkGrants) { grant in
                        HStack(spacing: 7) {
                            Image(systemName: "checkmark.shield")
                                .foregroundStyle(.green)
                            Text(grant.domain)
                                .font(.system(size: 11, design: .monospaced))
                            Text("· \(networkScopeTitle(grant.capability)) · \(networkGrantScopeTitle(grant.scope))")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button { store.revokeNetworkGrant(id: grant.id) } label: {
                                Image(systemName: "xmark.circle")
                            }
                            .buttonStyle(AppIconButtonStyle())
                            .help("撤销授权")
                        }
                    }
                }
            }

            Divider()
            Text("最近联网请求")
                .font(.system(size: 11, weight: .semibold))
            if store.networkRequests.isEmpty {
                Text("还没有联网请求记录")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(Array(store.networkRequests.suffix(8).reversed())) { request in
                    HStack(spacing: 7) {
                        AppStatusDot(color: networkRequestColor(request.state))
                        Text(request.metadata.url)
                            .font(.system(size: 10, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Text(request.state.rawValue)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Divider()
            Text("Search Providers")
                .font(.system(size: 11, weight: .semibold))
            Text("可替换搜索端点；凭据只保存为 Keychain 引用，首次联网仍经过 NetworkRuntime。")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            if store.searchProviders.isEmpty {
                Text("未配置自定义 Provider，当前使用内置公共搜索并在失败时自动回退")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(store.searchProviders) { provider in
                    HStack(spacing: 7) {
                        AppStatusDot(color: provider.enabled ? .green : .secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(provider.name)
                                .font(.system(size: 11, weight: .medium))
                            Text(provider.endpoint)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        Spacer()
                        if let health = store.searchProviderHealth[provider.id] {
                            Text(health.reachable ? "可用" : "失败")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(health.reachable ? .green : .red)
                        }
                        Button(provider.enabled ? "停用" : "启用") { store.toggleSearchProvider(id: provider.id) }
                            .buttonStyle(AppTextButtonStyle())
                        Button("测试") { store.testSearchProvider(id: provider.id) }
                            .buttonStyle(AppTextButtonStyle())
                    }
                }
            }
            HStack(spacing: 6) {
                TextField("ID", text: $searchID)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 90)
                TextField("名称", text: $searchName)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 110)
                TextField("https://search.example.com/api", text: $searchEndpoint)
                    .textFieldStyle(.roundedBorder)
                TextField("参数", text: $searchQueryParameter)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 58)
                Button("保存") {
                    let provider = SearchProviderConfiguration(
                        id: searchID,
                        name: searchName,
                        endpoint: searchEndpoint,
                        queryParameter: searchQueryParameter,
                        authorizationReference: searchAuthReference.isEmpty ? nil : searchAuthReference
                    )
                    guard provider.isValid else {
                        store.statusMessage = "Search Provider Endpoint 不安全或格式无效"
                        return
                    }
                    store.saveSearchProvider(provider)
                    searchID = ""
                    searchName = ""
                    searchEndpoint = ""
                }
                .buttonStyle(AppSecondaryButtonStyle())
            }
            TextField("Keychain 引用（可选，如 keychain://search-api）", text: $searchAuthReference)
                .textFieldStyle(.roundedBorder)

            Divider()
            Text("SSH Tool Hosts")
                .font(.system(size: 11, weight: .semibold))
            Text("模型与凭据始终留在本机；远端仅接收结构化工具请求。首次连接必须核对 Host Key 指纹。")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)

            if !store.sshHosts.isEmpty {
                ForEach(store.sshHosts) { host in
                    HStack(spacing: 7) {
                        AppStatusDot(color: sshStateColor(store.sshConnectionStatus[host.id] ?? .disconnected))
                        Text("\(host.user)@\(host.hostname):\(host.port)")
                            .font(.system(size: 11, design: .monospaced))
                        Text(sshStateTitle(store.sshConnectionStatus[host.id] ?? .disconnected))
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("连接") {
                            store.connectSSHHost(
                                id: host.id,
                                observedFingerprint: sshFingerprint.isEmpty ? (host.fingerprint ?? "") : sshFingerprint,
                                remotePath: sshRemotePath
                            )
                        }
                        .buttonStyle(AppSecondaryButtonStyle())
                        Button("安装并连接") {
                            store.installAndConnectSSHHost(
                                id: host.id,
                                observedFingerprint: sshFingerprint.isEmpty ? (host.fingerprint ?? "") : sshFingerprint
                            )
                        }
                        .buttonStyle(AppTextButtonStyle())
                    }
                }
            }

            HStack(spacing: 6) {
                TextField("ID", text: $sshID)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 90)
                TextField("Host", text: $sshHost)
                    .textFieldStyle(.roundedBorder)
                TextField("用户", text: $sshUser)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 100)
                TextField("端口", text: $sshPort)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 58)
                Button("保存 Host") {
                    guard let port = Int(sshPort), !sshID.isEmpty, !sshHost.isEmpty, !sshUser.isEmpty else {
                        store.statusMessage = "请填写 SSH ID、Host、用户和端口"
                        return
                    }
                    store.saveSSHHost(SSHHost(id: sshID, hostname: sshHost, user: sshUser, port: port, fingerprint: sshFingerprint.isEmpty ? nil : sshFingerprint))
                    sshID = ""
                    sshHost = ""
                    sshUser = ""
                }
                .buttonStyle(AppSecondaryButtonStyle())
            }
            TextField("Host Key 指纹（首次连接时输入或保存）", text: $sshFingerprint)
                .textFieldStyle(.roundedBorder)
            TextField("远程 Tool Host 路径", text: $sshRemotePath)
                .textFieldStyle(.roundedBorder)
        }
    }

    private func networkScopeTitle(_ scope: NetworkScope) -> String {
        switch scope {
        case .modelProvider: "模型"
        case .browser: "Browser"
        case .mcp: "MCP"
        case .github: "GitHub"
        case .ssh: "SSH"
        case .webSearch: "搜索"
        case .webFetch: "抓取"
        }
    }

    private func networkGrantScopeTitle(_ scope: NetworkGrantScope) -> String {
        switch scope {
        case .once: "一次"
        case .session: "本 Session"
        case .project: "本项目"
        case .user: "全局"
        }
    }

    private func networkRequestColor(_ state: NetworkRequestState) -> Color {
        switch state {
        case .completed: .green
        case .failed: .red
        case .indeterminate: .orange
        case .requested, .approved, .started: .blue
        }
    }

    private func sshStateTitle(_ state: SSHConnectionState) -> String {
        switch state {
        case .connected: "已连接"
        case .disconnected: "未连接"
        case .fingerprintChanged: "指纹已变化"
        case .needsAttention: "需要关注"
        }
    }

    private func sshStateColor(_ state: SSHConnectionState) -> Color {
        switch state {
        case .connected: .green
        case .disconnected: .secondary
        case .fingerprintChanged: .red
        case .needsAttention: .orange
        }
    }
}

private struct ExtensionCard<Content: View>: View {
    let title: String
    let subtitle: String
    let systemImage: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
                    .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            VStack(alignment: .leading, spacing: 9) {
                content
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .appPanel(padding: 14)
    }
}

private struct ChangesPanel: View {
    @Environment(WorkspaceStore.self) private var store
    @State private var isDiffExpanded = false

    var body: some View {
        @Bindable var store = store

        ScrollView {
            VStack(alignment: .leading, spacing: WorkspaceDesignTokens.inspectorSectionGap) {
                WorkspacePanelHeader(
                    icon: "arrow.triangle.branch",
                    eyebrow: store.projectName,
                    title: "Changes",
                    subtitle: store.isScratchProject ? "快速对话 · 无代码仓库" : "Git status · Diff · Commit"
                ) {
                    HStack(spacing: 6) {
                        AppToolbarIconButton(title: "Refresh Changes", systemImage: "arrow.clockwise") {
                            store.refreshGitStatus()
                        }
                        if store.selectedSession.target == .worktree {
                            Button {
                                store.prepareHandoff()
                            } label: {
                                Label("Handoff", systemImage: "arrow.left.arrow.right")
                            }
                            .buttonStyle(AppSecondaryButtonStyle())
                            .controlSize(.small)
                            .help("预览 Worktree 到当前项目的变更")
                        }
                    }
                } detail: {
                    HStack(spacing: 6) {
                        AppBadge(title: "\(store.gitStatusEntries.count) files")
                        AppBadge(title: "\(store.gitStatusEntries.filter(\.isStaged).count) staged")
                        AppBadge(title: "\(store.gitStatusEntries.filter(\.hasUnstagedChanges).count) unstaged")
                    }
                }
                if let gate = store.deliveryGateResult {
                    VStack(alignment: .leading, spacing: 7) {
                        HStack(spacing: 7) {
                            Image(systemName: gate.passed ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                                .foregroundStyle(gate.passed ? .green : .orange)
                            Text(gate.passed ? "Delivery gate passed" : "Delivery gate needs evidence")
                                .font(.system(size: 11, weight: .semibold))
                            Spacer()
                            Button("重新检查") { store.requestDeliveryGateEvaluation() }
                                .buttonStyle(.borderless)
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(.secondary)
                        }
                        if !gate.missingRequirements.isEmpty {
                            Text("缺少：\(gate.missingRequirements.joined(separator: " · "))")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                        if !gate.failedEvidence.isEmpty || !gate.unresolvedRisks.isEmpty {
                            Text((gate.failedEvidence + gate.unresolvedRisks).joined(separator: " · "))
                                .font(.system(size: 10))
                                .foregroundStyle(.orange)
                        }
                    }
                    .padding(11)
                    .background((gate.passed ? Color.green : Color.orange).opacity(0.055), in: RoundedRectangle(cornerRadius: WorkspaceDesignTokens.inspectorCardCornerRadius, style: .continuous))
                    .overlay { RoundedRectangle(cornerRadius: WorkspaceDesignTokens.inspectorCardCornerRadius, style: .continuous).stroke((gate.passed ? Color.green : Color.orange).opacity(0.18), lineWidth: 1) }
                }
                if let delivery = store.githubDeliveries.first {
                    VStack(alignment: .leading, spacing: 7) {
                        HStack(spacing: 7) {
                            Image(systemName: delivery.ciState == "passed" ? "checkmark.circle.fill" : "arrow.triangle.2.circlepath")
                                .foregroundStyle(delivery.ciState == "passed" ? .green : .orange)
                            Text("GitHub Delivery")
                                .font(.system(size: 11, weight: .semibold))
                            if let number = delivery.pullRequestNumber { Text("PR #\(number)").font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary) }
                            Spacer()
                            Text(delivery.ciState ?? "pending")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(.secondary)
                        }
                        if let url = delivery.pullRequestURL {
                            Text(url).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1)
                        }
                        HStack(spacing: 6) {
                            Button("刷新 CI") { store.refreshPullRequestChecks() }
                                .buttonStyle(AppSecondaryButtonStyle())
                            if delivery.ciState == "failed" || store.ciFailureEvidence != nil {
                                Button("创建修复 Session") { store.createCIFixSession() }
                                    .buttonStyle(AppSecondaryButtonStyle())
                            }
                        }
                        if let failure = store.ciFailureEvidence {
                            Text("失败步骤：\(failure.failedStep)")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(.orange)
                            Text(failure.logExcerpt)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .lineLimit(6)
                                .textSelection(.enabled)
                        }
                    }
                    .padding(11)
                    .background(Color.primary.opacity(0.028), in: RoundedRectangle(cornerRadius: WorkspaceDesignTokens.inspectorCardCornerRadius, style: .continuous))
                    .overlay { RoundedRectangle(cornerRadius: WorkspaceDesignTokens.inspectorCardCornerRadius, style: .continuous).stroke(AppTheme.border.opacity(0.42), lineWidth: 1) }
                }
                if store.gitStatusEntries.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Image(systemName: "checkmark.circle")
                            .font(.system(size: 18))
                            .foregroundStyle(.secondary)
                        Text(store.isScratchProject ? "快速对话没有代码变更" : "没有文件变更")
                            .font(.system(size: 12, weight: .semibold))
                        Text(store.isScratchProject ? "选择一个项目后，这里会显示真实 Git 状态。" : "刷新后会显示当前仓库真实 Git 状态。")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .frame(minHeight: 92)
                    .background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: WorkspaceDesignTokens.inspectorCardCornerRadius, style: .continuous))
                    .overlay { RoundedRectangle(cornerRadius: WorkspaceDesignTokens.inspectorCardCornerRadius, style: .continuous).stroke(AppTheme.border.opacity(0.38), lineWidth: 1) }
                } else {
                    VStack(spacing: 0) {
                        ForEach(store.gitStatusEntries) { entry in
                            HStack(spacing: 10) {
                                Text(verbatim: String(entry.indexStatus) + String(entry.workingTreeStatus))
                                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 28, alignment: .leading)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(entry.path)
                                        .font(.system(size: 11, weight: .medium))
                                        .lineLimit(1)
                                    Text(entry.title)
                                        .font(.system(size: 10))
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if entry.hasUnstagedChanges {
                                    Button("Stage") { store.stageGitPath(entry.path) }
                                        .buttonStyle(AppSecondaryButtonStyle())
                                        .controlSize(.small)
                                }
                                if entry.isStaged {
                                    Button("Unstage") { store.unstageGitPath(entry.path) }
                                        .buttonStyle(AppSecondaryButtonStyle())
                                        .controlSize(.small)
                                }
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            if entry.id != store.gitStatusEntries.last?.id { Divider() }
                        }
                    }
                    .background(Color.primary.opacity(0.022), in: RoundedRectangle(cornerRadius: WorkspaceDesignTokens.inspectorCardCornerRadius, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: WorkspaceDesignTokens.inspectorCardCornerRadius, style: .continuous)
                            .stroke(AppTheme.border.opacity(0.42), lineWidth: 1)
                    }
                }
                if let handoff = store.handoffPreview {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            AppSectionHeader(title: "Handoff Preview", systemImage: "arrow.triangle.merge")
                            Spacer()
                            AppBadge(title: "\(handoff.conflicts.count) conflicts")
                        }
                        ForEach(handoff.files) { file in
                            HStack(spacing: 8) {
                                Circle().fill(handoffColor(file.state)).frame(width: 7, height: 7)
                                Text(file.path).font(.system(size: 11, weight: .medium)).lineLimit(1)
                                Spacer()
                                Text(file.state.rawValue)
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 3)
                        }
                        if !store.handoffStatusMessage.isEmpty {
                            Text(store.handoffStatusMessage)
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                        HStack(spacing: 6) {
                            Button("应用无冲突文件") { store.applyHandoff() }
                                .buttonStyle(AppSecondaryButtonStyle())
                                .disabled(!handoff.isClean && handoff.files.allSatisfy { $0.state == .conflict })
                            Button("放弃并保留 Worktree") { store.abortHandoff() }
                                .buttonStyle(.borderless)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(11)
                    .background(Color.primary.opacity(0.022), in: RoundedRectangle(cornerRadius: WorkspaceDesignTokens.inspectorCardCornerRadius, style: .continuous))
                    .overlay { RoundedRectangle(cornerRadius: WorkspaceDesignTokens.inspectorCardCornerRadius, style: .continuous).stroke(AppTheme.border.opacity(0.42), lineWidth: 1) }
                }
                HStack {
                    TextField("Commit message", text: $store.gitCommitMessage)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11))
                    Button("Commit") { store.commitGitChanges() }
                        .buttonStyle(AppSecondaryButtonStyle())
                        .disabled(store.isScratchProject || store.gitCommitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Button("Create PR") { store.createPullRequest() }
                        .buttonStyle(AppSecondaryButtonStyle())
                        .disabled(store.isScratchProject || store.selectedSession.branch.isEmpty || store.selectedSession.branch == "main")
                }
                .frame(minHeight: 30)
                DisclosureGroup(isExpanded: $isDiffExpanded) {
                    Text(store.gitDiffOutput.isEmpty ? "刷新后显示当前工作区 Diff。" : store.gitDiffOutput)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(store.gitDiffOutput.isEmpty ? .secondary : .primary)
                        .lineLimit(store.gitDiffOutput.isEmpty ? 2 : 12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .padding(.top, 8)
                } label: {
                    AppSectionHeader(title: "Diff", systemImage: "doc.text")
                }
                if !store.gitLogOutput.isEmpty {
                    DisclosureGroup {
                        Text(store.gitLogOutput)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                            .padding(.top, 6)
                    } label: {
                        Label("Recent Log", systemImage: "clock.arrow.circlepath")
                            .font(.system(size: 11, weight: .semibold))
                    }
                }
            }
            .padding(12)
        }
        .onAppear { store.refreshGitStatus() }
    }

    private func handoffColor(_ state: HandoffFileStateKind) -> Color {
        switch state {
        case .conflict, .externalModified: .orange
        case .incomingOnly, .cleanMerge: .green
        case .localOnly: .blue
        default: .secondary
        }
    }
}

private struct FilesPanel: View {
    @Environment(WorkspaceStore.self) private var store
    @State private var filterText = ""

    var body: some View {
        GeometryReader { proxy in
            let layout = WorkspaceLayoutMetrics.forDetailWidth(proxy.size.width, inspectorContent: .files)
            let stacked = layout.usesStackedInspector
            let treeWidth = min(420, max(220, proxy.size.width * 0.33))

            VStack(spacing: 0) {
                header
                Divider()
                if stacked {
                    VStack(spacing: 0) {
                        treePane
                            .frame(height: max(160, proxy.size.height * 0.34))
                        Divider()
                        editorPane
                    }
                } else {
                    HSplitView {
                        treePane
                            .frame(minWidth: 220, idealWidth: treeWidth, maxWidth: 460)
                        editorPane
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(AppTheme.panel)
        }
        .onAppear {
            store.refreshFiles()
            Task { await store.refreshFileTree() }
        }
    }

    private var header: some View {
        WorkspacePanelHeader(
            icon: "folder",
            eyebrow: store.projectName,
            title: "Files",
            subtitle: filterText.isEmpty ? "Tree · TextKit 2 · Save" : "\(filteredTree.count) matches"
        ) {
            AppToolbarIconButton(title: "Refresh Files", systemImage: "arrow.clockwise") {
                Task { await store.refreshFileTree() }
            }
            AppToolbarIconButton(title: "New File", systemImage: "doc.badge.plus") {
                Task { await store.createNewFile() }
            }
            AppToolbarIconButton(title: "New Folder", systemImage: "folder.badge.plus") {
                Task { await store.createNewFolder() }
            }
            AppToolbarIconButton(title: "Save File", systemImage: "square.and.arrow.down", isDisabled: store.selectedEditorTab == nil || !store.editorIsDirty) {
                Task { await store.saveSelectedFile() }
            }
        } detail: {
            HStack(spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: WorkspaceTypography.microSize, weight: .semibold))
                        .foregroundStyle(.tertiary)
                    TextField("Search files…", text: $filterText)
                        .textFieldStyle(.plain)
                        .font(.system(size: WorkspaceTypography.metaSize))
                }
                .padding(.horizontal, 8)
                .frame(height: 32)
                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .stroke(AppTheme.border.opacity(0.55), lineWidth: 1)
                }
                if !store.fileTree.isEmpty {
                    AppBadge(title: "\(filteredTree.count) shown")
                    AppBadge(title: "\(store.openEditorTabs.count) open")
                }
            }
        }
    }

    private var filteredTree: [WorkspaceFileNode] {
        WorkspaceTreeFilter.filter(nodes: store.fileTree, query: filterText)
    }

    private var treePane: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Text(store.projectName)
                    .font(.system(size: WorkspaceTypography.microSize, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                if !filterText.isEmpty {
                    Text("Filtered")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 32)
            .background(AppTheme.panel)
            Divider()
            if filteredTree.isEmpty {
                VStack(alignment: .leading, spacing: 7) {
                    Image(systemName: filterText.isEmpty ? "folder" : "magnifyingglass")
                        .font(.system(size: 16))
                        .foregroundStyle(.secondary)
                    Text(filterText.isEmpty ? "尚未加载文件" : "没有匹配文件")
                        .font(.system(size: 12, weight: .semibold))
                    Text(filterText.isEmpty ? "打开项目后会显示可展开的文件树。" : "换一个关键词，或刷新文件树。")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(14)
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(filteredTree) { node in
                            FileTreeRow(node: node) {
                                if node.isDirectory {
                                    store.toggleDirectory(path: node.path)
                                } else {
                                    Task { await store.openFile(path: node.path) }
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 8)
                }
            }
        }
        .background(AppTheme.panel)
    }

    private var editorPane: some View {
        VStack(spacing: 0) {
            if let tab = store.selectedEditorTab {
                EditorHeader(tab: tab)
                Divider()
                CodeEditorView(text: Binding(
                    get: { store.editorBuffer },
                    set: { store.editorBuffer = $0 }
                ), isEditable: !tab.isReadOnly, onSave: {
                    Task { await store.saveSelectedFile() }
                }, onClose: {
                    store.closeEditorTab(id: tab.id)
                })
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                EditorStatusBar(tab: tab)
            } else {
                VStack(alignment: .leading, spacing: 11) {
                    HStack(spacing: 9) {
                        Image(systemName: "text.cursor")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 26, height: 26)
                            .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                        VStack(alignment: .leading, spacing: 2) {
                            Text("打开一个文件")
                                .font(.system(size: 13, weight: .semibold))
                            Text("从左侧文件树选择文本文件，编辑后用 ⌘S 保存。")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                    }
                    Text("二进制和大文件会以只读方式保护打开。")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(18)
            }
        }
        .background(AppTheme.canvas)
    }
}

private struct FileTreeRow: View {
    @Environment(WorkspaceStore.self) private var store
    let node: WorkspaceFileNode
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Rectangle()
                    .fill(Color.clear)
                    .frame(width: CGFloat(node.depth) * 12)
                if node.isDirectory {
                    Image(systemName: node.isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .frame(width: 10)
                } else {
                    AppStatusDot(color: gitColor)
                        .opacity(node.gitStatus == nil ? 0 : 1)
                        .frame(width: 10)
                }
                Image(systemName: node.isDirectory ? "folder" : "doc.text")
                    .font(.system(size: WorkspaceTypography.metaSize))
                    .foregroundStyle(node.isDirectory ? .secondary : .primary)
                    .frame(width: 14)
                Text(node.name)
                    .font(.system(size: WorkspaceTypography.metaSize, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                if node.gitStatus != nil && !node.isDirectory {
                    Circle()
                        .fill(gitColor)
                        .frame(width: 5, height: 5)
                }
            }
            .padding(.horizontal, 8)
            .frame(height: WorkspaceDesignTokens.filesTreeRowHeight)
            .background(isSelected ? AppTheme.selected : (isHovered ? AppTheme.hover : Color.clear), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovered)
        .help(node.path)
    }

    private var isSelected: Bool {
        store.selectedEditorTabID == node.path
    }

    private var gitColor: Color {
        switch node.gitStatus {
        case .untracked: .orange
        case .modified: .yellow
        case .staged: .green
        case .deleted: .red
        case .renamed: .blue
        case .conflict: .purple
        case nil: .secondary
        }
    }
}

private struct EditorHeader: View {
    @Environment(WorkspaceStore.self) private var store
    let tab: WorkspaceStore.EditorTab

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(store.openEditorTabs) { item in
                        EditorTabButton(tab: item, selected: store.selectedEditorTabID == item.id) {
                            store.selectEditorTab(id: item.id)
                        }
                    }
                }
                .padding(.vertical, 4)
            }
            Divider()
            HStack(spacing: 8) {
                AppStatusDot(color: gitColor)
                    .opacity(tab.gitStatus == nil ? 0 : 1)
                Text(tab.path)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let gitStatus = tab.gitStatus {
                    AppBadge(title: gitStatus.label, tint: gitColor)
                }
                if tab.isDirty {
                    AppBadge(title: "Unsaved", tint: .orange)
                }
                if tab.isReadOnly {
                    AppBadge(title: "Read Only", systemImage: "eye", tint: .secondary)
                }
                Spacer(minLength: 8)
                AppToolbarIconButton(title: "Save File", systemImage: "square.and.arrow.down", isDisabled: !tab.isDirty || tab.isReadOnly) {
                    Task { await store.saveSelectedFile() }
                }
                AppToolbarIconButton(title: "Revert Unsaved Changes", systemImage: "arrow.uturn.backward", isDisabled: !tab.isDirty) {
                    store.revertSelectedFile()
                }
                AppToolbarIconButton(title: "Close Tab", systemImage: "xmark") {
                    store.closeEditorTab(id: tab.id)
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 34)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, WorkspaceDesignTokens.editorChromeVerticalPadding)
        .background(AppTheme.chrome)
    }

    private var gitColor: Color {
        switch tab.gitStatus {
        case .untracked: .orange
        case .modified: .yellow
        case .staged: .green
        case .deleted: .red
        case .renamed: .blue
        case .conflict: .purple
        case nil: .secondary
        }
    }
}

private struct EditorTabButton: View {
    let tab: WorkspaceStore.EditorTab
    let selected: Bool
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: tab.isReadOnly ? "lock" : "doc.text")
                    .font(.system(size: WorkspaceTypography.microSize, weight: .medium))
                    .foregroundStyle(.tertiary)
                Text(tab.title)
                    .font(.system(size: WorkspaceTypography.metaSize, weight: selected ? .semibold : .medium))
                    .lineLimit(1)
                if tab.isDirty {
                    Circle().fill(Color.orange).frame(width: 6, height: 6)
                }
            }
            .foregroundStyle(selected || isHovered ? .primary : .secondary)
            .padding(.horizontal, 10)
            .frame(height: WorkspaceDesignTokens.inspectorTabHeight)
            .background(selected ? AppTheme.elevated : (isHovered ? AppTheme.hover : Color.clear), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay {
                if selected || isHovered {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .stroke(AppTheme.border.opacity(selected ? 0.65 : WorkspaceDesignTokens.hoverBorderOpacity), lineWidth: 1)
                }
            }
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovered)
        .help(tab.path)
    }
}

private struct EditorStatusBar: View {
    @Environment(WorkspaceStore.self) private var store
    let tab: WorkspaceStore.EditorTab

    var body: some View {
        HStack(spacing: 10) {
            EditorStatusPill(title: tab.isBinary ? "Binary" : tab.encoding)
            EditorStatusPill(title: "\(tab.lineCount) lines")
            EditorStatusPill(title: byteCountLabel)
            Spacer()
            Text(store.editorStatusMessage)
                .lineLimit(1)
                .truncationMode(.middle)
            if tab.isReadOnly {
                EditorStatusPill(title: "Readonly", systemImage: "lock")
            }
        }
        .font(.system(size: WorkspaceTypography.metaSize, weight: .medium))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(AppTheme.chrome)
    }

    private var byteCountLabel: String {
        if tab.byteCount >= 1_000_000 {
            return String(format: "%.1f MB", Double(tab.byteCount) / 1_000_000)
        }
        if tab.byteCount >= 1_000 {
            return String(format: "%.1f KB", Double(tab.byteCount) / 1_000)
        }
        return "\(tab.byteCount) B"
    }
}

private struct EditorStatusPill: View {
    let title: String
    var systemImage: String?

    var body: some View {
        HStack(spacing: 4) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: WorkspaceTypography.microSize, weight: .semibold))
            }
            Text(title)
        }
        .font(.system(size: WorkspaceTypography.microSize, weight: .medium, design: .rounded))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 7)
        .frame(height: 20)
        .background(Color.primary.opacity(0.04), in: Capsule(style: .continuous))
    }
}

private struct BrowserPanel: View {
    @Environment(WorkspaceStore.self) private var store
    @Environment(BrowserController.self) private var controller

    var body: some View {
        @Bindable var store = store

        VStack(spacing: 10) {
            HStack(spacing: 7) {
                Image(systemName: "globe")
                    .font(.system(size: WorkspaceTypography.metaSize, weight: .medium))
                    .foregroundStyle(.secondary)
                TextField("http://localhost:5173", text: $store.browserURL)
                    .textFieldStyle(.plain)
                    .font(.system(size: WorkspaceTypography.metaSize, design: .monospaced))
                    .padding(.horizontal, 8)
                    .frame(height: 32)
                    .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                Spacer()
                Button("捕获验证", systemImage: "checkmark.circle") {
                    Task {
                        await controller.captureSnapshot()
                        if let bundle = controller.evidenceBundle {
                            store.recordBrowserEvidence(bundle)
                        }
                    }
                }
                .labelStyle(.iconOnly)
                .buttonStyle(AppIconButtonStyle())
                .help("读取 DOM、可访问性树、控制台和网络错误")
                Button("重新加载", systemImage: "arrow.clockwise") { controller.reload() }
                    .labelStyle(.iconOnly)
                    .buttonStyle(AppIconButtonStyle())
            }
            BrowserWebPreview(controller: controller)
                .background(Color.white, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(AppTheme.border.opacity(0.75), lineWidth: 1)
                }
                .frame(minHeight: 220, idealHeight: 360, maxHeight: .infinity)
            HStack(spacing: 6) {
                AppBadge(title: "Session isolated", systemImage: "lock.shield")
                AppBadge(title: "localhost allowed", systemImage: "checkmark.circle", tint: .green)
                if controller.isLoading {
                    AppBadge(title: "加载中", systemImage: "arrow.triangle.2.circlepath", tint: .orange)
                } else if let snapshot = controller.snapshot {
                    AppBadge(title: snapshot.hasIssues ? "\(snapshot.issueCount) 个问题" : "验证通过", systemImage: snapshot.hasIssues ? "exclamationmark.triangle" : "checkmark.circle", tint: snapshot.hasIssues ? .orange : .green)
                }
                Spacer()
            }
            if !controller.lastError.isEmpty {
                Text(controller.lastError)
                    .font(.system(size: WorkspaceTypography.metaSize))
                    .foregroundStyle(.red)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Spacer()
        }
        .padding(12)
        .onAppear {
            controller.urlString = store.browserURL
        }
        .onChange(of: store.browserURL) { _, value in
            controller.urlString = value
            controller.loadIfNeeded()
        }
    }
}

private struct BrowserWebPreview: NSViewRepresentable {
    let controller: BrowserController

    func makeNSView(context: Context) -> WKWebView {
        controller.makeWebView()
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        controller.attach(webView)
        controller.loadIfNeeded()
    }
}

private struct ReviewPanel: View {
    @Environment(WorkspaceStore.self) private var store

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Review")
                        .font(.system(size: WorkspaceTypography.labelSize, weight: .semibold))
                    Text(store.reviewUpdatedAt.map { "最近审查 \(Self.timeFormatter.string(from: $0))" } ?? "只读检查当前 Diff")
                        .font(.system(size: WorkspaceTypography.microSize))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                HStack(spacing: 5) {
                    Button {
                        Task { await store.runReview() }
                    } label: {
                        Label("本地", systemImage: "checkmark.shield")
                            .font(.system(size: WorkspaceTypography.metaSize, weight: .medium))
                    }
                    .buttonStyle(AppSecondaryButtonStyle())
                    .disabled(store.reviewIsRunning || store.gitDiffOutput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .help("使用本地安全与正确性规则扫描")

                    Button {
                        Task { await store.runSemanticReview() }
                    } label: {
                        Label("DeepSeek", systemImage: "sparkles")
                            .font(.system(size: WorkspaceTypography.metaSize, weight: .medium))
                    }
                    .buttonStyle(AppSecondaryButtonStyle())
                    .disabled(store.reviewIsRunning || store.gitDiffOutput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .help("使用 DeepSeek Pro 只读审查当前 Diff")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            Divider()

            if store.reviewFindings.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Image(systemName: store.reviewUpdatedAt == nil ? "checkmark.shield" : "checkmark.circle")
                        .font(.system(size: 20, weight: .medium))
                        .foregroundStyle(.secondary)
                    Text(store.reviewUpdatedAt == nil ? "还没有审查结果" : "未发现自动扫描问题")
                        .font(.system(size: WorkspaceTypography.labelSize, weight: .semibold))
                    Text(store.reviewUpdatedAt == nil
                         ? "运行 Review 后，这里会显示按文件和行号定位的问题。"
                         : "当前 Diff 已通过本地安全与正确性规则扫描。")
                        .font(.system(size: WorkspaceTypography.metaSize))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(14)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 6) {
                            ReviewSummaryPill(title: "\(store.reviewFindings.count) 个问题", color: .orange)
                            ReviewSummaryPill(title: "\(store.reviewFindings.filter { $0.severity == .p0 }.count) 个高风险", color: .red)
                            Spacer()
                        }
                        .padding(.bottom, 2)
                        ForEach(store.reviewFindings) { finding in
                            ReviewFindingCard(finding: finding)
                        }
                    }
            .padding(12)
        }
    }

}
        .background(AppTheme.panel)
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()
}

private struct ReviewSummaryPill: View {
    let title: String
    let color: Color

    var body: some View {
        Text(title)
            .font(.system(size: WorkspaceTypography.microSize, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .frame(height: 20)
            .background(color.opacity(0.10), in: Capsule(style: .continuous))
    }
}

private struct ReviewFindingCard: View {
    @Environment(WorkspaceStore.self) private var store
    let finding: ReviewFinding
    @State private var isHovered = false

    var body: some View {
        Button {
            store.selectedRightPanel = .files
            Task { await store.openFile(path: finding.file) }
            store.statusMessage = "已定位到 \(finding.file):\(finding.startLine)"
        } label: {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 7) {
                    Text(finding.severity.title)
                        .font(.system(size: WorkspaceTypography.microSize, weight: .bold, design: .rounded))
                        .foregroundStyle(severityColor)
                        .padding(.horizontal, 6)
                        .frame(height: 18)
                        .background(severityColor.opacity(0.12), in: Capsule(style: .continuous))
                    Text(finding.category.title)
                        .font(.system(size: WorkspaceTypography.microSize, weight: .medium))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("\(finding.file):\(finding.startLine)")
                        .font(.system(size: WorkspaceTypography.microSize, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
                Text(finding.title)
                    .font(.system(size: WorkspaceTypography.labelSize, weight: .semibold))
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(finding.evidence)
                    .font(.system(size: WorkspaceTypography.metaSize))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(finding.recommendation)
                    .font(.system(size: WorkspaceTypography.metaSize))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(10)
            .background(isHovered ? AppTheme.hover : Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(isHovered ? AppTheme.border.opacity(0.5) : AppTheme.border.opacity(0.28), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovered)
    }

    private var severityColor: Color {
        switch finding.severity {
        case .p0: return .red
        case .p1: return .orange
        case .p2: return .yellow
        case .p3: return .blue
        }
    }
}

private struct BottomStatusBar: View {
    @Environment(WorkspaceStore.self) private var store

    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: WorkspaceDesignTokens.footerItemSpacing) {
                FooterChip(title: "Problems", systemImage: "exclamationmark.triangle", trailingText: "0")
                FooterChip(title: "Output", systemImage: "list.bullet.rectangle")
            }
            Spacer()
            HStack(spacing: 5) {
                AppStatusDot(color: store.statusMessage.contains("失败") ? .red : store.statusMessage.contains("执行") || store.statusMessage.contains("读取") ? .orange : .green)
                Text(store.statusMessage)
                    .lineLimit(1)
            }
            .font(.system(size: WorkspaceTypography.metaSize, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .frame(height: WorkspaceDesignTokens.footerStatusHeight)
        }
        .padding(.horizontal, 14)
        .frame(height: WorkspaceDesignTokens.footerHeight)
        .background(AppTheme.canvas)
        .overlay(alignment: .top) { Divider() }
    }
}

private struct FooterChip: View {
    let title: String
    let systemImage: String
    var trailingText: String?
    var isSelected = false
    var action: () -> Void = {}
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: systemImage)
                    .font(.system(size: 9, weight: .semibold))
                Text(title)
                    .font(.system(size: 10, weight: isSelected ? .semibold : .medium))
                if let trailingText {
                    Text(trailingText)
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5)
                        .frame(height: 16)
                        .background(Color.primary.opacity(0.06), in: Capsule(style: .continuous))
                }
            }
            .foregroundStyle(isSelected ? .primary : .secondary)
            .padding(.horizontal, 7)
            .frame(height: WorkspaceDesignTokens.footerControlHeight)
            .background(isSelected ? Color.primary.opacity(0.06) : (isHovered ? AppTheme.hover : Color.clear), in: Capsule(style: .continuous))
            .overlay {
                Capsule(style: .continuous)
                    .stroke(isSelected ? AppTheme.border.opacity(0.65) : (isHovered ? AppTheme.border.opacity(WorkspaceDesignTokens.hoverBorderOpacity) : Color.clear), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovered)
        .help(title)
        .accessibilityLabel(title)
    }
}

private struct PTYTerminalView: NSViewRepresentable {
    let terminalID: String?
    let output: String
    let onData: (Data) -> Void
    let onResize: (Int, Int) -> Void

    final class Coordinator: NSObject, SwiftTerm.TerminalViewDelegate {
        var lastOutput = ""
        var onData: (Data) -> Void
        var onResize: (Int, Int) -> Void

        init(onData: @escaping (Data) -> Void, onResize: @escaping (Int, Int) -> Void) {
            self.onData = onData
            self.onResize = onResize
        }

        func send(source: SwiftTerm.TerminalView, data: ArraySlice<UInt8>) {
            onData(Data(data))
        }

        func sizeChanged(source: SwiftTerm.TerminalView, newCols: Int, newRows: Int) {
            onResize(newCols, newRows)
        }

        func setTerminalTitle(source: SwiftTerm.TerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: SwiftTerm.TerminalView, directory: String?) {}
        func scrolled(source: SwiftTerm.TerminalView, position: Double) {}
        func requestOpenLink(source: SwiftTerm.TerminalView, link: String, params: [String: String]) {}
        func bell(source: SwiftTerm.TerminalView) {}
        func clipboardCopy(source: SwiftTerm.TerminalView, content: Data) {}
        func rangeChanged(source: SwiftTerm.TerminalView, startY: Int, endY: Int) {}
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onData: onData, onResize: onResize)
    }

    func makeNSView(context: Context) -> SwiftTerm.TerminalView {
        let view = SwiftTerm.TerminalView(frame: .zero)
        view.terminalDelegate = context.coordinator
        view.configureNativeColors()
        view.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        if !output.isEmpty {
            view.feed(text: output)
            context.coordinator.lastOutput = output
        }
        return view
    }

    func updateNSView(_ view: SwiftTerm.TerminalView, context: Context) {
        context.coordinator.onData = onData
        context.coordinator.onResize = onResize
        if output.count >= context.coordinator.lastOutput.count,
           output.hasPrefix(context.coordinator.lastOutput) {
            let delta = String(output.dropFirst(context.coordinator.lastOutput.count))
            if !delta.isEmpty { view.feed(text: delta) }
        } else if context.coordinator.lastOutput != output {
            // A new terminal tab is given a new identity by the parent. This
            // fallback keeps updates safe if a persisted snapshot is replaced.
            view.feed(text: "\u{1b}[2J\u{1b}[H")
            view.feed(text: output)
        }
        context.coordinator.lastOutput = output
    }
}

private struct TerminalView: View {
    @Environment(WorkspaceStore.self) private var store
    @State private var isRunHovered = false
    @State private var isStopHovered = false

    var body: some View {
        @Bindable var store = store

        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 7) {
                Label("Terminal", systemImage: "terminal")
                    .font(.system(size: WorkspaceTypography.titleSize, weight: .semibold))
                    .foregroundStyle(AppTheme.terminalText)
                Menu {
                    Button("Local") { store.terminalTarget = .local }
                    Button("Worktree") { store.terminalTarget = .worktree }
                    if !store.sshHosts.isEmpty {
                        Divider()
                        ForEach(store.sshHosts) { host in
                            Button("SSH · \(host.hostname)") {
                                store.terminalSSHHostID = host.id
                                store.terminalTarget = .ssh(hostID: host.id)
                            }
                            .disabled(store.sshConnectionStatus[host.id] != .connected)
                        }
                    }
                } label: {
                    Text(store.terminalTarget.label)
                        .font(.system(size: WorkspaceTypography.metaSize, weight: .medium, design: .rounded))
                        .foregroundStyle(AppTheme.terminalText.opacity(0.64))
                }
                .menuStyle(.borderlessButton)
                Spacer()
                Button { store.openTerminal() } label: {
                    Label("New", systemImage: "plus")
                }
                .buttonStyle(.plain)
                .font(.system(size: WorkspaceTypography.metaSize, weight: .semibold))
                .foregroundStyle(AppTheme.terminalText.opacity(0.82))
            }
            .padding(.horizontal, 14)
            .frame(height: 44)
            if !store.terminalSessions.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 5) {
                        ForEach(store.terminalSessions) { terminal in
                            Button {
                                store.selectTerminal(id: terminal.id)
                            } label: {
                                HStack(spacing: 5) {
                                    AppStatusDot(color: [.running, .background].contains(terminal.state) ? .green : (terminal.state == .failed ? .red : .gray))
                                    Text(terminal.target.label)
                                        .lineLimit(1)
                                    if let pid = terminal.pid { Text("· \(pid)").foregroundStyle(.secondary) }
                                }
                                .font(.system(size: WorkspaceTypography.metaSize, weight: terminal.id == store.activeTerminalID ? .semibold : .regular, design: .rounded))
                                .foregroundStyle(terminal.id == store.activeTerminalID ? AppTheme.terminalText : AppTheme.terminalText.opacity(0.58))
                                .padding(.horizontal, 8)
                                .frame(height: 30)
                                .background(terminal.id == store.activeTerminalID ? Color.white.opacity(0.12) : Color.clear, in: Capsule(style: .continuous))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 14)
                }
                .frame(height: 30)
            }
            HStack(spacing: 8) {
                TextField("command", text: $store.terminalCommand)
                    .textFieldStyle(.plain)
                    .font(.system(size: WorkspaceTypography.bodySize, design: .monospaced))
                    .foregroundStyle(AppTheme.terminalText)
                    .padding(.horizontal, 9)
                    .frame(height: 34)
                    .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                Button("Run") { store.runTerminalCommand() }
                    .buttonStyle(.plain)
                    .font(.system(size: WorkspaceTypography.metaSize, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 11)
                    .frame(height: 34)
                    .background(Color.accentColor.opacity(isRunHovered ? 0.86 : 1), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .onHover { isRunHovered = $0 }
                    .animation(.easeOut(duration: 0.12), value: isRunHovered)
                Button("Stop") { store.stopTerminalCommand() }
                    .buttonStyle(.plain)
                    .font(.system(size: WorkspaceTypography.metaSize, weight: .medium))
                    .foregroundStyle(AppTheme.terminalText)
                    .padding(.horizontal, 10)
                    .frame(height: 34)
                    .background(Color.white.opacity(isStopHovered ? 0.13 : 0.07), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .onHover { isStopHovered = $0 }
                    .animation(.easeOut(duration: 0.12), value: isStopHovered)
                    .disabled(!store.terminalRunning)
                Button("后台") { store.launchBackgroundTerminal() }
                    .buttonStyle(.plain)
                    .font(.system(size: WorkspaceTypography.metaSize, weight: .medium))
                    .foregroundStyle(AppTheme.terminalText)
                    .padding(.horizontal, 9)
                    .frame(height: 34)
                    .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            if let pending = store.terminalPendingApproval {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text("L\(pending.risk.rawValue) 命令需要确认")
                    Text(pending.arguments).lineLimit(1).foregroundStyle(.secondary)
                    Spacer()
                    Button("拒绝") { store.approvePendingTerminalCommand(.deny) }.buttonStyle(.plain)
                    Button("允许本次") { store.approvePendingTerminalCommand(.allowOnce) }.buttonStyle(.borderedProminent)
                }
                .font(.system(size: WorkspaceTypography.metaSize, weight: .medium))
                .foregroundStyle(AppTheme.terminalText)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .padding(.horizontal, 14)
            }
            if store.terminalProtectedInputRequired {
                ProtectedTerminalInputView { value in
                    store.sendProtectedTerminalInput(Data((value + "\n").utf8))
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 8)
            }
            PTYTerminalView(
                terminalID: store.activeTerminalID,
                output: store.activeTerminalOutput,
                onData: { store.sendTerminalInput($0) },
                onResize: { columns, rows in store.resizeTerminal(columns: columns, rows: rows) }
            )
            .id(store.activeTerminalID ?? "empty-terminal")
            .background(Color.black.opacity(0.14), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .padding(.horizontal, 14)
            HStack(spacing: 8) {
                Button("Interrupt") { store.interruptActiveTerminal() }.buttonStyle(.plain)
                Button("EOF") { store.eofActiveTerminal() }.buttonStyle(.plain)
                Button("Close") { store.closeActiveTerminal() }.buttonStyle(.plain)
            }
            .font(.system(size: WorkspaceTypography.metaSize, weight: .medium))
            .foregroundStyle(AppTheme.terminalText.opacity(0.72))
            .padding(.horizontal, 14)
            .padding(.top, 8)
            HStack(spacing: 7) {
                AppStatusDot(color: store.activeTerminal.map { [.running, .background].contains($0.state) ? .green : ($0.state == .failed ? .red : .gray) } ?? .gray)
                Text(store.activeTerminal?.state.rawValue ?? "Ready")
                Image(systemName: store.terminalHelperConnectionState.systemImage)
                    .foregroundStyle(store.terminalHelperConnectionState == .connected ? .green : (store.terminalHelperConnectionState == .needsAttention ? .orange : AppTheme.terminalText.opacity(0.68)))
                Text(store.terminalHelperConnectionState.title)
                if let terminal = store.activeTerminal {
                    Text("· \(terminal.cwd)").lineLimit(1)
                    if let pid = terminal.pid { Text("· PID \(pid)") }
                }
                ForEach(store.terminalPorts.filter { $0.terminalID == store.activeTerminalID }) { port in
                    Button("localhost:\(port.port)") { store.openTerminalPortInBrowser(port.port) }
                        .buttonStyle(.plain)
                        .foregroundStyle(.cyan)
                }
                Spacer()
                Text(store.statusMessage)
                    .lineLimit(1)
            }
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(AppTheme.terminalText.opacity(0.62))
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
        }
        .background(AppTheme.terminalBackground)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct ProtectedTerminalInputView: View {
    let submit: (String) -> Void
    @State private var value = ""

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "lock.fill").foregroundStyle(.orange)
            SecureField("需要用户接管：输入密码 / Token / 验证码", text: $value)
                .textFieldStyle(.plain)
                .onSubmit { submitValue() }
            Button("完成") { submitValue() }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
        }
        .padding(8)
        .background(Color.orange.opacity(0.14), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    }

    private func submitValue() {
        guard !value.isEmpty else { return }
        submit(value)
        value = ""
    }
}

private struct ToolbarButtons: View {
    @Environment(WorkspaceStore.self) private var store

    var body: some View {
        Button(store.isInspectorVisible ? "隐藏 Inspector" : "显示 Inspector", systemImage: store.isInspectorVisible ? "sidebar.right" : "sidebar.right") {
            store.isInspectorVisible.toggle()
        }
        .labelStyle(.iconOnly)
        .buttonStyle(AppIconButtonStyle())
        .help(store.isInspectorVisible ? "隐藏 Inspector" : "显示 Inspector")
        Button("打开终端", systemImage: "terminal") {
            store.selectedRightPanel = .terminal
            store.isInspectorVisible = true
        }
        .keyboardShortcut("j", modifiers: [.command])
        .labelStyle(.iconOnly)
        .buttonStyle(AppIconButtonStyle())
        .help("在右侧侧栏打开终端（⌘J）")
        Button("新建 Session", systemImage: "plus.bubble") { store.createSession() }
            .labelStyle(.iconOnly)
            .buttonStyle(AppIconButtonStyle())
            .help("新建 Session")
        Button("设置", systemImage: "gearshape") { store.isSettingsPresented = true }
            .labelStyle(.iconOnly)
            .buttonStyle(AppIconButtonStyle())
            .help("设置")
    }
}

private struct SettingsView: View {
    @Environment(WorkspaceStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        @Bindable var store = store

        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("连接设置")
                        .font(.system(size: WorkspaceTypography.displaySize, weight: .semibold))
                    Text("默认只需填写 Base URL 和 API Key；模型、协议和视觉能力都使用自动默认值。")
                        .font(.system(size: WorkspaceTypography.metaSize))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("关闭", systemImage: "xmark") { dismiss() }
                    .labelStyle(.iconOnly)
                    .buttonStyle(AppIconButtonStyle())
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
            Divider()
            Form {
                Section("基础连接") {
                    TextField("Base URL", text: $store.providerBaseURL)
                    SecureField("API Key", text: $store.providerAPIKey)
                    if !store.providerStatus.isEmpty {
                        Label(store.providerStatus, systemImage: store.providerStatus.hasPrefix("连接成功") || store.providerStatus.hasPrefix("已安全保存") ? "checkmark.circle.fill" : "info.circle")
                            .font(.system(size: WorkspaceTypography.metaSize))
                            .foregroundStyle(store.providerStatus.hasPrefix("连接成功") || store.providerStatus.hasPrefix("已安全保存") ? .green : .secondary)
                    }
                }
                Section {
                    DisclosureGroup("高级设置") {
                        VStack(alignment: .leading, spacing: 10) {
                            TextField("Provider 名称", text: $store.providerName)
                            TextField("模型", text: $store.providerModel)
                            Picker("协议", selection: $store.providerProtocol) {
                                Text("OpenAI-compatible").tag(ProviderProtocol.openAICompatible)
                                Text("Anthropic-compatible").tag(ProviderProtocol.anthropicCompatible)
                            }
                            LabeledContent("能力状态") {
                                Text("Tool \(store.providerCapabilities.toolCalling ? "已验证" : "未验证") · 图片 \(store.providerCapabilities.imageInput ? "已验证" : "未启用")")
                                    .font(.system(size: WorkspaceTypography.metaSize))
                                    .foregroundStyle(.secondary)
                            }
                            Text(store.providerCapabilities.imageInput
                                 ? "图片能力来自最近一次真实 Capability Test。"
                                 : "默认使用文本 Agent + 本地 OCR/PDF 提取；未验证的视觉能力不会发送原图。")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                            Toggle("启用独立视觉适配器", isOn: $store.visionAdapterEnabled)
                            if store.visionAdapterEnabled {
                                TextField("视觉适配器 Base URL", text: $store.visionAdapterBaseURL)
                                TextField("视觉模型", text: $store.visionAdapterModel)
                                SecureField("视觉适配器 API Key", text: $store.visionAdapterAPIKey)
                                Text("视觉适配器只返回结构化观察，不拥有文件、终端、Git 或 Computer Use 权限。")
                                    .font(.system(size: WorkspaceTypography.metaSize))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.top, 4)
                    }
                }
                Section("Computer Use") {
                    Label(store.computerPermissionStatus, systemImage: "accessibility")
                        .font(.system(size: WorkspaceTypography.metaSize))
                        .foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        Button("检查权限") { store.refreshComputerPermissionStatus() }
                            .buttonStyle(AppSecondaryButtonStyle())
                        Button("打开系统设置") {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                        .buttonStyle(AppSecondaryButtonStyle())
                    }
                    Text("Computer Use 默认只读观察；点击、输入和按键仍会按风险等级逐次审批。")
                        .font(.system(size: WorkspaceTypography.metaSize))
                        .foregroundStyle(.secondary)
                }
                Section("本机 Control Plane") {
                    if let pairing = store.controlPlanePairing {
                        Text(pairing.url.absoluteString)
                            .font(.system(size: WorkspaceTypography.metaSize, design: .monospaced))
                            .textSelection(.enabled)
                        Text("仅监听本机 loopback；配对令牌将在 \(pairing.expiresAt.formatted(date: .omitted, time: .shortened)) 过期。")
                            .font(.system(size: WorkspaceTypography.metaSize))
                            .foregroundStyle(.secondary)
                        Button("停止并撤销配对") { store.stopLocalControlPlane() }
                            .buttonStyle(AppSecondaryButtonStyle())
                    } else {
                        Text("供本机 Web、IDE 或第二客户端读取 Session 并通过同一审批链提交输入。不会开放局域网或公网访问。")
                            .font(.system(size: WorkspaceTypography.metaSize))
                            .foregroundStyle(.secondary)
                        Button("启动本机配对") { store.startLocalControlPlane() }
                            .buttonStyle(AppSecondaryButtonStyle())
                    }
                }
                Section("应用版本") {
                    LabeledContent("Build", value: BuildStamp.current)
                        .font(.system(size: WorkspaceTypography.metaSize, design: .monospaced))
                    Text("每次刷新都会原子替换应用并更新 Build，避免继续运行旧副本。")
                        .font(.system(size: WorkspaceTypography.metaSize))
                        .foregroundStyle(.secondary)
                }
                Section("Session 数据") {
                    Text("永久删除会先写入本机 JSON 备份；恢复操作不会上传项目、附件或密钥。")
                        .font(.system(size: WorkspaceTypography.metaSize))
                        .foregroundStyle(.secondary)
                    Button("从本地备份恢复 Session") {
                        store.isSessionRestorePickerPresented = true
                    }
                    .buttonStyle(AppSecondaryButtonStyle())
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                Button("测试能力") { Task { await store.testProvider() } }
                    .buttonStyle(AppSecondaryButtonStyle())
                Spacer()
                Button("取消") { dismiss() }
                    .buttonStyle(AppTextButtonStyle())
                    .foregroundStyle(.secondary)
                Button("保存 Provider") { store.saveProvider() }
                    .buttonStyle(AppPrimaryButtonStyle())
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
        }
        .background(AppTheme.canvas)
        .frame(minWidth: 560, idealWidth: 620, minHeight: 540)
    }
}

private extension View {
    func tagCapsule() -> some View {
        self.padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Color.secondary.opacity(0.12), in: Capsule())
    }
}
