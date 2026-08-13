import Foundation

// MARK: - Search Intent

/// 搜索意图分类，用于智能选择搜索引擎
public enum SearchIntent: String, Codable, Sendable {
    case general          // 通用搜索
    case troubleshooting  // 错误排查
    case tutorial         // 教程/如何做
    case documentation    // API 文档
    case packageSearch    // 包/库搜索
    case realtime         // 实时信息（天气、新闻）
    case code             // 代码片段
    case discussion       // 社区讨论
}

// MARK: - Search Strategy

/// 搜索策略：决定使用哪些提供商
struct SearchStrategy {
    let intent: SearchIntent
    let providerIDs: [String]
    let parallelCount: Int  // 并行查询数量
    let requireAllSuccess: Bool  // 是否需要所有提供商都成功

    static let strategies: [SearchIntent: SearchStrategy] = [
        .general: SearchStrategy(
            intent: .general,
            providerIDs: ["duckduckgo", "bing"],
            parallelCount: 2,
            requireAllSuccess: false
        ),
        .troubleshooting: SearchStrategy(
            intent: .troubleshooting,
            providerIDs: ["stackoverflow", "duckduckgo"],
            parallelCount: 2,
            requireAllSuccess: false
        ),
        .tutorial: SearchStrategy(
            intent: .tutorial,
            providerIDs: ["duckduckgo"],
            parallelCount: 1,
            requireAllSuccess: false
        ),
        .documentation: SearchStrategy(
            intent: .documentation,
            providerIDs: ["duckduckgo"],
            parallelCount: 1,
            requireAllSuccess: false
        ),
        .realtime: SearchStrategy(
            intent: .realtime,
            providerIDs: ["duckduckgo", "bing"],
            parallelCount: 2,
            requireAllSuccess: false
        ),
        .code: SearchStrategy(
            intent: .code,
            providerIDs: ["github", "stackoverflow", "duckduckgo"],
            parallelCount: 3,
            requireAllSuccess: false
        ),
        .discussion: SearchStrategy(
            intent: .discussion,
            providerIDs: ["reddit", "stackoverflow", "duckduckgo"],
            parallelCount: 3,
            requireAllSuccess: false
        ),
        .packageSearch: SearchStrategy(
            intent: .packageSearch,
            providerIDs: ["github", "duckduckgo"],
            parallelCount: 2,
            requireAllSuccess: false
        )
    ]
}

// MARK: - Search Orchestrator

/// 搜索编排器：智能路由、并行查询、结果融合、缓存
public actor SearchOrchestrator {
    private let providers: [String: any SearchProvider]
    private let runtime: NetworkRuntime
    private let cache: SearchCache

    public init(providers: [any SearchProvider], runtime: NetworkRuntime = .shared, cache: SearchCache? = nil) {
        var providerMap: [String: any SearchProvider] = [:]
        for provider in providers {
            providerMap[provider.id] = provider
        }
        self.providers = providerMap
        self.runtime = runtime
        self.cache = cache ?? SearchCache()
    }

    /// 编排搜索：分析意图 → 检查缓存 → 并行查询 → 融合结果 → 缓存
    public func orchestrate(request: WebSearchRequest, context: NetworkContext) async throws -> OrchestratedSearchResponse {
        let startTime = Date()

        // 1. 分析查询意图
        let intent = analyzeIntent(request.query)
        print("🎯 [ORCHESTRATOR] Intent: \(intent.rawValue) for query: \(request.query)")

        // 2. 检查缓存
        if let cached = try? await cache.get(query: request.query, intent: intent) {
            print("⚡️ [ORCHESTRATOR] Cache hit! Age: \(Int(cached.cacheAge))s")
            let totalTime = Date().timeIntervalSince(startTime)

            return OrchestratedSearchResponse(
                results: Array(cached.results.prefix(request.maxResults)),
                intent: intent,
                providerResponses: cached.providerIDs.map { ProviderSearchResponse(providerID: $0, response: nil, error: nil) },
                totalResults: cached.results.count,
                deduplicatedCount: 0,
                searchTime: totalTime
            )
        }

        // 3. 获取搜索策略
        let strategy = SearchStrategy.strategies[intent] ?? SearchStrategy.strategies[.general]!

        // 4. 选择可用的提供商
        let selectedProviders = selectProviders(strategy: strategy)
        guard !selectedProviders.isEmpty else {
            throw SearchOrchestratorError.noProvidersAvailable
        }

        print("📡 [ORCHESTRATOR] Using \(selectedProviders.count) providers: \(selectedProviders.map { $0.id }.joined(separator: ", "))")

        // 5. 并行查询
        let responses = await queryInParallel(
            providers: selectedProviders,
            request: request,
            context: context,
            maxParallel: strategy.parallelCount
        )

        // 6. 融合结果
        let merged = mergeResults(responses: responses, intent: intent)

        // 7. 去重
        let deduplicated = deduplicateResults(merged)

        // 8. 排序
        let ranked = rankResults(deduplicated, query: request.query, intent: intent)

        // 9. 缓存结果
        let providerIDs = responses.compactMap { $0.response != nil ? $0.providerID : nil }
        try? await cache.set(query: request.query, intent: intent, results: ranked, providerIDs: providerIDs)

        let totalTime = Date().timeIntervalSince(startTime)
        print("✅ [ORCHESTRATOR] Completed in \(String(format: "%.2f", totalTime))s, \(ranked.count) results")

        let beforeDedup = merged.count
        let afterDedup = deduplicated.count

        return OrchestratedSearchResponse(
            results: Array(ranked.prefix(request.maxResults)),
            intent: intent,
            providerResponses: responses,
            totalResults: beforeDedup,
            deduplicatedCount: beforeDedup - afterDedup,
            searchTime: totalTime
        )
    }

    // MARK: - Intent Analysis

    private func analyzeIntent(_ query: String) -> SearchIntent {
        let lowercased = query.lowercased()

        // 错误排查
        if lowercased.contains("error") || lowercased.contains("报错") ||
           lowercased.contains("bug") || lowercased.contains("问题") ||
           lowercased.contains("failed") || lowercased.contains("不工作") {
            return .troubleshooting
        }

        // 教程
        if lowercased.contains("how to") || lowercased.contains("如何") ||
           lowercased.contains("怎么") || lowercased.contains("教程") ||
           lowercased.contains("tutorial") {
            return .tutorial
        }

        // 文档
        if lowercased.contains("api") || lowercased.contains("文档") ||
           lowercased.contains("documentation") || lowercased.contains("reference") ||
           lowercased.contains("docs") {
            return .documentation
        }

        // 包搜索
        if lowercased.contains("package") || lowercased.contains("库") ||
           lowercased.contains("npm") || lowercased.contains("pip") ||
           lowercased.contains("cargo") || lowercased.contains("gem") {
            return .packageSearch
        }

        // 实时信息
        if lowercased.contains("天气") || lowercased.contains("weather") ||
           lowercased.contains("新闻") || lowercased.contains("news") ||
           lowercased.contains("今天") || lowercased.contains("明天") ||
           lowercased.contains("today") || lowercased.contains("tomorrow") {
            return .realtime
        }

        // 代码
        if lowercased.contains("code") || lowercased.contains("代码") ||
           lowercased.contains("example") || lowercased.contains("示例") ||
           lowercased.contains("snippet") {
            return .code
        }

        // 讨论
        if lowercased.contains("discuss") || lowercased.contains("讨论") ||
           lowercased.contains("reddit") || lowercased.contains("community") {
            return .discussion
        }

        return .general
    }

    // MARK: - Provider Selection

    private func selectProviders(strategy: SearchStrategy) -> [any SearchProvider] {
        var selected: [any SearchProvider] = []

        for providerID in strategy.providerIDs {
            if let provider = providers[providerID] {
                selected.append(provider)
            }
        }

        return selected
    }

    // MARK: - Parallel Query

    private func queryInParallel(
        providers: [any SearchProvider],
        request: WebSearchRequest,
        context: NetworkContext,
        maxParallel: Int
    ) async -> [ProviderSearchResponse] {
        let effectiveParallel = min(maxParallel, providers.count)

        return await withTaskGroup(of: ProviderSearchResponse?.self) { group in
            for provider in providers.prefix(effectiveParallel) {
                group.addTask {
                    do {
                        let response = try await provider.search(request: request, context: context)
                        return ProviderSearchResponse(
                            providerID: provider.id,
                            response: response,
                            error: nil
                        )
                    } catch {
                        print("⚠️ [ORCHESTRATOR] Provider \(provider.id) failed: \(error.localizedDescription)")
                        return ProviderSearchResponse(
                            providerID: provider.id,
                            response: nil,
                            error: error
                        )
                    }
                }
            }

            var results: [ProviderSearchResponse] = []
            for await result in group {
                if let result = result {
                    results.append(result)
                }
            }
            return results
        }
    }

    // MARK: - Result Merging

    private func mergeResults(responses: [ProviderSearchResponse], intent: SearchIntent) -> [WebSourceRecord] {
        var merged: [WebSourceRecord] = []

        for response in responses {
            guard let searchResponse = response.response else { continue }
            merged.append(contentsOf: searchResponse.results)
        }

        return merged
    }

    // MARK: - Deduplication

    private func deduplicateResults(_ results: [WebSourceRecord]) -> [WebSourceRecord] {
        var seen = Set<String>()
        var deduplicated: [WebSourceRecord] = []

        for result in results {
            // 使用 canonicalURL 去重
            let normalizedURL = result.canonicalURL.lowercased()

            if !seen.contains(normalizedURL) {
                seen.insert(normalizedURL)
                deduplicated.append(result)
            }
        }

        return deduplicated
    }

    private func normalizeURL(_ url: String) -> String {
        guard let urlComponents = URLComponents(string: url) else {
            return url.lowercased()
        }

        var normalized = urlComponents
        normalized.query = nil
        normalized.fragment = nil

        return (normalized.url?.absoluteString ?? url).lowercased()
    }

    // MARK: - Ranking

    private func rankResults(_ results: [WebSourceRecord], query: String, intent: SearchIntent) -> [WebSourceRecord] {
        let keywords = extractKeywords(query)

        let scored = results.map { result in
            (result: result, score: calculateRelevanceScore(result, keywords: keywords, intent: intent))
        }

        return scored
            .sorted { $0.score > $1.score }
            .map(\.result)
    }

    private func extractKeywords(_ query: String) -> [String] {
        let stopWords = Set(["the", "a", "an", "in", "on", "at", "to", "for", "of", "是", "的", "在", "和", "与"])

        return query
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty && !stopWords.contains($0) }
    }

    private func calculateRelevanceScore(_ result: WebSourceRecord, keywords: [String], intent: SearchIntent) -> Double {
        var score = 0.0

        let title = result.title.lowercased()
        let snippet = result.snippet.lowercased()
        let url = result.canonicalURL.lowercased()

        // 标题匹配（权重最高）
        for keyword in keywords {
            if title.contains(keyword) {
                score += 3.0
            }
        }

        // 摘要匹配
        for keyword in keywords {
            if snippet.contains(keyword) {
                score += 1.5
            }
        }

        // URL 匹配
        for keyword in keywords {
            if url.contains(keyword) {
                score += 0.5
            }
        }

        // 域名权威性加分
        score += domainAuthorityBonus(url, intent: intent)

        return score
    }

    private func domainAuthorityBonus(_ url: String, intent: SearchIntent) -> Double {
        let authoritative: [String: Double] = [
            "github.com": 2.0,
            "stackoverflow.com": 2.0,
            "developer.mozilla.org": 2.0,
            "docs.microsoft.com": 1.5,
            "developer.apple.com": 1.5,
            "rust-lang.org": 1.5,
            "python.org": 1.5,
            "npmjs.com": 1.5,
            "wikipedia.org": 1.0,
            "medium.com": 0.5
        ]

        for (domain, bonus) in authoritative {
            if url.contains(domain) {
                return bonus
            }
        }

        return 0.0
    }
}

// MARK: - Supporting Types

public struct ProviderSearchResponse: Sendable {
    let providerID: String
    let response: WebSearchResponse?
    let error: Error?

    init(providerID: String, response: WebSearchResponse?, error: Error?) {
        self.providerID = providerID
        self.response = response
        self.error = error
    }
}

public struct OrchestratedSearchResponse: Sendable {
    public let results: [WebSourceRecord]
    public let intent: SearchIntent
    public let providerResponses: [ProviderSearchResponse]
    public let totalResults: Int
    public let deduplicatedCount: Int
    public let searchTime: TimeInterval
}

public enum SearchOrchestratorError: Error, LocalizedError {
    case noProvidersAvailable
    case allProvidersFailed

    public var errorDescription: String? {
        switch self {
        case .noProvidersAvailable:
            return "No search providers available"
        case .allProvidersFailed:
            return "All search providers failed"
        }
    }
}
