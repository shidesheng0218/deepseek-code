import Foundation

public struct SessionMigrationBackup: Codable, Equatable, Sendable {
    public let directory: URL
    public let createdAt: Date
    public let copiedItems: [String]

    public init(directory: URL, createdAt: Date, copiedItems: [String]) {
        self.directory = directory
        self.createdAt = createdAt
        self.copiedItems = copiedItems
    }
}

public enum SessionMigrationCoordinator {
    /// Creates one local backup before the first durable-event migration. A
    /// marker avoids repeatedly copying unchanged legacy storage at every app launch.
    public static func backupLegacyStorageIfNeeded(root: URL) throws -> SessionMigrationBackup? {
        let migrations = root.appendingPathComponent("Migrations", isDirectory: true)
        let marker = migrations.appendingPathComponent("durable-event-v1.backed-up")
        if FileManager.default.fileExists(atPath: marker.path) { return nil }
        try FileManager.default.createDirectory(at: migrations, withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let destination = migrations.appendingPathComponent("durable-event-v1-\(stamp)", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let candidates = ["Database/sessions.sqlite3", "LegacyEvents", "providers.json", "Extensions", "Plugins"]
        var copied: [String] = []
        for relative in candidates {
            let source = root.appendingPathComponent(relative)
            guard FileManager.default.fileExists(atPath: source.path) else { continue }
            let target = destination.appendingPathComponent(relative)
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: source, to: target)
            copied.append(relative)
        }
        let backup = SessionMigrationBackup(directory: destination, createdAt: Date(), copiedItems: copied)
        try JSONEncoder().encode(backup).write(to: destination.appendingPathComponent("manifest.json"), options: .atomic)
        try Data("1".utf8).write(to: marker, options: .atomic)
        return backup
    }
}
