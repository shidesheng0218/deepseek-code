import Foundation

public enum SecretRedactor {
    public static func redact(_ value: String) -> String {
        var result = value
        result = replacing(pattern: "(?i)Bearer\\s+[^\\s]+", in: result, with: "Bearer [REDACTED]")
        result = replacing(pattern: "\\b(?:sk|ds)-[A-Za-z0-9_-]{8,}\\b", in: result, with: "[REDACTED_KEY]")
        return result
    }

    public static func redact(_ payload: [String: String]) -> [String: String] {
        payload.mapValues(redact)
    }

    private static func replacing(pattern: String, in value: String, with replacement: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return value }
        let range = NSRange(value.startIndex..., in: value)
        return regex.stringByReplacingMatches(in: value, options: [], range: range, withTemplate: replacement)
    }
}
