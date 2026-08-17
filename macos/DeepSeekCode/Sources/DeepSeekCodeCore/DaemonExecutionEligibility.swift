import Foundation

/// The foreground App and `deepseekd` deliberately share a Session model but
/// not every host capability yet. This gate makes that boundary explicit:
/// only a fully supported local/worktree text task may move to the daemon.
/// Admission is evaluated against a declared daemon capability profile. This
/// makes a missing host an explicit product boundary instead of an implicit
/// `WorkspaceStore` exclusion list.
public enum DaemonExecutionEligibility {
    public static func isEligible(
        target: SessionTarget,
        parts: [ContentPart],
        route: TaskRoute,
        hasEnabledHooks: Bool,
        hasEnabledMCP: Bool,
        profile: RuntimeProfile = DaemonRuntimeProfile.conservative
    ) -> Bool {
        guard target == .local || target == .worktree else { return false }
        let capabilities = Set(profile.capabilities)
        guard capabilities.contains(DaemonRuntimeProfile.workspaceRead) else { return false }
        guard !hasEnabledHooks || capabilities.contains(DaemonRuntimeProfile.hooks) else { return false }
        guard !hasEnabledMCP || capabilities.contains(DaemonRuntimeProfile.mcp) else { return false }
        guard !route.needsBrowser || capabilities.contains(DaemonRuntimeProfile.browser) else { return false }
        return parts.allSatisfy { part in
            switch part {
            case .text, .codeSelection, .toolEvidence:
                return true
            case .image, .document, .browserEvidence, .computerEvidence:
                return capabilities.contains(DaemonRuntimeProfile.attachments)
            }
        }
    }
}
