import Foundation

public enum CanonicalMessageRole: String, Codable, Sendable {
    case system
    case user
    case assistant
    case tool
}

public struct CanonicalMessage: Codable, Equatable, Sendable {
    public let role: CanonicalMessageRole
    public let parts: [ContentPart]
    public let toolCallID: String?
    public let toolCalls: [ChatToolCall]?

    public init(role: CanonicalMessageRole, parts: [ContentPart], toolCallID: String? = nil, toolCalls: [ChatToolCall]? = nil) {
        self.role = role
        self.parts = parts
        self.toolCallID = toolCallID
        self.toolCalls = toolCalls
    }
}

public struct GenerationPolicy: Codable, Equatable, Sendable {
    public let maxTokens: Int
    public let thinking: Bool
    public let temperature: Double?

    public init(maxTokens: Int, thinking: Bool = false, temperature: Double? = nil) {
        self.maxTokens = max(1, maxTokens)
        self.thinking = thinking
        self.temperature = temperature
    }
}

public enum CachePolicy: Codable, Equatable, Sendable {
    case auto
    case none
    case manual(system: Bool, tools: Bool, latestUserMessage: Bool)
}

public struct CanonicalLLMRequest: Codable, Equatable, Sendable {
    public let requestID: String
    public let providerID: String
    public let model: String
    public let system: [String]
    public let messages: [CanonicalMessage]
    public let tools: [ToolSchema]
    public let generation: GenerationPolicy
    public let cache: CachePolicy

    public init(
        requestID: String = UUID().uuidString,
        providerID: String,
        model: String,
        system: [String] = [],
        messages: [CanonicalMessage],
        tools: [ToolSchema] = [],
        generation: GenerationPolicy,
        cache: CachePolicy = .auto
    ) {
        self.requestID = requestID
        self.providerID = providerID
        self.model = model
        self.system = system
        self.messages = messages
        self.tools = tools
        self.generation = generation
        self.cache = cache
    }
}

public struct ProviderAdapterManifest: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let protocolName: ProviderProtocol
    public let supportsStreaming: Bool
    public let supportsToolCalling: Bool
    public let supportsReasoning: Bool
    public let supportsPromptCaching: Bool
    public let supportsImages: Bool
    public let maxContextTokens: Int
    public let requestTimeoutSeconds: Int

    public init(
        id: String,
        protocolName: ProviderProtocol,
        supportsStreaming: Bool = true,
        supportsToolCalling: Bool,
        supportsReasoning: Bool,
        supportsPromptCaching: Bool,
        supportsImages: Bool,
        maxContextTokens: Int,
        requestTimeoutSeconds: Int = 120
    ) {
        self.id = id
        self.protocolName = protocolName
        self.supportsStreaming = supportsStreaming
        self.supportsToolCalling = supportsToolCalling
        self.supportsReasoning = supportsReasoning
        self.supportsPromptCaching = supportsPromptCaching
        self.supportsImages = supportsImages
        self.maxContextTokens = max(1_024, maxContextTokens)
        self.requestTimeoutSeconds = max(10, requestTimeoutSeconds)
    }

    public static func forProfile(_ profile: ProviderProfile) -> ProviderAdapterManifest {
        ProviderAdapterManifest(
            id: profile.id,
            protocolName: profile.protocolName,
            supportsToolCalling: profile.capabilities.toolCalling,
            supportsReasoning: profile.protocolName == .openAICompatible,
            supportsPromptCaching: profile.capabilities.promptCaching,
            supportsImages: profile.capabilities.imageInput,
            maxContextTokens: profile.capabilities.maxContextTokens
        )
    }
}

public final class ProviderAdapterRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var manifests: [String: ProviderAdapterManifest] = [:]

    public init(profiles: [ProviderProfile] = []) {
        profiles.forEach { register(ProviderAdapterManifest.forProfile($0)) }
    }

    public func register(_ manifest: ProviderAdapterManifest) {
        lock.lock(); manifests[manifest.id] = manifest; lock.unlock()
    }

    public func manifest(providerID: String) -> ProviderAdapterManifest? {
        lock.lock(); defer { lock.unlock() }
        return manifests[providerID]
    }

    public func all() -> [ProviderAdapterManifest] {
        lock.lock(); defer { lock.unlock() }
        return manifests.values.sorted { $0.id < $1.id }
    }
}

public struct ProviderRoute: Codable, Equatable, Sendable {
    public let providerID: String
    public let protocolName: ProviderProtocol
    public let model: String
    public let manifest: ProviderAdapterManifest

    public init(providerID: String, protocolName: ProviderProtocol, model: String, manifest: ProviderAdapterManifest) {
        self.providerID = providerID
        self.protocolName = protocolName
        self.model = model
        self.manifest = manifest
    }
}

public enum ProviderRouteResolver {
    public static func resolve(profile: ProviderProfile, registry: ProviderAdapterRegistry? = nil) throws -> ProviderRoute {
        let manifest = registry?.manifest(providerID: profile.id) ?? .forProfile(profile)
        guard manifest.protocolName == profile.protocolName else {
            throw ProviderLowererError.invalidRequest("Provider 协议与 Adapter Manifest 不一致")
        }
        return ProviderRoute(providerID: profile.id, protocolName: profile.protocolName, model: profile.model, manifest: manifest)
    }

    public static func lower(_ request: CanonicalLLMRequest, route: ProviderRoute) throws -> Any {
        guard request.providerID == route.providerID, request.model == route.model else {
            throw ProviderLowererError.invalidRequest("Canonical Request 与 Provider Route 不匹配")
        }
        if request.generation.thinking && !route.manifest.supportsReasoning {
            throw ProviderLowererError.unsupportedContent("该 Provider 未通过 Reasoning 能力测试")
        }
        if !request.tools.isEmpty && !route.manifest.supportsToolCalling {
            throw ProviderLowererError.unsupportedContent("该 Provider 未通过 Tool Calling 能力测试")
        }
        switch route.protocolName {
        case .openAICompatible: return try OpenAICompatibleLowerer.lower(request)
        case .anthropicCompatible: return try AnthropicMessagesLowerer.lower(request)
        }
    }
}

public struct AnthropicMessagesRequest: Codable, Equatable, Sendable {
    public let model: String
    public let system: String?
    public let messages: [AnthropicMessage]
    public let maxTokens: Int
    public let stream: Bool
    public let tools: [AnthropicToolDefinition]?
    public let temperature: Double?

    public init(model: String, system: String?, messages: [AnthropicMessage], maxTokens: Int, stream: Bool, tools: [AnthropicToolDefinition]?, temperature: Double?) {
        self.model = model
        self.system = system
        self.messages = messages
        self.maxTokens = maxTokens
        self.stream = stream
        self.tools = tools
        self.temperature = temperature
    }

    private enum CodingKeys: String, CodingKey {
        case model, system, messages
        case maxTokens = "max_tokens"
        case stream, tools, temperature
    }
}

public struct AnthropicToolDefinition: Codable, Equatable, Sendable {
    public let name: String
    public let description: String
    public let inputSchema: JSONValue

    public init(name: String, description: String, inputSchema: JSONValue) {
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
    }

    private enum CodingKeys: String, CodingKey {
        case name, description
        case inputSchema = "input_schema"
    }
}

public struct AnthropicMessage: Codable, Equatable, Sendable {
    public let role: String
    public let content: [AnthropicContent]

    public init(role: String, content: [AnthropicContent]) {
        self.role = role
        self.content = content
    }
}

public enum AnthropicContent: Codable, Equatable, Sendable {
    case text(String)
    case image(mediaType: String, data: String)
    case toolUse(id: String, name: String, inputJSON: String)
    case toolResult(toolUseID: String, content: String)

    private enum CodingKeys: String, CodingKey { case type, text, source, id, name, input, toolUseID = "tool_use_id", content }
    private enum SourceKeys: String, CodingKey { case type, mediaType = "media_type", data }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .text(value):
            try container.encode("text", forKey: .type)
            try container.encode(value, forKey: .text)
        case let .image(mediaType, data):
            try container.encode("image", forKey: .type)
            var source = container.nestedContainer(keyedBy: SourceKeys.self, forKey: .source)
            try source.encode("base64", forKey: .type)
            try source.encode(mediaType, forKey: .mediaType)
            try source.encode(data, forKey: .data)
        case let .toolUse(id, name, inputJSON):
            try container.encode("tool_use", forKey: .type)
            try container.encode(id, forKey: .id)
            try container.encode(name, forKey: .name)
            let input = (try? JSONDecoder().decode(JSONValue.self, from: Data(inputJSON.utf8))) ?? .object([:])
            try container.encode(input, forKey: .input)
        case let .toolResult(toolUseID, content):
            try container.encode("tool_result", forKey: .type)
            try container.encode(toolUseID, forKey: .toolUseID)
            try container.encode(content, forKey: .content)
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .type) {
        case "text": self = .text(try container.decode(String.self, forKey: .text))
        case "image":
            let source = try container.nestedContainer(keyedBy: SourceKeys.self, forKey: .source)
            self = .image(mediaType: try source.decode(String.self, forKey: .mediaType), data: try source.decode(String.self, forKey: .data))
        case "tool_use":
            let input = try container.decode(JSONValue.self, forKey: .input)
            let encoded = try JSONEncoder().encode(input)
            self = .toolUse(
                id: try container.decode(String.self, forKey: .id),
                name: try container.decode(String.self, forKey: .name),
                inputJSON: String(decoding: encoded, as: UTF8.self)
            )
        case "tool_result":
            self = .toolResult(
                toolUseID: try container.decode(String.self, forKey: .toolUseID),
                content: try container.decode(String.self, forKey: .content)
            )
        default: throw ProviderLowererError.unsupportedContent("Anthropic content type")
        }
    }
}

public enum ProviderLowererError: LocalizedError, Sendable {
    case unsupportedContent(String)
    case invalidRequest(String)

    public var errorDescription: String? {
        switch self {
        case let .unsupportedContent(detail): "当前 Provider 不支持：\(detail)"
        case let .invalidRequest(detail): "模型请求无效：\(detail)"
        }
    }
}

public enum OpenAICompatibleLowerer {
    public static func lower(_ request: CanonicalLLMRequest) throws -> ChatRequest {
        guard !request.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ProviderLowererError.invalidRequest("缺少模型名")
        }
        var messages: [ChatMessage] = request.system.map { ChatMessage(role: "system", content: $0) }
        messages.append(contentsOf: request.messages.map { message in
            ChatMessage(
                role: message.role.rawValue,
                parts: message.parts,
                toolCallID: message.toolCallID,
                toolCalls: message.toolCalls
            )
        })
        return ChatRequest(
            model: request.model,
            messages: messages,
            maxTokens: request.generation.maxTokens,
            tools: request.tools,
            thinking: request.generation.thinking
        )
    }
}

public enum AnthropicMessagesLowerer {
    public static func lower(_ request: CanonicalLLMRequest) throws -> AnthropicMessagesRequest {
        guard !request.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ProviderLowererError.invalidRequest("缺少模型名")
        }
        let messages = try request.messages.map { message -> AnthropicMessage in
            guard message.role != .system else { throw ProviderLowererError.invalidRequest("system 必须位于 system 字段") }
            if message.role == .tool {
                guard let toolCallID = message.toolCallID else {
                    throw ProviderLowererError.invalidRequest("tool 结果缺少 tool_call_id")
                }
                return AnthropicMessage(role: "user", content: [.toolResult(toolUseID: toolCallID, content: message.parts.plainText)])
            }
            if message.role == .assistant, let toolCalls = message.toolCalls, !toolCalls.isEmpty {
                var content = try message.parts.map(content(for:))
                content.append(contentsOf: toolCalls.map {
                    .toolUse(id: $0.id, name: $0.function.name, inputJSON: $0.function.arguments)
                })
                return AnthropicMessage(role: "assistant", content: content)
            }
            let content = try message.parts.map(content(for:))
            return AnthropicMessage(role: message.role.rawValue, content: content)
        }
        return AnthropicMessagesRequest(
            model: request.model,
            system: request.system.isEmpty ? nil : request.system.joined(separator: "\n\n"),
            messages: messages,
            maxTokens: request.generation.maxTokens,
            stream: true,
            tools: request.tools.isEmpty ? nil : request.tools.map {
                AnthropicToolDefinition(name: $0.function.name, description: $0.function.description, inputSchema: $0.function.parameters)
            },
            temperature: nil
        )
    }

    private static func content(for part: ContentPart) throws -> AnthropicContent {
        switch part {
        case let .text(value): return .text(value)
        case let .codeSelection(path, startLine, endLine, text): return .text("[代码 \(path):\(startLine)-\(endLine)]\n\(text)")
        case let .browserEvidence(evidence): return .text("[浏览器证据 \(evidence.url)]\n\(evidence.summary)")
        case let .computerEvidence(evidence): return .text("[桌面证据 \(evidence.application)]\n\(evidence.summary)")
        case let .toolEvidence(evidence): return .text("[工具证据 \(evidence.title)]\n\(evidence.detail)")
        case let .document(attachment): return .text("[文档附件：\(attachment.filename)。请使用本地提取文本。]")
        case .image:
            throw ProviderLowererError.unsupportedContent("Anthropic 图片需要通过 AttachmentDataProvider 编译")
        }
    }
}

public struct NormalizedUsage: Codable, Equatable, Sendable {
    public let inputTokens: Int
    public let cacheReadInputTokens: Int
    public let cacheWriteInputTokens: Int
    public let reasoningTokens: Int
    public let outputTokens: Int

    public init(inputTokens: Int, cacheReadInputTokens: Int = 0, cacheWriteInputTokens: Int = 0, reasoningTokens: Int = 0, outputTokens: Int) {
        self.inputTokens = max(0, inputTokens)
        self.cacheReadInputTokens = max(0, cacheReadInputTokens)
        self.cacheWriteInputTokens = max(0, cacheWriteInputTokens)
        self.reasoningTokens = max(0, reasoningTokens)
        self.outputTokens = max(0, outputTokens)
    }
}
