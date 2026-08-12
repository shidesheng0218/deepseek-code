import Foundation

public enum AttachmentKind: String, Codable, CaseIterable, Sendable {
    case image
    case document
    case pdf
    case text
    case archive
    case browserSnapshot
    case computerSnapshot
}

public enum ExtractionState: String, Codable, Sendable {
    case pending
    case extracting
    case completed
    case failed
    case notApplicable
}

public enum ModelDeliveryState: String, Codable, Sendable {
    case notDelivered
    case pending
    case delivered
    case downgradedToText
    case blocked
    case failed
}

public struct AttachmentRef: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let filename: String
    public let kind: AttachmentKind
    public let sha256: String
    public let byteCount: Int
    public let localURL: URL
    public var extractionState: ExtractionState
    public var modelDelivery: ModelDeliveryState

    public init(
        id: String = UUID().uuidString,
        filename: String,
        kind: AttachmentKind,
        sha256: String,
        byteCount: Int,
        localURL: URL,
        extractionState: ExtractionState = .pending,
        modelDelivery: ModelDeliveryState = .notDelivered
    ) {
        self.id = id
        self.filename = filename
        self.kind = kind
        self.sha256 = sha256
        self.byteCount = byteCount
        self.localURL = localURL
        self.extractionState = extractionState
        self.modelDelivery = modelDelivery
    }

    private enum CodingKeys: String, CodingKey {
        case id, filename, kind, sha256, byteCount, blobName, extractionState, modelDelivery
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(filename, forKey: .filename)
        try container.encode(kind, forKey: .kind)
        try container.encode(sha256, forKey: .sha256)
        try container.encode(byteCount, forKey: .byteCount)
        try container.encode(localURL.lastPathComponent, forKey: .blobName)
        try container.encode(extractionState, forKey: .extractionState)
        try container.encode(modelDelivery, forKey: .modelDelivery)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        filename = try container.decode(String.self, forKey: .filename)
        kind = try container.decode(AttachmentKind.self, forKey: .kind)
        sha256 = try container.decode(String.self, forKey: .sha256)
        byteCount = try container.decode(Int.self, forKey: .byteCount)
        let blobName = try container.decodeIfPresent(String.self, forKey: .blobName) ?? filename
        localURL = URL(fileURLWithPath: blobName)
        extractionState = try container.decodeIfPresent(ExtractionState.self, forKey: .extractionState) ?? .pending
        modelDelivery = try container.decodeIfPresent(ModelDeliveryState.self, forKey: .modelDelivery) ?? .notDelivered
    }
}

public struct BrowserEvidenceRef: Codable, Equatable, Sendable {
    public let id: String
    public let url: String
    public let title: String
    public let summary: String
    public let screenshotAttachmentID: String?

    public init(id: String = UUID().uuidString, url: String, title: String = "", summary: String, screenshotAttachmentID: String? = nil) {
        self.id = id
        self.url = url
        self.title = title
        self.summary = summary
        self.screenshotAttachmentID = screenshotAttachmentID
    }
}

public struct ComputerEvidenceRef: Codable, Equatable, Sendable {
    public let id: String
    public let application: String
    public let windowTitle: String
    public let summary: String
    public let screenshotAttachmentID: String?

    public init(id: String = UUID().uuidString, application: String, windowTitle: String = "", summary: String, screenshotAttachmentID: String? = nil) {
        self.id = id
        self.application = application
        self.windowTitle = windowTitle
        self.summary = summary
        self.screenshotAttachmentID = screenshotAttachmentID
    }
}

public struct EvidenceRef: Codable, Equatable, Sendable {
    public let id: String
    public let kind: String
    public let title: String
    public let detail: String

    public init(id: String = UUID().uuidString, kind: String, title: String, detail: String) {
        self.id = id
        self.kind = kind
        self.title = title
        self.detail = detail
    }
}

public struct VisualElement: Codable, Equatable, Sendable {
    public let role: String
    public let label: String
    public let bounds: String?

    public init(role: String, label: String, bounds: String? = nil) {
        self.role = role
        self.label = label
        self.bounds = bounds
    }
}

public struct VisualObservation: Codable, Equatable, Sendable {
    public let summary: String
    public let visibleText: [String]
    public let uiElements: [VisualElement]
    public let errors: [String]
    public let uncertainty: [String]
    public let sourceAttachmentID: String

    public init(summary: String, visibleText: [String] = [], uiElements: [VisualElement] = [], errors: [String] = [], uncertainty: [String] = [], sourceAttachmentID: String) {
        self.summary = summary
        self.visibleText = visibleText
        self.uiElements = uiElements
        self.errors = errors
        self.uncertainty = uncertainty
        self.sourceAttachmentID = sourceAttachmentID
    }
}

public enum ContentPart: Codable, Equatable, Sendable {
    case text(String)
    case image(AttachmentRef)
    case document(AttachmentRef)
    case codeSelection(path: String, startLine: Int, endLine: Int, text: String)
    case browserEvidence(BrowserEvidenceRef)
    case computerEvidence(ComputerEvidenceRef)
    case toolEvidence(EvidenceRef)

    private enum CodingKeys: String, CodingKey {
        case type
        case text
        case attachment
        case path
        case startLine
        case endLine
        case evidence
    }

    private enum Kind: String, Codable {
        case text
        case image
        case document
        case codeSelection
        case browserEvidence
        case computerEvidence
        case toolEvidence
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .text(value):
            try container.encode(Kind.text, forKey: .type)
            try container.encode(value, forKey: .text)
        case let .image(value):
            try container.encode(Kind.image, forKey: .type)
            try container.encode(value, forKey: .attachment)
        case let .document(value):
            try container.encode(Kind.document, forKey: .type)
            try container.encode(value, forKey: .attachment)
        case let .codeSelection(path, startLine, endLine, value):
            try container.encode(Kind.codeSelection, forKey: .type)
            try container.encode(path, forKey: .path)
            try container.encode(startLine, forKey: .startLine)
            try container.encode(endLine, forKey: .endLine)
            try container.encode(value, forKey: .text)
        case let .browserEvidence(value):
            try container.encode(Kind.browserEvidence, forKey: .type)
            try container.encode(value, forKey: .evidence)
        case let .computerEvidence(value):
            try container.encode(Kind.computerEvidence, forKey: .type)
            try container.encode(value, forKey: .evidence)
        case let .toolEvidence(value):
            try container.encode(Kind.toolEvidence, forKey: .type)
            try container.encode(value, forKey: .evidence)
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(Kind.self, forKey: .type)
        switch kind {
        case .text:
            self = .text(try container.decode(String.self, forKey: .text))
        case .image:
            self = .image(try container.decode(AttachmentRef.self, forKey: .attachment))
        case .document:
            self = .document(try container.decode(AttachmentRef.self, forKey: .attachment))
        case .codeSelection:
            self = .codeSelection(
                path: try container.decode(String.self, forKey: .path),
                startLine: try container.decode(Int.self, forKey: .startLine),
                endLine: try container.decode(Int.self, forKey: .endLine),
                text: try container.decode(String.self, forKey: .text)
            )
        case .browserEvidence:
            self = .browserEvidence(try container.decode(BrowserEvidenceRef.self, forKey: .evidence))
        case .computerEvidence:
            self = .computerEvidence(try container.decode(ComputerEvidenceRef.self, forKey: .evidence))
        case .toolEvidence:
            self = .toolEvidence(try container.decode(EvidenceRef.self, forKey: .evidence))
        }
    }
}

public struct SessionBudget: Codable, Equatable, Sendable {
    public var maxToolTurns: Int
    public var maxWallClockSeconds: Int
    public var maxInputTokens: Int
    public var maxOutputTokens: Int
    public var maxCost: Decimal?

    public init(maxToolTurns: Int = 40, maxWallClockSeconds: Int = 1_800, maxInputTokens: Int = 200_000, maxOutputTokens: Int = 40_000, maxCost: Decimal? = nil) {
        self.maxToolTurns = max(1, maxToolTurns)
        self.maxWallClockSeconds = max(30, maxWallClockSeconds)
        self.maxInputTokens = max(1_000, maxInputTokens)
        self.maxOutputTokens = max(1_000, maxOutputTokens)
        self.maxCost = maxCost
    }
}

public struct ProviderCapabilities: Codable, Equatable, Sendable {
    public var toolCalling: Bool
    public var parallelReadTools: Bool
    public var imageInput: Bool
    public var documentInput: Bool
    public var promptCaching: Bool
    public var maxContextTokens: Int

    public init(toolCalling: Bool, parallelReadTools: Bool, imageInput: Bool, documentInput: Bool, promptCaching: Bool, maxContextTokens: Int) {
        self.toolCalling = toolCalling
        self.parallelReadTools = parallelReadTools
        self.imageInput = imageInput
        self.documentInput = documentInput
        self.promptCaching = promptCaching
        self.maxContextTokens = maxContextTokens
    }

    public static let deepSeekTextOnly = ProviderCapabilities(toolCalling: true, parallelReadTools: true, imageInput: false, documentInput: false, promptCaching: true, maxContextTokens: 128_000)
    public static let visionAdapter = ProviderCapabilities(toolCalling: true, parallelReadTools: true, imageInput: true, documentInput: true, promptCaching: true, maxContextTokens: 128_000)
}

public struct VisionAdapterConfiguration: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var baseURL: String
    public var model: String
    public var apiKeyReference: String

    public init(enabled: Bool = false, baseURL: String = "", model: String = "", apiKeyReference: String = "keychain://deepseek-vision") {
        self.enabled = enabled
        self.baseURL = baseURL
        self.model = model
        self.apiKeyReference = apiKeyReference
    }
}

public extension Array where Element == ContentPart {
    var plainText: String {
        compactMap { part in
            if case let .text(value) = part { return value }
            if case let .codeSelection(path, startLine, endLine, text) = part {
                return "[代码 \(path):\(startLine)-\(endLine)]\n\(text)"
            }
            if case let .browserEvidence(evidence) = part { return "[浏览器证据 \(evidence.url)]\n\(evidence.summary)" }
            if case let .computerEvidence(evidence) = part { return "[桌面证据 \(evidence.application)]\n\(evidence.summary)" }
            if case let .toolEvidence(evidence) = part { return "[工具证据 \(evidence.title)]\n\(evidence.detail)" }
            return nil
        }.joined(separator: "\n\n")
    }
}
