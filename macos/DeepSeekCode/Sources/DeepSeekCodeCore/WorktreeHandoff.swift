import Foundation

public enum HandoffDestination: String, Codable, CaseIterable, Sendable {
    case local
    case existingBranch
    case patch
    case commit
}

public enum WorktreeState: String, Codable, CaseIterable, Sendable {
    case active
    case handedOff
    case needsAttention
    case removed
}

public struct WorktreeRecord: Codable, Equatable, Identifiable, Sendable {
    public var id: String { sessionID }
    public let sessionID: String
    public let baseRevision: String
    public let branch: String
    public let worktreePath: String
    public let createdAt: Date
    public var state: WorktreeState

    public init(sessionID: String, baseRevision: String, branch: String, worktreePath: String, createdAt: Date = Date(), state: WorktreeState = .active) {
        self.sessionID = sessionID
        self.baseRevision = baseRevision
        self.branch = branch
        self.worktreePath = worktreePath
        self.createdAt = createdAt
        self.state = state
    }
}

public enum HandoffState: String, Codable, CaseIterable, Sendable {
    case preview
    case awaitingResolution
    case applying
    case applied
    case aborted
    case indeterminate
}

public struct HandoffTransaction: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let sessionID: String
    public let destination: HandoffDestination
    public let baseRevision: String
    public var state: HandoffState
    public let createdAt: Date
    public var updatedAt: Date

    public init(
        id: String = UUID().uuidString,
        sessionID: String,
        destination: HandoffDestination,
        baseRevision: String,
        state: HandoffState = .preview,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.sessionID = sessionID
        self.destination = destination
        self.baseRevision = baseRevision
        self.state = state
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct HandoffConflict: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let path: String
    public let base: String
    public let current: String
    public let incoming: String

    public init(path: String, base: String, current: String, incoming: String) {
        self.id = "\(path):\(UUID().uuidString)"
        self.path = path
        self.base = base
        self.current = current
        self.incoming = incoming
    }
}

public struct HandoffPreview: Codable, Equatable, Sendable {
    public let files: [String: String]
    public let conflicts: [HandoffConflict]

    public init(files: [String: String], conflicts: [HandoffConflict]) {
        self.files = files
        self.conflicts = conflicts
    }

    public var isClean: Bool { conflicts.isEmpty }
}

public enum WorktreeHandoff {
    public static func merge(base: String, current: String, incoming: String, path: String = "app.txt") -> HandoffPreview {
        if current == incoming {
            return HandoffPreview(files: [path: current], conflicts: [])
        }
        if current == base {
            return HandoffPreview(files: [path: incoming], conflicts: [])
        }
        if incoming == base {
            return HandoffPreview(files: [path: current], conflicts: [])
        }

        let conflict = HandoffConflict(path: path, base: base, current: current, incoming: incoming)
        let merged = """
        <<<<<<< CURRENT
        \(current)
        ||||||| BASE
        \(base)
        =======
        \(incoming)
        >>>>>>> INCOMING
        """
        return HandoffPreview(files: [path: merged], conflicts: [conflict])
    }
}
