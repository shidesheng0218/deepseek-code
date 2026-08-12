import CryptoKit
import Foundation

/// A per-session Seatbelt policy used only for local Agent-launched commands.
/// It confines writes to the selected workspace and a dedicated scratch area,
/// hides the user's home directory except for the explicit project root, and
/// denies outbound network access unless the command has already crossed the
/// normal NetworkRuntime/PermissionBroker approval chain.
public struct SandboxLaunchPolicy: Codable, Equatable, Sendable {
    public let sessionID: String
    public let workspacePath: String
    public let scratchPath: String
    public let allowsNetwork: Bool

    public init(sessionID: String, workspacePath: String, scratchPath: String, allowsNetwork: Bool = false) {
        self.sessionID = sessionID
        self.workspacePath = URL(fileURLWithPath: workspacePath, isDirectory: true).resolvingSymlinksInPath().standardizedFileURL.path
        self.scratchPath = URL(fileURLWithPath: scratchPath, isDirectory: true).resolvingSymlinksInPath().standardizedFileURL.path
        self.allowsNetwork = allowsNetwork
    }

    public var id: String {
        let raw = "\(sessionID)|\(workspacePath)|\(scratchPath)|\(allowsNetwork)"
        return SHA256.hash(data: Data(raw.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

public struct SandboxPreparedLaunch: Sendable {
    public let command: String
    public let environment: [String: String]
    public let usesLoginShell: Bool
    public let policyID: String
}

public struct SandboxPreflightResult: Equatable, Sendable {
    public let available: Bool
    public let detail: String

    public init(available: Bool, detail: String) {
        self.available = available
        self.detail = detail
    }
}

public enum SandboxRuntime {
    public static let executablePath = "/usr/bin/sandbox-exec"
    public static let availability: SandboxPreflightResult = preflight()

    /// The preflight executes a harmless write in a real Seatbelt profile and
    /// confirms a sibling path is rejected. If either assertion cannot be made
    /// we keep Auto mode conservative and report sandbox as unavailable.
    public static func preflight() -> SandboxPreflightResult {
        guard FileManager.default.isExecutableFile(atPath: executablePath) else {
            return SandboxPreflightResult(available: false, detail: "系统没有 sandbox-exec")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("deepseek-sandbox-preflight-\(UUID().uuidString)", isDirectory: true)
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("deepseek-sandbox-outside-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let policy = SandboxLaunchPolicy(sessionID: "preflight", workspacePath: root.path, scratchPath: root.path)
            let insideStatus = run(arguments: ["-p", profileText(for: policy), "/usr/bin/touch", root.appendingPathComponent("allowed").path])
            let outsideStatus = run(arguments: ["-p", profileText(for: policy), "/usr/bin/touch", outside.path])
            let insideExists = FileManager.default.fileExists(atPath: root.appendingPathComponent("allowed").path)
            if insideStatus == 0 && insideExists && outsideStatus != 0 && !FileManager.default.fileExists(atPath: outside.path) {
                return SandboxPreflightResult(available: true, detail: "Seatbelt 写入边界已验证")
            }
            return SandboxPreflightResult(available: false, detail: "Seatbelt 预检未能验证工作区边界")
        } catch {
            return SandboxPreflightResult(available: false, detail: "Seatbelt 预检失败：\(error.localizedDescription)")
        }
    }

    public static func prepare(command: String, policy: SandboxLaunchPolicy) throws -> SandboxPreparedLaunch {
        try FileManager.default.createDirectory(at: URL(fileURLWithPath: policy.scratchPath, isDirectory: true), withIntermediateDirectories: true)
        let profile = profileText(for: policy)
        let wrapped = "exec \(shellQuote(executablePath)) -p \(shellQuote(profile)) /bin/zsh -f -c \(shellQuote(command))"
        return SandboxPreparedLaunch(
            command: wrapped,
            environment: [
                "HOME": policy.scratchPath,
                "TMPDIR": policy.scratchPath,
                "PATH": "/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
            ],
            usesLoginShell: false,
            policyID: policy.id
        )
    }

    public static func profileText(for policy: SandboxLaunchPolicy) -> String {
        let workspace = seatbeltQuote(policy.workspacePath)
        let scratch = seatbeltQuote(policy.scratchPath)
        let home = seatbeltQuote(URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true).resolvingSymlinksInPath().standardizedFileURL.path)
        let network = policy.allowsNetwork ? "(allow network-outbound)" : ""
        return """
        (version 1)
        (deny default)
        (allow process*)
        (allow file-read*)
        (deny file-read* (subpath \"\(home)\"))
        (allow file-read* (subpath \"\(workspace)\") (subpath \"\(scratch)\"))
        (allow file-write* (subpath \"\(workspace)\") (subpath \"\(scratch)\"))
        (allow sysctl*)
        (allow mach-lookup)
        (allow mach-per-user-lookup)
        (allow ipc-posix-shm)
        (allow system-socket)
        \(network)
        """
    }

    private static func run(arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        guard (try? process.run()) != nil else { return -1 }
        process.waitUntilExit()
        return process.terminationStatus
    }

    private static func seatbeltQuote(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    private static func shellQuote(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\\"'\\\"'"))'"
    }
}
