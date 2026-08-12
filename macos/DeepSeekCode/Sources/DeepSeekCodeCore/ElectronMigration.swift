import Foundation
import SQLite3

public struct ElectronMigrationReport: Equatable, Sendable {
    public let importedProjects: Int
    public let importedSessions: Int
    public let importedEvents: Int
    public let importedProviders: Int
    public let requiresAPIKeyReentry: Bool
}

public enum ElectronDataMigrator {
    public static func migrate(sourceDatabase: URL, destination: SessionRepository, providerCatalog: ProviderCatalog) throws -> ElectronMigrationReport {
        var database: OpaquePointer?
        guard sqlite3_open_v2(sourceDatabase.path, &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK, let database else {
            throw ElectronMigrationError.cannotOpenSource
        }
        defer { sqlite3_close(database) }

        var projectsByPath: [String: ProjectRecord] = [:]
        var importedProjects = 0
        var importedSessions = 0
        var importedEvents = 0
        var importedProviders = 0

        if tableExists("sessions", in: database) {
            for row in try rows("SELECT id, project_path, title, mode, created_at, updated_at FROM sessions ORDER BY created_at ASC;", in: database) {
                let path = row.string(1)
                let project: ProjectRecord
                if let cached = projectsByPath[path] {
                    project = cached
                } else if let existing = try destination.project(path: path) {
                    project = existing
                } else {
                    project = try destination.createProject(name: URL(fileURLWithPath: path).lastPathComponent.isEmpty ? "迁移项目" : URL(fileURLWithPath: path).lastPathComponent, path: path)
                    importedProjects += 1
                }
                projectsByPath[path] = project
                let session = StoredSession(id: row.string(0), projectID: project.id, title: row.string(2), mode: AgentMode(rawValue: row.string(3)) ?? .acceptEdits, status: .waiting, createdAt: parseDate(row.string(4)), updatedAt: parseDate(row.string(5)))
                if try destination.importSession(session) { importedSessions += 1 }
            }
        }

        if tableExists("session_events", in: database) {
            for row in try rows("SELECT session_id, sequence, payload, created_at FROM session_events ORDER BY session_id, sequence ASC;", in: database) {
                let payload = decodePayload(row.string(2))
                let event = SessionEvent(sessionID: row.string(0), sequence: row.int(1), timestamp: parseDate(row.string(3)), type: payload["type"] ?? "electron_event", payload: payload)
                try destination.importEvent(event)
                importedEvents += 1
            }
        }

        if tableExists("provider_profiles", in: database) {
            for row in try rows("SELECT id, name, base_url, protocol, model, api_key_ref, input_per_million, cached_input_per_million, output_per_million FROM provider_profiles;", in: database) {
                let protocolName: ProviderProtocol = row.string(3) == "anthropic-compatible" ? .anthropicCompatible : .openAICompatible
                try providerCatalog.save(ProviderProfile(id: row.string(0), name: row.string(1), baseURL: row.string(2), model: row.string(4), protocolName: protocolName, apiKeyReference: row.string(5), inputPerMillion: row.double(6), cachedInputPerMillion: row.double(7), outputPerMillion: row.double(8)))
                importedProviders += 1
            }
        }

        return ElectronMigrationReport(importedProjects: importedProjects, importedSessions: importedSessions, importedEvents: importedEvents, importedProviders: importedProviders, requiresAPIKeyReentry: importedProviders > 0)
    }

    private static func tableExists(_ table: String, in database: OpaquePointer) -> Bool {
        guard let statement = try? prepare("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ? LIMIT 1;", in: database) else { return false }
        defer { sqlite3_finalize(statement) }
        _ = table.withCString { sqlite3_bind_text(statement, 1, $0, -1, sqliteTransient) }
        return sqlite3_step(statement) == SQLITE_ROW
    }

    private static func rows(_ sql: String, in database: OpaquePointer) throws -> [ElectronRow] {
        let statement = try prepare(sql, in: database)
        defer { sqlite3_finalize(statement) }
        var result: [ElectronRow] = []
        while sqlite3_step(statement) == SQLITE_ROW { result.append(ElectronRow(statement)) }
        return result
    }

    private static func prepare(_ sql: String, in database: OpaquePointer) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw ElectronMigrationError.queryFailed }
        return statement
    }

    private static func parseDate(_ value: String) -> Date {
        ISO8601DateFormatter().date(from: value) ?? Date(timeIntervalSince1970: Double(value) ?? Date().timeIntervalSince1970)
    }

    private static func decodePayload(_ value: String) -> [String: String] {
        guard let data = value.data(using: .utf8), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return ["raw": value] }
        return object.reduce(into: [:]) { result, item in
            switch item.value {
            case let string as String: result[item.key] = string
            case let number as NSNumber: result[item.key] = number.stringValue
            default: result[item.key] = String(describing: item.value)
            }
        }
    }
}

private struct ElectronRow {
    let values: [String]

    init(_ statement: OpaquePointer) {
        values = (0..<sqlite3_column_count(statement)).map { index in
            sqlite3_column_text(statement, index).map { String(cString: $0) } ?? ""
        }
    }

    func string(_ index: Int32) -> String { values[Int(index)] }
    func int(_ index: Int32) -> Int { Int(values[Int(index)]) ?? 0 }
    func double(_ index: Int32) -> Double { Double(values[Int(index)]) ?? 0 }
}

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

public enum ElectronMigrationError: LocalizedError {
    case cannotOpenSource
    case queryFailed

    public var errorDescription: String? {
        switch self {
        case .cannotOpenSource: "无法读取旧版 Electron 数据库"
        case .queryFailed: "读取旧版 Electron 数据库失败"
        }
    }
}
