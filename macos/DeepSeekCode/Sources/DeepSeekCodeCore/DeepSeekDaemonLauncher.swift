import Foundation

/// Finds or starts the single user-local `deepseekd` process used by the App
/// and CLI. Requests still travel over the authenticated Unix-domain socket;
/// this helper never starts a second in-process Agent loop.
public enum DeepSeekDaemonLauncher {
    public static func connect(
        storageRoot: URL = DeepSeekDaemonPaths.storageRoot(),
        executableURL: URL? = nil,
        timeout: TimeInterval = 4
    ) async throws -> DeepSeekDaemonClient {
        if let client = try? await existingClient(storageRoot: storageRoot) {
            return client
        }
        guard let executable = executableURL ?? discoverExecutable(),
              FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw DeepSeekDaemonTransportError.socketUnavailable("找不到 deepseekd；请从同一 Release 安装 App、CLI 和 Runtime")
        }
        let process = Process()
        process.executableURL = executable
        process.arguments = ["--root", storageRoot.path]
        process.standardInput = nil
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()

        let deadline = Date().addingTimeInterval(max(0.5, timeout))
        while Date() < deadline {
            if let client = try? await existingClient(storageRoot: storageRoot) {
                return client
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw DeepSeekDaemonTransportError.socketUnavailable("deepseekd 未能在本机启动")
    }

    public static func discoverExecutable() -> URL? {
        let environment = ProcessInfo.processInfo.environment
        let executable = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        let candidates = [
            environment["DEEPSEEKD_PATH"].map(URL.init(fileURLWithPath:)),
            Bundle.main.url(forResource: "deepseekd", withExtension: nil),
            executable.deletingLastPathComponent().appendingPathComponent("deepseekd"),
            executable.deletingLastPathComponent().appendingPathComponent("../Resources/deepseekd").standardizedFileURL
        ].compactMap { $0 }
        return candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) })
    }

    private static func existingClient(storageRoot: URL) async throws -> DeepSeekDaemonClient {
        let descriptor = try DeepSeekDaemonClient.loadDescriptor(storageRoot: storageRoot)
        let client = DeepSeekDaemonClient(descriptor: descriptor)
        let response = try await client.send(DeepSeekDaemonRequest(method: .handshake))
        guard response.ok else { throw DeepSeekDaemonTransportError.socketUnavailable("现有 deepseekd 不可用") }
        return client
    }
}
