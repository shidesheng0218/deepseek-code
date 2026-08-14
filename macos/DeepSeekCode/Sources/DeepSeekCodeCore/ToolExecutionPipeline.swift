import CryptoKit
import Foundation

/// Immutable identity and policy context for one tool call.  Every entrypoint
/// (Agent, terminal command, MCP or future Control Plane command) uses this
/// same context so a tool result always has a durable causal chain.
public struct ToolInvocationContext: Sendable {
    public let sessionID: String
    public let commandID: String
    public let callID: String
    public let tool: RegisteredTool
    public let argumentsJSON: String
    public let workerID: String?
    public let projectID: String?
    public let deadline: Date
    public let traceID: String

    public init(
        sessionID: String,
        commandID: String,
        callID: String,
        tool: RegisteredTool,
        argumentsJSON: String,
        workerID: String? = nil,
        projectID: String? = nil,
        deadline: Date? = nil,
        traceID: String = UUID().uuidString
    ) {
        self.sessionID = sessionID
        self.commandID = commandID
        self.callID = callID
        self.tool = tool
        self.argumentsJSON = argumentsJSON
        self.workerID = workerID
        self.projectID = projectID
        self.deadline = deadline ?? Date().addingTimeInterval(Double(max(1, tool.timeoutMilliseconds)) / 1_000)
        self.traceID = traceID
    }
}

public struct ToolExecutionResult: Codable, Equatable, Sendable {
    public let output: String
    public let succeeded: Bool
    public let indeterminate: Bool
    public let evidenceID: String?
    public let outputHash: String
    public let retryable: Bool
    public let code: String?

    public init(
        output: String,
        succeeded: Bool,
        indeterminate: Bool,
        evidenceID: String?,
        outputHash: String,
        retryable: Bool,
        code: String? = nil
    ) {
        self.output = output
        self.succeeded = succeeded
        self.indeterminate = indeterminate
        self.evidenceID = evidenceID
        self.outputHash = outputHash
        self.retryable = retryable
        self.code = code
    }
}

/// The only durable lifecycle owner for an authorized tool invocation.
///
/// Policy, hooks and approval selection deliberately happen before
/// `executeAuthorized`; callers then enter this pipeline exactly once.  The
/// router below is intentionally pure and never creates competing records.
public final class ToolExecutionPipeline: @unchecked Sendable {
    private let repository: SessionRepository
    private let router: ToolHostRouter

    public init(repository: SessionRepository, router: ToolHostRouter) {
        self.repository = repository
        self.router = router
    }

    /// Convenience for already-authorized read-only callers and fixtures.
    @discardableResult
    public func execute(_ context: ToolInvocationContext) async throws -> ToolExecutionResult {
        try begin(context)
        return try await executeAuthorized(context)
    }

    /// Records the common request/schema stage once.  It is idempotent by
    /// `commandID + callID`, protecting reconnecting clients from duplicate
    /// requested events.
    public func begin(_ context: ToolInvocationContext) throws {
        guard validJSONObject(context.argumentsJSON) else {
            try append(
                context,
                type: "tool_failed",
                payload: ["code": "INVALID_ARGUMENTS", "message": "工具参数不是有效 JSON 对象"],
                suffix: "schema-failed"
            )
            throw ToolExecutionPipelineError.invalidArguments
        }
        try append(
            context,
            type: "tool_requested",
            payload: basePayload(context),
            suffix: "requested"
        )
        try? repository.recordToolInvocation(
            ToolInvocationRecord(
                id: context.callID,
                sessionID: context.sessionID,
                tool: context.tool.name,
                phase: .requested,
                risk: context.tool.risk
            ),
            payload: basePayload(context)
        )
    }

    public func recordApprovalRequested(_ context: ToolInvocationContext, approvalID: String) throws {
        try append(
            context,
            type: "approval_requested",
            payload: basePayload(context).merging([
                "approvalID": approvalID,
                "argumentsHash": digest(context.argumentsJSON)
            ], uniquingKeysWith: { _, right in right }),
            suffix: "approval-(approvalID)"
        )
    }

    public func recordBlocked(_ context: ToolInvocationContext, code: String = "POLICY_BLOCKED") throws {
        try append(
            context,
            type: "tool_blocked",
            payload: basePayload(context).merging(["code": code], uniquingKeysWith: { _, right in right }),
            suffix: "blocked"
        )
        try? repository.recordToolInvocation(
            ToolInvocationRecord(
                id: context.callID,
                sessionID: context.sessionID,
                tool: context.tool.name,
                phase: .failed,
                risk: context.tool.risk,
                succeeded: false
            ),
            payload: ["code": code]
        )
    }

    /// Executes an invocation that has passed hooks, policy and any required
    /// approval.  Timeouts/cancellation deliberately become indeterminate:
    /// no caller may silently retry a potentially side-effecting command.
    public func executeAuthorized(_ context: ToolInvocationContext) async throws -> ToolExecutionResult {
        try append(context, type: "tool_started", payload: basePayload(context), suffix: "started")
        try? repository.recordToolInvocation(
            ToolInvocationRecord(
                id: context.callID,
                sessionID: context.sessionID,
                tool: context.tool.name,
                phase: .started,
                risk: context.tool.risk
            ),
            payload: basePayload(context)
        )

        do {
            let output = try await withDeadline(context) {
                try await self.router.execute(
                    tool: context.tool,
                    argumentsJSON: context.argumentsJSON,
                    sessionID: context.sessionID
                )
            }
            let normalized = normalize(output)
            let evidenceID = UUID().uuidString
            try append(
                context,
                type: "evidence_recorded",
                payload: [
                    "id": evidenceID,
                    "kind": VerificationEvidenceClassifier.kind(tool: context.tool.name, argumentsJSON: context.argumentsJSON).rawValue,
                    "title": VerificationEvidenceClassifier.title(tool: context.tool.name, argumentsJSON: context.argumentsJSON),
                    "detail": normalized.succeeded ? "工具执行成功" : "工具执行失败",
                    "succeeded": normalized.succeeded ? "true" : "false",
                    "outputHash": normalized.outputHash,
                    "callID": context.callID
                ],
                suffix: "evidence"
            )
            try append(
                context,
                // A structured `{ok:false}` response means the host returned
                // a known result (for example a provider outage). It is a
                // completed invocation, not an unknown side effect. Reserve
                // `tool_failed` for transport/execution errors below.
                type: "tool_completed",
                payload: basePayload(context).merging([
                    "ok": normalized.succeeded ? "true" : "false",
                    "outputHash": normalized.outputHash,
                    "code": normalized.code ?? "",
                    "message": normalized.message ?? ""
                ], uniquingKeysWith: { _, right in right }),
                suffix: "completed"
            )
            try? repository.recordToolInvocation(
                ToolInvocationRecord(
                    id: context.callID,
                    sessionID: context.sessionID,
                    tool: context.tool.name,
                    phase: .completed,
                    risk: context.tool.risk,
                    succeeded: normalized.succeeded
                ),
                payload: ["outputHash": normalized.outputHash, "code": normalized.code ?? ""]
            )
            return ToolExecutionResult(
                output: output,
                succeeded: normalized.succeeded,
                indeterminate: false,
                evidenceID: evidenceID,
                outputHash: normalized.outputHash,
                retryable: context.tool.idempotent && !normalized.succeeded,
                code: normalized.code
            )
        } catch is CancellationError {
            return try indeterminate(context, code: "CANCELLED", message: "工具执行在安全结果前被取消")
        } catch ToolExecutionPipelineError.deadlineExceeded {
            return try indeterminate(context, code: "TIMEOUT", message: "工具执行超时，结果状态未知")
        } catch let error as UnifiedRuntimeError {
            // A host-level remote/validation failure is a known, completed
            // result. It must remain distinguishable from a timeout or a
            // cancellation, neither of which can be safely replayed.
            return try completedFailure(
                context,
                code: errorCode(error),
                message: SecretRedactor.redact(error.localizedDescription)
            )
        } catch {
            let output = jsonError(code: "TOOL_EXECUTION_FAILED", message: SecretRedactor.redact(error.localizedDescription))
            let outputHash = digest(output)
            try append(
                context,
                type: "tool_failed",
                payload: basePayload(context).merging([
                    "ok": "false",
                    "code": "TOOL_EXECUTION_FAILED",
                    "message": SecretRedactor.redact(error.localizedDescription),
                    "outputHash": outputHash
                ], uniquingKeysWith: { _, right in right }),
                suffix: "failed"
            )
            try? repository.recordToolInvocation(
                ToolInvocationRecord(
                    id: context.callID,
                    sessionID: context.sessionID,
                    tool: context.tool.name,
                    phase: .failed,
                    risk: context.tool.risk,
                    succeeded: false
                ),
                payload: ["code": "TOOL_EXECUTION_FAILED", "outputHash": outputHash]
            )
            return ToolExecutionResult(
                output: output,
                succeeded: false,
                indeterminate: false,
                evidenceID: nil,
                outputHash: outputHash,
                retryable: context.tool.idempotent,
                code: "TOOL_EXECUTION_FAILED"
            )
        }
    }

    private func indeterminate(_ context: ToolInvocationContext, code: String, message: String) throws -> ToolExecutionResult {
        let output = jsonError(code: code, message: message)
        let outputHash = digest(output)
        try append(
            context,
            type: "tool_indeterminate",
            payload: basePayload(context).merging([
                "code": code,
                "message": message,
                "outputHash": outputHash
            ], uniquingKeysWith: { _, right in right }),
            suffix: "indeterminate"
        )
        try? repository.recordToolInvocation(
            ToolInvocationRecord(
                id: context.callID,
                sessionID: context.sessionID,
                tool: context.tool.name,
                phase: .indeterminate,
                risk: context.tool.risk,
                succeeded: nil
            ),
            payload: ["code": code, "outputHash": outputHash]
        )
        return ToolExecutionResult(
            output: output,
            succeeded: false,
            indeterminate: true,
            evidenceID: nil,
            outputHash: outputHash,
            retryable: false,
            code: code
        )
    }

    private func completedFailure(_ context: ToolInvocationContext, code: String, message: String) throws -> ToolExecutionResult {
        let output = jsonError(code: code, message: message)
        let outputHash = digest(output)
        let evidenceID = UUID().uuidString
        try append(
            context,
            type: "evidence_recorded",
            payload: [
                "id": evidenceID,
                "kind": VerificationEvidenceClassifier.kind(tool: context.tool.name, argumentsJSON: context.argumentsJSON).rawValue,
                "title": VerificationEvidenceClassifier.title(tool: context.tool.name, argumentsJSON: context.argumentsJSON),
                "detail": "工具已返回失败结果",
                "succeeded": "false",
                "outputHash": outputHash,
                "callID": context.callID
            ],
            suffix: "evidence"
        )
        try append(
            context,
            type: "tool_completed",
            payload: basePayload(context).merging([
                "ok": "false",
                "code": code,
                "message": message,
                "outputHash": outputHash
            ], uniquingKeysWith: { _, right in right }),
            suffix: "completed"
        )
        try? repository.recordToolInvocation(
            ToolInvocationRecord(
                id: context.callID,
                sessionID: context.sessionID,
                tool: context.tool.name,
                phase: .completed,
                risk: context.tool.risk,
                succeeded: false
            ),
            payload: ["code": code, "outputHash": outputHash]
        )
        return ToolExecutionResult(
            output: output,
            succeeded: false,
            indeterminate: false,
            evidenceID: evidenceID,
            outputHash: outputHash,
            retryable: context.tool.idempotent,
            code: code
        )
    }

    private func withDeadline<T: Sendable>(_ context: ToolInvocationContext, operation: @escaping @Sendable () async throws -> T) async throws -> T {
        let remaining = max(0.001, context.deadline.timeIntervalSinceNow)
        return try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
                throw ToolExecutionPipelineError.deadlineExceeded
            }
            defer { group.cancelAll() }
            guard let value = try await group.next() else { throw ToolExecutionPipelineError.deadlineExceeded }
            return value
        }
    }

    private func append(_ context: ToolInvocationContext, type: String, payload: [String: String], suffix: String) throws {
        _ = try repository.appendDurable(
            sessionID: context.sessionID,
            type: type,
            payload: payload,
            commandID: "pipeline-\(context.commandID)-\(context.callID)-\(suffix)",
            causationID: context.callID,
            correlationID: context.traceID
        )
    }

    private func basePayload(_ context: ToolInvocationContext) -> [String: String] {
        var payload: [String: String] = [
            "tool": context.tool.name,
            "callID": context.callID,
            "commandID": context.commandID,
            "risk": "L\(context.tool.risk.rawValue)",
            "traceID": context.traceID
        ]
        if let workerID = context.workerID { payload["workerID"] = workerID }
        if let projectID = context.projectID { payload["projectID"] = projectID }
        return payload
    }

    private func validJSONObject(_ raw: String) -> Bool {
        guard let data = raw.data(using: .utf8),
              let value = try? JSONSerialization.jsonObject(with: data) else { return false }
        return value is [String: Any]
    }

    private func normalize(_ output: String) -> (succeeded: Bool, outputHash: String, code: String?, message: String?) {
        let outputHash = digest(output)
        guard let data = output.data(using: .utf8),
              let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return (true, outputHash, nil, nil)
        }
        let succeeded = value["ok"] as? Bool != false
        return (
            succeeded,
            outputHash,
            value["code"] as? String,
            SecretRedactor.redact(value["message"] as? String ?? value["error"] as? String ?? "")
        )
    }

    private func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func jsonError(code: String, message: String) -> String {
        let value: [String: String] = ["ok": "false", "code": code, "message": message]
        let data = (try? JSONSerialization.data(withJSONObject: value)) ?? Data("{\"ok\":false}".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    private func errorCode(_ error: UnifiedRuntimeError) -> String {
        switch error {
        case .toolHostUnavailable: "TOOL_HOST_UNAVAILABLE"
        case .invalidArguments: "INVALID_ARGUMENTS"
        case .remote: "REMOTE_ERROR"
        case .hookTimedOut: "HOOK_TIMEOUT"
        }
    }
}

public enum ToolExecutionPipelineError: LocalizedError, Sendable {
    case invalidArguments
    case deadlineExceeded

    public var errorDescription: String? {
        switch self {
        case .invalidArguments: "工具参数不是有效 JSON 对象"
        case .deadlineExceeded: "工具执行超时"
        }
    }
}
