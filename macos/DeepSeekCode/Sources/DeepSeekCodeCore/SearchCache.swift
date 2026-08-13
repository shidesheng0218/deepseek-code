import Foundation
import SQLite3

// MARK: - SQLITE_TRANSIENT constant

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

// MARK: - Search Cache

/// SQLite-based search result cache with 24-hour TTL
public actor SearchCache {
    private let dbPath: String
    private var db: OpaquePointer?
    private let cacheTTL: TimeInterval = 24 * 60 * 60  // 24 hours

    public init(dbPath: String? = nil) {
        if let path = dbPath {
            self.dbPath = path
        } else {
            let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            let dbDir = cacheDir.appendingPathComponent("com.deepseek.code/search-cache", isDirectory: true)
            try? FileManager.default.createDirectory(at: dbDir, withIntermediateDirectories: true)
            self.dbPath = dbDir.appendingPathComponent("search-cache.db").path
        }
    }

    // MARK: - Database Lifecycle

    private func open() throws {
        guard db == nil else { return }

        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(dbPath, &db, flags, nil) == SQLITE_OK else {
            throw CacheError.databaseOpenFailed
        }

        try createTables()
    }

    private func close() {
        if let db = db {
            sqlite3_close(db)
            self.db = nil
        }
    }

    private func createTables() throws {
        let createTableSQL = """
        CREATE TABLE IF NOT EXISTS search_results (
            query_hash TEXT PRIMARY KEY,
            query TEXT NOT NULL,
            intent TEXT NOT NULL,
            results_json TEXT NOT NULL,
            provider_ids TEXT NOT NULL,
            cached_at REAL NOT NULL,
            hit_count INTEGER DEFAULT 0
        );
        CREATE INDEX IF NOT EXISTS idx_cached_at ON search_results(cached_at);
        CREATE INDEX IF NOT EXISTS idx_query ON search_results(query);
        """

        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, createTableSQL, nil, nil, &error) == SQLITE_OK else {
            if let error = error {
                let message = String(cString: error)
                sqlite3_free(error)
                throw CacheError.sqlError(message)
            }
            throw CacheError.tableCreationFailed
        }
    }

    // MARK: - Cache Operations

    public func get(query: String, intent: SearchIntent) async throws -> CachedSearchResult? {
        try open()

        let queryHash = hashQuery(query, intent: intent)
        let sql = "SELECT results_json, provider_ids, cached_at FROM search_results WHERE query_hash = ? LIMIT 1"

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw CacheError.queryPreparationFailed
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, queryHash, -1, SQLITE_TRANSIENT)

        guard sqlite3_step(stmt) == SQLITE_ROW else {
            return nil  // Cache miss
        }

        guard let resultsJSON = sqlite3_column_text(stmt, 0),
              let providerIDs = sqlite3_column_text(stmt, 1) else {
            return nil
        }

        let cachedAt = sqlite3_column_double(stmt, 2)
        let cacheAge = Date().timeIntervalSince1970 - cachedAt

        // Check TTL
        if cacheAge > cacheTTL {
            print("🗑️ [CACHE] Expired entry for query: \(query) (age: \(Int(cacheAge))s)")
            try await delete(queryHash: queryHash)
            return nil
        }

        print("✅ [CACHE] Hit for query: \(query) (age: \(Int(cacheAge))s)")

        // Increment hit count
        try await incrementHitCount(queryHash: queryHash)

        // Decode results
        let resultsData = Data(String(cString: resultsJSON).utf8)
        let results = try JSONDecoder().decode([WebSourceRecord].self, from: resultsData)

        let providers = String(cString: providerIDs).components(separatedBy: ",")

        return CachedSearchResult(
            results: results,
            providerIDs: providers,
            cachedAt: Date(timeIntervalSince1970: cachedAt),
            cacheAge: cacheAge
        )
    }

    public func set(query: String, intent: SearchIntent, results: [WebSourceRecord], providerIDs: [String]) async throws {
        try open()

        let queryHash = hashQuery(query, intent: intent)
        let resultsData = try JSONEncoder().encode(results)
        let resultsJSON = String(data: resultsData, encoding: .utf8) ?? "[]"
        let providerIDsStr = providerIDs.joined(separator: ",")
        let now = Date().timeIntervalSince1970

        let sql = """
        INSERT OR REPLACE INTO search_results (query_hash, query, intent, results_json, provider_ids, cached_at, hit_count)
        VALUES (?, ?, ?, ?, ?, ?, 0)
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw CacheError.insertPreparationFailed
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, queryHash, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, query, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 3, intent.rawValue, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 4, resultsJSON, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 5, providerIDsStr, -1, SQLITE_TRANSIENT)
        sqlite3_bind_double(stmt, 6, now)

        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw CacheError.insertFailed
        }

        print("💾 [CACHE] Stored \(results.count) results for query: \(query)")
    }

    private func incrementHitCount(queryHash: String) async throws {
        let sql = "UPDATE search_results SET hit_count = hit_count + 1 WHERE query_hash = ?"

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            return  // Non-critical operation
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, queryHash, -1, SQLITE_TRANSIENT)
        sqlite3_step(stmt)
    }

    private func delete(queryHash: String) async throws {
        let sql = "DELETE FROM search_results WHERE query_hash = ?"

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            return
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, queryHash, -1, SQLITE_TRANSIENT)
        sqlite3_step(stmt)
    }

    // MARK: - Cache Maintenance

    public func cleanExpired() async throws {
        try open()

        let cutoff = Date().timeIntervalSince1970 - cacheTTL
        let sql = "DELETE FROM search_results WHERE cached_at < ?"

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw CacheError.cleanupFailed
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_double(stmt, 1, cutoff)

        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw CacheError.cleanupFailed
        }

        let deleted = sqlite3_changes(db)
        if deleted > 0 {
            print("🗑️ [CACHE] Cleaned \(deleted) expired entries")
        }
    }

    public func stats() async throws -> CacheStats {
        try open()

        let sql = """
        SELECT COUNT(*), SUM(hit_count), AVG(hit_count)
        FROM search_results
        WHERE cached_at > ?
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw CacheError.queryPreparationFailed
        }
        defer { sqlite3_finalize(stmt) }

        let cutoff = Date().timeIntervalSince1970 - cacheTTL
        sqlite3_bind_double(stmt, 1, cutoff)

        guard sqlite3_step(stmt) == SQLITE_ROW else {
            return CacheStats(totalEntries: 0, totalHits: 0, avgHitsPerEntry: 0)
        }

        let count = Int(sqlite3_column_int(stmt, 0))
        let hits = Int(sqlite3_column_int(stmt, 1))
        let avg = sqlite3_column_double(stmt, 2)

        return CacheStats(totalEntries: count, totalHits: hits, avgHitsPerEntry: avg)
    }

    // MARK: - Utilities

    private func hashQuery(_ query: String, intent: SearchIntent) -> String {
        let input = "\(query.lowercased()):\(intent.rawValue)"
        return SHA256.hash(input)
    }
}

// MARK: - Supporting Types

public struct CachedSearchResult: Sendable {
    public let results: [WebSourceRecord]
    public let providerIDs: [String]
    public let cachedAt: Date
    public let cacheAge: TimeInterval
}

public struct CacheStats: Sendable {
    public let totalEntries: Int
    public let totalHits: Int
    public let avgHitsPerEntry: Double
}

public enum CacheError: Error, LocalizedError {
    case databaseOpenFailed
    case tableCreationFailed
    case queryPreparationFailed
    case insertPreparationFailed
    case insertFailed
    case cleanupFailed
    case sqlError(String)

    public var errorDescription: String? {
        switch self {
        case .databaseOpenFailed:
            return "Failed to open cache database"
        case .tableCreationFailed:
            return "Failed to create cache tables"
        case .queryPreparationFailed:
            return "Failed to prepare cache query"
        case .insertPreparationFailed:
            return "Failed to prepare cache insert"
        case .insertFailed:
            return "Failed to insert into cache"
        case .cleanupFailed:
            return "Failed to clean up cache"
        case .sqlError(let message):
            return "SQL error: \(message)"
        }
    }
}

// MARK: - SHA256 Helper

private enum SHA256 {
    static func hash(_ input: String) -> String {
        guard let data = input.data(using: .utf8) else { return "" }
        var hash = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        data.withUnsafeBytes {
            _ = CC_SHA256($0.baseAddress, CC_LONG(data.count), &hash)
        }
        return hash.map { String(format: "%02x", $0) }.joined()
    }
}

import CommonCrypto
