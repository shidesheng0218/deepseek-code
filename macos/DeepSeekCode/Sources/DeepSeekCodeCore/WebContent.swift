import Foundation
#if canImport(PDFKit)
import PDFKit
#endif

public enum WebFetchError: LocalizedError, Sendable {
    case unsupportedContentType
    case invalidContent
    case responseTooLarge

    public var errorDescription: String? {
        switch self {
        case .unsupportedContentType: "网页内容类型不支持"
        case .invalidContent: "网页内容无法解析"
        case .responseTooLarge: "网页正文超过上下文限制"
        }
    }
}

public struct WebSection: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let title: String
    public let text: String
    public let level: Int

    public init(id: String = UUID().uuidString, title: String, text: String, level: Int = 1) {
        self.id = id
        self.title = title
        self.text = text
        self.level = level
    }
}

public struct CitationCandidate: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let sourceID: String
    public let quote: String
    public let section: String?
    public let startOffset: Int?
    public let endOffset: Int?
    public let contentHash: String

    public init(id: String = UUID().uuidString, sourceID: String, quote: String, section: String? = nil, startOffset: Int? = nil, endOffset: Int? = nil, contentHash: String) {
        self.id = id
        self.sourceID = sourceID
        self.quote = quote
        self.section = section
        self.startOffset = startOffset
        self.endOffset = endOffset
        self.contentHash = contentHash
    }
}

public typealias Citation = CitationCandidate

public struct WebFetchResponse: Codable, Equatable, Sendable {
    public let sourceID: String
    public let sourceURL: String
    public let finalURL: String
    public let title: String?
    public let contentType: String
    public let statusCode: Int
    public let retrievedAt: Date
    public let contentHash: String
    public let extractedText: String
    public let sections: [WebSection]
    public let warnings: [String]
    public let citationCandidates: [CitationCandidate]

    public init(sourceID: String, sourceURL: String, finalURL: String, title: String?, contentType: String, statusCode: Int, retrievedAt: Date = Date(), contentHash: String, extractedText: String, sections: [WebSection], warnings: [String] = [], citationCandidates: [CitationCandidate] = []) {
        self.sourceID = sourceID
        self.sourceURL = sourceURL
        self.finalURL = finalURL
        self.title = title
        self.contentType = contentType
        self.statusCode = statusCode
        self.retrievedAt = retrievedAt
        self.contentHash = contentHash
        self.extractedText = extractedText
        self.sections = sections
        self.warnings = warnings
        self.citationCandidates = citationCandidates
    }
}

/// Provider seam for public, read-only page retrieval. Tool schemas and UI
/// presentation stay provider-neutral; tests and future providers can supply
/// deterministic evidence without constructing a live URLSession request.
public protocol WebFetchProvider: Sendable {
    func fetch(url: URL, context: NetworkContext) async throws -> WebFetchResponse
}

public enum WebContentExtractor {
    /// The fetch tool may retain enough primary-source context for grounded
    /// research, while `ContextBuilder` remains responsible for reducing what
    /// is sent back to the model on later turns.
    public static func extract(data: Data, contentType: String, sourceID: String, sourceURL: String, finalURL: String? = nil, statusCode: Int, maxCharacters: Int = 200_000) throws -> WebFetchResponse {
        guard data.count <= 2 * 1024 * 1024 else { throw WebFetchError.responseTooLarge }
        let mime = contentType.split(separator: ";", maxSplits: 1).first.map { String($0).lowercased().trimmingCharacters(in: .whitespaces) } ?? ""
        let extracted: (title: String?, text: String, sections: [WebSection])
        switch mime {
        case "text/html", "application/xhtml+xml":
            extracted = try extractHTML(data: data)
        case "application/json":
            guard let object = try? JSONSerialization.jsonObject(with: data), JSONSerialization.isValidJSONObject(object) else { throw WebFetchError.invalidContent }
            let pretty = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
            extracted = (nil, String(decoding: pretty, as: UTF8.self), [])
        case "text/plain":
            extracted = (nil, String(decoding: data, as: UTF8.self), [])
        case "application/pdf":
            extracted = try extractPDF(data: data)
        default:
            throw WebFetchError.unsupportedContentType
        }

        let text = extracted.text
            .replacingOccurrences(of: "\u{0000}", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw WebFetchError.invalidContent }
        let normalized = String(text.prefix(maxCharacters))
        let contentHash = WebEvidenceInspector.sha256(normalized)
        let sections = extracted.sections.map { section in
            WebSection(id: section.id, title: section.title, text: String(section.text.prefix(maxCharacters)), level: section.level)
        }
        let candidates = citationCandidates(sourceID: sourceID, text: normalized, sections: sections, contentHash: contentHash)
        return WebFetchResponse(
            sourceID: sourceID,
            sourceURL: sourceURL,
            finalURL: finalURL ?? sourceURL,
            title: extracted.title,
            contentType: mime,
            statusCode: statusCode,
            contentHash: contentHash,
            extractedText: normalized,
            sections: sections,
            warnings: WebEvidenceInspector.warnings(for: normalized),
            citationCandidates: candidates
        )
    }

    private static func extractHTML(data: Data) throws -> (title: String?, text: String, sections: [WebSection]) {
        let html = String(decoding: data, as: UTF8.self)
        let title = firstCapture(pattern: #"<title[^>]*>(.*?)</title>"#, in: html).map(clean)
        let body = html
            .replacingOccurrences(of: #"<script[\s\S]*?</script>"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"<style[\s\S]*?</style>"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"<noscript[\s\S]*?</noscript>"#, with: " ", options: .regularExpression)
        let sections = sectionsFromHTML(body)
        let text = clean(body.replacingOccurrences(of: #"<[^>]+>"#, with: " ", options: .regularExpression))
        return (title, text, sections)
    }

    private static func sectionsFromHTML(_ html: String) -> [WebSection] {
        let pattern = #"<h([1-6])[^>]*>(.*?)</h\1>"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else { return [] }
        let range = NSRange(html.startIndex..<html.endIndex, in: html)
        let matches = regex.matches(in: html, range: range)
        return matches.enumerated().compactMap { index, match in
            guard let levelValue = capture(match, html: html, index: 1),
                  let rawTitle = capture(match, html: html, index: 2) else { return nil }
            let start = match.range.location + match.range.length
            let end = index + 1 < matches.count ? matches[index + 1].range.location : html.utf8.count
            let startIndex = String.Index(utf16Offset: min(start, html.utf16.count), in: html)
            let endIndex = String.Index(utf16Offset: min(end, html.utf16.count), in: html)
            let body = html[startIndex..<endIndex]
            return WebSection(title: clean(rawTitle), text: clean(String(body.replacingOccurrences(of: #"<[^>]+>"#, with: " ", options: .regularExpression))), level: Int(levelValue) ?? 1)
        }
    }

    private static func extractPDF(data: Data) throws -> (title: String?, text: String, sections: [WebSection]) {
#if canImport(PDFKit)
        guard let document = PDFDocument(data: data) else { throw WebFetchError.invalidContent }
        let pages = (0..<document.pageCount).compactMap { index -> String? in
            guard let page = document.page(at: index), let text = page.string else { return nil }
            return "[Page \(index + 1)]\n\(text)"
        }
        let text = pages.joined(separator: "\n\n")
        guard !text.isEmpty else { throw WebFetchError.invalidContent }
        return (nil, text, pages.enumerated().map { WebSection(title: "Page \($0.offset + 1)", text: $0.element, level: 1) })
#else
        throw WebFetchError.unsupportedContentType
#endif
    }

    private static func citationCandidates(sourceID: String, text: String, sections: [WebSection], contentHash: String) -> [CitationCandidate] {
        let chunks = sections.isEmpty ? text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init) : sections.map(\.text)
        return chunks.filter { $0.count >= 20 }.prefix(8).map { chunk in
            CitationCandidate(sourceID: sourceID, quote: String(chunk.prefix(600)), section: sections.first(where: { $0.text == chunk })?.title, contentHash: contentHash)
        }
    }

    private static func firstCapture(pattern: String, in value: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]),
              let match = regex.firstMatch(in: value, range: NSRange(value.startIndex..<value.endIndex, in: value)) else { return nil }
        return capture(match, html: value, index: 1)
    }

    private static func capture(_ match: NSTextCheckingResult, html: String, index: Int) -> String? {
        guard index < match.numberOfRanges, match.range(at: index).location != NSNotFound,
              let range = Range(match.range(at: index), in: html) else { return nil }
        return String(html[range])
    }

    private static func clean(_ value: String) -> String {
        value
            .replacingOccurrences(of: #"<[^>]+>"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
