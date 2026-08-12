import Foundation

public enum ConversationRole: String, Codable, Sendable {
    case user
    case assistant
}

public struct ConversationMessage: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let role: ConversationRole
    public var text: String
    public var attachments: [AttachmentRef]
    public let createdAt: Date

    public init(id: String = UUID().uuidString, role: ConversationRole, text: String, attachments: [AttachmentRef] = [], createdAt: Date = Date()) {
        self.id = id
        self.role = role
        self.text = text
        self.attachments = attachments
        self.createdAt = createdAt
    }
}

/// A single, chronologically ordered item in the task conversation. It keeps
/// human turns, Agent output, execution, approvals and delivery evidence on
/// one axis instead of splitting them into unrelated message/activity lists.
public enum ConversationEntryKind: String, Codable, CaseIterable, Sendable {
    case user
    case assistant
    case tool
    case approval
    case verification
}

public enum ConversationEntryState: String, Codable, Sendable {
    case idle
    case running
    case waiting
    case completed
    case failed
    case info
}

public struct ConversationEntry: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let kind: ConversationEntryKind
    public var title: String
    public var text: String
    public var state: ConversationEntryState
    public var attachments: [AttachmentRef]
    public var toolCallID: String?
    public let createdAt: Date

    public init(id: String = UUID().uuidString, kind: ConversationEntryKind, title: String = "", text: String = "", state: ConversationEntryState = .idle, attachments: [AttachmentRef] = [], toolCallID: String? = nil, createdAt: Date = Date()) {
        self.id = id
        self.kind = kind
        self.title = title
        self.text = text
        self.state = state
        self.attachments = attachments
        self.toolCallID = toolCallID
        self.createdAt = createdAt
    }
}

/// A compact, localized status description shared by conversation chrome and
/// the task timeline. Keeping this mapping in Core prevents the same Session
/// state from being described differently across surfaces.
public struct ConversationStatusDescriptor: Equatable, Sendable {
    public let title: String
    public let systemImage: String
    public let colorToken: String

    public init(title: String, systemImage: String, colorToken: String) {
        self.title = title
        self.systemImage = systemImage
        self.colorToken = colorToken
    }
}

public enum ConversationStatusPresentation {
    public static func descriptor(for status: SessionStatus) -> ConversationStatusDescriptor {
        switch status {
        case .created, .planning:
            ConversationStatusDescriptor(title: "准备中", systemImage: "list.bullet", colorToken: "blue")
        case .awaitingPlanApproval:
            ConversationStatusDescriptor(title: "确认计划", systemImage: "list.clipboard", colorToken: "amber")
        case .executing, .running:
            ConversationStatusDescriptor(title: "处理中", systemImage: "waveform.path.ecg", colorToken: "mint")
        case .waiting:
            ConversationStatusDescriptor(title: "等待中", systemImage: "pause", colorToken: "secondary")
        case .awaitingToolApproval, .awaitingApproval, .awaitingDeliveryApproval:
            ConversationStatusDescriptor(title: "需要审批", systemImage: "hand.raised", colorToken: "amber")
        case .verifying:
            ConversationStatusDescriptor(title: "验证中", systemImage: "checklist", colorToken: "blue")
        case .handoffReady:
            ConversationStatusDescriptor(title: "待交付", systemImage: "arrow.right.circle", colorToken: "purple")
        case .delivering:
            ConversationStatusDescriptor(title: "交付中", systemImage: "arrow.up.circle", colorToken: "purple")
        case .needsRepair:
            ConversationStatusDescriptor(title: "需要修复", systemImage: "wrench.and.screwdriver", colorToken: "red")
        case .needsAttention:
            ConversationStatusDescriptor(title: "需要处理", systemImage: "exclamationmark.triangle", colorToken: "red")
        case .needsReview:
            ConversationStatusDescriptor(title: "等待审查", systemImage: "eye", colorToken: "amber")
        case .delivered, .completed:
            ConversationStatusDescriptor(title: "已交付", systemImage: "checkmark", colorToken: "green")
        case .failed:
            ConversationStatusDescriptor(title: "执行失败", systemImage: "xmark", colorToken: "red")
        }
    }
}

public enum ConversationProjector {
    /// Projection refreshes are allowed to receive overlapping deltas. Keep
    /// the first stable entry for an ID so SwiftUI never renders duplicate
    /// cards when an observer and a full refresh arrive together.
    public static func deduplicatedTimeline(_ entries: [ConversationEntry]) -> [ConversationEntry] {
        var seen: Set<String> = []
        return entries.filter { entry in
            guard seen.insert(entry.id).inserted else { return false }
            return true
        }
    }

    /// Compatibility projection for existing SwiftUI timeline views. Stable
    /// part IDs prevent duplicate cards when the projection refreshes.
    public static func timeline(parts: [SessionPart]) -> [ConversationEntry] {
        let entries = parts.sorted {
            $0.firstSequence == $1.firstSequence ? $0.id < $1.id : $0.firstSequence < $1.firstSequence
        }.map { part in
            let kind: ConversationEntryKind
            switch part.kind {
            case .user: kind = .user
            case .assistantText, .reasoning, .step, .patch: kind = .assistant
            case .toolCall: kind = .tool
            case .approval: kind = .approval
            case .workerResult, .verification, .usage: kind = .verification
            }
            let state: ConversationEntryState
            switch part.state {
            case .idle: state = .idle
            case .running: state = .running
            case .waiting, .indeterminate: state = .waiting
            case .completed: state = .completed
            case .failed: state = .failed
            case .info: state = .info
            }
            return ConversationEntry(
                id: part.id,
                kind: kind,
                title: part.title,
                text: part.text,
                state: state,
                toolCallID: part.toolCallID,
                createdAt: part.createdAt
            )
        }
        return deduplicatedTimeline(entries)
    }

    public static func project(events: [SessionEvent]) -> [ConversationMessage] {
        var messages: [ConversationMessage] = []
        for event in events.sorted(by: { $0.sequence < $1.sequence }) {
            switch event.type {
            case "user_message":
                let text = event.payload["text"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                guard !text.isEmpty else { continue }
                let attachments: [AttachmentRef]
                if let encoded = event.payload["attachmentsJSON"], let data = encoded.data(using: .utf8), let decoded = try? JSONDecoder().decode([AttachmentRef].self, from: data) {
                    attachments = decoded
                } else {
                    attachments = []
                }
                messages.append(ConversationMessage(id: "user-\(event.id.uuidString)", role: .user, text: text, attachments: attachments, createdAt: event.timestamp))
            case "assistant_text":
                let text = event.payload["text"] ?? ""
                guard !text.isEmpty else { continue }
                if let index = messages.lastIndex(where: { $0.role == .assistant }), index == messages.count - 1 {
                    messages[index].text += text
                } else {
                    messages.append(ConversationMessage(id: "assistant-\(event.id.uuidString)", role: .assistant, text: text, createdAt: event.timestamp))
                }
            default:
                continue
            }
        }
        return messages
    }

    public static func timeline(events: [SessionEvent]) -> [ConversationEntry] {
        var entries: [ConversationEntry] = []

        func decodedAttachments(_ event: SessionEvent) -> [AttachmentRef] {
            guard let encoded = event.payload["attachmentsJSON"],
                  let data = encoded.data(using: .utf8) else { return [] }
            return (try? JSONDecoder().decode([AttachmentRef].self, from: data)) ?? []
        }

        func appendVerification(event: SessionEvent, title: String, text: String, state: ConversationEntryState = .completed) {
            entries.append(ConversationEntry(id: "verification-\(event.id.uuidString)", kind: .verification, title: title, text: text, state: state, createdAt: event.timestamp))
        }

        func updateLatestTool(_ tool: String, callID: String?, state: ConversationEntryState, text: String) {
            let index = entries.lastIndex {
                guard $0.kind == .tool, $0.title == tool else { return false }
                if let callID { return $0.toolCallID == callID }
                return $0.state == .running
            }
            guard let index else {
                entries.append(ConversationEntry(kind: .tool, title: tool, text: text, state: state, toolCallID: callID))
                return
            }
            entries[index].state = state
            entries[index].text = text
        }

        for event in events.sorted(by: { $0.sequence < $1.sequence }) {
            switch event.type {
            case "user_message":
                let text = event.payload["text"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                guard !text.isEmpty else { continue }
                entries.append(ConversationEntry(id: "user-\(event.id.uuidString)", kind: .user, text: text, attachments: decodedAttachments(event), createdAt: event.timestamp))
            case "assistant_text":
                let text = event.payload["text"] ?? ""
                guard !text.isEmpty else { continue }
                if let index = entries.indices.last, entries[index].kind == .assistant {
                    entries[index].text += text
                } else {
                    entries.append(ConversationEntry(id: "assistant-\(event.id.uuidString)", kind: .assistant, title: "DeepSeek", text: text, createdAt: event.timestamp))
                }
            case "tool_requested":
                let tool = event.payload["tool"] ?? "工具"
                entries.append(ConversationEntry(id: "tool-\(event.id.uuidString)", kind: .tool, title: tool, text: "准备执行", state: .running, toolCallID: event.payload["callID"], createdAt: event.timestamp))
            case "tool_started":
                let tool = event.payload["tool"] ?? "工具"
                updateLatestTool(tool, callID: event.payload["callID"], state: .running, text: "执行中")
            case "tool_completed":
                let tool = event.payload["tool"] ?? "工具"
                let succeeded = event.payload["ok"] == "true"
                updateLatestTool(tool, callID: event.payload["callID"], state: succeeded ? .completed : .failed, text: succeeded ? "已完成" : "执行失败")
            case "tool_blocked":
                let tool = event.payload["tool"] ?? "工具"
                updateLatestTool(tool, callID: event.payload["callID"], state: .failed, text: "已被权限策略阻止")
            case "terminal_requested", "terminal_started", "terminal_resized", "terminal_signal", "terminal_attached", "terminal_detached", "terminal_portDiscovered":
                let detail = event.payload["detail"] ?? event.payload["terminalID"] ?? "Terminal"
                let title = event.type == "terminal_requested" ? "Terminal 请求" : "Terminal"
                let state: ConversationEntryState = event.type == "terminal_requested" ? .running : .info
                appendVerification(event: event, title: title, text: detail, state: state)
            case "terminal_input", "terminal_protectedInputCompleted":
                appendVerification(event: event, title: "Terminal 输入", text: event.payload["detail"] ?? "输入已发送", state: .completed)
            case "terminal_protectedInputRequired":
                appendVerification(event: event, title: "需要用户接管", text: "终端正在等待敏感输入", state: .waiting)
            case "terminal_output", "terminal_output_persisted":
                appendVerification(event: event, title: "Terminal 输出", text: event.payload["detail"] ?? "输出已接收", state: .info)
            case "terminal_completed":
                appendVerification(event: event, title: "Terminal 完成", text: event.payload["detail"] ?? "命令完成", state: .completed)
            case "terminal_failed":
                appendVerification(event: event, title: "Terminal 失败", text: event.payload["detail"] ?? "命令失败", state: .failed)
            case "terminal_indeterminate":
                appendVerification(event: event, title: "Terminal 状态未知", text: event.payload["reason"] ?? "未自动重放，请检查终端", state: .waiting)
            case "approval_requested":
                let tool = event.payload["tool"] ?? "工具"
                let risk = event.payload["risk"].map { " · \($0)" } ?? ""
                entries.append(ConversationEntry(id: "approval-\(event.id.uuidString)", kind: .approval, title: "需要审批", text: "\(tool)\(risk)", state: .waiting, createdAt: event.timestamp))
            case "approval_resolved":
                if let index = entries.lastIndex(where: { $0.kind == .approval && $0.state == .waiting }) {
                    let allowed = event.payload["decision"] != ApprovalDecision.deny.rawValue
                    entries[index].state = allowed ? .completed : .failed
                    entries[index].text += allowed ? " · 已允许" : " · 已拒绝"
                }
            case "verification_gate_evaluated":
                let passed = event.payload["passed"] == "true"
                let text = passed ? "修改、验证与交付证据已齐全" : (event.payload["missing"]?.replacingOccurrences(of: "|", with: " · ") ?? "仍缺少验证证据")
                entries.append(ConversationEntry(id: "gate-\(event.id.uuidString)", kind: .verification, title: passed ? "交付门禁已通过" : "仍需完成", text: text, state: passed ? .completed : .waiting, createdAt: event.timestamp))
            case "handoff_applied":
                entries.append(ConversationEntry(id: "handoff-\(event.id.uuidString)", kind: .verification, title: "Handoff 已应用", text: event.payload["files"] ?? "变更已安全应用", state: .completed, createdAt: event.timestamp))
            case "worker_session_created":
                entries.append(ConversationEntry(id: "worker-session-\(event.id.uuidString)", kind: .verification, title: "只读 Worker 已创建", text: event.payload["workerKind"] ?? "Worker", state: .running, createdAt: event.timestamp))
            case "worker_evidence_adopted":
                entries.append(ConversationEntry(id: "worker-evidence-\(event.id.uuidString)", kind: .verification, title: "Worker Evidence 已采纳", text: event.payload["evidenceIDs"] ?? "已采纳摘要", state: .completed, createdAt: event.timestamp))
            case "worker_session_needs_attention", "agent_worker_needs_attention":
                entries.append(ConversationEntry(id: "worker-attention-\(event.id.uuidString)", kind: .verification, title: "Worker 需要处理", text: event.payload["reason"] ?? "应用重启后未自动恢复", state: .waiting, createdAt: event.timestamp))
            case "github_pr_created":
                entries.append(ConversationEntry(id: "pr-\(event.id.uuidString)", kind: .verification, title: "Pull Request 已创建", text: event.payload["url"] ?? "GitHub 交付已创建", state: .completed, createdAt: event.timestamp))
            case "github_ci_evidence":
                let state = event.payload["state"] ?? "pending"
                let result: ConversationEntryState = state == "passed" ? .completed : (state == "failed" ? .failed : .running)
                entries.append(ConversationEntry(id: "ci-\(event.id.uuidString)", kind: .verification, title: "GitHub Actions CI", text: event.payload["detail"] ?? state, state: result, createdAt: event.timestamp))
            case "browser_evidence_recorded":
                entries.append(ConversationEntry(id: "browser-\(event.id.uuidString)", kind: .verification, title: "浏览器验证", text: "已记录 DOM、控制台、网络与截图证据", state: .completed, createdAt: event.timestamp))
            case "research_started":
                appendVerification(event: event, title: "联网研究", text: "开始研究 \(event.payload["goal"] ?? "")", state: .running)
            case "web_search_completed":
                let succeeded = event.payload["succeeded"] == "true"
                let provider = event.payload["providerID"] ?? "provider"
                let query = event.payload["query"] ?? "搜索"
                let count = event.payload["resultCount"] ?? "0"
                appendVerification(event: event, title: "联网搜索", text: "\(query) · \(provider) · \(count) 条结果", state: succeeded ? .completed : .failed)
            case "web_source_selected":
                appendVerification(event: event, title: "选定来源", text: "\(event.payload["sourceCount"] ?? "0") 个来源")
            case "web_fetch_completed":
                let succeeded = event.payload["succeeded"] != "false"
                let url = event.payload["url"] ?? "网页"
                let status = event.payload["status"] ?? "0"
                appendVerification(event: event, title: "网页抓取", text: "\(url) · HTTP \(status)", state: succeeded ? .completed : .failed)
            case "web_citation_recorded":
                appendVerification(event: event, title: "引用片段", text: event.payload["quote"] ?? event.payload["sourceID"] ?? "citation")
            case "research_conflict_detected":
                appendVerification(event: event, title: "研究冲突", text: event.payload["reason"] ?? "研究存在冲突", state: .failed)
            case "research_summary_generated":
                let succeeded = event.payload["succeeded"] == "true"
                appendVerification(event: event, title: "联网研究结论", text: event.payload["summary"] ?? "Research summary", state: succeeded ? .completed : .failed)
            case "research_failed":
                appendVerification(event: event, title: "研究失败", text: event.payload["reason"] ?? "研究失败", state: .failed)
            case "agent_failed":
                appendVerification(event: event, title: "执行失败", text: event.payload["message"] ?? "Agent 启动失败", state: .failed)
            default:
                continue
            }
        }
        return deduplicatedTimeline(entries)
    }
}
