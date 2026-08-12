import Foundation

public struct SessionDeletionBackup: Codable, Equatable, Sendable {
    public let formatVersion: Int
    public let session: StoredSession
    public let project: ProjectRecord?
    public let events: [SessionEvent]
    public let taskContract: TaskContract?
    public let createdAt: Date

    public init(formatVersion: Int = 1, session: StoredSession, project: ProjectRecord? = nil, events: [SessionEvent], taskContract: TaskContract?, createdAt: Date = Date()) {
        self.formatVersion = formatVersion
        self.session = session
        self.project = project
        self.events = events
        self.taskContract = taskContract
        self.createdAt = createdAt
    }

    public var isValid: Bool {
        !session.id.isEmpty && !session.projectID.isEmpty && events.allSatisfy { $0.sessionID == session.id }
            && Set(events.map(\.sequence)).count == events.count
    }
}

public struct SessionDeletionReceipt: Codable, Equatable, Sendable {
    public let sessionID: String
    public let backupURL: URL
    public let eventCount: Int
    public let deletedAt: Date

    public init(sessionID: String, backupURL: URL, eventCount: Int, deletedAt: Date = Date()) {
        self.sessionID = sessionID
        self.backupURL = backupURL
        self.eventCount = eventCount
        self.deletedAt = deletedAt
    }
}

public enum SessionLifecycleError: LocalizedError, Sendable {
    case invalidBackup
    case activeSession
    case activeTerminal
    case projectMissing

    public var errorDescription: String? {
        switch self {
        case .invalidBackup: "Session 备份无效或与原 Session 不匹配"
        case .activeSession: "Session 仍在执行中，请先停止或等待执行结束"
        case .activeTerminal: "Session 仍有运行中的 Terminal，请先停止或 Detach 后再删除"
        case .projectMissing: "Session 所属项目不存在，无法恢复"
        }
    }
}
