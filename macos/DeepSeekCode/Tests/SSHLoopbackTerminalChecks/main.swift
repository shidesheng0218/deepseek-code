import Foundation
import DeepSeekCodeCore
import Darwin

@main
struct DeepSeekCodeSSHLoopbackChecks {
    static func main() async throws {
        let fixture = try SSHLoopbackFixture.start()
        defer { fixture.stop() }
        precondition(fixture.port > 0)
        let shellOutput = try fixture.run(command: "printf loopback-ssh-ok")
        precondition(shellOutput.contains("loopback-ssh-ok"))
        let streamOutput = try fixture.roundTrip(payload: "loopback-stream-ok\n")
        precondition(streamOutput.contains("loopback-stream-ok"))
        precondition(fixture.host.identityFile != nil)
        precondition(fixture.host.knownHostsFile != nil)
        guard let toolHostPath = ProcessInfo.processInfo.environment["DEEPSEEK_TOOLHOST_PATH"], !toolHostPath.isEmpty else {
            print("SSH loopback persistent-terminal check skipped: DEEPSEEK_TOOLHOST_PATH is not set")
            return
        }
        try await fixture.verifyPersistentTerminal(toolHost: URL(fileURLWithPath: toolHostPath))
        print("SSH loopback persistent-terminal checks passed")
    }
}

/// Test-only SSH daemon. It binds to loopback, uses a throwaway key pair and
/// removes its files on exit; it never enables the macOS Remote Login service.
final class SSHLoopbackFixture {
    let root: URL
    let port: Int
    private let clientKey: URL
    private let knownHosts: URL
    private let daemon: Process

    private init(root: URL, port: Int, clientKey: URL, knownHosts: URL, daemon: Process) {
        self.root = root
        self.port = port
        self.clientKey = clientKey
        self.knownHosts = knownHosts
        self.daemon = daemon
    }

    var host: SSHHost {
        SSHHost(
            id: "loopback-ssh",
            hostname: "127.0.0.1",
            user: NSUserName(),
            port: port,
            fingerprint: "loopback-host-key",
            identityFile: clientKey.path,
            knownHostsFile: knownHosts.path
        )
    }

    static func start() throws -> SSHLoopbackFixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("DeepSeekCodeSSHLoopback-\(UUID().uuidString)", isDirectory: true)
        let daemonRoot = root.appendingPathComponent("daemon", isDirectory: true)
        let keysRoot = root.appendingPathComponent("keys", isDirectory: true)
        try FileManager.default.createDirectory(at: daemonRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: keysRoot, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)

        let hostKey = keysRoot.appendingPathComponent("host_ed25519")
        let clientKey = keysRoot.appendingPathComponent("client_ed25519")
        try run(executable: "/usr/bin/ssh-keygen", arguments: ["-q", "-t", "ed25519", "-N", "", "-f", hostKey.path])
        try run(executable: "/usr/bin/ssh-keygen", arguments: ["-q", "-t", "ed25519", "-N", "", "-f", clientKey.path])

        let authorizedKeys = daemonRoot.appendingPathComponent("authorized_keys")
        let clientPublicKey = try String(contentsOf: URL(fileURLWithPath: clientKey.path + ".pub"), encoding: .utf8)
        try Data(clientPublicKey.utf8).write(to: authorizedKeys, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: authorizedKeys.path)

        let port = try availableLoopbackPort()
        let hostParts = try String(contentsOf: URL(fileURLWithPath: hostKey.path + ".pub"), encoding: .utf8)
            .split(separator: " ")
        guard hostParts.count >= 2 else { throw FixtureError.invalidHostKey }
        let knownHosts = daemonRoot.appendingPathComponent("known_hosts")
        let knownHostLine = "[127.0.0.1]:\(port) \(hostParts[0]) \(hostParts[1])\n"
        try Data(knownHostLine.utf8).write(to: knownHosts, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: knownHosts.path)

        let config = daemonRoot.appendingPathComponent("sshd_config")
        let username = NSUserName()
        let text = """
        Port \(port)
        ListenAddress 127.0.0.1
        HostKey \(hostKey.path)
        PidFile \(daemonRoot.appendingPathComponent("sshd.pid").path)
        AuthorizedKeysFile \(authorizedKeys.path)
        PasswordAuthentication no
        KbdInteractiveAuthentication no
        ChallengeResponseAuthentication no
        PubkeyAuthentication yes
        UsePAM no
        PermitRootLogin no
        StrictModes no
        AllowUsers \(username)
        LogLevel VERBOSE
        """
        try Data(text.utf8).write(to: config, options: .atomic)
        try run(executable: "/usr/sbin/sshd", arguments: ["-t", "-f", config.path])

        let daemon = Process()
        let errors = Pipe()
        daemon.executableURL = URL(fileURLWithPath: "/usr/sbin/sshd")
        daemon.arguments = ["-D", "-e", "-f", config.path]
        daemon.standardOutput = FileHandle.nullDevice
        daemon.standardError = errors
        try daemon.run()
        let fixture = SSHLoopbackFixture(root: root, port: port, clientKey: clientKey, knownHosts: knownHosts, daemon: daemon)
        for _ in 0..<30 {
            if (try? fixture.run(command: "printf ready"))?.contains("ready") == true { return fixture }
            if !daemon.isRunning { break }
            Thread.sleep(forTimeInterval: 0.1)
        }
        let detail = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        fixture.stop()
        throw FixtureError.daemonFailed(detail)
    }

    func run(command: String) throws -> String {
        try Self.run(
            executable: "/usr/bin/ssh",
            arguments: [
                "-i", clientKey.path,
                "-o", "IdentitiesOnly=yes",
                "-o", "BatchMode=yes",
                "-o", "StrictHostKeyChecking=yes",
                "-o", "UserKnownHostsFile=\(knownHosts.path)",
                "-o", "ConnectTimeout=1",
                "-p", "\(port)",
                "\(NSUserName())@127.0.0.1",
                "--", command
            ]
        )
    }

    func roundTrip(payload: String) throws -> String {
        let process = Process()
        let input = Pipe()
        let output = Pipe()
        let errors = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = SSHClientArguments.options(for: host) + ["\(host.user)@\(host.hostname)", "--", "/bin/cat"]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        try input.fileHandleForWriting.write(contentsOf: Data(payload.utf8))
        try input.fileHandleForWriting.close()
        process.waitUntilExit()
        let stdout = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let stderr = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        guard process.terminationStatus == 0 else { throw FixtureError.commandFailed(stderr.isEmpty ? stdout : stderr) }
        return stdout
    }

    func verifyPersistentTerminal(toolHost: URL) async throws {
        guard FileManager.default.isExecutableFile(atPath: toolHost.path) else { throw FixtureError.missingToolHost }
        let remoteRoot = "Library/Caches/DeepSeekCodeLoopback/\(root.lastPathComponent)"
        defer { stopRemoteHelper(relativeRoot: remoteRoot) }

        do {
            _ = try ProcessSSHTerminalHelperHost(
                host: host,
                remotePath: toolHost.path,
                observedFingerprint: "changed-host-key",
                remoteRoot: remoteRoot
            )
            preconditionFailure("Host Key 变化必须阻止远程 Terminal")
        } catch SSHConnectionError.fingerprintChanged {
            // expected: this guard must run before an SSH process is started.
        }

        let terminal = try ProcessSSHTerminalHelperHost(
            host: host,
            remotePath: toolHost.path,
            observedFingerprint: "loopback-host-key",
            remoteRoot: remoteRoot
        )
        let handshake = try await terminal.handshake()
        precondition(handshake.hostVersion == TerminalHelperProtocol.currentHostVersion)
        let record = try await terminal.open(spec: TerminalLaunchSpec(
            sessionID: "ssh-loopback-session",
            target: .ssh(hostID: host.id),
            cwd: root.path,
            command: "printf remote-first; sleep 1; printf remote-second; sleep 2",
            background: true
        ))
        try await Task.sleep(nanoseconds: 300_000_000)
        await terminal.disconnect()
        try await Task.sleep(nanoseconds: 1_400_000_000)

        let receipt = try await terminal.attach(terminalID: record.id)
        let replay = try await terminal.read(terminalID: record.id, afterSequence: -1, maxBytes: 64_000)
        let output = replay.map(\.text).joined()
        precondition(receipt.terminalID == record.id)
        precondition(output.contains("remote-first"))
        precondition(output.contains("remote-second"))
    }

    func stop() {
        if daemon.isRunning { daemon.terminate() }
        let deadline = Date().addingTimeInterval(1)
        while daemon.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        if daemon.isRunning { daemon.interrupt() }
        try? FileManager.default.removeItem(at: root)
    }

    private func stopRemoteHelper(relativeRoot: String) {
        let remoteRoot = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(relativeRoot, isDirectory: true)
        let descriptorURL = remoteRoot.appendingPathComponent("daemon.json")
        if let data = try? Data(contentsOf: descriptorURL),
           let descriptor = try? JSONDecoder().decode(TerminalHelperDescriptor.self, from: data),
           let processID = descriptor.processID,
           processID > 0 {
            _ = kill(processID, SIGTERM)
            Thread.sleep(forTimeInterval: 0.1)
        }
        try? FileManager.default.removeItem(at: remoteRoot)
    }

    private static func availableLoopbackPort() throws -> Int {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw FixtureError.socketUnavailable }
        defer { close(descriptor) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        address.sin_port = 0
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard result == 0 else { throw FixtureError.socketUnavailable }
        var bound = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        guard withUnsafeMutablePointer(to: &bound, { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &length) } }) == 0 else {
            throw FixtureError.socketUnavailable
        }
        return Int(UInt16(bigEndian: bound.sin_port))
    }

    @discardableResult
    private static func run(executable: String, arguments: [String]) throws -> String {
        let process = Process()
        let output = Pipe()
        let errors = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        process.waitUntilExit()
        let stdout = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let stderr = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        guard process.terminationStatus == 0 else { throw FixtureError.commandFailed(stderr.isEmpty ? stdout : stderr) }
        return stdout
    }

    enum FixtureError: LocalizedError {
        case invalidHostKey
        case socketUnavailable
        case daemonFailed(String)
        case commandFailed(String)
        case missingToolHost

        var errorDescription: String? {
            switch self {
            case .invalidHostKey: "loopback SSH host key 无效"
            case .socketUnavailable: "无法分配 loopback SSH 端口"
            case let .daemonFailed(detail): "loopback sshd 启动失败：\(detail)"
            case let .commandFailed(detail): "loopback SSH 命令失败：\(detail)"
            case .missingToolHost: "找不到用于 loopback SSH 验收的 DeepSeekCodeToolHost"
            }
        }
    }
}
