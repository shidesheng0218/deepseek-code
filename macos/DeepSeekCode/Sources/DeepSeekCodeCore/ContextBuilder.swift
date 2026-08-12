import CryptoKit
import Foundation

public struct ContextAssembly: Sendable {
    public let messages: [ChatMessage]
    public let selection: ContextSelection

    public init(messages: [ChatMessage], selection: ContextSelection) {
        self.messages = messages
        self.selection = selection
    }
}

public struct ContextBuilder: Sendable {
    public init() {}

    public func estimateTokens(_ messages: [ChatMessage]) -> Int {
        let characters = messages.reduce(0) { $0 + $1.parts.plainText.count + ($1.reasoningContent?.count ?? 0) }
        return max(1, characters / 4)
    }

    public func compact(_ messages: [ChatMessage], maxTokens: Int) -> [ChatMessage] {
        assemble(messages, maxTokens: maxTokens).messages
    }

    /// Selects context by durable role/relevance instead of blindly removing
    /// the oldest messages. The returned selection can be persisted as a
    /// Quality Trace while the bounded messages are sent to the provider.
    public func assemble(_ messages: [ChatMessage], maxTokens: Int) -> ContextAssembly {
        let graph = ContextGraph.from(messages: messages)
        guard estimateTokens(messages) > maxTokens else {
            return ContextAssembly(
                messages: messages,
                selection: ContextSelection(nodes: graph.nodes, omittedIDs: [], estimatedTokens: estimateTokens(messages))
            )
        }
        let selection = graph.select(maxTokens: maxTokens)
        let selectedIDs = Set(selection.selectedIDs)
        var compacted = messages.enumerated().compactMap { index, message in
            selectedIDs.contains("message-\(index)") ? compactMessage(message) : nil
        }

        // A context without an explicit system/user message can still occur
        // in imported legacy events. Preserve its newest message rather than
        // sending an empty provider request.
        if compacted.isEmpty, let latest = messages.last {
            compacted = [compactMessage(latest)]
        }
        while estimateTokens(compacted) > maxTokens {
            guard let removable = compacted.firstIndex(where: { $0.role != "system" && $0.role != "user" }) else { break }
            compacted.remove(at: removable)
        }
        if estimateTokens(compacted) > maxTokens {
            let prefix = "[上下文已压缩]\\n"
            let perMessageCharacters = max(1, ((max(1, maxTokens) * 4) / max(1, compacted.count)) - prefix.count)
            compacted = compacted.map { message in
                guard message.content.count > perMessageCharacters else { return message }
                let trimmed = String(message.content.prefix(perMessageCharacters))
                return ChatMessage(role: message.role, content: "\(prefix)\(trimmed)", reasoningContent: message.reasoningContent, toolCallID: message.toolCallID, toolCalls: message.toolCalls)
            }
        }
        return ContextAssembly(messages: compacted, selection: selection)
    }

    private func compactMessage(_ message: ChatMessage) -> ChatMessage {
        guard message.role == "tool", message.content.count > 600 else { return message }
        let digest = SHA256.hash(data: Data(message.content.utf8)).map { String(format: "%02x", $0) }.joined()
        let summary = String(message.content.prefix(600))
        return ChatMessage(role: "tool", content: "[已压缩工具结果 sha256=\(digest.prefix(12))]\\n\(summary)", reasoningContent: message.reasoningContent, toolCallID: message.toolCallID, toolCalls: message.toolCalls)
    }
}
