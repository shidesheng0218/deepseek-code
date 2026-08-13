import CryptoKit
import Foundation

/// The model tier is selected from an explainable task plan rather than from
/// prompt length. It is intentionally provider-neutral: individual Provider
/// adapters lower `.fast` / `.capable` to verified model routes.
public enum QualityModelTier: String, Codable, Equatable, Sendable {
    case fast
    case capable
}

public enum QualityToolIntent: String, Codable, Equatable, Sendable {
    case none
    case readWorkspace
    case researchBeforeWrite
    case executeWithVerification
    case reviewEvidence
    case deliveryEvidence
}

public struct ContextPolicy: Codable, Equatable, Sendable {
    public let retainsStableInstructions: Bool
    public let retainsLatestUserMessage: Bool
    public let hydratesEvidenceByRelevance: Bool
    public let recentTurnLimit: Int

    public init(
        retainsStableInstructions: Bool = true,
        retainsLatestUserMessage: Bool = true,
        hydratesEvidenceByRelevance: Bool = true,
        recentTurnLimit: Int = 12
    ) {
        self.retainsStableInstructions = retainsStableInstructions
        self.retainsLatestUserMessage = retainsLatestUserMessage
        self.hydratesEvidenceByRelevance = hydratesEvidenceByRelevance
        self.recentTurnLimit = max(1, recentTurnLimit)
    }
}

/// A response contract gives the model an outcome-specific target without
/// forcing every normal answer into verbose JSON or a fixed template.
public struct ResponseContract: Codable, Equatable, Sendable {
    public let kind: ResponseContractKind
    public let requiredSections: [String]
    public let requiresCitations: Bool
    public let maximumParagraphs: Int?

    public init(kind: ResponseContractKind, requiredSections: [String], requiresCitations: Bool = false, maximumParagraphs: Int? = nil) {
        self.kind = kind
        self.requiredSections = requiredSections
        self.requiresCitations = requiresCitations
        self.maximumParagraphs = maximumParagraphs
    }

    public static func make(for route: TaskRoute) -> ResponseContract {
        switch route.responseContract {
        case .directAnswer:
            return ResponseContract(kind: .directAnswer, requiredSections: [], maximumParagraphs: 3)
        case .projectFinding:
            return ResponseContract(kind: .projectFinding, requiredSections: ["结论", "依据", "不确定", "下一步"])
        case .executionPlan:
            return ResponseContract(kind: .executionPlan, requiredSections: ["目标", "变更", "验证", "审批"])
        case .researchConclusion:
            return ResponseContract(kind: .researchConclusion, requiredSections: ["结论", "来源", "适用范围", "风险"], requiresCitations: true)
        case .repairReport:
            return ResponseContract(kind: .repairReport, requiredSections: ["根因", "变更", "验证", "风险"], requiresCitations: route.needsResearch)
        case .reviewFindings:
            return ResponseContract(kind: .reviewFindings, requiredSections: ["严重级别", "证据", "建议"])
        case .deliveryReport:
            return ResponseContract(kind: .deliveryReport, requiredSections: ["交付", "证据", "未完成", "下一步"])
        }
    }
}

public struct TaskQualityPlan: Codable, Equatable, Sendable {
    public let id: String
    public let route: TaskRoute
    public let modelTier: QualityModelTier
    public let responseContract: ResponseContract
    public let contextPolicy: ContextPolicy
    public let toolIntent: QualityToolIntent
    public let requiresCitations: Bool
    public let generatedAt: Date

    public init(
        id: String = UUID().uuidString,
        route: TaskRoute,
        modelTier: QualityModelTier,
        responseContract: ResponseContract,
        contextPolicy: ContextPolicy = ContextPolicy(),
        toolIntent: QualityToolIntent,
        requiresCitations: Bool,
        generatedAt: Date = Date()
    ) {
        self.id = id
        self.route = route
        self.modelTier = modelTier
        self.responseContract = responseContract
        self.contextPolicy = contextPolicy
        self.toolIntent = toolIntent
        self.requiresCitations = requiresCitations
        self.generatedAt = generatedAt
    }
}

/// The planner is deterministic, low-latency and persisted as an event. A
/// future classifier may propose a different route, but must do so through an
/// explicit plan revision rather than silently changing execution policy.
public enum TaskQualityPlanner {
    public static func plan(_ input: TaskRoutingInput) -> TaskQualityPlan {
        plan(route: TaskRouter.route(input))
    }

    public static func plan(route: TaskRoute) -> TaskQualityPlan {
        let contract = ResponseContract.make(for: route)
        let modelTier: QualityModelTier = route.needsHighReasoning || route.complexity >= .complex || [.review, .deliveryRepair, .multimodalRepair].contains(route.kind) ? .capable : .fast
        let toolIntent: QualityToolIntent
        switch route.kind {
        case .directAnswer:
            toolIntent = .none
        case .projectQuestion, .exploration:
            toolIntent = .readWorkspace
        case .research:
            toolIntent = .researchBeforeWrite
        case .review:
            toolIntent = .reviewEvidence
        case .deliveryRepair:
            toolIntent = .deliveryEvidence
        case .bugFix, .codeChange, .multimodalRepair:
            toolIntent = route.needsResearch ? .researchBeforeWrite : .executeWithVerification
        }
        return TaskQualityPlan(
            route: route,
            modelTier: modelTier,
            responseContract: contract,
            toolIntent: toolIntent,
            requiresCitations: contract.requiresCitations || route.needsResearch
        )
    }
}

public enum ContextEvidenceKind: String, Codable, CaseIterable, Equatable, Sendable {
    case stableInstruction
    case currentUser
    case recentConversation
    case toolResult
    case workspace
    case webCitation
    case browser
    case workerSummary
    case historicalSummary

    fileprivate var basePriority: Double {
        switch self {
        case .stableInstruction: 1_000
        case .currentUser: 990
        case .webCitation: 860
        case .workspace: 820
        case .browser: 800
        case .workerSummary: 760
        case .recentConversation: 700
        case .toolResult: 500
        case .historicalSummary: 400
        }
    }
}

/// A durable, content-addressed unit that may be hydrated into a model
/// request. Full evidence stays in the Evidence Store; a ContextEvidence only
/// carries the bounded text that is currently relevant.
public struct ContextEvidence: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let kind: ContextEvidenceKind
    public let content: String
    public let relevance: Double
    public let required: Bool
    public let sourceID: String?
    public let contentHash: String
    public let createdAt: Date

    public init(
        id: String = UUID().uuidString,
        kind: ContextEvidenceKind,
        content: String,
        relevance: Double = 0.5,
        required: Bool = false,
        sourceID: String? = nil,
        contentHash: String? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.kind = kind
        self.content = content
        self.relevance = min(1, max(0, relevance))
        self.required = required
        self.sourceID = sourceID
        self.contentHash = contentHash ?? Self.hash(content)
        self.createdAt = createdAt
    }

    public var estimatedTokens: Int { max(1, content.count / 4) }

    fileprivate var priority: Double { kind.basePriority + relevance * 100 }

    private static func hash(_ content: String) -> String {
        SHA256.hash(data: Data(content.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

public struct ContextSelection: Codable, Equatable, Sendable {
    public let nodes: [ContextEvidence]
    public let omittedIDs: [String]
    public let estimatedTokens: Int

    public init(nodes: [ContextEvidence], omittedIDs: [String], estimatedTokens: Int) {
        self.nodes = nodes
        self.omittedIDs = omittedIDs
        self.estimatedTokens = estimatedTokens
    }

    public var selectedIDs: [String] { nodes.map(\.id) }
}

/// Relevance-ranked context graph. Required policy and current-user evidence
/// always survive selection; all other evidence is selected by relevance and
/// provenance, avoiding the old "drop from the front" behavior.
public struct ContextGraph: Codable, Equatable, Sendable {
    public let nodes: [ContextEvidence]

    public init(nodes: [ContextEvidence]) {
        self.nodes = nodes
    }

    public func select(maxTokens: Int) -> ContextSelection {
        let budget = max(1, maxTokens)
        let ordered = nodes.enumerated().sorted { lhs, rhs in
            if lhs.element.required != rhs.element.required { return lhs.element.required }
            if lhs.element.priority != rhs.element.priority { return lhs.element.priority > rhs.element.priority }
            if lhs.element.createdAt != rhs.element.createdAt { return lhs.element.createdAt > rhs.element.createdAt }
            return lhs.offset < rhs.offset
        }

        var selectedIndexes: Set<Int> = []
        var used = 0
        for item in ordered {
            let tokenCount = item.element.estimatedTokens
            if item.element.required || used + tokenCount <= budget {
                selectedIndexes.insert(item.offset)
                used += tokenCount
            }
        }
        let selected = nodes.enumerated().compactMap { selectedIndexes.contains($0.offset) ? $0.element : nil }
        let omitted = nodes.enumerated().compactMap { selectedIndexes.contains($0.offset) ? nil : $0.element.id }
        return ContextSelection(nodes: selected, omittedIDs: omitted, estimatedTokens: selected.reduce(0) { $0 + $1.estimatedTokens })
    }

    public static func from(messages: [ChatMessage]) -> ContextGraph {
        let latestUserIndex = messages.lastIndex { $0.role == "user" }
        let nodes = messages.enumerated().map { index, message in
            let kind: ContextEvidenceKind
            switch message.role {
            case "system": kind = .stableInstruction
            case "user" where index == latestUserIndex: kind = .currentUser
            case "user", "assistant": kind = .recentConversation
            case "tool": kind = .toolResult
            default: kind = .historicalSummary
            }
            let required = kind == .stableInstruction || kind == .currentUser
            return ContextEvidence(id: "message-\(index)", kind: kind, content: message.content, relevance: required ? 1 : 0.5, required: required)
        }
        return ContextGraph(nodes: nodes)
    }
}

public struct QualityEvidenceState: Codable, Equatable, Sendable {
    public let kinds: Set<EvidenceKind>
    public let citationCount: Int

    public init(kinds: Set<EvidenceKind> = [], citationCount: Int = 0) {
        self.kinds = kinds
        self.citationCount = max(0, citationCount)
    }

    public var hasCitations: Bool { citationCount > 0 || kinds.contains(.citation) }

    public static func from(messages: [ChatMessage]) -> QualityEvidenceState {
        // Never treat a system-prompt placeholder such as `[WEB-S#]` as
        // evidence. Only concrete source IDs in model/tool content count.
        let text = messages
            .filter { $0.role != "system" }
            .map(\.content)
            .joined(separator: "\n")
            .lowercased()
        let pattern = #"\[web-s\d+\]"#
        let range = NSRange(text.startIndex..., in: text)
        let citations = (try? NSRegularExpression(pattern: pattern)).map { $0.numberOfMatches(in: text, range: range) } ?? 0
        var kinds: Set<EvidenceKind> = []
        if citations > 0 || text.contains("citation") { kinds.insert(.citation) }
        if text.contains("web_search") || text.contains("搜索结果") { kinds.insert(.webSearch) }
        if text.contains("web_fetch") || text.contains("抓取") { kinds.insert(.webFetch) }
        return QualityEvidenceState(kinds: kinds, citationCount: citations)
    }
}

public enum ToolDecision: Equatable, Sendable {
    case answerWithoutTool
    case execute
    case requestApproval(CommandRisk)
    case gatherEvidence([EvidenceKind])
    case blocked(String)
}

/// Decides the next safe class of tool action before the Permission Broker
/// applies its detailed project and user-grant policy. It does not grant any
/// permission itself.
public enum ToolDecisionPolicy {
    public static func decide(for tool: RegisteredTool, plan: TaskQualityPlan, evidence: QualityEvidenceState, workerKind: AgentWorkerKind = .main) -> ToolDecision {
        guard AgentWorkerPolicy.allows(tool.effect, for: workerKind) else {
            return .blocked("只读 Worker 不能使用具有副作用的工具")
        }
        guard tool.risk != .l4 else { return .blocked("L4 工具永久阻止") }
        if plan.toolIntent == .none {
            // A direct-answer route controls the *pre-tool* fast path. It
            // must not turn an explicit, read-only web tool call into a fake
            // failure. `AgentHost` still routes this through Research Grant,
            // PermissionBroker and NetworkRuntime's SSRF checks before any
            // request is sent.
            if ["web.search", "web.fetch"].contains(tool.name) { return .execute }
            // A direct-answer route should not trigger side effects, but a
            // model may still use an inexpensive local read to answer a
            // project-adjacent question accurately. It may also ask for a
            // concrete L0/L1 shell probe (for example `pwd`, `git status`,
            // or a test command); the Permission Broker still owns the
            // effective approval decision. Never let this exception cover a
            // workspace write, network action, or L2+ process command.
            if [.readOnly, .browserRead, .computerRead].contains(tool.effect) {
                return .execute
            }
            if tool.effect == .process, tool.risk <= .l1 {
                return .execute
            }
            return .answerWithoutTool
        }
        if plan.requiresCitations,
           !evidence.hasCitations,
           [.workspaceWrite, .gitWrite, .externalWrite].contains(tool.effect) {
            return .gatherEvidence([.webSearch, .webFetch, .citation])
        }
        if tool.risk >= .l2 { return .requestApproval(tool.risk) }
        return .execute
    }
}

public enum QualityFailurePhase: String, Codable, Equatable, Sendable {
    case requested
    case started
    case failed
    case indeterminate
}

public struct QualityToolFailure: Codable, Equatable, Sendable {
    public let effect: ToolEffect
    public let idempotent: Bool
    public let phase: QualityFailurePhase

    public init(effect: ToolEffect, idempotent: Bool, phase: QualityFailurePhase) {
        self.effect = effect
        self.idempotent = idempotent
        self.phase = phase
    }
}

public enum RecoveryAction: String, Codable, Equatable, Sendable {
    case retry
    case requestApproval
    case resumeAtSafeBoundary
    case needsAttention
}

/// Recovery is deliberately failure-only. Unknown writers are never replayed;
/// only a completed-safe, idempotent read can be retried automatically.
public enum RecoveryDirector {
    public static func action(for failure: QualityToolFailure) -> RecoveryAction {
        let readOnly = [.readOnly, .browserRead, .computerRead].contains(failure.effect)
        switch failure.phase {
        case .requested:
            return failure.idempotent && readOnly ? .retry : .requestApproval
        case .failed:
            return failure.idempotent && readOnly ? .retry : .requestApproval
        case .started, .indeterminate:
            return readOnly && failure.idempotent ? .resumeAtSafeBoundary : .needsAttention
        }
    }
}

public struct ResponseQualityAssessment: Codable, Equatable, Sendable {
    public let passed: Bool
    public let missingSections: [String]
    public let missingCitations: Bool
    public let styleViolations: [String]

    public init(passed: Bool, missingSections: [String], missingCitations: Bool, styleViolations: [String] = []) {
        self.passed = passed
        self.missingSections = missingSections
        self.missingCitations = missingCitations
        self.styleViolations = styleViolations
    }
}

public enum ResponseQualityValidator {
    public static func validate(_ response: String, contract: ResponseContract, evidence: QualityEvidenceState) -> ResponseQualityAssessment {
        let normalized = response.lowercased()
        let missingSections = contract.requiredSections.filter { !normalized.contains($0.lowercased()) }
        let missingCitations = contract.requiresCitations && !evidence.hasCitations
        let nonempty = !response.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let styleViolations = styleViolations(in: response, contract: contract)
        return ResponseQualityAssessment(
            passed: nonempty && missingSections.isEmpty && !missingCitations && styleViolations.isEmpty,
            missingSections: missingSections,
            missingCitations: missingCitations,
            styleViolations: styleViolations
        )
    }

    private static func styleViolations(in response: String, contract: ResponseContract) -> [String] {
        let normalized = response.lowercased()
        var violations: [String] = []
        let internalMarkers = [
            "web_fetch",
            "web_search",
            "run_command",
            "terminal.exec",
            "tool_completed",
            "tool_requested",
            "session_status",
            "deepseek-v",
            "tokens",
            "delivered",
            "needsattention",
            "needs attention"
        ]
        if internalMarkers.contains(where: { normalized.contains($0) }) {
            violations.append("internal_plumbing")
        }
        if contract.kind == .directAnswer {
            let headingMarkers = ["根因：", "变更：", "验证结果：", "仍存风险：", "输出：", "证据：", "交付："]
            let headingCount = headingMarkers.filter { response.contains($0) }.count
            if headingCount >= 2 { violations.append("mechanical_template") }
        }
        return violations
    }
}

public struct QualityTrace: Codable, Equatable, Sendable {
    public let planID: String
    public let routeKind: TaskKind
    public let selectedContextIDs: [String]
    public let omittedContextIDs: [String]
    public let toolIntent: QualityToolIntent
    public let responseAssessment: ResponseQualityAssessment?

    public init(plan: TaskQualityPlan, selection: ContextSelection, responseAssessment: ResponseQualityAssessment? = nil) {
        planID = plan.id
        routeKind = plan.route.kind
        selectedContextIDs = selection.selectedIDs
        omittedContextIDs = selection.omittedIDs
        toolIntent = plan.toolIntent
        self.responseAssessment = responseAssessment
    }
}

public struct QualityStrategyEvalCase: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let input: TaskRoutingInput
    public let expectedKind: TaskKind
    public let expectedTier: QualityModelTier

    public init(id: String, prompt: String, mode: AgentMode = .acceptEdits, hasAttachments: Bool = false, hasProject: Bool = false, expectedKind: TaskKind, expectedTier: QualityModelTier) {
        self.id = id
        self.input = TaskRoutingInput(prompt: prompt, mode: mode, hasAttachments: hasAttachments, hasProject: hasProject)
        self.expectedKind = expectedKind
        self.expectedTier = expectedTier
    }
}

public struct QualityStrategyEvalReport: Codable, Equatable, Sendable {
    public let total: Int
    public let passed: Int
    public let failedCaseIDs: [String]
}

/// A checked-in, deterministic strategy suite. It guards route, model-tier
/// and contract regressions before prompt or routing changes ship. It is not a
/// substitute for opt-in real-provider quality benchmarking.
public enum QualityStrategyEvalSuite {
    public static let v1: [QualityStrategyEvalCase] = [
        .init(id: "direct-01", prompt: "Swift actor 是什么？", expectedKind: .directAnswer, expectedTier: .fast),
        .init(id: "direct-02", prompt: "HTTP 302 是什么意思？", expectedKind: .directAnswer, expectedTier: .fast),
        .init(id: "direct-03", prompt: "解释一下 CAP 定理", expectedKind: .directAnswer, expectedTier: .fast),
        .init(id: "direct-04", prompt: "什么是 JSON Schema？", expectedKind: .directAnswer, expectedTier: .fast),
        .init(id: "direct-05", prompt: "Git rebase 和 merge 的区别？", expectedKind: .directAnswer, expectedTier: .fast),
        .init(id: "direct-06", prompt: "解释 UTF-8", expectedKind: .directAnswer, expectedTier: .fast),
        .init(id: "direct-07", prompt: "SQL 注入是什么？", expectedKind: .directAnswer, expectedTier: .fast),
        .init(id: "direct-08", prompt: "TLS 握手的主要步骤？", expectedKind: .directAnswer, expectedTier: .fast),
        .init(id: "direct-09", prompt: "什么是幂等？", expectedKind: .directAnswer, expectedTier: .fast),
        .init(id: "direct-10", prompt: "解释 O(n log n)", expectedKind: .directAnswer, expectedTier: .fast),

        .init(id: "project-01", prompt: "当前项目使用了什么状态管理方案？", hasProject: true, expectedKind: .projectQuestion, expectedTier: .fast),
        .init(id: "project-02", prompt: "这个项目的入口在哪里？", hasProject: true, expectedKind: .projectQuestion, expectedTier: .fast),
        .init(id: "project-03", prompt: "仓库里有哪些模块？", hasProject: true, expectedKind: .projectQuestion, expectedTier: .fast),
        .init(id: "project-04", prompt: "工作区是否有未提交变更？", hasProject: true, expectedKind: .projectQuestion, expectedTier: .fast),
        .init(id: "project-05", prompt: "代码库采用什么测试框架？", hasProject: true, expectedKind: .projectQuestion, expectedTier: .fast),

        .init(id: "explore-01", prompt: "分析项目目录结构", hasProject: true, expectedKind: .exploration, expectedTier: .fast),
        .init(id: "explore-02", prompt: "定位登录模块", hasProject: true, expectedKind: .exploration, expectedTier: .fast),
        .init(id: "explore-03", prompt: "看看依赖关系", hasProject: true, expectedKind: .exploration, expectedTier: .fast),
        .init(id: "explore-04", prompt: "探索当前仓库的构建入口", hasProject: true, expectedKind: .exploration, expectedTier: .fast),
        .init(id: "explore-05", prompt: "定位 API 客户端定义", hasProject: true, expectedKind: .exploration, expectedTier: .fast),

        .init(id: "research-01", prompt: "搜索 Swift 官方文档解释 actor 隔离", expectedKind: .research, expectedTier: .capable),
        .init(id: "research-02", prompt: "根据 React 官方文档说明 useEffect", expectedKind: .research, expectedTier: .capable),
        .init(id: "research-03", prompt: "联网查一下 Apple 的签名要求", expectedKind: .research, expectedTier: .capable),
        .init(id: "research-04", prompt: "搜索官方资料比较 OAuth PKCE", expectedKind: .research, expectedTier: .capable),
        .init(id: "research-05", prompt: "查询网页资料说明 WebKit 缓存", expectedKind: .research, expectedTier: .capable),
        .init(id: "research-06", prompt: "research HTTP RFC 中的重试语义", expectedKind: .research, expectedTier: .capable),
        .init(id: "research-07", prompt: "搜索 TypeScript documentation 的 satisfies", expectedKind: .research, expectedTier: .capable),
        .init(id: "research-08", prompt: "联网查官方文档中的 GitHub Actions 权限", expectedKind: .research, expectedTier: .capable),
        .init(id: "research-09", prompt: "查一下网页资料中 SQLite WAL 的限制", expectedKind: .research, expectedTier: .capable),
        .init(id: "research-10", prompt: "搜索官方文档解释 Playwright locator", expectedKind: .research, expectedTier: .capable),

        .init(id: "fix-01", prompt: "修复登录后页面闪退的报错", hasProject: true, expectedKind: .bugFix, expectedTier: .capable),
        .init(id: "fix-02", prompt: "fix failing unit test", hasProject: true, expectedKind: .bugFix, expectedTier: .capable),
        .init(id: "fix-03", prompt: "修复网络请求错误", hasProject: true, expectedKind: .bugFix, expectedTier: .capable),
        .init(id: "fix-04", prompt: "修复上传页面的 bug", hasProject: true, expectedKind: .bugFix, expectedTier: .capable),
        .init(id: "fix-05", prompt: "修复运行时报错", hasProject: true, expectedKind: .bugFix, expectedTier: .capable),
        .init(id: "fix-06", prompt: "修复 macOS 构建 failure", hasProject: true, expectedKind: .bugFix, expectedTier: .capable),
        .init(id: "fix-07", prompt: "修复终端命令执行错误", hasProject: true, expectedKind: .bugFix, expectedTier: .capable),
        .init(id: "fix-08", prompt: "修复浏览器 console error", hasProject: true, expectedKind: .bugFix, expectedTier: .capable),
        .init(id: "fix-09", prompt: "修复缓存失效 bug", hasProject: true, expectedKind: .bugFix, expectedTier: .capable),
        .init(id: "fix-10", prompt: "修复测试 failure", hasProject: true, expectedKind: .bugFix, expectedTier: .capable),

        .init(id: "change-01", prompt: "实现一个导出 CSV 的功能", hasProject: true, expectedKind: .codeChange, expectedTier: .fast),
        .init(id: "change-02", prompt: "修改代码以支持深色模式", hasProject: true, expectedKind: .codeChange, expectedTier: .fast),
        .init(id: "change-03", prompt: "实现通知设置页面", hasProject: true, expectedKind: .codeChange, expectedTier: .fast),
        .init(id: "change-04", prompt: "迁移认证流程", hasProject: true, expectedKind: .codeChange, expectedTier: .capable),
        .init(id: "change-05", prompt: "重构日志架构", hasProject: true, expectedKind: .codeChange, expectedTier: .capable),

        .init(id: "review-01", prompt: "review 当前 diff", hasProject: true, expectedKind: .review, expectedTier: .capable),
        .init(id: "review-02", prompt: "代码审查这个改动", hasProject: true, expectedKind: .review, expectedTier: .capable),
        .init(id: "review-03", prompt: "审查安全风险", hasProject: true, expectedKind: .review, expectedTier: .capable),
        .init(id: "review-04", prompt: "review 这次提交", hasProject: true, expectedKind: .review, expectedTier: .capable),
        .init(id: "review-05", prompt: "检查 diff 是否引入回归", hasProject: true, expectedKind: .review, expectedTier: .capable),

        .init(id: "delivery-01", prompt: "修复 CI 失败并更新 PR", hasProject: true, expectedKind: .deliveryRepair, expectedTier: .capable),
        .init(id: "delivery-02", prompt: "修复 GitHub Actions failure 后交付", hasProject: true, expectedKind: .deliveryRepair, expectedTier: .capable),
        .init(id: "delivery-03", prompt: "修复 PR 的 failing test", hasProject: true, expectedKind: .deliveryRepair, expectedTier: .capable),
        .init(id: "delivery-04", prompt: "修复 CI 报错并 handoff", hasProject: true, expectedKind: .deliveryRepair, expectedTier: .capable),
        .init(id: "delivery-05", prompt: "修复 GitHub Actions 错误并提交 PR", hasProject: true, expectedKind: .deliveryRepair, expectedTier: .capable),

        .init(id: "multimodal-01", prompt: "根据截图修复登录报错", hasAttachments: true, hasProject: true, expectedKind: .multimodalRepair, expectedTier: .capable),
        .init(id: "multimodal-02", prompt: "修复图片里的页面 bug", hasAttachments: true, hasProject: true, expectedKind: .multimodalRepair, expectedTier: .capable),
        .init(id: "multimodal-03", prompt: "根据截图 fix console error", hasAttachments: true, hasProject: true, expectedKind: .multimodalRepair, expectedTier: .capable),
        .init(id: "multimodal-04", prompt: "修复附件展示的错误", hasAttachments: true, hasProject: true, expectedKind: .multimodalRepair, expectedTier: .capable),
        .init(id: "multimodal-05", prompt: "根据页面截图修复 failure", hasAttachments: true, hasProject: true, expectedKind: .multimodalRepair, expectedTier: .capable)
    ]
}

public enum QualityStrategyEvaluator {
    public static func run(_ cases: [QualityStrategyEvalCase]) -> QualityStrategyEvalReport {
        let failed = cases.compactMap { item -> String? in
            let plan = TaskQualityPlanner.plan(item.input)
            return plan.route.kind == item.expectedKind && plan.modelTier == item.expectedTier ? nil : item.id
        }
        return QualityStrategyEvalReport(total: cases.count, passed: cases.count - failed.count, failedCaseIDs: failed)
    }
}
