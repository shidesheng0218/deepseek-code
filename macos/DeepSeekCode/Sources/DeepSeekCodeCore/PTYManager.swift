import Darwin
import Foundation

public enum PTYEvent: Sendable, Equatable {
    case output(String)
    case exited(Int32)
}

public enum PTYError: LocalizedError, Equatable {
    case invalidWorkingDirectory
    case openFailed(Int32)
    case spawnFailed(Int32)
    case writeFailed(Int32)

    public var errorDescription: String? {
        switch self {
        case .invalidWorkingDirectory:
            return "Working directory is not available"
        case let .openFailed(code):
            return "Failed to open PTY: \(PTYError.message(for: code))"
        case let .spawnFailed(code):
            return "Failed to start PTY process: \(PTYError.message(for: code))"
        case let .writeFailed(code):
            return "Failed to write to PTY: \(PTYError.message(for: code))"
        }
    }

    private static func message(for code: Int32) -> String {
        if let pointer = strerror(code) {
            return String(cString: pointer)
        }
        return "errno \(code)"
    }
}

public final class PTYSession: @unchecked Sendable, Identifiable {
    public let id = UUID()
    public let command: String
    public let pid: pid_t
    public let events: AsyncStream<PTYEvent>

    private let state: PTYProcessState

    fileprivate init(command: String, pid: pid_t, events: AsyncStream<PTYEvent>, state: PTYProcessState) {
        self.command = command
        self.pid = pid
        self.events = events
        self.state = state
    }

    public func write(_ text: String) throws {
        try state.write(text)
    }

    public func interrupt() {
        state.signal(SIGINT)
    }

    public func resize(columns: Int, rows: Int) throws {
        try state.resize(columns: columns, rows: rows)
    }

    public func eof() throws {
        try write("\u{04}")
    }

    public func terminate() {
        state.signal(SIGTERM)
    }

    public func kill() {
        state.signal(SIGKILL)
    }

    public func stopGracefully() async {
        state.signal(SIGINT)
        try? await Task.sleep(nanoseconds: 500_000_000)
        guard state.isAlive else { return }
        state.signal(SIGTERM)
        try? await Task.sleep(nanoseconds: 500_000_000)
        if state.isAlive { state.signal(SIGKILL) }
    }
}

public final class PTYManager: @unchecked Sendable {
    public init() {}

    public func start(command: String, cwd: URL, columns: Int = 120, rows: Int = 30, environment: [String: String] = [:], loginShell: Bool = true) throws -> PTYSession {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: cwd.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw PTYError.invalidWorkingDirectory
        }

        var master: Int32 = -1
        var slave: Int32 = -1
        var window = winsize(
            ws_row: UInt16(max(1, rows)),
            ws_col: UInt16(max(1, columns)),
            ws_xpixel: 0,
            ws_ypixel: 0
        )
        guard openpty(&master, &slave, nil, nil, &window) == 0 else {
            throw PTYError.openFailed(errno)
        }

        do {
            var processID = pid_t()
            try spawn(command: command, cwd: cwd, environment: environment, loginShell: loginShell, master: master, slave: slave, pid: &processID)
            close(slave)

            let state = PTYProcessState(pid: processID, masterFD: master)
            let stream = AsyncStream<PTYEvent> { continuation in
                let task = Task.detached(priority: .userInitiated) {
                    PTYManager.readLoop(state: state, continuation: continuation)
                }
                continuation.onTermination = { @Sendable _ in
                    task.cancel()
                    state.signal(SIGTERM)
                    state.closeMaster()
                }
            }
            return PTYSession(command: command, pid: processID, events: stream, state: state)
        } catch {
            close(master)
            close(slave)
            throw error
        }
    }

    private func spawn(command: String, cwd: URL, environment: [String: String], loginShell: Bool, master: Int32, slave: Int32, pid: inout pid_t) throws {
        var fileActions: posix_spawn_file_actions_t? = nil
        posix_spawn_file_actions_init(&fileActions)
        defer { posix_spawn_file_actions_destroy(&fileActions) }

        posix_spawn_file_actions_adddup2(&fileActions, slave, STDIN_FILENO)
        posix_spawn_file_actions_adddup2(&fileActions, slave, STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&fileActions, slave, STDERR_FILENO)
        posix_spawn_file_actions_addclose(&fileActions, master)
        if slave > STDERR_FILENO {
            posix_spawn_file_actions_addclose(&fileActions, slave)
        }
        let chdirResult = cwd.path.withCString { path in
            posix_spawn_file_actions_addchdir_np(&fileActions, path)
        }
        guard chdirResult == 0 else { throw PTYError.spawnFailed(chdirResult) }

        var attributes: posix_spawnattr_t? = nil
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP))
        posix_spawnattr_setpgroup(&attributes, 0)

        let arguments = ["zsh", loginShell ? "-lc" : "-fc", command]
        let environmentPairs = sanitizedEnvironment(merging: environment)
        let result = withCStringArray(arguments) { argv in
            withCStringArray(environmentPairs) { envp in
                "/bin/zsh".withCString { shell in
                    posix_spawnp(&pid, shell, &fileActions, &attributes, argv, envp)
                }
            }
        }
        guard result == 0 else { throw PTYError.spawnFailed(result) }
    }

    private static func readLoop(state: PTYProcessState, continuation: AsyncStream<PTYEvent>.Continuation) {
        var buffer = [UInt8](repeating: 0, count: 4096)
        while !Task.isCancelled {
            let count = buffer.withUnsafeMutableBytes { rawBuffer in
                Darwin.read(state.masterFD, rawBuffer.baseAddress, rawBuffer.count)
            }
            if count > 0 {
                continuation.yield(.output(String(decoding: buffer.prefix(Int(count)), as: UTF8.self)))
                continue
            }
            break
        }

        var status: Int32 = 0
        let waited = waitpid(state.pid, &status, 0)
        if waited == state.pid {
            continuation.yield(.exited(exitCode(from: status)))
        }
        state.closeMaster()
        continuation.finish()
    }

    private static func exitCode(from status: Int32) -> Int32 {
        if status & 0x7f == 0 {
            return (status >> 8) & 0xff
        }
        return 128 + (status & 0x7f)
    }

    private func sanitizedEnvironment(merging extra: [String: String]) -> [String] {
        let allowed = ["PATH", "HOME", "LANG", "LC_ALL", "TERM", "TMPDIR"]
        var values = ProcessInfo.processInfo.environment.filter { allowed.contains($0.key) }
        values["TERM"] = values["TERM"] ?? "xterm-256color"
        for (key, value) in extra where allowed.contains(key) {
            values[key] = value
        }
        return values.map { "\($0.key)=\($0.value)" }
    }

    private func withCStringArray<R>(_ strings: [String], _ body: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) throws -> R) rethrows -> R {
        let cStrings: [UnsafeMutablePointer<CChar>?] = strings.map { strdup($0) }
        defer { cStrings.forEach { free($0) } }
        var pointers = cStrings
        pointers.append(nil)
        return try pointers.withUnsafeMutableBufferPointer { buffer in
            try body(buffer.baseAddress)
        }
    }
}

private final class PTYProcessState: @unchecked Sendable {
    let pid: pid_t
    let masterFD: Int32

    private let lock = NSLock()
    private var closed = false

    init(pid: pid_t, masterFD: Int32) {
        self.pid = pid
        self.masterFD = masterFD
    }

    func write(_ text: String) throws {
        let bytes = Array(text.utf8)
        try bytes.withUnsafeBufferPointer { buffer in
            var written = 0
            while written < bytes.count {
                guard let base = buffer.baseAddress else { return }
                let result = Darwin.write(masterFD, base.advanced(by: written), bytes.count - written)
                if result < 0 { throw PTYError.writeFailed(errno) }
                written += result
            }
        }
    }

    func signal(_ signal: Int32) {
        _ = kill(-pid, signal)
    }

    var isAlive: Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }

    func resize(columns: Int, rows: Int) throws {
        var window = winsize(
            ws_row: UInt16(max(1, rows)),
            ws_col: UInt16(max(1, columns)),
            ws_xpixel: 0,
            ws_ypixel: 0
        )
        guard ioctl(masterFD, TIOCSWINSZ, &window) == 0 else {
            throw PTYError.writeFailed(errno)
        }
        signal(SIGWINCH)
    }

    func closeMaster() {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { return }
        closed = true
        close(masterFD)
    }
}
