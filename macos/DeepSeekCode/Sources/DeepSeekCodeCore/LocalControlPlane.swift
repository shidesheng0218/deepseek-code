import CryptoKit
import Foundation
import Network

public struct ControlPlanePairing: Codable, Equatable, Sendable {
    public let token: String
    public let url: URL
    public let loopbackURLs: [URL]
    public let expiresAt: Date

    public init(token: String, url: URL, loopbackURLs: [URL] = [], expiresAt: Date) {
        self.token = token
        self.url = url
        self.loopbackURLs = loopbackURLs
        self.expiresAt = expiresAt
    }
}

public struct ControlPlaneRequest: Sendable {
    public let method: String
    public let path: String
    public let headers: [String: String]
    public let body: Data

    public init(method: String, path: String, headers: [String: String], body: Data = Data()) {
        self.method = method
        self.path = path
        self.headers = headers
        self.body = body
    }
}

public struct ControlPlaneResponse: Sendable {
    public let status: Int
    public let contentType: String
    public let body: Data
    public let apiVersion: String

    public init(status: Int = 200, contentType: String = "application/json", body: Data = Data("{}".utf8), apiVersion: String = "v1") {
        self.status = status
        self.contentType = contentType
        self.body = body
        self.apiVersion = apiVersion
    }

    public static func json<T: Encodable>(_ value: T, status: Int = 200) -> ControlPlaneResponse {
        let data = (try? JSONEncoder().encode(value)) ?? Data("{}".utf8)
        return ControlPlaneResponse(status: status, body: data)
    }
}

public struct ControlPlaneInputPayload: Codable, Sendable {
    public let text: String
    public let idempotencyKey: String?

    public init(text: String, idempotencyKey: String? = nil) {
        self.text = text
        self.idempotencyKey = idempotencyKey
    }
}

/// Loopback-only control plane. It owns transport and pairing but delegates
/// session operations to the existing Supervisor/Repository layer. No API
/// credentials, raw attachments or unredacted terminal output are exposed.
public final class LocalControlPlane: @unchecked Sendable {
    public typealias Handler = @Sendable (ControlPlaneRequest) async -> ControlPlaneResponse

    private let queue = DispatchQueue(label: "com.deepseekcode.control-plane")
    private let secretStore: (any SecretStore)?
    private let tokenReference: String
    private let handler: Handler
    private var listener: NWListener?
    private var ipv6Listener: NWListener?
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var activeToken = ""
    private var tokenExpiresAt = Date.distantPast
    private var port: NWEndpoint.Port?
    private var ipv6Port: NWEndpoint.Port?

    public init(
        secretStore: (any SecretStore)? = nil,
        tokenReference: String = "keychain://control-plane-pairing",
        handler: @escaping Handler
    ) {
        self.secretStore = secretStore
        self.tokenReference = tokenReference
        self.handler = handler
    }

    @discardableResult
    public func start(ttl: TimeInterval = 600) throws -> ControlPlanePairing {
        stop()
        let token = Self.makeToken()
        activeToken = token
        tokenExpiresAt = Date().addingTimeInterval(max(60, ttl))
        try? secretStore?.save(reference: tokenReference, value: token)

        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.stateUpdateHandler = { [weak self] state in
            if case .ready = state {
                self?.port = self?.listener?.port
            }
        }
        listener.start(queue: queue)
        self.listener = listener

        // Also expose an IPv6 loopback endpoint when the host supports it.
        // IPv4 remains the primary compatibility URL if IPv6 is unavailable.
        let ipv6Parameters = NWParameters.tcp
        ipv6Parameters.allowLocalEndpointReuse = true
        ipv6Parameters.requiredLocalEndpoint = .hostPort(host: "::1", port: .any)
        if let ipv6 = try? NWListener(using: ipv6Parameters) {
            ipv6.newConnectionHandler = { [weak self] connection in
                self?.accept(connection)
            }
            ipv6.stateUpdateHandler = { [weak self] state in
                if case .ready = state {
                    self?.ipv6Port = self?.ipv6Listener?.port
                }
            }
            self.ipv6Listener = ipv6
            ipv6.start(queue: queue)
        }

        let deadline = Date().addingTimeInterval(2)
        while port == nil && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        guard let port else { throw ControlPlaneError.startFailed }
        var loopbackURLs = [URL(string: "http://127.0.0.1:\(port.rawValue)")!]
        if let ipv6Port {
            loopbackURLs.append(URL(string: "http://[::1]:\(ipv6Port.rawValue)")!)
        }
        return ControlPlanePairing(
            token: token,
            url: loopbackURLs[0],
            loopbackURLs: loopbackURLs,
            expiresAt: tokenExpiresAt
        )
    }

    public func stop() {
        listener?.cancel()
        ipv6Listener?.cancel()
        listener = nil
        ipv6Listener = nil
        connections.values.forEach { $0.cancel() }
        connections.removeAll()
        activeToken = ""
        tokenExpiresAt = .distantPast
        port = nil
        ipv6Port = nil
    }

    public func revokePairing() {
        activeToken = ""
        tokenExpiresAt = .distantPast
        try? secretStore?.remove(reference: tokenReference)
        connections.values.forEach { $0.cancel() }
        connections.removeAll()
    }

    public func publish(event: Encodable) {
        guard let data = try? JSONEncoder().encode(event) else { return }
        queue.async { [weak self] in
            guard let self else { return }
            let frame = Self.webSocketTextFrame(data)
            self.connections.values.forEach { $0.send(content: frame, completion: .contentProcessed { _ in }) }
        }
    }

    private func accept(_ connection: NWConnection) {
        let identifier = ObjectIdentifier(connection)
        connections[identifier] = connection
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            if case .failed = state { self.connections.removeValue(forKey: identifier) }
            if case .cancelled = state { self.connections.removeValue(forKey: identifier) }
        }
        connection.start(queue: queue)
        receive(connection, identifier: identifier, buffer: Data())
    }

    private func receive(_ connection: NWConnection, identifier: ObjectIdentifier, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [weak self, weak connection] data, _, isComplete, error in
            guard let self, let connection else { return }
            if let error {
                self.connections.removeValue(forKey: identifier)
                connection.cancel()
                _ = error
                return
            }
            var combined = buffer
            if let data { combined.append(data) }
            if let request = Self.parseRequest(combined) {
                Task {
                    await self.respond(request, on: connection, identifier: identifier)
                }
                return
            }
            if isComplete {
                self.connections.removeValue(forKey: identifier)
                return
            }
            self.receive(connection, identifier: identifier, buffer: combined)
        }
    }

    private func respond(_ request: ControlPlaneRequest, on connection: NWConnection, identifier: ObjectIdentifier) async {
        guard isAuthorized(request) else {
            send(ControlPlaneResponse(status: 401, body: Data("{\"error\":\"unauthorized\"}".utf8)), on: connection, identifier: identifier)
            return
        }
        if let requestedVersion = request.headers["x-deepseek-api-version"], requestedVersion != "v1" {
            send(ControlPlaneResponse(status: 426, body: Data("{\"error\":\"unsupported api version\",\"supported\":\"v1\"}".utf8)), on: connection, identifier: identifier)
            return
        }
        if request.headers["upgrade"]?.lowercased() == "websocket" {
            guard let key = request.headers["sec-websocket-key"] else {
                send(ControlPlaneResponse(status: 400, body: Data("{\"error\":\"missing websocket key\"}".utf8)), on: connection, identifier: identifier)
                return
            }
            let accept = Self.webSocketAccept(key)
            let response = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: \(accept)\r\n\r\n"
            connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in })
            return
        }
        let response = await handler(request)
        send(response, on: connection, identifier: identifier)
    }

    private func send(_ response: ControlPlaneResponse, on connection: NWConnection, identifier: ObjectIdentifier) {
        let reason = Self.reason(response.status)
        let header = "HTTP/1.1 \(response.status) \(reason)\r\nContent-Type: \(response.contentType)\r\nX-DeepSeek-API-Version: \(response.apiVersion)\r\nContent-Length: \(response.body.count)\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(header.utf8) + response.body, completion: .contentProcessed { [weak self, weak connection] _ in
            guard let self else { return }
            self.connections.removeValue(forKey: identifier)
            connection?.cancel()
        })
    }

    private func isAuthorized(_ request: ControlPlaneRequest) -> Bool {
        guard !activeToken.isEmpty, Date() < tokenExpiresAt else { return false }
        guard let authorization = request.headers["authorization"] else { return false }
        let parts = authorization.split(separator: " ", maxSplits: 1).map(String.init)
        guard parts.count == 2, parts[0].lowercased() == "bearer" else { return false }
        return parts[1] == activeToken
    }

    private static func parseRequest(_ data: Data) -> ControlPlaneRequest? {
        guard let text = String(data: data, encoding: .utf8), let separator = text.range(of: "\r\n\r\n") else { return nil }
        let headerText = String(text[..<separator.lowerBound])
        let bodyText = String(text[separator.upperBound...])
        // CRLF is one extended grapheme cluster in Swift's String model, so
        // splitting directly on Character("\n") silently leaves all headers
        // in one line. Normalize first to make Authorization and Content-
        // Length parsing deterministic for URLSession and curl clients.
        let normalizedHeaderText = headerText.replacingOccurrences(of: "\r\n", with: "\n")
        let lines = normalizedHeaderText.split(separator: "\n").map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
        guard let first = lines.first else { return nil }
        let requestParts = first.split(separator: " ", maxSplits: 2).map(String.init)
        guard requestParts.count == 3 else { return nil }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let index = line.firstIndex(of: ":") else { continue }
            let key = line[..<index].lowercased()
            headers[key] = line[line.index(after: index)...].trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let length = Int(headers["content-length"] ?? "0"), bodyText.utf8.count < length { return nil }
        return ControlPlaneRequest(method: requestParts[0], path: requestParts[1], headers: headers, body: Data(bodyText.utf8))
    }

    private static func makeToken() -> String {
        let bytes = (0..<32).map { _ in UInt8.random(in: 0...255) }
        return Data(bytes).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    private static func webSocketAccept(_ key: String) -> String {
        let value = key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
        return Data(Insecure.SHA1.hash(data: Data(value.utf8))).base64EncodedString()
    }

    private static func webSocketTextFrame(_ payload: Data) -> Data {
        var frame = Data([0x81])
        if payload.count < 126 {
            frame.append(UInt8(payload.count))
        } else if payload.count <= 0xFFFF {
            frame.append(126)
            frame.append(UInt8((payload.count >> 8) & 0xFF))
            frame.append(UInt8(payload.count & 0xFF))
        } else {
            frame.append(127)
            frame.append(contentsOf: withUnsafeBytes(of: UInt64(payload.count).bigEndian, Array.init))
        }
        frame.append(payload)
        return frame
    }

    private static func reason(_ status: Int) -> String {
        switch status {
        case 200: "OK"
        case 201: "Created"
        case 400: "Bad Request"
        case 401: "Unauthorized"
        case 404: "Not Found"
        case 409: "Conflict"
        case 426: "Upgrade Required"
        case 500: "Internal Server Error"
        default: "Response"
        }
    }
}

public enum ControlPlaneError: LocalizedError, Sendable {
    case startFailed

    public var errorDescription: String? { "本机 Control Plane 启动失败" }
}
