import Foundation

/// Stable fault-injection points used by recovery tests and debug builds.
public enum FailureInjectionPoint: String, Codable, CaseIterable, Sendable {
    case afterPlanCreated = "after_plan_created"
    case afterNetworkApproved = "after_network_approved"
    case afterToolStarted = "after_tool_started"
    case afterFileCheckpoint = "after_file_checkpoint"
    case afterPatchApplied = "after_patch_applied"
    case afterTestStarted = "after_test_started"
    case afterBrowserAction = "after_browser_action"
    case afterHandoffPreview = "after_handoff_preview"
    case afterHandoffApply = "after_handoff_apply"
    case afterCommit = "after_commit"
    case afterPush = "after_push"
    case afterPRCreated = "after_pr_created"
    case afterCIPoll = "after_ci_poll"
}

public protocol FailureInjector: Sendable {
    func consume(_ point: FailureInjectionPoint) -> Bool
}

/// Thread-safe, one-shot injector. A point is consumed once, which models a
/// crash immediately after an event boundary without causing repeated crashes.
public final class DeterministicFailureInjector: FailureInjector, @unchecked Sendable {
    private let lock = NSLock()
    private var remaining: Set<FailureInjectionPoint>

    public init(points: Set<FailureInjectionPoint> = []) {
        self.remaining = points
    }

    public func consume(_ point: FailureInjectionPoint) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard remaining.contains(point) else { return false }
        remaining.remove(point)
        return true
    }
}

public struct NoopFailureInjector: FailureInjector {
    public init() {}
    public func consume(_ point: FailureInjectionPoint) -> Bool { false }
}
