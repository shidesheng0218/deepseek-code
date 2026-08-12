import Foundation
import Darwin
import DeepSeekCodeCore

/// Small remote-side executable. It never receives a model key; it only
/// accepts framed JSON tool requests from the local macOS control plane.
@main
struct DeepSeekCodeToolHost {
    static func main() async {
        if CommandLine.arguments.contains("--terminal-helper") || CommandLine.arguments.contains("--terminal-helper-daemon") {
            await runTerminalHelper()
            return
        }
        if CommandLine.arguments.contains("--terminal-helper-proxy") {
            await runTerminalHelperProxy()
            return
        }
        if CommandLine.arguments.contains("--terminal-helper-health") {
            await runTerminalHelperHealth()
            return
        }
        if CommandLine.arguments.contains("--terminal-helper-stdio") {
            await runTerminalHelperStdio()
            return
        }
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        let checkpoint = FileManager.default.temporaryDirectory
            .appendingPathComponent("DeepSeekCodeToolHost/Checkpoints", isDirectory: true)
        let workspace = try? WorkspaceToolHost(root: root, checkpointDirectory: checkpoint)
        while let line = readLine(strippingNewline: true), !line.isEmpty {
            let response = await handle(line: line, workspace: workspace)
            if let data = try? JSONEncoder().encode(response) {
                print(String(decoding: data, as: UTF8.self), terminator: "\n")
                fflush(stdout)
            }
        }
    }

    private static func runTerminalHelper() async {
        let arguments = CommandLine.arguments
        func value(after flag: String, default fallback: String) -> String {
            guard let index = arguments.firstIndex(of: flag), arguments.index(after: index) < arguments.endIndex else { return fallback }
            return arguments[arguments.index(after: index)]
        }
        let root = URL(fileURLWithPath: value(after: "--root", default: FileManager.default.temporaryDirectory.appendingPathComponent("DeepSeekCodeTerminal").path), isDirectory: true)
        let socketPath = value(after: "--socket", default: root.appendingPathComponent("host.sock").path)
        let descriptorURL = URL(fileURLWithPath: value(after: "--descriptor", default: root.appendingPathComponent("host.json").path))
        do {
            // The Helper is launched headlessly by launchd or over SSH. Its
            // only secret is the local transcript-encryption key; provider
            // credentials stay in the App Keychain and never cross this
            // process boundary.
            let secretStore = try TerminalHelperSecretStore(root: root)
            let service = try PersistentTerminalService(root: root, secretStore: secretStore, socketPath: socketPath)
            let server = try TerminalHelperServer(service: service, socketPath: socketPath, descriptorURL: descriptorURL)
            try await server.run()
        } catch {
            FileHandle.standardError.write(Data("Terminal Helper 启动失败：\(SecretRedactor.redact(error.localizedDescription))\n".utf8))
        }
    }

    private static func runTerminalHelperStdio() async {
        let arguments = CommandLine.arguments
        func value(after flag: String, default fallback: String) -> String {
            guard let index = arguments.firstIndex(of: flag), arguments.index(after: index) < arguments.endIndex else { return fallback }
            return arguments[arguments.index(after: index)]
        }
        let root = URL(fileURLWithPath: value(after: "--root", default: FileManager.default.temporaryDirectory.appendingPathComponent("DeepSeekCodeRemoteTerminal").path), isDirectory: true)
        let token = value(after: "--token", default: "")
        do {
            let secretStore = try TerminalHelperSecretStore(root: root)
            let service = try PersistentTerminalService(root: root, secretStore: secretStore)
            let server = try TerminalHelperServer(service: service, socketPath: root.appendingPathComponent("unused.sock").path, descriptorURL: root.appendingPathComponent("stdio-host.json"), token: token.isEmpty ? UUID().uuidString : token)
            try await server.runStdio()
        } catch {
            FileHandle.standardError.write(Data("Terminal Helper stdio 启动失败：\(SecretRedactor.redact(error.localizedDescription))\n".utf8))
        }
    }

    private static func runTerminalHelperProxy() async {
        let arguments = CommandLine.arguments
        func value(after flag: String) -> String? {
            guard let index = arguments.firstIndex(of: flag), arguments.index(after: index) < arguments.endIndex else { return nil }
            return arguments[arguments.index(after: index)]
        }
        guard let socketPath = value(after: "--socket"), let descriptorPath = value(after: "--descriptor") else {
            FileHandle.standardError.write(Data("Terminal Helper Proxy 缺少 socket 或 descriptor 参数\n".utf8))
            return
        }
        do {
            try await TerminalHelperProxy.runStdio(socketPath: socketPath, descriptorURL: URL(fileURLWithPath: descriptorPath))
        } catch {
            FileHandle.standardError.write(Data("Terminal Helper Proxy 失败：\(SecretRedactor.redact(error.localizedDescription))\n".utf8))
        }
    }

    private static func runTerminalHelperHealth() async {
        let arguments = CommandLine.arguments
        func value(after flag: String) -> String? {
            guard let index = arguments.firstIndex(of: flag), arguments.index(after: index) < arguments.endIndex else { return nil }
            return arguments[arguments.index(after: index)]
        }
        guard let socketPath = value(after: "--socket"), let descriptorPath = value(after: "--descriptor") else {
            exit(2)
        }
        do {
            try await TerminalHelperProxy.health(socketPath: socketPath, descriptorURL: URL(fileURLWithPath: descriptorPath))
            exit(0)
        } catch {
            exit(1)
        }
    }

    private static func handle(line: String, workspace: WorkspaceToolHost?) async -> RemoteToolResponse {
        guard let data = line.data(using: .utf8), let request = try? JSONDecoder().decode(RemoteToolRequest.self, from: data) else {
            return RemoteToolResponse(id: UUID().uuidString, ok: false, output: "无效的远程请求")
        }
        if request.tool == "__handshake__" {
            let handshake = SSHCapabilityHandshake(
                protocolVersion: 1,
                hostVersion: "1.0",
                checksum: nil,
                capabilities: ["read_file", "list_directory", "search_workspace", "inspect_git", "apply_patch", "run_command", "terminal.open", "terminal.attach", "terminal.read", "terminal.write", "terminal.resize", "terminal.signal", "terminal.close"]
            )
            let encoded = (try? JSONEncoder().encode(handshake)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
            return RemoteToolResponse(id: request.id, ok: true, output: encoded)
        }
        guard let workspace else {
            return RemoteToolResponse(id: request.id, ok: false, output: "无法打开远程工作区")
        }
        let descriptor = AgentToolSchemas.registry.tool(named: request.tool)
            ?? RegisteredTool(name: request.tool, description: "远程结构化工具", parameters: .objectSchema(), effect: .readOnly, risk: .l0, timeoutMilliseconds: 60_000, maxOutputBytes: 128_000, idempotent: true, supportsCancellation: true)
        do {
            let output = try await LocalWorkspaceToolHost(workspace: workspace).execute(tool: descriptor, argumentsJSON: request.argumentsJSON, sessionID: request.sessionID)
            return RemoteToolResponse(id: request.id, ok: true, output: output)
        } catch {
            return RemoteToolResponse(id: request.id, ok: false, output: SecretRedactor.redact(error.localizedDescription))
        }
    }

}
