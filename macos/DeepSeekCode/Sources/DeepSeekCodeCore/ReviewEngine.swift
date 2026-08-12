import Foundation

public enum ReviewEngine {
    private struct AddedLine: Sendable {
        let file: String
        let line: Int
        let text: String
    }

    public static func scan(diff: String) -> [ReviewFinding] {
        let addedLines = parseAddedLines(diff)
        guard !addedLines.isEmpty else { return [] }

        var findings: [ReviewFinding] = []
        let grouped = Dictionary(grouping: addedLines, by: \.file)
        for file in grouped.keys.sorted() {
            guard let lines = grouped[file] else { continue }
            if let securityLine = lines.first(where: { containsSecretMarker($0.text) }) {
                findings.append(ReviewFinding(
                    severity: .p0,
                    category: .security,
                    file: securityLine.file,
                    startLine: securityLine.line,
                    endLine: securityLine.line,
                    title: "疑似将敏感凭据写入代码",
                    evidence: "第 \(securityLine.line) 行新增代码包含 api key、password、secret 或 private key 关键词。",
                    recommendation: "移除硬编码凭据，改用 macOS Keychain 或环境变量，并确认历史提交中没有泄露。"
                ))
            }

            if let correctnessLine = lines.first(where: { $0.text.contains("fatalError(") || $0.text.contains("!.") }) {
                findings.append(ReviewFinding(
                    severity: .p1,
                    category: .correctness,
                    file: correctnessLine.file,
                    startLine: correctnessLine.line,
                    endLine: correctnessLine.line,
                    title: "新增代码可能引入不可恢复失败",
                    evidence: "第 \(correctnessLine.line) 行检测到 fatalError 或强制解包模式。",
                    recommendation: "使用可恢复错误、guard 或显式失败状态，并补充对应测试。"
                ))
            }
        }

        return findings
    }

    private static func parseAddedLines(_ diff: String) -> [AddedLine] {
        var result: [AddedLine] = []
        var currentFile = "<diff>"
        var newLine = 1
        var inHunk = false

        for rawLine in diff.components(separatedBy: .newlines) {
            if rawLine.hasPrefix("+++ ") {
                let path = String(rawLine.dropFirst(4))
                currentFile = path.hasPrefix("b/") ? String(path.dropFirst(2)) : path
                inHunk = false
                continue
            }

            if rawLine.hasPrefix("@@") {
                guard let range = newLineRange(from: rawLine) else {
                    inHunk = false
                    continue
                }
                newLine = range.lowerBound
                inHunk = true
                continue
            }

            guard inHunk, !rawLine.hasPrefix("\\") else { continue }
            if rawLine.hasPrefix("+") {
                result.append(AddedLine(file: currentFile, line: newLine, text: String(rawLine.dropFirst())))
                newLine += 1
            } else if rawLine.hasPrefix("-") {
                continue
            } else {
                newLine += 1
            }
        }

        // A compact patch without file/hunk headers is still useful for local callers.
        if result.isEmpty {
            let compactLines = diff.components(separatedBy: .newlines).enumerated().compactMap { index, line -> AddedLine? in
                guard line.hasPrefix("+") && !line.hasPrefix("+++") else { return nil }
                return AddedLine(file: currentFile, line: index + 1, text: String(line.dropFirst()))
            }
            result.append(contentsOf: compactLines)
        }

        return result
    }

    private static func newLineRange(from hunk: String) -> ClosedRange<Int>? {
        let pattern = #"@@ -\d+(?:,\d+)? \+(\d+)(?:,(\d+))? @@"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: hunk, range: NSRange(hunk.startIndex..., in: hunk)),
              let startRange = Range(match.range(at: 1), in: hunk),
              let start = Int(hunk[startRange]) else { return nil }
        let count: Int
        if match.range(at: 2).location != NSNotFound, let countRange = Range(match.range(at: 2), in: hunk) {
            count = max(1, Int(hunk[countRange]) ?? 1)
        } else {
            count = 1
        }
        return start...(start + max(0, count - 1))
    }

    private static func containsSecretMarker(_ text: String) -> Bool {
        text.range(of: #"(?i)(api[_-]?key|password|secret|private[_-]?key)"#, options: .regularExpression) != nil
    }
}
