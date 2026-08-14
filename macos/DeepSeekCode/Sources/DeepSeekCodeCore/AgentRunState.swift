import CryptoKit
import Foundation

public enum AgentRunStatus: String, Codable, Equatable, Sendable {
    case idle
    case running
    case waitingApproval
    case completed
    case failed
    case cancelled
}

/// Immutable recovery anchor for an approval-gated tool call.  The resume
/// path validates this record before executing, so a stale UI action or a
/// changed run state cannot be redirected to a different command.
public struct ApprovalContinuation: Codable, Equatable, Sendable {
    public let approvalID: String
    public let sessionID: String
    public let commandID: String
    public let callID: String
    public let tool: String
    public let argumentsHash: String
    public let risk: CommandRisk
    public let checkpoint: String

    public init(
        approvalID: String,
        sessionID: String,
        commandID: String,
        callID: String,
        tool: String,
        argumentsJSON: String,
        risk: CommandRisk,
        checkpoint: String = "tool_execution"
    ) {
        self.approvalID = approvalID
        self.sessionID = sessionID
        self.commandID = commandID
        self.callID = callID
        self.tool = tool
        self.argumentsHash = Self.hash(argumentsJSON)
        self.risk = risk
        self.checkpoint = checkpoint
    }

    public func matches(sessionID: String, callID: String, tool: String, argumentsJSON: String) -> Bool {
        self.sessionID == sessionID
            && self.callID == callID
            && self.tool == tool
            && self.argumentsHash == Self.hash(argumentsJSON)
    }

    public static func hash(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

public struct PendingToolApproval: Codable, Equatable, Sendable {
    public let id: String
    public let toolCallID: String
    public let tool: String
    public let argumentsJSON: String
    /// Optional so older persisted AgentRunState records remain decodable.
    public let continuation: ApprovalContinuation?

    public init(id: String, toolCallID: String, tool: String, argumentsJSON: String, continuation: ApprovalContinuation? = nil) {
        self.id = id
        self.toolCallID = toolCallID
        self.tool = tool
        self.argumentsJSON = argumentsJSON
        self.continuation = continuation
    }
}

public struct AgentRunState: Codable, Equatable, Sendable {
    public let sessionID: String
    public let prompt: String
    public let mode: AgentMode
    public let model: String
    public var status: AgentRunStatus
    public var turn: Int
    public var pendingApproval: PendingToolApproval?
    public var messages: [ChatMessage]
    public var contextSummary: String
    public var taskContract: TaskContract?
    public var deliveryGateResult: DeliveryGateResult?

    public init(sessionID: String, prompt: String, mode: AgentMode, model: String, status: AgentRunStatus = .running, turn: Int = 0, pendingApproval: PendingToolApproval? = nil, messages: [ChatMessage] = [], contextSummary: String = "", taskContract: TaskContract? = nil, deliveryGateResult: DeliveryGateResult? = nil) {
        self.sessionID = sessionID
        self.prompt = prompt
        self.mode = mode
        self.model = model
        self.status = status
        self.turn = turn
        self.pendingApproval = pendingApproval
        self.messages = messages
        self.contextSummary = contextSummary
        self.taskContract = taskContract
        self.deliveryGateResult = deliveryGateResult
    }

    public mutating func requestApproval(approvalID: String, toolCallID: String = "", tool: String, argumentsJSON: String) {
        pendingApproval = PendingToolApproval(id: approvalID, toolCallID: toolCallID, tool: tool, argumentsJSON: argumentsJSON)
        status = .waitingApproval
    }

    public mutating func requestApproval(
        approvalID: String,
        commandID: String,
        toolCallID: String,
        tool: String,
        argumentsJSON: String,
        risk: CommandRisk,
        checkpoint: String = "tool_execution"
    ) {
        let continuation = ApprovalContinuation(
            approvalID: approvalID,
            sessionID: sessionID,
            commandID: commandID,
            callID: toolCallID,
            tool: tool,
            argumentsJSON: argumentsJSON,
            risk: risk,
            checkpoint: checkpoint
        )
        pendingApproval = PendingToolApproval(
            id: approvalID,
            toolCallID: toolCallID,
            tool: tool,
            argumentsJSON: argumentsJSON,
            continuation: continuation
        )
        status = .waitingApproval
    }

    public mutating func resolveApproval(decision: ApprovalDecision) {
        pendingApproval = nil
        status = decision == .deny ? .running : .running
    }

    public mutating func complete() {
        pendingApproval = nil
        status = .completed
    }

    public mutating func fail() {
        pendingApproval = nil
        status = .failed
    }
}
