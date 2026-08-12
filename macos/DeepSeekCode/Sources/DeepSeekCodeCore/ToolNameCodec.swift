import Foundation

public enum ToolNameCodec {
    public static func modelSafeName(from name: String) -> String {
        let replaced = name.replacingOccurrences(of: ".", with: "_")
        let filtered = replaced.map { character -> Character in
            if character.isLetter || character.isNumber || character == "_" || character == "-" {
                return character
            }
            return "_"
        }
        return String(filtered)
    }

    public static func modelCompatibleToolCalls(_ toolCalls: [ChatToolCall]?) -> [ChatToolCall]? {
        guard let toolCalls else { return nil }
        return toolCalls.map { call in
            ChatToolCall(
                id: call.id,
                name: modelSafeName(from: call.function.name),
                argumentsJSON: call.function.arguments
            )
        }
    }
}
