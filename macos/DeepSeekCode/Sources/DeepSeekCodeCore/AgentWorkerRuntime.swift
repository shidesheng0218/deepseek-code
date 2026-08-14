import Foundation

/// A worker is the user-facing unit of background Agent work. It is separate
/// from a Session so one Session can expose a main Agent plus read-only workers
/// later without giving those workers write access.
public enum AgentWorkerKind: String, Codable, CaseIterable, Equatable, Sendable {
    case main
    case explore
    case browser
    case review
    case ci

    public var title: String {
        switch self {
        case .main: "主 Agent"
        case .explore: "Explore"
        case .browser: "Browser"
        case .review: "Review"
        case .ci: "CI"
        }
    }

    public var systemImage: String {
        switch self {
        case .main: "sparkles"
        case .explore: "magnifyingglass"
        case .browser: "globe"
        case .review: "checkmark.shield"
        case .ci: "checkmark.circle"
        }
    }
}

/// Workers are child sessions with a deliberately smaller effect surface.
/// Keeping this policy independent from the main PermissionBroker prevents a
/// review/browser/explore worker from inheriting write access by accident.
public enum AgentWorkerPolicy {
    public static func allows(_ effect: ToolEffect, for kind: AgentWorkerKind) -> Bool {
        guard kind != .main else { return true }
        switch effect {
        case .readOnly, .browserRead, .computerRead:
            return true
        case .workspaceWrite, .process, .gitWrite, .network, .externalWrite, .browserAct, .computerAct:
            return false
        }
    }
}

public enum AgentWorkerState: String, Codable, CaseIterable, Sendable {
    case queued
    case running
    case waitingApproval
    case needsInput
    case pausing
    case paused
    case completed
    case failed
    case stopped
    case needsAttention

    public var title: String {
        switch self {
        case .queued: "排队中"
        case .running: "运行中"
        case .waitingApproval: "等待审批"
        case .needsInput: "需要输入"
        case .pausing: "即将暂停"
        case .paused: "已暂停"
        case .completed: "已完成"
        case .failed: "失败"
        case .stopped: "已停止"
        case .needsAttention: "需要处理"
        }
    }

    public var colorToken: String {
        switch self {
        case .queued, .paused: "secondary"
        case .running: "mint"
        case .waitingApproval, .needsInput, .pausing: "amber"
        case .completed: "green"
        case .failed, .needsAttention: "red"
        case .stopped: "secondary"
        }
    }
}

public struct AgentWorkerCheckpoint: Codable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let detail: String
    public let sequence: Int
    public let createdAt: Date

    public init(id: String = UUID().uuidString, title: String, detail: String, sequence: Int = 0, createdAt: Date = Date()) {
        self.id = id
        self.title = title
        self.detail = detail
        self.sequence = sequence
        self.createdAt = createdAt
    }
}

public struct WorkerResultEnvelope: Codable, Equatable, Sendable {
    public let workerID: String
    public let sessionID: String
    public let summary: String
    public let evidenceIDs: [String]
    public let warnings: [String]
    public let inputHash: String
    public let outputHash: String
    public let errorMessage: String?
    public let createdAt: Date

    public init(workerID: String, sessionID: String, summary: String, evidenceIDs: [String] = [], warnings: [String] = [], inputHash: String = "", outputHash: String = "", errorMessage: String? = nil, createdAt: Date = Date()) {
        self.workerID = workerID
        self.sessionID = sessionID
        self.summary = summary
        self.evidenceIDs = evidenceIDs
        self.warnings = warnings
        self.inputHash = inputHash
        self.outputHash = outputHash
        self.errorMessage = errorMessage
        self.createdAt = createdAt
    }
}

public struct WorkerSessionContract: Codable, Equatable, Sendable {
    public let parentSessionID: String
    public let workerKind: AgentWorkerKind
    public let objective: String
    public let allowedEffects: [ToolEffect]
    public let maxOutputBytes: Int
    public let budget: SessionBudget

    public init(
        parentSessionID: String,
        workerKind: AgentWorkerKind,
        objective: String,
        allowedEffects: [ToolEffect]? = nil,
        maxOutputBytes: Int = 128_000,
        budget: SessionBudget = SessionBudget()
    ) {
        self.parentSessionID = parentSessionID
        self.workerKind = workerKind
        self.objective = objective
        self.allowedEffects = allowedEffects ?? [.readOnly, .browserRead, .computerRead]
        self.maxOutputBytes = max(1_024, maxOutputBytes)
        self.budget = budget
    }
}

public protocol ChildAgentExecutionDriver: Sendable {
    func execute(
        contract: WorkerSessionContract,
        sessionID: String,
        workerID: String,
        workerSessionID: String
    ) async throws -> WorkerResultEnvelope
}

public protocol ChildAgentRuntime: Sendable {
    func create(parentSessionID: String, workerID: String, contract: WorkerSessionContract) async throws -> WorkerSessionRecord
    func start(workerSessionID: String) async throws
    func cancel(workerSessionID: String) async throws
    func collect(workerSessionID: String) async throws -> WorkerResultEnvelope
    func adopt(workerSessionID: String) async throws
}

public enum ChildAgentRuntimeError: LocalizedError, Sendable {
    case notFound
    case invalidState
    case failed(String)
    case timedOut

    public var errorDescription: String? {
        switch self {
        case .notFound: "找不到 Child Agent Session"
        case .invalidState: "Child Agent 当前状态不允许执行该操作"
        case let .failed(message): "Child Agent 执行失败：\(message)"
        case .timedOut: "Child Agent 等待结果超时"
        }
    }
}

/// Durable child-session runner. It keeps execution state in SQLite and
/// limits the executable surface to the injected read-only driver.
public actor DurableChildAgentRuntime: ChildAgentRuntime {
    private let repository: SessionRepository
    private let coordinator: WorkerSessionCoordinator
    private let driver: any ChildAgentExecutionDriver
    private var tasks: [String: Task<WorkerResultEnvelope, Error>] = [:]

    public init(repository: SessionRepository, driver: any ChildAgentExecutionDriver) {
        self.repository = repository
        self.coordinator = WorkerSessionCoordinator(repository: repository)
        self.driver = driver
    }

    public func create(parentSessionID: String, workerID: String, contract: WorkerSessionContract) throws -> WorkerSessionRecord {
        try coordinator.create(parentSessionID: parentSessionID, workerID: workerID, contract: contract)
    }

    public func start(workerSessionID: String) async throws {
        guard let record = try repository.workerSession(id: workerSessionID) else { throw ChildAgentRuntimeError.notFound }
        guard record.state == .queued else { throw ChildAgentRuntimeError.invalidState }
        _ = try coordinator.transition(id: workerSessionID, state: .running)
        let taskGraph = WorkerTaskGraph(repository: repository)
        let task = Task { [driver, coordinator, taskGraph] in
            do {
                let result = try await driver.execute(
                    contract: record.contract,
                    sessionID: record.parentSessionID,
                    workerID: record.workerID,
                    workerSessionID: record.id
                )
                _ = try coordinator.storeResult(id: record.id, result: result)
                _ = try? taskGraph.publish(WorkerTaskMessage(
                    parentSessionID: record.parentSessionID,
                    workerSessionID: record.id,
                    workerID: record.workerID,
                    kind: .evidence,
                    summary: result.summary,
                    evidenceIDs: result.evidenceIDs,
                    confidence: result.errorMessage == nil ? 0.8 : 0.2
                ))
                return result
            } catch is CancellationError {
                _ = try? coordinator.transition(id: record.id, state: .stopped)
                throw CancellationError()
            } catch {
                _ = try? coordinator.transition(id: record.id, state: .failed)
                throw error
            }
        }
        tasks[workerSessionID] = task
    }

    public func cancel(workerSessionID: String) async throws {
        guard let record = try repository.workerSession(id: workerSessionID) else { throw ChildAgentRuntimeError.notFound }
        tasks[workerSessionID]?.cancel()
        tasks[workerSessionID] = nil
        if record.state == .queued || record.state == .running {
            _ = try coordinator.transition(id: workerSessionID, state: .stopped)
        }
    }

    public func collect(workerSessionID: String) async throws -> WorkerResultEnvelope {
        guard let task = tasks[workerSessionID] else {
            guard let record = try repository.workerSession(id: workerSessionID), let result = record.result else {
                throw ChildAgentRuntimeError.notFound
            }
            return result
        }
        do {
            let result = try await withThrowingTaskGroup(of: WorkerResultEnvelope.self) { group in
                group.addTask { try await task.value }
                group.addTask {
                    try await Task.sleep(nanoseconds: 120_000_000_000)
                    throw ChildAgentRuntimeError.timedOut
                }
                guard let first = try await group.next() else { throw ChildAgentRuntimeError.notFound }
                group.cancelAll()
                return first
            }
            tasks[workerSessionID] = nil
            return result
        } catch let error as ChildAgentRuntimeError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw ChildAgentRuntimeError.failed(error.localizedDescription)
        }
    }

    public func adopt(workerSessionID: String) throws {
        guard let record = try repository.workerSession(id: workerSessionID), let result = record.result else {
            throw ChildAgentRuntimeError.notFound
        }
        _ = try coordinator.adopt(id: workerSessionID, result: result)
    }
}

public enum WorkerSessionState: String, Codable, CaseIterable, Sendable {
    case queued
    case running
    case awaitingAdoption
    case completed
    case failed
    case stopped
    case needsAttention
}

public struct WorkerSessionRecord: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let parentSessionID: String
    public let workerID: String
    public let contract: WorkerSessionContract
    public var state: WorkerSessionState
    public var cursorSequence: Int
    public var result: WorkerResultEnvelope?
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: String = UUID().uuidString,
        parentSessionID: String,
        workerID: String,
        contract: WorkerSessionContract,
        state: WorkerSessionState = .queued,
        cursorSequence: Int = 0,
        result: WorkerResultEnvelope? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.parentSessionID = parentSessionID
        self.workerID = workerID
        self.contract = contract
        self.state = state
        self.cursorSequence = cursorSequence
        self.result = result
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

/// Durable coordinator for read-only child sessions. Workers can produce
/// evidence, but only the parent supervisor may adopt that evidence or write
/// to the workspace.
public final class WorkerSessionCoordinator: @unchecked Sendable {
    private let repository: SessionRepository

    public init(repository: SessionRepository) {
        self.repository = repository
    }

    @discardableResult
    public func create(parentSessionID: String, workerID: String, contract: WorkerSessionContract) throws -> WorkerSessionRecord {
        guard contract.parentSessionID == parentSessionID else {
            throw WorkerSessionError.parentMismatch
        }
        guard contract.workerKind != .main else { throw WorkerSessionError.mainAgentCannotBeChild }
        guard contract.allowedEffects.allSatisfy({ AgentWorkerPolicy.allows($0, for: contract.workerKind) }) else {
            throw WorkerSessionError.effectNotAllowed
        }
        let record = WorkerSessionRecord(parentSessionID: parentSessionID, workerID: workerID, contract: contract)
        try repository.saveWorkerSession(record)
        try repository.appendDurable(
            sessionID: parentSessionID,
            type: "worker_session_created",
            payload: ["workerSessionID": record.id, "workerID": workerID, "workerKind": contract.workerKind.rawValue]
        )
        return record
    }

    public func transition(id: String, state: WorkerSessionState, cursorSequence: Int? = nil) throws -> WorkerSessionRecord {
        guard var record = try repository.workerSession(id: id) else { throw WorkerSessionError.notFound }
        record.state = state
        if let cursorSequence { record.cursorSequence = max(record.cursorSequence, cursorSequence) }
        record.updatedAt = Date()
        try repository.saveWorkerSession(record)
        try repository.appendDurable(
            sessionID: record.parentSessionID,
            type: "worker_session_\(state.rawValue)",
            payload: ["workerSessionID": id, "workerID": record.workerID, "cursorSequence": String(record.cursorSequence)]
        )
        return record
    }

    public func adopt(id: String, result: WorkerResultEnvelope) throws -> WorkerSessionRecord {
        guard let record = try repository.workerSession(id: id) else { throw WorkerSessionError.notFound }
        guard record.state == .awaitingAdoption || record.result == nil else {
            throw WorkerSessionError.alreadyAdopted
        }
        return try finalizeAdoption(record: record, result: result)
    }

    /// Stores a completed read-only result without making it part of the
    /// parent Agent context. Only the Supervisor's explicit `adopt` action
    /// records `worker_evidence_adopted` and changes it to completed.
    public func storeResult(id: String, result: WorkerResultEnvelope) throws -> WorkerSessionRecord {
        guard var record = try repository.workerSession(id: id) else { throw WorkerSessionError.notFound }
        guard result.workerID == record.workerID, result.sessionID == record.parentSessionID else {
            throw WorkerSessionError.resultMismatch
        }
        guard !result.evidenceIDs.isEmpty || !result.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw WorkerSessionError.emptyResult
        }
        record.result = result
        record.state = result.errorMessage == nil ? .awaitingAdoption : .failed
        record.updatedAt = Date()
        try repository.saveWorkerSession(record)
        try repository.appendDurable(
            sessionID: record.parentSessionID,
            type: "worker_result_ready",
            payload: [
                "workerSessionID": id,
                "workerID": record.workerID,
                "evidenceIDs": result.evidenceIDs.joined(separator: ","),
                "outputHash": result.outputHash
            ]
        )
        return record
    }

    private func finalizeAdoption(record: WorkerSessionRecord, result: WorkerResultEnvelope) throws -> WorkerSessionRecord {
        guard result.workerID == record.workerID, result.sessionID == record.parentSessionID else {
            throw WorkerSessionError.resultMismatch
        }
        guard !result.evidenceIDs.isEmpty || !result.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw WorkerSessionError.emptyResult
        }
        var updated = record
        updated.result = result
        updated.state = result.errorMessage == nil ? .completed : .failed
        updated.updatedAt = Date()
        try repository.saveWorkerSession(updated)
        try repository.appendDurable(
            sessionID: updated.parentSessionID,
            type: "worker_evidence_adopted",
            payload: [
                "workerSessionID": updated.id,
                "workerID": updated.workerID,
                "evidenceIDs": result.evidenceIDs.joined(separator: ","),
                "outputHash": result.outputHash
            ]
        )
        return updated
    }
}

public enum WorkerSessionError: LocalizedError, Sendable {
    case parentMismatch
    case mainAgentCannotBeChild
    case notFound
    case resultMismatch
    case emptyResult
    case effectNotAllowed
    case alreadyAdopted

    public var errorDescription: String? {
        switch self {
        case .parentMismatch: "Worker Session 不属于当前父 Session"
        case .mainAgentCannotBeChild: "主 Agent 不能作为只读 Child Session"
        case .notFound: "找不到 Worker Session"
        case .resultMismatch: "Worker 结果与 Session 身份不匹配"
        case .emptyResult: "Worker 必须返回摘要或 Evidence"
        case .effectNotAllowed: "只读 Worker 不能声明写入、网络或外部副作用"
        case .alreadyAdopted: "Worker 结果已经被采纳"
        }
    }
}

public struct AgentWorkerRecord: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let sessionID: String
    public let kind: AgentWorkerKind
    public let title: String
    public var state: AgentWorkerState
    public var prompt: String
    public var detail: String
    public var checkpoint: AgentWorkerCheckpoint?
    public var pendingReply: String?
    public var startedAt: Date?
    public var updatedAt: Date
    public var completedAt: Date?
    public var errorMessage: String?
    public var result: WorkerResultEnvelope?

    public init(id: String = UUID().uuidString, sessionID: String, kind: AgentWorkerKind = .main, title: String = "主 Agent", state: AgentWorkerState = .queued, prompt: String = "", detail: String = "等待开始", checkpoint: AgentWorkerCheckpoint? = nil, pendingReply: String? = nil, startedAt: Date? = nil, updatedAt: Date = Date(), completedAt: Date? = nil, errorMessage: String? = nil, result: WorkerResultEnvelope? = nil) {
        self.id = id
        self.sessionID = sessionID
        self.kind = kind
        self.title = title
        self.state = state
        self.prompt = prompt
        self.detail = detail
        self.checkpoint = checkpoint
        self.pendingReply = pendingReply
        self.startedAt = startedAt
        self.updatedAt = updatedAt
        self.completedAt = completedAt
        self.errorMessage = errorMessage
        self.result = result
    }

    public var isLive: Bool {
        [.queued, .running, .waitingApproval, .needsInput, .pausing].contains(state)
    }
}

/// Thread-safe in-process registry backed by SQLite. The registry is a
/// projection, not a second source of truth: every state change is also
/// appended to the Session event stream by WorkspaceStore.
public final class AgentWorkerRegistry: @unchecked Sendable {
    private let repository: SessionRepository?
    private let lock = NSLock()
    private var recordsByID: [String: AgentWorkerRecord] = [:]

    public init(repository: SessionRepository? = nil) {
        self.repository = repository
        if let repository {
            recordsByID = Dictionary(uniqueKeysWithValues: (try? repository.allAgentWorkers())?.map { ($0.id, $0) } ?? [])
        }
    }

    public func records(sessionID: String? = nil) -> [AgentWorkerRecord] {
        lock.lock(); defer { lock.unlock() }
        return recordsByID.values
            .filter { sessionID == nil || $0.sessionID == sessionID }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    @discardableResult
    public func create(sessionID: String, prompt: String, kind: AgentWorkerKind = .main, title: String? = nil) -> AgentWorkerRecord {
        let record = AgentWorkerRecord(sessionID: sessionID, kind: kind, title: title ?? kind.title, prompt: prompt)
        upsert(record)
        return record
    }

    @discardableResult
    public func update(_ record: AgentWorkerRecord) -> AgentWorkerRecord {
        var next = record
        next.updatedAt = Date()
        upsert(next)
        return next
    }

    @discardableResult
    public func transition(id: String, state: AgentWorkerState, detail: String? = nil, checkpoint: AgentWorkerCheckpoint? = nil, errorMessage: String? = nil) -> AgentWorkerRecord? {
        lock.lock()
        guard var record = recordsByID[id] else { lock.unlock(); return nil }
        record.state = state
        if let detail { record.detail = detail }
        if let checkpoint { record.checkpoint = checkpoint }
        if let errorMessage { record.errorMessage = errorMessage }
        if record.startedAt == nil && [.running, .waitingApproval, .needsInput, .pausing].contains(state) { record.startedAt = Date() }
        if [.completed, .failed, .stopped, .needsAttention].contains(state) { record.completedAt = Date() }
        record.updatedAt = Date()
        recordsByID[id] = record
        lock.unlock()
        try? repository?.saveAgentWorker(record)
        return record
    }

    public func setPendingReply(id: String, reply: String?) {
        lock.lock()
        guard var record = recordsByID[id] else { lock.unlock(); return }
        record.pendingReply = reply
        record.updatedAt = Date()
        recordsByID[id] = record
        lock.unlock()
        try? repository?.saveAgentWorker(record)
    }

    public func setResult(id: String, result: WorkerResultEnvelope) {
        lock.lock()
        guard var record = recordsByID[id] else { lock.unlock(); return }
        record.result = result
        record.updatedAt = Date()
        recordsByID[id] = record
        lock.unlock()
        try? repository?.saveAgentWorker(record)
    }

    private func upsert(_ record: AgentWorkerRecord) {
        lock.lock()
        recordsByID[record.id] = record
        lock.unlock()
        try? repository?.saveAgentWorker(record)
    }
}
