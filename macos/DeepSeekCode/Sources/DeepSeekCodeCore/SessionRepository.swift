import Foundation
import SQLite3

public struct ProjectRecord: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public var name: String
    public var path: String
    public let createdAt: Date
    public var updatedAt: Date

    public init(id: String = UUID().uuidString, name: String, path: String, createdAt: Date = Date(), updatedAt: Date = Date()) {
        self.id = id
        self.name = name
        self.path = path
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct StoredSession: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let projectID: String
    public var title: String
    public var mode: AgentMode
    public var target: SessionTarget
    public var branch: String
    public var worktreePath: String?
    public var baselineRevision: String?
    public var status: SessionStatus
    public var archived: Bool
    public let createdAt: Date
    public var updatedAt: Date

    public init(id: String = UUID().uuidString, projectID: String, title: String, mode: AgentMode, target: SessionTarget = .local, branch: String = "", worktreePath: String? = nil, baselineRevision: String? = nil, status: SessionStatus = .waiting, archived: Bool = false, createdAt: Date = Date(), updatedAt: Date = Date()) {
        self.id = id
        self.projectID = projectID
        self.title = title
        self.mode = mode
        self.target = target
        self.branch = branch
        self.worktreePath = worktreePath
        self.baselineRevision = baselineRevision
        self.status = status
        self.archived = archived
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public enum ApprovalDecision: String, Codable, Sendable {
    case pending
    case allowOnce = "allow_once"
    case allowSession = "allow_session"
    case deny
}

public struct ApprovalRecord: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let sessionID: String
    public let tool: String
    public let risk: CommandRisk
    public let arguments: String
    public var decision: ApprovalDecision
    public let createdAt: Date
    public var resolvedAt: Date?

    public init(id: String = UUID().uuidString, sessionID: String, tool: String, risk: CommandRisk, arguments: String, decision: ApprovalDecision = .pending, createdAt: Date = Date(), resolvedAt: Date? = nil) {
        self.id = id
        self.sessionID = sessionID
        self.tool = tool
        self.risk = risk
        self.arguments = arguments
        self.decision = decision
        self.createdAt = createdAt
        self.resolvedAt = resolvedAt
    }
}

public struct PersistedExtensionRecord: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let kind: String
    public let sessionID: String?
    public let payload: [String: String]
    public let createdAt: Date

    public init(id: String = UUID().uuidString, kind: String, sessionID: String? = nil, payload: [String: String], createdAt: Date = Date()) {
        self.id = id
        self.kind = kind
        self.sessionID = sessionID
        self.payload = payload
        self.createdAt = createdAt
    }
}

public struct ProjectedSessionState: Codable, Equatable, Sendable {
    public var session: StoredSession
    public var pendingApprovalID: String?
    public var usage: UsageSummary

    public init(session: StoredSession, pendingApprovalID: String? = nil, usage: UsageSummary = UsageSummary()) {
        self.session = session
        self.pendingApprovalID = pendingApprovalID
        self.usage = usage
    }
}

public enum SessionProjector {
    public static func project(session: StoredSession, events: [SessionEvent]) throws -> ProjectedSessionState {
        var result = ProjectedSessionState(session: session)
        for event in events.sorted(by: { $0.sequence < $1.sequence }) {
            switch event.type {
            case "session_status_changed":
                if let value = event.payload["status"], let status = SessionStatus(rawValue: value) {
                    result.session.status = status
                }
            case "approval_requested":
                result.pendingApprovalID = event.payload["approvalID"]
                result.session.status = .awaitingToolApproval
            case "approval_resolved":
                if result.pendingApprovalID == event.payload["approvalID"] {
                    result.pendingApprovalID = nil
                    if event.payload["decision"] == ApprovalDecision.deny.rawValue {
                        result.session.status = .waiting
                    } else {
                        result.session.status = .running
                    }
                }
            case "usage_recorded":
                let input = Int(event.payload["input"] ?? "0") ?? 0
                let cached = Int(event.payload["cached_input"] ?? "0") ?? 0
                let output = Int(event.payload["output"] ?? "0") ?? 0
                result.usage = UsageSummary(inputTokens: result.usage.inputTokens + input, cachedInputTokens: result.usage.cachedInputTokens + cached, outputTokens: result.usage.outputTokens + output, estimatedCost: result.usage.estimatedCost)
            default:
                continue
            }
        }
        return result
    }
}

public final class SessionRepository: @unchecked Sendable {
    private let database: OpaquePointer
    private let lock = NSLock()
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private var eventObservers: [UUID: @Sendable (SessionEvent) -> Void] = [:]

    public init(directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var handle: OpaquePointer?
        let path = directory.appendingPathComponent("sessions.sqlite3").path
        guard sqlite3_open_v2(path, &handle, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK, let handle else {
            throw RepositoryError.openFailed
        }
        database = handle
        do {
            try execute("PRAGMA foreign_keys = ON;")
            try executeScript("""
                CREATE TABLE IF NOT EXISTS projects (
                    id TEXT PRIMARY KEY,
                    name TEXT NOT NULL,
                    path TEXT NOT NULL,
                    created_at REAL NOT NULL,
                    updated_at REAL NOT NULL
                );
                CREATE TABLE IF NOT EXISTS sessions (
                    id TEXT PRIMARY KEY,
                    project_id TEXT NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
                    title TEXT NOT NULL,
                    mode TEXT NOT NULL,
                    target TEXT NOT NULL DEFAULT 'local',
                    branch TEXT NOT NULL DEFAULT '',
                    worktree_path TEXT,
                    baseline_revision TEXT,
                    status TEXT NOT NULL,
                    archived INTEGER NOT NULL DEFAULT 0,
                    created_at REAL NOT NULL,
                    updated_at REAL NOT NULL
                );
                CREATE TABLE IF NOT EXISTS task_contracts (
                    session_id TEXT PRIMARY KEY REFERENCES sessions(id) ON DELETE CASCADE,
                    payload TEXT NOT NULL,
                    updated_at REAL NOT NULL
                );
                CREATE TABLE IF NOT EXISTS session_events (
                    session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
                    sequence INTEGER NOT NULL,
                    event_id TEXT NOT NULL,
                    type TEXT NOT NULL,
                    payload TEXT NOT NULL,
                    timestamp REAL NOT NULL,
                    PRIMARY KEY (session_id, sequence)
                );
                CREATE TABLE IF NOT EXISTS session_event_log (
                    aggregate_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
                    sequence INTEGER NOT NULL,
                    event_id TEXT NOT NULL UNIQUE,
                    command_id TEXT NOT NULL,
                    causation_id TEXT,
                    correlation_id TEXT,
                    type TEXT NOT NULL,
                    payload TEXT NOT NULL,
                    timestamp REAL NOT NULL,
                    schema_version INTEGER NOT NULL DEFAULT 1,
                    PRIMARY KEY (aggregate_id, sequence)
                );
                CREATE INDEX IF NOT EXISTS session_event_log_command_idx ON session_event_log(command_id);
                CREATE TABLE IF NOT EXISTS session_projection (
                    session_id TEXT PRIMARY KEY REFERENCES sessions(id) ON DELETE CASCADE,
                    cursor_sequence INTEGER NOT NULL,
                    payload TEXT NOT NULL,
                    updated_at REAL NOT NULL
                );
                CREATE TABLE IF NOT EXISTS session_parts (
                    session_id TEXT PRIMARY KEY REFERENCES sessions(id) ON DELETE CASCADE,
                    cursor_sequence INTEGER NOT NULL,
                    payload TEXT NOT NULL,
                    updated_at REAL NOT NULL
                );
                CREATE TABLE IF NOT EXISTS session_input_inbox (
                    id TEXT PRIMARY KEY,
                    session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
                    idempotency_key TEXT NOT NULL UNIQUE,
                    admitted_sequence INTEGER NOT NULL,
                    delivery TEXT NOT NULL,
                    state TEXT NOT NULL,
                    payload TEXT NOT NULL,
                    created_at REAL NOT NULL,
                    updated_at REAL NOT NULL
                );
                CREATE INDEX IF NOT EXISTS session_input_pending_idx ON session_input_inbox(session_id, state, admitted_sequence);
                CREATE TABLE IF NOT EXISTS session_leases (
                    session_id TEXT PRIMARY KEY REFERENCES sessions(id) ON DELETE CASCADE,
                    owner_instance_id TEXT NOT NULL,
                    heartbeat REAL NOT NULL,
                    expires_at REAL NOT NULL
                );
                CREATE TABLE IF NOT EXISTS approvals (
                    id TEXT PRIMARY KEY,
                    session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
                    tool TEXT NOT NULL,
                    risk INTEGER NOT NULL,
                    arguments TEXT NOT NULL,
                    decision TEXT NOT NULL,
                    created_at REAL NOT NULL,
                    resolved_at REAL
                );
                CREATE TABLE IF NOT EXISTS permission_leases (
                    id TEXT PRIMARY KEY,
                    project_id TEXT NOT NULL DEFAULT '',
                    session_id TEXT NOT NULL DEFAULT '',
                    effect TEXT NOT NULL,
                    tool_name TEXT NOT NULL,
                    payload TEXT NOT NULL,
                    expires_at REAL NOT NULL,
                    revoked_at REAL,
                    UNIQUE(project_id, session_id, effect, tool_name)
                );
                CREATE TABLE IF NOT EXISTS agent_runs (
                    session_id TEXT PRIMARY KEY REFERENCES sessions(id) ON DELETE CASCADE,
                    state TEXT NOT NULL,
                    updated_at REAL NOT NULL
                );
                CREATE TABLE IF NOT EXISTS agent_workers (
                    id TEXT PRIMARY KEY,
                    session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
                    state TEXT NOT NULL,
                    payload TEXT NOT NULL,
                    updated_at REAL NOT NULL
                );
                CREATE TABLE IF NOT EXISTS worker_sessions (
                    id TEXT PRIMARY KEY,
                    parent_session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
                    worker_id TEXT NOT NULL UNIQUE,
                    state TEXT NOT NULL,
                    cursor_sequence INTEGER NOT NULL,
                    payload TEXT NOT NULL,
                    created_at REAL NOT NULL,
                    updated_at REAL NOT NULL
                );
                CREATE INDEX IF NOT EXISTS worker_sessions_parent_idx ON worker_sessions(parent_session_id, updated_at);
                CREATE TABLE IF NOT EXISTS handoffs (
                    id TEXT PRIMARY KEY,
                    session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
                    destination TEXT NOT NULL,
                    base_revision TEXT NOT NULL,
                    state TEXT NOT NULL,
                    created_at REAL NOT NULL,
                    updated_at REAL NOT NULL
                );
                CREATE TABLE IF NOT EXISTS worktrees (
                    session_id TEXT PRIMARY KEY REFERENCES sessions(id) ON DELETE CASCADE,
                    base_revision TEXT NOT NULL,
                    branch TEXT NOT NULL,
                    worktree_path TEXT NOT NULL,
                    state TEXT NOT NULL,
                    created_at REAL NOT NULL,
                    updated_at REAL NOT NULL
                );
                CREATE TABLE IF NOT EXISTS handoff_files (
                    handoff_id TEXT NOT NULL REFERENCES handoffs(id) ON DELETE CASCADE,
                    path TEXT NOT NULL,
                    state TEXT NOT NULL,
                    local_hash TEXT,
                    incoming_hash TEXT,
                    payload TEXT NOT NULL,
                    PRIMARY KEY (handoff_id, path)
                );
                CREATE TABLE IF NOT EXISTS mcp_servers (id TEXT PRIMARY KEY, payload TEXT NOT NULL, updated_at REAL NOT NULL);
                CREATE TABLE IF NOT EXISTS mcp_tools (id TEXT PRIMARY KEY, server_id TEXT NOT NULL, payload TEXT NOT NULL, updated_at REAL NOT NULL);
                CREATE TABLE IF NOT EXISTS skills (id TEXT PRIMARY KEY, payload TEXT NOT NULL, updated_at REAL NOT NULL);
                CREATE TABLE IF NOT EXISTS hooks (id TEXT PRIMARY KEY, payload TEXT NOT NULL, updated_at REAL NOT NULL);
                CREATE TABLE IF NOT EXISTS scheduled_tasks (id TEXT PRIMARY KEY, payload TEXT NOT NULL, updated_at REAL NOT NULL);
                CREATE TABLE IF NOT EXISTS scheduled_runs (id TEXT PRIMARY KEY, task_id TEXT NOT NULL, payload TEXT NOT NULL, updated_at REAL NOT NULL);
                CREATE TABLE IF NOT EXISTS ssh_hosts (id TEXT PRIMARY KEY, payload TEXT NOT NULL, updated_at REAL NOT NULL);
                CREATE TABLE IF NOT EXISTS ssh_installations (id TEXT PRIMARY KEY, host_id TEXT NOT NULL, payload TEXT NOT NULL, updated_at REAL NOT NULL);
                CREATE TABLE IF NOT EXISTS github_deliveries (id TEXT PRIMARY KEY, session_id TEXT NOT NULL, payload TEXT NOT NULL, updated_at REAL NOT NULL);
                CREATE TABLE IF NOT EXISTS tool_invocations (id TEXT PRIMARY KEY, session_id TEXT NOT NULL, tool TEXT NOT NULL, phase TEXT NOT NULL, risk INTEGER NOT NULL, succeeded INTEGER, payload TEXT NOT NULL, created_at REAL NOT NULL);
                CREATE TABLE IF NOT EXISTS usage_records (id TEXT PRIMARY KEY, session_id TEXT, payload TEXT NOT NULL, created_at REAL NOT NULL);
                CREATE TABLE IF NOT EXISTS network_grants (id TEXT PRIMARY KEY, domain TEXT NOT NULL, capability TEXT NOT NULL, operation TEXT NOT NULL, grant_scope TEXT NOT NULL, session_id TEXT, project_id TEXT, payload TEXT NOT NULL, created_at REAL NOT NULL, expires_at REAL, consumed_at REAL);
                CREATE TABLE IF NOT EXISTS network_requests (id TEXT PRIMARY KEY, session_id TEXT, capability TEXT NOT NULL, operation TEXT NOT NULL, state TEXT NOT NULL, status_code INTEGER, request_bytes INTEGER NOT NULL, response_bytes INTEGER NOT NULL, payload TEXT NOT NULL, created_at REAL NOT NULL, updated_at REAL NOT NULL);
                CREATE TABLE IF NOT EXISTS web_cache (id TEXT PRIMARY KEY, session_id TEXT, project_id TEXT, request_key TEXT NOT NULL, scope TEXT NOT NULL, purpose TEXT, payload TEXT NOT NULL, created_at REAL NOT NULL, expires_at REAL NOT NULL);
                CREATE TABLE IF NOT EXISTS terminal_sessions (
                    id TEXT PRIMARY KEY,
                    session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
                    state TEXT NOT NULL,
                    payload TEXT NOT NULL,
                    updated_at REAL NOT NULL
                );
                CREATE TABLE IF NOT EXISTS terminal_events (
                    id TEXT PRIMARY KEY,
                    terminal_id TEXT NOT NULL REFERENCES terminal_sessions(id) ON DELETE CASCADE,
                    session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
                    kind TEXT NOT NULL,
                    payload TEXT NOT NULL,
                    created_at REAL NOT NULL
                );
                CREATE TABLE IF NOT EXISTS terminal_processes (
                    terminal_id TEXT PRIMARY KEY REFERENCES terminal_sessions(id) ON DELETE CASCADE,
                    pid INTEGER,
                    process_group INTEGER,
                    command_hash TEXT,
                    cwd TEXT,
                    updated_at REAL NOT NULL
                );
                CREATE TABLE IF NOT EXISTS terminal_ports (
                    id TEXT PRIMARY KEY,
                    terminal_id TEXT NOT NULL REFERENCES terminal_sessions(id) ON DELETE CASCADE,
                    port INTEGER NOT NULL,
                    host TEXT NOT NULL,
                    payload TEXT NOT NULL,
                    discovered_at REAL NOT NULL
                );
                CREATE TABLE IF NOT EXISTS terminal_command_history (
                    id TEXT PRIMARY KEY,
                    session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
                    terminal_id TEXT NOT NULL REFERENCES terminal_sessions(id) ON DELETE CASCADE,
                    command TEXT,
                    command_hash TEXT NOT NULL,
                    risk INTEGER NOT NULL,
                    created_at REAL NOT NULL
                );
                """)
            try migrateLegacySessionEvents()
            try ensureSessionColumns()
        } catch {
            sqlite3_close(database)
            throw error
        }
    }

    deinit { sqlite3_close(database) }

    public func createProject(name: String, path: String) throws -> ProjectRecord {
        let project = ProjectRecord(name: name, path: path)
        try withLock {
            try execute("INSERT INTO projects (id, name, path, created_at, updated_at) VALUES (?, ?, ?, ?, ?);", values: [project.id, project.name, project.path, project.createdAt.timeIntervalSince1970, project.updatedAt.timeIntervalSince1970])
        }
        return project
    }

    public func projects() throws -> [ProjectRecord] {
        try withLock {
            try query("SELECT id, name, path, created_at, updated_at FROM projects ORDER BY updated_at DESC;") { statement in
                ProjectRecord(id: statement.string(0), name: statement.string(1), path: statement.string(2), createdAt: Date(timeIntervalSince1970: statement.double(3)), updatedAt: Date(timeIntervalSince1970: statement.double(4)))
            }
        }
    }

    public func project(path: String) throws -> ProjectRecord? {
        try withLock {
            try query("SELECT id, name, path, created_at, updated_at FROM projects WHERE path = ? LIMIT 1;", values: [path]) { statement in
                ProjectRecord(id: statement.string(0), name: statement.string(1), path: statement.string(2), createdAt: Date(timeIntervalSince1970: statement.double(3)), updatedAt: Date(timeIntervalSince1970: statement.double(4)))
            }.first
        }
    }

    public func project(id: String) throws -> ProjectRecord? {
        try withLock {
            try query("SELECT id, name, path, created_at, updated_at FROM projects WHERE id = ? LIMIT 1;", values: [id]) { statement in
                ProjectRecord(id: statement.string(0), name: statement.string(1), path: statement.string(2), createdAt: Date(timeIntervalSince1970: statement.double(3)), updatedAt: Date(timeIntervalSince1970: statement.double(4)))
            }.first
        }
    }

    @discardableResult
    public func importProject(_ project: ProjectRecord) throws -> Bool {
        try withLock {
            let existing = try query("SELECT 1 FROM projects WHERE id = ? LIMIT 1;", values: [project.id], map: { _ in true })
            guard existing.isEmpty else { return false }
            try execute("INSERT INTO projects (id, name, path, created_at, updated_at) VALUES (?, ?, ?, ?, ?);", values: [project.id, project.name, project.path, project.createdAt.timeIntervalSince1970, project.updatedAt.timeIntervalSince1970])
            return true
        }
    }

    public func createSession(projectID: String, title: String, mode: AgentMode, target: SessionTarget = .local, branch: String = "", worktreePath: String? = nil, baselineRevision: String? = nil) throws -> StoredSession {
        let session = StoredSession(projectID: projectID, title: title, mode: mode, target: target, branch: branch, worktreePath: worktreePath, baselineRevision: baselineRevision)
        try withLock {
            try execute("INSERT INTO sessions (id, project_id, title, mode, target, branch, worktree_path, baseline_revision, status, archived, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);", values: [session.id, session.projectID, session.title, session.mode.rawValue, session.target.rawValue, session.branch, session.worktreePath as Any, session.baselineRevision as Any, session.status.rawValue, session.archived ? 1 : 0, session.createdAt.timeIntervalSince1970, session.updatedAt.timeIntervalSince1970])
        }
        return session
    }

    public func updateWorktreeBinding(sessionID: String, branch: String, worktreePath: String, baselineRevision: String) throws {
        let now = Date().timeIntervalSince1970
        try withLock {
            try execute(
                "UPDATE sessions SET target = ?, branch = ?, worktree_path = ?, baseline_revision = ?, updated_at = ? WHERE id = ?;",
                values: [SessionTarget.worktree.rawValue, branch, worktreePath, baselineRevision, now, sessionID]
            )
        }
    }

    public func saveTaskContract(_ contract: TaskContract, sessionID: String) throws {
        let payload = String(decoding: try encoder.encode(contract), as: UTF8.self)
        try withLock {
            try execute(
                "INSERT OR REPLACE INTO task_contracts (session_id, payload, updated_at) VALUES (?, ?, ?);",
                values: [sessionID, payload, Date().timeIntervalSince1970]
            )
        }
    }

    public func taskContract(sessionID: String) throws -> TaskContract? {
        try withLock {
            try query("SELECT payload FROM task_contracts WHERE session_id = ? LIMIT 1;", values: [sessionID]) { statement in
                try? decoder.decode(TaskContract.self, from: Data(statement.string(0).utf8))
            }.compactMap { $0 }.first
        }
    }

    @discardableResult
    public func importSession(_ session: StoredSession) throws -> Bool {
        try withLock {
            let existing = try query("SELECT 1 FROM sessions WHERE id = ? LIMIT 1;", values: [session.id], map: { _ in true })
            guard existing.isEmpty else { return false }
            try execute("INSERT INTO sessions (id, project_id, title, mode, target, branch, worktree_path, baseline_revision, status, archived, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);", values: [session.id, session.projectID, session.title, session.mode.rawValue, session.target.rawValue, session.branch, session.worktreePath as Any, session.baselineRevision as Any, session.status.rawValue, session.archived ? 1 : 0, session.createdAt.timeIntervalSince1970, session.updatedAt.timeIntervalSince1970])
            return true
        }
    }

    public func sessions(projectID: String? = nil, includeArchived: Bool = false) throws -> [StoredSession] {
        try withLock {
            var sql = "SELECT id, project_id, title, mode, target, branch, worktree_path, baseline_revision, status, archived, created_at, updated_at FROM sessions"
            var values: [Any] = []
            var clauses: [String] = []
            if let projectID { clauses.append("project_id = ?"); values.append(projectID) }
            if !includeArchived { clauses.append("archived = 0") }
            if !clauses.isEmpty { sql += " WHERE " + clauses.joined(separator: " AND ") }
            sql += " ORDER BY updated_at DESC;"
            return try query(sql, values: values) { statement in
                StoredSession(id: statement.string(0), projectID: statement.string(1), title: statement.string(2), mode: AgentMode(rawValue: statement.string(3)) ?? .acceptEdits, target: SessionTarget(rawValue: statement.string(4)) ?? .local, branch: statement.string(5), worktreePath: statement.stringOrNil(6), baselineRevision: statement.stringOrNil(7), status: SessionStatus(rawValue: statement.string(8)) ?? .waiting, archived: statement.int(9) != 0, createdAt: Date(timeIntervalSince1970: statement.double(10)), updatedAt: Date(timeIntervalSince1970: statement.double(11)))
            }
        }
    }

    public func session(id: String) throws -> StoredSession? {
        try withLock {
            try query("SELECT id, project_id, title, mode, target, branch, worktree_path, baseline_revision, status, archived, created_at, updated_at FROM sessions WHERE id = ? LIMIT 1;", values: [id]) { statement in
                StoredSession(id: statement.string(0), projectID: statement.string(1), title: statement.string(2), mode: AgentMode(rawValue: statement.string(3)) ?? .acceptEdits, target: SessionTarget(rawValue: statement.string(4)) ?? .local, branch: statement.string(5), worktreePath: statement.stringOrNil(6), baselineRevision: statement.stringOrNil(7), status: SessionStatus(rawValue: statement.string(8)) ?? .waiting, archived: statement.int(9) != 0, createdAt: Date(timeIntervalSince1970: statement.double(10)), updatedAt: Date(timeIntervalSince1970: statement.double(11)))
            }.first
        }
    }

    public func createHandoff(sessionID: String, destination: HandoffDestination, baseRevision: String) throws -> HandoffTransaction {
        let transaction = HandoffTransaction(sessionID: sessionID, destination: destination, baseRevision: baseRevision)
        try withLock {
            try execute(
                "INSERT INTO handoffs (id, session_id, destination, base_revision, state, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?);",
                values: [
                    transaction.id,
                    transaction.sessionID,
                    transaction.destination.rawValue,
                    transaction.baseRevision,
                    transaction.state.rawValue,
                    transaction.createdAt.timeIntervalSince1970,
                    transaction.updatedAt.timeIntervalSince1970
                ]
            )
        }
        return transaction
    }

    public func saveWorktree(_ record: WorktreeRecord) throws {
        try withLock {
            try execute("INSERT OR REPLACE INTO worktrees (session_id, base_revision, branch, worktree_path, state, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?);", values: [record.sessionID, record.baseRevision, record.branch, record.worktreePath, record.state.rawValue, record.createdAt.timeIntervalSince1970, Date().timeIntervalSince1970])
        }
    }

    public func worktree(sessionID: String) throws -> WorktreeRecord? {
        try withLock {
            try query("SELECT session_id, base_revision, branch, worktree_path, state, created_at FROM worktrees WHERE session_id = ? LIMIT 1;", values: [sessionID]) { statement in
                WorktreeRecord(sessionID: statement.string(0), baseRevision: statement.string(1), branch: statement.string(2), worktreePath: statement.string(3), createdAt: Date(timeIntervalSince1970: statement.double(5)), state: WorktreeState(rawValue: statement.string(4)) ?? .needsAttention)
            }.first
        }
    }

    public func saveHandoffFiles(handoffID: String, files: [HandoffFileState]) throws {
        try withLock {
            for file in files {
                let payload = String(decoding: try encoder.encode(file), as: UTF8.self)
                try execute("INSERT OR REPLACE INTO handoff_files (handoff_id, path, state, local_hash, incoming_hash, payload) VALUES (?, ?, ?, ?, ?, ?);", values: [handoffID, file.path, file.state.rawValue, file.localHash as Any, file.incomingHash as Any, payload])
            }
        }
    }

    public func handoffFiles(handoffID: String) throws -> [HandoffFileState] {
        try withLock {
            try query("SELECT payload FROM handoff_files WHERE handoff_id = ? ORDER BY path ASC;", values: [handoffID]) { statement in
                try? decoder.decode(HandoffFileState.self, from: Data(statement.string(0).utf8))
            }.compactMap { $0 }
        }
    }

    public func handoff(id: String) throws -> HandoffTransaction? {
        try withLock {
            try query(
                "SELECT id, session_id, destination, base_revision, state, created_at, updated_at FROM handoffs WHERE id = ? LIMIT 1;",
                values: [id]
            ) { statement in
                HandoffTransaction(
                    id: statement.string(0),
                    sessionID: statement.string(1),
                    destination: HandoffDestination(rawValue: statement.string(2)) ?? .local,
                    baseRevision: statement.string(3),
                    state: HandoffState(rawValue: statement.string(4)) ?? .indeterminate,
                    createdAt: Date(timeIntervalSince1970: statement.double(5)),
                    updatedAt: Date(timeIntervalSince1970: statement.double(6))
                )
            }.first
        }
    }

    public func updateHandoff(id: String, state: HandoffState) throws {
        try withLock {
            try execute(
                "UPDATE handoffs SET state = ?, updated_at = ? WHERE id = ?;",
                values: [state.rawValue, Date().timeIntervalSince1970, id]
            )
        }
    }

    public func recordToolInvocation(_ invocation: ToolInvocationRecord, payload: [String: String] = [:]) throws {
        let encoded = String(decoding: try encoder.encode(payload), as: UTF8.self)
        try withLock {
            try execute(
                "INSERT OR REPLACE INTO tool_invocations (id, session_id, tool, phase, risk, succeeded, payload, created_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?);",
                values: [invocation.id, invocation.sessionID, invocation.tool, invocation.phase.rawValue, invocation.risk.rawValue, invocation.succeeded.map { $0 ? 1 : 0 } as Any, encoded, invocation.createdAt.timeIntervalSince1970]
            )
        }
    }

    public func toolInvocations(sessionID: String) throws -> [ToolInvocationRecord] {
        try withLock {
            try query(
                "SELECT id, session_id, tool, phase, risk, succeeded, created_at FROM tool_invocations WHERE session_id = ? ORDER BY created_at ASC;",
                values: [sessionID]
            ) { statement in
                ToolInvocationRecord(
                    id: statement.string(0),
                    sessionID: statement.string(1),
                    tool: statement.string(2),
                    phase: ToolInvocationPhase(rawValue: statement.string(3)) ?? .failed,
                    risk: CommandRisk(rawValue: statement.int(4)) ?? .l4,
                    succeeded: statement.isNull(5) ? nil : statement.int(5) != 0,
                    createdAt: Date(timeIntervalSince1970: statement.double(6))
                )
            }
        }
    }

    public func saveNetworkGrant(_ grant: NetworkGrant) throws {
        let payload = String(decoding: try encoder.encode(grant), as: UTF8.self)
        try withLock {
            try execute(
                "INSERT OR REPLACE INTO network_grants (id, domain, capability, operation, grant_scope, session_id, project_id, payload, created_at, expires_at, consumed_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);",
                values: [
                    grant.id,
                    grant.domain,
                    grant.capability.rawValue,
                    grant.operation.rawValue,
                    grant.scope.rawValue,
                    grant.sessionID as Any,
                    grant.projectID as Any,
                    payload,
                    grant.createdAt.timeIntervalSince1970,
                    grant.expiresAt?.timeIntervalSince1970 as Any,
                    grant.consumedAt?.timeIntervalSince1970 as Any
                ]
            )
        }
    }

    public func networkGrants() throws -> [NetworkGrant] {
        try withLock {
            try query("SELECT payload FROM network_grants ORDER BY created_at DESC;") { statement in
                try? decoder.decode(NetworkGrant.self, from: Data(statement.string(0).utf8))
            }.compactMap { $0 }
        }
    }

    public func deleteNetworkGrant(id: String) throws {
        try withLock {
            try execute("DELETE FROM network_grants WHERE id = ?;", values: [id])
        }
    }

    public func recordNetworkRequest(_ record: NetworkRequestRecord) throws {
        let payload = String(decoding: try encoder.encode(record), as: UTF8.self)
        try withLock {
            try execute(
                "INSERT OR REPLACE INTO network_requests (id, session_id, capability, operation, state, status_code, request_bytes, response_bytes, payload, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);",
                values: [
                    record.id,
                    record.metadata.sessionID as Any,
                    record.metadata.capability.rawValue,
                    record.metadata.operation.rawValue,
                    record.state.rawValue,
                    record.statusCode as Any,
                    record.requestBytes,
                    record.responseBytes,
                    payload,
                    record.createdAt.timeIntervalSince1970,
                    record.updatedAt.timeIntervalSince1970
                ]
            )
        }
    }

    public func networkRequests(sessionID: String? = nil) throws -> [NetworkRequestRecord] {
        try withLock {
            if let sessionID {
                return try query("SELECT payload FROM network_requests WHERE session_id = ? ORDER BY created_at ASC;", values: [sessionID]) { statement in
                    try? decoder.decode(NetworkRequestRecord.self, from: Data(statement.string(0).utf8))
                }.compactMap { $0 }
            }
            return try query("SELECT payload FROM network_requests ORDER BY created_at ASC;") { statement in
                try? decoder.decode(NetworkRequestRecord.self, from: Data(statement.string(0).utf8))
            }.compactMap { $0 }
        }
    }

    public func saveWebCache(_ entry: WebCacheEntry) throws {
        let payload = String(decoding: try encoder.encode(entry), as: UTF8.self)
        try withLock {
            try execute(
                "INSERT OR REPLACE INTO web_cache (id, session_id, project_id, request_key, scope, purpose, payload, created_at, expires_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?);",
                values: [
                    entry.id,
                    entry.sessionID as Any,
                    entry.projectID as Any,
                    entry.requestKey,
                    entry.scope.rawValue,
                    entry.purpose?.rawValue as Any,
                    payload,
                    entry.createdAt.timeIntervalSince1970,
                    entry.expiresAt.timeIntervalSince1970
                ]
            )
        }
    }

    public func webCacheEntry(sessionID: String?, projectID: String?, requestKey: String, now: Date = Date()) throws -> WebCacheEntry? {
        try withLock {
            var sql = "SELECT payload FROM web_cache WHERE request_key = ? AND expires_at > ?"
            var values: [Any] = [requestKey, now.timeIntervalSince1970]
            if let sessionID {
                sql += " AND session_id = ?"
                values.append(sessionID)
            } else {
                sql += " AND session_id IS NULL"
            }
            if let projectID {
                sql += " AND project_id = ?"
                values.append(projectID)
            } else {
                sql += " AND project_id IS NULL"
            }
            sql += " ORDER BY created_at DESC LIMIT 1;"
            return try query(sql, values: values) { statement in
                try? decoder.decode(WebCacheEntry.self, from: Data(statement.string(0).utf8))
            }.compactMap { $0 }.first
        }
    }

    public func saveExtensionRecord(_ record: PersistedExtensionRecord, table: String) throws {
        let allowed = Set(["mcp_servers", "mcp_tools", "skills", "hooks", "scheduled_tasks", "scheduled_runs", "ssh_hosts", "ssh_installations", "github_deliveries", "usage_records"])
        guard allowed.contains(table) else { throw RepositoryError.queryFailed(message: "不支持的扩展表") }
        let encoded = String(decoding: try encoder.encode(record.payload), as: UTF8.self)
        try withLock {
            if table == "scheduled_runs" {
                try execute("INSERT OR REPLACE INTO scheduled_runs (id, task_id, payload, updated_at) VALUES (?, ?, ?, ?);", values: [record.id, record.sessionID ?? "", encoded, record.createdAt.timeIntervalSince1970])
            } else if table == "github_deliveries" {
                try execute("INSERT OR REPLACE INTO github_deliveries (id, session_id, payload, updated_at) VALUES (?, ?, ?, ?);", values: [record.id, record.sessionID ?? "", encoded, record.createdAt.timeIntervalSince1970])
            } else if table == "ssh_installations" {
                try execute("INSERT OR REPLACE INTO ssh_installations (id, host_id, payload, updated_at) VALUES (?, ?, ?, ?);", values: [record.id, record.sessionID ?? "", encoded, record.createdAt.timeIntervalSince1970])
            } else if table == "mcp_tools" {
                try execute("INSERT OR REPLACE INTO mcp_tools (id, server_id, payload, updated_at) VALUES (?, ?, ?, ?);", values: [record.id, record.sessionID ?? "", encoded, record.createdAt.timeIntervalSince1970])
            } else {
                try execute("INSERT OR REPLACE INTO \(table) (id, payload, updated_at) VALUES (?, ?, ?);", values: [record.id, encoded, record.createdAt.timeIntervalSince1970])
            }
        }
    }

    public func extensionRecords(table: String) throws -> [PersistedExtensionRecord] {
        let allowed = Set(["mcp_servers", "skills", "hooks", "scheduled_tasks", "ssh_hosts", "usage_records"])
        guard allowed.contains(table) else { throw RepositoryError.queryFailed(message: "不支持读取的扩展表") }
        return try withLock {
            try query("SELECT id, payload, updated_at FROM \(table) ORDER BY updated_at DESC;") { statement in
                let payload = (try? self.decoder.decode([String: String].self, from: Data(statement.string(1).utf8))) ?? [:]
                return PersistedExtensionRecord(id: statement.string(0), kind: table, payload: payload, createdAt: Date(timeIntervalSince1970: statement.double(2)))
            }
        }
    }

    public func saveGitHubDelivery(_ delivery: GitHubDeliveryRecord) throws {
        let payload = String(decoding: try encoder.encode(delivery), as: UTF8.self)
        try withLock {
            try execute("INSERT OR REPLACE INTO github_deliveries (id, session_id, payload, updated_at) VALUES (?, ?, ?, ?);", values: [delivery.id, delivery.sessionID, payload, delivery.createdAt.timeIntervalSince1970])
        }
    }

    public func githubDeliveries(sessionID: String? = nil) throws -> [GitHubDeliveryRecord] {
        try withLock {
            let sql: String
            let values: [Any]
            if let sessionID {
                sql = "SELECT payload FROM github_deliveries WHERE session_id = ? ORDER BY updated_at DESC;"
                values = [sessionID]
            } else {
                sql = "SELECT payload FROM github_deliveries ORDER BY updated_at DESC;"
                values = []
            }
            return try query(sql, values: values) { statement in
                try? decoder.decode(GitHubDeliveryRecord.self, from: Data(statement.string(0).utf8))
            }.compactMap { $0 }
        }
    }

    public func saveScheduledRun(_ run: ScheduledRunRecord) throws {
        let encoded = String(decoding: try encoder.encode(run), as: UTF8.self)
        try withLock {
            try execute(
                "INSERT OR REPLACE INTO scheduled_runs (id, task_id, payload, updated_at) VALUES (?, ?, ?, ?);",
                values: [run.id, run.taskID, encoded, run.updatedAt.timeIntervalSince1970]
            )
        }
    }

    public func scheduledRuns(taskID: String? = nil) throws -> [ScheduledRunRecord] {
        try withLock {
            let rows: [String]
            if let taskID {
                rows = try query("SELECT payload FROM scheduled_runs WHERE task_id = ? ORDER BY updated_at DESC;", values: [taskID]) { $0.string(0) }
            } else {
                rows = try query("SELECT payload FROM scheduled_runs ORDER BY updated_at DESC;") { $0.string(0) }
            }
            return rows.compactMap { try? self.decoder.decode(ScheduledRunRecord.self, from: Data($0.utf8)) }
        }
    }

    public func saveTerminalSession(_ record: TerminalSessionRecord) throws {
        let safeRecord = record.redactedForPersistence()
        let payload = String(decoding: try encoder.encode(safeRecord), as: UTF8.self)
        try withLock {
            try execute(
                "INSERT INTO terminal_sessions (id, session_id, state, payload, updated_at) VALUES (?, ?, ?, ?, ?) ON CONFLICT(id) DO UPDATE SET state = excluded.state, payload = excluded.payload, updated_at = excluded.updated_at;",
                values: [safeRecord.id, safeRecord.sessionID, safeRecord.state.rawValue, payload, Date().timeIntervalSince1970]
            )
        }
    }

    public func terminalSessions(sessionID: String) throws -> [TerminalSessionRecord] {
        try withLock {
            try query("SELECT payload FROM terminal_sessions WHERE session_id = ? ORDER BY updated_at ASC;", values: [sessionID]) { statement in
                try? decoder.decode(TerminalSessionRecord.self, from: Data(statement.string(0).utf8))
            }.compactMap { $0 }
        }
    }

    public func allTerminalSessions() throws -> [TerminalSessionRecord] {
        try withLock {
            try query("SELECT payload FROM terminal_sessions ORDER BY updated_at ASC;") { statement in
                try? decoder.decode(TerminalSessionRecord.self, from: Data(statement.string(0).utf8))
            }.compactMap { $0 }
        }
    }

    public func appendTerminalEvent(_ event: TerminalAuditEvent) throws {
        let payload = String(decoding: try encoder.encode(event), as: UTF8.self)
        try withLock {
            try execute(
                "INSERT OR REPLACE INTO terminal_events (id, terminal_id, session_id, kind, payload, created_at) VALUES (?, ?, ?, ?, ?, ?);",
                values: [event.id, event.terminalID, event.sessionID, event.kind.rawValue, payload, event.createdAt.timeIntervalSince1970]
            )
        }
    }

    public func terminalEvents(terminalID: String) throws -> [TerminalAuditEvent] {
        try withLock {
            try query("SELECT payload FROM terminal_events WHERE terminal_id = ? ORDER BY created_at ASC;", values: [terminalID]) { statement in
                try? decoder.decode(TerminalAuditEvent.self, from: Data(statement.string(0).utf8))
            }.compactMap { $0 }
        }
    }

    public func saveTerminalPort(_ port: TerminalPortRecord) throws {
        let payload = String(decoding: try encoder.encode(port), as: UTF8.self)
        try withLock {
            try execute(
                "INSERT OR REPLACE INTO terminal_ports (id, terminal_id, port, host, payload, discovered_at) VALUES (?, ?, ?, ?, ?, ?);",
                values: [port.id, port.terminalID, port.port, port.host, payload, port.discoveredAt.timeIntervalSince1970]
            )
        }
    }

    public func terminalPorts(terminalID: String) throws -> [TerminalPortRecord] {
        try withLock {
            try query("SELECT payload FROM terminal_ports WHERE terminal_id = ? ORDER BY discovered_at ASC;", values: [terminalID]) { statement in
                try? decoder.decode(TerminalPortRecord.self, from: Data(statement.string(0).utf8))
            }.compactMap { $0 }
        }
    }

    public func saveTerminalProcess(_ process: TerminalProcessRecord) throws {
        try withLock {
            try execute(
                "INSERT INTO terminal_processes (terminal_id, pid, process_group, command_hash, cwd, updated_at) VALUES (?, ?, ?, ?, ?, ?) ON CONFLICT(terminal_id) DO UPDATE SET pid = excluded.pid, process_group = excluded.process_group, command_hash = excluded.command_hash, cwd = excluded.cwd, updated_at = excluded.updated_at;",
                values: [process.terminalID, process.pid.map { Int($0) } ?? NSNull(), process.processGroup.map { Int($0) } ?? NSNull(), process.commandHash, process.cwd, process.updatedAt.timeIntervalSince1970]
            )
        }
    }

    public func terminalProcess(terminalID: String) throws -> TerminalProcessRecord? {
        try withLock {
            try query("SELECT terminal_id, pid, process_group, command_hash, cwd, updated_at FROM terminal_processes WHERE terminal_id = ? LIMIT 1;", values: [terminalID]) { statement in
                TerminalProcessRecord(
                    terminalID: statement.string(0),
                    pid: statement.isNull(1) ? nil : Int32(statement.int(1)),
                    processGroup: statement.isNull(2) ? nil : Int32(statement.int(2)),
                    commandHash: statement.string(3),
                    cwd: statement.string(4),
                    updatedAt: Date(timeIntervalSince1970: statement.double(5))
                )
            }.first
        }
    }

    public func appendTerminalCommandHistory(_ history: TerminalCommandHistoryRecord) throws {
        try withLock {
            try execute(
                "INSERT OR REPLACE INTO terminal_command_history (id, session_id, terminal_id, command, command_hash, risk, created_at) VALUES (?, ?, ?, ?, ?, ?, ?);",
                values: [history.id, history.sessionID, history.terminalID, history.command as Any, history.commandHash, history.risk.rawValue, history.createdAt.timeIntervalSince1970]
            )
        }
    }

    public func terminalCommandHistory(sessionID: String) throws -> [TerminalCommandHistoryRecord] {
        try withLock {
            try query("SELECT id, session_id, terminal_id, command, command_hash, risk, created_at FROM terminal_command_history WHERE session_id = ? ORDER BY created_at DESC;", values: [sessionID]) { statement in
                TerminalCommandHistoryRecord(
                    id: statement.string(0),
                    sessionID: statement.string(1),
                    terminalID: statement.string(2),
                    storedCommand: statement.stringOrNil(3),
                    commandHash: statement.string(4),
                    risk: CommandRisk(rawValue: statement.int(5)) ?? .l4,
                    createdAt: Date(timeIntervalSince1970: statement.double(6))
                )
            }
        }
    }

    public func renameSession(id: String, title: String) throws {
        let now = Date().timeIntervalSince1970
        try withLock {
            try execute("UPDATE sessions SET title = ?, updated_at = ? WHERE id = ?;", values: [title, now, id])
        }
    }

    public func archiveSession(id: String) throws {
        let now = Date().timeIntervalSince1970
        try withLock {
            try execute("UPDATE sessions SET archived = 1, updated_at = ? WHERE id = ?;", values: [now, id])
        }
    }

    public func unarchiveSession(id: String) throws {
        let now = Date().timeIntervalSince1970
        try withLock {
            try execute("UPDATE sessions SET archived = 0, updated_at = ? WHERE id = ?;", values: [now, id])
        }
    }

    /// Permanently removes a Session only after writing a portable local
    /// backup. Active work is never deleted while a side effect may still be
    /// running; the caller must first stop it or wait for a safe boundary.
    @discardableResult
    public func deleteSession(id: String, backupDirectory: URL) throws -> SessionDeletionReceipt {
        guard let session = try session(id: id) else { throw RepositoryError.sessionNotFound }
        guard ![.running, .executing, .delivering, .verifying].contains(session.status) else {
            throw SessionLifecycleError.activeSession
        }
        let hasActiveTerminal = try terminalSessions(sessionID: id).contains {
            [.starting, .running, .background].contains($0.state)
        }
        guard !hasActiveTerminal else { throw SessionLifecycleError.activeTerminal }
        let backup = SessionDeletionBackup(
            session: session,
            project: try projects().first(where: { $0.id == session.projectID }),
            events: try events(sessionID: id),
            taskContract: try taskContract(sessionID: id)
        )
        guard backup.isValid else { throw SessionLifecycleError.invalidBackup }
        try FileManager.default.createDirectory(at: backupDirectory, withIntermediateDirectories: true)
        let fileName = "session-\(id)-\(Int(backup.createdAt.timeIntervalSince1970)).json"
        let backupURL = backupDirectory.appendingPathComponent(fileName)
        let data = try encoder.encode(backup)
        try data.write(to: backupURL, options: [.atomic, .completeFileProtection])
        try withLock {
            try execute("DELETE FROM sessions WHERE id = ?;", values: [id])
        }
        return SessionDeletionReceipt(sessionID: id, backupURL: backupURL, eventCount: backup.events.count)
    }

    @discardableResult
    public func restoreSession(from backupURL: URL) throws -> StoredSession {
        let data = try Data(contentsOf: backupURL)
        let backup = try decoder.decode(SessionDeletionBackup.self, from: data)
        guard backup.isValid else { throw SessionLifecycleError.invalidBackup }
        if let project = backup.project, try self.project(id: project.id) == nil {
            try importProject(project)
        }
        guard try self.project(id: backup.session.projectID) != nil else { throw SessionLifecycleError.projectMissing }
        guard try importSession(backup.session) else { return backup.session }
        if let contract = backup.taskContract { try saveTaskContract(contract, sessionID: backup.session.id) }
        for event in backup.events { try importEvent(event) }
        return backup.session
    }

    public func forkSession(id: String, title: String) throws -> StoredSession {
        guard let source = try session(id: id) else { throw RepositoryError.sessionNotFound }
        let fork = try createSession(projectID: source.projectID, title: title, mode: source.mode, target: .local, branch: "main", worktreePath: nil)
        try append(sessionID: fork.id, type: "session_forked", payload: ["sourceSessionID": source.id])
        return fork
    }

    public func append(sessionID: String, type: String, payload: [String: String]) throws {
        _ = try appendDurable(sessionID: sessionID, type: type, payload: payload)
    }

    /// Registers a lightweight observer for newly appended durable events.
    /// Observers are invoked after the SQLite transaction has released the
    /// repository lock, so a UI/control-plane callback can safely read a
    /// projection or append a follow-up event without deadlocking storage.
    @discardableResult
    public func observeEvents(_ observer: @escaping @Sendable (SessionEvent) -> Void) -> UUID {
        let id = UUID()
        lock.lock()
        eventObservers[id] = observer
        lock.unlock()
        return id
    }

    public func removeEventObserver(_ id: UUID) {
        lock.lock()
        eventObservers.removeValue(forKey: id)
        lock.unlock()
    }

    @discardableResult
    public func appendDurable(
        sessionID: String,
        type: String,
        payload: [String: String],
        commandID: String = UUID().uuidString,
        causationID: String? = nil,
        correlationID: String? = nil,
        schemaVersion: Int = SessionEventEnvelope.currentSchemaVersion
    ) throws -> SessionEvent {
        let result = try withLock {
            let existing = try query(
                "SELECT event_id, sequence, type, payload, timestamp FROM session_event_log WHERE command_id = ? LIMIT 1;",
                values: [commandID],
                map: { statement in
                    let payloadData = Data(statement.string(3).utf8)
                    let decoded = (try? self.decoder.decode([String: String].self, from: payloadData)) ?? [:]
                    return SessionEvent(
                        id: UUID(uuidString: statement.string(0)) ?? UUID(),
                        sessionID: sessionID,
                        sequence: statement.int(1),
                        timestamp: Date(timeIntervalSince1970: statement.double(4)),
                        type: statement.string(2),
                        payload: decoded
                    )
                }
            ).first
            if let existing {
                return existing
            }
            return try appendDurableUnlocked(
                sessionID: sessionID,
                type: type,
                payload: payload,
                commandID: commandID,
                causationID: causationID,
                correlationID: correlationID,
                schemaVersion: schemaVersion
            )
        }
        _ = try? refreshProjection(sessionID: sessionID)
        _ = try? refreshPartProjection(sessionID: sessionID)
        notifyEventObservers(result)
        return result
    }

    private func notifyEventObservers(_ event: SessionEvent) {
        lock.lock()
        let observers = Array(eventObservers.values)
        lock.unlock()
        observers.forEach { $0(event) }
    }

    public func importEvent(_ event: SessionEvent) throws {
        try withLock {
            let data = try encoder.encode(event.payload)
            try execute("INSERT OR IGNORE INTO session_event_log (aggregate_id, sequence, event_id, command_id, type, payload, timestamp, schema_version) VALUES (?, ?, ?, ?, ?, ?, ?, 1);", values: [event.sessionID, event.sequence, event.id.uuidString, "legacy-import-\(event.id.uuidString)", event.type, String(decoding: data, as: UTF8.self), event.timestamp.timeIntervalSince1970])
        }
        _ = try? refreshProjection(sessionID: event.sessionID)
        _ = try? refreshPartProjection(sessionID: event.sessionID)
    }

    public func events(sessionID: String) throws -> [SessionEvent] {
        try withLock {
            let durable = try query("SELECT event_id, sequence, type, payload, timestamp FROM session_event_log WHERE aggregate_id = ? ORDER BY sequence ASC;", values: [sessionID]) { statement in
                let payloadData = Data(statement.string(3).utf8)
                let payload = (try? self.decoder.decode([String: String].self, from: payloadData)) ?? [:]
                return SessionEvent(id: UUID(uuidString: statement.string(0)) ?? UUID(), sessionID: sessionID, sequence: statement.int(1), timestamp: Date(timeIntervalSince1970: statement.double(4)), type: statement.string(2), payload: payload)
            }
            if !durable.isEmpty { return durable }
            return try query("SELECT event_id, sequence, type, payload, timestamp FROM session_events WHERE session_id = ? ORDER BY sequence ASC;", values: [sessionID]) { statement in
                let payloadData = Data(statement.string(3).utf8)
                let payload = (try? self.decoder.decode([String: String].self, from: payloadData)) ?? [:]
                return SessionEvent(id: UUID(uuidString: statement.string(0)) ?? UUID(), sessionID: sessionID, sequence: statement.int(1), timestamp: Date(timeIntervalSince1970: statement.double(4)), type: statement.string(2), payload: payload)
            }
        }
    }

    public func events(sessionID: String, afterSequence sequence: Int) throws -> [SessionEvent] {
        try withLock {
            let durable = try query(
                "SELECT event_id, sequence, type, payload, timestamp FROM session_event_log WHERE aggregate_id = ? AND sequence > ? ORDER BY sequence ASC;",
                values: [sessionID, sequence]
            ) { statement in
                let payloadData = Data(statement.string(3).utf8)
                let payload = (try? self.decoder.decode([String: String].self, from: payloadData)) ?? [:]
                return SessionEvent(id: UUID(uuidString: statement.string(0)) ?? UUID(), sessionID: sessionID, sequence: statement.int(1), timestamp: Date(timeIntervalSince1970: statement.double(4)), type: statement.string(2), payload: payload)
            }
            if !durable.isEmpty { return durable }
            return try query(
                "SELECT event_id, sequence, type, payload, timestamp FROM session_events WHERE session_id = ? AND sequence > ? ORDER BY sequence ASC;",
                values: [sessionID, sequence]
            ) { statement in
                let payloadData = Data(statement.string(3).utf8)
                let payload = (try? self.decoder.decode([String: String].self, from: payloadData)) ?? [:]
                return SessionEvent(id: UUID(uuidString: statement.string(0)) ?? UUID(), sessionID: sessionID, sequence: statement.int(1), timestamp: Date(timeIntervalSince1970: statement.double(4)), type: statement.string(2), payload: payload)
            }
        }
    }

    public func eventEnvelope(commandID: String) throws -> SessionEventEnvelope? {
        try withLock {
            try query(
                "SELECT aggregate_id, sequence, event_id, command_id, causation_id, correlation_id, type, payload, timestamp, schema_version FROM session_event_log WHERE command_id = ? LIMIT 1;",
                values: [commandID],
                map: decodeEventEnvelope
            ).first
        }
    }

    public func eventEnvelopes(sessionID: String, afterSequence sequence: Int = 0) throws -> [SessionEventEnvelope] {
        try withLock {
            try query(
                "SELECT aggregate_id, sequence, event_id, command_id, causation_id, correlation_id, type, payload, timestamp, schema_version FROM session_event_log WHERE aggregate_id = ? AND sequence > ? ORDER BY sequence ASC;",
                values: [sessionID, sequence],
                map: decodeEventEnvelope
            )
        }
    }

    private func decodeEventEnvelope(_ statement: SQLiteStatement) -> SessionEventEnvelope {
        let payloadData = Data(statement.string(7).utf8)
        let payload = (try? decoder.decode([String: String].self, from: payloadData)) ?? [:]
        return SessionEventEnvelope(
            eventID: UUID(uuidString: statement.string(2)) ?? UUID(),
            aggregateID: statement.string(0),
            sequence: statement.int(1),
            commandID: statement.string(3),
            causationID: statement.isNull(4) ? nil : statement.string(4),
            correlationID: statement.isNull(5) ? nil : statement.string(5),
            kind: SessionEventKind(rawValue: statement.string(6)),
            payload: payload,
            timestamp: Date(timeIntervalSince1970: statement.double(8)),
            schemaVersion: statement.int(9)
        )
    }

    public func eventCount(sessionID: String) throws -> Int {
        try withLock {
            let values = try query("SELECT COUNT(*) FROM session_event_log WHERE aggregate_id = ?;", values: [sessionID]) { $0.int(0) }
            if values.first ?? 0 > 0 { return values.first ?? 0 }
            let legacy = try query("SELECT COUNT(*) FROM session_events WHERE session_id = ?;", values: [sessionID]) { $0.int(0) }
            return legacy.first ?? 0
        }
    }

    public func enqueueSessionInput(
        sessionID: String,
        idempotencyKey: String,
        delivery: SessionInputDelivery,
        parts: [ContentPart]
    ) throws -> SessionInputRecord {
        let record = try withLock {
            if let existing = try sessionInputUnlocked(idempotencyKey: idempotencyKey) {
                return existing
            }
            let admittedSequence = try query(
                "SELECT COALESCE(MAX(sequence), 0) + 1 FROM session_event_log WHERE aggregate_id = ?;",
                values: [sessionID]
            ) { $0.int(0) }.first ?? 1
            let record = SessionInputRecord(
                sessionID: sessionID,
                idempotencyKey: idempotencyKey,
                admittedSequence: admittedSequence,
                delivery: delivery,
                parts: parts
            )
            let payload = String(decoding: try encoder.encode(record), as: UTF8.self)
            try execute(
                "INSERT INTO session_input_inbox (id, session_id, idempotency_key, admitted_sequence, delivery, state, payload, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?);",
                values: [
                    record.id,
                    record.sessionID,
                    record.idempotencyKey,
                    record.admittedSequence,
                    record.delivery.rawValue,
                    record.state.rawValue,
                    payload,
                    record.createdAt.timeIntervalSince1970,
                    record.updatedAt.timeIntervalSince1970
                ]
            )
            _ = try appendDurableUnlocked(
                sessionID: sessionID,
                type: "session_input_accepted",
                payload: ["inputID": record.id, "delivery": delivery.rawValue],
                commandID: "input-\(idempotencyKey)",
                causationID: nil,
                correlationID: nil,
                schemaVersion: 1
            )
            return record
        }
        _ = try? refreshProjection(sessionID: sessionID)
        _ = try? refreshPartProjection(sessionID: sessionID)
        return record
    }

    public func promoteNextSessionInput(sessionID: String) throws -> SessionInputRecord? {
        let promoted: SessionInputRecord? = try withLock {
            let rows = try query(
                "SELECT payload FROM session_input_inbox WHERE session_id = ? AND state = ? AND delivery <> ? ORDER BY admitted_sequence ASC LIMIT 1;",
                values: [sessionID, SessionInputState.accepted.rawValue, SessionInputDelivery.contextOnly.rawValue]
            ) { $0.string(0) }
            guard let encoded = rows.first,
                  var record = try? decoder.decode(SessionInputRecord.self, from: Data(encoded.utf8)) else { return nil }
            record.state = .promoted
            record.updatedAt = Date()
            let payload = String(decoding: try encoder.encode(record), as: UTF8.self)
            try execute(
                "UPDATE session_input_inbox SET state = ?, payload = ?, updated_at = ? WHERE id = ?;",
                values: [record.state.rawValue, payload, record.updatedAt.timeIntervalSince1970, record.id]
            )
            _ = try appendDurableUnlocked(
                sessionID: sessionID,
                type: "session_input_promoted",
                payload: ["inputID": record.id],
                commandID: "promote-input-\(record.id)",
                causationID: record.id,
                correlationID: nil,
                schemaVersion: 1
            )
            return record
        }
        _ = try? refreshProjection(sessionID: sessionID)
        _ = try? refreshPartProjection(sessionID: sessionID)
        return promoted
    }

    /// Atomically claims one primary message and every accepted context-only
    /// message for the same safe boundary. The log records each promotion so
    /// an App/daemon restart can resume from the exact admitted state.
    public func promoteSessionInputBoundary(sessionID: String) throws -> SessionInputBoundary? {
        let boundary: SessionInputBoundary? = try withLock {
            let rows = try query(
                "SELECT payload FROM session_input_inbox WHERE session_id = ? AND state = ? ORDER BY admitted_sequence ASC;",
                values: [sessionID, SessionInputState.accepted.rawValue]
            ) { $0.string(0) }
            let accepted = rows.compactMap { try? decoder.decode(SessionInputRecord.self, from: Data($0.utf8)) }
            guard let primaryIndex = accepted.firstIndex(where: { $0.delivery != .contextOnly }) else { return nil }
            var primary = accepted[primaryIndex]
            let context = accepted.filter { $0.delivery == .contextOnly }
            let records = [primary] + context
            var promotedByID: [String: SessionInputRecord] = [:]
            for var record in records {
                record.state = .promoted
                record.updatedAt = Date()
                let payload = String(decoding: try encoder.encode(record), as: UTF8.self)
                try execute(
                    "UPDATE session_input_inbox SET state = ?, payload = ?, updated_at = ? WHERE id = ? AND state = ?;",
                    values: [record.state.rawValue, payload, record.updatedAt.timeIntervalSince1970, record.id, SessionInputState.accepted.rawValue]
                )
                guard sqlite3_changes(database) == 1 else { continue }
                _ = try appendDurableUnlocked(
                    sessionID: sessionID,
                    type: "session_input_promoted",
                    payload: ["inputID": record.id, "delivery": record.delivery.rawValue],
                    commandID: "promote-input-\(record.id)",
                    causationID: record.id,
                    correlationID: primary.id,
                    schemaVersion: SessionEventEnvelope.currentSchemaVersion
                )
                promotedByID[record.id] = record
            }
            guard let promotedPrimary = promotedByID[primary.id] else { return nil }
            primary = promotedPrimary
            return SessionInputBoundary(
                primary: primary,
                context: context.compactMap { promotedByID[$0.id] }
            )
        }
        _ = try? refreshProjection(sessionID: sessionID)
        _ = try? refreshPartProjection(sessionID: sessionID)
        return boundary
    }

    public func markSessionInputConsumed(id: String) throws {
        try transitionSessionInput(id: id, state: .consumed)
    }

    /// Completes an Inbox item only after it has crossed a durable execution
    /// boundary.  This compare-and-swap prevents a foreground client from
    /// losing an accepted message before its Agent run has actually started.
    @discardableResult
    public func consumePromotedSessionInput(id: String) throws -> Bool {
        let sessionID: String? = try withLock {
            let rows = try query("SELECT payload FROM session_input_inbox WHERE id = ? LIMIT 1;", values: [id]) { $0.string(0) }
            guard let encoded = rows.first,
                  var record = try? decoder.decode(SessionInputRecord.self, from: Data(encoded.utf8)),
                  record.state == .promoted else { return nil }
            record.state = .consumed
            record.updatedAt = Date()
            let payload = String(decoding: try encoder.encode(record), as: UTF8.self)
            try execute(
                "UPDATE session_input_inbox SET state = ?, payload = ?, updated_at = ? WHERE id = ? AND state = ?;",
                values: [
                    SessionInputState.consumed.rawValue,
                    payload,
                    record.updatedAt.timeIntervalSince1970,
                    id,
                    SessionInputState.promoted.rawValue
                ]
            )
            guard sqlite3_changes(database) == 1 else { return nil }
            _ = try appendDurableUnlocked(
                sessionID: record.sessionID,
                type: "session_input_consumed",
                payload: ["inputID": id],
                commandID: "input-consumed-\(id)",
                causationID: id,
                correlationID: nil,
                schemaVersion: 1
            )
            return record.sessionID
        }
        guard let sessionID else { return false }
        _ = try? refreshProjection(sessionID: sessionID)
        _ = try? refreshPartProjection(sessionID: sessionID)
        return true
    }

    public func cancelSessionInput(id: String) throws {
        try transitionSessionInput(id: id, state: .cancelled)
    }

    public func sessionInputs(sessionID: String) throws -> [SessionInputRecord] {
        try withLock {
            try query(
                "SELECT payload FROM session_input_inbox WHERE session_id = ? ORDER BY admitted_sequence ASC;",
                values: [sessionID]
            ) { statement in
                try? self.decoder.decode(SessionInputRecord.self, from: Data(statement.string(0).utf8))
            }.compactMap { $0 }
        }
    }

    public func acquireSessionLease(
        sessionID: String,
        ownerInstanceID: String,
        now: Date = Date(),
        ttl: TimeInterval = 15
    ) throws -> SessionLease {
        try withLock {
            let existing = try leaseUnlocked(sessionID: sessionID)
            if let existing, existing.ownerInstanceID != ownerInstanceID, existing.isActive(at: now) {
                throw SessionLeaseError.heldByAnotherOwner
            }
            let lease = SessionLease(
                sessionID: sessionID,
                ownerInstanceID: ownerInstanceID,
                heartbeat: now,
                expiresAt: now.addingTimeInterval(max(1, ttl))
            )
            try execute(
                "INSERT INTO session_leases (session_id, owner_instance_id, heartbeat, expires_at) VALUES (?, ?, ?, ?) ON CONFLICT(session_id) DO UPDATE SET owner_instance_id = excluded.owner_instance_id, heartbeat = excluded.heartbeat, expires_at = excluded.expires_at;",
                values: [lease.sessionID, lease.ownerInstanceID, lease.heartbeat.timeIntervalSince1970, lease.expiresAt.timeIntervalSince1970]
            )
            return lease
        }
    }

    public func renewSessionLease(
        sessionID: String,
        ownerInstanceID: String,
        now: Date = Date(),
        ttl: TimeInterval = 15
    ) throws -> SessionLease {
        try withLock {
            guard let existing = try leaseUnlocked(sessionID: sessionID), existing.ownerInstanceID == ownerInstanceID else {
                throw SessionLeaseError.notOwner
            }
            let lease = SessionLease(
                sessionID: sessionID,
                ownerInstanceID: ownerInstanceID,
                heartbeat: now,
                expiresAt: now.addingTimeInterval(max(1, ttl))
            )
            try execute(
                "UPDATE session_leases SET heartbeat = ?, expires_at = ? WHERE session_id = ?;",
                values: [lease.heartbeat.timeIntervalSince1970, lease.expiresAt.timeIntervalSince1970, sessionID]
            )
            return lease
        }
    }

    public func releaseSessionLease(sessionID: String, ownerInstanceID: String) throws {
        try withLock {
            guard let existing = try leaseUnlocked(sessionID: sessionID), existing.ownerInstanceID == ownerInstanceID else {
                throw SessionLeaseError.notOwner
            }
            try execute("DELETE FROM session_leases WHERE session_id = ?;", values: [sessionID])
        }
    }

    public func saveProjection(_ snapshot: SessionProjectionSnapshot) throws {
        try withLock {
            try execute(
                "INSERT INTO session_projection (session_id, cursor_sequence, payload, updated_at) VALUES (?, ?, ?, ?) ON CONFLICT(session_id) DO UPDATE SET cursor_sequence = excluded.cursor_sequence, payload = excluded.payload, updated_at = excluded.updated_at;",
                values: [snapshot.sessionID, snapshot.cursorSequence, snapshot.payload.base64EncodedString(), snapshot.updatedAt.timeIntervalSince1970]
            )
        }
    }

    public func projection(sessionID: String) throws -> SessionProjectionSnapshot? {
        try withLock {
            try query(
                "SELECT cursor_sequence, payload, updated_at FROM session_projection WHERE session_id = ? LIMIT 1;",
                values: [sessionID]
            ) { statement in
                SessionProjectionSnapshot(
                    sessionID: sessionID,
                    cursorSequence: statement.int(0),
                    payload: Data(base64Encoded: statement.string(1)) ?? Data(),
                    updatedAt: Date(timeIntervalSince1970: statement.double(2))
                )
            }.first
        }
    }

    /// Materializes the current event-log projection after each durable append.
    /// This is a cache only: it can always be rebuilt from `session_event_log`.
    @discardableResult
    public func refreshProjection(sessionID: String) throws -> SessionProjectionSnapshot? {
        guard let session = try session(id: sessionID) else { return nil }
        let events = try events(sessionID: sessionID)
        let state = try SessionProjector.project(session: session, events: events)
        let cursor = events.last?.sequence ?? 0
        let snapshot = SessionProjectionSnapshot(
            sessionID: sessionID,
            cursorSequence: cursor,
            payload: try encoder.encode(state)
        )
        try saveProjection(snapshot)
        return snapshot
    }

    public func saveSessionParts(
        sessionID: String,
        cursorSequence: Int,
        parts: [SessionPart],
        updatedAt: Date = Date()
    ) throws {
        let payload = String(decoding: try encoder.encode(parts), as: UTF8.self)
        try withLock {
            try execute(
                "INSERT INTO session_parts (session_id, cursor_sequence, payload, updated_at) VALUES (?, ?, ?, ?) ON CONFLICT(session_id) DO UPDATE SET cursor_sequence = excluded.cursor_sequence, payload = excluded.payload, updated_at = excluded.updated_at;",
                values: [sessionID, cursorSequence, payload, updatedAt.timeIntervalSince1970]
            )
        }
    }

    public func sessionParts(sessionID: String) throws -> SessionPartProjectionSnapshot? {
        try withLock {
            try query(
                "SELECT cursor_sequence, payload, updated_at FROM session_parts WHERE session_id = ? LIMIT 1;",
                values: [sessionID]
            ) { statement in
                SessionPartProjectionSnapshot(
                    sessionID: sessionID,
                    cursorSequence: statement.int(0),
                    parts: (try? self.decoder.decode([SessionPart].self, from: Data(statement.string(1).utf8))) ?? [],
                    updatedAt: Date(timeIntervalSince1970: statement.double(2))
                )
            }.first
        }
    }

    /// Refreshes the UI/control-plane cache from the append-only event log.
    @discardableResult
    public func refreshPartProjection(sessionID: String) throws -> SessionPartProjectionSnapshot? {
        guard try session(id: sessionID) != nil else { return nil }
        let events = try events(sessionID: sessionID)
        let snapshot = SessionPartProjectionSnapshot(
            sessionID: sessionID,
            cursorSequence: events.last?.sequence ?? 0,
            parts: SessionPartProjector.project(events: events)
        )
        try saveSessionParts(
            sessionID: snapshot.sessionID,
            cursorSequence: snapshot.cursorSequence,
            parts: snapshot.parts,
            updatedAt: snapshot.updatedAt
        )
        return snapshot
    }

    public func createApproval(sessionID: String, tool: String, risk: CommandRisk, arguments: String) throws -> ApprovalRecord {
        let approval = ApprovalRecord(sessionID: sessionID, tool: tool, risk: risk, arguments: arguments)
        try withLock {
            try execute("INSERT INTO approvals (id, session_id, tool, risk, arguments, decision, created_at, resolved_at) VALUES (?, ?, ?, ?, ?, ?, ?, NULL);", values: [approval.id, approval.sessionID, approval.tool, approval.risk.rawValue, approval.arguments, approval.decision.rawValue, approval.createdAt.timeIntervalSince1970])
        }
        return approval
    }

    public func approval(id: String) throws -> ApprovalRecord? {
        try withLock {
            try query("SELECT id, session_id, tool, risk, arguments, decision, created_at, resolved_at FROM approvals WHERE id = ? LIMIT 1;", values: [id]) { statement in
                ApprovalRecord(id: statement.string(0), sessionID: statement.string(1), tool: statement.string(2), risk: CommandRisk(rawValue: statement.int(3)) ?? .l4, arguments: statement.string(4), decision: ApprovalDecision(rawValue: statement.string(5)) ?? .pending, createdAt: Date(timeIntervalSince1970: statement.double(6)), resolvedAt: statement.isNull(7) ? nil : Date(timeIntervalSince1970: statement.double(7)))
            }.first
        }
    }

    public func resolveApproval(id: String, decision: ApprovalDecision) throws {
        try withLock {
            try execute("UPDATE approvals SET decision = ?, resolved_at = ? WHERE id = ?;", values: [decision.rawValue, Date().timeIntervalSince1970, id])
        }
    }

    /// One-shot compare-and-swap for an approval decision.  A second client
    /// resolving the same approval receives `false` and must not resume the
    /// original tool call again.
    @discardableResult
    public func resolvePendingApproval(id: String, decision: ApprovalDecision) throws -> Bool {
        guard decision != .pending else { return false }
        return try withLock {
            try execute(
                "UPDATE approvals SET decision = ?, resolved_at = ? WHERE id = ? AND decision = ?;",
                values: [decision.rawValue, Date().timeIntervalSince1970, id, ApprovalDecision.pending.rawValue]
            )
            return sqlite3_changes(database) == 1
        }
    }

    public func savePermissionLease(_ lease: PermissionLease) throws {
        try withLock {
            let payload = String(decoding: try encoder.encode(lease), as: UTF8.self)
            try execute(
                "INSERT INTO permission_leases (id, project_id, session_id, effect, tool_name, payload, expires_at, revoked_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?) ON CONFLICT(project_id, session_id, effect, tool_name) DO UPDATE SET id = excluded.id, payload = excluded.payload, expires_at = excluded.expires_at, revoked_at = excluded.revoked_at;",
                values: [
                    lease.id,
                    lease.key.projectID ?? "",
                    lease.key.sessionID ?? "",
                    lease.key.effect.rawValue,
                    lease.key.toolName,
                    payload,
                    lease.expiresAt.timeIntervalSince1970,
                    lease.revokedAt?.timeIntervalSince1970 as Any
                ]
            )
        }
    }

    public func permissionLease(key: PermissionLeaseKey) throws -> PermissionLease? {
        try withLock {
            let rows = try query(
                "SELECT payload FROM permission_leases WHERE project_id = ? AND session_id = ? AND effect = ? AND tool_name = ? LIMIT 1;",
                values: [key.projectID ?? "", key.sessionID ?? "", key.effect.rawValue, key.toolName]
            ) { $0.string(0) }
            return rows.first.flatMap { try? decoder.decode(PermissionLease.self, from: Data($0.utf8)) }
        }
    }

    public func saveRunState(_ state: AgentRunState) throws {
        let data = try encoder.encode(state)
        try withLock {
            try execute("INSERT INTO agent_runs (session_id, state, updated_at) VALUES (?, ?, ?) ON CONFLICT(session_id) DO UPDATE SET state = excluded.state, updated_at = excluded.updated_at;", values: [state.sessionID, String(decoding: data, as: UTF8.self), Date().timeIntervalSince1970])
        }
    }

    public func runState(sessionID: String) throws -> AgentRunState? {
        try withLock {
            let states = try query("SELECT state FROM agent_runs WHERE session_id = ? LIMIT 1;", values: [sessionID], map: { $0.string(0) })
            guard let encoded = states.first else { return nil }
            return try decoder.decode(AgentRunState.self, from: Data(encoded.utf8))
        }
    }

    public func saveAgentWorker(_ worker: AgentWorkerRecord) throws {
        let payload = String(decoding: try encoder.encode(worker), as: UTF8.self)
        try withLock {
            try execute(
                "INSERT INTO agent_workers (id, session_id, state, payload, updated_at) VALUES (?, ?, ?, ?, ?) ON CONFLICT(id) DO UPDATE SET state = excluded.state, payload = excluded.payload, updated_at = excluded.updated_at;",
                values: [worker.id, worker.sessionID, worker.state.rawValue, payload, worker.updatedAt.timeIntervalSince1970]
            )
        }
    }

    public func agentWorkers(sessionID: String? = nil) throws -> [AgentWorkerRecord] {
        try withLock {
            let rows: [String]
            if let sessionID {
                rows = try query("SELECT payload FROM agent_workers WHERE session_id = ? ORDER BY updated_at DESC;", values: [sessionID]) { $0.string(0) }
            } else {
                rows = try query("SELECT payload FROM agent_workers ORDER BY updated_at DESC;") { $0.string(0) }
            }
            return rows.compactMap { try? decoder.decode(AgentWorkerRecord.self, from: Data($0.utf8)) }
        }
    }

    public func allAgentWorkers() throws -> [AgentWorkerRecord] {
        try agentWorkers(sessionID: nil)
    }

    public func saveWorkerSession(_ record: WorkerSessionRecord) throws {
        let payload = String(decoding: try encoder.encode(record), as: UTF8.self)
        try withLock {
            try execute(
                "INSERT INTO worker_sessions (id, parent_session_id, worker_id, state, cursor_sequence, payload, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?) ON CONFLICT(id) DO UPDATE SET state = excluded.state, cursor_sequence = excluded.cursor_sequence, payload = excluded.payload, updated_at = excluded.updated_at;",
                values: [record.id, record.parentSessionID, record.workerID, record.state.rawValue, record.cursorSequence, payload, record.createdAt.timeIntervalSince1970, record.updatedAt.timeIntervalSince1970]
            )
        }
    }

    public func workerSession(id: String) throws -> WorkerSessionRecord? {
        try withLock {
            try query("SELECT payload FROM worker_sessions WHERE id = ? LIMIT 1;", values: [id]) { statement in
                try? self.decoder.decode(WorkerSessionRecord.self, from: Data(statement.string(0).utf8))
            }.compactMap { $0 }.first
        }
    }

    public func workerSessions(parentSessionID: String? = nil) throws -> [WorkerSessionRecord] {
        try withLock {
            let rows: [String]
            if let parentSessionID {
                rows = try query("SELECT payload FROM worker_sessions WHERE parent_session_id = ? ORDER BY updated_at DESC;", values: [parentSessionID]) { $0.string(0) }
            } else {
                rows = try query("SELECT payload FROM worker_sessions ORDER BY updated_at DESC;") { $0.string(0) }
            }
            return rows.compactMap { try? self.decoder.decode(WorkerSessionRecord.self, from: Data($0.utf8)) }
        }
    }

    private func appendDurableUnlocked(
        sessionID: String,
        type: String,
        payload: [String: String],
        commandID: String,
        causationID: String?,
        correlationID: String?,
        schemaVersion: Int
    ) throws -> SessionEvent {
        let now = Date()
        let eventID = UUID()
        let sequence = try query(
            "SELECT COALESCE(MAX(sequence), 0) + 1 FROM session_event_log WHERE aggregate_id = ?;",
            values: [sessionID]
        ) { $0.int(0) }.first ?? 1
        let data = try encoder.encode(payload)
        try execute(
            "INSERT INTO session_event_log (aggregate_id, sequence, event_id, command_id, causation_id, correlation_id, type, payload, timestamp, schema_version) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?);",
            values: [
                sessionID,
                sequence,
                eventID.uuidString,
                commandID,
                causationID as Any,
                correlationID as Any,
                type,
                String(decoding: data, as: UTF8.self),
                now.timeIntervalSince1970,
                max(1, schemaVersion)
            ]
        )
        try execute("UPDATE sessions SET updated_at = ? WHERE id = ?;", values: [now.timeIntervalSince1970, sessionID])
        return SessionEvent(
            id: eventID,
            sessionID: sessionID,
            sequence: sequence,
            timestamp: now,
            type: type,
            payload: payload
        )
    }

    private func migrateLegacySessionEvents() throws {
        try execute(
            """
            INSERT OR IGNORE INTO session_event_log
            (aggregate_id, sequence, event_id, command_id, type, payload, timestamp, schema_version)
            SELECT session_id, sequence, event_id, 'legacy-' || event_id, type, payload, timestamp, 1
            FROM session_events;
            """
        )
    }

    private func sessionInputUnlocked(idempotencyKey: String) throws -> SessionInputRecord? {
        try query(
            "SELECT payload FROM session_input_inbox WHERE idempotency_key = ? LIMIT 1;",
            values: [idempotencyKey]
        ) { statement in
            try? self.decoder.decode(SessionInputRecord.self, from: Data(statement.string(0).utf8))
        }.compactMap { $0 }.first
    }

    private func transitionSessionInput(id: String, state: SessionInputState) throws {
        let sessionID = try withLock {
            let rows = try query("SELECT payload FROM session_input_inbox WHERE id = ? LIMIT 1;", values: [id]) { $0.string(0) }
            guard let encoded = rows.first,
                  var record = try? decoder.decode(SessionInputRecord.self, from: Data(encoded.utf8)) else { return "" }
            record.state = state
            record.updatedAt = Date()
            let payload = String(decoding: try encoder.encode(record), as: UTF8.self)
            try execute(
                "UPDATE session_input_inbox SET state = ?, payload = ?, updated_at = ? WHERE id = ?;",
                values: [state.rawValue, payload, record.updatedAt.timeIntervalSince1970, id]
            )
            _ = try appendDurableUnlocked(
                sessionID: record.sessionID,
                type: state == .consumed ? "session_input_consumed" : "session_input_cancelled",
                payload: ["inputID": id],
                commandID: "input-\(state.rawValue)-\(id)",
                causationID: id,
                correlationID: nil,
                schemaVersion: 1
            )
            return record.sessionID
        }
        guard !sessionID.isEmpty else { return }
        _ = try? refreshProjection(sessionID: sessionID)
        _ = try? refreshPartProjection(sessionID: sessionID)
    }

    private func leaseUnlocked(sessionID: String) throws -> SessionLease? {
        try query(
            "SELECT owner_instance_id, heartbeat, expires_at FROM session_leases WHERE session_id = ? LIMIT 1;",
            values: [sessionID]
        ) { statement in
            SessionLease(
                sessionID: sessionID,
                ownerInstanceID: statement.string(0),
                heartbeat: Date(timeIntervalSince1970: statement.double(1)),
                expiresAt: Date(timeIntervalSince1970: statement.double(2))
            )
        }.first
    }

    private func ensureSessionColumns() throws {
        let columns = try query("PRAGMA table_info(sessions);") { $0.string(1) }
        if !columns.contains("target") {
            try execute("ALTER TABLE sessions ADD COLUMN target TEXT NOT NULL DEFAULT 'local';")
        }
        if !columns.contains("branch") {
            try execute("ALTER TABLE sessions ADD COLUMN branch TEXT NOT NULL DEFAULT '';")
        }
        if !columns.contains("worktree_path") {
            try execute("ALTER TABLE sessions ADD COLUMN worktree_path TEXT;")
        }
        if !columns.contains("baseline_revision") {
            try execute("ALTER TABLE sessions ADD COLUMN baseline_revision TEXT;")
        }
    }

    private func withLock<T>(_ operation: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try operation()
    }

    private func execute(_ sql: String, values: [Any] = []) throws {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        try bind(values, to: statement)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw RepositoryError.queryFailed(message: lastError) }
    }

    private func executeScript(_ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(database, sql, nil, nil, &error)
        defer {
            if let error { sqlite3_free(error) }
        }
        guard result == SQLITE_OK else {
            throw RepositoryError.queryFailed(message: error.map { String(cString: $0) } ?? lastError)
        }
    }

    private func query<T>(_ sql: String, values: [Any] = [], map: (SQLiteStatement) -> T) throws -> [T] {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        try bind(values, to: statement)
        var result: [T] = []
        while sqlite3_step(statement) == SQLITE_ROW { result.append(map(SQLiteStatement(statement))) }
        return result
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw RepositoryError.queryFailed(message: lastError) }
        return statement
    }

    private func bind(_ values: [Any], to statement: OpaquePointer) throws {
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            let result: Int32
            switch value {
            case let string as String:
                result = string.withCString { sqlite3_bind_text(statement, index, $0, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
            case let integer as Int:
                result = sqlite3_bind_int64(statement, index, sqlite3_int64(integer))
            case let double as Double:
                result = sqlite3_bind_double(statement, index, double)
            default:
                result = sqlite3_bind_null(statement, index)
            }
            guard result == SQLITE_OK else { throw RepositoryError.queryFailed(message: lastError) }
        }
    }

    private var lastError: String { String(cString: sqlite3_errmsg(database)) }
}

private struct SQLiteStatement {
    let statement: OpaquePointer

    init(_ statement: OpaquePointer) { self.statement = statement }
    func string(_ index: Int32) -> String { sqlite3_column_text(statement, index).map { String(cString: $0) } ?? "" }
    func stringOrNil(_ index: Int32) -> String? { isNull(index) ? nil : string(index) }
    func int(_ index: Int32) -> Int { Int(sqlite3_column_int64(statement, index)) }
    func double(_ index: Int32) -> Double { sqlite3_column_double(statement, index) }
    func isNull(_ index: Int32) -> Bool { sqlite3_column_type(statement, index) == SQLITE_NULL }
}

public enum RepositoryError: LocalizedError {
    case openFailed
    case sessionNotFound
    case queryFailed(message: String)

    public var errorDescription: String? {
        switch self {
        case .openFailed: "无法打开本地 Session 数据库"
        case .sessionNotFound: "找不到指定 Session"
        case let .queryFailed(message): "Session 数据库操作失败：\(message)"
        }
    }
}
