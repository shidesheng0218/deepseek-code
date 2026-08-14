import Foundation

public enum MCPTransportKind: String, Codable, CaseIterable, Sendable {
    case stdio
    case streamableHTTP = "streamable-http"
}

public struct MCPServerRecord: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public var name: String
    public var transportKind: MCPTransportKind
    public var trusted: Bool
    public var enabled: Bool
    public var authorizationReference: String?

    public init(id: String, name: String, transportKind: MCPTransportKind, trusted: Bool = false, enabled: Bool = true, authorizationReference: String? = nil) {
        self.id = id
        self.name = name
        self.transportKind = transportKind
        self.trusted = trusted
        self.enabled = enabled
        self.authorizationReference = authorizationReference
    }
}

public enum MCPHealth: String, Codable, Sendable {
    case unknown
    case connecting
    case healthy
    case degraded
    case unavailable
}

public protocol MCPManager: Sendable {
    func connect(serverID: String, transport: any MCPTransport) async throws
    func discoverTools(serverID: String) async throws -> [MCPToolDescriptor]
    func call(serverID: String, tool: String, argumentsJSON: String, sessionID: String) async throws -> String
    func health(serverID: String) async -> MCPHealth
    func disconnect(serverID: String) async
}

/// Actor-owned MCP lifecycle. It performs initialize/tools/list once, registers
/// discovered tools in the same ToolRegistry and keeps health per server.
public actor DefaultMCPManager: MCPManager {
    private let registry: ToolRegistry
    private let manifests: [String: HostCapabilityManifest]
    /// MCP is an extension transport, not a second execution authority. The
    /// manager registers its pure host with this router, then invokes it only
    /// through the shared durable pipeline.
    private let router: ToolHostRouter?
    private let pipeline: ToolExecutionPipeline?
    private var transports: [String: any MCPTransport] = [:]
    private var hosts: [String: MCPToolHost] = [:]
    private var descriptors: [String: [MCPToolDescriptor]] = [:]
    private var healthStates: [String: MCPHealth] = [:]

    public init(
        registry: ToolRegistry,
        manifests: [String: HostCapabilityManifest] = [:],
        router: ToolHostRouter? = nil,
        pipeline: ToolExecutionPipeline? = nil
    ) {
        self.registry = registry
        self.manifests = manifests
        self.router = router
        self.pipeline = pipeline
    }

    public func connect(serverID: String, transport: any MCPTransport) async throws {
        healthStates[serverID] = .connecting
        do {
            transports[serverID] = transport
            let initialize = MCPJSONRPCRequest(id: 1, method: "initialize", params: .object([
                "protocolVersion": .string("2025-06-18"),
                "capabilities": .objectSchema(),
                "clientInfo": .object(["name": .string("DeepSeek Code"), "version": .string("1.0")])
            ]))
            _ = try await transport.request(initialize)
            let initialized = MCPJSONRPCRequest(id: 2, method: "notifications/initialized", params: nil)
            _ = try? await transport.request(initialized)
            let tools = try await transport.request(MCPJSONRPCRequest(id: 3, method: "tools/list", params: nil)).tools
            descriptors[serverID] = tools
            let host = MCPToolHost(serverID: serverID, transport: transport, manifest: manifests[serverID])
            hosts[serverID] = host
            for descriptor in tools {
                registry.register(MCPToolRegistration.make(serverID: serverID, descriptor: descriptor))
            }
            router?.register(host: host, forPrefix: "mcp.\(serverID).")
            healthStates[serverID] = .healthy
        } catch {
            healthStates[serverID] = .unavailable
            transports[serverID] = nil
            hosts[serverID] = nil
            throw error
        }
    }

    public func discoverTools(serverID: String) async throws -> [MCPToolDescriptor] {
        guard let values = descriptors[serverID] else { throw MCPRuntimeError.invalidConfiguration }
        return values
    }

    public func call(serverID: String, tool: String, argumentsJSON: String, sessionID: String) async throws -> String {
        try await call(
            serverID: serverID,
            tool: tool,
            argumentsJSON: argumentsJSON,
            sessionID: sessionID,
            commandID: "mcp-call-\(UUID().uuidString)",
            callID: UUID().uuidString
        )
    }

    /// Executes an MCP tool through the one ToolExecutionPipeline.  Callers
    /// that retry a command must reuse both IDs; the pipeline will then retain
    /// a single request/evidence/completion chain instead of replaying a host
    /// call outside the event log.
    public func call(
        serverID: String,
        tool: String,
        argumentsJSON: String,
        sessionID: String,
        commandID: String,
        callID: String
    ) async throws -> String {
        guard hosts[serverID] != nil else { throw MCPRuntimeError.invalidConfiguration }
        guard let pipeline, router != nil else { throw MCPRuntimeError.pipelineRequired }
        let registered = registry.tool(named: "mcp.\(serverID).\(tool)") ?? MCPToolRegistration.make(
            serverID: serverID,
            descriptor: MCPToolDescriptor(name: tool, description: "", inputSchema: .objectSchema())
        )
        let result = try await pipeline.execute(ToolInvocationContext(
            sessionID: sessionID,
            commandID: commandID,
            callID: callID,
            tool: registered,
            argumentsJSON: argumentsJSON
        ))
        return result.output
    }

    public func health(serverID: String) async -> MCPHealth {
        healthStates[serverID] ?? .unknown
    }

    public func disconnect(serverID: String) async {
        transports[serverID] = nil
        hosts[serverID] = nil
        descriptors[serverID] = nil
        healthStates[serverID] = .unknown
    }

    public func installRoutes(on router: ToolHostRouter) {
        for (serverID, host) in hosts {
            router.register(host: host, forPrefix: "mcp.\(serverID).")
        }
    }
}

public struct MCPToolDescriptor: Codable, Equatable, Identifiable, Sendable {
    public var id: String { name }
    public let name: String
    public let description: String
    public let inputSchema: JSONValue

    public init(name: String, description: String, inputSchema: JSONValue) {
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
    }
}

public enum MCPToolRegistration {
    public static func make(serverID: String, descriptor: MCPToolDescriptor, readOnly: Bool = false) -> RegisteredTool {
        RegisteredTool(
            name: "mcp.\(serverID).\(descriptor.name)",
            description: descriptor.description,
            parameters: descriptor.inputSchema,
            effect: readOnly ? .readOnly : .externalWrite,
            risk: readOnly ? .l1 : .l2,
            timeoutMilliseconds: 30_000,
            maxOutputBytes: 128_000,
            idempotent: readOnly,
            supportsCancellation: true
        )
    }
}

public struct MCPJSONRPCRequest: Codable, Equatable, Sendable {
    public let jsonrpc: String
    public let id: Int
    public let method: String
    public let params: JSONValue?

    public init(id: Int, method: String, params: JSONValue?) {
        self.jsonrpc = "2.0"
        self.id = id
        self.method = method
        self.params = params
    }
}

public struct MCPJSONRPCError: Codable, Equatable, Sendable {
    public let code: Int
    public let message: String
}

public struct MCPJSONRPCResponse: Codable, Equatable, Sendable {
    public let jsonrpc: String
    public let id: Int?
    public let result: JSONValue?
    public let error: MCPJSONRPCError?

    public static func decode(line: String) throws -> MCPJSONRPCResponse {
        try JSONDecoder().decode(MCPJSONRPCResponse.self, from: Data(line.utf8))
    }

    public var tools: [MCPToolDescriptor] {
        guard case let .object(result)? = result,
              case let .array(values)? = result["tools"] else { return [] }
        return values.compactMap { value in
            guard case let .object(tool) = value,
                  case let .string(name)? = tool["name"] else { return nil }
            let description: String
            if case let .string(value)? = tool["description"] {
                description = value
            } else {
                description = ""
            }
            return MCPToolDescriptor(name: name, description: description, inputSchema: tool["inputSchema"] ?? .objectSchema())
        }
    }
}

public enum MCPRuntimeError: LocalizedError {
    case invalidConfiguration
    case pipelineRequired
    case invalidResponse
    case server(String)

    public var errorDescription: String? {
        switch self {
        case .invalidConfiguration: "MCP 配置无效"
        case .pipelineRequired: "MCP 调用必须通过统一工具流水线"
        case .invalidResponse: "MCP Server 返回了无效响应"
        case let .server(message): "MCP Server 错误：\(message)"
        }
    }
}

public protocol MCPTransport: Sendable {
    func request(_ request: MCPJSONRPCRequest) async throws -> MCPJSONRPCResponse
}

public struct MCPToolHost: ToolHost {
    public let serverID: String
    public let transport: any MCPTransport
    public let manifest: HostCapabilityManifest

    public init(
        serverID: String,
        transport: any MCPTransport,
        manifest: HostCapabilityManifest? = nil
    ) {
        self.serverID = serverID
        self.transport = transport
        self.manifest = manifest ?? HostCapabilityManifest(
            hostID: "mcp.\(serverID)",
            allowedEffects: [.readOnly, .network, .externalWrite]
        )
    }

    public func execute(tool: RegisteredTool, argumentsJSON: String, sessionID: String) async throws -> String {
        guard manifest.allows(effect: tool.effect) else { throw HostCapabilityError.denied }
        guard let data = argumentsJSON.data(using: .utf8),
              let arguments = try? JSONDecoder().decode(JSONValue.self, from: data) else {
            throw MCPRuntimeError.invalidConfiguration
        }
        let toolName = tool.name.split(separator: ".").last.map(String.init) ?? tool.name
        let requestID = abs(sessionID.hashValue)
        let request = MCPJSONRPCRequest(
            id: requestID,
            method: "tools/call",
            params: .object([
                "name": .string(toolName),
                "arguments": arguments
            ])
        )
        let response = try await transport.request(request)
        if let error = response.error { throw MCPRuntimeError.server(error.message) }
        guard let result = response.result,
              let encoded = try? JSONEncoder().encode(result) else {
            throw MCPRuntimeError.invalidResponse
        }
        guard encoded.count <= min(tool.maxOutputBytes, manifest.maxOutputBytes) else {
            throw MCPRuntimeError.server("MCP 输出超过 Host 上限")
        }
        return String(decoding: encoded, as: UTF8.self)
    }

    public func cancel(invocationID: String) async {}
}

public struct StreamableHTTPMCPTransport: MCPTransport {
    public let endpoint: URL
    public let authorizationReference: String?
    public let secretStore: (any SecretStore)?
    public let runtime: NetworkRuntime

    public init(endpoint: URL, authorizationReference: String? = nil, secretStore: (any SecretStore)? = nil, runtime: NetworkRuntime = .shared) {
        self.endpoint = endpoint
        self.authorizationReference = authorizationReference
        self.secretStore = secretStore
        self.runtime = runtime
    }

    public func request(_ request: MCPJSONRPCRequest) async throws -> MCPJSONRPCResponse {
        var urlRequest = URLRequest(url: endpoint)
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = 30
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        if let authorizationReference, let secretStore,
           let token = try? secretStore.load(reference: authorizationReference),
           !token.isEmpty {
            urlRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        urlRequest.httpBody = try JSONEncoder().encode(request)
        let (data, response) = try await runtime.data(for: urlRequest, scope: .mcp, approved: true, maxBytes: 512_000)
        guard (200..<300).contains(response.statusCode) else {
            throw MCPRuntimeError.server("HTTP \(response.statusCode)")
        }
        let body = String(decoding: data, as: UTF8.self)
        let line = body
            .split(separator: "\n")
            .map(String.init)
            .last(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty })?
            .replacingOccurrences(of: "data:", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? body
        let decoded = try MCPJSONRPCResponse.decode(line: line)
        if let error = decoded.error { throw MCPRuntimeError.server(error.message) }
        return decoded
    }
}

public struct StdioMCPTransport: MCPTransport {
    public let command: String
    public let arguments: [String]

    public init(command: String, arguments: [String]) {
        self.command = command
        self.arguments = arguments
    }

    public func request(_ request: MCPJSONRPCRequest) async throws -> MCPJSONRPCResponse {
        try await Task.detached(priority: .userInitiated) {
            let process = Process()
            let input = Pipe()
            let output = Pipe()
            let errors = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = [command] + arguments
            process.standardInput = input
            process.standardOutput = output
            process.standardError = errors
            try process.run()
            let payload = try JSONEncoder().encode(request) + Data([0x0A])
            try input.fileHandleForWriting.write(contentsOf: payload)
            try input.fileHandleForWriting.close()
            process.waitUntilExit()
            let stdout = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            guard process.terminationStatus == 0 else {
                let stderr = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                throw MCPRuntimeError.server(stderr)
            }
            guard let line = stdout.split(separator: "\n").map(String.init).last(where: { !$0.isEmpty }) else {
                throw MCPRuntimeError.invalidResponse
            }
            let decoded = try MCPJSONRPCResponse.decode(line: line)
            if let error = decoded.error { throw MCPRuntimeError.server(error.message) }
            return decoded
        }.value
    }
}
