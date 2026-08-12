import Foundation

public enum DeepSeekTaskKind: String, CaseIterable, Identifiable, Sendable {
    case complexCoding
    case exploration
    case review
    case summarization
    case browserValidation

    public var id: String { rawValue }
}

public struct DeepSeekModelCapabilities: Codable, Equatable, Sendable {
    public let supportsThinking: Bool
    public let supportsToolCalling: Bool
    public let supportsStrictTools: Bool
    public let supportsParallelTools: Bool
    public let supportsVision: Bool
    public let supportsResponsesAPI: Bool
    public let supportsPromptCache: Bool
    public let contextWindow: Int
    public let maxOutputTokens: Int

    public init(
        supportsThinking: Bool,
        supportsToolCalling: Bool,
        supportsStrictTools: Bool,
        supportsParallelTools: Bool,
        supportsVision: Bool,
        supportsResponsesAPI: Bool,
        supportsPromptCache: Bool,
        contextWindow: Int,
        maxOutputTokens: Int
    ) {
        self.supportsThinking = supportsThinking
        self.supportsToolCalling = supportsToolCalling
        self.supportsStrictTools = supportsStrictTools
        self.supportsParallelTools = supportsParallelTools
        self.supportsVision = supportsVision
        self.supportsResponsesAPI = supportsResponsesAPI
        self.supportsPromptCache = supportsPromptCache
        self.contextWindow = contextWindow
        self.maxOutputTokens = maxOutputTokens
    }
}

public enum DeepSeekModelCatalog {
    public static let proModel = "deepseek-v4-pro"
    public static let fastModel = "deepseek-v4-flash"
    // DeepSeek's OpenAI-compatible endpoint is rooted at the host; adding
    // `/v1` produces an invalid path for the current API.
    public static let defaultBaseURL = "https://api.deepseek.com"

    public static func isLegacy(_ model: String) -> Bool {
        let normalized = model.lowercased()
        return normalized == "deepseek-chat" || normalized == "deepseek-reasoner"
    }

    public static func normalizedModel(_ model: String) -> String {
        let normalized = model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized == proModel || normalized.hasPrefix("\(proModel)-") { return proModel }
        if normalized == fastModel || normalized.hasPrefix("\(fastModel)-") { return fastModel }
        return model.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func model(for task: DeepSeekTaskKind) -> String {
        switch task {
        case .complexCoding, .review, .browserValidation:
            proModel
        case .exploration, .summarization:
            fastModel
        }
    }

    public static func routedModel(preferred: String, mode: AgentMode, prompt: String) -> String {
        let normalizedPreferred = normalizedModel(preferred)
        guard normalizedPreferred == proModel || normalizedPreferred == fastModel || isLegacy(normalizedPreferred) else { return normalizedPreferred }
        let route = TaskRouter.route(TaskRoutingInput(prompt: prompt, mode: mode))
        return routedModel(preferred: normalizedPreferred, route: route)
    }

    /// Model routing follows the durable task classification rather than a
    /// raw character-count heuristic. This keeps short but high-stakes repair
    /// and research requests on the capable route while preserving fast
    /// answers for ordinary questions.
    public static func routedModel(preferred: String, route: TaskRoute) -> String {
        let normalizedPreferred = normalizedModel(preferred)
        guard normalizedPreferred == proModel || normalizedPreferred == fastModel || isLegacy(normalizedPreferred) else { return normalizedPreferred }
        let requiresPro = route.needsHighReasoning || route.complexity >= .complex || [.review, .deliveryRepair, .multimodalRepair].contains(route.kind)
        return requiresPro ? proModel : fastModel
    }

    public static func capabilities(for model: String) -> DeepSeekModelCapabilities {
        if model == fastModel {
            return DeepSeekModelCapabilities(
                supportsThinking: true,
                supportsToolCalling: true,
                supportsStrictTools: true,
                supportsParallelTools: true,
                supportsVision: false,
                supportsResponsesAPI: true,
                supportsPromptCache: true,
                contextWindow: 1_000_000,
                maxOutputTokens: 64_000
            )
        }

        if model == proModel {
            return DeepSeekModelCapabilities(
                supportsThinking: true,
                supportsToolCalling: true,
                supportsStrictTools: true,
                supportsParallelTools: true,
                supportsVision: false,
                supportsResponsesAPI: true,
                supportsPromptCache: true,
                contextWindow: 1_000_000,
                maxOutputTokens: 128_000
            )
        }

        return DeepSeekModelCapabilities(
            supportsThinking: false,
            supportsToolCalling: false,
            supportsStrictTools: false,
            supportsParallelTools: false,
            supportsVision: false,
            supportsResponsesAPI: false,
            supportsPromptCache: false,
            contextWindow: 128_000,
            maxOutputTokens: 16_000
        )
    }
}
