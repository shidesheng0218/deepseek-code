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
    public static func approvalTitle(for tool: String) -> String {
        switch canonicalToolDisplayKind(tool) {
        case "web": return "需要确认外部网页访问"
        case "terminal": return "需要确认命令执行"
        case "git": return "需要确认 Git 操作"
        case "browser": return "需要确认浏览器操作"
        default: return "需要你确认"
        }
    }

    public static func approvalText(tool: String, risk: String?) -> String {
        let suffix = risk.map { "（\($0)）" } ?? ""
        switch canonicalToolDisplayKind(tool) {
        case "web":
            return "这个请求需要访问新的外部网站\(suffix)。确认后我会继续处理。"
        case "terminal":
            return "这个请求需要执行本地命令\(suffix)。确认后我会继续处理。"
        case "git":
            return "这个请求涉及 Git 或外部交付操作\(suffix)。确认后我会继续处理。"
        case "browser":
            return "这个请求需要操作浏览器\(suffix)。确认后我会继续处理。"
        default:
            return "这个请求需要你确认\(suffix)。确认后我会继续处理。"
        }
    }

    private static func canonicalToolDisplayKind(_ tool: String) -> String {
        let lower = tool.lowercased()
        if lower.contains("web") { return "web" }
        if lower.contains("terminal") || lower == "run_command" { return "terminal" }
        if lower.contains("git") || lower.contains("github") { return "git" }
        if lower.contains("browser") { return "browser" }
        return "tool"
    }

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

    /// Primary chat projection. Tool calls, token usage and internal steps
    /// remain in the durable Parts/Evidence projections, but are deliberately
    /// excluded from the default conversation so users see the request,
    /// meaningful Assistant response, required approvals and delivery state
    /// rather than implementation names such as `web_search`.
    public static func timeline(parts: [SessionPart]) -> [ConversationEntry] {
        let entries = parts.sorted {
            $0.firstSequence == $1.firstSequence ? $0.id < $1.id : $0.firstSequence < $1.firstSequence
        }.compactMap { part -> ConversationEntry? in
            let kind: ConversationEntryKind
            switch part.kind {
            case .user: kind = .user
            case .assistantText: kind = .assistant
            case .approval: kind = .approval
            case .reasoning, .toolCall, .step, .patch, .workerResult, .verification, .usage:
                return nil
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
            let title = kind == .approval ? approvalTitle(for: part.text) : part.title
            let text = kind == .approval ? approvalText(tool: part.text, risk: nil) : part.text
            return ConversationEntry(
                id: part.id,
                kind: kind,
                title: title,
                text: text,
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
            case "tool_requested", "tool_started", "tool_completed", "tool_blocked", "tool_failed", "tool_indeterminate":
                // Internal tool lifecycle remains in the event log and
                // Evidence inspector. It is intentionally absent from the
                // primary conversation stream.
                continue
            case let type where type.hasPrefix("terminal_"):
                continue
            case "approval_requested":
                let tool = event.payload["tool"] ?? "工具"
                entries.append(ConversationEntry(id: "approval-\(event.id.uuidString)", kind: .approval, title: approvalTitle(for: tool), text: approvalText(tool: tool, risk: event.payload["risk"]), state: .waiting, createdAt: event.timestamp))
            case "approval_resolved":
                if let index = entries.lastIndex(where: { $0.kind == .approval && $0.state == .waiting }) {
                    let allowed = event.payload["decision"] != ApprovalDecision.deny.rawValue
                    entries[index].state = allowed ? .completed : .failed
                    entries[index].text = allowed ? "已确认，我会继续处理。" : "已拒绝，我不会执行这一步。"
                }
            case "agent_failed":
                let message = event.payload["message"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "这次处理没有完成。"
                guard !message.isEmpty else { continue }
                entries.append(ConversationEntry(
                    id: "assistant-failure-\(event.id.uuidString)",
                    kind: .assistant,
                    title: "DeepSeek",
                    text: message,
                    state: .failed,
                    createdAt: event.timestamp
                ))
            default:
                continue
            }
        }
        return deduplicatedTimeline(entries)
    }
}
