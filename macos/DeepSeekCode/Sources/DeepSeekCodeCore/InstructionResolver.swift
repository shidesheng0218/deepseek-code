import Foundation

public struct InstructionSource: Codable, Equatable, Identifiable, Sendable {
    public var id: String { path }
    public let path: String
    public let scope: String
    public let text: String

    public init(path: String, scope: String, text: String) {
        self.path = path
        self.scope = scope
        self.text = text
    }
}

public struct ResolvedInstructions: Codable, Equatable, Sendable {
    public let text: String
    public let sources: [InstructionSource]

    public init(text: String, sources: [InstructionSource]) {
        self.text = text
        self.sources = sources
    }
}

public enum InstructionResolver {
    private static let cache = InstructionResolutionCache()

    public static func resolve(
        workspaceRoot: URL,
        workingDirectory: URL,
        userGlobalInstructions: String = ""
    ) throws -> ResolvedInstructions {
        let root = workspaceRoot.standardizedFileURL
        let working = workingDirectory.standardizedFileURL
        let files = instructionFiles(root: root, working: working)
        let cacheKey = cacheKey(root: root, working: working, userGlobalInstructions: userGlobalInstructions, files: files)
        if let cached = cache.value(for: cacheKey) { return cached }
        var sources: [InstructionSource] = []

        let global = userGlobalInstructions.trimmingCharacters(in: .whitespacesAndNewlines)
        if !global.isEmpty {
            sources.append(InstructionSource(path: "global", scope: "user", text: global))
        }

        let projectInstructions = root.appendingPathComponent(".deepseek/instructions.md")
        if let text = try? String(contentsOf: projectInstructions, encoding: .utf8) {
            sources.append(InstructionSource(path: ".deepseek/instructions.md", scope: "project", text: text))
        }

        for directory in instructionDirectories(root: root, working: working) {
            for name in ["CLAUDE.md", "AGENTS.md"] {
                let instructionURL = directory.appendingPathComponent(name)
                guard let text = try? String(contentsOf: instructionURL, encoding: .utf8) else { continue }
                let relative = instructionURL.path.replacingOccurrences(of: root.path + "/", with: "")
                sources.append(InstructionSource(path: relative, scope: directory == root ? "project" : "directory", text: text))
            }
        }

        let resolved = ResolvedInstructions(
            text: sources.map(\.text).joined(separator: "\n\n"),
            sources: sources
        )
        cache.insert(resolved, for: cacheKey)
        return resolved
    }

    private static func instructionDirectories(root: URL, working: URL) -> [URL] {
        let relativeWorkingPath = working.path.replacingOccurrences(of: root.path, with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let components = relativeWorkingPath.isEmpty ? [] : relativeWorkingPath.split(separator: "/").map(String.init)
        var directories: [URL] = [root]
        var cursor = root
        for component in components {
            cursor = cursor.appendingPathComponent(component, isDirectory: true)
            directories.append(cursor)
        }
        return directories
    }

    private static func instructionFiles(root: URL, working: URL) -> [URL] {
        [root.appendingPathComponent(".deepseek/instructions.md")] + instructionDirectories(root: root, working: working).flatMap { directory in
            [directory.appendingPathComponent("CLAUDE.md"), directory.appendingPathComponent("AGENTS.md")]
        }
    }

    private static func cacheKey(root: URL, working: URL, userGlobalInstructions: String, files: [URL]) -> String {
        let fileFingerprint = files.map { url -> String in
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else {
                return "\(url.path)|missing"
            }
            let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            let size = (attributes[.size] as? NSNumber)?.intValue ?? 0
            return "\(url.path)|\(modified)|\(size)"
        }.joined(separator: "|")
        return [root.path, working.path, userGlobalInstructions, fileFingerprint].joined(separator: "\u{1F}")
    }
}

private final class InstructionResolutionCache: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: ResolvedInstructions] = [:]

    func value(for key: String) -> ResolvedInstructions? {
        lock.lock()
        defer { lock.unlock() }
        return values[key]
    }

    func insert(_ value: ResolvedInstructions, for key: String) {
        lock.lock()
        if values.count >= 32, let oldestKey = values.keys.first {
            values.removeValue(forKey: oldestKey)
        }
        values[key] = value
        lock.unlock()
    }
}
