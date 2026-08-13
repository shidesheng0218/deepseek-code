import Foundation
import DeepSeekCodeCore

@main
struct DeepSeekCodeCLIChecks {
    static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("deepseek-cli-checks-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try Data("# CLI Worker Fixture\n".utf8).write(to: workspace.appendingPathComponent("README.md"))

        let directory = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
        let daemonURL = directory.appendingPathComponent("deepseekd")
        let cliURL = directory.appendingPathComponent("deepseek")
        let toolHostURL = directory.appendingPathComponent("DeepSeekCodeToolHost")
        precondition(FileManager.default.isExecutableFile(atPath: daemonURL.path))
        precondition(FileManager.default.isExecutableFile(atPath: cliURL.path))
        precondition(FileManager.default.isExecutableFile(atPath: toolHostURL.path))

        let daemon = Process()
        daemon.executableURL = daemonURL
        daemon.arguments = ["--root", root.path]
        var environment = ProcessInfo.processInfo.environment
        environment["DEEPSEEK_TOOLHOST_PATH"] = toolHostURL.path
        daemon.environment = environment
        daemon.standardOutput = FileHandle.nullDevice
        daemon.standardError = FileHandle.nullDevice
        try daemon.run()
        defer {
            if daemon.isRunning { daemon.terminate() }
            daemon.waitUntilExit()
        }

        try await waitForDaemon(root: root)
        let sessionID = try runCLI(cliURL, root: root, arguments: ["init", workspace.path]).trimmingCharacters(in: .whitespacesAndNewlines)
        precondition(!sessionID.isEmpty)

        let terminalResult = try runCLI(
            cliURL,
            root: root,
            arguments: ["terminal", "exec", sessionID, "printf cli-terminal-ok"]
        )
        precondition(terminalResult.contains("cli-terminal-ok"))

        // Full CLI approval round trip: the first L2 command must return a
        // durable approval ID without executing; approving it must allow one
        // exact retry; reusing the same allow-once approval must be rejected.
        let approvalRequest = try runCLIResult(
            cliURL,
            root: root,
            arguments: ["terminal", "exec", sessionID, "curl --version"]
        )
        precondition(approvalRequest.status == 0)
        precondition(approvalRequest.stderr.contains("需要审批："))
        let approvalID = approvalRequest.stderr
            .split(separator: "\n")
            .first(where: { $0.contains("需要审批：") })
            .map(String.init)?
            .replacingOccurrences(of: "需要审批：", with: "")
            .split(separator: "（")
            .first
            .map(String.init)
        precondition(approvalID?.isEmpty == false)
        guard let approvalID else { throw NSError(domain: "DeepSeekCodeCLIChecks", code: 2) }

        let approved = try runCLI(cliURL, root: root, arguments: ["approve", sessionID, approvalID])
        precondition(approved.contains("approved"))

        let approvedRetry = try runCLI(
            cliURL,
            root: root,
            arguments: ["terminal", "exec", sessionID, "curl --version", "--approval", approvalID]
        )
        precondition(approvedRetry.contains("curl"))

        let repeatedApproval = try runCLIResult(
            cliURL,
            root: root,
            arguments: ["terminal", "exec", sessionID, "curl --version", "--approval", approvalID]
        )
        precondition(repeatedApproval.status != 0)
        precondition(repeatedApproval.stderr.contains("APPROVAL_INVALID") || repeatedApproval.stderr.contains("确认无效"))

        let workerID = try runCLI(
            cliURL,
            root: root,
            arguments: ["worker", "create", sessionID, "explore", "读取项目结构"]
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        precondition(!workerID.isEmpty)

        _ = try runCLI(cliURL, root: root, arguments: ["worker", "start", workerID])
        let collected = try runCLI(cliURL, root: root, arguments: ["worker", "collect", workerID])
        precondition(collected.contains("README.md"))
        _ = try runCLI(cliURL, root: root, arguments: ["worker", "adopt", workerID])
        let listed = try runCLI(cliURL, root: root, arguments: ["worker", "list", sessionID])
        precondition(listed.contains(workerID))
        precondition(listed.contains("completed"))
        print("DeepSeek CLI checks passed")
    }

    private static func waitForDaemon(root: URL) async throws {
        for _ in 0..<50 {
            if let descriptor = try? DeepSeekDaemonClient.loadDescriptor(storageRoot: root) {
                let client = DeepSeekDaemonClient(descriptor: descriptor)
                if let response = try? await client.send(DeepSeekDaemonRequest(method: .handshake)), response.ok {
                    return
                }
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw NSError(domain: "DeepSeekCodeCLIChecks", code: 1, userInfo: [NSLocalizedDescriptionKey: "deepseekd 未能启动"])
    }

    private static func runCLI(_ executable: URL, root: URL, arguments: [String]) throws -> String {
        let result = try runCLIResult(executable, root: root, arguments: arguments)
        guard result.status == 0 else {
            throw NSError(domain: "DeepSeekCodeCLIChecks", code: Int(result.status), userInfo: [NSLocalizedDescriptionKey: result.stderr])
        }
        return result.stdout
    }

    private struct CLIResult {
        let status: Int32
        let stdout: String
        let stderr: String
    }

    private static func runCLIResult(_ executable: URL, root: URL, arguments: [String]) throws -> CLIResult {
        let process = Process()
        let output = Pipe()
        let errors = Pipe()
        process.executableURL = executable
        process.arguments = ["--root", root.path] + arguments
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        process.waitUntilExit()
        let stdout = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let stderr = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return CLIResult(status: process.terminationStatus, stdout: stdout, stderr: stderr)
    }
}
