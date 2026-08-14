import Foundation

public struct SearchProviderConfiguration: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public var name: String
    public var endpoint: String
    public var queryParameter: String
    public var authorizationReference: String?
    public var enabled: Bool

    public init(
        id: String,
        name: String,
        endpoint: String,
        queryParameter: String = "q",
        authorizationReference: String? = nil,
        enabled: Bool = true
    ) {
        self.id = id
        self.name = name
        self.endpoint = endpoint
        self.queryParameter = queryParameter
        self.authorizationReference = authorizationReference
        self.enabled = enabled
    }

    public var isValid: Bool {
        guard !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !queryParameter.isEmpty,
              let url = URL(string: endpoint),
              let scheme = url.scheme?.lowercased(),
              url.host != nil,
              url.user == nil,
              url.password == nil,
              let host = url.host,
              !NetworkPolicy.isUnsafeHost(host) else { return false }
        return scheme == "http" || scheme == "https"
    }
}

public struct SearchProviderHealth: Codable, Equatable, Sendable {
    public let providerID: String
    public let reachable: Bool
    public let statusCode: Int?
    public let detail: String

    public init(providerID: String, reachable: Bool, statusCode: Int? = nil, detail: String) {
        self.providerID = providerID
        self.reachable = reachable
        self.statusCode = statusCode
        self.detail = detail
    }
}

public struct SearchProviderCapabilities: Codable, Equatable, Sendable {
    public let supportsLanguage: Bool
    public let supportsRegion: Bool
    public let supportsFreshness: Bool
    public let requiresCredential: Bool

    public init(supportsLanguage: Bool = false, supportsRegion: Bool = false, supportsFreshness: Bool = false, requiresCredential: Bool = false) {
        self.supportsLanguage = supportsLanguage
        self.supportsRegion = supportsRegion
        self.supportsFreshness = supportsFreshness
        self.requiresCredential = requiresCredential
    }
}

public enum SearchFreshness: String, Codable, CaseIterable, Sendable {
    case day
    case week
    case month
}

public struct WebSearchRequest: Codable, Equatable, Sendable {
    public let query: String
    public let maxResults: Int
    public let language: String?
    public let region: String?
    public let freshness: SearchFreshness?
    public let providerID: String?

    public init(query: String, maxResults: Int = 8, language: String? = nil, region: String? = nil, freshness: SearchFreshness? = nil, providerID: String? = nil) {
        self.query = query
        // The provider may know about more sources, but the model-facing
        // contract is intentionally bounded. Eight source cards are enough
        // for a grounded follow-up while preventing one tool call from
        // flooding the conversation context.
        self.maxResults = min(8, max(1, maxResults))
        self.language = language
        self.region = region
        self.freshness = freshness
        self.providerID = providerID
    }
}

public struct WebSearchResult: Codable, Equatable, Sendable {
    public let title: String
    public let url: String
    public let snippet: String
    public let providerID: String

    public init(title: String, url: String, snippet: String, providerID: String) {
        self.title = title
        self.url = url
        self.snippet = snippet
        self.providerID = providerID
    }
}

public struct WebSourceRecord: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let canonicalURL: String
    public let title: String
    public let snippet: String
    public let providerID: String
    public let rank: Int
    public let domain: String
    public let contentHash: String?
    public let retrievedAt: Date
    public let warnings: [String]

    private enum CodingKeys: String, CodingKey {
        case id, canonicalURL, title, snippet, providerID, rank, domain, contentHash, retrievedAt, warnings
    }

    public init(id: String, canonicalURL: String, title: String, snippet: String, providerID: String, rank: Int, domain: String, contentHash: String? = nil, retrievedAt: Date, warnings: [String] = []) {
        self.id = id
        self.canonicalURL = canonicalURL
        self.title = title
        self.snippet = snippet
        self.providerID = providerID
        self.rank = rank
        self.domain = domain
        self.contentHash = contentHash
        self.retrievedAt = retrievedAt
        self.warnings = warnings
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        canonicalURL = try container.decode(String.self, forKey: .canonicalURL)
        title = try container.decode(String.self, forKey: .title)
        snippet = try container.decode(String.self, forKey: .snippet)
        providerID = try container.decode(String.self, forKey: .providerID)
        rank = try container.decode(Int.self, forKey: .rank)
        domain = try container.decode(String.self, forKey: .domain)
        contentHash = try container.decodeIfPresent(String.self, forKey: .contentHash)
        warnings = try container.decodeIfPresent([String].self, forKey: .warnings) ?? []
        if let dateString = try container.decodeIfPresent(String.self, forKey: .retrievedAt),
           let parsed = WebSourceRecord.parseDate(dateString) {
            retrievedAt = parsed
        } else if let seconds = try container.decodeIfPresent(Double.self, forKey: .retrievedAt) {
            retrievedAt = Date(timeIntervalSince1970: seconds)
        } else if let milliseconds = try container.decodeIfPresent(Int.self, forKey: .retrievedAt) {
            retrievedAt = Date(timeIntervalSince1970: TimeInterval(milliseconds))
        } else {
            retrievedAt = Date()
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(canonicalURL, forKey: .canonicalURL)
        try container.encode(title, forKey: .title)
        try container.encode(snippet, forKey: .snippet)
        try container.encode(providerID, forKey: .providerID)
        try container.encode(rank, forKey: .rank)
        try container.encode(domain, forKey: .domain)
        try container.encodeIfPresent(contentHash, forKey: .contentHash)
        try container.encode(WebSourceRecord.iso8601String(from: retrievedAt), forKey: .retrievedAt)
        try container.encode(warnings, forKey: .warnings)
    }

    private static func iso8601String(from date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private static func parseDate(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let parsed = formatter.date(from: value) {
            return parsed
        }
        let fallback = ISO8601DateFormatter()
        if let parsed = fallback.date(from: value) {
            return parsed
        }
        if let seconds = Double(value) {
            return Date(timeIntervalSince1970: seconds)
        }
        return nil
    }
}

public struct WebSearchResponse: Codable, Equatable, Sendable {
    public let providerID: String
    public let results: [WebSourceRecord]
    public let retrievedAt: Date
    public let requestID: String

    public init(providerID: String, results: [WebSourceRecord], retrievedAt: Date = Date(), requestID: String = UUID().uuidString) {
        self.providerID = providerID
        self.results = results
        self.retrievedAt = retrievedAt
        self.requestID = requestID
    }
}

public enum WebSourceNormalizer {
    public static func normalize(_ results: [WebSearchResult], providerID: String, preferredDomains: [String] = [], retrievedAt: Date = Date()) -> [WebSourceRecord] {
        let preferred = Set(preferredDomains.map { $0.lowercased() })
        var seen: Set<String> = []
        var values: [(result: WebSearchResult, url: String, domain: String, index: Int)] = []

        for (index, result) in results.enumerated() {
            guard let normalized = canonicalURL(result.url),
                  let url = URL(string: normalized),
                  let host = url.host?.lowercased(),
                  seen.insert(normalized).inserted else { continue }
            values.append((result, normalized, host, index))
        }

        values.sort { lhs, rhs in
            let lhsPreferred = preferred.contains(lhs.domain) || preferred.contains { lhs.domain.hasSuffix(".\($0)") }
            let rhsPreferred = preferred.contains(rhs.domain) || preferred.contains { rhs.domain.hasSuffix(".\($0)") }
            if lhsPreferred != rhsPreferred { return lhsPreferred }
            return lhs.index < rhs.index
        }

        return values.enumerated().map { index, value in
            let warnings = WebEvidenceInspector.warnings(for: "\(value.result.title)\n\(value.result.snippet)")
            return WebSourceRecord(
                id: "web-source-\(WebEvidenceInspector.sha256(value.url).prefix(16))",
                canonicalURL: value.url,
                title: value.result.title.trimmingCharacters(in: .whitespacesAndNewlines),
                snippet: value.result.snippet.trimmingCharacters(in: .whitespacesAndNewlines),
                providerID: providerID,
                rank: index + 1,
                domain: value.domain,
                retrievedAt: retrievedAt,
                warnings: warnings
            )
        }
    }

    public static func canonicalURL(_ rawValue: String) -> String? {
        guard var components = URLComponents(string: rawValue),
              let scheme = components.scheme?.lowercased(),
              (scheme == "http" || scheme == "https"),
              let host = components.host?.lowercased(),
              !host.isEmpty,
              components.user == nil,
              components.password == nil,
              !NetworkPolicy.isUnsafeHost(host) else { return nil }
        components.scheme = scheme
        components.host = host
        components.fragment = nil
        let retainedQueryItems = components.queryItems?.filter { item in
            let name = item.name.lowercased()
            return !name.hasPrefix("utm_") && !["gclid", "fbclid", "mc_cid", "mc_eid"].contains(name)
        }
        components.queryItems = retainedQueryItems?.isEmpty == true ? nil : retainedQueryItems
        if components.path.count > 1, components.path.hasSuffix("/") {
            components.path.removeLast()
        }
        return components.url?.absoluteString
    }
}

public protocol SearchProvider: Sendable {
    var id: String { get }
    var capabilities: SearchProviderCapabilities { get }
    func search(request: WebSearchRequest, context: NetworkContext) async throws -> WebSearchResponse
    func healthCheck(context: NetworkContext) async -> SearchProviderHealth
}

/// Product-facing name for the provider-neutral `web_search` seam.
public typealias WebSearchProvider = SearchProvider

public extension SearchProvider {
    func search(query: String, maxResults: Int) async throws -> [WebSearchResult] {
        let response = try await search(
            request: WebSearchRequest(query: query, maxResults: maxResults),
            context: NetworkContext(sessionID: "network-legacy", purpose: .researchSearch, requestedBy: "legacy-search")
        )
        return response.results.map { WebSearchResult(title: $0.title, url: $0.canonicalURL, snippet: $0.snippet, providerID: $0.providerID) }
    }

    func healthCheck() async -> SearchProviderHealth {
        await healthCheck(context: NetworkContext(sessionID: "network-settings", purpose: .providerHealth, requestedBy: "settings"))
    }
}

public struct DuckDuckGoSearchProvider: SearchProvider {
    public let id = "duckduckgo"
    public let runtime: NetworkRuntime
    public let capabilities = SearchProviderCapabilities()

    public init(runtime: NetworkRuntime = .shared) {
        self.runtime = runtime
    }

    public func search(request: WebSearchRequest, context: NetworkContext) async throws -> WebSearchResponse {
        print("→ [DDG] Searching: \(request.query)")

        var components = URLComponents(string: "https://html.duckduckgo.com/html/")!
        components.queryItems = [URLQueryItem(name: "q", value: request.query)]
        var urlRequest = URLRequest(url: components.url!)
        urlRequest.httpMethod = "GET"
        urlRequest.timeoutInterval = 30

        // 使用真实浏览器 User-Agent，避免被识别为爬虫
        urlRequest.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36", forHTTPHeaderField: "User-Agent")
        urlRequest.setValue("text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")
        urlRequest.setValue("en-US,en;q=0.9,zh-CN;q=0.8", forHTTPHeaderField: "Accept-Language")

        let (data, _) = try await runtime.data(for: urlRequest, scope: .webSearch, context: context, maxBytes: 512_000)
        let html = String(decoding: data, as: UTF8.self)

        // 尝试多个 pattern，提高解析成功率
        let patterns = [
            // Pattern 1: 原始格式
            #"result__a[^>]*href="([^"]+)"[^>]*>(.*?)</a>.*?result__snippet[^>]*>(.*?)</a>|result__a[^>]*href="([^"]+)"[^>]*>(.*?)</a>.*?result__snippet[^>]*>(.*?)</div>"#,
            // Pattern 2: 宽松格式
            #"<a[^>]*class=\"result__a\"[^>]*href=\"([^\"]+)\"[^>]*>(.*?)</a>.*?<a[^>]*class=\"result__snippet\"[^>]*>(.*?)</a>"#,
            // Pattern 3: 更宽松（适应结构变化）
            #"result__a\"[^>]*href=\"([^\"]+)\">(.*?)</a>.*?result__snippet\">(.*?)</(?:a|div)>"#,
        ]

        var rawResults: [WebSearchResult] = []

        for (index, pattern) in patterns.enumerated() {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else {
                continue
            }

            let range = NSRange(html.startIndex..<html.endIndex, in: html)
            let matches = regex.matches(in: html, range: range).prefix(request.maxResults)

            rawResults = matches.compactMap { match in
                let url = Self.capture(match, html: html, index: 1) ?? Self.capture(match, html: html, index: 4)
                let title = Self.capture(match, html: html, index: 2) ?? Self.capture(match, html: html, index: 5)
                let snippet = Self.capture(match, html: html, index: 3) ?? Self.capture(match, html: html, index: 6)
                guard let url, let title else { return nil }

                return WebSearchResult(
                    title: Self.stripHTML(title),
                    url: Self.cleanURL(url),
                    snippet: Self.stripHTML(snippet ?? ""),
                    providerID: id
                )
            }

            if !rawResults.isEmpty {
                print("✅ [DDG] Pattern \(index + 1) matched \(rawResults.count) results")
                break
            }
        }

        if rawResults.isEmpty {
            print("⚠️ [DDG] No results parsed (HTML: \(html.count) chars)")
            #if DEBUG
            let timestamp = Int(Date().timeIntervalSince1970)
            if let tempDir = FileManager.default.temporaryDirectory as URL? {
                let debugFile = tempDir.appendingPathComponent("ddg-\(timestamp).html")
                try? html.write(to: debugFile, atomically: true, encoding: .utf8)
                print("→ [DDG] Debug: \(debugFile.path)")
            }
            #endif
        }

        let retrievedAt = Date()
        return WebSearchResponse(providerID: id, results: WebSourceNormalizer.normalize(rawResults, providerID: id, retrievedAt: retrievedAt), retrievedAt: retrievedAt)
    }

    public func healthCheck(context: NetworkContext) async -> SearchProviderHealth {
        do {
            let response = try await search(request: WebSearchRequest(query: "DeepSeek", maxResults: 1), context: context)
            return SearchProviderHealth(providerID: id, reachable: !response.results.isEmpty, statusCode: 200, detail: response.results.isEmpty ? "未返回搜索结果" : "搜索响应正常")
        } catch {
            return SearchProviderHealth(providerID: id, reachable: false, detail: SecretRedactor.redact(error.localizedDescription))
        }
    }

    private static func capture(_ match: NSTextCheckingResult, html: String, index: Int) -> String? {
        guard index < match.numberOfRanges else { return nil }
        let range = match.range(at: index)
        guard range.location != NSNotFound, let swiftRange = Range(range, in: html) else { return nil }
        return String(html[swiftRange])
    }

    private static func cleanURL(_ url: String) -> String {
        // 处理 DuckDuckGo 重定向：//duckduckgo.com/l/?uddg=...
        if url.contains("duckduckgo.com/l/?uddg=") {
            if let uddgRange = url.range(of: "uddg=") {
                let afterUddg = url[uddgRange.upperBound...]
                if let ampRange = afterUddg.range(of: "&") {
                    let encoded = String(afterUddg[..<ampRange.lowerBound])
                    return encoded.removingPercentEncoding ?? url
                } else {
                    return String(afterUddg).removingPercentEncoding ?? url
                }
            }
        }

        // 补全协议
        if url.hasPrefix("//") {
            return "https:" + url
        }

        return url.replacingOccurrences(of: "&amp;", with: "&")
    }

    private static func stripHTML(_ value: String) -> String {
        var result = value
            .replacingOccurrences(of: #"<[^>]+>"#, with: " ", options: .regularExpression)

        // 更完整的 HTML 实体解码
        let entities: [String: String] = [
            "&nbsp;": " ", "&amp;": "&", "&quot;": "\"", "&apos;": "'",
            "&lt;": "<", "&gt;": ">", "&#39;": "'", "&ndash;": "–",
            "&mdash;": "—", "&hellip;": "…", "&rsquo;": "'", "&lsquo;": "'"
        ]

        for (entity, char) in entities {
            result = result.replacingOccurrences(of: entity, with: char)
        }

        return result
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// No-key fallback for networks where DuckDuckGo's HTML endpoint is blocked
/// or rate-limited. The result shape is normalized before it reaches the
/// Agent, just like every other search provider.
public struct BingSearchProvider: SearchProvider {
    public let id = "bing"
    public let runtime: NetworkRuntime
    public let capabilities = SearchProviderCapabilities()

    public init(runtime: NetworkRuntime = .shared) {
        self.runtime = runtime
    }

    public func search(request: WebSearchRequest, context: NetworkContext) async throws -> WebSearchResponse {
        var components = URLComponents(string: "https://www.bing.com/search")!
        components.queryItems = [URLQueryItem(name: "q", value: request.query)]
        var urlRequest = URLRequest(url: components.url!)
        urlRequest.httpMethod = "GET"
        urlRequest.timeoutInterval = 15
        urlRequest.setValue("DeepSeek Code/1.0", forHTTPHeaderField: "User-Agent")
        urlRequest.setValue("text/html", forHTTPHeaderField: "Accept")
        let (data, _) = try await runtime.data(for: urlRequest, scope: .webSearch, context: context, maxBytes: 512_000)
        let html = String(decoding: data, as: UTF8.self)
        let rawResults = Self.parseResults(html).prefix(request.maxResults).map {
            WebSearchResult(title: $0.title, url: $0.url, snippet: $0.snippet, providerID: id)
        }
        let retrievedAt = Date()
        return WebSearchResponse(providerID: id, results: WebSourceNormalizer.normalize(rawResults, providerID: id, retrievedAt: retrievedAt), retrievedAt: retrievedAt)
    }

    public func healthCheck(context: NetworkContext) async -> SearchProviderHealth {
        do {
            let response = try await search(request: WebSearchRequest(query: "DeepSeek", maxResults: 1), context: context)
            return SearchProviderHealth(providerID: id, reachable: !response.results.isEmpty, statusCode: 200, detail: response.results.isEmpty ? "未返回搜索结果" : "搜索响应正常")
        } catch {
            return SearchProviderHealth(providerID: id, reachable: false, detail: SecretRedactor.redact(error.localizedDescription))
        }
    }

    private struct ParsedResult {
        let title: String
        let url: String
        let snippet: String
    }

    private static func parseResults(_ html: String) -> [ParsedResult] {
        var results: [ParsedResult] = []

        // 尝试多个 pattern，因为 Bing 页面结构经常变化
        let patterns = [
            // Pattern 1: 标准的 b_algo 格式
            #"<li[^>]*class=\"[^\"]*\bb_algo\b[^\"]*\"[^>]*>.*?<h2[^>]*>\s*<a[^>]*href=\"([^\"]+)\"[^>]*>(.*?)</a>.*?<div[^>]*class=\"b_caption\"[^>]*>.*?<p[^>]*>(.*?)</p>"#,
            // Pattern 2: 新版格式（带 id）
            #"<li[^>]*id=\"[^\"]*b_algo[^\"]*\"[^>]*>.*?<h2[^>]*>.*?<a[^>]*href=\"([^\"]+)\"[^>]*>(.*?)</a>.*?<p[^>]*>(.*?)</p>"#,
            // Pattern 3: 更宽松的格式
            #"<h2[^>]*>.*?<a[^>]*href=\"(https?://[^\"]+)\"[^>]*>(.*?)</a>.*?</h2>.*?<p[^>]*>(.*?)</p>"#
        ]

        for (index, pattern) in patterns.enumerated() {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else {
                print("⚠️ [SEARCH] Bing regex pattern \(index + 1) failed to compile")
                continue
            }
            let range = NSRange(html.startIndex..<html.endIndex, in: html)
            let matches = regex.matches(in: html, range: range).compactMap { (match: NSTextCheckingResult) -> ParsedResult? in
                guard let url = capture(match, html: html, index: 1),
                      let title = capture(match, html: html, index: 2) else { return nil }
                let snippet = capture(match, html: html, index: 3) ?? ""
                return ParsedResult(
                    title: stripHTML(title),
                    url: url.replacingOccurrences(of: "&amp;", with: "&"),
                    snippet: stripHTML(snippet)
                )
            }

            if !matches.isEmpty {
                print("✅ [SEARCH] Bing pattern \(index + 1) matched \(matches.count) results")
                results.append(contentsOf: matches)
                break
            }
        }

        // 如果所有 pattern 都失败，记录调试信息
        if results.isEmpty {
            print("⚠️ [SEARCH] Bing HTML parsing failed - all patterns returned 0 results")
            print("→ [SEARCH] HTML length: \(html.count) characters")

            // 在调试模式下保存 HTML 用于分析
            #if DEBUG
            let timestamp = Int(Date().timeIntervalSince1970)
            if let tempDir = FileManager.default.temporaryDirectory as URL?,
               let htmlData = html.data(using: .utf8) {
                let debugFile = tempDir.appendingPathComponent("bing-debug-\(timestamp).html")
                try? htmlData.write(to: debugFile)
                print("→ [SEARCH] Debug HTML saved to: \(debugFile.path)")
            }
            #endif
        }

        return results
    }

    private static func capture(_ match: NSTextCheckingResult, html: String, index: Int) -> String? {
        guard index < match.numberOfRanges else { return nil }
        let range = match.range(at: index)
        guard range.location != NSNotFound, let swiftRange = Range(range, in: html) else { return nil }
        return String(html[swiftRange])
    }

    private static func stripHTML(_ value: String) -> String {
        value
            .replacingOccurrences(of: #"<[^>]+>"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public struct HTTPJSONSearchProvider: SearchProvider {
    public let configuration: SearchProviderConfiguration
    public let runtime: NetworkRuntime
    public let secretStore: (any SecretStore)?
    public let id: String
    public let capabilities: SearchProviderCapabilities

    public init(configuration: SearchProviderConfiguration, runtime: NetworkRuntime = .shared, secretStore: (any SecretStore)? = nil) throws {
        guard configuration.isValid, let url = URL(string: configuration.endpoint) else {
            throw ProviderRequestError.invalidEndpoint
        }
        _ = url
        self.configuration = configuration
        self.runtime = runtime
        self.secretStore = secretStore
        self.id = configuration.id
        self.capabilities = SearchProviderCapabilities(requiresCredential: configuration.authorizationReference != nil)
    }

    public func search(request: WebSearchRequest, context: NetworkContext) async throws -> WebSearchResponse {
        guard var components = URLComponents(string: configuration.endpoint) else {
            throw ProviderRequestError.invalidEndpoint
        }
        components.queryItems = (components.queryItems ?? []) + [URLQueryItem(name: configuration.queryParameter, value: request.query)]
        var urlRequest = URLRequest(url: components.url!)
        urlRequest.httpMethod = "GET"
        urlRequest.timeoutInterval = 30
        urlRequest.setValue("DeepSeek Code/1.0", forHTTPHeaderField: "User-Agent")
        if let reference = configuration.authorizationReference,
           let secretStore,
           let token = try? secretStore.load(reference: reference),
           !token.isEmpty {
            urlRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        let (data, _) = try await runtime.data(for: urlRequest, scope: .webSearch, context: context, maxBytes: 512_000)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NetworkRuntimeError.invalidResponse
        }
        let values = (object["results"] as? [[String: Any]]) ?? (object["items"] as? [[String: Any]]) ?? []
        let rawResults: [WebSearchResult] = values.prefix(request.maxResults).compactMap { value in
            guard let url = value["url"] as? String ?? value["link"] as? String else { return nil }
            return WebSearchResult(
                title: value["title"] as? String ?? "",
                url: url,
                snippet: value["snippet"] as? String ?? value["description"] as? String ?? "",
                providerID: id
            )
        }
        let retrievedAt = Date()
        return WebSearchResponse(providerID: id, results: WebSourceNormalizer.normalize(rawResults, providerID: id, retrievedAt: retrievedAt), retrievedAt: retrievedAt)
    }

    public func healthCheck(context: NetworkContext) async -> SearchProviderHealth {
        guard var components = URLComponents(string: configuration.endpoint), components.url != nil else {
            return SearchProviderHealth(providerID: id, reachable: false, detail: "Endpoint 无效")
        }
        components.queryItems = (components.queryItems ?? []) + [URLQueryItem(name: configuration.queryParameter, value: "health")]
        guard let healthURL = components.url else {
            return SearchProviderHealth(providerID: id, reachable: false, detail: "Endpoint 无效")
        }
        var request = URLRequest(url: healthURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.setValue("DeepSeek Code/1.0", forHTTPHeaderField: "User-Agent")
        if let reference = configuration.authorizationReference,
           let secretStore,
           let token = try? secretStore.load(reference: reference),
           !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        do {
            let (_, response) = try await runtime.data(for: request, scope: .webSearch, context: context, maxBytes: 8_192)
            return SearchProviderHealth(providerID: id, reachable: (200..<500).contains(response.statusCode), statusCode: response.statusCode, detail: "HTTP \(response.statusCode)")
        } catch {
            return SearchProviderHealth(providerID: id, reachable: false, detail: SecretRedactor.redact(error.localizedDescription))
        }
    }
}
