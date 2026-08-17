import Foundation
import DeepSeekCodeCore

@main
struct DeepSeekCodeDaemon {
    static func main() async {
        let storageRoot = argumentValue("--root").map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? DeepSeekDaemonPaths.storageRoot()
        do {
            try FileManager.default.createDirectory(at: storageRoot, withIntermediateDirectories: true)
            let repository = try SessionRepository(directory: storageRoot.appendingPathComponent("Database", isDirectory: true))
            let eventStore = try EventStore(directory: storageRoot.appendingPathComponent("LegacyEvents", isDirectory: true))
            let providerCatalog = try ProviderCatalog(directory: storageRoot)
            let secretStore: any SecretStore = KeychainSecretStore()
            let terminalHost = ProcessPersistentTerminalHost(
                manager: TerminalHelperProcessManager(
                    executableURL: terminalHelperExecutableURL(),
                    root: storageRoot
                        .appendingPathComponent("TerminalRuntime", isDirectory: true)
                        .appendingPathComponent("Helper", isDirectory: true)
                )
            )
            let daemonHooks = (try? ExtensionStore(
                directory: storageRoot.appendingPathComponent("Extensions", isDirectory: true)
            ).listHooks()) ?? []
            let runner = NativeDaemonSessionRunner(
                repository: repository,
                eventStore: eventStore,
                providerCatalog: providerCatalog,
                secretStore: secretStore,
                storageRoot: storageRoot,
                terminalHost: terminalHost,
                hooks: daemonHooks
            )
            let driver = DaemonSessionExecutionDriver(repository: repository, runner: runner)
            let workerDriver = ProcessChildAgentExecutionDriver(
                executableURL: workerExecutableURL(),
                workspaceResolver: { _, workerSessionID in
                    guard let worker = try? repository.workerSession(id: workerSessionID),
                          let session = try? repository.session(id: worker.parentSessionID),
                          let project = try? repository.project(id: session.projectID) else {
                        return storageRoot
                    }
                    return URL(fileURLWithPath: session.worktreePath ?? project.path, isDirectory: true)
                }
            )
            let workerRuntime = DurableChildAgentRuntime(repository: repository, driver: workerDriver)
            let supervisor = SessionSupervisor(
                repository: repository,
                executionDriver: driver,
                instanceID: "deepseekd-\(ProcessInfo.processInfo.processIdentifier)"
            )
            runner.installRuntimeSupervisor(supervisor)
            // Safety-first recovery runs before accepting any new command.
            // Unknown writers are marked Needs Attention by the supervisor;
            // the daemon never auto-replays them.
            for session in try repository.sessions() where !session.archived {
                _ = try? await supervisor.recover(sessionID: session.id)
            }
            let router = DeepSeekDaemonCommandRouter(
                repository: repository,
                supervisor: supervisor,
                workerRuntime: workerRuntime,
                terminalHost: terminalHost,
                runtimeProfile: runner.runtimeCapabilities,
                instanceID: "deepseekd-\(ProcessInfo.processInfo.processIdentifier)"
            )
            let server = try DeepSeekDaemonServer(router: router, storageRoot: storageRoot)
            try await server.run()
        } catch {
            FileHandle.standardError.write(Data("deepseekd 启动失败：\(SecretRedactor.redact(error.localizedDescription))\n".utf8))
        }
    }

    private static func argumentValue(_ flag: String) -> String? {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1]
    }

    private static func workerExecutableURL() -> URL {
        if let configured = ProcessInfo.processInfo.environment["DEEPSEEK_WORKER_PATH"],
           FileManager.default.isExecutableFile(atPath: configured) {
            return URL(fileURLWithPath: configured)
        }
        let executable = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        let candidates = [
            executable.deletingLastPathComponent().appendingPathComponent("deepseek-worker"),
            executable.deletingLastPathComponent().appendingPathComponent("../Resources/deepseek-worker").standardizedFileURL,
            executable.deletingLastPathComponent().appendingPathComponent("DeepSeekCodeWorker").standardizedFileURL
        ]
        return candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) ?? candidates[0]
    }

    private static func terminalHelperExecutableURL() -> URL {
        if let configured = ProcessInfo.processInfo.environment["DEEPSEEK_TOOLHOST_PATH"],
           FileManager.default.isExecutableFile(atPath: configured) {
            return URL(fileURLWithPath: configured)
        }
        let executable = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        let candidates = [
            executable.deletingLastPathComponent().appendingPathComponent("DeepSeekCodeToolHost"),
            executable.deletingLastPathComponent().appendingPathComponent("../Resources/DeepSeekCodeToolHost").standardizedFileURL,
            executable.deletingLastPathComponent().appendingPathComponent("DeepSeekCodeToolHost").standardizedFileURL
        ]
        return candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) ?? candidates[0]
    }
}
