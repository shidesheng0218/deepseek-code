import CryptoKit
import Foundation

public struct FileEvidence: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let sessionID: String?
    public let path: String
    public let startLine: Int
    public let endLine: Int
    public let content: String
    public let contentHash: String
    public let truncated: Bool
    public let byteCount: Int
    public let warnings: [String]
    public let createdAt: Date

    public init(
        id: String = UUID().uuidString,
        sessionID: String? = nil,
        path: String,
        startLine: Int,
        endLine: Int,
        content: String,
        contentHash: String,
        truncated: Bool,
        byteCount: Int,
        warnings: [String] = [],
        createdAt: Date = Date()
    ) {
        self.id = id
        self.sessionID = sessionID
        self.path = path
        self.startLine = startLine
        self.endLine = endLine
        self.content = content
        self.contentHash = contentHash
        self.truncated = truncated
        self.byteCount = byteCount
        self.warnings = warnings
        self.createdAt = createdAt
    }
}

public enum WorkspaceEvidenceError: LocalizedError, Sendable {
    case secretPath
    case binaryFile
    case invalidRange

    public var errorDescription: String? {
        switch self {
        case .secretPath: "为避免泄露，凭据文件不能生成模型 Evidence"
        case .binaryFile: "二进制文件不能生成文本 Evidence"
        case .invalidRange: "文件行范围无效"
        }
    }
}

public extension WorkspaceToolHost {
    func readEvidence(path: String, sessionID: String? = nil, startLine: Int = 1, maxLines: Int = 200, maxBytes: Int = 32_000) throws -> FileEvidence {
        guard startLine >= 1, maxLines > 0, maxBytes > 0 else { throw WorkspaceEvidenceError.invalidRange }
        guard !Self.isSensitivePath(path) else { throw WorkspaceEvidenceError.secretPath }
        let kind = try detectFileKind(path: path)
        guard !kind.isBinary else { throw WorkspaceEvidenceError.binaryFile }
        let value = try readFile(path: path, startLine: startLine, maxLines: min(maxLines, 500))
        let originalPrefix = String(value.content.prefix(maxBytes))
        let bounded = SecretRedactor.redact(originalPrefix)
        let actualEnd = startLine + max(0, bounded.split(separator: "\n", omittingEmptySubsequences: false).count - 1)
        var warnings: [String] = []
        if value.truncated || originalPrefix.count < value.content.count { warnings.append("内容已按范围或大小截断") }
        if bounded != originalPrefix { warnings.append("检测到疑似凭据，已脱敏") }
        return FileEvidence(
            sessionID: sessionID,
            path: path,
            startLine: startLine,
            endLine: actualEnd,
            content: bounded,
            contentHash: Self.sha256(bounded),
            truncated: value.truncated || bounded.count < value.content.count,
            byteCount: kind.byteCount,
            warnings: warnings
        )
    }

    private static func isSensitivePath(_ path: String) -> Bool {
        let lowered = path.lowercased()
        let names = [".env", ".pem", ".key", "id_rsa", "id_ed25519", "credentials", "secrets", "token"]
        return names.contains { lowered == $0 || lowered.hasSuffix("/\($0)") || lowered.contains("/\($0).") }
    }

    private static func sha256(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

public struct LSPQuery: Codable, Equatable, Sendable {
    public let path: String
    public let method: String
    public let line: Int?
    public let column: Int?
    public let symbol: String?

    public init(path: String, method: String, line: Int? = nil, column: Int? = nil, symbol: String? = nil) {
        self.path = path
        self.method = method
        self.line = line
        self.column = column
        self.symbol = symbol
    }
}

public struct LSPResult: Codable, Equatable, Sendable {
    public let method: String
    public let items: [[String: String]]
    public let available: Bool
    public let warnings: [String]
    public let createdAt: Date

    public init(method: String, items: [[String: String]] = [], available: Bool, warnings: [String] = [], createdAt: Date = Date()) {
        self.method = method
        self.items = items
        self.available = available
        self.warnings = warnings
        self.createdAt = createdAt
    }
}

public protocol LSPService: Sendable {
    func query(_ request: LSPQuery, workspaceRoot: URL) async -> LSPResult
}

/// A safe baseline LSP adapter. It performs no shell execution and reports
/// capability absence explicitly; platform-specific SourceKit/TypeScript LSP
/// adapters can be registered later without changing the tool contract.
public struct LocalLSPService: LSPService {
    public init() {}

    public func query(_ request: LSPQuery, workspaceRoot: URL) async -> LSPResult {
        let path = workspaceRoot.appendingPathComponent(request.path).standardizedFileURL
        guard path.path.hasPrefix(workspaceRoot.standardizedFileURL.path + "/"), FileManager.default.fileExists(atPath: path.path) else {
            return LSPResult(method: request.method, available: false, warnings: ["文件不存在或路径不在工作区内"])
        }
        return LSPResult(method: request.method, available: false, warnings: ["当前项目未注册可用的 LSP Server；未伪装成语义结果"])
    }
}

/// Compatibility name for the eventual native SourceKit adapter. Until a
/// project registers a real server, this implementation deliberately reports
/// unavailable rather than fabricating semantic locations.
public typealias SourceKitLSPService = LocalLSPService
