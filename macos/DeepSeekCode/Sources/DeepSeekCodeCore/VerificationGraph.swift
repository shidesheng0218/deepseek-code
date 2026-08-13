import Foundation

public enum EvidenceKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case command
    case test
    case lint
    case build
    case browser
    case computer
    case diff
    case review
    case checkpoint
    case terminal
    case network
    case webSearch
    case webFetch
    case citation
    case researchSummary

    public var id: String { rawValue }
}

public enum VerificationEvidenceClassifier {
    public static func kind(tool: String, argumentsJSON: String) -> EvidenceKind {
        if tool.hasPrefix("web.") || tool.hasPrefix("mcp.") || tool.hasPrefix("github.") || tool.hasPrefix("ssh.") {
            return .network
        }
        switch tool {
        case "apply_patch":
            return .diff
        case "inspect_git":
            return .diff
        case "browser_open", "browser_snapshot", "browser_act", "browser_console", "browser.open", "browser.snapshot", "browser.screenshot", "browser.query", "browser.click", "browser.type", "browser.assert", "browser.console", "browser.network":
            return .browser
        case "computer.inspect_app", "computer.snapshot", "computer.find", "computer.click", "computer.type", "computer.key", "computer.capture_window":
            return .computer
        case "terminal.open", "terminal.read", "terminal.write", "terminal.resize", "terminal.signal", "terminal.list", "terminal.attach", "terminal.ports", "terminal.close":
            return .terminal
        case "run_command", "terminal.exec":
            guard let data = argumentsJSON.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let command = object["command"] as? String else {
                return .command
            }
            let value = command.lowercased()
            if value.contains("lint") || value.contains("format --check") || value.contains("swiftformat") {
                return .lint
            }
            if value.contains("test") || value.contains("pytest") || value.contains("cargo test") || value.contains("go test") || value.contains("xcodebuild test") {
                return .test
            }
            if value.contains("build") || value.contains("xcodebuild") || value.contains("swift build") || value.contains("cargo build") {
                return .build
            }
            return .command
        case "web.search", "web.fetch":
            return .network
        default:
            return .checkpoint
        }
    }

    /// Gives verification records domain names instead of low-level tool
    /// identifiers, allowing TaskContract requirements to match durable
    /// evidence after a restart.
    public static func title(tool: String, argumentsJSON: String) -> String {
        switch tool {
        case "run_command", "terminal.exec":
            guard let data = argumentsJSON.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let command = object["command"] as? String,
                  !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return tool
            }
            return command
        case "apply_patch": return "代码 Diff"
        case "github.create_pr": return "Pull Request"
        case "github.pr_checks": return "CI"
        case "github.ci_logs": return "CI 日志"
        case "browser.assert":
            guard let data = argumentsJSON.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let description = object["description"] as? String,
                  !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return "浏览器验证"
            }
            return description
        case "browser.snapshot", "browser.screenshot", "browser.query", "browser.click", "browser.type": return "浏览器验证"
        case "terminal.open", "terminal.read", "terminal.write", "terminal.resize", "terminal.signal", "terminal.list", "terminal.attach", "terminal.ports", "terminal.close": return "Terminal"
        default: return tool
        }
    }
}

public struct BrowserSnapshot: Codable, Equatable, Sendable {
    public let snapshotVersion: Int
    public let url: String
    public let title: String
    public let domText: String
    public let accessibilityTree: String
    public let consoleErrors: [String]
    public let networkFailures: [String]
    public let capturedAt: Date

    public init(
        url: String,
        title: String,
        domText: String,
        accessibilityTree: String,
        consoleErrors: [String] = [],
        networkFailures: [String] = [],
        capturedAt: Date = Date(),
        snapshotVersion: Int = 0
    ) {
        self.url = url
        self.title = title
        self.domText = domText
        self.accessibilityTree = accessibilityTree
        self.consoleErrors = consoleErrors
        self.networkFailures = networkFailures
        self.capturedAt = capturedAt
        self.snapshotVersion = snapshotVersion
    }

    private enum CodingKeys: String, CodingKey { case snapshotVersion, url, title, domText, accessibilityTree, consoleErrors, networkFailures, capturedAt }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.snapshotVersion = try container.decodeIfPresent(Int.self, forKey: .snapshotVersion) ?? 0
        self.url = try container.decode(String.self, forKey: .url)
        self.title = try container.decode(String.self, forKey: .title)
        self.domText = try container.decode(String.self, forKey: .domText)
        self.accessibilityTree = try container.decode(String.self, forKey: .accessibilityTree)
        self.consoleErrors = try container.decodeIfPresent([String].self, forKey: .consoleErrors) ?? []
        self.networkFailures = try container.decodeIfPresent([String].self, forKey: .networkFailures) ?? []
        self.capturedAt = try container.decodeIfPresent(Date.self, forKey: .capturedAt) ?? Date()
    }

    public func nextVersion() -> BrowserSnapshot {
        BrowserSnapshot(url: url, title: title, domText: domText, accessibilityTree: accessibilityTree, consoleErrors: consoleErrors, networkFailures: networkFailures, capturedAt: capturedAt, snapshotVersion: snapshotVersion + 1)
    }

    public func canPerform(actionSnapshotVersion: Int) -> Bool {
        actionSnapshotVersion == snapshotVersion
    }

    public var hasIssues: Bool {
        !consoleErrors.isEmpty || !networkFailures.isEmpty
    }

    public var issueCount: Int {
        consoleErrors.count + networkFailures.count
    }
}

public struct BrowserActionRecord: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let tool: String
    public let selector: String?
    public let snapshotVersion: Int
    public let succeeded: Bool
    public let detail: String
    public let createdAt: Date

    public init(id: String = UUID().uuidString, tool: String, selector: String? = nil, snapshotVersion: Int, succeeded: Bool, detail: String = "", createdAt: Date = Date()) {
        self.id = id
        self.tool = tool
        self.selector = selector
        self.snapshotVersion = snapshotVersion
        self.succeeded = succeeded
        self.detail = detail
        self.createdAt = createdAt
    }
}

public struct BrowserEvidenceBundle: Codable, Equatable, Sendable {
    public let url: String
    public let title: String
    public let domSummary: String
    public let accessibilityTree: String
    public let consoleErrors: [String]
    public let networkFailures: [String]
    public let screenshotPath: String?
    public let actions: [BrowserActionRecord]
    public let passedAssertions: [String]
    public let failedAssertions: [String]
    public let sourceTerminalID: String?
    public let capturedAt: Date

    public init(url: String, title: String, domSummary: String, accessibilityTree: String, consoleErrors: [String] = [], networkFailures: [String] = [], screenshotPath: String? = nil, actions: [BrowserActionRecord] = [], passedAssertions: [String] = [], failedAssertions: [String] = [], sourceTerminalID: String? = nil, capturedAt: Date = Date()) {
        self.url = url
        self.title = title
        self.domSummary = domSummary
        self.accessibilityTree = accessibilityTree
        self.consoleErrors = consoleErrors
        self.networkFailures = networkFailures
        self.screenshotPath = screenshotPath
        self.actions = actions
        self.passedAssertions = passedAssertions
        self.failedAssertions = failedAssertions
        self.sourceTerminalID = sourceTerminalID
        self.capturedAt = capturedAt
    }

    private enum CodingKeys: String, CodingKey { case url, title, domSummary, accessibilityTree, consoleErrors, networkFailures, screenshotPath, actions, passedAssertions, failedAssertions, sourceTerminalID, capturedAt }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.url = try container.decode(String.self, forKey: .url)
        self.title = try container.decodeIfPresent(String.self, forKey: .title) ?? ""
        self.domSummary = try container.decodeIfPresent(String.self, forKey: .domSummary) ?? ""
        self.accessibilityTree = try container.decodeIfPresent(String.self, forKey: .accessibilityTree) ?? ""
        self.consoleErrors = try container.decodeIfPresent([String].self, forKey: .consoleErrors) ?? []
        self.networkFailures = try container.decodeIfPresent([String].self, forKey: .networkFailures) ?? []
        self.screenshotPath = try container.decodeIfPresent(String.self, forKey: .screenshotPath)
        self.actions = try container.decodeIfPresent([BrowserActionRecord].self, forKey: .actions) ?? []
        self.passedAssertions = try container.decodeIfPresent([String].self, forKey: .passedAssertions) ?? []
        self.failedAssertions = try container.decodeIfPresent([String].self, forKey: .failedAssertions) ?? []
        self.sourceTerminalID = try container.decodeIfPresent(String.self, forKey: .sourceTerminalID)
        self.capturedAt = try container.decodeIfPresent(Date.self, forKey: .capturedAt) ?? Date()
    }

    public static func fromToolOutput(_ output: String, tool: String) -> BrowserEvidenceBundle? {
        guard let data = output.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["ok"] as? Bool != false,
              let url = object["url"] as? String else { return nil }
        let version = object["snapshotVersion"] as? Int ?? 0
        let selector = object["selector"] as? String
        let action = BrowserActionRecord(
            tool: tool,
            selector: selector,
            snapshotVersion: version,
            succeeded: true,
            detail: object["description"] as? String ?? ""
        )
        return BrowserEvidenceBundle(
            url: url,
            title: object["title"] as? String ?? "",
            domSummary: object["domText"] as? String ?? object["domSummary"] as? String ?? "",
            accessibilityTree: object["accessibilityTree"] as? String ?? "",
            consoleErrors: object["consoleErrors"] as? [String] ?? [],
            networkFailures: object["networkFailures"] as? [String] ?? [],
            screenshotPath: object["path"] as? String,
            actions: [action],
            passedAssertions: (object["description"] as? String).map { [$0] } ?? [],
            failedAssertions: []
        )
    }

    public var succeeded: Bool {
        failedAssertions.isEmpty && consoleErrors.isEmpty && networkFailures.isEmpty && actions.allSatisfy(\.succeeded)
    }
}

public struct EvidenceRecord: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let taskID: String
    public let kind: EvidenceKind
    public let title: String
    public let detail: String
    public let succeeded: Bool
    public let createdAt: Date

    public init(id: String = UUID().uuidString, taskID: String, kind: EvidenceKind, title: String, detail: String, succeeded: Bool, createdAt: Date = Date()) {
        self.id = id
        self.taskID = taskID
        self.kind = kind
        self.title = title
        self.detail = detail
        self.succeeded = succeeded
        self.createdAt = createdAt
    }
}

public struct VerificationNode: Codable, Equatable, Identifiable, Sendable {
    public enum State: String, Codable, Sendable {
        case pending
        case running
        case passed
        case failed
        case skipped
    }

    public let id: String
    public let title: String
    public var state: State
    public var evidenceIDs: [String]

    public init(id: String = UUID().uuidString, title: String, state: State = .pending, evidenceIDs: [String] = []) {
        self.id = id
        self.title = title
        self.state = state
        self.evidenceIDs = evidenceIDs
    }
}

public struct VerificationGraph: Codable, Equatable, Sendable {
    public let taskID: String
    public private(set) var nodes: [VerificationNode]
    public private(set) var evidenceRecords: [EvidenceRecord]

    public init(taskID: String, nodes: [VerificationNode] = [], evidenceRecords: [EvidenceRecord] = []) {
        self.taskID = taskID
        self.nodes = nodes
        self.evidenceRecords = evidenceRecords
    }

    public mutating func append(evidence: EvidenceRecord) {
        guard evidence.taskID == taskID else { return }
        evidenceRecords.append(evidence)
    }

    public mutating func append(node: VerificationNode) {
        nodes.append(node)
    }

    public var passedCount: Int {
        nodes.filter { $0.state == .passed }.count
    }

    public func evidence(for id: String) -> EvidenceRecord? {
        evidenceRecords.first { $0.id == id }
    }

    /// Rebuilds verification evidence from the durable event stream. The
    /// projector deliberately recognizes delivery events as first-class
    /// evidence so a restart cannot make a previously-created PR or CI result
    /// disappear from the delivery gate.
    public static func project(taskID: String, events: [SessionEvent]) -> VerificationGraph {
        var graph = VerificationGraph(taskID: taskID)
        var seen: Set<String> = []
        func append(_ evidence: EvidenceRecord) {
            if seen.contains(evidence.id) {
                graph.evidenceRecords.removeAll { $0.id == evidence.id }
                graph.nodes.removeAll { $0.evidenceIDs.contains(evidence.id) }
            } else {
                seen.insert(evidence.id)
            }
            graph.append(evidence: evidence)
            graph.append(node: VerificationNode(id: "evidence-\(evidence.id)", title: evidence.title, state: evidence.succeeded ? .passed : .failed, evidenceIDs: [evidence.id]))
        }

        for event in events.sorted(by: { $0.sequence < $1.sequence }) {
            let payload = event.payload
            switch event.type {
            case "evidence_recorded":
                let kind = EvidenceKind(rawValue: payload["kind"] ?? "command") ?? .command
                append(EvidenceRecord(id: payload["id"] ?? "event-\(event.sequence)", taskID: taskID, kind: kind, title: payload["title"] ?? "Evidence", detail: payload["detail"] ?? "", succeeded: payload["succeeded"] == "true", createdAt: event.timestamp))
            case "github_pr_created":
                append(EvidenceRecord(id: payload["deliveryID"] ?? "pr-\(event.sequence)", taskID: taskID, kind: .network, title: "Pull Request", detail: payload["url"] ?? "PR created", succeeded: true, createdAt: event.timestamp))
            case "github_ci_evidence":
                let state = payload["state"] ?? "pending"
                append(EvidenceRecord(id: payload["deliveryID"].map { "ci-\($0)" } ?? "ci-default", taskID: taskID, kind: .network, title: "CI", detail: payload["detail"] ?? state, succeeded: state == "passed", createdAt: event.timestamp))
            case "handoff_applied":
                append(EvidenceRecord(id: payload["handoffID"] ?? "handoff-\(event.sequence)", taskID: taskID, kind: .checkpoint, title: "Handoff", detail: payload["files"] ?? "Handoff applied", succeeded: true, createdAt: event.timestamp))
            case "browser_evidence_recorded":
                let bundle = payload["bundle"].flatMap { Data($0.utf8) }.flatMap { try? JSONDecoder().decode(BrowserEvidenceBundle.self, from: $0) }
                append(EvidenceRecord(id: "browser-\(event.sequence)", taskID: taskID, kind: .browser, title: "浏览器验证", detail: bundle?.url ?? "Browser evidence", succeeded: bundle?.succeeded ?? false, createdAt: event.timestamp))
            case "web_evidence_recorded":
                let evidence = payload["evidence"].flatMap { Data($0.utf8) }.flatMap { try? JSONDecoder().decode(WebEvidence.self, from: $0) }
                guard let evidence else {
                    append(EvidenceRecord(id: "web-\(event.sequence)", taskID: taskID, kind: .network, title: "Web Evidence", detail: "无法解析网页证据", succeeded: false, createdAt: event.timestamp))
                    continue
                }
                if let sourceID = evidence.sourceID {
                    let domain = evidence.sources.first(where: { $0.id == sourceID })?.domain ?? URL(string: evidence.finalURL)?.host ?? "外部来源"
                    append(EvidenceRecord(id: "web-fetch-\(event.sequence)", taskID: taskID, kind: .webFetch, title: "网页读取：\(domain)", detail: evidence.finalURL, succeeded: true, createdAt: event.timestamp))
                } else if !evidence.sources.isEmpty {
                    for source in evidence.sources {
                        append(EvidenceRecord(id: "web-search-\(event.sequence)-\(source.id)", taskID: taskID, kind: .webSearch, title: "来源：\(source.domain)", detail: source.canonicalURL, succeeded: true, createdAt: event.timestamp))
                    }
                } else {
                    append(EvidenceRecord(id: "web-\(event.sequence)", taskID: taskID, kind: .network, title: evidence.title ?? "Web Evidence", detail: evidence.finalURL, succeeded: true, createdAt: event.timestamp))
                }
                for citation in evidence.citations where !citation.quote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    append(EvidenceRecord(id: "citation-\(event.sequence)-\(citation.id)", taskID: taskID, kind: .citation, title: "引用：\(citation.sourceID)", detail: citation.quote, succeeded: true, createdAt: event.timestamp))
                }
            case "research_summary_generated":
                append(EvidenceRecord(id: payload["evidenceID"] ?? "research-summary-\(event.sequence)", taskID: taskID, kind: .researchSummary, title: "联网研究结论", detail: payload["summary"] ?? "Research summary", succeeded: payload["succeeded"] != "false", createdAt: event.timestamp))
            case "terminal_completed", "terminal_failed", "terminal_indeterminate", "terminal_attached", "terminal_portDiscovered", "terminal_output_persisted":
                let succeeded = event.type == "terminal_completed" || event.type == "terminal_attached" || event.type == "terminal_portDiscovered" || event.type == "terminal_output_persisted"
                let title = event.type == "terminal_portDiscovered" ? "Terminal 端口" : "Terminal"
                append(EvidenceRecord(id: "terminal-\(event.sequence)", taskID: taskID, kind: .terminal, title: title, detail: payload["detail"] ?? event.type, succeeded: succeeded, createdAt: event.timestamp))
            default:
                continue
            }
        }
        return graph
    }
}
