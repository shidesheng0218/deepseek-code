import Foundation

/// Resolves the tool surface for one concrete model/worker run. A tool can be
/// registered globally and still be absent from a request when the provider,
/// execution mode or sandbox cannot safely support it.
public enum ToolAvailabilityResolver {
    public static func resolve(
        providerCapabilities: ProviderCapabilities,
        agentMode: AgentMode,
        workerKind: AgentWorkerKind,
        target: SessionTarget,
        projectTrusted: Bool,
        sandboxAvailable: Bool,
        tools: [RegisteredTool] = AgentToolSchemas.registry.allTools()
    ) -> [RegisteredTool] {
        tools.filter { tool in
            guard providerCapabilities.toolCalling else { return false }
            guard AgentWorkerPolicy.allows(tool.effect, for: workerKind) else { return false }

            // Plan and read-only child sessions are intentionally incapable of
            // side effects. Keeping unsupported tools out of the schema avoids
            // asking the model to call something that must always be blocked.
            if agentMode == .plan && !isReadOnly(tool.effect) { return false }
            if workerKind != .main && !isReadOnly(tool.effect) { return false }

            // SSH requests must not accidentally receive local workspace or
            // Git writers. For local/worktree tasks, keep normal tools visible
            // and let PermissionBroker decide whether each invocation needs a
            // prompt; hiding them here would break older Accept Edits flows.
            if tool.effect == .workspaceWrite || tool.effect == .gitWrite {
                guard target != .ssh else { return false }
            }
            if tool.effect == .process && target == .ssh {
                // `terminal.*` calls on SSH are routed by SSHToolHost; generic
                // local process tools must not leak into that request.
                guard tool.name.hasPrefix("terminal.") || tool.name == "ssh.execute" else { return false }
            }

            // Attachments are represented by ContentPart and are only sent to
            // a provider after a real capability test.
            if tool.name.hasPrefix("vision.") && !providerCapabilities.imageInput { return false }
            if tool.name.hasPrefix("document.") && !providerCapabilities.documentInput { return false }
            if agentMode == .auto, (!projectTrusted || !sandboxAvailable), [.computerAct, .externalWrite].contains(tool.effect) {
                return false
            }
            return true
        }.sorted { $0.name < $1.name }
    }

    private static func isReadOnly(_ effect: ToolEffect) -> Bool {
        switch effect {
        case .readOnly, .browserRead, .computerRead: return true
        case .workspaceWrite, .process, .gitWrite, .network, .externalWrite, .browserAct, .computerAct: return false
        }
    }
}
