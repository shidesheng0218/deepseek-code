import Foundation

public enum AgentRunStatus: String, Codable, Equatable, Sendable {
    case idle
    case running
    case waitingApproval
    case completed
    case failed
    case cancelled
}

public struct PendingToolApproval: Codable, Equatable, Sendable {
    public let id: String
    public let toolCallID: String
    public let tool: String
    public let argumentsJSON: String

    public init(id: String, toolCallID: String, tool: String, argumentsJSON: String) {
        self.id = id
        self.toolCallID = toolCallID
        self.tool = tool
        self.argumentsJSON = argumentsJSON
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
