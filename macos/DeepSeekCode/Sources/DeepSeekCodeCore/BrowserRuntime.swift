import Foundation

public actor BrowserAutomationBridge: ToolHost {
    public static let shared = BrowserAutomationBridge()

    public typealias Handler = @Sendable (RegisteredTool, String, String) async throws -> String
    private var handler: Handler?

    private init() {}

    public func install(handler: @escaping Handler) {
        self.handler = handler
    }

    public func execute(tool: RegisteredTool, argumentsJSON: String, sessionID: String) async throws -> String {
        guard let handler else {
            throw UnifiedRuntimeError.remote("Browser 尚未初始化，请先打开 Browser 面板")
        }
        return try await handler(tool, argumentsJSON, sessionID)
    }

    public func cancel(invocationID: String) async {}
}
