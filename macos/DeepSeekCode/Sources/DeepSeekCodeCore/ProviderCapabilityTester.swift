import Foundation

public struct ProviderCapabilityTestResult: Codable, Equatable, Sendable {
    public let providerID: String
    public let succeeded: Bool
    public let capabilities: ProviderCapabilities
    public let detail: String
    public let testedAt: Date

    public init(providerID: String, succeeded: Bool, capabilities: ProviderCapabilities, detail: String, testedAt: Date = Date()) {
        self.providerID = providerID
        self.succeeded = succeeded
        self.capabilities = capabilities
        self.detail = detail
        self.testedAt = testedAt
    }
}

public enum ProviderCapabilityTester {
    /// A user-triggered, bounded test. It verifies actual stream reachability
    /// and tool-call transport without assuming any provider marketing claim.
    public static func test(profile: ProviderProfile, apiKey: String, networkRuntime: NetworkRuntime? = nil) async -> ProviderCapabilityTestResult {
        do {
            let client = try ProviderClientFactory.make(profile: profile, apiKey: apiKey, networkRuntime: networkRuntime)
            let tool = ToolSchema(
                name: "capability_echo",
                description: "Reply with the supplied value for a capability test.",
                parameters: .objectSchema(properties: ["value": .object(["type": .string("string")])], required: ["value"])
            )
            let request = ChatRequest(
                model: profile.model,
                messages: [
                    ChatMessage(role: "system", content: "For this capability test, call capability_echo exactly once with value ok."),
                    ChatMessage(role: "user", content: "Run the capability test.")
                ],
                maxTokens: 32,
                tools: [tool]
            )
            var sawResponse = false
            var sawTool = false
            for try await event in client.stream(request) {
                switch event {
                case .textDelta, .reasoningDelta, .usage, .usageDetails, .done:
                    sawResponse = true
                case .toolCall, .toolCallDelta:
                    sawResponse = true
                    sawTool = true
                }
            }
            var capabilities = profile.capabilities
            capabilities.toolCalling = sawTool
            return ProviderCapabilityTestResult(
                providerID: profile.id,
                succeeded: sawResponse,
                capabilities: capabilities,
                detail: sawTool ? "文本流与 Tool Calling 已通过真实测试" : "文本流已通过；Provider 未完成 Tool Calling 测试"
            )
        } catch {
            var disabled = profile.capabilities
            disabled.toolCalling = false
            return ProviderCapabilityTestResult(
                providerID: profile.id,
                succeeded: false,
                capabilities: disabled,
                detail: SecretRedactor.redact(error.localizedDescription)
            )
        }
    }
}
