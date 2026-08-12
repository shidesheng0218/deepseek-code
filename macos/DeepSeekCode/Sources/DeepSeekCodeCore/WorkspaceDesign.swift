import Foundation

/// Shared density and geometry rules for the native desktop shell. The
/// workspace stays information-dense, but no primary reading/control text
/// falls below the system's comfortable desktop range.
public enum WorkspaceTypography: Sendable {
    public static let microSize: Double = 10
    public static let metaSize: Double = 12
    public static let labelSize: Double = 13
    public static let bodySize: Double = 14
    public static let titleSize: Double = 16
    public static let displaySize: Double = 28
}

public enum WorkspaceDesignTokens: Sendable {
    public static let sidebarMinWidth: Double = 250
    public static let sidebarIdealWidth: Double = 288
    public static let sidebarMaxWidth: Double = 344
    public static let conversationMaxWidth: Double = 840
    /// Keeps CJK assistant output from shrinking to a character-by-character
    /// column while the timeline is resolving its flexible width.
    public static let conversationMessageMinWidth: Double = 360
    public static let inspectorMinWidth: Double = 324
    public static let inspectorIdealWidth: Double = 400
    public static let panelCornerRadius: Double = 10
    public static let controlCornerRadius: Double = 8
    public static let compactSpacing: Double = 10
    public static let sectionSpacing: Double = 20
    public static let statusDotSize: Double = 7
    public static let rowMinHeight: Double = 38
    public static let borderOpacity: Double = 0.16
    public static let chromeToolbarHeight: Double = 44
    public static let inspectorTabHeight: Double = 34
    public static let inspectorHeaderHeight: Double = 48
    public static let inspectorContentPadding: Double = 16
    public static let inspectorSectionGap: Double = 12
    public static let inspectorCardCornerRadius: Double = 10
    public static let filesTreeRowHeight: Double = 32
    public static let editorFontSize: Double = 13
    public static let editorChromeVerticalPadding: Double = 9
    public static let footerHeight: Double = 32
    public static let footerControlHeight: Double = 24
    public static let footerItemSpacing: Double = 6
    public static let footerStatusHeight: Double = 20
    public static let sidebarHeaderHeight: Double = 64
    public static let sidebarActionHeight: Double = 32
    public static let sidebarSessionRowHeight: Double = 46
    public static let sidebarSectionGap: Double = 16
    public static let composerDockPadding: Double = 16
    public static let composerInputMinHeight: Double = 108
    public static let composerInputMaxHeight: Double = 208
    public static let conversationComposerInputMinHeight: Double = 68
    public static let conversationComposerInputMaxHeight: Double = 148
    public static let composerChipHeight: Double = 26
    public static let composerActionHeight: Double = 32
    public static let homeContentMaxWidth: Double = 840
    public static let homeOverviewCardWidth: Double = 600
    public static let homeComposerMaxWidth: Double = 1_020
    public static let homeDockHorizontalPadding: Double = 48
    public static let homeDockBottomPadding: Double = 16
    public static let homeHeatmapCellSize: Double = 15
    public static let homeHeatmapGap: Double = 5
    public static let sidebarNavigationRowHeight: Double = 38
    public static let sidebarProjectRowHeight: Double = 38
    public static let homeComposerInputMinHeight: Double = 82
    public static let homeComposerInputMaxHeight: Double = 144
    public static let hoverBackgroundOpacity: Double = 0.08
    public static let hoverBorderOpacity: Double = 0.28
    public static let textButtonHoverOpacity: Double = 0.06
    public static let menuHoverOpacity: Double = 0.08
}
