import Foundation

public struct RegisteredTool: Codable, Equatable, Identifiable, Sendable {
    public var id: String { name }
    public let name: String
    public let description: String
    public let parameters: JSONValue
    public let effect: ToolEffect
    public let risk: CommandRisk
    public let timeoutMilliseconds: Int
    public let maxOutputBytes: Int
    public let idempotent: Bool
    public let supportsCancellation: Bool

    public init(
        name: String,
        description: String,
        parameters: JSONValue,
        effect: ToolEffect,
        risk: CommandRisk,
        timeoutMilliseconds: Int,
        maxOutputBytes: Int,
        idempotent: Bool,
        supportsCancellation: Bool
    ) {
        self.name = name
        self.description = description
        self.parameters = parameters
        self.effect = effect
        self.risk = risk
        self.timeoutMilliseconds = timeoutMilliseconds
        self.maxOutputBytes = maxOutputBytes
        self.idempotent = idempotent
        self.supportsCancellation = supportsCancellation
    }

    public func schema(modelName: String? = nil) -> ToolSchema {
        ToolSchema(name: modelName ?? name, description: description, parameters: parameters)
    }
}

public enum ToolInvocationPhase: String, Codable, CaseIterable, Sendable {
    case requested
    case approved
    case started
    case completed
    case failed
    case indeterminate
}

public struct ToolInvocationRecord: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let sessionID: String
    public let tool: String
    public let phase: ToolInvocationPhase
    public let risk: CommandRisk
    public let succeeded: Bool?
    public let createdAt: Date

    public init(
        id: String = UUID().uuidString,
        sessionID: String,
        tool: String,
        phase: ToolInvocationPhase,
        risk: CommandRisk,
        succeeded: Bool? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.sessionID = sessionID
        self.tool = tool
        self.phase = phase
        self.risk = risk
        self.succeeded = succeeded
        self.createdAt = createdAt
    }
}

public protocol ToolHost: Sendable {
    func execute(tool: RegisteredTool, argumentsJSON: String, sessionID: String) async throws -> String
    func cancel(invocationID: String) async
}

public final class ToolRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var tools: [String: RegisteredTool] = [:]
    private var cachedSchemas: [ToolSchema]?
    private var cachedNameMap: ToolNameMap?

    public init(_ initialTools: [RegisteredTool] = []) {
        initialTools.forEach { tools[$0.name] = $0 }
    }

    public func register(_ tool: RegisteredTool) {
        lock.lock()
        tools[tool.name] = tool
        cachedSchemas = nil
        cachedNameMap = nil
        lock.unlock()
    }

    public func tool(named name: String) -> RegisteredTool? {
        lock.lock()
        defer { lock.unlock() }
        if let tool = tools[name] { return tool }
        return resolvedNameMapLocked().modelToInternal[name].flatMap { tools[$0] }
    }

    public func allTools() -> [RegisteredTool] {
        lock.lock()
        defer { lock.unlock() }
        return tools.values.sorted { $0.name < $1.name }
    }

    public func schemas() -> [ToolSchema] {
        lock.lock()
        defer { lock.unlock() }
        if let cachedSchemas { return cachedSchemas }
        let snapshot = tools.values.sorted { $0.name < $1.name }
        let map = resolvedNameMapLocked()
        let schemas = snapshot.map { tool in
            tool.schema(modelName: map.internalToModel[tool.name] ?? tool.name)
        }
        cachedSchemas = schemas
        return schemas
    }

    public func modelName(for internalName: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return resolvedNameMapLocked().internalToModel[internalName]
    }

    private struct ToolNameMap {
        var internalToModel: [String: String]
        var modelToInternal: [String: String]
    }

    private func resolvedNameMapLocked() -> ToolNameMap {
        if let cachedNameMap { return cachedNameMap }
        let map = toolNameMap(from: Array(tools.values))
        cachedNameMap = map
        return map
    }

    private func toolNameMap(from tools: [RegisteredTool]) -> ToolNameMap {
        let ordered = tools.sorted { $0.name < $1.name }
        var internalToModel: [String: String] = [:]
        var modelToInternal: [String: String] = [:]
        for tool in ordered {
            var candidate = ToolNameCodec.modelSafeName(from: tool.name)
            if candidate.isEmpty { candidate = "tool" }
            if candidate.count > 64 { candidate = String(candidate.prefix(64)) }
            var suffix = 2
            while modelToInternal[candidate] != nil || candidate.count > 64 {
                let base = String(ToolNameCodec.modelSafeName(from: tool.name).prefix(max(1, 64 - ("_\(suffix)".count))))
                candidate = base.isEmpty ? "tool_\(suffix)" : "\(base)_\(suffix)"
                suffix += 1
            }
            internalToModel[tool.name] = candidate
            modelToInternal[candidate] = tool.name
        }
        return ToolNameMap(internalToModel: internalToModel, modelToInternal: modelToInternal)
    }
}
