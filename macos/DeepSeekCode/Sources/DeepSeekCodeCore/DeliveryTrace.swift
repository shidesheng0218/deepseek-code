import Foundation

/// Immutable projection linking the evidence generated across Terminal,
/// Browser, tests, review, GitHub and CI for a single delivery attempt.
public struct DeliveryTrace: Codable, Equatable, Sendable {
    public let sessionID: String
    public let worktreeID: String?
    public let terminalIDs: [String]
    public let ports: [Int]
    public let browserEvidenceIDs: [String]
    public let testEvidenceIDs: [String]
    public let reviewEvidenceIDs: [String]
    public let commitSHA: String?
    public let pullRequestID: String?
    public let ciRunIDs: [String]

    public init(sessionID: String, worktreeID: String? = nil, terminalIDs: [String] = [], ports: [Int] = [], browserEvidenceIDs: [String] = [], testEvidenceIDs: [String] = [], reviewEvidenceIDs: [String] = [], commitSHA: String? = nil, pullRequestID: String? = nil, ciRunIDs: [String] = []) {
        self.sessionID = sessionID
        self.worktreeID = worktreeID
        self.terminalIDs = terminalIDs
        self.ports = ports
        self.browserEvidenceIDs = browserEvidenceIDs
        self.testEvidenceIDs = testEvidenceIDs
        self.reviewEvidenceIDs = reviewEvidenceIDs
        self.commitSHA = commitSHA
        self.pullRequestID = pullRequestID
        self.ciRunIDs = ciRunIDs
    }

    public static func project(sessionID: String, events: [SessionEvent]) -> DeliveryTrace {
        var worktreeID: String?
        var terminals: Set<String> = []
        var ports: Set<Int> = []
        var browser: Set<String> = []
        var tests: Set<String> = []
        var reviews: Set<String> = []
        var commitSHA: String?
        var prID: String?
        var ci: Set<String> = []

        for event in events.sorted(by: { $0.sequence < $1.sequence }) {
            let payload = event.payload
            switch event.type {
            case "worktree_created", "worktree_ready":
                worktreeID = payload["worktreeID"] ?? payload["worktreePath"] ?? worktreeID
            case "terminal_started", "terminal_opened", "terminal_completed", "terminal_portDiscovered", "terminal_output_persisted":
                if let terminalID = payload["terminalID"], !terminalID.isEmpty { terminals.insert(terminalID) }
                if let port = Int(payload["port"] ?? "") { ports.insert(port) }
            case "browser_evidence_recorded":
                browser.insert(payload["browserSessionID"] ?? payload["bundleID"] ?? "browser-\(event.id.uuidString)")
            case "evidence_recorded":
                let id = payload["id"] ?? "evidence-\(event.id.uuidString)"
                let kind = EvidenceKind(rawValue: payload["kind"] ?? "")
                if kind == .test { tests.insert(id) }
                if kind == .review { reviews.insert(id) }
            case "review_completed":
                reviews.insert(payload["evidenceID"] ?? "review-\(event.id.uuidString)")
            case "git_commit_created", "commit_created":
                commitSHA = payload["sha"] ?? payload["commit"] ?? commitSHA
            case "github_pr_created":
                prID = payload["deliveryID"] ?? payload["number"] ?? prID
            case "github_ci_evidence":
                if let value = payload["deliveryID"] ?? payload["runID"], !value.isEmpty { ci.insert(value) }
            default:
                continue
            }
        }
        return DeliveryTrace(
            sessionID: sessionID,
            worktreeID: worktreeID,
            terminalIDs: terminals.sorted(),
            ports: ports.sorted(),
            browserEvidenceIDs: browser.sorted(),
            testEvidenceIDs: tests.sorted(),
            reviewEvidenceIDs: reviews.sorted(),
            commitSHA: commitSHA,
            pullRequestID: prID,
            ciRunIDs: ci.sorted()
        )
    }
}
