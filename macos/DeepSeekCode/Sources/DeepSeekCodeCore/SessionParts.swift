import Foundation

/// Stable, projection-only units rendered by the conversation timeline. They
/// are never a second source of truth: every value is rebuildable from the
/// durable session event log.
public enum SessionPartKind: String, Codable, CaseIterable, Sendable {
    case user
    case assistantText
    case reasoning
    case toolCall
    case approval
    case step
    case patch
    case workerResult
    case verification
    case usage
}

public enum SessionPartState: String, Codable, CaseIterable, Sendable {
    case idle
    case running
    case waiting
    case completed
    case failed
    case indeterminate
    case info
}

public struct SessionPart: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let sessionID: String
    public let kind: SessionPartKind
    public var state: SessionPartState
    public var title: String
    public var text: String
    public var eventIDs: [String]
    public var evidenceIDs: [String]
    public var toolCallID: String?
    public let firstSequence: Int
    public var lastSequence: Int
    public let createdAt: Date
    public var updatedAt: Date

    public init(
        id: String,
        sessionID: String,
        kind: SessionPartKind,
        state: SessionPartState = .idle,
        title: String = "",
        text: String = "",
        eventIDs: [String],
        evidenceIDs: [String] = [],
        toolCallID: String? = nil,
        firstSequence: Int,
        lastSequence: Int? = nil,
        createdAt: Date,
        updatedAt: Date? = nil
    ) {
        self.id = id
        self.sessionID = sessionID
        self.kind = kind
        self.state = state
        self.title = title
        self.text = text
        self.eventIDs = eventIDs
        self.evidenceIDs = evidenceIDs
        self.toolCallID = toolCallID
        self.firstSequence = firstSequence
        self.lastSequence = lastSequence ?? firstSequence
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
    }
}

public enum SessionPartProjector {
    public static func project(events: [SessionEvent]) -> [SessionPart] {
        var parts: [SessionPart] = []
        var toolIndexes: [String: Int] = [:]
        var approvalIndexes: [String: Int] = [:]

        func eventID(_ event: SessionEvent) -> String { event.id.uuidString }

        func appendPart(
            id: String,
            event: SessionEvent,
            kind: SessionPartKind,
            state: SessionPartState = .idle,
            title: String = "",
            text: String = "",
            toolCallID: String? = nil,
            evidenceIDs: [String] = []
        ) {
            parts.append(SessionPart(
                id: id,
                sessionID: event.sessionID,
                kind: kind,
                state: state,
                title: title,
                text: text,
                eventIDs: [eventID(event)],
                evidenceIDs: evidenceIDs,
                toolCallID: toolCallID,
                firstSequence: event.sequence,
                createdAt: event.timestamp
            ))
        }

        func updatePart(_ index: Int, event: SessionEvent, state: SessionPartState? = nil, text: String? = nil, title: String? = nil, evidenceID: String? = nil) {
            guard parts.indices.contains(index) else { return }
            parts[index].eventIDs.append(eventID(event))
            parts[index].lastSequence = event.sequence
            parts[index].updatedAt = event.timestamp
            if let state { parts[index].state = state }
            if let text { parts[index].text = text }
            if let title { parts[index].title = title }
            if let evidenceID, !evidenceID.isEmpty, !parts[index].evidenceIDs.contains(evidenceID) {
                parts[index].evidenceIDs.append(evidenceID)
            }
        }

        func appendOrUpdateText(event: SessionEvent, kind: SessionPartKind, title: String, text: String) {
            guard !text.isEmpty else { return }
            if let index = parts.indices.last, parts[index].kind == kind, parts[index].state == .running || parts[index].state == .idle {
                parts[index].text += text
                updatePart(index, event: event, state: .running)
                return
            }
            let prefix = kind == .assistantText ? "assistant" : "reasoning"
            appendPart(id: "\(prefix)-\(eventID(event))", event: event, kind: kind, state: .running, title: title, text: text)
        }

        for event in events.sorted(by: { $0.sequence < $1.sequence }) {
            let payload = event.payload
            switch event.type {
            case "user_message":
                let text = payload["text"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                guard !text.isEmpty else { continue }
                appendPart(id: "user-\(eventID(event))", event: event, kind: .user, state: .completed, text: text)
            case "assistant_text":
                appendOrUpdateText(event: event, kind: .assistantText, title: "DeepSeek", text: payload["text"] ?? "")
            case "assistant_reasoning":
                appendOrUpdateText(event: event, kind: .reasoning, title: "思考", text: payload["text"] ?? "")
            case "agent_completed", "session_turn_completed":
                if let index = parts.indices.last, parts[index].kind == .assistantText, parts[index].state == .running {
                    updatePart(index, event: event, state: .completed)
                }
            case "tool_requested", "tool_started", "tool_completed", "tool_failed", "tool_blocked", "tool_indeterminate":
                let callID = payload["callID"] ?? "event-\(eventID(event))"
                let tool = payload["tool"] ?? "工具"
                let index = toolIndexes[callID]
                switch event.type {
                case "tool_requested":
                    appendPart(id: "tool-\(callID)", event: event, kind: .toolCall, state: .waiting, title: tool, text: "等待执行", toolCallID: callID)
                    toolIndexes[callID] = parts.indices.last
                case "tool_started":
                    if let index {
                        updatePart(index, event: event, state: .running, text: "执行中")
                    } else {
                        appendPart(id: "tool-\(callID)", event: event, kind: .toolCall, state: .running, title: tool, text: "执行中", toolCallID: callID)
                        toolIndexes[callID] = parts.indices.last
                    }
                case "tool_completed":
                    let succeeded = payload["ok"] != "false"
                    let state: SessionPartState = succeeded ? .completed : .failed
                    let text = succeeded ? "已完成" : "执行失败"
                    if let index {
                        updatePart(index, event: event, state: state, text: text, evidenceID: payload["evidenceID"])
                    } else {
                        appendPart(id: "tool-\(callID)", event: event, kind: .toolCall, state: state, title: tool, text: text, toolCallID: callID)
                        toolIndexes[callID] = parts.indices.last
                    }
                case "tool_indeterminate":
                    if let index {
                        updatePart(index, event: event, state: .indeterminate, text: payload["reason"] ?? "执行结果未知")
                    } else {
                        appendPart(id: "tool-\(callID)", event: event, kind: .toolCall, state: .indeterminate, title: tool, text: payload["reason"] ?? "执行结果未知", toolCallID: callID)
                        toolIndexes[callID] = parts.indices.last
                    }
                default:
                    if let index {
                        updatePart(index, event: event, state: .failed, text: event.type == "tool_blocked" ? "已被权限策略阻止" : "执行失败")
                    } else {
                        appendPart(id: "tool-\(callID)", event: event, kind: .toolCall, state: .failed, title: tool, text: event.type == "tool_blocked" ? "已被权限策略阻止" : "执行失败", toolCallID: callID)
                        toolIndexes[callID] = parts.indices.last
                    }
                }
            case "approval_requested", "approval_resolved":
                let approvalID = payload["approvalID"] ?? "event-\(eventID(event))"
                if event.type == "approval_requested" {
                    let tool = payload["tool"] ?? "工具"
                    let risk = payload["risk"].map { " · \($0)" } ?? ""
                    appendPart(id: "approval-\(approvalID)", event: event, kind: .approval, state: .waiting, title: "需要审批", text: "\(tool)\(risk)")
                    approvalIndexes[approvalID] = parts.indices.last
                } else if let index = approvalIndexes[approvalID] {
                    let allowed = payload["decision"] != ApprovalDecision.deny.rawValue
                    updatePart(index, event: event, state: allowed ? .completed : .failed, text: allowed ? "已允许" : "已拒绝")
                } else {
                    appendPart(id: "approval-\(approvalID)", event: event, kind: .approval, state: .info, title: "审批已恢复", text: payload["decision"] ?? "已处理")
                }
            case "worker_result_adopted", "worker_evidence_adopted", "worker_completed", "worker_failed", "worker_session_needs_attention":
                let succeeded = event.type != "worker_failed"
                let state: SessionPartState = event.type == "worker_session_needs_attention" ? .indeterminate : (succeeded ? .completed : .failed)
                appendPart(id: "worker-\(eventID(event))", event: event, kind: .workerResult, state: state, title: payload["workerKind"] ?? "Worker", text: payload["summary"] ?? payload["message"] ?? payload["reason"] ?? "Worker 已完成", evidenceIDs: payload["evidenceIDs"]?.split(separator: ",").map(String.init) ?? [])
            case "usage_recorded":
                let model = payload["model"] ?? "模型"
                let output = payload["output"] ?? "0"
                appendPart(id: "usage-\(eventID(event))", event: event, kind: .usage, state: .info, title: model, text: "输出 \(output) tokens")
            case "verification_gate_evaluated", "browser_evidence_recorded", "review_completed", "handoff_applied", "github_pr_created", "github_ci_evidence", "agent_failed", "research_failed", "research_summary_generated":
                let failed = event.type == "agent_failed" || event.type == "research_failed" || payload["passed"] == "false" || payload["state"] == "failed"
                appendPart(id: "verification-\(eventID(event))", event: event, kind: .verification, state: failed ? .failed : .completed, title: verificationTitle(for: event.type), text: verificationText(for: event))
            default:
                continue
            }
        }

        return parts
    }

    private static func verificationTitle(for type: String) -> String {
        switch type {
        case "verification_gate_evaluated": "交付门禁"
        case "browser_evidence_recorded": "浏览器验证"
        case "review_completed": "代码审查"
        case "handoff_applied": "Handoff"
        case "github_pr_created": "Pull Request"
        case "github_ci_evidence": "GitHub Actions CI"
        case "agent_failed": "执行失败"
        case "research_failed": "研究失败"
        case "research_summary_generated": "联网研究结论"
        default: "验证"
        }
    }

    private static func verificationText(for event: SessionEvent) -> String {
        event.payload["detail"]
            ?? event.payload["message"]
            ?? event.payload["summary"]
            ?? event.payload["missing"]?.replacingOccurrences(of: "|", with: " · ")
            ?? "已记录验证证据"
    }
}
