import Foundation

public final class GitService: @unchecked Sendable {
    private let root: URL

    public init(root: URL) throws {
        self.root = root.standardizedFileURL
        guard FileManager.default.fileExists(atPath: self.root.path) else { throw CocoaError(.fileNoSuchFile) }
    }

    @discardableResult
    public func initializeIfNeeded() throws -> String {
        if FileManager.default.fileExists(atPath: root.appendingPathComponent(".git").path) { return "Git repository already initialized" }
        return try run(arguments: ["init"]).stdout
    }

    public func status() throws -> String {
        try run(arguments: ["status", "--short", "--branch"]).stdout
    }

    public func statusEntries() throws -> [GitStatusEntry] {
        GitService.parsePorcelainStatus(try run(arguments: ["status", "--porcelain=v1"]).stdout)
    }

    public func diff() throws -> String {
        try run(arguments: ["diff", "--no-ext-diff", "--"] ).stdout
    }

    public func addIntentToAdd(path: String) throws {
        _ = try run(arguments: ["add", "-N", "--", path])
    }

    public func stage(path: String) throws {
        _ = try run(arguments: ["add", "--", path])
    }

    public func unstage(path: String) throws {
        _ = try run(arguments: ["restore", "--staged", "--", path])
    }

    public func commit(message: String) throws {
        _ = try run(arguments: ["commit", "-m", message])
    }

    public func push(remote: String = "origin", branch: String? = nil) throws {
        var arguments = ["push", remote]
        if let branch { arguments.append(branch) }
        _ = try run(arguments: arguments)
    }

    public func log(limit: Int = 20) throws -> String {
        try run(arguments: ["log", "-n", "\(max(1, limit))", "--oneline", "--decorate"]).stdout
    }

    public func currentRevision() throws -> String {
        try run(arguments: ["rev-parse", "--verify", "HEAD"]).stdout
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func trackedFiles(revision: String = "HEAD") throws -> [String] {
        try run(arguments: ["ls-tree", "-r", "--name-only", revision]).stdout
            .split(separator: "\n")
            .map(String.init)
    }

    public func fileContent(revision: String, path: String) throws -> String {
        try run(arguments: ["show", "\(revision):\(path)"]).stdout
    }

    public func textFiles(revision: String) throws -> [String: String] {
        var result: [String: String] = [:]
        for path in try trackedFiles(revision: revision) {
            if let content = try? fileContent(revision: revision, path: path) { result[path] = content }
        }
        return result
    }

    public func blame(path: String) throws -> String {
        try run(arguments: ["blame", "--", path]).stdout
    }

    public func removeWorktree(path: URL) throws {
        _ = try run(arguments: ["worktree", "remove", path.path])
    }

    public func createWorktree(path: URL, branch: String, base: String = "HEAD") throws -> String {
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        return try run(arguments: ["worktree", "add", "-b", branch, path.path, base]).stdout
    }

    public static func parsePorcelainStatus(_ output: String) -> [GitStatusEntry] {
        output
            .split(separator: "\n", omittingEmptySubsequences: false)
            .compactMap { rawLine -> GitStatusEntry? in
                let line = String(rawLine)
                guard line.count >= 3 else { return nil }
                let first = line[line.startIndex]
                let second = line[line.index(after: line.startIndex)]
                let rawPath = String(line.dropFirst(3))
                guard !rawPath.isEmpty else { return nil }
                let path = rawPath.components(separatedBy: " -> ").last ?? rawPath
                return GitStatusEntry(indexStatus: first, workingTreeStatus: second, path: path)
            }
    }

    private func run(arguments: [String], timeout: TimeInterval = 60) throws -> (stdout: String, stderr: String, exitCode: Int32) {
        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git"] + arguments
        process.currentDirectoryURL = root
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        let drainer = ProcessOutputDrainer(stdout: stdoutPipe, stderr: stderrPipe)
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        try process.run()
        if finished.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            _ = finished.wait(timeout: .now() + 2)
            throw GitError(command: arguments.joined(separator: " "), detail: "Git 命令超时（\(Int(timeout))s）")
        }
        let output = drainer.joined()
        let stdout = String(data: output.stdout, encoding: .utf8) ?? ""
        let stderr = String(data: output.stderr, encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else { throw GitError(command: arguments.joined(separator: " "), detail: stderr) }
        return (stdout, stderr, process.terminationStatus)
    }
}

public struct GitStatusEntry: Sendable, Equatable, Identifiable {
    public var id: String { path }
    public let indexStatus: Character
    public let workingTreeStatus: Character
    public let path: String

    public var isStaged: Bool {
        indexStatus != " " && indexStatus != "?"
    }

    public var hasUnstagedChanges: Bool {
        workingTreeStatus != " " || indexStatus == "?"
    }

    public var title: String {
        switch (indexStatus, workingTreeStatus) {
        case ("?", "?"): return "Untracked"
        case ("A", _): return "Added"
        case ("M", " "), (" ", "M"), ("M", "M"): return "Modified"
        case ("D", _), (_, "D"): return "Deleted"
        case ("R", _): return "Renamed"
        case ("C", _): return "Copied"
        case ("U", _), (_, "U"): return "Conflict"
        default: return "\(indexStatus)\(workingTreeStatus)"
        }
    }

    public var fileStatus: GitFileStatus {
        switch (indexStatus, workingTreeStatus) {
        case ("?", "?"): return .untracked
        case ("U", _), (_, "U"): return .conflict
        case ("D", _), (_, "D"): return .deleted
        case ("R", _): return .renamed
        case let (index, _) where index != " " && index != "?": return .staged
        default: return .modified
        }
    }
}

public struct GitError: LocalizedError, Sendable {
    public let command: String
    public let detail: String
    public var errorDescription: String? { "Git \(command) failed: \(detail)" }
}

public struct ReviewFinding: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let severity: Severity
    public let category: Category
    public let file: String
    public let startLine: Int
    public let endLine: Int
    public let title: String
    public let evidence: String
    public let recommendation: String

    public init(id: UUID = UUID(), severity: Severity, category: Category, file: String, startLine: Int, endLine: Int, title: String, evidence: String, recommendation: String) {
        self.id = id
        self.severity = severity
        self.category = category
        self.file = file
        self.startLine = startLine
        self.endLine = endLine
        self.title = title
        self.evidence = evidence
        self.recommendation = recommendation
    }

    public enum Severity: String, Codable, CaseIterable, Sendable {
        case p0, p1, p2, p3
        public var title: String { rawValue.uppercased() }
    }

    public enum Category: String, Codable, CaseIterable, Sendable {
        case correctness
        case security
        case performance
        case maintainability
        case testGap = "test-gap"

        public var title: String {
            switch self {
            case .correctness: "正确性"
            case .security: "安全"
            case .performance: "性能"
            case .maintainability: "可维护性"
            case .testGap: "测试缺口"
            }
        }
    }
}
