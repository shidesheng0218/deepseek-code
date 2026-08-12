import Foundation

public enum GitHubCommandBuilder {
    public static func createPR(title: String, body: String, base: String, head: String) -> String {
        [
            "gh pr create",
            "--title", quote(title),
            "--body", quote(body),
            "--base", quote(base),
            "--head", quote(head)
        ].joined(separator: " ")
    }

    public static func ciStatus(prNumber: Int) -> String {
        "gh pr checks \(prNumber)"
    }

    public static func ciLogs(runID: String) -> String {
        "gh run view \(quote(runID)) --log-failed"
    }

    public static func viewPR(prNumber: Int) -> String {
        "gh pr view \(prNumber) --json number,title,state,url,headRefName,baseRefName"
    }

    public static func push(remote: String = "origin", branch: String? = nil) -> String {
        ["git push", quote(remote), branch.map(quote)].compactMap { $0 }.joined(separator: " ")
    }

    public static func replyReview(prNumber: Int, body: String) -> String {
        "gh pr comment \(prNumber) --body \(quote(body))"
    }

    private static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

public struct ProcessGitHubCommandRunner: GitHubCommandRunning {
    public let workingDirectory: URL?
    public let timeout: TimeInterval

    public init(workingDirectory: URL? = nil, timeout: TimeInterval = 60) {
        self.workingDirectory = workingDirectory
        self.timeout = timeout
    }

    public func run(arguments: [String]) async throws -> String {
        try await Task.detached(priority: .userInitiated) {
            let process = Process()
            let output = Pipe()
            let errors = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["gh"] + arguments
            process.currentDirectoryURL = workingDirectory
            process.standardOutput = output
            process.standardError = errors
            try process.run()
            let deadline = Date().addingTimeInterval(timeout)
            while process.isRunning && Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
            if process.isRunning {
                process.terminate()
                throw UnifiedRuntimeError.remote("GitHub CLI 请求超时")
            }
            let stdout = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            let stderr = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            guard process.terminationStatus == 0 else { throw UnifiedRuntimeError.remote(stderr.isEmpty ? stdout : stderr) }
            return stdout
        }.value
    }

    public func runGit(arguments: [String]) async throws -> String {
        try await Task.detached(priority: .userInitiated) {
            let process = Process()
            let output = Pipe()
            let errors = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["git"] + arguments
            process.currentDirectoryURL = workingDirectory
            process.standardOutput = output
            process.standardError = errors
            try process.run()
            let deadline = Date().addingTimeInterval(timeout)
            while process.isRunning && Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
            if process.isRunning {
                process.terminate()
                throw UnifiedRuntimeError.remote("Git Push 请求超时")
            }
            let stdout = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            let stderr = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            guard process.terminationStatus == 0 else { throw UnifiedRuntimeError.remote(stderr.isEmpty ? stdout : stderr) }
            return stdout
        }.value
    }
}

public struct GitHubDeliveryRecord: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let sessionID: String
    public var pullRequestURL: String?
    public var pullRequestNumber: Int?
    public var ciState: String?
    public var lastEvidence: String?
    public let createdAt: Date

    public init(id: String = UUID().uuidString, sessionID: String, pullRequestURL: String? = nil, pullRequestNumber: Int? = nil, ciState: String? = nil, lastEvidence: String? = nil, createdAt: Date = Date()) {
        self.id = id
        self.sessionID = sessionID
        self.pullRequestURL = pullRequestURL
        self.pullRequestNumber = pullRequestNumber
        self.ciState = ciState
        self.lastEvidence = lastEvidence
        self.createdAt = createdAt
    }
}

public struct CIFailureEvidence: Codable, Equatable, Sendable {
    public let repository: String
    public let pullRequestNumber: Int
    public let workflow: String
    public let job: String
    public let failedStep: String
    public let logExcerpt: String
    public let commitSHA: String
    public let createdAt: Date

    public init(repository: String, pullRequestNumber: Int, workflow: String, job: String, failedStep: String, logExcerpt: String, commitSHA: String, createdAt: Date = Date()) {
        self.repository = repository
        self.pullRequestNumber = pullRequestNumber
        self.workflow = workflow
        self.job = job
        self.failedStep = failedStep
        self.logExcerpt = logExcerpt
        self.commitSHA = commitSHA
        self.createdAt = createdAt
    }

    public static func parse(repository: String, pullRequestNumber: Int, workflow: String, job: String, log: String, commitSHA: String) -> CIFailureEvidence {
        let lines = log.split(whereSeparator: \.isNewline).map(String.init)
        let step = lines.first(where: { $0.hasPrefix("Run ") })?.dropFirst(4).trimmingCharacters(in: .whitespacesAndNewlines)
            ?? lines.first(where: { $0.localizedCaseInsensitiveContains("error") })?.trimmingCharacters(in: .whitespacesAndNewlines)
            ?? "CI step failed"
        let excerpt = lines.suffix(80).joined(separator: "\n")
        return CIFailureEvidence(repository: repository, pullRequestNumber: pullRequestNumber, workflow: workflow, job: job, failedStep: step, logExcerpt: SecretRedactor.redact(excerpt), commitSHA: commitSHA)
    }
}

public actor GitHubDeliveryCoordinator {
    private let runner: any GitHubCommandRunning
    private let repository: SessionRepository?
    private let networkRuntime: NetworkRuntime?

    public init(runner: any GitHubCommandRunning, repository: SessionRepository? = nil, networkRuntime: NetworkRuntime? = nil) {
        self.runner = runner
        self.repository = repository
        self.networkRuntime = networkRuntime
    }

    public func createPullRequest(sessionID: String, title: String, body: String, base: String, head: String, approved: Bool) async throws -> GitHubDeliveryRecord {
        guard approved else { throw UnifiedRuntimeError.remote("创建 Pull Request 需要用户审批") }
        let endpoint = URL(string: "https://api.github.com")!
        await networkRuntime?.recordExternalRequest(capability: .github, operation: .delivery, url: endpoint, sessionID: sessionID, projectID: nil, state: .started)
        do {
            let output = try await runner.run(arguments: ["pr", "create", "--title", title, "--body", body, "--base", base, "--head", head])
            let url = output.split(whereSeparator: { $0.isNewline }).last.map(String.init)
            let number = url.flatMap { Int($0.split(separator: "/").last ?? "") }
            let record = GitHubDeliveryRecord(sessionID: sessionID, pullRequestURL: url, pullRequestNumber: number, lastEvidence: output)
            try repository?.saveGitHubDelivery(record)
            try repository?.append(sessionID: sessionID, type: "github_pr_created", payload: ["deliveryID": record.id, "url": url ?? "", "evidence": SecretRedactor.redact(output)])
            try repository?.append(sessionID: sessionID, type: "evidence_recorded", payload: [
                "id": UUID().uuidString,
                "kind": EvidenceKind.network.rawValue,
                "title": "Pull Request",
                "detail": SecretRedactor.redact(output),
                "succeeded": "true"
            ])
            await networkRuntime?.recordExternalRequest(capability: .github, operation: .delivery, url: endpoint, sessionID: sessionID, projectID: nil, state: .completed, statusCode: 0)
            return record
        } catch {
            await networkRuntime?.recordExternalRequest(capability: .github, operation: .delivery, url: endpoint, sessionID: sessionID, projectID: nil, state: .failed, errorMessage: error.localizedDescription)
            throw error
        }
    }

    public func refreshChecks(sessionID: String, delivery: inout GitHubDeliveryRecord, number: Int) async throws {
        let endpoint = URL(string: "https://api.github.com")!
        await networkRuntime?.recordExternalRequest(capability: .github, operation: .read, url: endpoint, sessionID: sessionID, projectID: nil, state: .started)
        do {
            let output = try await runner.run(arguments: ["pr", "checks", "\(number)"])
            delivery.ciState = output.localizedCaseInsensitiveContains("pass") ? "passed" : (output.localizedCaseInsensitiveContains("fail") ? "failed" : "pending")
            delivery.lastEvidence = output
            try repository?.saveGitHubDelivery(delivery)
            try repository?.append(sessionID: sessionID, type: "github_ci_evidence", payload: ["deliveryID": delivery.id, "state": delivery.ciState ?? "pending", "detail": SecretRedactor.redact(output)])
            try repository?.append(sessionID: sessionID, type: "evidence_recorded", payload: [
                "id": UUID().uuidString,
                "kind": EvidenceKind.network.rawValue,
                "title": "CI",
                "detail": SecretRedactor.redact(output),
                "succeeded": delivery.ciState == "passed" ? "true" : "false"
            ])
            if delivery.ciState == "failed" {
                let failure = CIFailureEvidence.parse(repository: "", pullRequestNumber: number, workflow: "unknown", job: "unknown", log: output, commitSHA: "")
                let encoded = (try? JSONEncoder().encode(failure)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
                try repository?.append(sessionID: sessionID, type: "ci_failure_evidence", payload: ["evidence": encoded])
            }
            await networkRuntime?.recordExternalRequest(capability: .github, operation: .read, url: endpoint, sessionID: sessionID, projectID: nil, state: .completed, statusCode: 0)
        } catch {
            await networkRuntime?.recordExternalRequest(capability: .github, operation: .read, url: endpoint, sessionID: sessionID, projectID: nil, state: .failed, errorMessage: error.localizedDescription)
            throw error
        }
    }

    public func fetchCILogs(sessionID: String, runID: String, repositoryName: String, pullRequestNumber: Int, workflow: String = "unknown", job: String = "unknown", commitSHA: String = "") async throws -> CIFailureEvidence {
        let endpoint = URL(string: "https://api.github.com")!
        await networkRuntime?.recordExternalRequest(capability: .github, operation: .read, url: endpoint, sessionID: sessionID, projectID: nil, state: .started)
        do {
            let output = try await runner.run(arguments: ["run", "view", runID, "--log-failed"])
            let failure = CIFailureEvidence.parse(repository: repositoryName, pullRequestNumber: pullRequestNumber, workflow: workflow, job: job, log: output, commitSHA: commitSHA)
            let encoded = (try? JSONEncoder().encode(failure)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
            try repository?.append(sessionID: sessionID, type: "ci_failure_evidence", payload: ["evidence": encoded])
            await networkRuntime?.recordExternalRequest(capability: .github, operation: .read, url: endpoint, sessionID: sessionID, projectID: nil, state: .completed, statusCode: 0)
            return failure
        } catch {
            await networkRuntime?.recordExternalRequest(capability: .github, operation: .read, url: endpoint, sessionID: sessionID, projectID: nil, state: .failed, errorMessage: error.localizedDescription)
            throw error
        }
    }

    public func fetchCILogs(sessionID: String, repositoryName: String, pullRequestNumber: Int, runID: String, workflow: String, job: String, commitSHA: String) async throws -> CIFailureEvidence {
        let endpoint = URL(string: "https://api.github.com")!
        await networkRuntime?.recordExternalRequest(capability: .github, operation: .read, url: endpoint, sessionID: sessionID, projectID: nil, state: .started)
        do {
            let output = try await runner.run(arguments: ["run", "view", runID, "--log-failed"])
            let failure = CIFailureEvidence.parse(repository: repositoryName, pullRequestNumber: pullRequestNumber, workflow: workflow, job: job, log: output, commitSHA: commitSHA)
            let encoded = (try? JSONEncoder().encode(failure)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
            try repository?.append(sessionID: sessionID, type: "ci_failure_evidence", payload: ["evidence": encoded])
            try repository?.append(sessionID: sessionID, type: "evidence_recorded", payload: [
                "id": UUID().uuidString,
                "kind": EvidenceKind.network.rawValue,
                "title": "CI Failure",
                "detail": failure.logExcerpt,
                "succeeded": "false"
            ])
            await networkRuntime?.recordExternalRequest(capability: .github, operation: .read, url: endpoint, sessionID: sessionID, projectID: nil, state: .completed, statusCode: 0)
            return failure
        } catch {
            await networkRuntime?.recordExternalRequest(capability: .github, operation: .read, url: endpoint, sessionID: sessionID, projectID: nil, state: .failed, errorMessage: error.localizedDescription)
            throw error
        }
    }

    public func createFixSession(from sessionID: String, projectID: String, failure: CIFailureEvidence, contract: TaskContract, repository: SessionRepository? = nil) throws -> StoredSession {
        guard let repository = repository ?? self.repository else { throw UnifiedRuntimeError.remote("Session 数据库不可用") }
        let title = "修复 CI：\(failure.failedStep)"
        let branch = "deepseek/ci-fix-\(failure.pullRequestNumber)-\(UUID().uuidString.prefix(8).lowercased())"
        let session = try repository.createSession(projectID: projectID, title: title, mode: .acceptEdits, target: .worktree, branch: branch)
        try repository.saveTaskContract(contract, sessionID: session.id)
        let encoded = (try? JSONEncoder().encode(failure)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        try repository.append(sessionID: session.id, type: "github_ci_fix_session", payload: ["sourceSessionID": sessionID, "pullRequest": "\(failure.pullRequestNumber)", "failure": encoded])
        try repository.append(sessionID: session.id, type: "ci_fix_session_created", payload: ["sourceSessionID": sessionID, "pullRequest": "\(failure.pullRequestNumber)", "failedStep": failure.failedStep])
        try repository.append(sessionID: sessionID, type: "ci_fix_session_created", payload: ["fixSessionID": session.id, "pullRequest": "\(failure.pullRequestNumber)", "failedStep": failure.failedStep])
        return session
    }

    public func createFixSessionFromCILogs(sessionID: String, projectID: String, runID: String, repositoryName: String, pullRequestNumber: Int, contract: TaskContract, workflow: String = "unknown", job: String = "unknown", commitSHA: String = "") async throws -> StoredSession {
        let failure = try await fetchCILogs(sessionID: sessionID, runID: runID, repositoryName: repositoryName, pullRequestNumber: pullRequestNumber, workflow: workflow, job: job, commitSHA: commitSHA)
        return try createFixSession(from: sessionID, projectID: projectID, failure: failure, contract: contract)
    }

    public func createFixSession(from sessionID: String, projectID: String, title: String, repository: SessionRepository) throws -> StoredSession {
        let contract = try repository.taskContract(sessionID: sessionID) ?? TaskContract.compatibility(prompt: title)
        let failure = CIFailureEvidence(repository: "", pullRequestNumber: 0, workflow: "", job: "", failedStep: title, logExcerpt: "", commitSHA: "")
        return try createFixSession(from: sessionID, projectID: projectID, failure: failure, contract: contract, repository: repository)
    }
}
