import SwiftUI
import DeepSeekCodeCore

enum AppTheme {
    static let canvas = Color(nsColor: .windowBackgroundColor)
    static let sidebar = Color(nsColor: .controlBackgroundColor)
    static let panel = Color(nsColor: .underPageBackgroundColor)
    static let elevated = Color(nsColor: .controlBackgroundColor)
    static let chrome = Color(nsColor: .controlBackgroundColor).opacity(0.72)
    static let hover = Color.primary.opacity(WorkspaceDesignTokens.hoverBackgroundOpacity)
    static let selected = Color.primary.opacity(0.085)
    static let border = Color(nsColor: .separatorColor)
    static let text = Color(nsColor: .labelColor)
    static let secondaryText = Color(nsColor: .secondaryLabelColor)
    static let tertiaryText = Color(nsColor: .tertiaryLabelColor)
    static let terminalBackground = Color(red: 0.075, green: 0.082, blue: 0.09)
    static let terminalText = Color(red: 0.87, green: 0.89, blue: 0.9)
}

struct AppPanelModifier: ViewModifier {
    var padding: CGFloat = 12

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(AppTheme.elevated, in: RoundedRectangle(cornerRadius: WorkspaceDesignTokens.panelCornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: WorkspaceDesignTokens.panelCornerRadius, style: .continuous)
                    .stroke(AppTheme.border.opacity(0.72), lineWidth: 1)
            }
    }
}

struct InspectorCard<Content: View>: View {
    let padding: CGFloat
    @ViewBuilder let content: Content

    init(padding: CGFloat = 12, @ViewBuilder content: () -> Content) {
        self.padding = padding
        self.content = content()
    }

    var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(padding)
            .background(Color.primary.opacity(0.028), in: RoundedRectangle(cornerRadius: WorkspaceDesignTokens.inspectorCardCornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: WorkspaceDesignTokens.inspectorCardCornerRadius, style: .continuous)
                    .stroke(AppTheme.border.opacity(0.42), lineWidth: 1)
            }
    }
}

struct AppBadge: View {
    let title: String
    var systemImage: String?
    var tint: Color = .secondary

    var body: some View {
        HStack(spacing: 4) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: WorkspaceTypography.microSize, weight: .semibold))
            }
            Text(title)
                .font(.system(size: WorkspaceTypography.microSize, weight: .medium))
                .lineLimit(1)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(tint.opacity(0.10), in: Capsule(style: .continuous))
        .overlay {
            Capsule(style: .continuous)
                .stroke(tint.opacity(0.14), lineWidth: 1)
        }
    }
}

struct InteractiveBadgeLabel: View {
    let title: String
    var systemImage: String?
    var tint: Color = .secondary
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 4) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: WorkspaceTypography.microSize, weight: .semibold))
            }
            Text(title)
                .font(.system(size: WorkspaceTypography.microSize, weight: .medium))
                .lineLimit(1)
        }
        .foregroundStyle(isHovered ? .primary : tint)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(isHovered ? AppTheme.hover : tint.opacity(0.10), in: Capsule(style: .continuous))
        .overlay {
            Capsule(style: .continuous)
                .stroke(isHovered ? AppTheme.border.opacity(WorkspaceDesignTokens.hoverBorderOpacity) : tint.opacity(0.14), lineWidth: 1)
        }
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovered)
    }
}

struct AppSectionHeader: View {
    let title: String
    var systemImage: String?
    var actionTitle: String?
    var actionSystemImage: String?
    var action: (() -> Void)?

    var body: some View {
        HStack(spacing: 7) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: WorkspaceTypography.metaSize, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            Text(title)
                .font(.system(size: WorkspaceTypography.labelSize, weight: .semibold))
                .foregroundStyle(.primary)
            Spacer()
            if let actionTitle, let action {
                Button(actionTitle, systemImage: actionSystemImage ?? "arrow.clockwise", action: action)
                    .buttonStyle(AppTextButtonStyle())
                    .font(.system(size: WorkspaceTypography.metaSize, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(minHeight: 24)
    }
}

struct AppStatusDot: View {
    let color: Color

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: WorkspaceDesignTokens.statusDotSize, height: WorkspaceDesignTokens.statusDotSize)
    }
}

struct AppIconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        AppIconButtonBody(label: configuration.label, isPressed: configuration.isPressed)
    }
}

private struct AppIconButtonBody<Label: View>: View {
    let label: Label
    let isPressed: Bool
    @State private var isHovered = false

    var body: some View {
        label
            .font(.system(size: WorkspaceTypography.metaSize, weight: .medium))
            .foregroundStyle(isPressed || isHovered ? Color.primary : Color.secondary)
            .frame(width: 32, height: 30)
            .background((isPressed ? Color.primary.opacity(0.12) : isHovered ? AppTheme.hover : Color.clear), in: RoundedRectangle(cornerRadius: WorkspaceDesignTokens.controlCornerRadius, style: .continuous))
            .contentShape(Rectangle())
            .onHover { isHovered = $0 }
            .animation(.easeOut(duration: 0.12), value: isHovered)
    }
}

struct AppToolbarIconButton: View {
    let title: String
    let systemImage: String
    var isDisabled = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
        }
        .buttonStyle(AppIconButtonStyle())
        .disabled(isDisabled)
        .help(title)
        .accessibilityLabel(title)
    }
}

struct AppPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        AppPrimaryButtonBody(label: configuration.label, isPressed: configuration.isPressed)
    }
}

private struct AppPrimaryButtonBody<Label: View>: View {
    let label: Label
    let isPressed: Bool
    @State private var isHovered = false

    var body: some View {
        label
            .font(.system(size: WorkspaceTypography.labelSize, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .frame(height: 32)
            .background(Color.accentColor.opacity(isPressed ? 0.78 : isHovered ? 0.88 : 1), in: RoundedRectangle(cornerRadius: WorkspaceDesignTokens.controlCornerRadius, style: .continuous))
            .opacity(isPressed ? 0.86 : 1)
            .onHover { isHovered = $0 }
            .animation(.easeOut(duration: 0.12), value: isHovered)
    }
}

struct AppSecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        AppSecondaryButtonBody(label: configuration.label, isPressed: configuration.isPressed)
    }
}

struct AppTextButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        AppTextButtonBody(label: configuration.label, isPressed: configuration.isPressed)
    }
}

private struct AppTextButtonBody<Label: View>: View {
    let label: Label
    let isPressed: Bool
    @State private var isHovered = false

    var body: some View {
        label
            .foregroundStyle(isPressed || isHovered ? .primary : .secondary)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(isHovered ? Color.primary.opacity(WorkspaceDesignTokens.textButtonHoverOpacity) : Color.clear, in: RoundedRectangle(cornerRadius: WorkspaceDesignTokens.controlCornerRadius, style: .continuous))
            .contentShape(Rectangle())
            .onHover { isHovered = $0 }
            .animation(.easeOut(duration: 0.12), value: isHovered)
    }
}

private struct AppSecondaryButtonBody<Label: View>: View {
    let label: Label
    let isPressed: Bool
    @State private var isHovered = false

    var body: some View {
        label
            .font(.system(size: WorkspaceTypography.metaSize, weight: .medium))
            .foregroundStyle(.primary)
            .padding(.horizontal, 11)
            .frame(height: 32)
            .background(Color.primary.opacity(isPressed ? 0.10 : isHovered ? WorkspaceDesignTokens.hoverBackgroundOpacity : 0.055), in: RoundedRectangle(cornerRadius: WorkspaceDesignTokens.controlCornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: WorkspaceDesignTokens.controlCornerRadius, style: .continuous)
                    .stroke(AppTheme.border.opacity(isHovered ? WorkspaceDesignTokens.hoverBorderOpacity : 0.75), lineWidth: 1)
            }
            .onHover { isHovered = $0 }
            .animation(.easeOut(duration: 0.12), value: isHovered)
    }
}

extension View {
    func appPanel(padding: CGFloat = 12) -> some View {
        modifier(AppPanelModifier(padding: padding))
    }

    func appSectionTitle() -> some View {
        font(.system(size: WorkspaceTypography.metaSize, weight: .semibold))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
            .tracking(0.3)
    }
}
