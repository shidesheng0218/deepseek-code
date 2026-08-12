import Foundation

public struct SessionEvent: Codable, Equatable, Sendable {
    public let id: UUID
    public let sessionID: String
    public let sequence: Int
    public let timestamp: Date
    public let type: String
    public let payload: [String: String]

    public init(id: UUID = UUID(), sessionID: String = "", sequence: Int = 0, timestamp: Date = Date(), type: String, payload: [String: String]) {
        self.id = id
        self.sessionID = sessionID
        self.sequence = sequence
        self.timestamp = timestamp
        self.type = type
        self.payload = payload
    }
}
public final class EventStore: @unchecked Sendable {
    private let directory: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let lock = NSLock()

    public init(directory: URL) throws {
        self.directory = directory
        self.encoder = JSONEncoder()
        self.decoder = JSONDecoder()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    public func append(sessionID: String, event: SessionEvent) throws {
        lock.lock()
        defer { lock.unlock() }
        let existing = try loadUnlocked(sessionID: sessionID)
        let next = SessionEvent(id: event.id, sessionID: sessionID, sequence: existing.count + 1, timestamp: event.timestamp, type: event.type, payload: event.payload)
        let data = try encoder.encode(next)
        let url = fileURL(sessionID: sessionID)
        if !FileManager.default.fileExists(atPath: url.path) {
            try data.write(to: url, options: .atomic)
        } else {
            let handle = try FileHandle(forWritingTo: url)
            try handle.seekToEnd()
            try handle.write(contentsOf: Data([0x0A]) + data)
            try handle.close()
        }
    }

    public func load(sessionID: String) throws -> [SessionEvent] {
        lock.lock()
        defer { lock.unlock() }
        return try loadUnlocked(sessionID: sessionID)
    }

    private func loadUnlocked(sessionID: String) throws -> [SessionEvent] {
        let url = fileURL(sessionID: sessionID)
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let data = try Data(contentsOf: url)
        return try data.split(separator: 0x0A).map { try decoder.decode(SessionEvent.self, from: Data($0)) }
    }

    private func fileURL(sessionID: String) -> URL {
        directory.appendingPathComponent("\(safeFileName(sessionID)).jsonl")
    }

    private func safeFileName(_ value: String) -> String {
        value.replacingOccurrences(of: "[^A-Za-z0-9._-]", with: "_", options: .regularExpression)
    }
}
