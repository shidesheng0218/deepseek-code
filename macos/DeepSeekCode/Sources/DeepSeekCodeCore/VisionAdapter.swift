import Foundation

public final class OpenAICompatibleVisionAdapter: @unchecked Sendable {
    private let client: OpenAICompatibleClient
    private let model: String

    public init(baseURL: String, apiKey: String, model: String, attachmentProvider: any AttachmentDataProvider) throws {
        self.client = try OpenAICompatibleClient(baseURL: baseURL, apiKey: apiKey, attachmentProvider: attachmentProvider)
        self.model = model
    }

    public func observe(attachment: AttachmentRef, task: String) async throws -> VisualObservation {
        let request = ChatRequest(
            model: model,
            messages: [
                ChatMessage(role: "system", content: "你是视觉观察器。只输出 JSON，不调用工具。字段为 summary、visibleText、uiElements、errors、uncertainty。"),
                ChatMessage(role: "user", parts: [.text(task), .image(attachment)])
            ],
            maxTokens: 2_048,
            tools: []
        )
        var output = ""
        for try await event in client.stream(request) {
            if case let .textDelta(text) = event { output += text }
        }
        if let data = output.data(using: .utf8), let observation = try? JSONDecoder().decode(VisualObservation.self, from: data) {
            return observation
        }
        return VisualObservation(summary: output.trimmingCharacters(in: .whitespacesAndNewlines), uncertainty: ["视觉适配器没有返回符合 Schema 的 JSON"], sourceAttachmentID: attachment.id)
    }
}
