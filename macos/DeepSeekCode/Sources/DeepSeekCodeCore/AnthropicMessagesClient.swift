import Foundation

/// Native Anthropic Messages client. It shares the product's ProviderStreamEvent
/// contract so the supervisor never has to understand provider-specific SSE.
public final class AnthropicMessagesClient: @unchecked Sendable, ChatStreaming {
    private let endpoint: URL
    private let apiKey: String
    private let networkPolicy: NetworkPolicy
    private let networkRuntime: NetworkRuntime?
    private let networkContext: NetworkContext?

    public init(baseURL: String, apiKey: String, networkPolicy: NetworkPolicy = .default, networkRuntime: NetworkRuntime? = nil, networkContext: NetworkContext? = nil) throws {
        guard let base = URL(string: baseURL), base.scheme != nil, base.host != nil,
              networkPolicy.decision(for: base, scope: .modelProvider) == .allow else {
            throw ProviderRequestError.invalidEndpoint
        }
        endpoint = base.appendingPathComponent("messages")
        self.apiKey = apiKey
        self.networkPolicy = networkPolicy
        self.networkRuntime = networkRuntime
        self.networkContext = networkContext
    }

    public func stream(_ request: ChatRequest) -> AsyncThrowingStream<ProviderStreamEvent, Error> {
        let canonical = CanonicalLLMRequest.from(chatRequest: request, providerID: "anthropic")
        return stream(canonical)
    }

    public func stream(_ request: CanonicalLLMRequest) -> AsyncThrowingStream<ProviderStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    let body = try AnthropicMessagesLowerer.lower(request)
                    var urlRequest = URLRequest(url: endpoint)
                    urlRequest.httpMethod = "POST"
                    urlRequest.timeoutInterval = 120
                    urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    urlRequest.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                    urlRequest.setValue(apiKey, forHTTPHeaderField: "x-api-key")
                    urlRequest.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
                    urlRequest.httpBody = try JSONEncoder().encode(body)

                    var state = AnthropicStreamState()
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
                                if try AnthropicSSEDecoder.consume(line: line, state: &state, continuation: continuation) { break }
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
                            var responseBody = ""
                            for try await line in bytes.lines {
                                responseBody += line
                                if responseBody.utf8.count >= 4_096 { break }
                            }
                            throw ProviderRequestError.httpStatus(code: http.statusCode, body: responseBody)
                        }
                        for try await line in bytes.lines {
                            if try AnthropicSSEDecoder.consume(line: line, state: &state, continuation: continuation) { break }
                        }
                    }
                    if !state.didFinish { continuation.yield(.done) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }
}

public extension CanonicalLLMRequest {
    static func from(chatRequest: ChatRequest, providerID: String) -> CanonicalLLMRequest {
        let system = chatRequest.messages.filter { $0.role == "system" }.map(\.content)
        let messages = chatRequest.messages
            .filter { $0.role != "system" }
            .map {
                CanonicalMessage(
                    role: CanonicalMessageRole(rawValue: $0.role) ?? .user,
                    parts: $0.parts,
                    toolCallID: $0.toolCallID,
                    toolCalls: $0.toolCalls
                )
            }
        return CanonicalLLMRequest(
            providerID: providerID,
            model: chatRequest.model,
            system: system,
            messages: messages,
            tools: chatRequest.tools ?? [],
            generation: GenerationPolicy(maxTokens: chatRequest.maxTokens, thinking: chatRequest.thinking?.type == "enabled"),
            cache: .auto
        )
    }
}

private struct AnthropicStreamState {
    var inputTokens = 0
    var cacheReadTokens = 0
    var cacheWriteTokens = 0
    var didEmitUsage = false
    var didFinish = false
}

private enum AnthropicSSEDecoder {
    static func consume(
        line: String,
        state: inout AnthropicStreamState,
        continuation: AsyncThrowingStream<ProviderStreamEvent, Error>.Continuation
    ) throws -> Bool {
        guard line.hasPrefix("data:") else { return false }
        let raw = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
        guard !raw.isEmpty,
              let object = try JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any],
              let type = object["type"] as? String else { return false }

        switch type {
        case "error":
            let error = object["error"] as? [String: Any]
            let detail = error?["message"] as? String ?? "Anthropic 请求失败"
            throw ProviderRequestError.httpStatus(code: 0, body: detail)
        case "message_start":
            let message = object["message"] as? [String: Any]
            let usage = message?["usage"] as? [String: Any]
            state.inputTokens = usage?["input_tokens"] as? Int ?? 0
            state.cacheReadTokens = usage?["cache_read_input_tokens"] as? Int ?? 0
            state.cacheWriteTokens = usage?["cache_creation_input_tokens"] as? Int ?? 0
        case "content_block_start":
            guard let index = object["index"] as? Int,
                  let block = object["content_block"] as? [String: Any],
                  block["type"] as? String == "tool_use",
                  let id = block["id"] as? String,
                  let name = block["name"] as? String else { break }
            continuation.yield(.toolCallDelta(index: index, id: id, name: name, arguments: nil))
        case "content_block_delta":
            guard let index = object["index"] as? Int,
                  let delta = object["delta"] as? [String: Any],
                  let deltaType = delta["type"] as? String else { break }
            if deltaType == "text_delta", let text = delta["text"] as? String {
                continuation.yield(.textDelta(text))
            } else if deltaType == "input_json_delta", let partial = delta["partial_json"] as? String {
                continuation.yield(.toolCallDelta(index: index, id: nil, name: nil, arguments: partial))
            }
        case "message_delta":
            let usage = object["usage"] as? [String: Any]
            let output = usage?["output_tokens"] as? Int ?? 0
            if state.cacheWriteTokens > 0 {
                continuation.yield(.usageDetails(NormalizedUsage(inputTokens: state.inputTokens, cacheReadInputTokens: state.cacheReadTokens, cacheWriteInputTokens: state.cacheWriteTokens, outputTokens: output)))
            } else {
                continuation.yield(.usage(input: state.inputTokens, cachedInput: state.cacheReadTokens, output: output))
            }
            state.didEmitUsage = true
        case "message_stop":
            if !state.didEmitUsage {
                if state.cacheWriteTokens > 0 {
                    continuation.yield(.usageDetails(NormalizedUsage(inputTokens: state.inputTokens, cacheReadInputTokens: state.cacheReadTokens, cacheWriteInputTokens: state.cacheWriteTokens, outputTokens: 0)))
                } else {
                    continuation.yield(.usage(input: state.inputTokens, cachedInput: state.cacheReadTokens, output: 0))
                }
            }
            continuation.yield(.done)
            state.didFinish = true
            return true
        default:
            break
        }
        return false
    }
}
