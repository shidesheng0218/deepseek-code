import Foundation

public enum ProviderClientFactory {
    public static func make(
        profile: ProviderProfile,
        apiKey: String,
        attachmentProvider: (any AttachmentDataProvider)? = nil,
        networkRuntime: NetworkRuntime? = nil,
        networkContext: NetworkContext? = nil
    ) throws -> any ChatStreaming {
        switch profile.protocolName {
        case .openAICompatible:
            return try OpenAICompatibleClient(
                baseURL: profile.baseURL,
                apiKey: apiKey,
                attachmentProvider: attachmentProvider,
                networkRuntime: networkRuntime,
                networkContext: networkContext
            )
        case .anthropicCompatible:
            return try AnthropicMessagesClient(
                baseURL: profile.baseURL,
                apiKey: apiKey,
                networkRuntime: networkRuntime,
                networkContext: networkContext
            )
        }
    }
}
