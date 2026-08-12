import Foundation

public struct ShellIntentAnalysis: Codable, Equatable, Sendable {
    public let risk: CommandRisk
    public let commands: [String]
    public let paths: [String]
    public let hasDynamicSyntax: Bool
    public let hasRedirection: Bool
    public let accessesNetwork: Bool
    public let writesWorkspace: Bool
    public let reasons: [String]

    public init(risk: CommandRisk, commands: [String], paths: [String], hasDynamicSyntax: Bool, hasRedirection: Bool, accessesNetwork: Bool, writesWorkspace: Bool, reasons: [String]) {
        self.risk = risk
        self.commands = commands
        self.paths = paths
        self.hasDynamicSyntax = hasDynamicSyntax
        self.hasRedirection = hasRedirection
        self.accessesNetwork = accessesNetwork
        self.writesWorkspace = writesWorkspace
        self.reasons = reasons
    }
}

/// Conservative shell intent analysis used before PermissionBroker and
/// Seatbelt. It deliberately treats syntax it cannot classify as risky.
public enum ShellIntentAnalyzer {
    public static func analyze(_ command: String) -> ShellIntentAnalysis {
        let value = command.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = value.lowercased()
        var reasons: [String] = []
        var risk: CommandRisk = .l0
        let dynamic = lower.contains("$\\(") || lower.contains("${") || lower.contains("`") || lower.contains("$(")
        let redirection = lower.contains(">") || lower.contains("<")
        let unmatchedQuotes = quoteBalance(value) != 0
        let tokens = tokenize(value)
        let commands = tokens.filter { !$0.isEmpty && !$0.contains("=") && !$0.hasPrefix("-") && $0 != "|" && $0 != ";" && $0 != "&&" && $0 != "||" }
        let commandNames = commands.enumerated().compactMap { index, token -> String? in
            if index == 0 || tokens[safe: max(0, index - 1)] == "|" || tokens[safe: max(0, index - 1)] == ";" || tokens[safe: max(0, index - 1)] == "&&" || tokens[safe: max(0, index - 1)] == "||" {
                return token.lowercased()
            }
            return nil
        }
        let pathTokens = tokens.filter { token in
            token.contains("/") || token.hasPrefix("~") || token.hasPrefix(".")
        }
        if unmatchedQuotes {
            risk = max(risk, .l3)
            reasons.append("引号不完整，无法安全解析")
        }
        if dynamic {
            risk = max(risk, .l2)
            reasons.append("包含动态变量或命令替换")
        }
        if redirection {
            risk = max(risk, .l2)
            reasons.append("包含输入/输出重定向")
        }
        let gitNetworkOperation = isGitNetworkOperation(tokens: tokens)
        if commandNames.contains(where: { ["curl", "wget", "nc", "ssh", "scp"].contains($0) }) || gitNetworkOperation {
            risk = max(risk, .l2)
            reasons.append("可能访问网络或外部仓库")
        }
        if commandNames.contains(where: { ["rm", "rmdir", "unlink", "chmod", "chown", "mv", "cp", "install"].contains($0) }) {
            risk = max(risk, .l3)
            reasons.append("包含文件写入、移动或删除")
        }
        if lower.contains("sudo") || lower.contains("mkfs") || lower.contains("diskutil erase") || lower.contains("git push --force") || lower.contains("rm -rf /") {
            risk = .l4
            reasons.append("包含永久阻止的危险操作")
        }
        if commandNames.contains(where: { ["npm", "pnpm", "yarn", "pytest", "cargo", "go"].contains($0) }) && risk < .l1 {
            risk = .l1
            reasons.append("执行开发工具命令")
        }
        return ShellIntentAnalysis(
            risk: risk,
            commands: commandNames,
            paths: pathTokens,
            hasDynamicSyntax: dynamic,
            hasRedirection: redirection,
            accessesNetwork: commandNames.contains(where: { ["curl", "wget", "nc", "ssh", "scp"].contains($0) }) || gitNetworkOperation,
            writesWorkspace: risk >= .l2,
            reasons: reasons
        )
    }

    private static func quoteBalance(_ value: String) -> Int {
        var single = false
        var double = false
        var escaped = false
        for character in value {
            if escaped { escaped = false; continue }
            if character == "\\" { escaped = true; continue }
            if character == "'" && !double { single.toggle() }
            if character == "\"" && !single { double.toggle() }
        }
        return (single ? 1 : 0) + (double ? 1 : 0)
    }

    private static func tokenize(_ value: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var quote: Character?
        var escaped = false
        func flush() {
            if !current.isEmpty { tokens.append(current); current = "" }
        }
        for character in value {
            if escaped { current.append(character); escaped = false; continue }
            if character == "\\" { escaped = true; continue }
            if let activeQuote = quote {
                if character == activeQuote { quote = nil } else { current.append(character) }
                continue
            }
            if character == "'" || character == "\"" { quote = character; continue }
            if character == " " || character == "\t" || character == "\n" { flush(); continue }
            if "|;&<>".contains(character) {
                flush(); tokens.append(String(character)); continue
            }
            current.append(character)
        }
        flush()
        return tokens
    }

    private static func isGitNetworkOperation(tokens: [String]) -> Bool {
        let networkSubcommands: Set<String> = ["clone", "fetch", "pull", "push", "ls-remote", "submodule"]
        for (index, token) in tokens.enumerated() where token.lowercased() == "git" {
            var next = index + 1
            while next < tokens.count {
                let candidate = tokens[next].lowercased()
                if candidate == "-c" || candidate == "--git-dir" || candidate == "--work-tree" {
                    next += 2
                    continue
                }
                if candidate.hasPrefix("-") {
                    next += 1
                    continue
                }
                return networkSubcommands.contains(candidate)
            }
        }
        return false
    }
}

private extension Array {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
