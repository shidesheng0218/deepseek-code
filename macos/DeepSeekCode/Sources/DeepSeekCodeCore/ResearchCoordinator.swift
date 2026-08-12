import Foundation

public enum ResearchStatus: String, Codable, CaseIterable, Sendable {
    case running
    case completed
    case insufficientSources
    case conflict
    case needsAttention
    case failed
}

public struct ResearchRequest: Codable, Equatable, Sendable {
    public let sessionID: String
    public let projectID: String?
    public let goal: String
    public let requirement: WebResearchRequirement
    public let seedQuery: String?
    public let preferredProviderID: String?
    public let requestedBy: String

    public init(
        sessionID: String,
        projectID: String? = nil,
        goal: String,
        requirement: WebResearchRequirement,
        seedQuery: String? = nil,
        preferredProviderID: String? = nil,
        requestedBy: String = "main-agent"
    ) {
        self.sessionID = sessionID
        self.projectID = projectID
        self.goal = goal
        self.requirement = requirement
        self.seedQuery = seedQuery
        self.preferredProviderID = preferredProviderID
        self.requestedBy = requestedBy
    }
}

public struct ResearchSummary: Codable, Equatable, Sendable {
    public let title: String
    public let conclusion: String
    public let highlights: [String]
    public let sourceBlocks: [String]
    public let citationLabels: [String]
    public let warnings: [String]
    public let conflicts: [String]
    public let contextBlock: String
    public let evidenceID: String

    public init(
        title: String,
        conclusion: String,
        highlights: [String],
        sourceBlocks: [String],
        citationLabels: [String],
        warnings: [String],
        conflicts: [String],
        contextBlock: String,
        evidenceID: String
    ) {
        self.title = title
        self.conclusion = conclusion
        self.highlights = highlights
        self.sourceBlocks = sourceBlocks
        self.citationLabels = citationLabels
        self.warnings = warnings
        self.conflicts = conflicts
        self.contextBlock = contextBlock
        self.evidenceID = evidenceID
    }
}

public struct ResearchRunState: Codable, Equatable, Sendable {
    public let request: ResearchRequest
    public var status: ResearchStatus
    public var queries: [String]
    public var providerHealth: [String: SearchProviderHealth]
    public var searchResponses: [WebSearchResponse]
    public var selectedSources: [WebSourceRecord]
    public var fetches: [WebFetchResponse]
    public var citations: [CitationCandidate]
    public var warnings: [String]
    public var conflicts: [String]
    public var summary: ResearchSummary?

    public init(
        request: ResearchRequest,
        status: ResearchStatus = .running,
        queries: [String] = [],
        providerHealth: [String: SearchProviderHealth] = [:],
        searchResponses: [WebSearchResponse] = [],
        selectedSources: [WebSourceRecord] = [],
        fetches: [WebFetchResponse] = [],
        citations: [CitationCandidate] = [],
        warnings: [String] = [],
        conflicts: [String] = [],
        summary: ResearchSummary? = nil
    ) {
        self.request = request
        self.status = status
        self.queries = queries
        self.providerHealth = providerHealth
        self.searchResponses = searchResponses
        self.selectedSources = selectedSources
        self.fetches = fetches
        self.citations = citations
        self.warnings = warnings
        self.conflicts = conflicts
        self.summary = summary
    }
}

public final class ResearchCoordinator: @unchecked Sendable {
    public typealias Fetcher = @Sendable (WebSourceRecord, NetworkContext) async throws -> WebFetchResponse

    private let searchProviders: [any SearchProvider]
    private let fetcher: Fetcher
    private let repository: SessionRepository?
    private let iso8601 = ISO8601DateFormatter()

    public init(
        searchProviders: [any SearchProvider],
        fetcher: @escaping Fetcher,
        repository: SessionRepository? = nil
    ) {
        self.searchProviders = searchProviders
        self.fetcher = fetcher
        self.repository = repository
        iso8601.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    }

    public convenience init(
        searchProviders: [any SearchProvider],
        networkRuntime: NetworkRuntime = .shared,
        repository: SessionRepository? = nil
    ) {
        self.init(searchProviders: searchProviders, fetcher: { source, context in
            try await Self.fetch(source: source, using: networkRuntime, context: context)
        }, repository: repository)
    }

    public func run(_ request: ResearchRequest) async -> ResearchRunState {
        var state = ResearchRunState(request: request)
        let queries = planQueries(request)
        state.queries = queries

        await persist(sessionID: request.sessionID, type: "research_started", payload: [
            "goal": request.goal,
            "queryCount": "\(queries.count)",
            "requiredSourceCount": "\(request.requirement.requiredSourceCount)",
            "requestedBy": request.requestedBy
        ])

        let healthContext = NetworkContext(
            sessionID: request.sessionID,
            projectID: request.projectID,
            purpose: .providerHealth,
            requestedBy: request.requestedBy
        )
        let providerOrdering = await self.orderedProviders(preferredProviderID: request.preferredProviderID, healthContext: healthContext)
        state.providerHealth = providerOrdering.health
        let orderedProviders = providerOrdering.providers

        var rawSources: [WebSourceRecord] = []
        let searchLimit = min(request.requirement.maxSearches, queries.count)
        for query in queries.prefix(searchLimit) {
            let searchResult = await runSearch(query: query, providers: orderedProviders, request: request, healthContext: healthContext)
            if let response = searchResult.response {
                state.searchResponses.append(response)
                rawSources.append(contentsOf: response.results)
                await persistSearchEvidence(query: query, response: response, request: request)
                await persist(sessionID: request.sessionID, type: "web_search_completed", payload: [
                    "query": query,
                    "providerID": response.providerID,
                    "requestID": response.requestID,
                    "resultCount": "\(response.results.count)",
                    "succeeded": "true"
                ])
            } else {
                await persist(sessionID: request.sessionID, type: "web_search_completed", payload: [
                    "query": query,
                    "providerID": searchResult.providerID ?? "",
                    "resultCount": "0",
                    "succeeded": "false",
                    "error": searchResult.error ?? "search failed"
                ])
                state.warnings.append("查询“\(query)”未返回可用来源")
            }
        }

        let dedupedSources = Self.deduplicate(rawSources)
        let selectedSources = ResearchSourceSelector.select(dedupedSources, requirement: request.requirement)
        state.selectedSources = selectedSources
        await persist(sessionID: request.sessionID, type: "web_source_selected", payload: [
            "sourceCount": "\(selectedSources.count)",
            "sourceIDs": selectedSources.map(\.id).joined(separator: "|")
        ])

        let fetchLimit = min(request.requirement.maxFetches, selectedSources.count)
        let fetchContext = NetworkContext(
            sessionID: request.sessionID,
            projectID: request.projectID,
            purpose: .researchFetch,
            requestedBy: request.requestedBy
        )
        let fetched = await fetchSources(Array(selectedSources.prefix(fetchLimit)), request: request, context: fetchContext)
        for result in fetched {
            switch result {
            case let .success(item):
                state.fetches.append(item.fetch)
                state.citations.append(contentsOf: item.fetch.citationCandidates)
                state.warnings.append(contentsOf: item.fetch.warnings)
                await persistFetchEvidence(source: item.source, fetch: item.fetch, request: request)
                await persist(sessionID: request.sessionID, type: "web_fetch_completed", payload: [
                    "sourceID": item.source.id,
                    "url": item.fetch.finalURL,
                    "status": "\(item.fetch.statusCode)",
                    "contentHash": item.fetch.contentHash,
                    "warningCount": "\(item.fetch.warnings.count)",
                    "citationCount": "\(item.fetch.citationCandidates.count)",
                    "succeeded": "true"
                ])
                for citation in item.fetch.citationCandidates {
                    await persist(sessionID: request.sessionID, type: "web_citation_recorded", payload: [
                        "citationID": citation.id,
                        "sourceID": citation.sourceID,
                        "quote": citation.quote,
                        "section": citation.section ?? "",
                        "contentHash": citation.contentHash
                    ])
                }
            case let .failure(item):
                state.conflicts.append("抓取 \(item.source.domain) 失败：\(item.error)")
                await persist(sessionID: request.sessionID, type: "web_fetch_completed", payload: [
                    "sourceID": item.source.id,
                    "url": item.source.canonicalURL,
                    "status": "0",
                    "error": item.error,
                    "succeeded": "false"
                ])
            }
        }

        state.warnings = Self.unique(state.warnings)
        state.conflicts = Self.unique(state.conflicts)

        if request.requirement.requireCitations && state.citations.isEmpty {
            state.conflicts.append("缺少可引用片段")
        }
        if request.requirement.requireOfficialSources && !request.requirement.preferredDomains.isEmpty {
            let hasOfficial = state.selectedSources.contains { source in
                request.requirement.preferredDomains.contains { preferred in
                    source.domain == preferred || source.domain.hasSuffix(".\(preferred)")
                }
            }
            if !hasOfficial {
                state.conflicts.append("未抓取到官方来源")
            }
        }

        state.conflicts = Self.unique(state.conflicts)

        if state.selectedSources.count < request.requirement.requiredSourceCount || state.fetches.count < request.requirement.requiredSourceCount || (request.requirement.requireCitations && state.citations.count < request.requirement.requiredSourceCount) {
            state.status = .insufficientSources
        } else if !state.conflicts.isEmpty {
            state.status = .conflict
        } else if !state.warnings.isEmpty {
            state.status = .needsAttention
        } else if state.searchResponses.isEmpty || state.fetches.isEmpty {
            state.status = .failed
        } else {
            state.status = .completed
        }

        let summary = Self.buildSummary(state: state)
        state.summary = summary
        await persist(sessionID: request.sessionID, type: "research_summary_generated", payload: [
            "evidenceID": summary.evidenceID,
            "summary": summary.conclusion,
            "status": state.status.rawValue,
            "succeeded": state.status == .completed ? "true" : "false"
        ])

        if state.status != .completed {
            let reason: String = switch state.status {
            case .running, .completed:
                "研究未完成"
            case .insufficientSources:
                "来源不足"
            case .conflict:
                "来源冲突"
            case .needsAttention:
                "存在风险或需要人工复核"
            case .failed:
                "研究失败"
            }
            await persist(sessionID: request.sessionID, type: "research_conflict_detected", payload: [
                "reason": reason,
                "warningCount": "\(state.warnings.count)",
                "conflictCount": "\(state.conflicts.count)"
            ])
            await persist(sessionID: request.sessionID, type: "research_failed", payload: [
                "reason": reason,
                "status": state.status.rawValue
            ])
        }

        return state
    }

    public func run(
        sessionID: String,
        projectID: String? = nil,
        goal: String,
        requirement: WebResearchRequirement,
        seedQuery: String? = nil,
        preferredProviderID: String? = nil,
        requestedBy: String = "main-agent"
    ) async -> ResearchRunState {
        await run(ResearchRequest(
            sessionID: sessionID,
            projectID: projectID,
            goal: goal,
            requirement: requirement,
            seedQuery: seedQuery,
            preferredProviderID: preferredProviderID,
            requestedBy: requestedBy
        ))
    }

    private func planQueries(_ request: ResearchRequest) -> [String] {
        let base = (request.seedQuery ?? request.goal).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !base.isEmpty else { return [request.goal] }
        var queries = [base]
        if let preferred = request.requirement.preferredDomains.first {
            queries.append("\(base) site:\(preferred)")
        }
        if request.requirement.requireOfficialSources {
            if let preferred = request.requirement.preferredDomains.dropFirst().first {
                queries.append("\(base) site:\(preferred)")
            } else {
                queries.append("\(base) official documentation")
            }
        } else {
            queries.append("\(base) documentation")
        }
        return Array(Self.unique(queries).prefix(3))
    }

    private struct ProviderOrdering: Sendable {
        let providers: [any SearchProvider]
        let health: [String: SearchProviderHealth]
    }

    private func orderedProviders(
        preferredProviderID: String?,
        healthContext: NetworkContext
    ) async -> ProviderOrdering {
        var providers = searchProviders
        if let preferredProviderID, let index = providers.firstIndex(where: { $0.id == preferredProviderID }) {
            let preferred = providers.remove(at: index)
            providers.insert(preferred, at: 0)
        }

        var health: [String: SearchProviderHealth] = [:]
        for provider in providers {
            let providerHealth = await provider.healthCheck(context: healthContext)
            health[provider.id] = providerHealth
        }
        let healthy = providers.filter { health[$0.id]?.reachable ?? false }
        return ProviderOrdering(providers: healthy.isEmpty ? providers : healthy, health: health)
    }

    private struct SearchOutcome: Sendable {
        let providerID: String?
        let response: WebSearchResponse?
        let error: String?
    }

    private func runSearch(
        query: String,
        providers: [any SearchProvider],
        request: ResearchRequest,
        healthContext: NetworkContext
    ) async -> SearchOutcome {
        var lastError: String?
        for provider in providers {
            let searchRequest = WebSearchRequest(query: query, maxResults: 8, providerID: provider.id)
            do {
                let response = try await provider.search(request: searchRequest, context: healthContext)
                if !response.results.isEmpty {
                    return SearchOutcome(providerID: provider.id, response: response, error: nil)
                }
                lastError = "未返回搜索结果"
            } catch {
                lastError = SecretRedactor.redact(error.localizedDescription)
            }
        }
        return SearchOutcome(providerID: providers.first?.id, response: nil, error: lastError)
    }

    private struct FetchOutcome: Sendable {
        let source: WebSourceRecord
        let fetch: WebFetchResponse
    }

    private struct FetchFailureOutcome: Sendable {
        let source: WebSourceRecord
        let error: String
    }

    private enum FetchResult: Sendable {
        case success(FetchOutcome)
        case failure(FetchFailureOutcome)
    }

    private func fetchSources(
        _ sources: [WebSourceRecord],
        request: ResearchRequest,
        context: NetworkContext
    ) async -> [FetchResult] {
        await withTaskGroup(of: (Int, FetchResult).self) { group in
            for (index, source) in sources.enumerated() {
                group.addTask {
                    do {
                        let fetch = try await self.fetcher(source, context)
                        return (index, .success(FetchOutcome(source: source, fetch: fetch)))
                    } catch {
                        return (index, .failure(FetchFailureOutcome(source: source, error: SecretRedactor.redact(error.localizedDescription))))
                    }
                }
            }
            var values: [(Int, FetchResult)] = []
            for await value in group { values.append(value) }
            return values.sorted { $0.0 < $1.0 }.map(\.1)
        }
    }

    private func persistSearchEvidence(query: String, response: WebSearchResponse, request: ResearchRequest) async {
        let searchURL = Self.searchURL(for: query)
        let evidence = WebEvidence(
            sourceURL: searchURL.absoluteString,
            finalURL: searchURL.absoluteString,
            title: "联网搜索：\(query)",
            contentType: "application/json",
            statusCode: 200,
            retrievedAt: iso8601.string(from: response.retrievedAt),
            contentHash: WebEvidenceInspector.sha256(response.results.map(\.canonicalURL).joined(separator: "|")),
            summary: response.results.first?.snippet ?? "",
            relevantSections: response.results.map { "\($0.title) — \($0.canonicalURL)" }.joined(separator: "\n"),
            warnings: response.results.flatMap(\.warnings),
            sources: response.results
        )
        await persistWebEvidence(evidence, sessionID: request.sessionID)
    }

    private func persistFetchEvidence(source: WebSourceRecord, fetch: WebFetchResponse, request: ResearchRequest) async {
        let evidence = WebEvidence(
            sourceURL: source.canonicalURL,
            finalURL: fetch.finalURL,
            sourceID: source.id,
            title: fetch.title ?? source.title,
            contentType: fetch.contentType,
            statusCode: fetch.statusCode,
            retrievedAt: iso8601.string(from: fetch.retrievedAt),
            contentHash: fetch.contentHash,
            summary: WebEvidenceInspector.summary(fetch.extractedText),
            relevantSections: WebEvidenceInspector.summary(fetch.extractedText, maxCharacters: 8_000),
            warnings: fetch.warnings,
            sources: [source],
            sections: fetch.sections,
            citations: fetch.citationCandidates
        )
        await persistWebEvidence(evidence, sessionID: request.sessionID)
    }

    private func persistWebEvidence(_ evidence: WebEvidence, sessionID: String) async {
        guard let data = try? JSONEncoder().encode(evidence),
              let encoded = String(data: data, encoding: .utf8) else { return }
        await persist(sessionID: sessionID, type: "web_evidence_recorded", payload: ["evidence": encoded])
    }

    private func persist(sessionID: String, type: String, payload: [String: String]) async {
        try? repository?.append(sessionID: sessionID, type: type, payload: payload)
    }

    private static func buildSummary(state: ResearchRunState) -> ResearchSummary {
        let sourceLabels = state.selectedSources.enumerated().map { "WEB-S\($0.offset + 1)" }
        let fetchedBySourceID = Dictionary(uniqueKeysWithValues: state.fetches.map { ($0.sourceID, $0) })
        let sourceBlocks = state.selectedSources.enumerated().map { index, source in
            let label = "WEB-S\(index + 1)"
            let fetch = fetchedBySourceID[source.id]
            let retrievedAt = fetch.map { Self.iso8601String(from: $0.retrievedAt) } ?? Self.iso8601String(from: source.retrievedAt)
            let title = fetch?.title ?? source.title
            let url = fetch?.finalURL ?? source.canonicalURL
            let excerpt = fetch.map { WebEvidenceInspector.summary($0.extractedText, maxCharacters: 400) } ?? WebEvidenceInspector.summary(source.snippet, maxCharacters: 400)
            let warnings = Self.unique(source.warnings + (fetch?.warnings ?? []))
            return """
            [\(label)]
            标题: \(title)
            URL: \(url)
            来源域名: \(source.domain)
            抓取时间: \(retrievedAt)
            相关片段: \(excerpt)
            警告: \(warnings.isEmpty ? "无" : warnings.joined(separator: "；"))
            """
        }
        let citationLabels = sourceLabels
        let highlights = state.fetches.map { WebEvidenceInspector.summary($0.extractedText, maxCharacters: 160) }
        var conclusionParts: [String] = ["围绕“\(state.request.goal)”完成了 \(state.selectedSources.count) 个来源的研究。"]
        if state.status == .completed {
            if !citationLabels.isEmpty {
                conclusionParts.append("建议优先参考 \(citationLabels.joined(separator: "、"))。")
            }
        } else if state.status == .insufficientSources {
            conclusionParts.append("来源不足，暂时不能交付。")
        } else if state.status == .conflict {
            conclusionParts.append("来源之间存在冲突，需要人工复核。")
        } else if state.status == .needsAttention {
            conclusionParts.append("研究结果包含风险或警告，需要人工确认。")
        } else if state.status == .failed {
            conclusionParts.append("研究失败，未能形成可靠结论。")
        }
        if !state.warnings.isEmpty {
            conclusionParts.append("警告：\(state.warnings.joined(separator: "；"))")
        }
        if !state.conflicts.isEmpty {
            conclusionParts.append("冲突：\(state.conflicts.joined(separator: "；"))")
        }
        let conclusion = conclusionParts.joined(separator: " ")
        let contextBlock = ([conclusion] + sourceBlocks).joined(separator: "\n\n")
        let evidenceID = "research-summary-\(WebEvidenceInspector.sha256(contextBlock).prefix(16))"
        return ResearchSummary(
            title: "联网研究：\(state.request.goal)",
            conclusion: conclusion,
            highlights: highlights,
            sourceBlocks: sourceBlocks,
            citationLabels: citationLabels,
            warnings: state.warnings,
            conflicts: state.conflicts,
            contextBlock: contextBlock,
            evidenceID: evidenceID
        )
    }

    private static func searchURL(for query: String) -> URL {
        var components = URLComponents(string: "https://search.local/")!
        components.queryItems = [URLQueryItem(name: "q", value: query)]
        return components.url ?? URL(string: "https://search.local/")!
    }

    private static func deduplicate(_ sources: [WebSourceRecord]) -> [WebSourceRecord] {
        var seen: Set<String> = []
        var uniqueSources: [WebSourceRecord] = []
        for source in sources where seen.insert(source.canonicalURL).inserted {
            uniqueSources.append(source)
        }
        uniqueSources.sort { lhs, rhs in
            let lhsPreferred = lhs.rank
            let rhsPreferred = rhs.rank
            if lhsPreferred != rhsPreferred { return lhsPreferred < rhsPreferred }
            return lhs.domain < rhs.domain
        }
        return uniqueSources
    }

    private static func unique(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        return values.filter { seen.insert($0).inserted }
    }

    private static func iso8601String(from date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private static func fetch(
        source: WebSourceRecord,
        using runtime: NetworkRuntime,
        context: NetworkContext
    ) async throws -> WebFetchResponse {
        guard let url = URL(string: source.canonicalURL) else {
            throw WebFetchError.invalidContent
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 30
        request.setValue("DeepSeek Code/1.0", forHTTPHeaderField: "User-Agent")
        request.setValue("text/html, application/xhtml+xml, text/plain, application/json, application/pdf", forHTTPHeaderField: "Accept")
        let (data, response) = try await runtime.data(for: request, scope: .webFetch, context: context, maxBytes: 2 * 1024 * 1024)
        let contentType = response.value(forHTTPHeaderField: "Content-Type") ?? ""
        let finalURL = response.url?.absoluteString ?? url.absoluteString
        return try WebContentExtractor.extract(
            data: data,
            contentType: contentType,
            sourceID: source.id,
            sourceURL: source.canonicalURL,
            finalURL: finalURL,
            statusCode: response.statusCode
        )
    }
}
