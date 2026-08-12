import Foundation

public protocol SessionOrchestrator: Sendable {
    func run(_ request: AgentRunRequest) -> AsyncThrowingStream<AgentEvent, Error>
    func resume(sessionID: String, approvalID: String, decision: ApprovalDecision) -> AsyncThrowingStream<AgentEvent, Error>
}

public final class NativeSessionOrchestrator: SessionOrchestrator, @unchecked Sendable {
    private let host: NativeAgentHost

    public init(host: NativeAgentHost) {
        self.host = host
    }

    public func run(_ request: AgentRunRequest) -> AsyncThrowingStream<AgentEvent, Error> {
        host.run(request)
    }

    public func resume(sessionID: String, approvalID: String, decision: ApprovalDecision) -> AsyncThrowingStream<AgentEvent, Error> {
        host.resume(sessionID: sessionID, approvalID: approvalID, decision: decision)
    }
}
