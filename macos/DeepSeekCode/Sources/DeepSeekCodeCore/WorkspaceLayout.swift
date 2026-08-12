import Foundation

public enum WorkspaceInspectorContent: String, CaseIterable, Sendable {
    case changes
    case files
    case browser
    case review
    case terminal
}

/// Width policy shared by the desktop shell and its checks.
/// The UI uses a stacked inspector when a horizontal three-column layout
/// would make the conversation or inspector unreadably narrow.
public struct WorkspaceLayoutMetrics: Equatable, Sendable {
    public let isInspectorVisible: Bool
    public let consumesInspectorSpace: Bool
    public let usesStackedInspector: Bool
    public let rightPanelMinWidth: Double
    public let rightPanelIdealWidth: Double
    public let rightPanelMaxWidth: Double
    public let conversationMinWidth: Double
    public let conversationIdealWidth: Double
    public let conversationContentMaxWidth: Double
    public let contentPadding: Double

    /// Alias used by the shell contract and UI layout code. Keeping the older
    /// name preserves source compatibility with the Files panel layout.
    public var usesStackedLayout: Bool { usesStackedInspector }

    public static func forDetailWidth(
        _ width: Double,
        inspectorContent: WorkspaceInspectorContent = .changes,
        inspectorVisible: Bool = true
    ) -> WorkspaceLayoutMetrics {
        let width = width.isFinite ? max(0, width) : 0
        let isFilesInspector = inspectorContent == .files

        // Claude-style shell: an empty/closed inspector is not an invisible
        // third column. The conversation owns the detail area and keeps a
        // readable content measure inside it.
        if !inspectorVisible {
            let isNarrow = width < 760
            return WorkspaceLayoutMetrics(
                isInspectorVisible: false,
                consumesInspectorSpace: false,
                usesStackedInspector: isNarrow,
                rightPanelMinWidth: 0,
                rightPanelIdealWidth: 0,
                rightPanelMaxWidth: 0,
                conversationMinWidth: 0,
                conversationIdealWidth: width,
                conversationContentMaxWidth: min(WorkspaceDesignTokens.conversationMaxWidth, max(0, width - (isNarrow ? 28 : 96))),
                contentPadding: isNarrow ? 16 : 24
            )
        }

        if width < 860 {
            return WorkspaceLayoutMetrics(
                isInspectorVisible: true,
                consumesInspectorSpace: true,
                usesStackedInspector: true,
                rightPanelMinWidth: 0,
                rightPanelIdealWidth: 0,
                rightPanelMaxWidth: .infinity,
                conversationMinWidth: 0,
                conversationIdealWidth: width,
                conversationContentMaxWidth: min(WorkspaceDesignTokens.conversationMaxWidth, max(0, width - 32)),
                contentPadding: isFilesInspector ? 18 : 16
            )
        }

        let isMedium = width < 1_200
        let rightIdeal: Double
        let rightMin: Double
        let rightMax: Double
        if isFilesInspector {
            rightMin = isMedium ? 300 : 360
            rightIdeal = isMedium
                ? min(460, max(360, width * 0.36))
                : min(700, max(540, width * 0.40))
            rightMax = isMedium
                ? min(560, max(440, width * 0.46))
                : min(760, max(620, width * 0.50))
        } else {
            rightMin = isMedium ? 260 : 300
            rightIdeal = isMedium
                ? min(360, max(300, width * 0.31))
                : min(440, max(340, width * 0.26))
            rightMax = isMedium ? 420 : min(520, max(420, width * 0.34))
        }

        return WorkspaceLayoutMetrics(
            isInspectorVisible: true,
            consumesInspectorSpace: true,
            usesStackedInspector: false,
            rightPanelMinWidth: rightMin,
            rightPanelIdealWidth: rightIdeal,
            rightPanelMaxWidth: rightMax,
            conversationMinWidth: isMedium ? (isFilesInspector ? 360 : 420) : (isFilesInspector ? 460 : 520),
            conversationIdealWidth: max(isMedium ? (isFilesInspector ? 430 : 500) : (isFilesInspector ? 620 : 680), width - rightIdeal),
            conversationContentMaxWidth: min(WorkspaceDesignTokens.conversationMaxWidth, max(isMedium ? 620 : 700, width - rightIdeal - 48)),
            contentPadding: isMedium ? (isFilesInspector ? 20 : 22) : (isFilesInspector ? 28 : 34)
        )
    }

    private init(
        isInspectorVisible: Bool,
        consumesInspectorSpace: Bool,
        usesStackedInspector: Bool,
        rightPanelMinWidth: Double,
        rightPanelIdealWidth: Double,
        rightPanelMaxWidth: Double,
        conversationMinWidth: Double,
        conversationIdealWidth: Double,
        conversationContentMaxWidth: Double,
        contentPadding: Double
    ) {
        self.isInspectorVisible = isInspectorVisible
        self.consumesInspectorSpace = consumesInspectorSpace
        self.usesStackedInspector = usesStackedInspector
        self.rightPanelMinWidth = rightPanelMinWidth
        self.rightPanelIdealWidth = rightPanelIdealWidth
        self.rightPanelMaxWidth = rightPanelMaxWidth
        self.conversationMinWidth = conversationMinWidth
        self.conversationIdealWidth = conversationIdealWidth
        self.conversationContentMaxWidth = conversationContentMaxWidth
        self.contentPadding = contentPadding
    }
}
