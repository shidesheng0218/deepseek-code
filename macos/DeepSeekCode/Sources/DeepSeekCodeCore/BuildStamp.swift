import Foundation

/// The build identity is intentionally read from the application bundle so a
/// refreshed app can explain exactly which binary is running. Unit-test and
/// command-line bundles fall back to a stable development label.
public enum BuildStamp {
    public static var current: String {
        ProductRuntimeIdentity().buildID
    }
}
