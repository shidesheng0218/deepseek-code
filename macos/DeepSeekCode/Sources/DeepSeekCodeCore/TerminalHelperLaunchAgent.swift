import Darwin
import Foundation

public struct TerminalHelperLaunchAgentArtifact: Sendable, Equatable {
    public let label: String
    public let plist: String
    public let url: URL

    public init(label: String, plist: String, url: URL) {
        self.label = label
        self.plist = plist
        self.url = url
    }
}

public enum TerminalHelperLaunchAgentRenderer {
    public static func render(label: String, executablePath: String, rootPath: String, socketPath: String, descriptorPath: String) -> TerminalHelperLaunchAgentArtifact {
        let safeLabel = label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "com.deepseekcode.terminal" : label
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents/\(safeLabel).plist")
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
          <key>Label</key><string>\(escape(safeLabel))</string>
          <key>ProgramArguments</key>
          <array>
            <string>\(escape(executablePath))</string>
            <string>--terminal-helper</string>
            <string>--root</string><string>\(escape(rootPath))</string>
            <string>--socket</string><string>\(escape(socketPath))</string>
            <string>--descriptor</string><string>\(escape(descriptorPath))</string>
          </array>
          <key>RunAtLoad</key><true/>
          <key>KeepAlive</key><true/>
          <key>ProcessType</key><string>Background</string>
          <key>LowPriorityIO</key><true/>
        </dict>
        </plist>
        """
        return TerminalHelperLaunchAgentArtifact(label: safeLabel, plist: plist, url: url)
    }

    private static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}

public final class TerminalHelperLaunchAgentManager: @unchecked Sendable {
    public let directory: URL

    public init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents", isDirectory: true)
    }

    @discardableResult
    public func install(executableURL: URL, root: URL, socketPath: String, descriptorURL: URL, label: String = "com.deepseekcode.terminal") throws -> TerminalHelperLaunchAgentArtifact {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let artifact = TerminalHelperLaunchAgentRenderer.render(label: label, executablePath: executableURL.path, rootPath: root.path, socketPath: socketPath, descriptorPath: descriptorURL.path)
        try Data(artifact.plist.utf8).write(to: artifact.url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: artifact.url.path)
        bootstrap(artifact.url)
        return artifact
    }

    public func uninstall(label: String = "com.deepseekcode.terminal") {
        let url = directory.appendingPathComponent("\(label).plist")
        bootout(url)
        try? FileManager.default.removeItem(at: url)
    }

    public func restart(label: String = "com.deepseekcode.terminal") {
        runLaunchctl(arguments: ["kickstart", "-k", "gui/\(getuid())/\(label)"])
    }

    private func bootstrap(_ plist: URL) {
        runLaunchctl(arguments: ["bootstrap", "gui/\(getuid())", plist.path])
    }

    private func bootout(_ plist: URL) {
        runLaunchctl(arguments: ["bootout", "gui/\(getuid())", plist.path])
    }

    private func runLaunchctl(arguments: [String]) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
    }
}
