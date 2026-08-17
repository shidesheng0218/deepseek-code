import Foundation

/// The declarative capability set assembled into `deepseekd`.  It is shared
/// by the daemon and GUI admission policy so a task is never delegated to a
/// runtime that silently lacks one of its requested hosts.
public enum DaemonRuntimeProfile {
    public static let workspaceRead = CapabilityID("workspace.read")
    public static let workspaceWrite = CapabilityID("workspace.write")
    public static let networkBroker = CapabilityID("network.broker")
    public static let webSearch = CapabilityID("web.search")
    public static let webFetch = CapabilityID("web.fetch")
    public static let terminal = CapabilityID("terminal.persistent")
    public static let attachments = CapabilityID("attachments.local")
    public static let hooks = CapabilityID("hooks.pretool")
    public static let mcp = CapabilityID("mcp.runtime")
    public static let browser = CapabilityID("browser.automation")
    public static let ssh = CapabilityID("ssh.runtime")

    public static func registry() -> CapabilityRegistry {
        let registry = CapabilityRegistry()
        registry.register(CapabilityDefinition(id: workspaceRead, version: "1.0.0", dependencies: [], allowedEffects: [.readOnly]))
        registry.register(CapabilityDefinition(id: workspaceWrite, version: "1.0.0", dependencies: [workspaceRead], allowedEffects: [.workspaceWrite]))
        registry.register(CapabilityDefinition(id: networkBroker, version: "1.0.0", dependencies: [], allowedEffects: [.network]))
        registry.register(CapabilityDefinition(id: webSearch, version: "1.0.0", dependencies: [networkBroker], allowedEffects: [.network]))
        registry.register(CapabilityDefinition(id: webFetch, version: "1.0.0", dependencies: [networkBroker], allowedEffects: [.network]))
        registry.register(CapabilityDefinition(id: terminal, version: "1.0.0", dependencies: [workspaceRead], allowedEffects: [.process, .workspaceWrite, .gitWrite]))
        registry.register(CapabilityDefinition(id: attachments, version: "1.0.0", dependencies: [], allowedEffects: [.readOnly]))
        registry.register(CapabilityDefinition(id: hooks, version: "1.0.0", dependencies: [workspaceRead], allowedEffects: [.process]))
        registry.register(CapabilityDefinition(id: mcp, version: "1.0.0", dependencies: [networkBroker], allowedEffects: [.readOnly, .network, .externalWrite]))
        registry.register(CapabilityDefinition(id: browser, version: "1.0.0", dependencies: [networkBroker], allowedEffects: [.browserRead, .browserAct]))
        registry.register(CapabilityDefinition(id: ssh, version: "1.0.0", dependencies: [networkBroker], allowedEffects: [.process, .network]))
        return registry
    }

    public static func make(
        terminalAvailable: Bool,
        attachmentAvailable: Bool,
        hooksAvailable: Bool,
        mcpAvailable: Bool,
        browserAvailable: Bool,
        sshAvailable: Bool,
        permissionMode: PermissionMode = .trustedWorkspace
    ) throws -> RuntimeProfile {
        var capabilities: [CapabilityID] = [workspaceRead, workspaceWrite, webSearch, webFetch]
        if terminalAvailable { capabilities.append(terminal) }
        if attachmentAvailable { capabilities.append(attachments) }
        if hooksAvailable { capabilities.append(hooks) }
        if mcpAvailable { capabilities.append(mcp) }
        if browserAvailable { capabilities.append(browser) }
        if sshAvailable { capabilities.append(ssh) }
        return try RuntimeAssembler(registry: registry()).assemble(
            RuntimeProfile(capabilities: capabilities, permissionMode: permissionMode)
        )
    }

    /// Conservative profile used by clients before they attach to deepseekd.
    /// It only advertises hosts that the production daemon always assembles.
    public static var conservative: RuntimeProfile {
        // All definitions and arguments are static and internally valid.
        try! make(
            terminalAvailable: true,
            attachmentAvailable: true,
            hooksAvailable: false,
            mcpAvailable: false,
            browserAvailable: false,
            sshAvailable: false
        )
    }
}
