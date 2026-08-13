import Foundation

public enum ToolEffect: String, Codable, Hashable, Sendable {
    case readOnly
    case workspaceWrite
    case process
    case gitWrite
    case network
    case externalWrite
    case browserRead
    case browserAct
    case computerRead
    case computerAct
}

public struct ToolDescriptor: Codable, Equatable, Sendable {
    public let name: String
    public let effect: ToolEffect
    public let risk: CommandRisk

    public init(name: String, effect: ToolEffect, risk: CommandRisk) {
        self.name = name
        self.effect = effect
        self.risk = risk
    }
}

public struct PermissionContext: Equatable, Sendable {
    public let mode: AgentMode
    public let projectTrusted: Bool
    public let sandboxAvailable: Bool

    public init(mode: AgentMode, projectTrusted: Bool, sandboxAvailable: Bool) {
        self.mode = mode
        self.projectTrusted = projectTrusted
        self.sandboxAvailable = sandboxAvailable
    }
}

public enum PermissionDecision: Equatable, Sendable {
    case allow
    case ask(CommandRisk)
    case block(CommandRisk)
}

public enum PermissionBroker {
    public static func decision(tool: ToolDescriptor, context: PermissionContext) -> PermissionDecision {
        if tool.risk == .l4 {
            return .block(tool.risk)
        }
        let isReadOnly = tool.effect == .readOnly || tool.effect == .browserRead || tool.effect == .computerRead

        if context.mode == .plan {
            return isReadOnly && tool.risk == .l0 ? .allow : .block(tool.risk)
        }
        if isReadOnly && tool.risk == .l0 {
            return .allow
        }
        if context.mode == .manual {
            return .ask(tool.risk)
        }
        if context.mode == .acceptEdits {
            return tool.effect == .workspaceWrite && tool.risk == .l1 ? .allow : .ask(tool.risk)
        }

        // Auto 模式优化：自动允许 web 研究工具（无需项目可信）
        // 这让体验接近 Claude Code，web 搜索被视为低风险操作
        if context.mode == .auto {
            if tool.name == "web.search" || tool.name == "web.fetch" {
                return .allow
            }
        }

        if tool.risk >= .l3 {
            return .block(tool.risk)
        }
        if !context.projectTrusted || !context.sandboxAvailable {
            return tool.effect == .workspaceWrite && tool.risk == .l1 ? .allow : .ask(tool.risk)
        }
        if tool.risk <= .l1 {
            return .allow
        }
        return .ask(tool.risk)
    }
}
