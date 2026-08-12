import CryptoKit
import Darwin
import Foundation

public enum TerminalHelperProtocol {
    public static let currentHostVersion = "1.1.0"
}

/// Versioned capabilities exchanged between the App and a persistent
/// terminal helper. Keeping this separate from the model/tool schema lets the
/// helper evolve without exposing transport details to the Agent.
public struct TerminalCapabilityHandshake: Codable, Equatable, Sendable {
    public let protocolVersion: Int
    public let hostVersion: String
    public let capabilities: [String]
    public let instanceID: String

    public init(protocolVersion: Int = 1, hostVersion: String = TerminalHelperProtocol.currentHostVersion, capabilities: [String] = [], instanceID: String = UUID().uuidString) {
        self.protocolVersion = protocolVersion
        self.hostVersion = hostVersion
        self.capabilities = capabilities
        self.instanceID = instanceID
    }
}

/// Durable identity used to decide whether a process is safe to reattach to.
/// It deliberately stores a command hash, never the raw command.
public struct TerminalProcessManifest: Codable, Equatable, Sendable {
    public let terminalID: String
    public let sessionID: String
    public let pid: Int32
    public let processGroupID: Int32
    public let startedAt: Date
    public let cwd: String
    public let commandHash: String
    public let target: TerminalTarget
    public let socketPath: String
    public let transcriptID: String
    public var lastOutputSequence: Int
    public var state: TerminalSessionState

    public init(terminalID: String, sessionID: String, pid: Int32, processGroupID: Int32, startedAt: Date, cwd: String, commandHash: String, target: TerminalTarget, socketPath: String, transcriptID: String, lastOutputSequence: Int = -1, state: TerminalSessionState = .starting) {
        self.terminalID = terminalID
        self.sessionID = sessionID
        self.pid = pid
        self.processGroupID = processGroupID
        self.startedAt = startedAt
        self.cwd = cwd
        self.commandHash = commandHash
        self.target = target
        self.socketPath = socketPath
        self.transcriptID = transcriptID
        self.lastOutputSequence = lastOutputSequence
        self.state = state
    }
}

public struct TerminalAttachReceipt: Codable, Equatable, Sendable {
    public let terminalID: String
    public let state: TerminalSessionState
    public let pid: Int32?
    public let processGroupID: Int32?
    public let lastOutputSequence: Int
    public let replayFromSequence: Int
    public let writable: Bool
    public let requiresApproval: Bool
    public let exitCode: Int32?

    public init(terminalID: String, state: TerminalSessionState, pid: Int32?, processGroupID: Int32?, lastOutputSequence: Int, replayFromSequence: Int, writable: Bool, requiresApproval: Bool, exitCode: Int32? = nil) {
        self.terminalID = terminalID
        self.state = state
        self.pid = pid
        self.processGroupID = processGroupID
        self.lastOutputSequence = lastOutputSequence
        self.replayFromSequence = replayFromSequence
        self.writable = writable
        self.requiresApproval = requiresApproval
        self.exitCode = exitCode
    }
}

public protocol PersistentTerminalHost: Sendable {
    func handshake() async throws -> TerminalCapabilityHandshake
    func open(spec: TerminalLaunchSpec) async throws -> TerminalSessionRecord
    func attach(terminalID: String) async throws -> TerminalAttachReceipt
    func read(terminalID: String, afterSequence: Int, maxBytes: Int) async throws -> [TerminalOutputChunk]
    func write(terminalID: String, data: Data) async throws
    func resize(terminalID: String, columns: Int, rows: Int) async throws
    func signal(terminalID: String, signal: TerminalSignal) async throws
    func detach(terminalID: String) async throws
    func close(terminalID: String) async throws
    func inspect(terminalID: String) async throws -> TerminalProcessInspection
}

public protocol PersistentTerminalInteractiveHost: PersistentTerminalHost {
    func writeProtectedInput(terminalID: String, data: Data) async throws
    func protectedInputRequired(terminalID: String) async -> Bool
    func stopGracefully(terminalID: String) async throws
}

/// File-backed process registry. Each manifest is written atomically so an
/// App crash cannot leave a partially decoded registry entry.
public final class PersistentTerminalRegistry: @unchecked Sendable {
    private let root: URL
    private let lock = NSLock()

    public init(root: URL) throws {
        self.root = root.appendingPathComponent("registry", isDirectory: true)
        try FileManager.default.createDirectory(at: self.root, withIntermediateDirectories: true)
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: self.root.path)
    }

    public func save(_ manifest: TerminalProcessManifest) throws {
        lock.lock(); defer { lock.unlock() }
        let url = fileURL(for: manifest.terminalID)
        let data = try JSONEncoder.terminal.encode(manifest)
        try data.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    public func manifest(terminalID: String) throws -> TerminalProcessManifest? {
        lock.lock(); defer { lock.unlock() }
        let url = fileURL(for: terminalID)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder.terminal.decode(TerminalProcessManifest.self, from: Data(contentsOf: url))
    }

    public func manifests(sessionID: String? = nil) throws -> [TerminalProcessManifest] {
        lock.lock(); defer { lock.unlock() }
        let urls = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
        return urls.compactMap { url in
            guard let value = try? JSONDecoder.terminal.decode(TerminalProcessManifest.self, from: Data(contentsOf: url)) else { return nil }
            return sessionID == nil || value.sessionID == sessionID ? value : nil
        }.sorted { $0.startedAt < $1.startedAt }
    }

    public func remove(terminalID: String) throws {
        lock.lock(); defer { lock.unlock() }
        try? FileManager.default.removeItem(at: fileURL(for: terminalID))
    }

    private func fileURL(for terminalID: String) -> URL {
        let safeID = terminalID.replacingOccurrences(of: "[^A-Za-z0-9._-]", with: "_", options: .regularExpression)
        return root.appendingPathComponent("\(safeID).json")
    }
}

/// Append-only, encrypted output chunks. SQLite stores only the manifest and
/// hashes; transcript bytes remain local and are never inserted into model
/// context automatically.
public final class TerminalTranscriptStore: @unchecked Sendable {
    private struct ChunkMeta: Codable, Equatable, Sendable {
        let sequence: Int
        let sessionID: String
        let byteCount: Int
        let contentHash: String
        let filename: String
        let createdAt: Date
    }

    private struct Manifest: Codable, Equatable, Sendable {
        let terminalID: String
        let sessionID: String
        var chunks: [ChunkMeta]
    }

    private let root: URL
    private let secretStore: any SecretStore
    private let lock = NSLock()

    public init(root: URL, secretStore: any SecretStore) throws {
        self.root = root.appendingPathComponent("transcripts", isDirectory: true)
        self.secretStore = secretStore
        try FileManager.default.createDirectory(at: self.root, withIntermediateDirectories: true)
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: self.root.path)
    }

    public func append(terminalID: String, sessionID: String, text: String) throws -> TerminalOutputChunk {
        guard !text.isEmpty else { throw TerminalRuntimeError.invalidArguments }
        lock.lock(); defer { lock.unlock() }
        let directory = directoryURL(for: terminalID)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var manifest = try loadManifest(terminalID: terminalID) ?? Manifest(terminalID: terminalID, sessionID: sessionID, chunks: [])
        let sequence = manifest.chunks.last.map { $0.sequence + 1 } ?? 0
        let data = Data(text.utf8)
        let hash = Self.sha256(data)
        let filename = String(format: "chunk-%06d.bin", sequence)
        let sealed = try seal(data)
        try sealed.write(to: directory.appendingPathComponent(filename), options: .atomic)
        let meta = ChunkMeta(sequence: sequence, sessionID: sessionID, byteCount: data.count, contentHash: hash, filename: filename, createdAt: Date())
        manifest.chunks.append(meta)
        try saveManifest(manifest)
        return TerminalOutputChunk(sessionID: sessionID, text: text, sequence: sequence)
    }

    public func read(terminalID: String, afterSequence: Int, maxBytes: Int) throws -> [TerminalOutputChunk] {
        lock.lock(); defer { lock.unlock() }
        guard let manifest = try loadManifest(terminalID: terminalID) else { return [] }
        var result: [TerminalOutputChunk] = []
        var used = 0
        for meta in manifest.chunks where meta.sequence > afterSequence {
            let data = try open(Data(contentsOf: directoryURL(for: terminalID).appendingPathComponent(meta.filename)))
            guard Self.sha256(data) == meta.contentHash else { throw UnifiedRuntimeError.remote("Terminal 输出校验失败") }
            let limit = max(1, maxBytes)
            // Sequence-based replay cannot safely represent a partial chunk;
            // return whole chunks only. A single oversized chunk is returned
            // whole so callers never silently lose its tail.
            if used > 0 && used + data.count > limit { break }
            result.append(TerminalOutputChunk(sessionID: meta.sessionID, text: String(decoding: data, as: UTF8.self), sequence: meta.sequence, createdAt: meta.createdAt))
            used += data.count
        }
        return result
    }

    public func lastSequence(terminalID: String) throws -> Int { try loadManifest(terminalID: terminalID)?.chunks.last?.sequence ?? -1 }

    public func remove(terminalID: String) throws { lock.lock(); defer { lock.unlock() }; try? FileManager.default.removeItem(at: directoryURL(for: terminalID)) }

    private func directoryURL(for terminalID: String) -> URL {
        let safeID = terminalID.replacingOccurrences(of: "[^A-Za-z0-9._-]", with: "_", options: .regularExpression)
        return root.appendingPathComponent(safeID, isDirectory: true)
    }

    private func manifestURL(for terminalID: String) -> URL { directoryURL(for: terminalID).appendingPathComponent("manifest.json") }

    private func loadManifest(terminalID: String) throws -> Manifest? {
        let url = manifestURL(for: terminalID)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder.terminal.decode(Manifest.self, from: Data(contentsOf: url))
    }

    private func saveManifest(_ manifest: Manifest) throws {
        try JSONEncoder.terminal.encode(manifest).write(to: manifestURL(for: manifest.terminalID), options: .atomic)
    }

    private func key() throws -> SymmetricKey {
        let reference = "keychain://deepseek-terminal-transcript-v1"
        if let encoded = try secretStore.load(reference: reference), let data = Data(base64Encoded: encoded), data.count == 32 { return SymmetricKey(data: data) }
        let data = Data((0..<32).map { _ in UInt8.random(in: .min ... .max) })
        try secretStore.save(reference: reference, value: data.base64EncodedString())
        return SymmetricKey(data: data)
    }

    private func seal(_ data: Data) throws -> Data { guard let combined = try AES.GCM.seal(data, using: key()).combined else { throw UnifiedRuntimeError.remote("Terminal 输出加密失败") }; return combined }
    private func open(_ data: Data) throws -> Data { try AES.GCM.open(try AES.GCM.SealedBox(combined: data), using: key()) }
    private static func sha256(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}

/// The stateful side of the persistent terminal protocol. It is intentionally
/// usable in-process for tests and by the standalone Helper executable in
/// production; the App talks to the same contract through a broker.
public actor PersistentTerminalService: PersistentTerminalInteractiveHost {
    private let localHost: LocalTerminalHost
    private let registry: PersistentTerminalRegistry
    private let transcriptStore: TerminalTranscriptStore
    private let socketPath: String

    public init(root: URL, secretStore: any SecretStore, socketPath: String = "") throws {
        registry = try PersistentTerminalRegistry(root: root)
        transcriptStore = try TerminalTranscriptStore(root: root, secretStore: secretStore)
        self.socketPath = socketPath
        localHost = LocalTerminalHost(registry: registry, transcriptStore: transcriptStore, socketPath: socketPath)
    }

    public func handshake() async throws -> TerminalCapabilityHandshake {
        TerminalCapabilityHandshake(capabilities: ["open", "attach", "read", "write", "resize", "signal", "detach", "close", "inspect", "transcript-replay"])
    }

    public func open(spec: TerminalLaunchSpec) async throws -> TerminalSessionRecord {
        guard spec.target == .local || spec.target == .worktree else { throw TerminalRuntimeError.unsupportedTarget }
        return try await localHost.open(spec: spec)
    }

    public func attach(terminalID: String) async throws -> TerminalAttachReceipt {
        if let record = await localHost.record(terminalID: terminalID) {
            let sequence = try transcriptStore.lastSequence(terminalID: terminalID)
            return TerminalAttachReceipt(
                terminalID: terminalID,
                state: record.state,
                pid: record.pid,
                processGroupID: record.pid,
                lastOutputSequence: sequence,
                replayFromSequence: max(-1, sequence),
                writable: ![.exited, .failed, .stopped, .indeterminate, .needsAttention].contains(record.state),
                requiresApproval: false,
                exitCode: record.exitCode
            )
        }
        guard let manifest = try registry.manifest(terminalID: terminalID) else { throw TerminalRuntimeError.sessionNotFound }
        // A manifest without this Helper's live PTY descriptor proves only
        // process existence, not safe stdin/stdout ownership. Do not pretend
        // it is attachable: surface it for explicit user attention instead.
        return TerminalAttachReceipt(
            terminalID: terminalID,
            state: .needsAttention,
            pid: manifest.pid,
            processGroupID: manifest.processGroupID,
            lastOutputSequence: manifest.lastOutputSequence,
            replayFromSequence: manifest.lastOutputSequence,
            writable: false,
            requiresApproval: true
        )
    }

    public func read(terminalID: String, afterSequence: Int, maxBytes: Int) async throws -> [TerminalOutputChunk] {
        try transcriptStore.read(terminalID: terminalID, afterSequence: afterSequence, maxBytes: maxBytes)
    }

    public func write(terminalID: String, data: Data) async throws {
        try await localHost.write(sessionID: terminalID, data: data)
    }

    public func resize(terminalID: String, columns: Int, rows: Int) async throws {
        try await localHost.resize(sessionID: terminalID, columns: columns, rows: rows)
    }

    public func signal(terminalID: String, signal: TerminalSignal) async throws {
        try await localHost.signal(sessionID: terminalID, signal: signal)
    }

    public func stopGracefully(terminalID: String) async throws {
        try await localHost.stopGracefully(sessionID: terminalID)
    }

    public func detach(terminalID: String) async throws {
        _ = try await attach(terminalID: terminalID)
    }

    public func close(terminalID: String) async throws {
        try await localHost.close(sessionID: terminalID)
    }

    public func inspect(terminalID: String) async throws -> TerminalProcessInspection {
        if let record = await localHost.record(terminalID: terminalID) {
            return TerminalProcessInspector.inspect(record)
        }
        guard let manifest = try registry.manifest(terminalID: terminalID) else { throw TerminalRuntimeError.sessionNotFound }
        let isRunning = kill(manifest.pid, 0) == 0 || errno == EPERM
        return TerminalProcessInspection(isRunning: isRunning, commandMatches: false, cwdMatches: false)
    }

    public func records(sessionID: String) async throws -> [TerminalSessionRecord] {
        let live = await localHost.records(for: sessionID)
        let liveIDs = Set(live.map(\.id))
        let persisted = try registry.manifests(sessionID: sessionID).filter { !liveIDs.contains($0.terminalID) }.map { manifest in
            TerminalSessionRecord(
                id: manifest.terminalID,
                sessionID: manifest.sessionID,
                target: manifest.target,
                cwd: manifest.cwd,
                command: nil,
                pid: manifest.pid,
                state: .needsAttention,
                startedAt: manifest.startedAt,
                outputHash: nil
            )
        }
        return (live + persisted).sorted { $0.startedAt < $1.startedAt }
    }

    public func protectedInputRequired(terminalID: String) async -> Bool {
        await localHost.protectedInputRequired(terminalID: terminalID)
    }

    public func writeProtectedInput(terminalID: String, data: Data) async throws {
        try await localHost.writeProtectedInput(sessionID: terminalID, data: data)
    }
}

/// Reconciles SQLite terminal records with the persistent Helper after an App
/// restart. It never launches a missing command and never sends a signal on
/// an uncertain result.
public struct PersistentTerminalRecoveryCoordinator: Sendable {
    public let repository: SessionRepository
    public let host: any PersistentTerminalHost

    public init(repository: SessionRepository, host: any PersistentTerminalHost) {
        self.repository = repository
        self.host = host
    }

    public func recover(sessionID: String) async throws -> [TerminalSessionRecord] {
        let stored = try repository.terminalSessions(sessionID: sessionID)
        var recovered: [TerminalSessionRecord] = []
        for record in stored {
            do {
                let receipt = try await host.attach(terminalID: record.id)
                let state = receipt.requiresApproval ? TerminalSessionState.needsAttention : receipt.state
                let updated = TerminalSessionRecord(
                    id: record.id,
                    sessionID: record.sessionID,
                    target: record.target,
                    cwd: record.cwd,
                    command: record.command,
                    pid: receipt.pid ?? record.pid,
                    state: state,
                    columns: record.columns,
                    rows: record.rows,
                    startedAt: record.startedAt,
                    endedAt: [.exited, .failed, .stopped].contains(state) ? (record.endedAt ?? Date()) : record.endedAt,
                    exitCode: record.exitCode,
                    outputHash: record.outputHash,
                    portIDs: record.portIDs
                )
                try repository.saveTerminalSession(updated)
                try repository.append(sessionID: sessionID, type: state == .needsAttention ? "terminal_indeterminate" : "terminal_attached", payload: ["terminalID": record.id, "detail": state == .needsAttention ? "Helper 返回需要确认，未自动接管" : "已从持久 Helper 恢复"])
                recovered.append(updated)
            } catch {
                var needsAttention = record
                needsAttention.state = .needsAttention
                try repository.saveTerminalSession(needsAttention)
                try repository.append(sessionID: sessionID, type: "terminal_indeterminate", payload: ["terminalID": record.id, "detail": "Helper 无法确认终端状态；未自动重放"])
                recovered.append(needsAttention)
            }
        }
        return recovered
    }
}

private extension JSONEncoder {
    static var terminal: JSONEncoder { let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .millisecondsSince1970; return encoder }
}

private extension JSONDecoder {
    static var terminal: JSONDecoder { let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .millisecondsSince1970; return decoder }
}
