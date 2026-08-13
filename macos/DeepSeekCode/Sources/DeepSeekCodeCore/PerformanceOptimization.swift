import Foundation

/// 智能缓存管理器
public actor SmartCacheManager {
    private var fileCache: [String: CachedFile] = [:]
    private var apiResponseCache: [String: CachedResponse] = [:]
    private var searchResultCache: [String: CachedSearchResultData] = [:]

    private let fileCacheExpiry: TimeInterval = 300 // 5分钟
    private let apiCacheExpiry: TimeInterval = 600 // 10分钟
    private let searchCacheExpiry: TimeInterval = 1800 // 30分钟

    public init() {}

    // MARK: - 文件缓存

    public func getCachedFile(_ path: String) async -> String? {
        // 清理过期缓存
        await cleanupExpiredFileCache()

        guard let cached = fileCache[path],
              cached.expiresAt > Date() else {
            return nil
        }

        // 检查文件是否被修改
        if let fileModTime = getFileModificationTime(path),
           fileModTime > cached.modifiedAt {
            fileCache.removeValue(forKey: path)
            return nil
        }

        // 更新访问时间
        fileCache[path]?.lastAccessedAt = Date()
        return cached.content
    }

    public func cacheFile(_ path: String, content: String) async {
        let modTime = getFileModificationTime(path) ?? Date()
        fileCache[path] = CachedFile(
            content: content,
            modifiedAt: modTime,
            expiresAt: Date().addingTimeInterval(fileCacheExpiry),
            lastAccessedAt: Date()
        )
    }

    public func invalidateFileCache(_ path: String) async {
        fileCache.removeValue(forKey: path)
    }

    public func invalidateAllFileCache() async {
        fileCache.removeAll()
    }

    // MARK: - API 响应缓存

    public func getCachedAPIResponse(_ key: String) async -> String? {
        await cleanupExpiredAPICache()

        guard let cached = apiResponseCache[key],
              cached.expiresAt > Date() else {
            return nil
        }

        apiResponseCache[key]?.lastAccessedAt = Date()
        return cached.response
    }

    public func cacheAPIResponse(_ key: String, response: String) async {
        apiResponseCache[key] = CachedResponse(
            response: response,
            expiresAt: Date().addingTimeInterval(apiCacheExpiry),
            lastAccessedAt: Date()
        )
    }

    // MARK: - 搜索结果缓存

    public func getCachedSearchResult(_ query: String) async -> [String]? {
        await cleanupExpiredSearchCache()

        guard let cached = searchResultCache[query],
              cached.expiresAt > Date() else {
            return nil
        }

        searchResultCache[query]?.lastAccessedAt = Date()
        return cached.results
    }

    public func cacheSearchResult(_ query: String, results: [String]) async {
        searchResultCache[query] = CachedSearchResultData(
            results: results,
            expiresAt: Date().addingTimeInterval(searchCacheExpiry),
            lastAccessedAt: Date()
        )
    }

    // MARK: - 清理过期缓存

    private func cleanupExpiredFileCache() async {
        let now = Date()
        fileCache = fileCache.filter { $0.value.expiresAt > now }
    }

    private func cleanupExpiredAPICache() async {
        let now = Date()
        apiResponseCache = apiResponseCache.filter { $0.value.expiresAt > now }
    }

    private func cleanupExpiredSearchCache() async {
        let now = Date()
        searchResultCache = searchResultCache.filter { $0.value.expiresAt > now }
    }

    // MARK: - 统计信息

    public func getCacheStats() async -> SimpleCacheStats {
        return SimpleCacheStats(
            fileCacheSize: fileCache.count,
            apiCacheSize: apiResponseCache.count,
            searchCacheSize: searchResultCache.count,
            totalMemoryUsage: estimateMemoryUsage()
        )
    }

    private func estimateMemoryUsage() -> Int {
        var total = 0
        for (key, value) in fileCache {
            total += key.utf8.count + value.content.utf8.count
        }
        for (key, value) in apiResponseCache {
            total += key.utf8.count + value.response.utf8.count
        }
        for (key, value) in searchResultCache {
            total += key.utf8.count
            for result in value.results {
                total += result.utf8.count
            }
        }
        return total
    }

    // MARK: - 辅助方法

    private func getFileModificationTime(_ path: String) -> Date? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let modDate = attributes[.modificationDate] as? Date else {
            return nil
        }
        return modDate
    }
}

// MARK: - 缓存数据结构

struct CachedFile {
    let content: String
    let modifiedAt: Date
    let expiresAt: Date
    var lastAccessedAt: Date
}

struct CachedResponse {
    let response: String
    let expiresAt: Date
    var lastAccessedAt: Date
}

struct CachedSearchResultData {
    let results: [String]
    let expiresAt: Date
    var lastAccessedAt: Date
}

public struct SimpleCacheStats {
    public let fileCacheSize: Int
    public let apiCacheSize: Int
    public let searchCacheSize: Int
    public let totalMemoryUsage: Int

    public var formattedMemoryUsage: String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .memory
        return formatter.string(fromByteCount: Int64(totalMemoryUsage))
    }
}

/// 请求批处理器
public actor RequestBatcher {
    private var pendingRequests: [BatchableRequest] = []
    private var batchTimer: Task<Void, Never>?
    private let batchDelay: TimeInterval = 0.1
    private let executor: @Sendable (BatchableRequest) async -> Any

    public init(executor: @escaping @Sendable (BatchableRequest) async -> Any) {
        self.executor = executor
    }

    public func enqueue(_ request: BatchableRequest) async {
        pendingRequests.append(request)

        // 取消现有的定时器
        batchTimer?.cancel()

        // 启动新的定时器
        batchTimer = Task {
            try? await Task.sleep(nanoseconds: UInt64(batchDelay * 1_000_000_000))
            await executeBatch()
        }
    }

    private func executeBatch() async {
        guard !pendingRequests.isEmpty else { return }

        let requests = pendingRequests
        pendingRequests.removeAll()

        // 分类请求
        let (parallelRequests, serialRequests) = categorizeRequests(requests)
        let localExecutor = executor

        // 并行执行可以并行的请求
        await withTaskGroup(of: Void.self) { group in
            for request in parallelRequests {
                group.addTask {
                    _ = await localExecutor(request)
                }
            }
        }

        // 串行执行需要顺序的请求
        for request in serialRequests {
            _ = await localExecutor(request)
        }
    }

    private func categorizeRequests(_ requests: [BatchableRequest]) -> (parallel: [BatchableRequest], serial: [BatchableRequest]) {
        var parallel: [BatchableRequest] = []
        var serial: [BatchableRequest] = []

        for request in requests {
            if request.canRunInParallel {
                parallel.append(request)
            } else {
                serial.append(request)
            }
        }

        return (parallel, serial)
    }
}

public struct BatchableRequest: Sendable {
    public let id: String
    public let type: RequestType
    public let canRunInParallel: Bool
    public let priority: Int

    public init(id: String, type: RequestType, canRunInParallel: Bool = true, priority: Int = 0) {
        self.id = id
        self.type = type
        self.canRunInParallel = canRunInParallel
        self.priority = priority
    }

    public enum RequestType: Sendable {
        case readFile(String)
        case writeFile(String, String)
        case search(String)
        case command(String)
    }
}

/// 增量更新管理器
@MainActor
public class IncrementalUpdateManager: ObservableObject {
    @Published public var items: [UpdatableItem] = []

    public init() {}

    public func appendText(to itemID: String, text: String) {
        if let index = items.firstIndex(where: { $0.id == itemID }) {
            items[index].text += text
            items[index].lastUpdated = Date()
        } else {
            items.append(UpdatableItem(id: itemID, text: text))
        }
    }

    public func updateItem(id: String, transform: (inout UpdatableItem) -> Void) {
        if let index = items.firstIndex(where: { $0.id == id }) {
            transform(&items[index])
            items[index].lastUpdated = Date()
        }
    }

    public func removeItem(id: String) {
        items.removeAll { $0.id == id }
    }

    public func clear() {
        items.removeAll()
    }
}

public struct UpdatableItem: Identifiable {
    public let id: String
    public var text: String
    public var lastUpdated: Date

    public init(id: String, text: String, lastUpdated: Date = Date()) {
        self.id = id
        self.text = text
        self.lastUpdated = lastUpdated
    }
}

/// 流式文件读取器
public final class StreamingFileReader: Sendable {
    private let chunkSize: Int

    public init(chunkSize: Int = 8192) {
        self.chunkSize = chunkSize
    }

    public func readLargeFile(_ path: String) -> AsyncStream<String> {
        let chunkSize = self.chunkSize
        return AsyncStream { continuation in
            Task {
                guard let fileHandle = FileHandle(forReadingAtPath: path) else {
                    continuation.finish()
                    return
                }

                defer {
                    try? fileHandle.close()
                }

                while true {
                    autoreleasepool {
                        let data = fileHandle.readData(ofLength: chunkSize)
                        if data.isEmpty {
                            continuation.finish()
                            return
                        }

                        if let chunk = String(data: data, encoding: .utf8) {
                            continuation.yield(chunk)
                        }
                    }
                }
            }
        }
    }

    public func readLargeFileLineByLine(_ path: String) -> AsyncStream<String> {
        let chunkSize = self.chunkSize
        return AsyncStream { continuation in
            Task {
                guard let fileHandle = FileHandle(forReadingAtPath: path) else {
                    continuation.finish()
                    return
                }

                defer {
                    try? fileHandle.close()
                }

                var buffer = Data()
                let newlineData = "\n".data(using: .utf8)!

                while true {
                    autoreleasepool {
                        let chunk = fileHandle.readData(ofLength: chunkSize)
                        if chunk.isEmpty {
                            // 处理剩余的 buffer
                            if !buffer.isEmpty, let line = String(data: buffer, encoding: .utf8) {
                                continuation.yield(line)
                            }
                            continuation.finish()
                            return
                        }

                        buffer.append(chunk)

                        // 查找换行符并分割
                        while let range = buffer.range(of: newlineData) {
                            let lineData = buffer.subdata(in: 0..<range.lowerBound)
                            if let line = String(data: lineData, encoding: .utf8) {
                                continuation.yield(line)
                            }
                            buffer.removeSubrange(0..<range.upperBound)
                        }
                    }
                }
            }
        }
    }
}
