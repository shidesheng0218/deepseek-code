import Foundation

/// Identifies which execution runtime owns the resumable command loop for a
/// Session. Ownership is an append-only fact so UI process-local state is
/// never used to decide where a pending approval must be resumed after an
/// App relaunch.
public enum SessionRuntimeOwner: String, Codable, Equatable, Sendable {
    case daemon = "deepseekd"
    case foregroundApp = "foreground_app"
}

public enum SessionRuntimeOwnership {
    public static func assign(
        _ owner: SessionRuntimeOwner,
        sessionID: String,
        repository: SessionRepository,
        instanceID: String,
        commandID: String
    ) throws {
        if self.owner(sessionID: sessionID, repository: repository) == owner {
            return
        }
        _ = try repository.appendDurable(
            sessionID: sessionID,
            type: "runtime_owner_changed",
            payload: [
                "runtime": owner.rawValue,
                "instanceID": instanceID,
                "sessionID": sessionID
            ],
            commandID: commandID
        )
    }

    public static func owner(sessionID: String, repository: SessionRepository) -> SessionRuntimeOwner? {
        guard let rawValue = try? repository.events(sessionID: sessionID)
            .last(where: { $0.type == "runtime_owner_changed" })?
            .payload["runtime"] else {
            return nil
        }
        return SessionRuntimeOwner(rawValue: rawValue)
    }
}
