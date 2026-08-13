import Foundation

/// The foreground App and `deepseekd` deliberately share a Session model but
/// not every host capability yet. This gate makes that boundary explicit:
/// only a fully supported local/worktree text task may move to the daemon.
/// Browser/Computer use, SSH, attachments, hooks and MCP remain foreground
/// until they have an equivalent durable host, rather than silently losing
/// functionality during delegation.
public enum DaemonExecutionEligibility {
    public static func isEligible(
        target: SessionTarget,
        parts: [ContentPart],
        route: TaskRoute,
        hasEnabledHooks: Bool,
        hasEnabledMCP: Bool
    ) -> Bool {
        guard target == .local || target == .worktree else { return false }
        guard !hasEnabledHooks, !hasEnabledMCP else { return false }
        guard !route.needsBrowser else { return false }
        return !parts.contains { part in
            switch part {
            case .text, .codeSelection, .toolEvidence:
                false
            case .image, .document, .browserEvidence, .computerEvidence:
                true
            }
        }
    }
}
