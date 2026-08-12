import Foundation
import DeepSeekCodeCore

@main
struct DeepSeekCodeScheduler {
    static func main() {
        let arguments = CommandLine.arguments
        let taskID = value(after: "--scheduled-task", in: arguments) ?? ""
        let taskFile = value(after: "--task-file", in: arguments)
        guard !taskID.isEmpty else {
            print("DeepSeekCodeScheduler requires --scheduled-task <id>")
            return
        }
        var task: ScheduledTask?
        if let taskFile, let data = try? Data(contentsOf: URL(fileURLWithPath: taskFile)) {
            task = try? JSONDecoder().decode(ScheduledTask.self, from: data)
        }
        let run = ScheduledRunRecord(taskID: taskID, status: task?.isRunnable == true ? .running : .needsAttention)
        let repository = try? SessionRepository(
            directory: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
                .appendingPathComponent("DeepSeekCode/Database", isDirectory: true)
        )
        try? repository?.saveScheduledRun(run)
        var triggerPath: String?
        if let task, task.isRunnable {
            do {
                let inbox = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
                    .appendingPathComponent("DeepSeekCode/ScheduledInbox", isDirectory: true)
                let trigger = try ScheduledTriggerStore.write(ScheduledTrigger(id: run.id, task: task), directory: inbox)
                triggerPath = trigger.path
                launchDesktopApp(trigger: trigger)
            } catch {
                triggerPath = nil
                var failed = run
                failed.status = .needsAttention
                failed.updatedAt = Date()
                try? repository?.saveScheduledRun(failed)
            }
        }
        let result: [String: Any] = [
            "taskID": taskID,
            "status": run.status.rawValue,
            "reason": task?.isRunnable == true ? "scheduler helper created a local trigger; the app will resume the Session" : "task configuration is missing or invalid",
            "triggerPath": triggerPath as Any
        ]
        if let data = try? JSONSerialization.data(withJSONObject: result) {
            print(String(decoding: data, as: UTF8.self))
        }
    }

    private static func launchDesktopApp(trigger: URL) {
        let helperURL = URL(fileURLWithPath: CommandLine.arguments.first ?? "").standardizedFileURL
        let appExecutable = helperURL
            .deletingLastPathComponent() // Library
            .deletingLastPathComponent() // Contents
            .appendingPathComponent("MacOS/DeepSeekCode")
        guard FileManager.default.isExecutableFile(atPath: appExecutable.path) else { return }
        let process = Process()
        process.executableURL = appExecutable
        process.arguments = ["--scheduled-trigger", trigger.path]
        try? process.run()
    }

    private static func value(after flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1]
    }
}
