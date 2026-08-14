import Foundation
import DeepSeekCodeCore

@main
struct DeepSeekCodeWorkerChecks {
    static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("deepseek-worker-checks-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Sources", isDirectory: true), withIntermediateDirectories: true)
        try Data("# Worker\n".utf8).write(to: root.appendingPathComponent("README.md"))
        try Data("struct Worker {}\n".utf8).write(to: root.appendingPathComponent("Sources/Worker.swift"))

        let request = WorkerHelperRequest(
            workerSessionID: "worker-session",
            sessionID: "parent-session",
            workerID: "explore-worker",
            workspaceRoot: root.path,
            contract: WorkerSessionContract(parentSessionID: "parent-session", workerKind: .explore, objective: "读取项目")
        )
        let requestLine = String(decoding: try WorkerHelperJSON.encoder.encode(request), as: UTF8.self)
        let executable = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().appendingPathComponent("deepseek-worker")
        let process = Process()
        let input = Pipe()
        let output = Pipe()
        process.executableURL = executable
        process.arguments = ["--stdio"]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = Pipe()
        try process.run()
        try input.fileHandleForWriting.write(contentsOf: Data((requestLine + "\n").utf8))
        try input.fileHandleForWriting.close()
        process.waitUntilExit()
        precondition(process.terminationStatus == 0)
        let responseLine = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .split(separator: "\n")
            .first
            .map(String.init) ?? ""
        let response = try WorkerHelperJSON.decoder.decode(WorkerHelperResponse.self, from: Data(responseLine.utf8))
        precondition(response.ok)
        precondition(response.result?.workerID == "explore-worker")
        precondition(response.result?.summary.contains("README.md") == true)

        let resolverProbe = WorkerResolverProbe(root: root)
        let driver = ProcessChildAgentExecutionDriver(
            executableURL: executable,
            workspaceResolver: { parentSessionID, workerSessionID in
                resolverProbe.record(parentSessionID: parentSessionID, workerSessionID: workerSessionID)
                return root
            },
            timeout: 5
        )
        let driven = try await driver.execute(
            contract: WorkerSessionContract(parentSessionID: "parent-session", workerKind: .explore, objective: "通过 Driver 扫描项目"),
            sessionID: "parent-session",
            workerID: "process-explore-worker",
            workerSessionID: "process-worker-session"
        )
        precondition(driven.workerID == "process-explore-worker")
        precondition(driven.sessionID == "parent-session")
        precondition(driven.summary.contains("README.md"))
        precondition(driven.outputHash.count == 64)
        precondition(resolverProbe.parentSessionID == "parent-session")
        precondition(resolverProbe.workerSessionID == "process-worker-session")

        let repository = try SessionRepository(directory: root.appendingPathComponent("Database", isDirectory: true))
        let project = try repository.createProject(name: "Worker graph", path: root.path)
        let parentSession = try repository.createSession(projectID: project.id, title: "Worker graph parent", mode: .acceptEdits)
        let taskGraph = WorkerTaskGraph(repository: repository)
        let finding = WorkerTaskMessage(
            parentSessionID: parentSession.id,
            workerSessionID: "process-worker-session",
            workerID: "process-explore-worker",
            kind: .finding,
            summary: "发现 README.md 作为项目入口说明",
            evidenceIDs: ["worker-explore-evidence"],
            confidence: 0.92
        )
        _ = try taskGraph.publish(finding)
        let graphMessages = try taskGraph.messages(parentSessionID: parentSession.id)
        precondition(graphMessages == [finding])
        let graphEvents = try repository.eventEnvelopes(sessionID: parentSession.id)
        precondition(graphEvents.last?.kind == SessionEventKind(rawValue: "worker_task_message"))
        precondition(graphEvents.last?.correlationID == parentSession.id)
        print("DeepSeek worker checks passed")
    }
}

private final class WorkerResolverProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let root: URL
    private var parent = ""
    private var worker = ""

    init(root: URL) { self.root = root }

    func record(parentSessionID: String, workerSessionID: String) {
        lock.lock()
        parent = parentSessionID
        worker = workerSessionID
        lock.unlock()
    }

    var parentSessionID: String {
        lock.lock(); defer { lock.unlock() }
        return parent
    }

    var workerSessionID: String {
        lock.lock(); defer { lock.unlock() }
        return worker
    }
}
