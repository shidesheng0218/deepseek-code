import CryptoKit
import Foundation

#if os(macOS)
import CoreGraphics
import ImageIO
import PDFKit
import Vision
#endif

public protocol AttachmentDataProvider: Sendable {
    func data(for attachment: AttachmentRef) throws -> Data
}

public struct AttachmentExtraction: Codable, Equatable, Sendable {
    public let text: String
    public let pageCount: Int?
    public let usedOCR: Bool
    public let warnings: [String]

    public init(text: String, pageCount: Int? = nil, usedOCR: Bool = false, warnings: [String] = []) {
        self.text = text
        self.pageCount = pageCount
        self.usedOCR = usedOCR
        self.warnings = warnings
    }
}

public enum AttachmentStoreError: LocalizedError, Sendable {
    case sourceUnavailable
    case invalidKey
    case decryptFailed
    case unsupportedFile
    case extractionFailed(String)

    public var errorDescription: String? {
        switch self {
        case .sourceUnavailable: "附件源文件不可读取"
        case .invalidKey: "附件加密密钥无效"
        case .decryptFailed: "附件解密失败"
        case .unsupportedFile: "暂不支持提取该附件类型"
        case let .extractionFailed(message): "附件提取失败：\(message)"
        }
    }
}

public final class AttachmentStore: AttachmentDataProvider, @unchecked Sendable {
    private let directory: URL
    private let secretStore: any SecretStore
    private let keyReference = "keychain://deepseek-attachments-v1"
    private let lock = NSLock()

    public init(directory: URL, secretStore: any SecretStore) throws {
        self.directory = directory.standardizedFileURL
        self.secretStore = secretStore
        try FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
    }

    public func importFile(at sourceURL: URL) throws -> AttachmentRef {
        guard FileManager.default.isReadableFile(atPath: sourceURL.path) else {
            throw AttachmentStoreError.sourceUnavailable
        }
        let sourceData = try Data(contentsOf: sourceURL)
        let hash = Self.sha256(sourceData)
        let blobURL = directory.appendingPathComponent("\(hash).blob")
        let blobExisted = FileManager.default.fileExists(atPath: blobURL.path)
        if !blobExisted {
            let sealed = try seal(sourceData)
            try sealed.write(to: blobURL, options: .atomic)
        }
        lock.lock()
        addBlobReference(hash: hash, blobExistedBeforeImport: blobExisted)
        lock.unlock()
        return AttachmentRef(
            filename: sourceURL.lastPathComponent,
            kind: Self.kind(for: sourceURL, data: sourceData),
            sha256: hash,
            byteCount: sourceData.count,
            localURL: blobURL,
            extractionState: .pending,
            modelDelivery: .notDelivered
        )
    }

    public func data(for attachment: AttachmentRef) throws -> Data {
        let resolvedURL = resolveURL(attachment.localURL)
        let sealedData = try Data(contentsOf: resolvedURL)
        guard let box = try? AES.GCM.SealedBox(combined: sealedData) else {
            throw AttachmentStoreError.decryptFailed
        }
        do {
            return try AES.GCM.open(box, using: try key())
        } catch {
            throw AttachmentStoreError.decryptFailed
        }
    }

    public func extractText(from attachment: AttachmentRef) throws -> AttachmentExtraction {
        let sourceData = try data(for: attachment)
        switch attachment.kind {
        case .text, .document:
            guard let text = String(data: sourceData, encoding: .utf8) else {
                throw AttachmentStoreError.extractionFailed("文件不是 UTF-8 文本")
            }
            return AttachmentExtraction(text: String(text.prefix(200_000)))
        case .pdf:
#if os(macOS)
            guard let document = PDFDocument(data: sourceData) else { throw AttachmentStoreError.extractionFailed("PDF 无法打开") }
            let text = (0..<document.pageCount).compactMap { document.page(at: $0)?.string }.joined(separator: "\n\n")
            return AttachmentExtraction(text: String(text.prefix(300_000)), pageCount: document.pageCount)
#else
            throw AttachmentStoreError.unsupportedFile
#endif
        case .image:
#if os(macOS)
            return try Self.ocr(data: sourceData)
#else
            return AttachmentExtraction(text: "", usedOCR: false, warnings: ["当前平台未启用 OCR"])
#endif
        case .archive:
            return AttachmentExtraction(text: "[压缩包：\(attachment.filename)。仅保留文件元数据，未自动解压。]", warnings: ["压缩包未解压"])
        case .browserSnapshot, .computerSnapshot:
            guard let text = String(data: sourceData, encoding: .utf8) else {
                throw AttachmentStoreError.extractionFailed("快照数据不可读取")
            }
            return AttachmentExtraction(text: String(text.prefix(200_000)))
        }
    }

    public func delete(_ attachment: AttachmentRef) throws {
        let resolvedURL = resolveURL(attachment.localURL)
        guard resolvedURL.path.hasPrefix(directory.path + "/") else { return }
        let hash = resolvedURL.deletingPathExtension().lastPathComponent
        lock.lock()
        let remaining = dropBlobReference(hash: hash)
        lock.unlock()
        guard remaining == 0 else { return }
        try? FileManager.default.removeItem(at: resolvedURL)
    }

    /// Blobs are content-addressed: two attachments with identical content
    /// share one encrypted blob. A small on-disk refcount index keeps `delete`
    /// from destroying the shared blob while another attachment still uses it.
    private var refcountIndexURL: URL {
        directory.appendingPathComponent("refcounts.json", isDirectory: false)
    }

    private func addBlobReference(hash: String, blobExistedBeforeImport: Bool) {
        var refcounts = loadRefcounts()
        if blobExistedBeforeImport, refcounts[hash] == nil {
            // Legacy blob with unknown users (imported before refcounting
            // existed). Leave it unmanaged so it is never deleted; the next
            // import of the same content starts counting from one.
            return
        }
        refcounts[hash, default: 0] += 1
        writeRefcounts(refcounts)
    }

    /// Returns the remaining reference count. A blob with no recorded
    /// reference (legacy content imported before refcounting existed) is
    /// conservatively treated as still in use and is never deleted.
    private func dropBlobReference(hash: String) -> Int {
        var refcounts = loadRefcounts()
        guard let current = refcounts[hash], current > 0 else { return 1 }
        let remaining = current - 1
        if remaining == 0 {
            refcounts.removeValue(forKey: hash)
        } else {
            refcounts[hash] = remaining
        }
        writeRefcounts(refcounts)
        return remaining
    }

    private func loadRefcounts() -> [String: Int] {
        guard let data = try? Data(contentsOf: refcountIndexURL),
              let value = try? JSONDecoder().decode([String: Int].self, from: data) else {
            return [:]
        }
        return value
    }

    private func writeRefcounts(_ refcounts: [String: Int]) {
        guard let data = try? JSONEncoder().encode(refcounts) else { return }
        try? data.write(to: refcountIndexURL, options: .atomic)
    }

    private func key() throws -> SymmetricKey {
        lock.lock()
        defer { lock.unlock() }
        if let encoded = try secretStore.load(reference: keyReference),
           let data = Data(base64Encoded: encoded), data.count == 32 {
            return SymmetricKey(data: data)
        }
        let data = Data((0..<32).map { _ in UInt8.random(in: .min ... .max) })
        try secretStore.save(reference: keyReference, value: data.base64EncodedString())
        return SymmetricKey(data: data)
    }

    private func seal(_ data: Data) throws -> Data {
        guard let combined = try AES.GCM.seal(data, using: key()).combined else {
            throw AttachmentStoreError.invalidKey
        }
        return combined
    }

    private func resolveURL(_ url: URL) -> URL {
        if url.isFileURL && url.path.hasPrefix("/") && url.path.hasPrefix(directory.path + "/") {
            return url
        }
        return directory.appendingPathComponent(url.lastPathComponent)
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func kind(for url: URL, data: Data) -> AttachmentKind {
        let ext = url.pathExtension.lowercased()
        if ext == "pdf" || data.starts(with: [0x25, 0x50, 0x44, 0x46]) { return .pdf }
        if ["png", "jpg", "jpeg", "gif", "webp", "heic"].contains(ext) { return .image }
        if ["zip", "tar", "gz", "tgz", "7z"].contains(ext) { return .archive }
        return .text
    }

#if os(macOS)
    private static func ocr(data: Data) throws -> AttachmentExtraction {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw AttachmentStoreError.extractionFailed("图片无法解码")
        }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = ["zh-Hans", "en-US"]
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        let text = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
        return AttachmentExtraction(text: String(text.prefix(100_000)), usedOCR: true)
    }
#endif
}
