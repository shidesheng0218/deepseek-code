import Foundation

public enum ReviewWorker {
    public static let systemPrompt = """
    你是 DeepSeek Code 的只读代码审查 Worker。只审查用户提供的 Git Diff，不修改文件，不执行命令。
    只输出 JSON 对象，不要解释。格式：
    {"findings":[{"severity":"P0|P1|P2|P3","category":"correctness|security|performance|maintainability|test-gap","file":"相对路径","startLine":1,"endLine":1,"title":"问题标题","evidence":"证据","recommendation":"建议"}]}
    只报告有证据的问题，避免风格偏好；没有问题时输出 {"findings":[]}。
    """

    public static func parse(response: String) -> [ReviewFinding] {
        let candidate = extractJSONObject(from: response)
        guard let data = candidate.data(using: .utf8),
              let envelope = try? JSONDecoder().decode(Envelope.self, from: data) else {
            return []
        }
        return envelope.findings.map { value in
            ReviewFinding(
                severity: ReviewFinding.Severity(rawValue: value.severity.lowercased()) ?? .p2,
                category: ReviewFinding.Category(rawValue: value.category.lowercased()) ?? .maintainability,
                file: value.file,
                startLine: max(1, value.startLine),
                endLine: max(max(1, value.startLine), value.endLine),
                title: value.title,
                evidence: value.evidence,
                recommendation: value.recommendation
            )
        }
    }

    private static func extractJSONObject(from response: String) -> String {
        let value = response.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let start = value.firstIndex(of: "{"), let end = value.lastIndex(of: "}") else { return value }
        return String(value[start...end])
    }

    private struct Envelope: Decodable {
        let findings: [Finding]
    }

    private struct Finding: Decodable {
        let severity: String
        let category: String
        let file: String
        let startLine: Int
        let endLine: Int
        let title: String
        let evidence: String
        let recommendation: String
    }
}

public enum ReviewWorkerEvent: Sendable, Equatable {
    case textDelta(String)
    case usage(input: Int, cachedInput: Int, output: Int, latencyMilliseconds: Int)
    case completed(findings: [ReviewFinding])
}

public final class DeepSeekReviewWorker: @unchecked Sendable {
    private let client: any ChatStreaming
    private let model: String

    public init(client: any ChatStreaming, model: String) {
        self.client = client
        self.model = model
    }

    public func run(diff: String) -> AsyncThrowingStream<ReviewWorkerEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    let request = ChatRequest(
                        model: model,
                        messages: [
                            ChatMessage(role: "system", content: ReviewWorker.systemPrompt),
                            ChatMessage(role: "user", content: "请审查以下 Diff：\n\n\(diff)")
                        ],
                        maxTokens: 4096,
                        thinking: true
                    )
                    var response = ""
                    let modelRequestStartedAt = Date()
                    for try await event in client.stream(request) {
                        switch event {
                        case let .textDelta(text):
                            response.append(text)
                            continuation.yield(.textDelta(text))
                        case .reasoningDelta:
                            continue
                        case let .usage(input, cachedInput, output):
                            continuation.yield(.usage(
                                input: input,
                                cachedInput: cachedInput,
                                output: output,
                                latencyMilliseconds: UsageLatency.milliseconds(startedAt: modelRequestStartedAt)
                            ))
                        case let .usageDetails(usage):
                            continuation.yield(.usage(
                                input: usage.inputTokens,
                                cachedInput: usage.cacheReadInputTokens,
                                output: usage.outputTokens,
                                latencyMilliseconds: UsageLatency.milliseconds(startedAt: modelRequestStartedAt)
                            ))
                        case .done:
                            continue
                        case .toolCall, .toolCallDelta:
                            continue
                        }
                    }
                    continuation.yield(.completed(findings: ReviewWorker.parse(response: response)))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }
}
