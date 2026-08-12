import Foundation

public enum ProviderProtocol: String, Codable, CaseIterable, Sendable {
    case openAICompatible
    case anthropicCompatible
}

public struct ProviderProfile: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public var name: String
    public var baseURL: String
    public var model: String
    public var protocolName: ProviderProtocol
    public var apiKeyReference: String
    public var capabilities: ProviderCapabilities
    public var visionAdapter: VisionAdapterConfiguration?
    public var inputPerMillion: Double
    public var cachedInputPerMillion: Double
    public var outputPerMillion: Double

    public init(id: String = "deepseek-default", name: String, baseURL: String, model: String, protocolName: ProviderProtocol, apiKeyReference: String, capabilities: ProviderCapabilities = .deepSeekTextOnly, visionAdapter: VisionAdapterConfiguration? = nil, inputPerMillion: Double = 0, cachedInputPerMillion: Double = 0, outputPerMillion: Double = 0) {
        self.id = id
        self.name = name
        self.baseURL = baseURL
        self.model = model
        self.protocolName = protocolName
        self.apiKeyReference = apiKeyReference
        self.capabilities = capabilities
        self.visionAdapter = visionAdapter
        self.inputPerMillion = inputPerMillion
        self.cachedInputPerMillion = cachedInputPerMillion
        self.outputPerMillion = outputPerMillion
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, baseURL, model, protocolName, apiKeyReference, capabilities, visionAdapter
        case inputPerMillion, cachedInputPerMillion, outputPerMillion
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        baseURL = try container.decode(String.self, forKey: .baseURL)
        model = try container.decode(String.self, forKey: .model)
        protocolName = try container.decode(ProviderProtocol.self, forKey: .protocolName)
        apiKeyReference = try container.decode(String.self, forKey: .apiKeyReference)
        capabilities = try container.decodeIfPresent(ProviderCapabilities.self, forKey: .capabilities) ?? .deepSeekTextOnly
        visionAdapter = try container.decodeIfPresent(VisionAdapterConfiguration.self, forKey: .visionAdapter)
        inputPerMillion = try container.decodeIfPresent(Double.self, forKey: .inputPerMillion) ?? 0
        cachedInputPerMillion = try container.decodeIfPresent(Double.self, forKey: .cachedInputPerMillion) ?? 0
        outputPerMillion = try container.decodeIfPresent(Double.self, forKey: .outputPerMillion) ?? 0
    }

    public static let defaultDeepSeek = ProviderProfile(
        name: "DeepSeek",
        baseURL: DeepSeekModelCatalog.defaultBaseURL,
        model: DeepSeekModelCatalog.fastModel,
        protocolName: .openAICompatible,
        apiKeyReference: "keychain://deepseek-default"
    )
}

public final class ProviderCatalog: @unchecked Sendable {
    private let fileURL: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        fileURL = directory.appendingPathComponent("providers.json")
    }

    public func list() throws -> [ProviderProfile] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        return try decoder.decode([ProviderProfile].self, from: data)
    }

    public func save(_ profile: ProviderProfile) throws {
        var profiles = try list()
        if let index = profiles.firstIndex(where: { $0.id == profile.id }) {
            profiles[index] = profile
        } else {
            profiles.append(profile)
        }
        try encoder.encode(profiles).write(to: fileURL, options: .atomic)
    }
}

public struct UsageSummary: Sendable, Equatable, Codable {
    public private(set) var inputTokens = 0
    public private(set) var cachedInputTokens = 0
    public private(set) var outputTokens = 0
    public private(set) var estimatedCost = 0.0

    public init() {}

    public init(inputTokens: Int, cachedInputTokens: Int, outputTokens: Int, estimatedCost: Double) {
        self.inputTokens = inputTokens
        self.cachedInputTokens = cachedInputTokens
        self.outputTokens = outputTokens
        self.estimatedCost = estimatedCost
    }

    public mutating func record(input: Int, cachedInput: Int, output: Int, pricing: ProviderProfile) {
        inputTokens += input
        cachedInputTokens += cachedInput
        outputTokens += output
        let cost = (Double(input) * pricing.inputPerMillion + Double(cachedInput) * pricing.cachedInputPerMillion + Double(output) * pricing.outputPerMillion) / 1_000_000
        estimatedCost = (estimatedCost + cost).rounded(toPlaces: 6)
    }
}

private extension Double {
    func rounded(toPlaces places: Int) -> Double {
        let scale = pow(10.0, Double(places))
        return (self * scale).rounded() / scale
    }
}
