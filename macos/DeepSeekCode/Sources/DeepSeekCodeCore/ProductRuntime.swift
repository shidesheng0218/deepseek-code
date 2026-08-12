import Foundation

/// The shipped macOS product is the SwiftUI runtime. This identity is kept in
/// Core so the UI, diagnostics, control plane and release scripts all expose
/// the same answer about which binary is running.
public struct ProductRuntimeIdentity: Codable, Equatable, Sendable {
    public let productName: String
    public let buildID: String
    public let version: String
    public let sourceOfTruth: String
    public let bundlePath: String
    public let executablePath: String

    public init(bundle: Bundle = .main) {
        productName = "DeepSeek Code"
        version = (bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
            ?? "0.1.0"
        let infoBuild = (bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let stampURL = bundle.url(forResource: "build-stamp", withExtension: "txt")
        let fileBuild = stampURL.flatMap { try? String(contentsOf: $0, encoding: .utf8) }?.trimmingCharacters(in: .whitespacesAndNewlines)
        buildID = [infoBuild, fileBuild].compactMap { $0 }.first(where: { !$0.isEmpty }) ?? "development"
        sourceOfTruth = "swift-native"
        bundlePath = bundle.bundleURL.path
        executablePath = bundle.executableURL?.path ?? ProcessInfo.processInfo.arguments.first ?? ""
    }

    public var displayLabel: String { "\(productName) · \(buildID)" }
}

public struct ProductRuntimeDiagnostics: Codable, Equatable, Sendable {
    public let identity: ProductRuntimeIdentity
    public let generatedAt: Date
    public let legacyElectronPath: String?

    public init(identity: ProductRuntimeIdentity = ProductRuntimeIdentity(), generatedAt: Date = Date(), legacyElectronPath: String? = nil) {
        self.identity = identity
        self.generatedAt = generatedAt
        self.legacyElectronPath = legacyElectronPath
    }
}
