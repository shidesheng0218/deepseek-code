# 搜索功能修复方案

## 问题诊断

你的应用**工具调用成功了**，但返回空结果，原因是：

1. `BingSearchProvider` 使用正则表达式解析 Bing HTML
2. Bing 的页面结构经常变化，正则表达式失效
3. 解析失败返回空数组 `[]`
4. DeepSeek 模型看到空结果，回复"无法获取"

## Claude Code 为什么能成功？

Claude Code 使用的是：
- **Brave Search API**（官方 API，JSON 格式）
- 或 **自己的搜索服务**

它们返回结构化的 JSON 数据，不需要解析 HTML。

## 解决方案

### 方案 1：使用 Brave Search API（推荐）

Brave Search 提供免费的 API，每月 2000 次查询。

#### 步骤 1：注册 API Key

访问：https://brave.com/search/api/

#### 步骤 2：添加 BraveSearchProvider

创建新文件或在 `SearchProviders.swift` 中添加：

```swift
public struct BraveSearchProvider: SearchProvider {
    public let id = "brave"
    public let runtime: NetworkRuntime
    public let apiKey: String
    public let capabilities = SearchProviderCapabilities(
        supportsLanguage: true,
        supportsRegion: true,
        supportsFreshness: true
    )

    public init(runtime: NetworkRuntime = .shared, apiKey: String) {
        self.runtime = runtime
        self.apiKey = apiKey
    }

    public func search(request: WebSearchRequest, context: NetworkContext) async throws -> WebSearchResponse {
        var components = URLComponents(string: "https://api.search.brave.com/res/v1/web/search")!
        var queryItems = [URLQueryItem(name: "q", value: request.query)]
        queryItems.append(URLQueryItem(name: "count", value: "\(request.maxResults)"))
        
        if let region = request.region {
            queryItems.append(URLQueryItem(name: "country", value: region))
        }
        if let language = request.language {
            queryItems.append(URLQueryItem(name: "search_lang", value: language))
        }
        if let freshness = request.freshness {
            let freshnessValue = switch freshness {
            case .day: "pd"
            case .week: "pw"
            case .month: "pm"
            }
            queryItems.append(URLQueryItem(name: "freshness", value: freshnessValue))
        }
        
        components.queryItems = queryItems
        
        var urlRequest = URLRequest(url: components.url!)
        urlRequest.httpMethod = "GET"
        urlRequest.timeoutInterval = 15
        urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "X-Subscription-Token")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")
        
        let (data, _) = try await runtime.data(for: urlRequest, scope: .webSearch, context: context, maxBytes: 512_000)
        
        struct BraveResponse: Codable {
            struct WebResult: Codable {
                let title: String
                let url: String
                let description: String?
            }
            struct Web: Codable {
                let results: [WebResult]
            }
            let web: Web?
        }
        
        let response = try JSONDecoder().decode(BraveResponse.self, from: data)
        let rawResults = (response.web?.results ?? []).map {
            WebSearchResult(
                title: $0.title,
                url: $0.url,
                snippet: $0.description ?? "",
                providerID: id
            )
        }
        
        let retrievedAt = Date()
        return WebSearchResponse(
            providerID: id,
            results: WebSourceNormalizer.normalize(rawResults, providerID: id, retrievedAt: retrievedAt),
            retrievedAt: retrievedAt
        )
    }

    public func healthCheck(context: NetworkContext) async -> SearchProviderHealth {
        do {
            let response = try await search(request: WebSearchRequest(query: "test", maxResults: 1), context: context)
            return SearchProviderHealth(
                providerID: id,
                reachable: !response.results.isEmpty,
                statusCode: 200,
                detail: response.results.isEmpty ? "未返回搜索结果" : "搜索响应正常"
            )
        } catch {
            return SearchProviderHealth(providerID: id, reachable: false, detail: SecretRedactor.redact(error.localizedDescription))
        }
    }
}
```

#### 步骤 3：在 WorkspaceStore 中使用

修改 `WorkspaceStore.swift:3270-3275`：

```swift
let configuredProviders: [any SearchProvider] = searchProviders
    .filter { $0.enabled }
    .compactMap { configuration in
        // 如果有配置的 API provider，优先使用
        if configuration.id == "brave", let apiKey = configuration.authorizationReference {
            let apiKeyValue = try? secretStore?.load(reference: apiKey)
            if let apiKeyValue {
                return BraveSearchProvider(runtime: networkRuntime, apiKey: apiKeyValue) as any SearchProvider
            }
        }
        return try? HTTPJSONSearchProvider(configuration: configuration, runtime: networkRuntime, secretStore: secretStore)
    }

// 如果用户没有配置任何 provider，使用修复后的 Bing
let fallbackProviders: [any SearchProvider] = configuredProviders.isEmpty ? [
    ImprovedBingSearchProvider(runtime: networkRuntime)
] : []

router.register(
    host: WebToolHost(
        runtime: networkRuntime,
        searchProviders: configuredProviders + fallbackProviders,
        projectID: selectedProjectID
    ),
    forPrefix: "web."
)
```

### 方案 2：修复 Bing 正则表达式（临时方案）

如果不想用 API，可以更新正则表达式：

```swift
// 在 SearchProviders.swift 中更新 BingSearchProvider

private static func parseResults(_ html: String) -> [ParsedResult] {
    var results: [ParsedResult] = []
    
    // 尝试多个 pattern，Bing 页面结构有多种
    let patterns = [
        // 新版 pattern
        #"<li[^>]*class=\"[^\"]*\bb_algo\b[^\"]*\"[^>]*>.*?<h2[^>]*>\s*<a[^>]*href=\"([^\"]+)\"[^>]*>(.*?)</a>.*?<div[^>]*class=\"b_caption\"[^>]*>.*?<p[^>]*>(.*?)</p>"#,
        // 备用 pattern 1
        #"<li[^>]*id=\"[^\"]*b_algo[^\"]*\"[^>]*>.*?<h2[^>]*>.*?<a[^>]*href=\"([^\"]+)\"[^>]*>(.*?)</a>.*?<div[^>]*>(.*?)</div>"#,
        // 备用 pattern 2 - 更宽松
        #"<a[^>]*href=\"(https?://[^\"]+)\"[^>]*><h2[^>]*>(.*?)</h2></a>.*?<p[^>]*>(.*?)</p>"#
    ]
    
    for pattern in patterns {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else { continue }
        let range = NSRange(html.startIndex..<html.endIndex, in: html)
        let matches = regex.matches(in: html, range: range).compactMap { match in
            guard let url = capture(match, html: html, index: 1),
                  let title = capture(match, html: html, index: 2) else { return nil }
            return ParsedResult(
                title: stripHTML(title),
                url: url.replacingOccurrences(of: "&amp;", with: "&"),
                snippet: stripHTML(capture(match, html: html, index: 3) ?? "")
            )
        }
        
        if !matches.isEmpty {
            results.append(contentsOf: matches)
            break
        }
    }
    
    // 如果所有 pattern 都失败，添加调试日志
    if results.isEmpty {
        print("⚠️ [SEARCH] Bing HTML parsing failed, no results found")
        // 保存 HTML 到文件用于调试
        #if DEBUG
        if let docPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            let debugFile = docPath.appendingPathComponent("bing-debug-\(Date().timeIntervalSince1970).html")
            try? html.write(to: debugFile, atomically: true, encoding: .utf8)
            print("→ [SEARCH] Debug HTML saved to: \(debugFile.path)")
        }
        #endif
    }
    
    return results
}
```

### 方案 3：使用 DuckDuckGo（已内置但可能也有问题）

检查 DuckDuckGo 的实现是否有效。

### 方案 4：使用 SerpAPI（付费但稳定）

SerpAPI 提供稳定的 Google/Bing 搜索 API。

## 推荐实施顺序

1. **立即**：添加调试日志，确认是否真的返回空结果
2. **短期**：实施方案 2（修复 Bing 正则）
3. **长期**：实施方案 1（使用 Brave Search API）

## 调试步骤

### 1. 确认问题

添加日志到 `NetworkRuntime.swift:1485`：

```swift
let response = try await provider.search(request: request, context: context)
print("✅ [SEARCH] Provider \(response.providerID) returned \(response.results.count) results")
if response.results.isEmpty {
    print("⚠️ [SEARCH] Empty results for query: \(request.query)")
}
```

### 2. 查看搜索结果

```bash
swift run DeepSeekCode 2>&1 | grep "\[SEARCH\]"
```

### 3. 如果看到 "0 results"

说明解析失败，实施方案 2 或方案 1。

## Claude Code 的搜索工具描述

参考 Claude Code 的工具描述，让模型更好地使用结果：

```swift
ToolSchema(name: "web.search", description: "搜索公开网页并返回标题、链接和摘要。返回 JSON 包含 results 数组，每项有 title、url、snippet 字段。即使找不到完美匹配，也会返回相关结果。", parameters: ...)
```

当前描述："搜索公开网页并返回标题、链接和摘要"

建议改为："在互联网上搜索信息。返回结构化的搜索结果，包含标题、URL 和内容摘要。结果为 JSON 格式的 results 数组。"

这样模型会知道如何解析和使用结果。
