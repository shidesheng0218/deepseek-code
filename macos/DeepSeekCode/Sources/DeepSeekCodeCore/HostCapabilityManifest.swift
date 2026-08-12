import Foundation

public enum HostCapabilityError: LocalizedError, Sendable {
    case denied

    public var errorDescription: String? {
        "当前 Host 的能力清单不允许该操作"
    }
}

/// One capability boundary shared by shell, MCP, hooks, plugins and helpers.
/// This is evaluated before a host is invoked; Seatbelt remains the OS-level
/// enforcement for local processes.
public struct HostCapabilityManifest: Codable, Equatable, Sendable {
    public let hostID: String
    public let allowedPaths: [String]
    public let allowedDomains: [String]
    public let allowedEffects: [ToolEffect]
    public let allowedEnvironmentKeys: [String]
    public let maxOutputBytes: Int
    public let timeoutMilliseconds: Int

    public init(hostID: String, allowedPaths: [String] = [], allowedDomains: [String] = [], allowedEffects: [ToolEffect] = [.readOnly], allowedEnvironmentKeys: [String] = [], maxOutputBytes: Int = 128_000, timeoutMilliseconds: Int = 30_000) {
        self.hostID = hostID
        self.allowedPaths = allowedPaths.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().standardizedFileURL.path }
        self.allowedDomains = allowedDomains.map { $0.lowercased() }
        self.allowedEffects = allowedEffects
        self.allowedEnvironmentKeys = allowedEnvironmentKeys.map { $0.uppercased() }
        self.maxOutputBytes = max(1_024, maxOutputBytes)
        self.timeoutMilliseconds = max(100, timeoutMilliseconds)
    }

    public func allows(effect: ToolEffect, path: String? = nil, domain: String? = nil, environmentKey: String? = nil) -> Bool {
        guard allowedEffects.contains(effect) else { return false }
        if let path {
            let normalized = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
            guard allowedPaths.isEmpty || allowedPaths.contains(where: { normalized == $0 || normalized.hasPrefix($0 + "/") }) else { return false }
        }
        if let domain {
            let normalized = domain.lowercased()
            guard allowedDomains.isEmpty || allowedDomains.contains(where: { normalized == $0 || normalized.hasSuffix(".\($0)") }) else { return false }
        }
        if let environmentKey {
            guard allowedEnvironmentKeys.contains(environmentKey.uppercased()) else { return false }
        }
        return true
    }

    public func requiresApproval(for effect: ToolEffect) -> Bool {
        switch effect {
        case .readOnly, .browserRead, .computerRead:
            false
        case .workspaceWrite, .process, .gitWrite, .network, .externalWrite, .browserAct, .computerAct:
            true
        }
    }
}
