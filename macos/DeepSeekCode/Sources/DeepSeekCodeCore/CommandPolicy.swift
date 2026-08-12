import Foundation

public enum CommandRisk: Int, Comparable, Codable, Sendable {
    case l0 = 0
    case l1 = 1
    case l2 = 2
    case l3 = 3
    case l4 = 4

    public static func < (lhs: CommandRisk, rhs: CommandRisk) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

public enum CommandPolicy {
    public static func classify(_ command: String) -> CommandRisk {
        let value = command.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let analyzedRisk = ShellIntentAnalyzer.analyze(command).risk
        if value.contains("sudo ") || value.contains("mkfs") || value.contains("diskutil erase") || value.contains("rm -rf /") || value.contains("git push --force") {
            return .l4
        }
        if value.contains("rm ") || value.contains("chmod ") || value.contains("chown ") || value.contains(" mv ") {
            return .l3
        }
        if value.contains("npm install") || value.contains("pnpm install") || value.contains("yarn add") || value.contains("curl ") || value.contains("git commit") || value.contains("git push") {
            return .l2
        }
        if value == "npm test" || value.contains("npm run test") || value.contains("npm run lint") || value.contains("npm run build") || value.contains("pytest") || value.contains("cargo test") || value.contains("go test") {
            return .l1
        }
        return max(.l0, analyzedRisk)
    }
}
