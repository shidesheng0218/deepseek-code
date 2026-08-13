import Foundation
import DeepSeekCodeCore

@main
struct DeepSeekCodeCLI {
    static func main() async {
        do {
            let parsed = parseArguments(Array(CommandLine.arguments.dropFirst()))
            let client = try await connect(storageRoot: parsed.storageRoot)
            try await run(command: parsed.arguments, client: client)
        } catch {
            FileHandle.standardError.write(Data("deepseek: \(SecretRedactor.redact(error.localizedDescription))\n".utf8))
            exit(1)
        }
    }

    private static func run(command: [String], client: DeepSeekDaemonClient) async throws {
        guard let first = command.first else {
            printUsage()
            return
        }
        switch first {
        case "doctor":
            let handshake = try await send(.handshake, client: client)
            let value = try decode(DeepSeekDaemonHandshake.self, handshake.output)
            let sessions = try decode([DeepSeekDaemonSessionSummary].self, (try await send(.sessionList, client: client)).output)
            print("deepseekd protocol \(value.protocolVersion) · instance \(value.instanceID) · sessions \(sessions.count)")
        case "init":
            let path = command.dropFirst().first ?? FileManager.default.currentDirectoryPath
            let session = try await createSession(projectPath: path, title: "CLI Session", client: client)
            print(session.id)
        case "session":
            try await runSessionCommand(Array(command.dropFirst()), client: client)
        case "worker":
            try await runWorkerCommand(Array(command.dropFirst()), client: client)
        case "terminal":
            try await runTerminalCommand(Array(command.dropFirst()), client: client)
        case "ask", "run", "research":
            let input = Array(command.dropFirst())
            let sessionID = optionValue("--session", in: input)
            let prompt = input.filter { $0 != "--session" && $0 != sessionID }.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !prompt.isEmpty else { throw CLIError.invalidUsage("缺少任务内容") }
            let session: StoredSession
            if let sessionID {
                let listed = try decode([DeepSeekDaemonSessionSummary].self, (try await send(.sessionList, client: client)).output)
                guard let match = listed.first(where: { $0.id == sessionID }) else { throw CLIError.invalidUsage("找不到 Session \(sessionID)") }
                session = StoredSession(id: match.id, projectID: match.projectID, title: match.title, mode: .acceptEdits, target: match.target, status: match.status)
            } else {
                session = try await createSession(projectPath: FileManager.default.currentDirectoryPath, title: String(prompt.prefix(72)), client: client)
            }
            let key = "cli-\(UUID().uuidString)"
            _ = try await send(
                .inputAdmit,
                payload: DeepSeekDaemonInputPayload(
                    sessionID: session.id,
                    idempotencyKey: key,
                    delivery: .immediate,
                    parts: [.text(first == "research" ? "联网研究：\(prompt)" : prompt)]
                ),
                client: client
            )
            _ = try await send(.sessionStart, payload: DeepSeekDaemonSessionPayload(sessionID: session.id), client: client)
            try await follow(sessionID: session.id, client: client)
        case "approve":
            guard command.count == 3 else { throw CLIError.invalidUsage("用法：deepseek approve <session-id> <approval-id>") }
            _ = try await send(
                .approvalResolve,
                payload: DeepSeekDaemonApprovalPayload(sessionID: command[1], approvalID: command[2], decision: .allowOnce),
                client: client
            )
            print("approved")
        case "evidence":
            guard command.count == 3, command[1] == "show" else { throw CLIError.invalidUsage("用法：deepseek evidence show <session-id>") }
            let events = try decode([SessionEvent].self, (try await send(.sessionEvents, payload: DeepSeekDaemonEventsPayload(sessionID: command[2]), client: client)).output)
            for event in events where ["evidence_recorded", "web_evidence_recorded", "browser_evidence_recorded", "verification_gate_evaluated"].contains(event.type) {
                print("[\(event.sequence)] \(event.type) \(event.payload)")
            }
        default:
            throw CLIError.invalidUsage("未知命令：\(first)")
        }
    }

    private static func runSessionCommand(_ command: [String], client: DeepSeekDaemonClient) async throws {
        guard let action = command.first else { throw CLIError.invalidUsage("缺少 session 子命令") }
        switch action {
        case "list":
            let sessions = try decode([DeepSeekDaemonSessionSummary].self, (try await send(.sessionList, client: client)).output)
            for session in sessions {
                print("\(session.id)\t\(session.status.rawValue)\t\(session.target.rawValue)\t\(session.title)")
            }
        case "attach":
            guard command.count == 2 else { throw CLIError.invalidUsage("用法：deepseek session attach <id>") }
            let receipt = try decode(SessionAttachReceipt.self, (try await send(.sessionAttach, payload: DeepSeekDaemonSessionPayload(sessionID: command[1]), client: client)).output)
            print("\(receipt.sessionID)\t\(receipt.status.rawValue)\tcursor=\(receipt.eventCursor)\tneedsAttention=\(receipt.needsAttention)")
        case "pause", "resume", "cancel":
            guard command.count == 2 else { throw CLIError.invalidUsage("用法：deepseek session \(action) <id>") }
            let method: DeepSeekDaemonMethod = switch action {
            case "pause": .sessionPause
            case "resume": .sessionResume
            default: .sessionCancel
            }
            _ = try await send(method, payload: DeepSeekDaemonSessionPayload(sessionID: command[1]), client: client)
            print(action)
        default:
            throw CLIError.invalidUsage("未知 session 子命令：\(action)")
        }
    }

    private static func runWorkerCommand(_ command: [String], client: DeepSeekDaemonClient) async throws {
        guard let action = command.first else { throw CLIError.invalidUsage("缺少 worker 子命令") }
        switch action {
        case "create":
            guard command.count >= 4,
                  let kind = AgentWorkerKind(rawValue: command[2]),
                  kind != .main else {
                throw CLIError.invalidUsage("用法：deepseek worker create <session-id> <explore|review|browser|ci> <目标>")
            }
            let objective = command.dropFirst(3).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !objective.isEmpty else { throw CLIError.invalidUsage("Worker 目标不能为空") }
            let response = try await send(
                .workerCreate,
                payload: DeepSeekDaemonWorkerCreatePayload(
                    parentSessionID: command[1],
                    workerKind: kind,
                    objective: objective
                ),
                client: client
            )
            let worker = try decode(WorkerSessionRecord.self, response.output)
            print(worker.id)
        case "list":
            guard command.count == 2 else { throw CLIError.invalidUsage("用法：deepseek worker list <session-id>") }
            let response = try await send(
                .workerList,
                payload: DeepSeekDaemonSessionPayload(sessionID: command[1]),
                client: client
            )
            let workers = try decode([WorkerSessionRecord].self, response.output)
            for worker in workers {
                print("\(worker.id)\t\(worker.state.rawValue)\t\(worker.contract.workerKind.rawValue)\t\(worker.contract.objective)")
            }
        case "start", "cancel", "collect", "adopt":
            guard command.count == 2 else { throw CLIError.invalidUsage("用法：deepseek worker \(action) <worker-session-id>") }
            let payload = DeepSeekDaemonWorkerPayload(workerSessionID: command[1])
            switch action {
            case "start":
                _ = try await send(.workerStart, payload: payload, client: client)
                print("started")
            case "cancel":
                _ = try await send(.workerCancel, payload: payload, client: client)
                print("cancelled")
            case "collect":
                let response = try await send(.workerCollect, payload: payload, client: client)
                let result = try decode(WorkerResultEnvelope.self, response.output)
                print(result.summary)
                if !result.warnings.isEmpty {
                    FileHandle.standardError.write(Data("\n警告：\(result.warnings.joined(separator: "；"))\n".utf8))
                }
            case "adopt":
                _ = try await send(.workerAdopt, payload: payload, client: client)
                print("adopted")
            default:
                break
            }
        default:
            throw CLIError.invalidUsage("未知 worker 子命令：\(action)")
        }
    }

    private static func runTerminalCommand(_ command: [String], client: DeepSeekDaemonClient) async throws {
        guard let action = command.first else { throw CLIError.invalidUsage("缺少 terminal 子命令") }
        switch action {
        case "open":
            guard command.count >= 2 else { throw CLIError.invalidUsage("用法：deepseek terminal open <session-id> [command]") }
            let sessionID = command[1]
            let rawCommand = command.dropFirst(2).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            let response = try await send(
                .terminalOpen,
                payload: DeepSeekDaemonTerminalOpenPayload(sessionID: sessionID, command: rawCommand.isEmpty ? nil : rawCommand, background: true),
                client: client
            )
            print(response.output)
        case "exec":
            guard command.count >= 3 else { throw CLIError.invalidUsage("用法：deepseek terminal exec <session-id> <command> [--approval <id>]") }
            let sessionID = command[1]
            var values = Array(command.dropFirst(2))
            var approvalID: String?
            if let index = values.firstIndex(of: "--approval"), values.indices.contains(index + 1) {
                approvalID = values[index + 1]
                values.removeSubrange(index...index + 1)
            }
            let shellCommand = values.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !shellCommand.isEmpty else { throw CLIError.invalidUsage("终端命令不能为空") }
            let response = try await send(
                .terminalExec,
                payload: DeepSeekDaemonTerminalExecPayload(sessionID: sessionID, command: shellCommand, approvalID: approvalID),
                client: client,
                allowFailure: true
            )
            if response.code == "APPROVAL_REQUIRED" {
                let approval = try decode(DeepSeekDaemonTerminalApprovalRequired.self, response.output)
                FileHandle.standardError.write(Data("需要审批：\(approval.approvalID)（L\(approval.risk.rawValue)）\n".utf8))
                return
            }
            guard response.ok else { throw CLIError.command(response.output) }
            print(response.output)
        case "list":
            guard command.count == 2 else { throw CLIError.invalidUsage("用法：deepseek terminal list <session-id>") }
            let response = try await send(.terminalList, payload: DeepSeekDaemonSessionPayload(sessionID: command[1]), client: client)
            let records = try decode([TerminalSessionRecord].self, response.output)
            for record in records {
                print("\(record.id)\t\(record.state.rawValue)\tpid=\(record.pid.map(String.init) ?? "-")\t\(record.cwd)")
            }
        case "attach":
            guard command.count == 2 else { throw CLIError.invalidUsage("用法：deepseek terminal attach <terminal-id>") }
            let response = try await send(.terminalAttach, payload: DeepSeekDaemonTerminalIDPayload(terminalID: command[1]), client: client)
            print(response.output)
        case "read":
            guard command.count >= 2 else { throw CLIError.invalidUsage("用法：deepseek terminal read <terminal-id> [after-sequence]") }
            let cursor = command.dropFirst(2).first.flatMap(Int.init) ?? -1
            let response = try await send(.terminalRead, payload: DeepSeekDaemonTerminalReadPayload(terminalID: command[1], afterSequence: cursor), client: client)
            let chunks = try decode([TerminalOutputChunk].self, response.output)
            print(chunks.map(\.text).joined(), terminator: "")
        case "write":
            guard command.count >= 3 else { throw CLIError.invalidUsage("用法：deepseek terminal write <terminal-id> <text>") }
            let response = try await send(.terminalWrite, payload: DeepSeekDaemonTerminalWritePayload(terminalID: command[1], data: command.dropFirst(2).joined(separator: " ")), client: client)
            print(response.output)
        case "resize":
            guard command.count == 4, let columns = Int(command[2]), let rows = Int(command[3]) else { throw CLIError.invalidUsage("用法：deepseek terminal resize <terminal-id> <columns> <rows>") }
            _ = try await send(.terminalResize, payload: DeepSeekDaemonTerminalResizePayload(terminalID: command[1], columns: columns, rows: rows), client: client)
            print("resized")
        case "signal":
            guard command.count == 3, let signal = TerminalSignal(rawValue: command[2]) else { throw CLIError.invalidUsage("用法：deepseek terminal signal <terminal-id> <interrupt|terminate|kill|eof>") }
            _ = try await send(.terminalSignal, payload: DeepSeekDaemonTerminalSignalPayload(terminalID: command[1], signal: signal), client: client)
            print("signalled")
        case "ports":
            guard command.count == 2 else { throw CLIError.invalidUsage("用法：deepseek terminal ports <terminal-id>") }
            let response = try await send(.terminalPorts, payload: DeepSeekDaemonTerminalIDPayload(terminalID: command[1]), client: client)
            let ports = try decode([Int].self, response.output)
            print(ports.map(String.init).joined(separator: "\n"))
        case "close":
            guard command.count == 2 else { throw CLIError.invalidUsage("用法：deepseek terminal close <terminal-id>") }
            _ = try await send(.terminalClose, payload: DeepSeekDaemonTerminalIDPayload(terminalID: command[1]), client: client)
            print("closed")
        default:
            throw CLIError.invalidUsage("未知 terminal 子命令：\(action)")
        }
    }

    private static func createSession(projectPath: String, title: String, client: DeepSeekDaemonClient) async throws -> StoredSession {
        let response = try await send(
            .sessionCreate,
            payload: DeepSeekDaemonCreateSessionPayload(projectPath: projectPath, title: title),
            client: client
        )
        return try decode(StoredSession.self, response.output)
    }

    private static func follow(sessionID: String, client: DeepSeekDaemonClient) async throws {
        var cursor = 0
        let deadline = Date().addingTimeInterval(600)
        while Date() < deadline {
            let events = try decode([SessionEvent].self, (try await send(.sessionEvents, payload: DeepSeekDaemonEventsPayload(sessionID: sessionID, afterSequence: cursor), client: client)).output)
            for event in events {
                cursor = max(cursor, event.sequence)
                switch event.type {
                case "assistant_text":
                    FileHandle.standardOutput.write(Data((event.payload["text"] ?? "").utf8))
                case "approval_requested":
                    FileHandle.standardError.write(Data("\n需要审批：\(event.payload["approvalID"] ?? "")\n".utf8))
                case "agent_failed":
                    FileHandle.standardError.write(Data("\nAgent 失败：\(event.payload["message"] ?? "")\n".utf8))
                default:
                    continue
                }
            }
            let receipt = try decode(SessionAttachReceipt.self, (try await send(.sessionAttach, payload: DeepSeekDaemonSessionPayload(sessionID: sessionID), client: client)).output)
            switch receipt.status {
            case .awaitingToolApproval, .completed, .delivered, .needsRepair, .needsAttention, .failed:
                if !events.isEmpty { print(terminator: "\n") }
                return
            default:
                try await Task.sleep(nanoseconds: 150_000_000)
            }
        }
        throw CLIError.invalidUsage("等待 Session 超时；可使用 deepseek session attach \(sessionID) 查看状态")
    }

    private static func send(_ method: DeepSeekDaemonMethod, client: DeepSeekDaemonClient) async throws -> DeepSeekDaemonResponse {
        try await send(method, payload: "{}", client: client)
    }

    private static func send<T: Encodable>(_ method: DeepSeekDaemonMethod, payload: T, client: DeepSeekDaemonClient, allowFailure: Bool = false) async throws -> DeepSeekDaemonResponse {
        let data = try DeepSeekDaemonJSON.encoder.encode(payload)
        return try await send(method, payload: String(decoding: data, as: UTF8.self), client: client, allowFailure: allowFailure)
    }

    private static func send(_ method: DeepSeekDaemonMethod, payload: String, client: DeepSeekDaemonClient, allowFailure: Bool = false) async throws -> DeepSeekDaemonResponse {
        let response = try await client.send(DeepSeekDaemonRequest(method: method, payload: payload))
        guard response.ok || allowFailure else { throw CLIError.command(response.output) }
        return response
    }

    private static func decode<T: Decodable>(_ type: T.Type, _ payload: String) throws -> T {
        try DeepSeekDaemonJSON.decoder.decode(T.self, from: Data(payload.utf8))
    }

    private static func connect(storageRoot: URL) async throws -> DeepSeekDaemonClient {
        if let descriptor = try? DeepSeekDaemonClient.loadDescriptor(storageRoot: storageRoot) {
            let client = DeepSeekDaemonClient(descriptor: descriptor)
            if let response = try? await client.send(DeepSeekDaemonRequest(method: .handshake)), response.ok {
                return client
            }
        }
        let candidates = [
            ProcessInfo.processInfo.environment["DEEPSEEKD_PATH"],
            URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.deletingLastPathComponent().appendingPathComponent("deepseekd").path,
            URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
                .deletingLastPathComponent()
                .appendingPathComponent("../Resources/deepseekd")
                .standardizedFileURL.path
        ].compactMap { $0 }.filter { FileManager.default.isExecutableFile(atPath: $0) }
        guard let executable = candidates.first else {
            throw CLIError.command("找不到 deepseekd；请从同一 Release 安装 deepseek 与 deepseekd")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["--root", storageRoot.path]
        process.standardInput = nil
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        for _ in 0..<40 {
            try await Task.sleep(nanoseconds: 100_000_000)
            if let descriptor = try? DeepSeekDaemonClient.loadDescriptor(storageRoot: storageRoot) {
                let client = DeepSeekDaemonClient(descriptor: descriptor)
                if let response = try? await client.send(DeepSeekDaemonRequest(method: .handshake)), response.ok {
                    return client
                }
            }
        }
        throw CLIError.command("deepseekd 未能在本机启动")
    }

    private static func parseArguments(_ values: [String]) -> (storageRoot: URL, arguments: [String]) {
        var root = DeepSeekDaemonPaths.storageRoot()
        var remaining: [String] = []
        var index = 0
        while index < values.count {
            if values[index] == "--root", values.indices.contains(index + 1) {
                root = URL(fileURLWithPath: values[index + 1], isDirectory: true)
                index += 2
            } else {
                remaining.append(values[index])
                index += 1
            }
        }
        return (root, remaining)
    }

    private static func optionValue(_ key: String, in values: [String]) -> String? {
        guard let index = values.firstIndex(of: key), values.indices.contains(index + 1) else { return nil }
        return values[index + 1]
    }

    private static func printUsage() {
        print("""
        deepseek doctor
        deepseek init [project-path]
        deepseek ask|run|research [--session <id>] \"任务\"
        deepseek session list|attach|pause|resume|cancel <id>
        deepseek worker create <session-id> <explore|review|browser|ci> "目标"
        deepseek worker list <session-id>
        deepseek worker start|cancel|collect|adopt <worker-session-id>
        deepseek terminal open|exec|list|attach|read|write|resize|signal|ports|close ...
        deepseek approve <session-id> <approval-id>
        deepseek evidence show <session-id>
        """)
    }
}

private enum CLIError: LocalizedError {
    case invalidUsage(String)
    case command(String)

    var errorDescription: String? {
        switch self {
        case let .invalidUsage(message), let .command(message): message
        }
    }
}
