import Foundation

public enum UsageLatency {
    /// Returns a non-negative, rounded duration suitable for user-visible usage
    /// telemetry. Callers pass request boundaries so queueing/tool time is not
    /// mistaken for a model-provider response time.
    public static func milliseconds(startedAt: Date, endedAt: Date = Date()) -> Int {
        max(0, Int((endedAt.timeIntervalSince(startedAt) * 1_000).rounded()))
    }
}

public enum UsageFeature: String, Codable, CaseIterable, Identifiable, Sendable {
    case mainAgent
    case exploreWorker
    case reviewWorker
    case browserWorker
    case summary
    case title
    case compaction

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .mainAgent: "Main Agent"
        case .exploreWorker: "Explore Worker"
        case .reviewWorker: "Review Worker"
        case .browserWorker: "Browser Worker"
        case .summary: "摘要"
        case .title: "标题"
        case .compaction: "上下文压缩"
        }
    }
}

public struct UsageRecord: Codable, Equatable, Sendable {
    public let feature: UsageFeature
    public let model: String
    public let inputTokens: Int
    public let cachedInputTokens: Int
    public let reasoningTokens: Int
    public let outputTokens: Int
    public let latencyMilliseconds: Int
    public let estimatedCost: Double
    public let succeeded: Bool
    public let providerID: String?
    public let routeID: String?
    public let requestID: String?
    public let cacheWriteInputTokens: Int?
    public let firstTokenLatencyMilliseconds: Int?
    public let toolWaitMilliseconds: Int?
    public let actualCost: Double?

    public init(feature: UsageFeature, model: String, inputTokens: Int, cachedInputTokens: Int, reasoningTokens: Int = 0, outputTokens: Int, latencyMilliseconds: Int, estimatedCost: Double, succeeded: Bool, providerID: String? = nil, routeID: String? = nil, requestID: String? = nil, cacheWriteInputTokens: Int? = nil, firstTokenLatencyMilliseconds: Int? = nil, toolWaitMilliseconds: Int? = nil, actualCost: Double? = nil) {
        self.feature = feature
        self.model = model
        self.inputTokens = inputTokens
        self.cachedInputTokens = cachedInputTokens
        self.reasoningTokens = reasoningTokens
        self.outputTokens = outputTokens
        self.latencyMilliseconds = latencyMilliseconds
        self.estimatedCost = estimatedCost
        self.succeeded = succeeded
        self.providerID = providerID
        self.routeID = routeID
        self.requestID = requestID
        self.cacheWriteInputTokens = cacheWriteInputTokens
        self.firstTokenLatencyMilliseconds = firstTokenLatencyMilliseconds
        self.toolWaitMilliseconds = toolWaitMilliseconds
        self.actualCost = actualCost
    }
}

public struct UsageLedger: Codable, Equatable, Sendable {
    public private(set) var total = UsageSummary()
    public private(set) var allRecords: [UsageRecord] = []

    public init() {}

    public init(records: [UsageRecord]) {
        self.init()
        for record in records {
            self.record(record)
        }
    }

    public mutating func record(_ value: UsageRecord) {
        allRecords.append(value)
        total = UsageSummary(
            inputTokens: total.inputTokens + value.inputTokens,
            cachedInputTokens: total.cachedInputTokens + value.cachedInputTokens,
            outputTokens: total.outputTokens + value.outputTokens,
            estimatedCost: (total.estimatedCost + value.estimatedCost).rounded(toPlaces: 6)
        )
    }

    public func records(for feature: UsageFeature) -> [UsageRecord] {
        allRecords.filter { $0.feature == feature }
    }

    /// Rebuilds a session ledger from persisted events. Older events without
    /// feature/model/latency metadata remain readable as main-agent records.
    public static func project(events: [SessionEvent], pricing: ProviderProfile) -> UsageLedger {
        var ledger = UsageLedger()
        for event in events where event.type == "usage_recorded" {
            let input = Int(event.payload["input"] ?? "0") ?? 0
            let cachedInput = Int(event.payload["cached_input"] ?? "0") ?? 0
            let reasoning = Int(event.payload["reasoning"] ?? "0") ?? 0
            let output = Int(event.payload["output"] ?? "0") ?? 0
            let latency = max(0, Int(event.payload["latency_ms"] ?? "0") ?? 0)
            let cacheWrite = max(0, Int(event.payload["cache_write_input"] ?? "0") ?? 0)
            let firstToken = Int(event.payload["first_token_ms"] ?? "")
            let toolWait = Int(event.payload["tool_wait_ms"] ?? "")
            let feature = UsageFeature(rawValue: event.payload["feature"] ?? "") ?? .mainAgent
            let model = event.payload["model"] ?? pricing.model
            var estimate = UsageSummary()
            estimate.record(input: input, cachedInput: cachedInput, output: output, pricing: pricing)
            ledger.record(UsageRecord(
                feature: feature,
                model: model,
                inputTokens: input,
                cachedInputTokens: cachedInput,
                reasoningTokens: reasoning,
                outputTokens: output,
                latencyMilliseconds: latency,
                estimatedCost: estimate.estimatedCost,
                succeeded: event.payload["succeeded"] != "false",
                providerID: event.payload["provider_id"],
                routeID: event.payload["route_id"],
                requestID: event.payload["request_id"],
                cacheWriteInputTokens: cacheWrite,
                firstTokenLatencyMilliseconds: firstToken,
                toolWaitMilliseconds: toolWait,
                actualCost: Double(event.payload["actual_cost"] ?? "")
            ))
        }
        return ledger
    }
}

private extension Double {
    func rounded(toPlaces places: Int) -> Double {
        let scale = pow(10.0, Double(places))
        return (self * scale).rounded() / scale
    }
}
