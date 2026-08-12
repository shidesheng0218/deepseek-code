import Foundation

public struct HarnessBenchmarkResult: Codable, Equatable, Sendable, Identifiable {
    public let fixtureID: String
    public let title: String
    public let passed: Bool
    public let durationMilliseconds: Int
    public let evidenceIDs: [String]
    public let failure: String?

    public var id: String { fixtureID }

    public init(fixtureID: String, title: String, passed: Bool, durationMilliseconds: Int, evidenceIDs: [String] = [], failure: String? = nil) {
        self.fixtureID = fixtureID
        self.title = title
        self.passed = passed
        self.durationMilliseconds = max(0, durationMilliseconds)
        self.evidenceIDs = evidenceIDs
        self.failure = failure
    }
}

public protocol HarnessBenchmarkFixture: Sendable {
    var id: String { get }
    var title: String { get }
    func run() async throws -> HarnessBenchmarkResult
}

public struct HarnessBenchmarkReport: Codable, Equatable, Sendable {
    public let results: [HarnessBenchmarkResult]
    public let total: Int
    public let passed: Int
    public let failedFixtureIDs: [String]

    public init(results: [HarnessBenchmarkResult]) {
        self.results = results
        total = results.count
        passed = results.filter(\.passed).count
        failedFixtureIDs = results.filter { !$0.passed }.map(\.fixtureID)
    }
}

public struct HarnessBenchmarkRunner: Sendable {
    public let fixtures: [any HarnessBenchmarkFixture]
    public let maxConcurrent: Int

    public init(fixtures: [any HarnessBenchmarkFixture], maxConcurrent: Int = 3) {
        self.fixtures = fixtures
        self.maxConcurrent = min(3, max(1, maxConcurrent))
    }

    public func run() async throws -> HarnessBenchmarkReport {
        var results: [HarnessBenchmarkResult] = []
        for batchStart in stride(from: 0, to: fixtures.count, by: maxConcurrent) {
            let batch = Array(fixtures[batchStart..<min(fixtures.count, batchStart + maxConcurrent)])
            let batchResults = await withTaskGroup(of: HarnessBenchmarkResult.self) { group in
                for fixture in batch {
                    group.addTask {
                        let startedAt = Date()
                        do {
                            var result = try await fixture.run()
                            if result.durationMilliseconds == 0 {
                                result = HarnessBenchmarkResult(
                                    fixtureID: result.fixtureID,
                                    title: result.title,
                                    passed: result.passed,
                                    durationMilliseconds: Int(Date().timeIntervalSince(startedAt) * 1_000),
                                    evidenceIDs: result.evidenceIDs,
                                    failure: result.failure
                                )
                            }
                            return result
                        } catch {
                            return HarnessBenchmarkResult(
                                fixtureID: fixture.id,
                                title: fixture.title,
                                passed: false,
                                durationMilliseconds: Int(Date().timeIntervalSince(startedAt) * 1_000),
                                failure: SecretRedactor.redact(error.localizedDescription)
                            )
                        }
                    }
                }
                var values: [HarnessBenchmarkResult] = []
                for await result in group { values.append(result) }
                return values
            }
            results.append(contentsOf: batchResults)
        }
        return HarnessBenchmarkReport(results: results.sorted { $0.fixtureID < $1.fixtureID })
    }
}
