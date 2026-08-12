import Foundation

public enum ProviderStreamEvent: Equatable, Sendable {
    case textDelta(String)
    case reasoningDelta(String)
    case toolCall(id: String, name: String, argumentsJSON: String)
    case toolCallDelta(index: Int, id: String?, name: String?, arguments: String?)
    case usage(input: Int, cachedInput: Int, output: Int)
    case usageDetails(NormalizedUsage)
    case done
}

public indirect enum JSONValue: Codable, Equatable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([String: JSONValue].self) { self = .object(value) }
        else { self = .array(try container.decode([JSONValue].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .string(value): try container.encode(value)
        case let .number(value): try container.encode(value)
        case let .bool(value): try container.encode(value)
        case let .object(value): try container.encode(value)
        case let .array(value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }
}

public extension JSONValue {
    static func objectSchema(properties: [String: JSONValue] = [:], required: [String] = []) -> JSONValue {
        var schema: [String: JSONValue] = [
            "type": .string("object"),
            "properties": .object(properties)
        ]
        if !required.isEmpty {
            schema["required"] = .array(required.map(JSONValue.string))
        }
        return .object(schema)
    }
}

public struct ToolSchema: Codable, Equatable, Sendable {
    public let type: String
    public let function: Function

    public init(name: String, description: String, parameters: JSONValue) {
        type = "function"
        function = Function(name: name, description: description, parameters: parameters)
    }

    enum CodingKeys: String, CodingKey { case type, function }

    public struct Function: Codable, Equatable, Sendable {
        public let name: String
        public let description: String
        public let parameters: JSONValue
    }
}

public enum OpenAIStreamDecodeError: LocalizedError {
    case noEvent

    public var errorDescription: String? { "SSE frame did not contain a supported event" }
}

public enum ProviderRequestError: LocalizedError, Sendable {
    case invalidEndpoint
    case httpStatus(code: Int, body: String)

    public var errorDescription: String? {
        switch self {
        case .invalidEndpoint:
            return "模型地址无效"
        case let .httpStatus(code, body):
            let detail = Self.extractMessage(from: body)
            return detail.isEmpty ? "模型请求失败（HTTP \(code)）" : "模型请求失败（HTTP \(code)）：\(detail)"
        }
    }

    private static func extractMessage(from body: String) -> String {
        guard let data = body.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return body.trimmingCharacters(in: .whitespacesAndNewlines).prefix(400).description
        }
        if let error = object["error"] as? [String: Any], let message = error["message"] as? String { return message }
        if let message = object["message"] as? String { return message }
        return body.trimmingCharacters(in: .whitespacesAndNewlines).prefix(400).description
    }
}

public enum OpenAIStreamDecoder {
    public static func parse(data: String) throws -> ProviderStreamEvent {
        if data == "[DONE]" { return .done }
        let payload = try JSONDecoder().decode(Payload.self, from: Data(data.utf8))
        if let reasoning = payload.choices?.first?.delta?.reasoningContent, !reasoning.isEmpty {
            return .reasoningDelta(reasoning)
        }
        if let content = payload.choices?.first?.delta?.content, !content.isEmpty {
            return .textDelta(content)
        }
        if let tool = payload.choices?.first?.delta?.toolCalls?.first {
            let id = tool.id
            let name = tool.function?.name
            let arguments = tool.function?.arguments
            if let id, let name, let arguments, isJSONObject(arguments) {
                return .toolCall(id: id, name: name, argumentsJSON: arguments)
            }
            return .toolCallDelta(index: tool.index ?? 0, id: id, name: name, arguments: arguments)
        }
        if let usage = payload.usage {
            return .usage(input: usage.promptTokens ?? 0, cachedInput: usage.promptTokensDetails?.cachedTokens ?? 0, output: usage.completionTokens ?? 0)
        }
        throw OpenAIStreamDecodeError.noEvent
    }

    private struct Payload: Decodable {
        let choices: [Choice]?
        let usage: Usage?
    }

    private struct Choice: Decodable {
        let delta: Delta?
    }

    private struct Delta: Decodable {
        let content: String?
        let reasoningContent: String?
        let toolCalls: [ToolCall]?

        enum CodingKeys: String, CodingKey {
            case content
            case reasoningContent = "reasoning_content"
            case toolCalls = "tool_calls"
        }
    }

    private struct ToolCall: Decodable {
        let index: Int?
        let id: String?
        let function: Function?
    }

    private struct Function: Decodable {
        let name: String?
        let arguments: String?
    }

    private struct Usage: Decodable {
        let promptTokens: Int?
        let completionTokens: Int?
        let promptTokensDetails: PromptTokensDetails?

        enum CodingKeys: String, CodingKey {
            case promptTokens = "prompt_tokens"
            case completionTokens = "completion_tokens"
            case promptTokensDetails = "prompt_tokens_details"
        }
    }

    private struct PromptTokensDetails: Decodable {
        let cachedTokens: Int?

        enum CodingKeys: String, CodingKey {
            case cachedTokens = "cached_tokens"
        }
    }

    private static func isJSONObject(_ value: String) -> Bool {
        guard let data = value.data(using: .utf8), let object = try? JSONSerialization.jsonObject(with: data) else { return false }
        return object is [String: Any]
    }
}

public struct ChatToolCall: Codable, Equatable, Sendable {
    public let id: String
    public let type: String
    public let function: Function

    public init(id: String, name: String, argumentsJSON: String) {
        self.id = id
        self.type = "function"
        self.function = Function(name: name, arguments: argumentsJSON)
    }

    public struct Function: Codable, Equatable, Sendable {
        public let name: String
        public let arguments: String
    }
}

public struct ChatMessage: Codable, Equatable, Sendable {
    public let role: String
    public let parts: [ContentPart]
    public var reasoningContent: String?
    public let toolCallID: String?
    public let toolCalls: [ChatToolCall]?

    public init(role: String, content: String, reasoningContent: String? = nil, toolCallID: String? = nil, toolCalls: [ChatToolCall]? = nil) {
        self.role = role
        parts = content.isEmpty ? [] : [.text(content)]
        self.reasoningContent = reasoningContent
        self.toolCallID = toolCallID
        self.toolCalls = toolCalls
    }

    public init(role: String, parts: [ContentPart], reasoningContent: String? = nil, toolCallID: String? = nil, toolCalls: [ChatToolCall]? = nil) {
        self.role = role
        self.parts = parts
        self.reasoningContent = reasoningContent
        self.toolCallID = toolCallID
        self.toolCalls = toolCalls
    }

    public var content: String { parts.plainText }

    private enum CodingKeys: String, CodingKey {
        case role
        case content
        case parts
        case reasoningContent = "reasoning_content"
        case toolCallID = "tool_call_id"
        case toolCalls = "tool_calls"
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(role, forKey: .role)
        try container.encode(parts, forKey: .parts)
        try container.encodeIfPresent(reasoningContent, forKey: .reasoningContent)
        try container.encodeIfPresent(toolCallID, forKey: .toolCallID)
        try container.encodeIfPresent(toolCalls, forKey: .toolCalls)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        role = try container.decode(String.self, forKey: .role)
        if let decodedParts = try? container.decode([ContentPart].self, forKey: .parts) {
            parts = decodedParts
        } else if let legacyContent = try? container.decode(String.self, forKey: .content) {
            parts = legacyContent.isEmpty ? [] : [.text(legacyContent)]
        } else {
            parts = []
        }
        reasoningContent = try container.decodeIfPresent(String.self, forKey: .reasoningContent)
        toolCallID = try container.decodeIfPresent(String.self, forKey: .toolCallID)
        toolCalls = try container.decodeIfPresent([ChatToolCall].self, forKey: .toolCalls)
    }
}

public struct ChatRequest: Codable, Sendable {
    public let model: String
    public let messages: [ChatMessage]
    public let maxTokens: Int
    public let stream: Bool
    public let streamOptions: StreamOptions
    public let tools: [ToolSchema]?
    public let thinking: ThinkingConfig?

    public init(model: String, messages: [ChatMessage], maxTokens: Int, stream: Bool = true, tools: [ToolSchema] = [], thinking: Bool? = nil) {
        self.model = model
        self.messages = messages
        self.maxTokens = maxTokens
        self.stream = stream
        self.streamOptions = StreamOptions(includeUsage: true)
        self.tools = tools.isEmpty ? nil : tools
        self.thinking = thinking.map { ThinkingConfig(type: $0 ? "enabled" : "disabled") }
    }

    enum CodingKeys: String, CodingKey {
        case model
        case messages
        case maxTokens = "max_tokens"
        case stream
        case streamOptions = "stream_options"
        case tools
        case thinking
    }

    public struct StreamOptions: Codable, Sendable {
        let includeUsage: Bool
        enum CodingKeys: String, CodingKey { case includeUsage = "include_usage" }
    }

    public struct ThinkingConfig: Codable, Equatable, Sendable {
        public let type: String

        public init(type: String) {
            self.type = type
        }
    }
}

public final class OpenAICompatibleClient: @unchecked Sendable {
    private let endpoint: URL
    private let apiKey: String
    private let attachmentProvider: (any AttachmentDataProvider)?
    private let networkPolicy: NetworkPolicy
    private let networkRuntime: NetworkRuntime?
    private let networkContext: NetworkContext?

    public init(baseURL: String, apiKey: String, attachmentProvider: (any AttachmentDataProvider)? = nil, networkPolicy: NetworkPolicy = .default, networkRuntime: NetworkRuntime? = nil, networkContext: NetworkContext? = nil) throws {
        guard let base = URL(string: baseURL), base.scheme != nil, base.host != nil,
              networkPolicy.decision(for: base, scope: .modelProvider) == .allow else { throw ProviderRequestError.invalidEndpoint }
        endpoint = base.appendingPathComponent("chat/completions")
        self.apiKey = apiKey
        self.attachmentProvider = attachmentProvider
        self.networkPolicy = networkPolicy
        self.networkRuntime = networkRuntime
        self.networkContext = networkContext
    }

    public func stream(_ request: ChatRequest) -> AsyncThrowingStream<ProviderStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    var urlRequest = URLRequest(url: endpoint)
                    urlRequest.httpMethod = "POST"
                    urlRequest.timeoutInterval = 120
                    urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    urlRequest.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                    urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
                    urlRequest.httpBody = try OpenAICompatibleRequest(request: request, attachmentProvider: attachmentProvider).encoded()
                    if let networkRuntime {
                        let events = await networkRuntime.streamLines(
                            for: urlRequest,
                            scope: .modelProvider,
                            operation: .read,
                            context: networkContext,
                            approved: true,
                            maxBytes: 2 * 1024 * 1024
                        )
                        for try await event in events {
                            switch event {
                            case let .response(statusCode, body):
                                guard (200..<300).contains(statusCode) else {
                                    throw ProviderRequestError.httpStatus(code: statusCode, body: body ?? "")
                                }
                            case let .line(line):
                                if try Self.consumeSSELine(line, continuation: continuation) { break }
                            case .completed:
                                break
                            }
                        }
                    } else {
                        let (bytes, response) = try await URLSession.shared.bytes(for: urlRequest)
                        guard let http = response as? HTTPURLResponse else {
                            throw ProviderRequestError.httpStatus(code: 0, body: "服务端没有返回 HTTP 响应")
                        }
                        guard (200..<300).contains(http.statusCode) else {
                            var body = ""
                            for try await line in bytes.lines {
                                body += line
                                if body.utf8.count >= 4_096 { break }
                            }
                            throw ProviderRequestError.httpStatus(code: http.statusCode, body: body)
                        }
                        for try await line in bytes.lines {
                            if try Self.consumeSSELine(line, continuation: continuation) { break }
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    private static func consumeSSELine(
        _ line: String,
        continuation: AsyncThrowingStream<ProviderStreamEvent, Error>.Continuation
    ) throws -> Bool {
        guard line.hasPrefix("data:") else { return false }
        let data = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
        do {
            let event = try OpenAIStreamDecoder.parse(data: data)
            continuation.yield(event)
            return event == .done
        } catch OpenAIStreamDecodeError.noEvent {
            return false
        }
    }
}

private struct OpenAICompatibleRequest: Encodable {
    let model: String
    let messages: [OpenAICompatibleMessage]
    let maxTokens: Int
    let stream: Bool
    let streamOptions: ChatRequest.StreamOptions
    let tools: [ToolSchema]?
    let thinking: ChatRequest.ThinkingConfig?

    init(request: ChatRequest, attachmentProvider: (any AttachmentDataProvider)?) {
        model = request.model
        messages = request.messages.map { OpenAICompatibleMessage(message: $0, attachmentProvider: attachmentProvider) }
        maxTokens = request.maxTokens
        stream = request.stream
        streamOptions = request.streamOptions
        tools = request.tools
        thinking = request.thinking
    }

    func encoded() throws -> Data {
        try JSONEncoder().encode(self)
    }

    enum CodingKeys: String, CodingKey {
        case model
        case messages
        case maxTokens = "max_tokens"
        case stream
        case streamOptions = "stream_options"
        case tools
        case thinking
    }
}

private struct OpenAICompatibleMessage: Encodable {
    let role: String
    let content: OpenAICompatibleContent
    let reasoningContent: String?
    let toolCallID: String?
    let toolCalls: [ChatToolCall]?

    init(message: ChatMessage, attachmentProvider: (any AttachmentDataProvider)?) {
        role = message.role
        content = OpenAICompatibleContent(parts: message.parts, attachmentProvider: attachmentProvider)
        reasoningContent = message.reasoningContent
        toolCallID = message.toolCallID
        toolCalls = ToolNameCodec.modelCompatibleToolCalls(message.toolCalls)
    }

    enum CodingKeys: String, CodingKey {
        case role
        case content
        case reasoningContent = "reasoning_content"
        case toolCallID = "tool_call_id"
        case toolCalls = "tool_calls"
    }
}

private enum OpenAICompatibleContent: Encodable {
    case text(String)
    case parts([OpenAICompatibleContentPart])

    init(parts: [ContentPart], attachmentProvider: (any AttachmentDataProvider)?) {
        let hasStructuredContent = parts.contains { part in
            switch part {
            case .text, .codeSelection, .browserEvidence, .computerEvidence, .toolEvidence: false
            case .image, .document: true
            }
        }
        if !hasStructuredContent {
            self = .text(parts.plainText)
        } else {
            self = .parts(parts.compactMap { OpenAICompatibleContentPart(part: $0, attachmentProvider: attachmentProvider) })
        }
    }

    func encode(to encoder: Encoder) throws {
        switch self {
        case let .text(value):
            var container = encoder.singleValueContainer()
            try container.encode(value)
        case let .parts(values):
            var container = encoder.unkeyedContainer()
            try values.forEach { try container.encode($0) }
        }
    }
}

private struct OpenAICompatibleContentPart: Encodable {
    let type: String
    let text: String?
    private let imageURL: ImageURL?

    init?(part: ContentPart, attachmentProvider: (any AttachmentDataProvider)?) {
        switch part {
        case let .text(value):
            type = "text"
            text = value
            imageURL = nil
        case let .image(attachment):
            type = "image_url"
            text = nil
            imageURL = ImageURL(url: Self.dataURL(for: attachment, provider: attachmentProvider))
        case let .document(attachment):
            type = "text"
            text = "[文档附件：\(attachment.filename)。请使用已提取的文本证据。]"
            imageURL = nil
        case let .codeSelection(path, startLine, endLine, value):
            type = "text"
            text = "[代码 \(path):\(startLine)-\(endLine)]\n\(value)"
            imageURL = nil
        case let .browserEvidence(evidence):
            type = "text"
            text = "[浏览器证据 \(evidence.url)]\n\(evidence.summary)"
            imageURL = nil
        case let .computerEvidence(evidence):
            type = "text"
            text = "[桌面证据 \(evidence.application)]\n\(evidence.summary)"
            imageURL = nil
        case let .toolEvidence(evidence):
            type = "text"
            text = "[工具证据 \(evidence.title)]\n\(evidence.detail)"
            imageURL = nil
        }
    }

    private enum CodingKeys: String, CodingKey { case type, text, imageURL = "image_url" }

    private struct ImageURL: Encodable {
        let url: String
    }

    private static func dataURL(for attachment: AttachmentRef, provider: (any AttachmentDataProvider)?) -> String {
        guard attachment.byteCount <= 8 * 1_024 * 1_024,
              let data = try? provider?.data(for: attachment) else {
            return "attachment://\(attachment.id)"
        }
        let mime: String
        switch attachment.filename.lowercased().split(separator: ".").last.map(String.init) {
        case "png": mime = "image/png"
        case "jpg", "jpeg": mime = "image/jpeg"
        case "gif": mime = "image/gif"
        case "webp": mime = "image/webp"
        default: mime = "application/octet-stream"
        }
        return "data:\(mime);base64,\(data.base64EncodedString())"
    }
}
