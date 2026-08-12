import Foundation

public protocol EventSink: Sendable {
    func append(_ event: SessionEvent) async
}

public protocol RecoveryCoordinator: Sendable {
    func recover(sessionID: String) throws -> ProjectedSessionState?
}

public protocol ExtensionRuntime: Sendable {
    func prepare(sessionID: String, projectRoot: URL) async throws
    func finish(sessionID: String) async
}

public final class RepositoryEventSink: EventSink, @unchecked Sendable {
    private let repository: SessionRepository

    public init(repository: SessionRepository) {
        self.repository = repository
    }

    public func append(_ event: SessionEvent) async {
        try? repository.importEvent(event)
    }
}

public struct RepositoryRecoveryCoordinator: RecoveryCoordinator {
    public let repository: SessionRepository

    public init(repository: SessionRepository) {
        self.repository = repository
    }

    public func recover(sessionID: String) throws -> ProjectedSessionState? {
        guard let session = try repository.session(id: sessionID) else { return nil }
        var events = try repository.events(sessionID: sessionID)
        var activeToolCalls: [String: SessionEvent] = [:]
        for event in events {
            guard let callID = event.payload["callID"], !callID.isEmpty else { continue }
            switch event.type {
            case "tool_started": activeToolCalls[callID] = event
            case "tool_completed", "tool_blocked", "tool_indeterminate": activeToolCalls.removeValue(forKey: callID)
            default: continue
            }
        }
        for (callID, started) in activeToolCalls {
            let recovered = try repository.appendDurable(
                sessionID: sessionID,
                type: "tool_indeterminate",
                payload: [
                    "tool": started.payload["tool"] ?? "unknown",
                    "callID": callID,
                    "reason": "应用重启后工具执行结果未知"
                ],
                commandID: "recovery-indeterminate-\(callID)"
            )
            events.append(recovered)
        }
        // A relaunch never silently resumes an in-flight writer or child
        // worker. Mark durable worker records as attention-required so the UI
        // can offer an explicit continue/retry decision at a safe boundary.
        for var worker in try repository.agentWorkers(sessionID: sessionID) where worker.isLive {
            worker.state = .needsAttention
            worker.errorMessage = "应用重启后未自动恢复；请显式继续或重新发起"
            worker.updatedAt = Date()
            try repository.saveAgentWorker(worker)
            let recovered = try repository.appendDurable(
                sessionID: sessionID,
                type: "agent_worker_needs_attention",
                payload: ["workerID": worker.id, "reason": "应用重启后未自动恢复"]
            )
            events.append(recovered)
        }
        for var workerSession in try repository.workerSessions(parentSessionID: sessionID) where [.queued, .running].contains(workerSession.state) {
            workerSession.state = .needsAttention
            workerSession.updatedAt = Date()
            try repository.saveWorkerSession(workerSession)
            let recovered = try repository.appendDurable(
                sessionID: sessionID,
                type: "worker_session_needs_attention",
                payload: ["workerSessionID": workerSession.id, "reason": "应用重启后未自动恢复"]
            )
            events.append(recovered)
        }
        let projected = try SessionProjector.project(session: session, events: events)
        let hasIndeterminate = events.contains { event in
            event.type == "tool_indeterminate" || event.type == "ssh_tool_indeterminate" || event.type == "mcp_tool_indeterminate" || event.type == "github_indeterminate" || event.type == "github_push_indeterminate" || event.type == "github_pr_indeterminate"
        }
        var result = projected
        if (hasIndeterminate || events.contains(where: { $0.type == "agent_worker_needs_attention" || $0.type == "worker_session_needs_attention" })) && result.session.status != .delivered {
            result.session.status = .needsAttention
        }
        return result
    }
}

/// Minimal extension lifecycle coordinator. It centralizes project trust and
/// records lifecycle events; actual MCP/Hook work remains owned by their hosts.
public struct NativeExtensionRuntime: ExtensionRuntime {
    public let repository: SessionRepository?
    public let hooks: [HookDefinition]

    public init(repository: SessionRepository? = nil, hooks: [HookDefinition] = []) {
        self.repository = repository
        self.hooks = hooks
    }

    public func prepare(sessionID: String, projectRoot: URL) async throws {
        try repository?.append(sessionID: sessionID, type: "hook_session_start", payload: ["projectPath": projectRoot.path, "hookCount": "\(hooks.count)"])
        for hook in hooks where hook.lifecycle == .sessionStart && hook.enabled && hook.trusted {
            let result = try await HookRunner.execute(hook, payload: ["sessionID": sessionID, "projectPath": projectRoot.path])
            try repository?.append(sessionID: sessionID, type: "hook_completed", payload: ["hookID": hook.id, "decision": String(describing: result.decision)])
        }
    }

    public func finish(sessionID: String) async {
        try? repository?.append(sessionID: sessionID, type: "hook_session_end", payload: [:])
    }
}
