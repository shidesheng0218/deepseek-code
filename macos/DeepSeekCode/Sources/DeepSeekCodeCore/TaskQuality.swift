import Foundation

public enum TaskKind: String, Codable, CaseIterable, Sendable {
    case directAnswer
    case projectQuestion
    case exploration
    case bugFix
    case codeChange
    case research
    case review
    case deliveryRepair
    case multimodalRepair
}

public enum TaskComplexity: Int, Codable, Comparable, Sendable {
    case trivial = 0
    case standard = 1
    case complex = 2
    case critical = 3

    public static func < (lhs: TaskComplexity, rhs: TaskComplexity) -> Bool { lhs.rawValue < rhs.rawValue }
}

public enum ResponseContractKind: String, Codable, Sendable {
    case directAnswer
    case projectFinding
    case executionPlan
    case researchConclusion
    case repairReport
    case reviewFindings
    case deliveryReport
}

public enum VerificationPolicy: String, Codable, Sendable {
    case none
    case optional
    case required
    case citationRequired
}

public struct TaskRoutingInput: Codable, Equatable, Sendable {
    public let prompt: String
    public let mode: AgentMode
    public let hasAttachments: Bool
    public let hasProject: Bool

    public init(prompt: String, mode: AgentMode, hasAttachments: Bool = false, hasProject: Bool = false) {
        self.prompt = prompt
        self.mode = mode
        self.hasAttachments = hasAttachments
        self.hasProject = hasProject
    }
}

public struct TaskRoute: Codable, Equatable, Sendable {
    public let kind: TaskKind
    public let complexity: TaskComplexity
    public let confidence: Double
    public let needsWorkspace: Bool
    public let needsResearch: Bool
    public let needsBrowser: Bool
    public let needsHighReasoning: Bool
    public let responseContract: ResponseContractKind
    public let verificationPolicy: VerificationPolicy
    public let reasons: [String]

    public init(
        kind: TaskKind,
        complexity: TaskComplexity,
        confidence: Double,
        needsWorkspace: Bool,
        needsResearch: Bool,
        needsBrowser: Bool,
        needsHighReasoning: Bool,
        responseContract: ResponseContractKind,
        verificationPolicy: VerificationPolicy,
        reasons: [String]
    ) {
        self.kind = kind
        self.complexity = complexity
        self.confidence = min(1, max(0, confidence))
        self.needsWorkspace = needsWorkspace
        self.needsResearch = needsResearch
        self.needsBrowser = needsBrowser
        self.needsHighReasoning = needsHighReasoning
        self.responseContract = responseContract
        self.verificationPolicy = verificationPolicy
        self.reasons = reasons
    }
}

/// Deterministic first-pass routing keeps low-latency requests cheap and
/// makes every later model escalation explainable. Ambiguous routes carry a
/// lower confidence so callers can request a fast-model classifier later.
public enum TaskRouter {
    public static func route(_ input: TaskRoutingInput) -> TaskRoute {
        let prompt = input.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = prompt.lowercased()
        let contains = { (values: [String]) in values.contains { lower.contains($0.lowercased()) } }
        let repair = contains(["修复", "报错", "错误", "bug", "fix", "failing", "failure"])
        let review = contains(["review", "审查", "代码审查", "diff"])
        let research = contains(["联网", "官方文档", "搜索", "网页", "资料", "查一下", "查询", "research", "documentation", "web"])
        // “页面” alone is a normal UI feature request, not a browser-test
        // requirement. Escalate only on an explicit browser/evidence signal.
        let browser = contains(["浏览器", "截图", "dom", "console", "playwright", "browser"])
        let delivery = contains(["ci", "pull request", "pr", "交付", "github actions", "handoff"])
        // Intent verbs are required here. Generic nouns such as “代码” or
        // “构建” occur frequently in questions and exploration requests, and
        // must not force an execution plan by themselves.
        let codeChange = contains(["修改代码", "修改文件", "实现", "新增", "更新", "调整", "改动", "替换", "重构", "迁移", "implement", "refactor", "migrate", "add feature"])
        let exploration = contains(["分析项目", "探索", "定位", "看看", "目录", "依赖", "读取", "查看文件", "read file", "explore"])
        let multimodal = input.hasAttachments && (repair || browser)
        var reasons: [String] = []
        if repair { reasons.append("包含修复或错误信号") }
        if research { reasons.append("包含联网研究信号") }
        if browser { reasons.append("包含浏览器验证信号") }
        if delivery { reasons.append("包含交付或 CI 信号") }
        if input.hasAttachments { reasons.append("包含附件") }

        let kind: TaskKind
        if multimodal { kind = .multimodalRepair }
        else if delivery && repair { kind = .deliveryRepair }
        else if review { kind = .review }
        else if repair { kind = .bugFix }
        else if research { kind = .research }
        else if codeChange { kind = .codeChange }
        else if exploration { kind = .exploration }
        // Opening a repository must not turn every general question into an
        // expensive workspace task. Require an explicit project reference
        // before asking the Agent to inspect local files.
        else if input.hasProject && contains(["项目", "当前项目", "仓库", "代码库", "工作区", "this project", "repository", "workspace"]) { kind = .projectQuestion }
        else { kind = .directAnswer }

        var complexity: TaskComplexity = kind == .directAnswer ? .trivial : .standard
        if repair || research || browser || delivery { complexity = max(complexity, .complex) }
        if contains(["安全", "权限", "迁移", "架构", "重构", "性能", "security", "permission", "migration", "architecture", "refactor", "performance"]) {
            complexity = .critical
            reasons.append("包含高风险工程信号")
        }
        if input.mode == .auto { complexity = max(complexity, .complex) }
        let needsWorkspace = [.projectQuestion, .exploration, .bugFix, .codeChange, .review, .deliveryRepair, .multimodalRepair].contains(kind)
        let responseContract: ResponseContractKind = switch kind {
        case .directAnswer: .directAnswer
        case .projectQuestion, .exploration: .projectFinding
        case .research: .researchConclusion
        case .review: .reviewFindings
        case .deliveryRepair: .deliveryReport
        case .bugFix, .multimodalRepair: .repairReport
        case .codeChange: .executionPlan
        }
        let verification: VerificationPolicy = switch kind {
        case .directAnswer: .none
        case .research: .citationRequired
        case .bugFix, .codeChange, .review, .deliveryRepair, .multimodalRepair: .required
        case .projectQuestion, .exploration: .optional
        }
        let confidence: Double = reasons.isEmpty ? 0.72 : min(0.96, 0.78 + Double(reasons.count) * 0.05)
        return TaskRoute(
            kind: kind,
            complexity: complexity,
            confidence: confidence,
            needsWorkspace: needsWorkspace,
            needsResearch: research,
            needsBrowser: browser,
            needsHighReasoning: complexity >= .complex,
            responseContract: responseContract,
            verificationPolicy: verification,
            reasons: reasons.isEmpty ? ["默认直接回答路径"] : reasons
        )
    }
}

public enum ResponseContractRenderer {
    public static func instruction(for route: TaskRoute) -> String {
        switch route.responseContract {
        case .directAnswer:
            "直接给出结论。默认不超过三段；仅在必要时给一个最小示例。"
        case .projectFinding:
            "输出：结论、依据文件或 Evidence、不确定项、建议下一步。不要把推测写成事实。"
        case .executionPlan:
            "输出：目标、计划变更、涉及文件、验证方式、需要审批的操作。未执行前不得声称完成。"
        case .researchConclusion:
            "输出：结论、可引用来源、适用范围、冲突或风险。每个外部关键结论必须引用来源 ID。"
        case .repairReport:
            "输出：根因、变更、验证结果、仍存风险。测试或浏览器验证失败时不得称已修复。"
        case .reviewFindings:
            "只报告有证据的问题；按严重级别、文件、行号、证据和建议组织；没有问题时明确说明范围。"
        case .deliveryReport:
            "输出：已交付内容、PR/CI/验证证据、未完成项、豁免项和下一步。"
        }
    }
}
