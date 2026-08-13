import Foundation

// MARK: - GitHub Code Search Provider

/// GitHub code search provider for code snippets, repositories, and issues
public struct GitHubSearchProvider: SearchProvider, Sendable {
    public let id = "github"
    public let capabilities = SearchProviderCapabilities(
        supportsLanguage: false,
        supportsRegion: false,
        supportsFreshness: false,
        requiresCredential: false
    )
    private let runtime: NetworkRuntime

    public init(runtime: NetworkRuntime = .shared) {
        self.runtime = runtime
    }

    public func healthCheck(context: NetworkContext) async -> SearchProviderHealth {
        SearchProviderHealth(providerID: id, reachable: true, detail: "GitHub search provider")
    }

    public func search(request: WebSearchRequest, context: NetworkContext) async throws -> WebSearchResponse {
        let query = request.query
        let encodedQuery = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query

        // 搜索代码、仓库和问题
        let searchURL = "https://github.com/search?q=\(encodedQuery)&type=code"

        var urlRequest = URLRequest(url: URL(string: searchURL)!)
        urlRequest.httpMethod = "GET"
        urlRequest.timeoutInterval = 15
        urlRequest.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36", forHTTPHeaderField: "User-Agent")

        let (data, _) = try await runtime.data(for: urlRequest, scope: .webSearch, context: context, maxBytes: 2 * 1024 * 1024)

        guard let html = String(data: data, encoding: .utf8) else {
            throw SearchProviderError.invalidResponse
        }

        let results = parseGitHubResults(html: html, query: query)

        let normalized = WebSourceNormalizer.normalize(
            results,
            providerID: id,
            preferredDomains: ["github.com"],
            retrievedAt: Date()
        )

        return WebSearchResponse(
            providerID: id,
            results: normalized,
            retrievedAt: Date()
        )
    }

    private func parseGitHubResults(html: String, query: String) -> [WebSearchResult] {
        var results: [WebSearchResult] = []

        // GitHub 搜索结果模式
        let patterns = [
            #"<a[^>]*href=\"(/[^\"]+)\"[^>]*class=\"[^\"]*search-title[^\"]*\"[^>]*>([^<]+)</a>"#,
            #"<div[^>]*class=\"[^\"]*f4[^\"]*\"[^>]*>.*?<a[^>]*href=\"(/[^\"]+)\"[^>]*>([^<]+)</a>"#
        ]

        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else {
                continue
            }

            let matches = regex.matches(in: html, range: NSRange(html.startIndex..., in: html))

            for match in matches.prefix(20) {
                guard match.numberOfRanges >= 3,
                      let pathRange = Range(match.range(at: 1), in: html),
                      let titleRange = Range(match.range(at: 2), in: html) else {
                    continue
                }

                let path = String(html[pathRange])
                let title = String(html[titleRange])
                    .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines)

                let url = "https://github.com\(path)"

                results.append(WebSearchResult(
                    title: decodeHTML(title),
                    url: url,
                    snippet: "GitHub code search result for: \(query)",
                    providerID: id
                ))
            }

            if !results.isEmpty {
                break
            }
        }

        return results
    }

    private func decodeHTML(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&#39;", with: "'")
    }
}

// MARK: - Stack Overflow Search Provider

/// Stack Overflow search provider for programming Q&A
public struct StackOverflowSearchProvider: SearchProvider, Sendable {
    public let id = "stackoverflow"
    public let capabilities = SearchProviderCapabilities(
        supportsLanguage: false,
        supportsRegion: false,
        supportsFreshness: false,
        requiresCredential: false
    )
    private let runtime: NetworkRuntime

    public init(runtime: NetworkRuntime = .shared) {
        self.runtime = runtime
    }

    public func healthCheck(context: NetworkContext) async -> SearchProviderHealth {
        SearchProviderHealth(providerID: id, reachable: true, detail: "Stack Overflow search provider")
    }

    public func search(request: WebSearchRequest, context: NetworkContext) async throws -> WebSearchResponse {
        let query = request.query
        let encodedQuery = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query

        let searchURL = "https://stackoverflow.com/search?q=\(encodedQuery)"

        var urlRequest = URLRequest(url: URL(string: searchURL)!)
        urlRequest.httpMethod = "GET"
        urlRequest.timeoutInterval = 15
        urlRequest.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36", forHTTPHeaderField: "User-Agent")

        let (data, _) = try await runtime.data(for: urlRequest, scope: .webSearch, context: context, maxBytes: 2 * 1024 * 1024)

        guard let html = String(data: data, encoding: .utf8) else {
            throw SearchProviderError.invalidResponse
        }

        let results = parseStackOverflowResults(html: html)

        let normalized = WebSourceNormalizer.normalize(
            results,
            providerID: id,
            preferredDomains: ["stackoverflow.com"],
            retrievedAt: Date()
        )

        return WebSearchResponse(
            providerID: id,
            results: normalized,
            retrievedAt: Date()
        )
    }

    private func parseStackOverflowResults(html: String) -> [WebSearchResult] {
        var results: [WebSearchResult] = []

        // Stack Overflow 问题结果
        let pattern = #"<div[^>]*class=\"[^\"]*search-result[^\"]*\"[^>]*>.*?<a[^>]*href=\"(/questions/[^\"]+)\"[^>]*class=\"[^\"]*result-link[^\"]*\"[^>]*>([^<]+)</a>.*?<div[^>]*class=\"[^\"]*excerpt[^\"]*\"[^>]*>([^<]+)</div>"#

        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else {
            return results
        }

        let matches = regex.matches(in: html, range: NSRange(html.startIndex..., in: html))

        for match in matches.prefix(15) {
            guard match.numberOfRanges >= 4,
                  let pathRange = Range(match.range(at: 1), in: html),
                  let titleRange = Range(match.range(at: 2), in: html),
                  let snippetRange = Range(match.range(at: 3), in: html) else {
                continue
            }

            let path = String(html[pathRange])
            let title = String(html[titleRange])
                .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let snippet = String(html[snippetRange])
                .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)

            let url = "https://stackoverflow.com\(path)"

            results.append(WebSearchResult(
                title: decodeHTML(title),
                url: url,
                snippet: decodeHTML(snippet),
                providerID: id
            ))
        }

        return results
    }

    private func decodeHTML(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&#39;", with: "'")
    }
}

// MARK: - Reddit Search Provider

/// Reddit search provider for community discussions
public struct RedditSearchProvider: SearchProvider, Sendable {
    public let id = "reddit"
    public let capabilities = SearchProviderCapabilities(
        supportsLanguage: false,
        supportsRegion: false,
        supportsFreshness: false,
        requiresCredential: false
    )
    private let runtime: NetworkRuntime

    public init(runtime: NetworkRuntime = .shared) {
        self.runtime = runtime
    }

    public func healthCheck(context: NetworkContext) async -> SearchProviderHealth {
        SearchProviderHealth(providerID: id, reachable: true, detail: "Reddit search provider")
    }

    public func search(request: WebSearchRequest, context: NetworkContext) async throws -> WebSearchResponse {
        let query = request.query
        let encodedQuery = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query

        let searchURL = "https://www.reddit.com/search/?q=\(encodedQuery)"

        var urlRequest = URLRequest(url: URL(string: searchURL)!)
        urlRequest.httpMethod = "GET"
        urlRequest.timeoutInterval = 15
        urlRequest.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36", forHTTPHeaderField: "User-Agent")

        let (data, _) = try await runtime.data(for: urlRequest, scope: .webSearch, context: context, maxBytes: 2 * 1024 * 1024)

        guard let html = String(data: data, encoding: .utf8) else {
            throw SearchProviderError.invalidResponse
        }

        let results = parseRedditResults(html: html)

        let normalized = WebSourceNormalizer.normalize(
            results,
            providerID: id,
            preferredDomains: ["reddit.com"],
            retrievedAt: Date()
        )

        return WebSearchResponse(
            providerID: id,
            results: normalized,
            retrievedAt: Date()
        )
    }

    private func parseRedditResults(html: String) -> [WebSearchResult] {
        var results: [WebSearchResult] = []

        // Reddit 帖子结果
        let pattern = #"<a[^>]*href=\"(/r/[^\"]+/comments/[^\"]+)\"[^>]*>.*?<h3[^>]*>([^<]+)</h3>"#

        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else {
            return results
        }

        let matches = regex.matches(in: html, range: NSRange(html.startIndex..., in: html))

        for match in matches.prefix(10) {
            guard match.numberOfRanges >= 3,
                  let pathRange = Range(match.range(at: 1), in: html),
                  let titleRange = Range(match.range(at: 2), in: html) else {
                continue
            }

            let path = String(html[pathRange])
            let title = String(html[titleRange])
                .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)

            let url = "https://www.reddit.com\(path)"

            results.append(WebSearchResult(
                title: decodeHTML(title),
                url: url,
                snippet: "Reddit discussion",
                providerID: id
            ))
        }

        return results
    }

    private func decodeHTML(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&#39;", with: "'")
    }
}

// MARK: - Error Types

public enum SearchProviderError: Error, LocalizedError {
    case invalidResponse
    case networkError(Error)

    public var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "Invalid search response"
        case .networkError(let error):
            return "Network error: \(error.localizedDescription)"
        }
    }
}
