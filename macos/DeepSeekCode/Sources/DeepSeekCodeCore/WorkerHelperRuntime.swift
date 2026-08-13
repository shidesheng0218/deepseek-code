import CryptoKit
import Foundation

/// Versioned envelope for an isolated read-only Worker helper. The helper is
/// intentionally given a workspace path and a capability contract, never a
/// SessionRepository, a provider key, a terminal handle, or an approval API.
public struct WorkerHelperRequest: Codable, Equatable, Sendable {
    public let protocolVersion: Int
    public let requestID: String
    public let workerSessionID: String
    public let sessionID: String
    public let workerID: String
    public let workspaceRoot: String
    public let contract: WorkerSessionContract
    public let deadline: Date

    public init(
        protocolVersion: Int = 1,
        requestID: String = UUID().uuidString,
        workerSessionID: String,
        sessionID: String,
        workerID: String,
        workspaceRoot: String,
        contract: WorkerSessionContract,
        deadline: Date = Date().addingTimeInterval(60)
    ) {
        self.protocolVersion = protocolVersion
        self.requestID = requestID
        self.workerSessionID = workerSessionID
        self.sessionID = sessionID
        self.workerID = workerID
        self.workspaceRoot = workspaceRoot
        self.contract = contract
        self.deadline = deadline
    }
}

public struct WorkerHelperResponse: Codable, Equatable, Sendable {
    public let protocolVersion: Int
    public let requestID: String
    public let ok: Bool
    public let result: WorkerResultEnvelope?
    public let error: String?

    public init(protocolVersion: Int = 1, requestID: String, ok: Bool, result: WorkerResultEnvelope? = nil, error: String? = nil) {
        self.protocolVersion = protocolVersion
        self.requestID = requestID
        self.ok = ok
        self.result = result
        self.error = error.map(SecretRedactor.redact)
    }
}

public enum WorkerHelperError: LocalizedError, Sendable {
    case unsupportedProtocol
    case invalidContract
    case workspaceUnavailable
    case deadlineExceeded
    case unsupportedKind

    public var errorDescription: String? {
        switch self {
        case .unsupportedProtocol: "Worker Helper 协议版本不兼容"
        case .invalidContract: "Worker 合同违反只读能力边界"
        case .workspaceUnavailable: "Worker 工作区不可读取"
        case .deadlineExceeded: "Worker 已超过执行期限"
        case .unsupportedKind: "该 Worker 类型尚未有可安全执行的只读实现"
        }
    }
}

/// Pure, testable Worker implementation. Its output is a content-addressed
/// envelope that still requires a parent Supervisor adoption before becoming
/// usable by the main Agent.
public enum WorkerHelperService {
    public static func execute(_ request: WorkerHelperRequest) async throws -> WorkerHelperResponse {
        guard request.protocolVersion == 1 else { throw WorkerHelperError.unsupportedProtocol }
        guard request.contract.parentSessionID == request.sessionID,
              request.contract.workerKind != .main,
              request.contract.allowedEffects.allSatisfy({ AgentWorkerPolicy.allows($0, for: request.contract.workerKind) }) else {
            throw WorkerHelperError.invalidContract
        }
        guard Date() < request.deadline else { throw WorkerHelperError.deadlineExceeded }
        let root = URL(fileURLWithPath: request.workspaceRoot, isDirectory: true).standardizedFileURL
        guard FileManager.default.fileExists(atPath: root.path) else { throw WorkerHelperError.workspaceUnavailable }

        let result: WorkerResultEnvelope
        switch request.contract.workerKind {
        case .explore:
            result = try explore(request: request, root: root)
        case .review:
            result = try review(request: request, root: root)
        case .browser, .ci:
            // Browser and CI Workers consume evidence produced by their
            // respective hosts. They deliberately cannot acquire browser or
            // network access on their own.
            result = informationalResult(
                request: request,
                summary: "\(request.contract.workerKind.title) Worker 等待主 Supervisor 提供只读 Evidence。",
                warnings: ["Worker 未获得 Browser、Terminal、网络或外部系统权限"]
            )
        case .main:
            throw WorkerHelperError.invalidContract
        }
        return WorkerHelperResponse(requestID: request.requestID, ok: true, result: result)
    }

    private static func explore(request: WorkerHelperRequest, root: URL) throws -> WorkerResultEnvelope {
        let excluded = Set([".git", ".build", "node_modules", "DerivedData", ".DS_Store"])
        let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        )
        var paths: [String] = []
        var totalBytes = 0
        while let file = enumerator?.nextObject() as? URL, paths.count < 160 {
            let relative = file.path.replacingOccurrences(of: root.path + "/", with: "")
            guard !relative.isEmpty,
                  !relative.split(separator: "/").contains(where: { excluded.contains(String($0)) }) else { continue }
            let values = try? file.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
            if values?.isDirectory == true {
                paths.append(relative + "/")
            } else {
                totalBytes += values?.fileSize ?? 0
                paths.append(relative)
            }
        }
        let evidenceID = evidenceID(kind: "explore", content: paths.joined(separator: "\n"))
        let summary = paths.isEmpty
            ? "项目目录为空或没有可读取文件。"
            : "项目结构（前 \(paths.count) 项）：\(paths.joined(separator: "、"))"
        return envelope(
            request: request,
            summary: truncate(summary, limit: request.contract.maxOutputBytes),
            evidenceIDs: [evidenceID],
            warnings: totalBytes > 20_000_000 ? ["项目较大，结构清单已截断"] : [],
            content: summary
        )
    }

    private static func review(request: WorkerHelperRequest, root: URL) throws -> WorkerResultEnvelope {
        let diffURL = root.appendingPathComponent(".git", isDirectory: true)
        let summary: String
        var warnings: [String] = []
        if FileManager.default.fileExists(atPath: diffURL.path) {
            // Do not shell out to git: the helper's review is intentionally a
            // filesystem-only analysis. Full git evidence is supplied by the
            // parent when it has already requested it through ToolRegistry.
            summary = "Review Worker 已确认这是 Git 工作区；等待主 Supervisor 传入 Diff Evidence 后进行 P0–P3 审查。"
            warnings.append("未直接调用 Git 或 Terminal；避免 Worker 获得进程能力")
        } else {
            summary = "Review Worker 未检测到 Git 元数据；等待主 Supervisor 提供 Diff Evidence。"
        }
        let evidenceID = evidenceID(kind: "review", content: summary)
        return envelope(request: request, summary: summary, evidenceIDs: [evidenceID], warnings: warnings, content: summary)
    }

    private static func informationalResult(request: WorkerHelperRequest, summary: String, warnings: [String]) -> WorkerResultEnvelope {
        envelope(request: request, summary: summary, evidenceIDs: [], warnings: warnings, content: summary)
    }

    private static func envelope(
        request: WorkerHelperRequest,
        summary: String,
        evidenceIDs: [String],
        warnings: [String],
        content: String
    ) -> WorkerResultEnvelope {
        WorkerResultEnvelope(
            workerID: request.workerID,
            sessionID: request.sessionID,
            summary: SecretRedactor.redact(summary),
            evidenceIDs: evidenceIDs,
            warnings: warnings.map(SecretRedactor.redact),
            inputHash: sha256("\(request.contract.objective)|\(request.workspaceRoot)|\(request.workerSessionID)"),
            outputHash: sha256(content)
        )
    }

    private static func evidenceID(kind: String, content: String) -> String {
        "worker-\(kind)-\(sha256(content).prefix(16))"
    }

    private static func sha256(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func truncate(_ value: String, limit: Int) -> String {
        String(value.prefix(max(256, min(limit, 128_000))))
    }
}

public enum WorkerHelperJSON {
    public static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return encoder
    }

    public static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }
}

/// Executes the packaged `deepseek-worker` helper as a real child process.
/// The parent passes only a read-only Worker contract and a workspace path;
/// the helper never receives the repository, provider credentials, terminal
/// handles or approval APIs. Results remain `awaitingAdoption` until the
/// parent explicitly adopts them through `DurableChildAgentRuntime`.
public struct ProcessChildAgentExecutionDriver: ChildAgentExecutionDriver, @unchecked Sendable {
    public let executableURL: URL
    /// Receives both identities: the parent Session remains part of the
    /// Worker envelope/audit chain, while the Child Session ID resolves the
    /// persisted contract and its exact workspace.
    public let workspaceResolver: @Sendable (_ parentSessionID: String, _ workerSessionID: String) -> URL
    public let timeout: TimeInterval

    public init(
        executableURL: URL,
        workspaceResolver: @escaping @Sendable (_ parentSessionID: String, _ workerSessionID: String) -> URL,
        timeout: TimeInterval = 60
    ) {
        self.executableURL = executableURL
        self.workspaceResolver = workspaceResolver
        self.timeout = max(0.1, timeout)
    }

    public func execute(
        contract: WorkerSessionContract,
        sessionID: String,
        workerID: String,
        workerSessionID: String
    ) async throws -> WorkerResultEnvelope {
        guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            throw ChildAgentRuntimeError.failed("找不到可执行的 deepseek-worker：\(executableURL.path)")
        }
        let workspace = workspaceResolver(sessionID, workerSessionID).standardizedFileURL
        let request = WorkerHelperRequest(
            workerSessionID: workerSessionID,
            sessionID: sessionID,
            workerID: workerID,
            workspaceRoot: workspace.path,
            contract: contract,
            deadline: Date().addingTimeInterval(timeout)
        )
        return try await Task.detached(priority: .userInitiated) {
            try Self.run(request: request, executableURL: executableURL, timeout: timeout)
        }.value
    }

    private static func run(request: WorkerHelperRequest, executableURL: URL, timeout: TimeInterval) throws -> WorkerResultEnvelope {
        let process = Process()
        let input = Pipe()
        let output = Pipe()
        let errors = Pipe()
        process.executableURL = executableURL
        process.arguments = ["--stdio"]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        try process.run()

        let encoded = try WorkerHelperJSON.encoder.encode(request) + Data([0x0A])
        try input.fileHandleForWriting.write(contentsOf: encoded)
        try input.fileHandleForWriting.close()

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        if process.isRunning {
            process.terminate()
            let terminationDeadline = Date().addingTimeInterval(1)
            while process.isRunning && Date() < terminationDeadline {
                Thread.sleep(forTimeInterval: 0.01)
            }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            throw ChildAgentRuntimeError.timedOut
        }

        let stdout = output.fileHandleForReading.readDataToEndOfFile()
        let stderr = errors.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0 else {
            let message = String(data: stderr, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
                ?? "deepseek-worker 退出码 \(process.terminationStatus)"
            throw ChildAgentRuntimeError.failed(SecretRedactor.redact(message))
        }
        guard let line = String(decoding: stdout, as: UTF8.self)
            .split(separator: "\n")
            .first
            .map(String.init),
            let response = try? WorkerHelperJSON.decoder.decode(WorkerHelperResponse.self, from: Data(line.utf8)),
            response.requestID == request.requestID else {
            throw ChildAgentRuntimeError.failed("deepseek-worker 返回了无效响应")
        }
        guard response.ok, let result = response.result else {
            throw ChildAgentRuntimeError.failed(response.error ?? "deepseek-worker 执行失败")
        }
        return result
    }
}
