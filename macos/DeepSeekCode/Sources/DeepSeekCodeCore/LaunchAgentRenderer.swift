import Foundation

public struct LaunchAgentArtifact: Sendable, Equatable {
    public let label: String
    public let plist: String

    public init(label: String, plist: String) {
        self.label = label
        self.plist = plist
    }
}

public struct InstalledLaunchAgent: Sendable, Equatable {
    public let label: String
    public let url: URL

    public init(label: String, url: URL) {
        self.label = label
        self.url = url
    }
}

public final class LaunchAgentManager: @unchecked Sendable {
    public let directory: URL

    public init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents", isDirectory: true)
    }

    @discardableResult
    public func install(task: ScheduledTask, schedulerExecutable: String) throws -> InstalledLaunchAgent {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let label = LaunchAgentRenderer.label(for: task.id)
        let taskURL = directory.appendingPathComponent("\(label).task.json")
        try JSONEncoder().encode(task).write(to: taskURL, options: .atomic)
        let artifact = LaunchAgentRenderer.render(task: task, schedulerExecutable: schedulerExecutable, taskFile: taskURL.path)
        let url = directory.appendingPathComponent("\(artifact.label).plist")
        try Data(artifact.plist.utf8).write(to: url, options: .atomic)
        return InstalledLaunchAgent(label: artifact.label, url: url)
    }

    public func uninstall(taskID: String) throws {
        let label = LaunchAgentRenderer.label(for: taskID)
        let url = directory.appendingPathComponent("\(label).plist")
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        let taskURL = directory.appendingPathComponent("\(label).task.json")
        if FileManager.default.fileExists(atPath: taskURL.path) { try FileManager.default.removeItem(at: taskURL) }
    }
}

public enum LaunchAgentRenderer {
    public static func label(for taskID: String) -> String {
        "com.deepseekcode.scheduled.\(sanitizedID(taskID))"
    }

    public static func render(task: ScheduledTask, schedulerExecutable: String, taskFile: String? = nil) -> LaunchAgentArtifact {
        let label = label(for: task.id)
        let interval = startInterval(for: task.schedule)
        let taskFileArgument = taskFile.map {
            """
            <string>--task-file</string>
            <string>\(escape($0))</string>
            """
        } ?? ""
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
          <key>Label</key><string>\(label)</string>
          <key>ProgramArguments</key>
          <array>
            <string>\(escape(schedulerExecutable))</string>
            <string>--scheduled-task</string>
            <string>\(escape(task.id))</string>
            \(taskFileArgument)
          </array>
          <key>StartInterval</key><integer>\(interval)</integer>
          <key>ProcessType</key><string>Background</string>
          <key>RunAtLoad</key><false/>
        </dict>
        </plist>
        """
        return LaunchAgentArtifact(label: label, plist: plist)
    }

    public static func allowsUnattended(risk: CommandRisk) -> Bool {
        risk <= .l1
    }

    private static func startInterval(for schedule: String) -> Int {
        switch schedule.lowercased() {
        case "hourly": 60 * 60
        case "weekly": 7 * 24 * 60 * 60
        default: 24 * 60 * 60
        }
    }

    private static func sanitizedID(_ id: String) -> String {
        id.lowercased().map { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" ? $0 : "-" }.reduce(into: "") { $0.append($1) }
    }

    private static func escape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}
