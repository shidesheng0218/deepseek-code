import Foundation

public struct BrowserAssertion: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let description: String
    public let selector: String
    public let expectedText: String?

    public init(id: String = UUID().uuidString, description: String, selector: String, expectedText: String? = nil) {
        self.id = id
        self.description = description
        self.selector = selector
        self.expectedText = expectedText
    }
}

public struct DeliveryRequirement: Codable, Equatable, Sendable {
    public let repository: String
    public let requiresHandoff: Bool
    public let requiresPullRequest: Bool
    public let requiresCI: Bool

    public init(repository: String, requiresHandoff: Bool = true, requiresPullRequest: Bool = true, requiresCI: Bool = true) {
        self.repository = repository
        self.requiresHandoff = requiresHandoff
        self.requiresPullRequest = requiresPullRequest
        self.requiresCI = requiresCI
    }
}

/// Makes network research a first-class, verifiable part of a task instead of
/// leaving source selection entirely to an unbounded model loop.
public struct WebResearchRequirement: Codable, Equatable, Sendable {
    public let enabled: Bool
    public let requiredSourceCount: Int
    public let allowedDomains: [String]
    public let preferredDomains: [String]
    public let requireOfficialSources: Bool
    public let maxSearches: Int
    public let maxFetches: Int
    public let requireCitations: Bool

    public init(
        enabled: Bool = true,
        requiredSourceCount: Int = 2,
        allowedDomains: [String] = [],
        preferredDomains: [String] = [],
        requireOfficialSources: Bool = false,
        maxSearches: Int = 3,
        maxFetches: Int = 3,
        requireCitations: Bool = true
    ) {
        self.enabled = enabled
        self.requiredSourceCount = min(5, max(1, requiredSourceCount))
        self.allowedDomains = allowedDomains.map { $0.lowercased() }
        self.preferredDomains = preferredDomains.map { $0.lowercased() }
        self.requireOfficialSources = requireOfficialSources
        self.maxSearches = min(3, max(1, maxSearches))
        self.maxFetches = min(5, max(1, maxFetches))
        self.requireCitations = requireCitations
    }
}

public enum ResearchSourceSelector {
    public static func select(_ sources: [WebSourceRecord], requirement: WebResearchRequirement) -> [WebSourceRecord] {
        guard requirement.enabled else { return [] }
        let allowedDomains = Set(requirement.allowedDomains)
        let preferredDomains = Set(requirement.preferredDomains)
        let requireOfficialFirst = requirement.requireOfficialSources && !preferredDomains.isEmpty
        let filtered = sources.filter { source in
            allowedDomains.isEmpty || allowedDomains.contains(source.domain) || allowedDomains.contains { source.domain.hasSuffix(".\($0)") }
        }
        let ordered = filtered.sorted { lhs, rhs in
            let lhsPreferred = preferredDomains.contains(lhs.domain) || preferredDomains.contains { lhs.domain.hasSuffix(".\($0)") }
            let rhsPreferred = preferredDomains.contains(rhs.domain) || preferredDomains.contains { rhs.domain.hasSuffix(".\($0)") }
            if lhsPreferred != rhsPreferred { return lhsPreferred }
            return lhs.rank < rhs.rank
        }
        var selected: [WebSourceRecord] = []
        var seenDomains: Set<String> = []

        for source in ordered where selected.count < requirement.requiredSourceCount {
            let isPreferred = preferredDomains.contains(source.domain) || preferredDomains.contains { source.domain.hasSuffix(".\($0)") }
            if requireOfficialFirst && selected.isEmpty && !isPreferred {
                continue
            }
            guard seenDomains.insert(source.domain).inserted else { continue }
            selected.append(source)
        }
        return selected
    }
}

public enum VerificationRequirement: Codable, Equatable, Sendable {
    case command(String)
    case test(String)
    case lint(String)
    case build(String)
    case browser(BrowserAssertion)
    case review
    case handoff
    case ci

    private enum CodingKeys: String, CodingKey { case kind, value }
    private enum Kind: String, Codable { case command, test, lint, build, browser, review, handoff, ci }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(Kind.self, forKey: .kind)
        switch kind {
        case .command: self = .command(try container.decode(String.self, forKey: .value))
        case .test: self = .test(try container.decode(String.self, forKey: .value))
        case .lint: self = .lint(try container.decode(String.self, forKey: .value))
        case .build: self = .build(try container.decode(String.self, forKey: .value))
        case .browser: self = .browser(try container.decode(BrowserAssertion.self, forKey: .value))
        case .review: self = .review
        case .handoff: self = .handoff
        case .ci: self = .ci
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .command(value): try container.encode(Kind.command, forKey: .kind); try container.encode(value, forKey: .value)
        case let .test(value): try container.encode(Kind.test, forKey: .kind); try container.encode(value, forKey: .value)
        case let .lint(value): try container.encode(Kind.lint, forKey: .kind); try container.encode(value, forKey: .value)
        case let .build(value): try container.encode(Kind.build, forKey: .kind); try container.encode(value, forKey: .value)
        case let .browser(value): try container.encode(Kind.browser, forKey: .kind); try container.encode(value, forKey: .value)
        case .review: try container.encode(Kind.review, forKey: .kind)
        case .handoff: try container.encode(Kind.handoff, forKey: .kind)
        case .ci: try container.encode(Kind.ci, forKey: .kind)
        }
    }

    public var title: String {
        switch self {
        case let .command(value), let .test(value), let .lint(value), let .build(value): value
        case let .browser(assertion): assertion.description
        case .review: "Review"
        case .handoff: "Handoff"
        case .ci: "CI"
        }
    }

    public var evidenceKind: EvidenceKind {
        switch self {
        case .command: .command
        case .test: .test
        case .lint: .lint
        case .build: .build
        case .browser: .browser
        case .review: .review
        case .handoff: .checkpoint
        case .ci: .network
        }
    }
}

public struct TaskContract: Codable, Equatable, Sendable {
    public let goal: String
    public let requiredChanges: [String]
    public let requiredTests: [VerificationRequirement]
    public let requiredBrowserChecks: [BrowserAssertion]
    public let delivery: DeliveryRequirement?
    public let budget: SessionBudget
    public let webResearch: WebResearchRequirement?

    public init(goal: String, requiredChanges: [String] = [], requiredTests: [VerificationRequirement] = [], requiredBrowserChecks: [BrowserAssertion] = [], delivery: DeliveryRequirement? = nil, budget: SessionBudget = SessionBudget(), webResearch: WebResearchRequirement? = nil) {
        self.goal = goal
        self.requiredChanges = requiredChanges
        self.requiredTests = requiredTests
        self.requiredBrowserChecks = requiredBrowserChecks
        self.delivery = delivery
        self.budget = budget
        self.webResearch = webResearch
    }

    /// Compatibility contract for sessions created before the strict delivery
    /// workflow existed. It keeps the user's goal and budget while requiring a
    /// real diff only when the agent actually edits the workspace.
    public static func compatibility(prompt: String, budget: SessionBudget = SessionBudget()) -> TaskContract {
        TaskContract(goal: prompt, budget: budget)
    }
}

public struct DeliveryGateResult: Codable, Equatable, Sendable {
    public let passed: Bool
    public let missingRequirements: [String]
    public let failedEvidence: [String]
    public let unresolvedRisks: [String]

    public init(passed: Bool, missingRequirements: [String] = [], failedEvidence: [String] = [], unresolvedRisks: [String] = []) {
        self.passed = passed
        self.missingRequirements = missingRequirements
        self.failedEvidence = failedEvidence
        self.unresolvedRisks = unresolvedRisks
    }
}

public enum DeliveryGate {
    public static func evaluate(contract: TaskContract, graph: VerificationGraph, hasDiff: Bool, pendingApprovals: Int, indeterminateSideEffects: Int, reviewFindings: [ReviewFinding] = []) -> DeliveryGateResult {
        var missing: [String] = []
        var failures = graph.evidenceRecords.filter { !$0.succeeded }.map { $0.title }
        let passedTitles = Set(graph.nodes.filter { $0.state == .passed }.map(\.title))

        if !contract.requiredChanges.isEmpty && !hasDiff { missing.append("代码 Diff") }
        for requirement in contract.requiredTests where !isSatisfied(requirement, graph: graph, passedTitles: passedTitles) {
            missing.append(requirement.title)
        }
        for assertion in contract.requiredBrowserChecks where !isBrowserAssertionSatisfied(assertion, graph: graph, passedTitles: passedTitles) {
            missing.append("浏览器断言：\(assertion.description)")
        }
        if let research = contract.webResearch, research.enabled {
            let successfulResearch = graph.evidenceRecords.filter { $0.succeeded }
            let fetchedSources = successfulResearch.filter { $0.kind == .webFetch }
            let citations = successfulResearch.filter { $0.kind == .citation }
            if fetchedSources.count < research.requiredSourceCount {
                missing.append("联网研究来源")
            }
            if research.requireCitations && citations.count < research.requiredSourceCount {
                missing.append("联网研究引用")
            }
            if research.requireOfficialSources {
                if research.preferredDomains.isEmpty {
                    missing.append("联网研究官方域名")
                } else {
                    let hasOfficialSource = fetchedSources.contains { evidence in
                        guard let host = URL(string: evidence.detail)?.host?.lowercased() else { return false }
                        return research.preferredDomains.contains { preferred in
                            host == preferred || host.hasSuffix(".\(preferred)")
                        }
                    }
                    if !hasOfficialSource {
                        missing.append("联网研究官方来源")
                    }
                }
            }
        }
        if let delivery = contract.delivery {
            if delivery.requiresHandoff && !passedTitles.contains("Handoff") { missing.append("Handoff") }
            if delivery.requiresPullRequest && !passedTitles.contains("Pull Request") { missing.append("Pull Request") }
            if delivery.requiresCI && !passedTitles.contains("CI") { missing.append("CI") }
        }
        if pendingApprovals > 0 { missing.append("待处理审批") }
        let blockingReview = reviewFindings.filter { $0.severity == .p0 || $0.severity == .p1 }
        if !blockingReview.isEmpty {
            missing.append("处理 P0/P1 Review")
            failures.append(contentsOf: blockingReview.map { "\($0.severity.title): \($0.title)" })
        }
        var risks: [String] = []
        if indeterminateSideEffects > 0 { risks.append("存在结果未知的副作用") }
        if !failures.isEmpty { failures = Array(Set(failures)).sorted() }
        let passed = missing.isEmpty && failures.isEmpty && risks.isEmpty
        return DeliveryGateResult(passed: passed, missingRequirements: Array(Set(missing)).sorted(), failedEvidence: failures, unresolvedRisks: risks)
    }

    private static func isSatisfied(_ requirement: VerificationRequirement, graph: VerificationGraph, passedTitles: Set<String>) -> Bool {
        if passedTitles.contains(requirement.title) { return true }
        let successful = graph.evidenceRecords.filter(\.succeeded)
        switch requirement {
        case let .command(command):
            return successful.contains { $0.kind == .command && $0.title == command }
        case let .test(command):
            return successful.contains { $0.kind == .test && ($0.title == command || $0.detail.localizedCaseInsensitiveContains(command)) }
        case let .lint(command):
            return successful.contains { $0.kind == .lint && ($0.title == command || $0.detail.localizedCaseInsensitiveContains(command)) }
        case let .build(command):
            return successful.contains { $0.kind == .build && ($0.title == command || $0.detail.localizedCaseInsensitiveContains(command)) }
        case .browser:
            return successful.contains { $0.kind == .browser }
        case .review:
            return successful.contains { $0.kind == .review }
        case .handoff:
            return successful.contains { $0.kind == .checkpoint && $0.title.localizedCaseInsensitiveContains("handoff") }
        case .ci:
            return successful.contains { $0.title.localizedCaseInsensitiveContains("ci") && ($0.kind == .network || $0.kind == .command) }
        }
    }

    private static func isBrowserAssertionSatisfied(_ assertion: BrowserAssertion, graph: VerificationGraph, passedTitles: Set<String>) -> Bool {
        passedTitles.contains(assertion.description) || graph.evidenceRecords.contains {
            $0.succeeded && $0.kind == .browser && ($0.title == "Browser assertion:\(assertion.id)" || $0.detail.localizedCaseInsensitiveContains(assertion.description))
        }
    }
}
