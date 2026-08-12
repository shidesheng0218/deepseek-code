import Foundation

public enum AgentMode: String, CaseIterable, Identifiable, Codable, Sendable {
    case plan
    case manual
    case acceptEdits
    case auto

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .plan: "Plan"
        case .manual: "Manual"
        case .acceptEdits: "Accept Edits"
        case .auto: "Auto"
        }
    }

    public var subtitle: String {
        switch self {
        case .plan: "只读探索并生成计划"
        case .manual: "每一步都需要确认"
        case .acceptEdits: "自动应用工作区补丁"
        case .auto: "低风险操作自动执行"
        }
    }
}

public enum SessionTarget: String, CaseIterable, Identifiable, Codable, Sendable {
    case local
    case worktree
    case ssh

    public var id: String { rawValue }
    public var title: String { rawValue.capitalized }
}

public enum HomeOverviewSection: String, CaseIterable, Identifiable, Sendable {
    case overview
    case models

    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .overview: "Overview"
        case .models: "Runtime"
        }
    }
}

public enum HomeActivityRange: String, CaseIterable, Identifiable, Sendable {
    case all
    case thirtyDays
    case sevenDays

    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .all: "All"
        case .thirtyDays: "30d"
        case .sevenDays: "7d"
        }
    }
}

public enum HomeCopy {
    public static func activityHint(hasSessions: Bool, range: HomeActivityRange) -> String {
        hasSessions
            ? "最近一次活动来自当前工作区 · \(range.title)"
            : "从底部输入框开始创建第一个任务 · \(range.title)"
    }

    public static func modelHint(range: HomeActivityRange) -> String {
        "连接细节在左上角设置里查看 · \(range.title)"
    }
}

public enum ConversationChromeCopy {
    public static func topBarSummary(changeCount: Int, statusMessage: String) -> [String] {
        var items: [String] = []
        if changeCount > 0 {
            items.append("\(changeCount) 个文件有变更")
        }
        if !statusMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            items.append(statusMessage)
        }
        return items
    }

    public static let showsComposerSeparator = false
    public static let showsConversationHeaderDivider = false

    public static func showsContextRow(isHome: Bool) -> Bool {
        !isHome
    }
}

public enum ComposerKeyAction: Equatable, Sendable {
    case submit
    case insertNewline
    case deferToTextView
}

public enum ComposerKeyHandling {
    public static func action(isReturn: Bool, hasMarkedText: Bool, hasShift: Bool) -> ComposerKeyAction {
        guard isReturn else { return .deferToTextView }
        // While an IME has marked text, Return confirms the composition. Let
        // NSTextView handle it instead of sending an incomplete message.
        guard !hasMarkedText else { return .deferToTextView }
        return hasShift ? .insertNewline : .submit
    }
}

public enum SessionStatus: String, CaseIterable, Identifiable, Codable, Sendable {
    case created
    case planning
    case awaitingPlanApproval
    case executing
    case running
    case waiting
    case awaitingToolApproval
    case awaitingApproval
    case needsAttention
    case verifying
    case handoffReady
    case awaitingDeliveryApproval
    case delivering
    case needsRepair
    case delivered
    case needsReview
    case completed
    case failed

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .created: "Created"
        case .planning: "Planning"
        case .awaitingPlanApproval: "Awaiting plan approval"
        case .executing: "Executing"
        case .running: "Running"
        case .waiting: "Waiting"
        case .awaitingToolApproval: "Awaiting tool approval"
        case .awaitingApproval: "Awaiting approval"
        case .needsAttention: "Needs attention"
        case .verifying: "Verifying"
        case .handoffReady: "Handoff ready"
        case .awaitingDeliveryApproval: "Awaiting delivery approval"
        case .delivering: "Delivering"
        case .needsRepair: "Needs repair"
        case .delivered: "Delivered"
        case .needsReview: "Needs review"
        case .completed: "Completed"
        case .failed: "Failed"
        }
    }

    public var colorToken: String {
        switch self {
        case .created: "blue"
        case .planning: "blue"
        case .awaitingPlanApproval: "amber"
        case .executing: "mint"
        case .running: "mint"
        case .waiting: "secondary"
        case .awaitingToolApproval: "amber"
        case .awaitingApproval: "amber"
        case .needsAttention: "red"
        case .verifying: "blue"
        case .handoffReady: "purple"
        case .awaitingDeliveryApproval: "amber"
        case .delivering: "purple"
        case .needsRepair: "red"
        case .delivered: "green"
        case .needsReview: "amber"
        case .completed: "green"
        case .failed: "red"
        }
    }

    /// Deterministic state transitions used by the supervisor and recovery projector.
    /// Legacy states remain accepted so existing sessions can be resumed safely.
    public func canTransition(to next: SessionStatus) -> Bool {
        if self == next { return true }
        switch (self, next) {
        case (.created, .planning),
             (.planning, .awaitingPlanApproval),
             (.planning, .executing),
             (.awaitingPlanApproval, .executing),
             (.awaitingPlanApproval, .planning),
             (.executing, .awaitingToolApproval),
             (.executing, .verifying),
             (.executing, .needsAttention),
             (.executing, .failed),
             (.running, .awaitingApproval),
             (.running, .verifying),
             (.running, .needsAttention),
             (.running, .failed),
             (.awaitingApproval, .executing),
             (.awaitingApproval, .needsAttention),
             (.verifying, .handoffReady),
             (.verifying, .needsRepair),
             (.verifying, .awaitingDeliveryApproval),
             (.handoffReady, .awaitingDeliveryApproval),
             (.awaitingDeliveryApproval, .delivering),
             (.awaitingDeliveryApproval, .needsAttention),
             (.delivering, .delivered),
             (.delivering, .needsRepair),
             (.needsRepair, .executing),
             (.needsRepair, .verifying),
             (.needsAttention, .executing),
             (.needsAttention, .verifying),
             (.needsAttention, .awaitingApproval),
             (.needsReview, .verifying),
             (.completed, .verifying),
             (.failed, .executing),
             (.waiting, .planning),
             (.waiting, .executing):
            return true
        default:
            return false
        }
    }
}

public struct Session: Identifiable, Hashable, Sendable {
    public let id: String
    public var title: String
    public var target: SessionTarget
    public var branch: String
    public var status: SessionStatus
    public var cost: String

    public init(id: String, title: String, target: SessionTarget, branch: String, status: SessionStatus, cost: String) {
        self.id = id
        self.title = title
        self.target = target
        self.branch = branch
        self.status = status
        self.cost = cost
    }

    public static let sample = Session(id: "login", title: "修复登录状态同步", target: .worktree, branch: "deepseek/fix-auth-sync", status: .running, cost: "¥0.18")

    public static let samples = [
        sample,
        Session(id: "review", title: "审查支付模块", target: .local, branch: "main", status: .needsReview, cost: "¥0.09"),
        Session(id: "perf", title: "分析首屏性能", target: .worktree, branch: "deepseek/perf-audit", status: .waiting, cost: "¥0.04"),
        Session(id: "deps", title: "升级依赖并验证", target: .ssh, branch: "release/1.4", status: .completed, cost: "¥0.12")
    ]
}

public struct PlanStep: Identifiable, Hashable, Sendable {
    public let id: String
    public var title: String
    public var state: State

    public enum State: String, Sendable {
        case completed
        case active
        case pending
    }

    public init(id: String, title: String, state: State) {
        self.id = id
        self.title = title
        self.state = state
    }
}

public struct ChangeFile: Identifiable, Hashable, Sendable {
    public var id: String { path }
    public let path: String
    public let added: Int
    public let removed: Int

    public init(path: String, added: Int, removed: Int) {
        self.path = path
        self.added = added
        self.removed = removed
    }
}
