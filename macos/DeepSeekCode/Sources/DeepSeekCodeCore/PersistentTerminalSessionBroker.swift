import Foundation

/// Compatibility adapter for environments where the bundled Helper binary is
/// unavailable (tests or an incomplete legacy install). It remains explicit
/// in status UI and is never used by a valid packaged App.
public actor LegacyPersistentTerminalHost: PersistentTerminalInteractiveHost {
    private let local: LocalTerminalHost

    public init(local: LocalTerminalHost) { self.local = local }

    public func handshake() async throws -> TerminalCapabilityHandshake { TerminalCapabilityHandshake(capabilities: ["legacy-in-process"]) }
    public func open(spec: TerminalLaunchSpec) async throws -> TerminalSessionRecord { try await local.open(spec: spec) }
    public func attach(terminalID: String) async throws -> TerminalAttachReceipt {
        guard let record = await local.record(terminalID: terminalID) else { throw TerminalRuntimeError.sessionNotFound }
        return TerminalAttachReceipt(terminalID: terminalID, state: record.state, pid: record.pid, processGroupID: record.pid, lastOutputSequence: -1, replayFromSequence: -1, writable: [.running, .background, .starting].contains(record.state), requiresApproval: false, exitCode: record.exitCode)
    }
    public func read(terminalID: String, afterSequence: Int, maxBytes: Int) async throws -> [TerminalOutputChunk] { [try await local.read(sessionID: terminalID, maxBytes: maxBytes)] }
    public func write(terminalID: String, data: Data) async throws { try await local.write(sessionID: terminalID, data: data) }
    public func writeProtectedInput(terminalID: String, data: Data) async throws { try await local.writeProtectedInput(sessionID: terminalID, data: data) }
    public func protectedInputRequired(terminalID: String) async -> Bool { await local.protectedInputRequired(terminalID: terminalID) }
    public func resize(terminalID: String, columns: Int, rows: Int) async throws { try await local.resize(sessionID: terminalID, columns: columns, rows: rows) }
    public func signal(terminalID: String, signal: TerminalSignal) async throws { try await local.signal(sessionID: terminalID, signal: signal) }
    public func stopGracefully(terminalID: String) async throws { try await local.stopGracefully(sessionID: terminalID) }
    public func detach(terminalID: String) async throws { try await local.attach(sessionID: terminalID) }
    public func close(terminalID: String) async throws { try await local.close(sessionID: terminalID) }
    public func inspect(terminalID: String) async throws -> TerminalProcessInspection {
        guard let record = await local.record(terminalID: terminalID) else { throw TerminalRuntimeError.sessionNotFound }
        return TerminalProcessInspector.inspect(record)
    }
}

/// The single terminal surface consumed by SwiftUI and manual terminal
/// actions. It owns no PTY itself; every endpoint is a persistent Helper host.
public actor PersistentTerminalSessionBroker: TerminalHost {
    public typealias SSHHostResolver = @Sendable (String) async throws -> any PersistentTerminalHost

    private let localHost: any PersistentTerminalHost
    private let sshResolver: SSHHostResolver?
    private var hosts: [String: any PersistentTerminalHost] = [:]
    private var recordsByID: [String: TerminalSessionRecord] = [:]
    private var cursors: [String: Int] = [:]
    private var buffers: [String: TerminalOutputBuffer] = [:]
    private var protectedStates: Set<String> = []

    public init(localHost: any PersistentTerminalHost, sshResolver: SSHHostResolver? = nil) {
        self.localHost = localHost
        self.sshResolver = sshResolver
    }

    public func open(spec: TerminalLaunchSpec) async throws -> TerminalSessionRecord {
        let host: any PersistentTerminalHost
        switch spec.target {
        case .local, .worktree:
            host = localHost
        case let .ssh(hostID):
            guard let sshResolver else { throw TerminalRuntimeError.unsupportedTarget }
            host = try await sshResolver(hostID)
        }
        let record = try await host.open(spec: spec)
        hosts[record.id] = host
        recordsByID[record.id] = record
        cursors[record.id] = -1
        buffers[record.id] = TerminalOutputBuffer()
        return record
    }

    public func write(sessionID: String, data: Data) async throws {
        let id = resolveID(sessionID)
        guard !protectedStates.contains(id) else { throw TerminalRuntimeError.protectedInputRequired }
        try await (try await host(for: id)).write(terminalID: id, data: data)
    }

    public func writeProtectedInput(sessionID: String, data: Data) async throws {
        let id = resolveID(sessionID)
        if let interactive = try await host(for: id) as? any PersistentTerminalInteractiveHost {
            try await interactive.writeProtectedInput(terminalID: id, data: data)
        } else {
            throw TerminalRuntimeError.protectedInputRequired
        }
        protectedStates.remove(id)
    }

    public func resize(sessionID: String, columns: Int, rows: Int) async throws {
        let id = resolveID(sessionID)
        try await (try await host(for: id)).resize(terminalID: id, columns: columns, rows: rows)
        if var record = recordsByID[id] {
            record.columns = max(1, columns)
            record.rows = max(1, rows)
            recordsByID[id] = record
        }
    }

    public func signal(sessionID: String, signal: TerminalSignal) async throws {
        let id = resolveID(sessionID)
        try await (try await host(for: id)).signal(terminalID: id, signal: signal)
    }

    public func stopGracefully(sessionID: String) async throws {
        let id = resolveID(sessionID)
        if let interactive = try await host(for: id) as? any PersistentTerminalInteractiveHost {
            try await interactive.stopGracefully(terminalID: id)
        } else {
            try await (try await host(for: id)).signal(terminalID: id, signal: .interrupt)
            try await (try await host(for: id)).signal(terminalID: id, signal: .terminate)
        }
    }

    public func read(sessionID: String, maxBytes: Int) async throws -> TerminalOutputChunk {
        let id = resolveID(sessionID)
        let chunks = try await (try await host(for: id)).read(terminalID: id, afterSequence: cursors[id] ?? -1, maxBytes: maxBytes)
        guard !chunks.isEmpty else {
            await refreshRecord(id: id)
            throw TerminalRuntimeError.noOutput
        }
        let text = chunks.map(\.text).joined()
        cursors[id] = chunks.last?.sequence ?? cursors[id] ?? -1
        var buffer = buffers[id] ?? TerminalOutputBuffer()
        buffer.append(text)
        buffers[id] = buffer
        if TerminalInputGuard.classify(text) == .protected { protectedStates.insert(id) }
        await refreshRecord(id: id)
        return TerminalOutputChunk(sessionID: recordsByID[id]?.sessionID ?? id, text: text, sequence: cursors[id] ?? -1)
    }

    public func attach(sessionID: String) async throws {
        let id = resolveID(sessionID)
        let receipt = try await (try await host(for: id)).attach(terminalID: id)
        if var record = recordsByID[id] {
            record.state = receipt.requiresApproval ? .needsAttention : receipt.state
            record.pid = receipt.pid ?? record.pid
            record.exitCode = receipt.exitCode ?? record.exitCode
            record.endedAt = [.exited, .failed, .stopped].contains(record.state) ? (record.endedAt ?? Date()) : record.endedAt
            recordsByID[id] = record
        }
    }

    public func close(sessionID: String) async throws {
        let id = resolveID(sessionID)
        try await (try await host(for: id)).close(terminalID: id)
        if var record = recordsByID[id] { record.state = .stopped; record.endedAt = Date(); recordsByID[id] = record }
    }

    public func records(for sessionID: String) -> [TerminalSessionRecord] {
        recordsByID.values.filter { $0.sessionID == sessionID }.sorted { $0.startedAt < $1.startedAt }
    }

    public func record(terminalID: String) -> TerminalSessionRecord? { recordsByID[terminalID] }

    public func output(terminalID: String) -> String { buffers[terminalID]?.text ?? "" }

    public func protectedInputRequired(terminalID: String) -> Bool { protectedStates.contains(terminalID) }

    public func register(records: [TerminalSessionRecord]) {
        for record in records {
            recordsByID[record.id] = record
            cursors[record.id] = -1
            if buffers[record.id] == nil { buffers[record.id] = TerminalOutputBuffer() }
        }
    }

    private func host(for terminalID: String) async throws -> any PersistentTerminalHost {
        if let existing = hosts[terminalID] { return existing }
        guard let record = recordsByID[terminalID] else { return localHost }
        if case let .ssh(hostID) = record.target, let sshResolver {
            let resolved = try await sshResolver(hostID)
            hosts[terminalID] = resolved
            return resolved
        }
        return localHost
    }

    private func resolveID(_ sessionID: String) -> String {
        if recordsByID[sessionID] != nil { return sessionID }
        return recordsByID.values.filter { $0.sessionID == sessionID }.sorted { $0.startedAt < $1.startedAt }.last?.id ?? sessionID
    }

    private func refreshRecord(id: String) async {
        guard let current = recordsByID[id], let receipt = try? await (try await host(for: id)).attach(terminalID: id) else { return }
        var updated = current
        updated.state = receipt.requiresApproval ? .needsAttention : receipt.state
        updated.pid = receipt.pid ?? current.pid
        updated.exitCode = receipt.exitCode ?? current.exitCode
        if [.exited, .failed, .stopped].contains(updated.state), updated.endedAt == nil { updated.endedAt = Date() }
        recordsByID[id] = updated
    }
}
