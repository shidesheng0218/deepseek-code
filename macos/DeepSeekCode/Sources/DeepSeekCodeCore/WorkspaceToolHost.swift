import CryptoKit
import Foundation

public struct FileRead: Sendable, Equatable {
    public let content: String
    public let sha256: String
    public let truncated: Bool
}

public struct PatchChange: Sendable, Equatable {
    public let path: String
    public let content: String
    public let expectedHash: String?
    public let isDeletion: Bool

    public init(path: String, content: String, expectedHash: String? = nil, isDeletion: Bool = false) {
        self.path = path
        self.content = content
        self.expectedHash = expectedHash
        self.isDeletion = isDeletion
    }
}

public struct PatchResult: Sendable, Equatable {
    public let checkpointID: UUID
    public let changedFiles: [String]
}

public struct CommandOutput: Sendable, Equatable {
    public let command: String
    public let stdout: String
    public let stderr: String
    public let exitCode: Int32
    public let risk: CommandRisk
}

public enum GitFileStatus: String, Codable, Sendable, Equatable {
    case untracked
    case modified
    case staged
    case deleted
    case renamed
    case conflict
}

public struct WorkspaceFileNode: Sendable, Equatable, Identifiable {
    public var id: String { path }
    public let path: String
    public let name: String
    public let isDirectory: Bool
    public let depth: Int
    public let gitStatus: GitFileStatus?
    public let isExpanded: Bool

    public init(path: String, name: String, isDirectory: Bool, depth: Int, gitStatus: GitFileStatus?, isExpanded: Bool) {
        self.path = path
        self.name = name
        self.isDirectory = isDirectory
        self.depth = depth
        self.gitStatus = gitStatus
        self.isExpanded = isExpanded
    }
}

public struct FileKind: Sendable, Equatable {
    public let isBinary: Bool
    public let byteCount: Int
}

public struct EditableFileSnapshot: Sendable, Equatable {
    public let path: String
    public let content: String
    public let sha256: String
    public let encoding: String
    public let lineCount: Int
    public let byteCount: Int
    public let isLargeFile: Bool
    public let isBinary: Bool
}

public enum WorkspaceToolError: LocalizedError {
    case outsideWorkspace
    case hashMismatch(path: String)
    case commandTimedOut
    case binaryFile(path: String)

    public var errorDescription: String? {
        switch self {
        case .outsideWorkspace: "Path is outside the workspace"
        case let .hashMismatch(path): "hash mismatch for \(path)"
        case .commandTimedOut: "Command timed out"
        case let .binaryFile(path): "\(path) is a binary file"
        }
    }
}

private struct Checkpoint: Codable {
    let id: UUID
    let label: String
    let entries: [CheckpointEntry]
}

private struct CheckpointEntry: Codable {
    let path: String
    let existed: Bool
    let contentBase64: String?
}

public final class WorkspaceToolHost: @unchecked Sendable {
    private let root: URL
    private let checkpointDirectory: URL

    public var rootPath: String { root.path }

    public init(root: URL, checkpointDirectory: URL) throws {
        self.root = root.standardizedFileURL.resolvingSymlinksInPath()
        self.checkpointDirectory = checkpointDirectory.standardizedFileURL
        try FileManager.default.createDirectory(at: self.root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: self.checkpointDirectory, withIntermediateDirectories: true)
    }

    public func listDirectory(path: String = ".") throws -> [WorkspaceDirectoryEntry] {
        let directory = try resolve(path: path, allowRoot: true)
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
            .filter { $0.lastPathComponent != ".git" && $0.lastPathComponent != "node_modules" }
            .map { url in
                let values = try? url.resourceValues(forKeys: [.isDirectoryKey])
                return WorkspaceDirectoryEntry(name: url.lastPathComponent, isDirectory: values?.isDirectory ?? false)
            }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    public func listTree(path: String = ".", expanded: Set<String>, maxDepth: Int = 4, maxEntries: Int = 500, gitStatuses: [String: GitFileStatus] = [:]) throws -> [WorkspaceFileNode] {
        let directory = try resolve(path: path, allowRoot: true)
        let basePrefix = path == "." ? "" : normalizedRelativePath(path) + "/"
        var nodes: [WorkspaceFileNode] = []
        try appendTreeEntries(directory: directory, basePrefix: basePrefix, depth: 0, expanded: expanded, maxDepth: maxDepth, maxEntries: maxEntries, gitStatuses: gitStatuses, nodes: &nodes)
        return nodes
    }

    public func readFile(path: String, startLine: Int = 1, maxLines: Int = 200) throws -> FileRead {
        let url = try resolve(path: path)
        let content = try String(contentsOf: url, encoding: .utf8)
        let lines = content.split(separator: "\n", omittingEmptySubsequences: false)
        let start = max(0, startLine - 1)
        let limit = min(max(maxLines, 1), 500)
        let selected = lines.dropFirst(start).prefix(limit)
        let numbered = selected.enumerated().map { index, line in "\(start + index + 1): \(line)" }.joined(separator: "\n")
        return FileRead(content: numbered, sha256: digest(content), truncated: start + selected.count < lines.count)
    }

    public func detectFileKind(path: String) throws -> FileKind {
        let url = try resolve(path: path)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let byteCount = (attributes[.size] as? NSNumber)?.intValue ?? 0
        let sample = try Data(contentsOf: url, options: [.mappedIfSafe]).prefix(8_192)
        return FileKind(isBinary: sample.contains(0), byteCount: byteCount)
    }

    public func readEditableFile(path: String, maxBytes: Int = 1_000_000) throws -> EditableFileSnapshot {
        let url = try resolve(path: path)
        let kind = try detectFileKind(path: path)
        let isLarge = kind.byteCount > maxBytes
        guard !kind.isBinary else {
            return EditableFileSnapshot(path: normalizedRelativePath(path), content: "", sha256: "", encoding: "binary", lineCount: 0, byteCount: kind.byteCount, isLargeFile: isLarge, isBinary: true)
        }
        guard !isLarge else {
            let data = try Data(contentsOf: url, options: [.mappedIfSafe]).prefix(maxBytes)
            let preview = String(decoding: data, as: UTF8.self)
            return EditableFileSnapshot(path: normalizedRelativePath(path), content: preview, sha256: digest(preview), encoding: "utf-8", lineCount: lineCount(preview), byteCount: kind.byteCount, isLargeFile: true, isBinary: false)
        }
        let content = try String(contentsOf: url, encoding: .utf8)
        return EditableFileSnapshot(path: normalizedRelativePath(path), content: content, sha256: digest(content), encoding: "utf-8", lineCount: lineCount(content), byteCount: kind.byteCount, isLargeFile: false, isBinary: false)
    }

    public func saveEditableFile(path: String, content: String, expectedHash: String) throws -> EditableFileSnapshot {
        let current = try readEditableFile(path: path)
        if current.sha256 != expectedHash {
            throw WorkspaceToolError.hashMismatch(path: path)
        }
        _ = try applyPatch(changes: [PatchChange(path: path, content: content, expectedHash: expectedHash)], label: "editor save")
        return try readEditableFile(path: path)
    }

    public func searchWorkspace(query: String, maxMatches: Int = 100) throws -> [WorkspaceMatch] {
        guard !query.isEmpty else { return [] }
        let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
        var matches: [WorkspaceMatch] = []
        while let next = enumerator?.nextObject() as? URL, matches.count < maxMatches {
            if [".git", "node_modules", ".deepseek"].contains(next.lastPathComponent) {
                if (try? next.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true { enumerator?.skipDescendants() }
                continue
            }
            guard (try? next.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) != true,
                  let content = try? String(contentsOf: next, encoding: .utf8) else { continue }
            let relativePath = next.path.replacingOccurrences(of: root.path + "/", with: "")
            for (index, line) in content.split(separator: "\n", omittingEmptySubsequences: false).enumerated() where line.localizedCaseInsensitiveContains(query) {
                matches.append(WorkspaceMatch(path: relativePath, line: index + 1, text: String(line.prefix(300))))
                if matches.count >= maxMatches { break }
            }
        }
        return matches
    }

    public func applyPatch(changes: [PatchChange], label: String) throws -> PatchResult {
        guard !changes.isEmpty else { return PatchResult(checkpointID: UUID(), changedFiles: []) }
        let prepared = try changes.map { change -> (PatchChange, URL, String?) in
            let url = try resolve(path: change.path, allowMissingLeaf: true)
            let before = try? String(contentsOf: url, encoding: .utf8)
            if let expectedHash = change.expectedHash, digest(before ?? "") != expectedHash {
                throw WorkspaceToolError.hashMismatch(path: change.path)
            }
            return (change, url, before)
        }

        let checkpointID = UUID()
        let checkpoint = Checkpoint(
            id: checkpointID,
            label: label,
            entries: prepared.map { change, _, before in
                CheckpointEntry(path: change.path, existed: before != nil, contentBase64: before.map { Data($0.utf8).base64EncodedString() })
            }
        )
        let checkpointURL = checkpointDirectory.appendingPathComponent("\(checkpointID.uuidString).json")
        try JSONEncoder().encode(checkpoint).write(to: checkpointURL, options: .atomic)

        do {
            for (change, url, _) in prepared {
                if change.isDeletion {
                    try? FileManager.default.removeItem(at: url)
                    continue
                }
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                let temporary = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).deepseek-\(checkpointID.uuidString).tmp")
                try Data(change.content.utf8).write(to: temporary, options: .atomic)
                _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary, backupItemName: nil, options: [])
            }
        } catch {
            // A multi-file patch is one transaction: restore every entry if a
            // later atomic replacement fails.
            try? restore(checkpointID: checkpointID)
            throw error
        }
        return PatchResult(checkpointID: checkpointID, changedFiles: changes.map(\.path))
    }

    public func restore(checkpointID: UUID) throws {
        let url = checkpointDirectory.appendingPathComponent("\(checkpointID.uuidString).json")
        let checkpoint = try JSONDecoder().decode(Checkpoint.self, from: Data(contentsOf: url))
        for entry in checkpoint.entries {
            let target = try resolve(path: entry.path, allowMissingLeaf: true)
            if entry.existed, let encoded = entry.contentBase64, let data = Data(base64Encoded: encoded) {
                try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: target, options: .atomic)
            } else {
                try? FileManager.default.removeItem(at: target)
            }
        }
    }

    public func run(command: String, timeout: TimeInterval = 120) throws -> CommandOutput {
        let process = Process()
        let output = Pipe()
        let errors = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", command]
        process.currentDirectoryURL = root
        process.standardOutput = output
        process.standardError = errors
        process.environment = sanitizedEnvironment()

        let completion = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in completion.signal() }
        try process.run()
        if completion.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            _ = completion.wait(timeout: .now() + 2)
            throw WorkspaceToolError.commandTimedOut
        }
        let stdout = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return CommandOutput(command: command, stdout: stdout, stderr: stderr, exitCode: process.terminationStatus, risk: CommandPolicy.classify(command))
    }

    public func gitStatus() throws -> CommandOutput { try run(command: "git status --short --branch") }
    public func gitDiff() throws -> CommandOutput { try run(command: "git diff --no-ext-diff") }

    private func resolve(path: String, allowRoot: Bool = false, allowMissingLeaf: Bool = false) throws -> URL {
        guard !path.isEmpty else { throw WorkspaceToolError.outsideWorkspace }
        let candidate = root.appendingPathComponent(path).standardizedFileURL
        guard contains(candidate, root: root, allowRoot: allowRoot) else { throw WorkspaceToolError.outsideWorkspace }
        if FileManager.default.fileExists(atPath: candidate.path) {
            let resolved = candidate.resolvingSymlinksInPath().standardizedFileURL
            guard contains(resolved, root: root, allowRoot: allowRoot) else { throw WorkspaceToolError.outsideWorkspace }
            return resolved
        }
        if allowMissingLeaf {
            let parent = candidate.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL
            guard contains(parent, root: root, allowRoot: true) else { throw WorkspaceToolError.outsideWorkspace }
            return parent.appendingPathComponent(candidate.lastPathComponent)
        }
        throw CocoaError(.fileNoSuchFile)
    }

    private func contains(_ candidate: URL, root: URL, allowRoot: Bool) -> Bool {
        if allowRoot && candidate.path == root.path { return true }
        return candidate.path.hasPrefix(root.path.hasSuffix("/") ? root.path : root.path + "/")
    }

    private func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func appendTreeEntries(directory: URL, basePrefix: String, depth: Int, expanded: Set<String>, maxDepth: Int, maxEntries: Int, gitStatuses: [String: GitFileStatus], nodes: inout [WorkspaceFileNode]) throws {
        guard depth < maxDepth, nodes.count < maxEntries else { return }
        let entries = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
            .filter { !ignoredTreeName($0.lastPathComponent) }
            .sorted { left, right in
                let leftDirectory = (try? left.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                let rightDirectory = (try? right.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                if leftDirectory != rightDirectory { return leftDirectory && !rightDirectory }
                return left.lastPathComponent.localizedStandardCompare(right.lastPathComponent) == .orderedAscending
            }
        for entry in entries where nodes.count < maxEntries {
            let isDirectory = (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            let relativePath = basePrefix + entry.lastPathComponent
            let isExpanded = isDirectory && expanded.contains(relativePath)
            nodes.append(WorkspaceFileNode(path: relativePath, name: entry.lastPathComponent, isDirectory: isDirectory, depth: depth, gitStatus: gitStatuses[relativePath], isExpanded: isExpanded))
            if isExpanded {
                try appendTreeEntries(directory: entry, basePrefix: relativePath + "/", depth: depth + 1, expanded: expanded, maxDepth: maxDepth, maxEntries: maxEntries, gitStatuses: gitStatuses, nodes: &nodes)
            }
        }
    }

    private func ignoredTreeName(_ name: String) -> Bool {
        [".git", "node_modules", ".DS_Store"].contains(name)
    }

    private func normalizedRelativePath(_ path: String) -> String {
        let parts = path.split(separator: "/").filter { $0 != "." && !$0.isEmpty }
        return parts.isEmpty ? "." : parts.joined(separator: "/")
    }

    private func lineCount(_ content: String) -> Int {
        guard !content.isEmpty else { return 0 }
        var count = content.split(separator: "\n", omittingEmptySubsequences: false).count
        if content.hasSuffix("\n") { count -= 1 }
        return max(0, count)
    }

    private func sanitizedEnvironment() -> [String: String] {
        let allowed = ["PATH", "HOME", "LANG", "LC_ALL", "TERM", "TMPDIR"]
        return ProcessInfo.processInfo.environment.filter { allowed.contains($0.key) }
    }
}

public struct WorkspaceDirectoryEntry: Sendable, Equatable, Identifiable {
    public var id: String { name }
    public let name: String
    public let isDirectory: Bool
}

public struct WorkspaceMatch: Sendable, Equatable, Identifiable {
    public var id: String { "\(path):\(line)" }
    public let path: String
    public let line: Int
    public let text: String
}
