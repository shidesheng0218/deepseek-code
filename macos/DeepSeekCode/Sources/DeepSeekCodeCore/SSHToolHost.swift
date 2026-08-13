import Foundation
import CryptoKit

public struct RemoteToolRequest: Codable, Equatable, Sendable {
    public let protocolVersion: Int
    public let id: String
    public let sessionID: String
    public let tool: String
    public let argumentsJSON: String

    public init(id: String, sessionID: String, tool: String, argumentsJSON: String, protocolVersion: Int = 1) {
        self.protocolVersion = protocolVersion
        self.id = id
        self.sessionID = sessionID
        self.tool = tool
        self.argumentsJSON = argumentsJSON
    }
}

public struct RemoteToolResponse: Codable, Equatable, Sendable {
    public let protocolVersion: Int
    public let id: String
    public let ok: Bool
    public let output: String
    public let indeterminate: Bool

    public init(id: String, ok: Bool, output: String, indeterminate: Bool = false, protocolVersion: Int = 1) {
        self.protocolVersion = protocolVersion
        self.id = id
        self.ok = ok
        self.output = output
        self.indeterminate = indeterminate
    }
}

public struct SSHInstallPlan: Equatable, Sendable {
    public let host: SSHHost
    public let version: String
    public let checksum: String
    public let remoteInstallPath: String
    public let command: String

    public init(host: SSHHost, version: String, checksum: String, remoteInstallPath: String, command: String) {
        self.host = host
        self.version = version
        self.checksum = checksum
        self.remoteInstallPath = remoteInstallPath
        self.command = command
    }
}

public struct SSHInstallReceipt: Codable, Equatable, Sendable {
    public let hostID: String
    public let version: String
    public let remotePath: String
    public let checksum: String
    public let handshake: SSHCapabilityHandshake

    public init(hostID: String, version: String, remotePath: String, checksum: String, handshake: SSHCapabilityHandshake) {
        self.hostID = hostID
        self.version = version
        self.remotePath = remotePath
        self.checksum = checksum
        self.handshake = handshake
    }
}

public enum SSHToolHostInstaller {
    public static func plan(host: SSHHost, version: String, checksum: String) -> SSHInstallPlan {
        let remotePath = "$HOME/.local/share/deepseek-code/host/\(version)"
        let command = SSHCommandBuilder.command(
            host: host,
            command: "mkdir -p \(remotePath) && printf '%s  %s\\n' \(shellQuote(checksum)) \(shellQuote("\(remotePath)/DeepSeekCodeToolHost"))"
        )
        return SSHInstallPlan(host: host, version: version, checksum: checksum, remoteInstallPath: remotePath, command: command)
    }

    public static func fingerprintMatches(expected: String?, observed: String) -> Bool {
        guard let expected, !expected.isEmpty else { return true }
        return expected == observed
    }

    public static func installCommand(host: SSHHost, version: String, checksum: String, localBinaryPath: String) -> String {
        let remoteDirectory = "$HOME/.local/share/deepseek-code/host/\(version)"
        let remoteBinary = "\(remoteDirectory)/DeepSeekCodeToolHost"
        let target = "\(host.user)@\(host.hostname):\(remoteBinary)"
        return [
            "ssh -p \(host.port) \(host.user)@\(host.hostname) -- mkdir -p \(remoteDirectory)",
            "scp -P \(host.port) \(shellQuote(localBinaryPath)) \(shellQuote(target))",
            "ssh -p \(host.port) \(host.user)@\(host.hostname) -- chmod 700 \(remoteBinary) && shasum -a 256 \(remoteBinary)"
        ].joined(separator: " && ") + " # expected \(shellQuote(checksum))"
    }

    public static func checksum(for binaryURL: URL) throws -> String {
        SHA256.hash(data: try Data(contentsOf: binaryURL)).map { String(format: "%02x", $0) }.joined()
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

/// Framed JSON transport used by the local control plane. The remote process
/// receives only structured tool requests; credentials remain on the Mac.
public struct ProcessSSHRemoteTransport: SSHRemoteTransport {
    public let host: SSHHost
    public let remotePath: String
    public let timeout: TimeInterval

    public init(host: SSHHost, remotePath: String, timeout: TimeInterval = 30) {
        self.host = host
        self.remotePath = remotePath
        self.timeout = timeout
    }

    public func send(_ request: RemoteToolRequest) async throws -> RemoteToolResponse {
        try await Task.detached(priority: .userInitiated) {
            let process = Process()
            let input = Pipe()
            let output = Pipe()
            let errors = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            process.arguments = SSHClientArguments.options(for: host) + ["\(host.user)@\(host.hostname)", remotePath]
            process.standardInput = input
            process.standardOutput = output
            process.standardError = errors
            // Draining must start before the process runs, otherwise remote
            // responses larger than the 64KB pipe buffer block ssh forever.
            let drainer = ProcessOutputDrainer(stdout: output, stderr: errors)
            try process.run()
            try input.fileHandleForWriting.write(contentsOf: JSONEncoder().encode(request) + Data([0x0A]))
            try input.fileHandleForWriting.close()
            let deadline = Date().addingTimeInterval(timeout)
            while process.isRunning && Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
            if process.isRunning {
                process.terminate()
                return RemoteToolResponse(id: request.id, ok: false, output: "SSH 请求超时", indeterminate: true)
            }
            let drained = drainer.joined()
            let stdout = String(decoding: drained.stdout, as: UTF8.self)
            let stderr = String(decoding: drained.stderr, as: UTF8.self)
            guard process.terminationStatus == 0 else {
                return RemoteToolResponse(id: request.id, ok: false, output: stderr.isEmpty ? stdout : stderr, indeterminate: false)
            }
            guard let line = stdout.split(separator: "\n").last,
                  let data = String(line).data(using: .utf8),
                  let response = try? JSONDecoder().decode(RemoteToolResponse.self, from: data) else {
                return RemoteToolResponse(id: request.id, ok: false, output: "远程 Tool Host 返回无效 JSON", indeterminate: true)
            }
            return response
        }.value
    }

    public func handshake() async throws -> SSHCapabilityHandshake {
        let response = try await send(RemoteToolRequest(id: UUID().uuidString, sessionID: "handshake", tool: "__handshake__", argumentsJSON: "{}"))
        guard response.ok,
              let data = response.output.data(using: .utf8),
              let handshake = try? JSONDecoder().decode(SSHCapabilityHandshake.self, from: data) else {
            throw SSHConnectionError.incompatibleProtocol
        }
        return handshake
    }

    /// Installs a packaged, checksum-verified Tool Host without forwarding API
    /// credentials. The installation runs only after the caller has confirmed
    /// the SSH Host Key fingerprint.
    public func install(binaryURL: URL, version: String, checksum: String) async throws -> SSHInstallReceipt {
        let safeVersion = version.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !safeVersion.isEmpty, safeVersion.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == "_" }) else {
            throw UnifiedRuntimeError.remote("SSH Tool Host 版本标识无效")
        }
        let localData = try Data(contentsOf: binaryURL)
        let localChecksum = SHA256.hash(data: localData).map { String(format: "%02x", $0) }.joined()
        guard localChecksum.caseInsensitiveCompare(checksum) == .orderedSame else {
            throw UnifiedRuntimeError.remote("本地 SSH Tool Host 校验和不匹配")
        }
        let remoteDirectory = "$HOME/.local/share/deepseek-code/host/\(safeVersion)"
        let remotePath = "\(remoteDirectory)/DeepSeekCodeToolHost"
        _ = try await runProcess(
            executable: "/usr/bin/ssh",
            arguments: SSHClientArguments.options(for: host) + ["\(host.user)@\(host.hostname)", "mkdir -p \(remoteDirectory)"]
        )
        _ = try await runProcess(
            executable: "/usr/bin/scp",
            arguments: SSHClientArguments.options(for: host, portFlag: "-P") + [binaryURL.path, "\(host.user)@\(host.hostname):\(remotePath)"]
        )
        let remoteChecksum = try await runProcess(
            executable: "/usr/bin/ssh",
            arguments: SSHClientArguments.options(for: host) + ["\(host.user)@\(host.hostname)", "chmod 700 \(remotePath) && shasum -a 256 \(remotePath)"]
        )
        guard remoteChecksum.localizedCaseInsensitiveContains(localChecksum) else {
            throw UnifiedRuntimeError.remote("远程 SSH Tool Host 校验和不匹配")
        }
        let installed = ProcessSSHRemoteTransport(host: host, remotePath: remotePath, timeout: timeout)
        let handshake = try await installed.handshake()
        return SSHInstallReceipt(hostID: host.id, version: safeVersion, remotePath: remotePath, checksum: localChecksum, handshake: handshake)
    }

    private func runProcess(executable: String, arguments: [String]) async throws -> String {
        try await Task.detached(priority: .userInitiated) {
            let process = Process()
            let output = Pipe()
            let errors = Pipe()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.standardOutput = output
            process.standardError = errors
            try process.run()
            let deadline = Date().addingTimeInterval(timeout)
            while process.isRunning && Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
            if process.isRunning {
                process.terminate()
                throw UnifiedRuntimeError.remote("SSH Tool Host 安装超时")
            }
            let stdout = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            let stderr = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            guard process.terminationStatus == 0 else {
                throw UnifiedRuntimeError.remote(stderr.isEmpty ? stdout : stderr)
            }
            return stdout
        }.value
    }
}

/// Dispatches the generic ssh.execute tool to a fingerprint-verified remote
/// Host. The model never receives raw SSH command construction or credentials.
public struct SSHDispatchToolHost: ToolHost {
    public let manager: SSHConnectionManager
    public let networkRuntime: NetworkRuntime?

    public init(manager: SSHConnectionManager, networkRuntime: NetworkRuntime? = nil) {
        self.manager = manager
        self.networkRuntime = networkRuntime
    }

    public func execute(tool: RegisteredTool, argumentsJSON: String, sessionID: String) async throws -> String {
        guard tool.name == "ssh.execute",
              let data = argumentsJSON.data(using: .utf8),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hostID = object["hostID"] as? String,
              let remoteTool = object["tool"] as? String,
              let remoteArguments = object["arguments"],
              JSONSerialization.isValidJSONObject(remoteArguments),
              let remoteData = try? JSONSerialization.data(withJSONObject: remoteArguments),
              let host = await manager.host(id: hostID) else {
            throw UnifiedRuntimeError.invalidArguments
        }
        let remoteEffect = Self.effect(for: remoteTool)
        let remoteToolDescriptor = RegisteredTool(
            name: remoteTool,
            description: "已验证 SSH Tool Host 远程工具",
            parameters: .objectSchema(),
            effect: remoteEffect,
            risk: Self.risk(for: remoteTool),
            timeoutMilliseconds: 60_000,
            maxOutputBytes: 128_000,
            idempotent: remoteEffect == .readOnly,
            supportsCancellation: true
        )
        let operation: NetworkOperation = remoteEffect == .readOnly ? .read : .write
        guard let endpoint = URL(string: "ssh://\(host.host.hostname):\(host.host.port)") else {
            throw UnifiedRuntimeError.invalidArguments
        }
        await networkRuntime?.recordExternalRequest(capability: .ssh, operation: operation, url: endpoint, sessionID: sessionID, projectID: nil, state: .started)
        do {
            let output = try await host.execute(
                tool: remoteToolDescriptor,
                argumentsJSON: String(decoding: remoteData, as: UTF8.self),
                sessionID: sessionID
            )
            await networkRuntime?.recordExternalRequest(capability: .ssh, operation: operation, url: endpoint, sessionID: sessionID, projectID: nil, state: .completed, statusCode: 0)
            return output
        } catch {
            let indeterminate = error.localizedDescription.contains("未知") || error.localizedDescription.contains("断")
            await networkRuntime?.recordExternalRequest(capability: .ssh, operation: operation, url: endpoint, sessionID: sessionID, projectID: nil, state: indeterminate ? .indeterminate : .failed, errorMessage: error.localizedDescription)
            throw error
        }
    }

    public func cancel(invocationID: String) async {}

    private static func effect(for tool: String) -> ToolEffect {
        switch tool {
        case "read_file", "list_directory", "search_workspace", "inspect_git": .readOnly
        case "apply_patch": .workspaceWrite
        case "run_command": .process
        default: .readOnly
        }
    }

    private static func risk(for tool: String) -> CommandRisk {
        switch tool {
        case "read_file", "list_directory", "search_workspace", "inspect_git": .l0
        case "apply_patch": .l1
        case "run_command": .l2
        default: .l2
        }
    }
}

public enum SSHConnectionState: String, Codable, Sendable {
    case disconnected
    case connected
    case fingerprintChanged
    case needsAttention
}

public actor SSHConnectionManager {
    private var states: [String: SSHConnectionState] = [:]
    private var hosts: [String: SSHToolHost] = [:]
    private var observedFingerprints: [String: String] = [:]

    public init() {}

    public func connect(host: SSHHost, observedFingerprint: String, remotePath: String, transport: any SSHRemoteTransport) async throws -> SSHToolHost {
        guard SSHToolHostInstaller.fingerprintMatches(expected: host.fingerprint, observed: observedFingerprint) else {
            states[host.id] = .fingerprintChanged
            throw SSHConnectionError.fingerprintChanged
        }
        let handshake = try await transport.handshake()
        guard handshake.protocolVersion == 1 else {
            states[host.id] = .needsAttention
            throw SSHConnectionError.incompatibleProtocol
        }
        let toolHost = SSHToolHost(host: host, remotePath: remotePath, transport: transport)
        hosts[host.id] = toolHost
        observedFingerprints[host.id] = observedFingerprint
        states[host.id] = .connected
        return toolHost
    }

    public func host(id: String) -> SSHToolHost? { hosts[id] }
    public func state(hostID: String) -> SSHConnectionState { states[hostID] ?? .disconnected }

    /// Creates the PTY-specific remote Helper channel only for a previously
    /// fingerprint-verified host. This stays separate from generic ssh.execute
    /// so a one-shot workspace RPC is never misrepresented as a recoverable
    /// terminal connection.
    public func persistentTerminalHost(hostID: String, observedFingerprint: String, remotePath: String? = nil) throws -> ProcessSSHTerminalHelperHost {
        guard let existing = hosts[hostID] else { throw SSHConnectionError.notConnected }
        guard SSHToolHostInstaller.fingerprintMatches(expected: existing.host.fingerprint, observed: observedFingerprint) else {
            states[hostID] = .fingerprintChanged
            throw SSHConnectionError.fingerprintChanged
        }
        return try ProcessSSHTerminalHelperHost(
            host: existing.host,
            remotePath: remotePath ?? existing.remotePath,
            observedFingerprint: observedFingerprint
        )
    }

    public func persistentTerminalHost(hostID: String) throws -> ProcessSSHTerminalHelperHost {
        guard let existing = hosts[hostID], let observed = observedFingerprints[hostID] else { throw SSHConnectionError.notConnected }
        guard SSHToolHostInstaller.fingerprintMatches(expected: existing.host.fingerprint, observed: observed) else {
            states[hostID] = .fingerprintChanged
            throw SSHConnectionError.fingerprintChanged
        }
        return try ProcessSSHTerminalHelperHost(host: existing.host, remotePath: existing.remotePath, observedFingerprint: observed)
    }

    public func markIndeterminate(hostID: String) {
        states[hostID] = .needsAttention
    }

    public func reconnect(hostID: String, observedFingerprint: String, transport: any SSHRemoteTransport) async throws -> SSHToolHost {
        guard let existing = hosts[hostID] else { throw SSHConnectionError.notConnected }
        return try await connect(host: existing.host, observedFingerprint: observedFingerprint, remotePath: existing.remotePath, transport: transport)
    }

    public func installAndConnect(host: SSHHost, observedFingerprint: String, binaryURL: URL, version: String, timeout: TimeInterval = 30) async throws -> (toolHost: SSHToolHost, receipt: SSHInstallReceipt) {
        guard SSHToolHostInstaller.fingerprintMatches(expected: host.fingerprint, observed: observedFingerprint) else {
            states[host.id] = .fingerprintChanged
            throw SSHConnectionError.fingerprintChanged
        }
        let checksum = try SSHToolHostInstaller.checksum(for: binaryURL)
        let bootstrap = ProcessSSHRemoteTransport(host: host, remotePath: "/usr/bin/false", timeout: timeout)
        let receipt = try await bootstrap.install(binaryURL: binaryURL, version: version, checksum: checksum)
        let transport = ProcessSSHRemoteTransport(host: host, remotePath: receipt.remotePath, timeout: timeout)
        let toolHost = try await connect(host: host, observedFingerprint: observedFingerprint, remotePath: receipt.remotePath, transport: transport)
        return (toolHost, receipt)
    }

    public func disconnect(hostID: String) {
        states[hostID] = .disconnected
    }
}

public enum SSHConnectionError: LocalizedError, Sendable {
    case fingerprintChanged
    case incompatibleProtocol
    case notConnected
    public var errorDescription: String? {
        switch self {
        case .fingerprintChanged: "SSH Host Key 指纹已变化，已阻止连接"
        case .incompatibleProtocol: "远程 SSH Tool Host 协议版本不兼容"
        case .notConnected: "SSH Host 尚未建立连接，无法重连"
        }
    }
}
