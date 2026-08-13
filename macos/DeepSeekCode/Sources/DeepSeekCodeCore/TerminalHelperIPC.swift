import Darwin
import Foundation
import CryptoKit

public struct TerminalHelperDescriptor: Codable, Equatable, Sendable {
    public let protocolVersion: Int
    public let instanceID: String
    public let socketPath: String
    public let token: String
    public let startedAt: Date
    public let processID: Int32?

    public init(protocolVersion: Int = 1, instanceID: String = UUID().uuidString, socketPath: String, token: String, startedAt: Date = Date(), processID: Int32? = Int32(getpid())) {
        self.protocolVersion = protocolVersion
        self.instanceID = instanceID
        self.socketPath = socketPath
        self.token = token
        self.startedAt = startedAt
        self.processID = processID
    }
}

public struct TerminalHelperRequest: Codable, Equatable, Sendable {
    public let protocolVersion: Int
    public let id: String
    public let token: String
    public let sessionID: String
    public let method: String
    public let terminalID: String?
    public let payload: String

    public init(id: String = UUID().uuidString, token: String, sessionID: String, method: String, terminalID: String? = nil, payload: String = "{}", protocolVersion: Int = 1) {
        self.protocolVersion = protocolVersion
        self.id = id
        self.token = token
        self.sessionID = sessionID
        self.method = method
        self.terminalID = terminalID
        self.payload = payload
    }
}

public struct TerminalHelperResponse: Codable, Equatable, Sendable {
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

public enum TerminalHelperMethod {
    public static let handshake = "handshake"
    public static let open = "open"
    public static let attach = "attach"
    public static let read = "read"
    public static let write = "write"
    public static let resize = "resize"
    public static let signal = "signal"
    public static let detach = "detach"
    public static let close = "close"
    public static let inspect = "inspect"
    public static let list = "list"
    public static let stopGracefully = "stop_gracefully"
    public static let protectedStatus = "protected_status"
    public static let writeProtected = "write_protected"
}

/// macOS `sockaddr_un` has a very short path limit. Application Support and
/// test roots can easily exceed it, so the Helper uses a deterministic,
/// per-root fallback under `/tmp` while retaining a 0600 descriptor/token in
/// its private runtime directory. This is the same local-only model as
/// `deepseekd`; it never opens a TCP listener.
public enum TerminalHelperPaths {
    public static func socketPath(root: URL) -> String {
        let candidate = root.appendingPathComponent("host.sock", isDirectory: false).path
        if candidate.utf8.count < 100 { return candidate }
        let digest = SHA256.hash(data: Data(root.standardizedFileURL.path.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return "/tmp/deepseek-terminal-\(digest.prefix(24)).sock"
    }
}

/// One-request-per-connection Unix domain transport. The Helper process keeps
/// the PTY alive; connections are intentionally short-lived so reconnecting
/// after an App crash cannot duplicate a request or strand a pipe.
public struct UnixDomainTerminalTransport: Sendable {
    public let descriptor: TerminalHelperDescriptor
    public let timeout: TimeInterval

    public init(descriptor: TerminalHelperDescriptor, timeout: TimeInterval = 10) {
        self.descriptor = descriptor
        self.timeout = timeout
    }

    public func send(_ request: TerminalHelperRequest) async throws -> TerminalHelperResponse {
        try await Task.detached(priority: .userInitiated) {
            let fd = try Self.connect(path: descriptor.socketPath)
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            let data = try JSONEncoder.terminalHelper.encode(request) + Data([0x0A])
            try handle.write(contentsOf: data)
            _ = shutdown(fd, SHUT_WR)
            let deadline = Date().addingTimeInterval(timeout)
            var responseData = Data()
            while Date() < deadline {
                let chunk = try handle.read(upToCount: 64 * 1024) ?? Data()
                if chunk.isEmpty { break }
                responseData.append(chunk)
                if responseData.contains(0x0A) { break }
            }
            guard let line = String(decoding: responseData, as: UTF8.self).split(separator: "\n").first,
                  let encoded = String(line).data(using: .utf8),
                  let response = try? JSONDecoder.terminalHelper.decode(TerminalHelperResponse.self, from: encoded) else {
                return TerminalHelperResponse(id: request.id, ok: false, output: "Terminal Helper 返回无效响应", indeterminate: true)
            }
            return response
        }.value
    }

    private static func connect(path: String) throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw UnifiedRuntimeError.remote("无法创建 Terminal Helper Socket") }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8) + [0]
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard pathBytes.count <= capacity else { close(fd); throw UnifiedRuntimeError.remote("Terminal Helper Socket 路径过长") }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            for index in 0..<buffer.count { buffer[index] = 0 }
            for (index, byte) in pathBytes.enumerated() { buffer[index] = byte }
        }
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { pointer in
                Darwin.connect(fd, pointer, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else { let code = errno; close(fd); throw UnifiedRuntimeError.remote("无法连接 Terminal Helper：\(String(cString: strerror(code)))") }
        return fd
    }
}

/// Bridges an SSH stdio stream to a same-user remote Unix socket. The remote
/// daemon token never leaves the remote account: requests are rewritten only
/// inside the proxy process after it reads the 0600 descriptor locally.
public enum TerminalHelperProxy {
    public static func rewrite(_ request: TerminalHelperRequest, using descriptor: TerminalHelperDescriptor) -> TerminalHelperRequest {
        TerminalHelperRequest(
            id: request.id,
            token: descriptor.token,
            sessionID: request.sessionID,
            method: request.method,
            terminalID: request.terminalID,
            payload: request.payload,
            protocolVersion: descriptor.protocolVersion
        )
    }

    public static func runStdio(socketPath: String, descriptorURL: URL) async throws {
        let descriptor = try JSONDecoder.terminalHelper.decode(TerminalHelperDescriptor.self, from: Data(contentsOf: descriptorURL))
        guard descriptor.socketPath == socketPath else { throw UnifiedRuntimeError.remote("远程 Terminal Helper Socket 描述不匹配") }
        let transport = UnixDomainTerminalTransport(descriptor: descriptor, timeout: 20)
        while let line = readLine(strippingNewline: true) {
            guard let data = line.data(using: .utf8),
                  let request = try? JSONDecoder.terminalHelper.decode(TerminalHelperRequest.self, from: data) else {
                let invalid = TerminalHelperResponse(id: UUID().uuidString, ok: false, output: "无效的 Terminal Proxy 请求")
                FileHandle.standardOutput.write(try JSONEncoder.terminalHelperResponse.encode(invalid) + Data([0x0A]))
                continue
            }
            let response: TerminalHelperResponse
            do {
                response = try await transport.send(rewrite(request, using: descriptor))
            } catch {
                response = TerminalHelperResponse(id: request.id, ok: false, output: SecretRedactor.redact(error.localizedDescription), indeterminate: true)
            }
            FileHandle.standardOutput.write(try JSONEncoder.terminalHelperResponse.encode(response) + Data([0x0A]))
        }
    }

    public static func health(socketPath: String, descriptorURL: URL) async throws {
        let descriptor = try JSONDecoder.terminalHelper.decode(TerminalHelperDescriptor.self, from: Data(contentsOf: descriptorURL))
        guard descriptor.socketPath == socketPath else { throw UnifiedRuntimeError.remote("Terminal Helper Socket 描述不匹配") }
        let response = try await UnixDomainTerminalTransport(descriptor: descriptor, timeout: 3).send(
            TerminalHelperRequest(token: descriptor.token, sessionID: "health", method: TerminalHelperMethod.handshake)
        )
        guard response.ok else { throw UnifiedRuntimeError.remote(response.output) }
    }
}

/// Starts the standalone Helper lazily and keeps it alive independently from
/// any single tool invocation. The descriptor file is the only shared state;
/// it contains a per-instance token and is protected with 0600 permissions.
public actor TerminalHelperProcessManager {
    public let executableURL: URL
    public let root: URL
    public let socketPath: String
    public let descriptorURL: URL
    private var process: Process?
    private var cachedDescriptor: TerminalHelperDescriptor?

    public init(executableURL: URL, root: URL) {
        self.executableURL = executableURL
        self.root = root
        socketPath = TerminalHelperPaths.socketPath(root: root)
        descriptorURL = root.appendingPathComponent("host.json")
    }

    public func ensureStarted() async throws -> TerminalHelperDescriptor {
        if let cachedDescriptor, await isReachable(cachedDescriptor) { return cachedDescriptor }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        if let existing = try? loadDescriptor() {
            if await isReachable(existing) {
                cachedDescriptor = existing
                return existing
            }
            if await isLegacyReachable(existing) {
                guard !hasActiveTerminals() else {
                    throw UnifiedRuntimeError.remote("Terminal Helper 版本过旧，存在运行中终端；为避免强杀后台任务，请先停止或导出这些终端")
                }
                TerminalHelperLaunchAgentManager().restart()
                try? FileManager.default.removeItem(at: descriptorURL)
                try? FileManager.default.removeItem(atPath: socketPath)
            }
        }
        // A packaged App installs a user LaunchAgent first. This lets the
        // Helper outlive the UI process; direct spawning below is only a
        // bounded startup fallback when launchd has not produced a descriptor.
        _ = try? TerminalHelperLaunchAgentManager().install(
            executableURL: executableURL,
            root: root,
            socketPath: socketPath,
            descriptorURL: descriptorURL
        )
        let launchAgentDeadline = Date().addingTimeInterval(1)
        while Date() < launchAgentDeadline {
            if let descriptor = try? loadDescriptor(), await isReachable(descriptor) {
                cachedDescriptor = descriptor
                return descriptor
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        try? FileManager.default.removeItem(at: descriptorURL)
        let child = Process()
        child.executableURL = executableURL
        child.arguments = ["--terminal-helper", "--root", root.path, "--socket", socketPath, "--descriptor", descriptorURL.path]
        child.standardInput = nil
        child.standardOutput = nil
        child.standardError = nil
        try child.run()
        process = child
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if let descriptor = try? loadDescriptor(), await isReachable(descriptor) {
                cachedDescriptor = descriptor
                return descriptor
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        throw UnifiedRuntimeError.remote("Terminal Helper 启动超时")
    }

    public func terminate() {
        process?.terminate()
        process = nil
        cachedDescriptor = nil
    }

    private func loadDescriptor() throws -> TerminalHelperDescriptor {
        try JSONDecoder.terminalHelper.decode(TerminalHelperDescriptor.self, from: Data(contentsOf: descriptorURL))
    }

    private func isReachable(_ descriptor: TerminalHelperDescriptor) async -> Bool {
        guard let handshake = await handshake(descriptor) else { return false }
        return handshake.hostVersion == TerminalHelperProtocol.currentHostVersion
    }

    private func isLegacyReachable(_ descriptor: TerminalHelperDescriptor) async -> Bool {
        await handshake(descriptor) != nil
    }

    private func handshake(_ descriptor: TerminalHelperDescriptor) async -> TerminalCapabilityHandshake? {
        let transport = UnixDomainTerminalTransport(descriptor: descriptor, timeout: 1)
        let request = TerminalHelperRequest(token: descriptor.token, sessionID: "health", method: TerminalHelperMethod.handshake)
        guard let response = try? await transport.send(request), response.ok,
              let data = response.output.data(using: .utf8) else { return nil }
        return try? JSONDecoder.terminalHelper.decode(TerminalCapabilityHandshake.self, from: data)
    }

    private func hasActiveTerminals() -> Bool {
        guard let registry = try? PersistentTerminalRegistry(root: root), let manifests = try? registry.manifests() else { return false }
        return manifests.contains { [.starting, .running, .background].contains($0.state) }
    }
}

public actor ProcessPersistentTerminalHost: PersistentTerminalInteractiveHost {
    private let manager: TerminalHelperProcessManager

    public init(manager: TerminalHelperProcessManager) { self.manager = manager }

    public func handshake() async throws -> TerminalCapabilityHandshake {
        let descriptor = try await manager.ensureStarted()
        let response = try await send(method: TerminalHelperMethod.handshake, descriptor: descriptor, sessionID: "handshake")
        return try decode(response.output, as: TerminalCapabilityHandshake.self)
    }

    public func open(spec: TerminalLaunchSpec) async throws -> TerminalSessionRecord {
        let descriptor = try await manager.ensureStarted()
        let response = try await send(method: TerminalHelperMethod.open, descriptor: descriptor, sessionID: spec.sessionID, payload: spec)
        return try decode(response.output, as: TerminalSessionRecord.self)
    }

    public func attach(terminalID: String) async throws -> TerminalAttachReceipt {
        let descriptor = try await manager.ensureStarted()
        let response = try await send(method: TerminalHelperMethod.attach, descriptor: descriptor, sessionID: "attach", terminalID: terminalID)
        return try decode(response.output, as: TerminalAttachReceipt.self)
    }

    public func read(terminalID: String, afterSequence: Int, maxBytes: Int) async throws -> [TerminalOutputChunk] {
        let descriptor = try await manager.ensureStarted()
        let payload = "{\"afterSequence\":\(afterSequence),\"maxBytes\":\(maxBytes)}"
        let response = try await send(method: TerminalHelperMethod.read, descriptor: descriptor, sessionID: "read", terminalID: terminalID, payload: payload)
        return try decode(response.output, as: [TerminalOutputChunk].self)
    }

    public func write(terminalID: String, data: Data) async throws {
        let descriptor = try await manager.ensureStarted()
        let payload = try JSONSerialization.data(withJSONObject: ["data": String(decoding: data, as: UTF8.self)])
        _ = try await send(method: TerminalHelperMethod.write, descriptor: descriptor, sessionID: "write", terminalID: terminalID, payload: String(decoding: payload, as: UTF8.self))
    }

    public func resize(terminalID: String, columns: Int, rows: Int) async throws {
        let descriptor = try await manager.ensureStarted()
        _ = try await send(method: TerminalHelperMethod.resize, descriptor: descriptor, sessionID: "resize", terminalID: terminalID, payload: "{\"columns\":\(columns),\"rows\":\(rows)}")
    }

    public func signal(terminalID: String, signal: TerminalSignal) async throws {
        let descriptor = try await manager.ensureStarted()
        _ = try await send(method: TerminalHelperMethod.signal, descriptor: descriptor, sessionID: "signal", terminalID: terminalID, payload: "{\"signal\":\"\(signal.rawValue)\"}")
    }

    public func stopGracefully(terminalID: String) async throws {
        let descriptor = try await manager.ensureStarted()
        _ = try await send(method: TerminalHelperMethod.stopGracefully, descriptor: descriptor, sessionID: "stop", terminalID: terminalID)
    }

    public func writeProtectedInput(terminalID: String, data: Data) async throws {
        let descriptor = try await manager.ensureStarted()
        let payload = try JSONSerialization.data(withJSONObject: ["data": String(decoding: data, as: UTF8.self)])
        _ = try await send(method: TerminalHelperMethod.writeProtected, descriptor: descriptor, sessionID: "protected-write", terminalID: terminalID, payload: String(decoding: payload, as: UTF8.self))
    }

    public func protectedInputRequired(terminalID: String) async -> Bool {
        guard let descriptor = try? await manager.ensureStarted(),
              let response = try? await send(method: TerminalHelperMethod.protectedStatus, descriptor: descriptor, sessionID: "protected-status", terminalID: terminalID),
              let value = try? JSONDecoder.terminalHelper.decode(Bool.self, from: Data(response.output.utf8)) else { return false }
        return value
    }

    public func detach(terminalID: String) async throws {
        let descriptor = try await manager.ensureStarted()
        _ = try await send(method: TerminalHelperMethod.detach, descriptor: descriptor, sessionID: "detach", terminalID: terminalID)
    }

    public func close(terminalID: String) async throws {
        let descriptor = try await manager.ensureStarted()
        _ = try await send(method: TerminalHelperMethod.close, descriptor: descriptor, sessionID: "close", terminalID: terminalID)
    }

    public func inspect(terminalID: String) async throws -> TerminalProcessInspection {
        let descriptor = try await manager.ensureStarted()
        let response = try await send(method: TerminalHelperMethod.inspect, descriptor: descriptor, sessionID: "inspect", terminalID: terminalID)
        return try decode(response.output, as: TerminalProcessInspection.self)
    }

    private func send<T: Encodable>(method: String, descriptor: TerminalHelperDescriptor, sessionID: String, terminalID: String? = nil, payload: T? = nil) async throws -> TerminalHelperResponse {
        let encodedPayload = payload.flatMap { try? String(decoding: JSONEncoder.terminalHelper.encode($0), as: UTF8.self) } ?? "{}"
        return try await send(method: method, descriptor: descriptor, sessionID: sessionID, terminalID: terminalID, payload: encodedPayload)
    }

    private func send(method: String, descriptor: TerminalHelperDescriptor, sessionID: String, terminalID: String? = nil, payload: String = "{}") async throws -> TerminalHelperResponse {
        let response = try await UnixDomainTerminalTransport(descriptor: descriptor).send(TerminalHelperRequest(token: descriptor.token, sessionID: sessionID, method: method, terminalID: terminalID, payload: payload))
        guard response.ok else { throw UnifiedRuntimeError.remote(response.output) }
        return response
    }

    private func decode<T: Decodable>(_ output: String, as type: T.Type) throws -> T {
        try JSONDecoder.terminalHelper.decode(T.self, from: Data(output.utf8))
    }
}

/// SSH counterpart for the persistent Helper protocol. The remote daemon owns
/// the PTY and Unix socket. Each RPC uses a short-lived SSH tunnel, so a
/// transport stall cannot strand a stream; reconnecting simply talks to the
/// same remote daemon and reattaches the same terminal instead of starting a
/// new shell.
public actor ProcessSSHTerminalHelperHost: PersistentTerminalInteractiveHost {
    private let host: SSHHost
    private let remotePath: String
    private let remoteRoot: String
    private let observedFingerprint: String

    public init(host: SSHHost, remotePath: String, observedFingerprint: String, remoteRoot: String? = nil) throws {
        guard SSHToolHostInstaller.fingerprintMatches(expected: host.fingerprint, observed: observedFingerprint) else { throw SSHConnectionError.fingerprintChanged }
        self.host = host
        self.remotePath = remotePath
        self.remoteRoot = remoteRoot ?? ".local/share/deepseek-code/terminal/\(Self.safeComponent(host.id))"
        self.observedFingerprint = observedFingerprint
    }

    public func handshake() async throws -> TerminalCapabilityHandshake {
        let response = try send(method: TerminalHelperMethod.handshake, sessionID: "handshake")
        return try JSONDecoder.terminalHelper.decode(TerminalCapabilityHandshake.self, from: Data(response.output.utf8))
    }

    public func open(spec: TerminalLaunchSpec) async throws -> TerminalSessionRecord {
        var remoteSpec = spec
        remoteSpec = TerminalLaunchSpec(sessionID: spec.sessionID, target: .local, cwd: spec.cwd, command: spec.command, columns: spec.columns, rows: spec.rows, background: spec.background)
        let response = try send(method: TerminalHelperMethod.open, sessionID: spec.sessionID, payload: remoteSpec)
        return try decode(response.output, as: TerminalSessionRecord.self)
    }

    public func attach(terminalID: String) async throws -> TerminalAttachReceipt { try decode(try send(method: TerminalHelperMethod.attach, sessionID: "attach", terminalID: terminalID).output, as: TerminalAttachReceipt.self) }

    public func read(terminalID: String, afterSequence: Int, maxBytes: Int) async throws -> [TerminalOutputChunk] {
        let payload = "{\"afterSequence\":\(afterSequence),\"maxBytes\":\(maxBytes)}"
        return try decode(try send(method: TerminalHelperMethod.read, sessionID: "read", terminalID: terminalID, payload: payload).output, as: [TerminalOutputChunk].self)
    }

    public func write(terminalID: String, data: Data) async throws {
        let payload = String(decoding: try JSONSerialization.data(withJSONObject: ["data": String(decoding: data, as: UTF8.self)]), as: UTF8.self)
        _ = try send(method: TerminalHelperMethod.write, sessionID: "write", terminalID: terminalID, payload: payload)
    }

    public func resize(terminalID: String, columns: Int, rows: Int) async throws { _ = try send(method: TerminalHelperMethod.resize, sessionID: "resize", terminalID: terminalID, payload: "{\"columns\":\(columns),\"rows\":\(rows)}") }
    public func signal(terminalID: String, signal: TerminalSignal) async throws { _ = try send(method: TerminalHelperMethod.signal, sessionID: "signal", terminalID: terminalID, payload: "{\"signal\":\"\(signal.rawValue)\"}") }
    public func stopGracefully(terminalID: String) async throws { _ = try send(method: TerminalHelperMethod.stopGracefully, sessionID: "stop", terminalID: terminalID) }
    public func writeProtectedInput(terminalID: String, data: Data) async throws {
        let payload = String(decoding: try JSONSerialization.data(withJSONObject: ["data": String(decoding: data, as: UTF8.self)]), as: UTF8.self)
        _ = try send(method: TerminalHelperMethod.writeProtected, sessionID: "protected-write", terminalID: terminalID, payload: payload)
    }
    public func protectedInputRequired(terminalID: String) async -> Bool {
        guard let response = try? send(method: TerminalHelperMethod.protectedStatus, sessionID: "protected-status", terminalID: terminalID),
              let value = try? JSONDecoder.terminalHelper.decode(Bool.self, from: Data(response.output.utf8)) else { return false }
        return value
    }
    public func detach(terminalID: String) async throws { _ = try send(method: TerminalHelperMethod.detach, sessionID: "detach", terminalID: terminalID) }
    public func close(terminalID: String) async throws { _ = try send(method: TerminalHelperMethod.close, sessionID: "close", terminalID: terminalID) }
    public func inspect(terminalID: String) async throws -> TerminalProcessInspection { try decode(try send(method: TerminalHelperMethod.inspect, sessionID: "inspect", terminalID: terminalID).output, as: TerminalProcessInspection.self) }

    public func disconnect() {}

    private func send<T: Encodable>(method: String, sessionID: String, terminalID: String? = nil, payload: T? = nil) throws -> TerminalHelperResponse {
        let encoded = payload.flatMap { try? String(decoding: JSONEncoder.terminalHelper.encode($0), as: UTF8.self) } ?? "{}"
        return try send(method: method, sessionID: sessionID, terminalID: terminalID, payload: encoded)
    }

    private func send(method: String, sessionID: String, terminalID: String? = nil, payload: String = "{}") throws -> TerminalHelperResponse {
        do {
            try ensureRemoteDaemon()
            let child = Process()
            let input = Pipe()
            let output = Pipe()
            let errors = Pipe()
            child.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            let command = "\(remoteExecutable()) --terminal-helper-proxy --socket \(remoteSocket()) --descriptor \(remoteDescriptor())"
            child.arguments = SSHClientArguments.options(for: host) + ["\(host.user)@\(host.hostname)", "--", command]
            child.standardInput = input
            child.standardOutput = output
            child.standardError = errors
            try child.run()
            // The proxy replaces this placeholder with the token from the
            // remote 0600 descriptor, so the remote token never crosses SSH.
            let request = TerminalHelperRequest(token: "proxy-local-placeholder", sessionID: sessionID, method: method, terminalID: terminalID, payload: payload)
            try input.fileHandleForWriting.write(contentsOf: JSONEncoder.terminalHelper.encode(request) + Data([0x0A]))
            try input.fileHandleForWriting.close()
            let deadline = Date().addingTimeInterval(15)
            while child.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
            if child.isRunning {
                child.terminate()
                throw UnifiedRuntimeError.remote("SSH Terminal Proxy 请求超时")
            }
            let stdout = output.fileHandleForReading.readDataToEndOfFile()
            let stderr = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            guard child.terminationStatus == 0 else {
                throw UnifiedRuntimeError.remote(stderr.isEmpty ? "SSH Terminal Proxy 退出异常" : stderr)
            }
            guard let line = stdout.split(separator: 0x0A).first else {
                throw UnifiedRuntimeError.remote(stderr.isEmpty ? "SSH Terminal Proxy 未返回响应" : stderr)
            }
            let response = try JSONDecoder.terminalHelperResponse.decode(TerminalHelperResponse.self, from: line)
            guard response.ok else { throw UnifiedRuntimeError.remote(response.output) }
            return response
        } catch {
            disconnect()
            let detail = SecretRedactor.redact(error.localizedDescription)
            throw UnifiedRuntimeError.remote("SSH Terminal Proxy 中断；结果未知，请重连后 Attach。原因：\(detail)")
        }
    }

    private func decode<T: Decodable>(_ output: String, as type: T.Type) throws -> T { try JSONDecoder.terminalHelper.decode(T.self, from: Data(output.utf8)) }
    private func ensureRemoteDaemon() throws {
        guard SSHToolHostInstaller.fingerprintMatches(expected: host.fingerprint, observed: observedFingerprint) else { throw SSHConnectionError.fingerprintChanged }
        let root = remoteRootExpression()
        let socket = remoteSocket()
        let executable = remoteExecutable()
        let command = "root=\(root); socket=\(socket); mkdir -p \"$root\"; if [ -S \"$socket\" ] && [ -f \"$root/daemon.json\" ] && \(executable) --terminal-helper-health --socket \"$socket\" --descriptor \"$root/daemon.json\" >/dev/null 2>&1; then exit 0; fi; rm -f \"$socket\" \"$root/daemon.json\"; nohup \(executable) --terminal-helper-daemon --root \"$root\" --socket \"$socket\" --descriptor \"$root/daemon.json\" >\"$root/daemon.log\" 2>&1 < /dev/null & for i in 1 2 3 4 5 6 7 8 9 10; do [ -S \"$socket\" ] && [ -f \"$root/daemon.json\" ] && exit 0; sleep 1; done; [ -f \"$root/daemon.log\" ] && cat \"$root/daemon.log\" >&2; exit 1"
        let check = Process()
        let errors = Pipe()
        check.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        check.arguments = SSHClientArguments.options(for: host) + ["\(host.user)@\(host.hostname)", "--", command]
        check.standardOutput = FileHandle.nullDevice
        check.standardError = errors
        try check.run()
        check.waitUntilExit()
        guard check.terminationStatus == 0 else {
            let detail = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            throw UnifiedRuntimeError.remote(detail.isEmpty ? "远程 Terminal daemon 启动失败" : SecretRedactor.redact(detail))
        }
    }

    private func remoteRootExpression() -> String { "\"$HOME/\(remoteRoot)\"" }
    /// Keep the control socket out of the durable registry directory. macOS
    /// has a short Unix-domain path limit; home directories or project names
    /// can otherwise prevent a remote daemon from starting at all.
    private func remoteSocket() -> String {
        let source = "\(host.user)@\(host.hostname):\(host.port):\(remoteRoot)"
        let digest = SHA256.hash(data: Data(source.utf8)).map { String(format: "%02x", $0) }.joined()
        return shellQuote("/tmp/deepseek-code-\(digest.prefix(20)).sock")
    }
    private func remoteDescriptor() -> String { "\"$HOME/\(remoteRoot)/daemon.json\"" }
    private func remoteExecutable() -> String {
        if remotePath.hasPrefix("~/") { return "\"$HOME\"/\(shellQuote(String(remotePath.dropFirst(2))))" }
        if remotePath.hasPrefix("$HOME/") { return "\"$HOME\"/\(shellQuote(String(remotePath.dropFirst(6))))" }
        return shellQuote(remotePath)
    }
    private static func safeComponent(_ value: String) -> String { value.map { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == "_" ? $0 : "-" }.reduce(into: "") { $0.append($1) } }
    private func shellQuote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
}

/// Server used by the standalone Helper executable. The service owns all PTY
/// descriptors, so the App can terminate without killing approved sessions.
public final class TerminalHelperServer: @unchecked Sendable {
    private let service: PersistentTerminalService
    private let descriptorURL: URL
    private let descriptor: TerminalHelperDescriptor
    private var responseCache: [String: TerminalHelperResponse] = [:]

    public init(service: PersistentTerminalService, socketPath: String, descriptorURL: URL, token: String = UUID().uuidString) throws {
        self.service = service
        self.descriptorURL = descriptorURL
        descriptor = TerminalHelperDescriptor(socketPath: socketPath, token: token)
    }

    public func run() async throws -> Never {
        let socketPath = descriptor.socketPath
        unlink(socketPath)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw UnifiedRuntimeError.remote("Terminal Helper Socket 创建失败") }
        defer { close(fd); unlink(socketPath) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketPath.utf8) + [0]
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard pathBytes.count <= capacity else { throw UnifiedRuntimeError.remote("Terminal Helper Socket 路径过长") }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            for index in 0..<buffer.count { buffer[index] = 0 }
            for (index, byte) in pathBytes.enumerated() { buffer[index] = byte }
        }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, listen(fd, 16) == 0 else { throw UnifiedRuntimeError.remote("Terminal Helper Socket 绑定失败") }
        chmod(socketPath, 0o600)
        try JSONEncoder.terminalHelper.encode(descriptor).write(to: descriptorURL, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: descriptorURL.path)

        while true {
            let client = accept(fd, nil, nil)
            guard client >= 0 else { continue }
            let handle = FileHandle(fileDescriptor: client, closeOnDealloc: true)
            let requestData = try handle.readToEnd() ?? Data()
            let response = await handleRequest(requestData)
            try? handle.write(contentsOf: JSONEncoder.terminalHelperResponse.encode(response) + Data([0x0A]))
        }
    }

    public func runStdio() async throws {
        while let line = readLine(strippingNewline: true) {
            let response = await handleRequest(Data(line.utf8))
            if let encoded = try? JSONEncoder.terminalHelperResponse.encode(response) {
                FileHandle.standardOutput.write(encoded)
                FileHandle.standardOutput.write(Data([0x0A]))
            }
        }
    }

    private func handleRequest(_ data: Data) async -> TerminalHelperResponse {
        guard let line = String(decoding: data, as: UTF8.self).split(separator: "\n").first,
              let encoded = String(line).data(using: .utf8),
              let request = try? JSONDecoder.terminalHelper.decode(TerminalHelperRequest.self, from: encoded) else {
            return TerminalHelperResponse(id: UUID().uuidString, ok: false, output: "无效的 Terminal Helper 请求")
        }
        // A reconnect may resend the last framed request after a transport
        // timeout. Returning the exact prior response prevents duplicate
        // stdin, signals, closes, or other side effects.
        if let cached = responseCache[request.id] { return cached }
        let result = await handleAuthorizedRequest(request)
        if responseCache.count >= 512 { responseCache.removeValue(forKey: responseCache.keys.first!) }
        responseCache[request.id] = result
        return result
    }

    private func handleAuthorizedRequest(_ request: TerminalHelperRequest) async -> TerminalHelperResponse {
        guard request.token == descriptor.token, request.protocolVersion == descriptor.protocolVersion else {
            return TerminalHelperResponse(id: request.id, ok: false, output: "Terminal Helper 身份验证失败")
        }
        do {
            switch request.method {
            case TerminalHelperMethod.handshake:
                return TerminalHelperResponse(id: request.id, ok: true, output: String(decoding: try JSONEncoder.terminalHelper.encode(await service.handshake()), as: UTF8.self))
            case TerminalHelperMethod.open:
                let spec = try JSONDecoder.terminalHelper.decode(TerminalLaunchSpec.self, from: Data(request.payload.utf8))
                let record = try await service.open(spec: spec)
                return try response(id: request.id, value: record)
            case TerminalHelperMethod.attach:
                let receipt = try await service.attach(terminalID: request.terminalID ?? "")
                return try response(id: request.id, value: receipt)
            case TerminalHelperMethod.read:
                let args = try JSONSerialization.jsonObject(with: Data(request.payload.utf8)) as? [String: Any] ?? [:]
                let chunks = try await service.read(terminalID: request.terminalID ?? "", afterSequence: args["afterSequence"] as? Int ?? -1, maxBytes: args["maxBytes"] as? Int ?? 128_000)
                return try response(id: request.id, value: chunks)
            case TerminalHelperMethod.write:
                let args = try JSONSerialization.jsonObject(with: Data(request.payload.utf8)) as? [String: Any] ?? [:]
                guard let text = args["data"] as? String else { throw TerminalRuntimeError.invalidArguments }
                try await service.write(terminalID: request.terminalID ?? "", data: Data(text.utf8))
                return TerminalHelperResponse(id: request.id, ok: true, output: "{}")
            case TerminalHelperMethod.resize:
                let args = try JSONSerialization.jsonObject(with: Data(request.payload.utf8)) as? [String: Any] ?? [:]
                try await service.resize(terminalID: request.terminalID ?? "", columns: args["columns"] as? Int ?? 120, rows: args["rows"] as? Int ?? 30)
                return TerminalHelperResponse(id: request.id, ok: true, output: "{}")
            case TerminalHelperMethod.signal:
                let args = try JSONSerialization.jsonObject(with: Data(request.payload.utf8)) as? [String: Any] ?? [:]
                guard let raw = args["signal"] as? String, let signal = TerminalSignal(rawValue: raw) else { throw TerminalRuntimeError.invalidArguments }
                try await service.signal(terminalID: request.terminalID ?? "", signal: signal)
                return TerminalHelperResponse(id: request.id, ok: true, output: "{}")
            case TerminalHelperMethod.stopGracefully:
                try await service.stopGracefully(terminalID: request.terminalID ?? "")
                return TerminalHelperResponse(id: request.id, ok: true, output: "{}")
            case TerminalHelperMethod.protectedStatus:
                return try response(id: request.id, value: await service.protectedInputRequired(terminalID: request.terminalID ?? ""))
            case TerminalHelperMethod.writeProtected:
                let args = try JSONSerialization.jsonObject(with: Data(request.payload.utf8)) as? [String: Any] ?? [:]
                guard let text = args["data"] as? String else { throw TerminalRuntimeError.invalidArguments }
                try await service.writeProtectedInput(terminalID: request.terminalID ?? "", data: Data(text.utf8))
                return TerminalHelperResponse(id: request.id, ok: true, output: "{}")
            case TerminalHelperMethod.detach:
                try await service.detach(terminalID: request.terminalID ?? "")
                return TerminalHelperResponse(id: request.id, ok: true, output: "{}")
            case TerminalHelperMethod.close:
                try await service.close(terminalID: request.terminalID ?? "")
                return TerminalHelperResponse(id: request.id, ok: true, output: "{}")
            case TerminalHelperMethod.inspect:
                return try response(id: request.id, value: await service.inspect(terminalID: request.terminalID ?? ""))
            case TerminalHelperMethod.list:
                return try response(id: request.id, value: try await service.records(sessionID: request.sessionID))
            default:
                throw TerminalRuntimeError.invalidArguments
            }
        } catch let error as TerminalRuntimeError {
            return TerminalHelperResponse(id: request.id, ok: false, output: error.localizedDescription, indeterminate: error == .sessionNotFound ? false : true)
        } catch {
            return TerminalHelperResponse(id: request.id, ok: false, output: SecretRedactor.redact(error.localizedDescription), indeterminate: true)
        }
    }

    private func response<T: Encodable>(id: String, value: T) throws -> TerminalHelperResponse {
        TerminalHelperResponse(id: id, ok: true, output: String(decoding: try JSONEncoder.terminalHelper.encode(value), as: UTF8.self))
    }
}

private extension JSONEncoder {
    static var terminalHelper: JSONEncoder { let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .millisecondsSince1970; return encoder }
    static var terminalHelperResponse: JSONEncoder { terminalHelper }
}

private extension JSONDecoder {
    static var terminalHelper: JSONDecoder { let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .millisecondsSince1970; return decoder }
    static var terminalHelperResponse: JSONDecoder { terminalHelper }
}
