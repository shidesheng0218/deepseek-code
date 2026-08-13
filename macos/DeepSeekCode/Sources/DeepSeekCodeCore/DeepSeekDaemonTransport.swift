import Darwin
import Foundation

public struct DeepSeekDaemonDescriptor: Codable, Equatable, Sendable {
    public let protocolVersion: Int
    public let instanceID: String
    public let socketPath: String
    public let token: String
    public let startedAt: Date
    public let processID: Int32

    public init(
        protocolVersion: Int = DeepSeekDaemonProtocol.version,
        instanceID: String = "deepseekd-\(UUID().uuidString)",
        socketPath: String,
        token: String,
        startedAt: Date = Date(),
        processID: Int32 = Int32(getpid())
    ) {
        self.protocolVersion = protocolVersion
        self.instanceID = instanceID
        self.socketPath = socketPath
        self.token = token
        self.startedAt = startedAt
        self.processID = processID
    }
}

public enum DeepSeekDaemonPaths {
    public static func storageRoot() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("DeepSeekCode", isDirectory: true)
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("DeepSeekCode", isDirectory: true)
    }

    public static func runtimeRoot(storageRoot: URL) -> URL {
        storageRoot.appendingPathComponent("Runtime", isDirectory: true)
    }

    public static func descriptorURL(storageRoot: URL) -> URL {
        runtimeRoot(storageRoot: storageRoot).appendingPathComponent("deepseekd.json", isDirectory: false)
    }

    public static func socketPath(storageRoot: URL) -> String {
        let candidate = runtimeRoot(storageRoot: storageRoot).appendingPathComponent("deepseekd.sock", isDirectory: false).path
        // macOS sockaddr_un has a short path limit. A deterministic per-user
        // fallback keeps the endpoint local and never exposes a TCP port.
        if candidate.utf8.count < 100 { return candidate }
        return "/tmp/deepseekd-\(getuid()).sock"
    }
}

public enum DeepSeekDaemonTransportError: LocalizedError, Sendable {
    case socketUnavailable(String)
    case invalidResponse
    case authenticationFailed

    public var errorDescription: String? {
        switch self {
        case let .socketUnavailable(message): "无法连接 deepseekd：\(message)"
        case .invalidResponse: "deepseekd 返回了无效响应"
        case .authenticationFailed: "deepseekd 身份验证失败"
        }
    }
}

/// One framed request per Unix-domain connection. Retrying the same request
/// id is safe because the server memoizes the response before closing the
/// connection.
public struct DeepSeekDaemonClient: Sendable {
    public let descriptor: DeepSeekDaemonDescriptor
    public let timeout: TimeInterval

    public init(descriptor: DeepSeekDaemonDescriptor, timeout: TimeInterval = 15) {
        self.descriptor = descriptor
        self.timeout = timeout
    }

    public func send(_ request: DeepSeekDaemonRequest) async throws -> DeepSeekDaemonResponse {
        try await Task.detached(priority: .userInitiated) {
            let fd = try connect(path: descriptor.socketPath)
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            let authenticated = DeepSeekDaemonRequest(
                protocolVersion: request.protocolVersion,
                id: request.id,
                token: descriptor.token,
                method: request.method,
                payload: request.payload
            )
            try handle.write(contentsOf: DeepSeekDaemonJSON.encoder.encode(authenticated) + Data([0x0A]))
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
                  let response = try? DeepSeekDaemonJSON.decoder.decode(DeepSeekDaemonResponse.self, from: Data(line.utf8)) else {
                throw DeepSeekDaemonTransportError.invalidResponse
            }
            guard response.id == request.id else { throw DeepSeekDaemonTransportError.invalidResponse }
            if response.code == "AUTHENTICATION_FAILED" { throw DeepSeekDaemonTransportError.authenticationFailed }
            return response
        }.value
    }

    public static func loadDescriptor(storageRoot: URL = DeepSeekDaemonPaths.storageRoot()) throws -> DeepSeekDaemonDescriptor {
        try DeepSeekDaemonJSON.decoder.decode(
            DeepSeekDaemonDescriptor.self,
            from: Data(contentsOf: DeepSeekDaemonPaths.descriptorURL(storageRoot: storageRoot))
        )
    }

    private func connect(path: String) throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw DeepSeekDaemonTransportError.socketUnavailable(String(cString: strerror(errno))) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8) + [0]
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard pathBytes.count <= capacity else {
            close(fd)
            throw DeepSeekDaemonTransportError.socketUnavailable("Socket 路径过长")
        }
        withUnsafeMutableBytes(of: &address.sun_path) { bytes in
            bytes.initializeMemory(as: UInt8.self, repeating: 0)
            for (index, byte) in pathBytes.enumerated() { bytes[index] = byte }
        }
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            let message = String(cString: strerror(errno))
            close(fd)
            throw DeepSeekDaemonTransportError.socketUnavailable(message)
        }
        return fd
    }
}

/// Authenticated same-user Unix socket host for SessionSupervisor commands.
/// It owns no model credentials; providers are resolved by the daemon's
/// execution driver, while this transport only passes durable commands.
public final class DeepSeekDaemonServer: @unchecked Sendable {
    public let descriptor: DeepSeekDaemonDescriptor
    private let descriptorURL: URL
    private let router: DeepSeekDaemonCommandRouter
    private var responseCache: [String: DeepSeekDaemonResponse] = [:]

    public init(
        router: DeepSeekDaemonCommandRouter,
        storageRoot: URL = DeepSeekDaemonPaths.storageRoot(),
        token: String = UUID().uuidString,
        instanceID: String = "deepseekd-\(UUID().uuidString)"
    ) throws {
        let runtimeRoot = DeepSeekDaemonPaths.runtimeRoot(storageRoot: storageRoot)
        try FileManager.default.createDirectory(at: runtimeRoot, withIntermediateDirectories: true)
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: runtimeRoot.path)
        descriptorURL = DeepSeekDaemonPaths.descriptorURL(storageRoot: storageRoot)
        descriptor = DeepSeekDaemonDescriptor(instanceID: instanceID, socketPath: DeepSeekDaemonPaths.socketPath(storageRoot: storageRoot), token: token)
        self.router = router
    }

    public func run() async throws -> Never {
        let socketPath = descriptor.socketPath
        unlink(socketPath)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw DeepSeekDaemonTransportError.socketUnavailable(String(cString: strerror(errno))) }
        defer {
            close(fd)
            unlink(socketPath)
        }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketPath.utf8) + [0]
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard pathBytes.count <= capacity else { throw DeepSeekDaemonTransportError.socketUnavailable("Socket 路径过长") }
        withUnsafeMutableBytes(of: &address.sun_path) { bytes in
            bytes.initializeMemory(as: UInt8.self, repeating: 0)
            for (index, byte) in pathBytes.enumerated() { bytes[index] = byte }
        }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, listen(fd, 32) == 0 else {
            throw DeepSeekDaemonTransportError.socketUnavailable(String(cString: strerror(errno)))
        }
        chmod(socketPath, 0o600)
        try DeepSeekDaemonJSON.encoder.encode(descriptor).write(to: descriptorURL, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: descriptorURL.path)

        while true {
            let clientFD = accept(fd, nil, nil)
            guard clientFD >= 0 else { continue }
            let handle = FileHandle(fileDescriptor: clientFD, closeOnDealloc: true)
            let data = try handle.readToEnd() ?? Data()
            let response = await handleRequest(data)
            try? handle.write(contentsOf: DeepSeekDaemonJSON.encoder.encode(response) + Data([0x0A]))
        }
    }

    private func handleRequest(_ data: Data) async -> DeepSeekDaemonResponse {
        guard let line = String(decoding: data, as: UTF8.self).split(separator: "\n").first,
              let request = try? DeepSeekDaemonJSON.decoder.decode(DeepSeekDaemonRequest.self, from: Data(line.utf8)) else {
            return DeepSeekDaemonResponse(id: UUID().uuidString, ok: false, output: "无效 deepseekd 请求", code: "INVALID_REQUEST")
        }
        guard request.token == descriptor.token else {
            return DeepSeekDaemonResponse(id: request.id, ok: false, output: "deepseekd 身份验证失败", code: "AUTHENTICATION_FAILED")
        }
        if let cached = responseCache[request.id] { return cached }
        let response = await router.handle(request)
        if responseCache.count >= 512, let first = responseCache.keys.first { responseCache.removeValue(forKey: first) }
        responseCache[request.id] = response
        return response
    }
}
