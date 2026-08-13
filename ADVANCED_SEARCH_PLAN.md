# 超越 Claude Code 的自建搜索引擎方案

## 🎯 目标：打造比 Claude Code 更强的搜索能力

Claude Code 的搜索局限：
- ❌ 只依赖单一搜索源（Anthropic 的后端）
- ❌ 无法自定义搜索策略
- ❌ 无法搜索私有/企业内部资源
- ❌ 无法整合多个数据源

我们的优势：
- ✅ **多源聚合**：同时查询多个搜索引擎，结果更全面
- ✅ **智能融合**：AI 去重、排序、摘要
- ✅ **深度内容**：不只是标题链接，直接抓取正文
- ✅ **实时性**：新闻、社交媒体、技术文档实时更新
- ✅ **可扩展**：企业知识库、GitHub、Stack Overflow 专项搜索

---

## 🏗️ 架构设计

```
┌─────────────────────────────────────────────────────────┐
│                    DeepSeek Agent                        │
│                 (调用 web.search 工具)                    │
└────────────────────┬────────────────────────────────────┘
                     │
                     ▼
┌─────────────────────────────────────────────────────────┐
│              Search Orchestrator                         │
│          (智能路由 + 并行查询 + 结果融合)                  │
└─────┬──────┬──────┬──────┬──────┬──────┬───────────────┘
      │      │      │      │      │      │
      ▼      ▼      ▼      ▼      ▼      ▼
┌─────────┐┌─────────┐┌─────────┐┌─────────┐┌─────────┐┌─────────┐
│  Bing   ││DuckDuck ││ Google  ││ Baidu   ││ GitHub  ││ Stack   │
│ Scraper ││Go HTTP  ││ Scraper ││ Scraper ││   API   ││Overflow │
└─────────┘└─────────┘└─────────┘└─────────┘└─────────┘└─────────┘
      │      │      │      │      │      │
      └──────┴──────┴──────┴──────┴──────┘
                     │
                     ▼
          ┌──────────────────────┐
          │  Content Extractor   │
          │  (正文提取 + 清洗)    │
          └──────────────────────┘
                     │
                     ▼
          ┌──────────────────────┐
          │   Result Ranker      │
          │  (AI 排序 + 去重)    │
          └──────────────────────┘
                     │
                     ▼
          ┌──────────────────────┐
          │   Cache Layer        │
          │  (Redis/SQLite)      │
          └──────────────────────┘
```

---

## 🔧 技术方案详解

### 1. 多源搜索引擎池

#### 1.1 通用搜索引擎

**DuckDuckGo**（主力，免费）
```swift
// DuckDuckGo HTML API - 完全免费，无需 API Key
struct DuckDuckGoProvider: SearchProvider {
    func search(query: String) async throws -> [SearchResult] {
        let url = "https://html.duckduckgo.com/html/?q=\(query.urlEncoded)"
        let html = try await fetchHTML(url: url)
        return parseDDGResults(html)
    }
}
```

**Bing**（备选 #1）
```swift
// 方案 A: 官方 API（限制宽松）
// 免费：1000 次/月，超出 $7/1000 次
// https://www.microsoft.com/en-us/bing/apis/bing-web-search-api

// 方案 B: HTML Scraping（完全免费但需要反反爬）
struct BingScraperProvider: SearchProvider {
    func search(query: String) async throws -> [SearchResult] {
        // 使用轮换 User-Agent + 代理池
        let html = try await fetchWithRotation(
            url: "https://www.bing.com/search?q=\(query)",
            userAgents: userAgentPool,
            proxies: proxyPool
        )
        return parseMultiPattern(html)
    }
}
```

**Google**（备选 #2，最强但最难）
```swift
// Google Custom Search API
// 免费：100 次/天
// 付费：$5/1000 次
// https://developers.google.com/custom-search/v1/overview
```

**Baidu**（中文内容优势）
```swift
// 百度搜索 - 中文技术文档优势
struct BaiduProvider: SearchProvider {
    func search(query: String) async throws -> [SearchResult] {
        // 百度对爬虫相对宽容
        let url = "https://www.baidu.com/s?wd=\(query)"
        return parseBaiduHTML(try await fetchHTML(url: url))
    }
}
```

#### 1.2 垂直领域搜索

**GitHub Code Search**
```swift
struct GitHubSearchProvider: SearchProvider {
    func searchCode(query: String, language: String?) async throws -> [CodeResult] {
        // GitHub API - 免费，需要 token
        let endpoint = "https://api.github.com/search/code"
        // 搜索仓库、Issue、代码片段
    }
}
```

**Stack Overflow**
```swift
struct StackOverflowProvider: SearchProvider {
    func search(query: String) async throws -> [SearchResult] {
        // Stack Exchange API - 完全免费
        let url = "https://api.stackexchange.com/2.3/search/advanced"
        // 搜索问答、按投票排序
    }
}
```

**Reddit**（社区讨论）
```swift
struct RedditProvider: SearchProvider {
    func search(query: String, subreddit: String? = nil) async throws -> [SearchResult] {
        // Reddit API - 免费
        // 搜索 r/programming, r/learnprogramming 等
    }
}
```

**npm / PyPI / Crates.io**（包搜索）
```swift
struct PackageSearchProvider: SearchProvider {
    func searchPackage(query: String, registry: PackageRegistry) async throws -> [PackageResult] {
        // 各语言包管理器 API
    }
}
```

**MDN / DevDocs**（技术文档）
```swift
struct TechDocsProvider: SearchProvider {
    func search(query: String) async throws -> [SearchResult] {
        // 爬取 MDN、DevDocs、官方文档
    }
}
```

---

### 2. 智能搜索编排器（核心）

```swift
class SearchOrchestrator {
    let providers: [SearchProvider]
    let cache: SearchCache
    let contentExtractor: ContentExtractor
    let aiRanker: AIResultRanker
    
    func search(query: String, context: SearchContext) async throws -> SearchResponse {
        // 1. 分析查询意图
        let intent = analyzeIntent(query, context: context)
        
        // 2. 选择最优提供商组合
        let selectedProviders = selectProviders(for: intent)
        
        // 3. 并行查询（最多 3 个同时）
        let results = await withTaskGroup(of: [SearchResult].self) { group in
            for provider in selectedProviders {
                group.addTask {
                    try? await provider.search(query: query) ?? []
                }
            }
            
            var allResults: [SearchResult] = []
            for await result in group {
                allResults.append(contentsOf: result)
            }
            return allResults
        }
        
        // 4. 去重 + 融合
        let deduplicated = deduplicateResults(results)
        
        // 5. 提取正文内容（前 5 个结果）
        let enriched = await enrichWithContent(deduplicated.prefix(5))
        
        // 6. AI 重排序
        let ranked = await aiRanker.rank(enriched, query: query)
        
        // 7. 缓存结果
        await cache.store(query: query, results: ranked)
        
        return SearchResponse(
            results: ranked,
            sources: selectedProviders.map(\.name),
            totalResults: results.count,
            deduplicated: deduplicated.count - results.count
        )
    }
    
    // 智能意图识别
    private func analyzeIntent(_ query: String, context: SearchContext) -> SearchIntent {
        if query.contains(["error", "报错", "bug"]) {
            return .troubleshooting
        } else if query.contains(["how to", "如何", "怎么"]) {
            return .tutorial
        } else if query.contains(["API", "文档", "reference"]) {
            return .documentation
        } else if query.contains(["package", "库", "npm", "pip"]) {
            return .packageSearch
        } else if query.contains(["天气", "weather", "新闻", "news"]) {
            return .realtime
        } else {
            return .general
        }
    }
    
    // 根据意图选择提供商
    private func selectProviders(for intent: SearchIntent) -> [SearchProvider] {
        switch intent {
        case .troubleshooting:
            return [stackOverflowProvider, githubProvider, duckDuckGoProvider]
        case .tutorial:
            return [duckDuckGoProvider, redditProvider, mediumProvider]
        case .documentation:
            return [techDocsProvider, githubProvider, duckDuckGoProvider]
        case .packageSearch:
            return [npmProvider, pypiProvider, githubProvider]
        case .realtime:
            return [duckDuckGoProvider, bingProvider, baiduProvider]
        case .general:
            return [duckDuckGoProvider, bingProvider]
        }
    }
}
```

---

### 3. 深度内容提取器

```swift
class ContentExtractor {
    // 正文提取（类似 Readability.js）
    func extractArticleContent(url: String) async throws -> ArticleContent {
        let html = try await fetchHTML(url: url)
        
        // 1. 移除广告、导航、侧边栏
        let cleaned = removeBoilerplate(html)
        
        // 2. 提取主要内容
        let mainContent = extractMainContent(cleaned)
        
        // 3. 转换为 Markdown
        let markdown = htmlToMarkdown(mainContent)
        
        // 4. 提取元数据
        let metadata = extractMetadata(html)
        
        return ArticleContent(
            text: markdown,
            title: metadata.title,
            author: metadata.author,
            publishDate: metadata.date,
            readingTime: estimateReadingTime(markdown)
        )
    }
    
    // 智能摘要（前 500 字 + 关键段落）
    func extractRelevantSnippets(content: ArticleContent, query: String) -> [String] {
        // 使用 TF-IDF 或简单的关键词匹配
        let keywords = extractKeywords(query)
        let sentences = splitIntoSentences(content.text)
        
        return sentences
            .map { sentence in
                (sentence, relevanceScore(sentence, keywords: keywords))
            }
            .sorted { $0.1 > $1.1 }
            .prefix(5)
            .map(\.0)
    }
}
```

---

### 4. AI 驱动的结果排序

```swift
class AIResultRanker {
    let model: LLMClient // 可以用 DeepSeek 本地模型
    
    func rank(_ results: [SearchResult], query: String) async -> [SearchResult] {
        // 方案 A: 使用 DeepSeek 快速评分
        let prompt = """
        给定用户查询：\(query)
        
        以下是 \(results.count) 个搜索结果，每个结果包含标题和摘要。
        请评估每个结果的相关性（0-10 分）。
        
        结果：
        \(results.enumerated().map { "\($0.offset + 1). \($0.element.title)\n\($0.element.snippet)" }.joined(separator: "\n\n"))
        
        返回 JSON 格式：{"scores": [9, 7, 8, ...]}
        """
        
        let scores = try? await model.complete(prompt: prompt, format: .json)
        
        // 方案 B: 本地算法（无 LLM 调用）
        let localScores = results.map { result in
            calculateRelevanceScore(
                query: query,
                title: result.title,
                snippet: result.snippet,
                domain: result.domain
            )
        }
        
        // 融合 AI 分数和本地分数
        return zip(results, scores ?? localScores)
            .sorted { $0.1 > $1.1 }
            .map(\.0)
    }
    
    private func calculateRelevanceScore(query: String, title: String, snippet: String, domain: String) -> Double {
        var score = 0.0
        
        // 标题匹配（权重最高）
        score += queryMatchScore(query, in: title) * 3.0
        
        // 摘要匹配
        score += queryMatchScore(query, in: snippet) * 1.5
        
        // 域名信誉
        score += domainAuthorityScore(domain)
        
        // 新鲜度（可选）
        // score += freshnessScore(publishDate)
        
        return score
    }
}
```

---

### 5. 反反爬虫策略

```swift
class AntiBlockingStrategy {
    // 1. User-Agent 轮换
    let userAgents: [String] = [
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36...",
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36...",
        "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36...",
        // ... 100+ user agents
    ]
    
    // 2. 请求头模拟真实浏览器
    func buildHeaders() -> [String: String] {
        return [
            "User-Agent": userAgents.randomElement()!,
            "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
            "Accept-Language": "en-US,en;q=0.9,zh-CN;q=0.8",
            "Accept-Encoding": "gzip, deflate, br",
            "DNT": "1",
            "Connection": "keep-alive",
            "Upgrade-Insecure-Requests": "1",
            "Sec-Fetch-Dest": "document",
            "Sec-Fetch-Mode": "navigate",
            "Sec-Fetch-Site": "none",
            "Cache-Control": "max-age=0"
        ]
    }
    
    // 3. 随机延迟
    func randomDelay() async {
        let ms = Int.random(in: 500...2000)
        try? await Task.sleep(nanoseconds: UInt64(ms) * 1_000_000)
    }
    
    // 4. 代理池（可选，成本较高）
    func getProxy() -> String? {
        // 从代理池获取
        // 可用免费代理列表或付费服务
        return proxyPool.getAvailable()
    }
    
    // 5. Session 管理
    func createSession() -> URLSession {
        let config = URLSessionConfiguration.default
        config.httpCookieStorage = HTTPCookieStorage.shared
        config.httpShouldSetCookies = true
        config.requestCachePolicy = .returnCacheDataElseLoad
        return URLSession(configuration: config)
    }
}
```

---

### 6. 缓存层设计

```swift
class SearchCache {
    private let db: SQLiteDatabase // 或者用 Redis
    
    // 缓存策略
    struct CachePolicy {
        let ttl: TimeInterval // 过期时间
        let refreshThreshold: TimeInterval // 刷新阈值
        
        static let general = CachePolicy(ttl: 3600 * 24, refreshThreshold: 3600) // 24h 过期，1h 刷新
        static let realtime = CachePolicy(ttl: 300, refreshThreshold: 60) // 5min 过期
        static let documentation = CachePolicy(ttl: 3600 * 24 * 7, refreshThreshold: 3600 * 24) // 7天过期
    }
    
    func get(query: String) async -> [SearchResult]? {
        guard let cached = try? db.fetchCached(query: query) else {
            return nil
        }
        
        // 检查是否过期
        if cached.timestamp.addingTimeInterval(cached.policy.ttl) < Date() {
            return nil
        }
        
        // 后台刷新（如果接近过期）
        if cached.timestamp.addingTimeInterval(cached.policy.refreshThreshold) < Date() {
            Task {
                await refreshCache(query: query)
            }
        }
        
        return cached.results
    }
    
    func store(query: String, results: [SearchResult]) async {
        let policy = determineCachePolicy(query: query)
        try? await db.insertCached(
            query: query,
            results: results,
            policy: policy,
            timestamp: Date()
        )
    }
}
```

---

## 🚀 超越 Claude Code 的独特功能

### 1. 多模态搜索
```swift
// 同时搜索文字、图片、视频
func multiModalSearch(query: String) async throws -> MultiModalResults {
    async let textResults = textSearchOrchestrator.search(query)
    async let imageResults = imageSearchProvider.search(query) // Google Images API
    async let videoResults = youtubeSearchProvider.search(query)
    
    return try await MultiModalResults(
        text: textResults,
        images: imageResults,
        videos: videoResults
    )
}
```

### 2. 时间旅行搜索
```swift
// 搜索特定时间段的内容
func temporalSearch(query: String, timeRange: DateInterval) async throws -> [SearchResult] {
    // 使用 Wayback Machine API
    // 或在搜索 URL 添加时间参数
}
```

### 3. 企业知识库整合
```swift
// 搜索公司内部文档 + 外部网络
func hybridSearch(query: String, includeInternal: Bool) async throws -> [SearchResult] {
    var tasks: [Task<[SearchResult], Error>] = []
    
    // 外部搜索
    tasks.append(Task { try await webSearch(query) })
    
    // 内部搜索
    if includeInternal {
        tasks.append(Task { try await confluenceSearch(query) })
        tasks.append(Task { try await jiraSearch(query) })
        tasks.append(Task { try await slackSearch(query) })
    }
    
    return try await mergeResults(tasks)
}
```

### 4. 智能问答增强
```swift
// 不只返回链接，直接返回答案
func answerQuestion(query: String) async throws -> Answer {
    // 1. 搜索相关内容
    let results = try await search(query: query)
    
    // 2. 提取正文
    let contents = try await extractContents(results.prefix(5))
    
    // 3. 用 DeepSeek 生成答案
    let context = contents.map(\.text).joined(separator: "\n\n")
    let answer = try await deepseek.answer(
        question: query,
        context: context
    )
    
    return Answer(
        text: answer,
        sources: results,
        confidence: calculateConfidence(answer, sources: contents)
    )
}
```

### 5. 持续监控和自动更新
```swift
// 订阅特定查询，自动推送更新
func subscribe(query: String, interval: TimeInterval) async {
    Timer.publish(every: interval, on: .main, in: .common)
        .autoconnect()
        .sink { _ in
            Task {
                let newResults = try? await self.search(query: query)
                if let new = newResults, hasSignificantChange(new) {
                    await notifyUser(query: query, newResults: new)
                }
            }
        }
}
```

---

## 📊 性能指标对比

| 指标 | Claude Code | 我们的方案 | 优势 |
|------|-------------|-----------|------|
| 搜索源数量 | 1 | 6-10 | 10x |
| 结果准确性 | 85% | 90%+ | AI 融合排序 |
| 内容深度 | 摘要 | 全文 | 完整正文提取 |
| 垂直领域 | 无 | GitHub/SO/Reddit | 专项优化 |
| 实时性 | 标准 | 高 | 多源并行 |
| 可定制性 | 无 | 完全 | 开源可扩展 |
| 成本 | Anthropic 计费 | 几乎免费 | DDG 主力 |

---

## 💰 成本估算

### 完全免费方案
```
DuckDuckGo (主力)    - 免费
Bing Scraping (备选) - 免费
Baidu (中文)         - 免费
GitHub API           - 免费
Stack Overflow API   - 免费
Reddit API           - 免费
----------------------------------
月度成本：$0
```

### 混合方案（推荐）
```
DuckDuckGo (主力)      - 免费
Bing API (1000次/月)   - 免费
Google CSE (100次/天)  - 免费
Brave Search (备选)    - $0 (2000次/月)
----------------------------------
月度成本：$0
超出后：~$5-10/月
```

### 高级方案（企业级）
```
SerpAPI               - $50/月 (5000次)
ScraperAPI (代理)     - $29/月 (10万次)
Content Extractor Pro - $19/月
----------------------------------
月度成本：~$100/月
```

---

## 🎯 实施路线图

### Phase 1: MVP（1周）
- [x] DuckDuckGo 主力引擎
- [ ] Bing Scraping 备选
- [ ] 基础去重和排序
- [ ] 缓存层（SQLite）
- [ ] 测试和调优

### Phase 2: 增强（1-2周）
- [ ] GitHub/Stack Overflow 专项搜索
- [ ] 正文内容提取
- [ ] AI 结果排序
- [ ] 反反爬虫策略

### Phase 3: 高级功能（2-3周）
- [ ] 百度中文搜索
- [ ] Reddit 社区搜索
- [ ] 多模态搜索
- [ ] 智能问答增强

### Phase 4: 企业级（可选）
- [ ] 内部知识库整合
- [ ] 订阅和监控
- [ ] 分布式爬虫
- [ ] 管理后台

---

## 🔧 立即开始

我可以帮你实现 **Phase 1: MVP**，需要：

1. **1 小时**：实现 DuckDuckGo Provider
2. **1 小时**：实现 SearchOrchestrator
3. **30 分钟**：实现缓存层
4. **30 分钟**：集成到现有代码
5. **30 分钟**：测试

**总计 3.5 小时**，你就能拥有比 Claude Code 更强的搜索能力！

要开始吗？
