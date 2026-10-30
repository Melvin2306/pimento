import PimentoCore
import SwiftUI

// Building blocks of the Settings panes: a wide pane of two columns of
// grouped cards, rows with right-aligned labels and leading controls (as in
// Apple's settings panes), short secondary notes and ⓘ buttons for the rest.

/// The Settings window's width; each pane is as high as its content.
enum SettingsLayout {
    static let width: CGFloat = 800
    static let padding: CGFloat = 20
    static let columnSpacing: CGFloat = 16
    static let groupSpacing: CGFloat = 14
}

// A classic key: the `@Entry` macro needs full Xcode.
private struct SettingsLabelWidthKey: EnvironmentKey {
    static let defaultValue: CGFloat = 0
}

extension EnvironmentValues {
    /// The width of the label column of `SettingsRow`s, set per column of a
    /// pane so the controls of stacked groups line up. 0: no label column.
    var settingsLabelWidth: CGFloat {
        get { self[SettingsLabelWidthKey.self] }
        set { self[SettingsLabelWidthKey.self] = newValue }
    }
}

/// A pane: padding, checkboxes for toggles, the theme's page background.
struct SettingsPaneContainer<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: SettingsLayout.groupSpacing) { content() }
            .toggleStyle(.checkbox)
            .padding(SettingsLayout.padding)
            .frame(width: SettingsLayout.width, alignment: .topLeading)
            .fixedSize(horizontal: false, vertical: true)
            .themedPageBackground()
    }
}

/// Two columns of groups, top-aligned, each with its own label width.
struct SettingsColumns<Leading: View, Trailing: View>: View {
    var leadingLabelWidth: CGFloat = 0
    var trailingLabelWidth: CGFloat = 0
    /// A fixed width for the leading column; nil: both columns share the width.
    var leadingWidth: CGFloat?
    @ViewBuilder let leading: () -> Leading
    @ViewBuilder let trailing: () -> Trailing

    var body: some View {
        HStack(alignment: .top, spacing: SettingsLayout.columnSpacing) {
            column(leadingLabelWidth, leading)
                .frame(width: leadingWidth)
                .frame(maxWidth: leadingWidth == nil ? .infinity : nil, alignment: .top)
            column(trailingLabelWidth, trailing)
                .frame(maxWidth: .infinity, alignment: .top)
        }
    }

    private func column<C: View>(_ labelWidth: CGFloat, _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: SettingsLayout.groupSpacing) { content() }
            .environment(\.settingsLabelWidth, labelWidth)
    }
}

/// A titled card of rows, like a grouped form section.
struct SettingsGroup<Content: View, Accessory: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content
    @ViewBuilder let accessory: () -> Accessory

    init(_ title: String, @ViewBuilder content: @escaping () -> Content,
         @ViewBuilder accessory: @escaping () -> Accessory) {
        self.title = title
        self.content = content
        self.accessory = accessory
    }

    var body: some View {
        ThemeReader { palette in
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(title)
                        .font(headerFont(palette))
                        .foregroundStyle(headerColor(palette))
                        .accessibilityAddTraits(.isHeader)
                    accessory()
                }
                .padding(.leading, 2)
                VStack(alignment: .leading, spacing: 9) { content() }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 11)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(SettingsCardBackground(palette: palette))
            }
        }
    }

    private func headerFont(_ palette: ThemePalette) -> Font {
        switch palette.theme {
        case .native: .system(size: 13, weight: .semibold)
        case .azure: palette.font(14, weight: .semibold)
        case .windowsXP: palette.font(12, weight: .bold)
        }
    }

    private func headerColor(_ palette: ThemePalette) -> Color {
        switch palette.theme {
        case .native: .primary
        case .azure: palette.text
        // The blue of an XP group box title.
        case .windowsXP: Color(hex: 0x0046D5)
        }
    }
}

extension SettingsGroup where Accessory == EmptyView {
    init(_ title: String, @ViewBuilder content: @escaping () -> Content) {
        self.init(title, content: content, accessory: { EmptyView() })
    }
}

/// The card behind a group's rows, in the theme's look.
private struct SettingsCardBackground: View {
    let palette: ThemePalette

    var body: some View {
        switch palette.theme {
        case .native where palette.isUltra:
            shape(8).fill(Color(hex: 0x0A0A0A)).overlay(shape(8).strokeBorder(Color(hex: 0x1F1F1F)))
        case .native:
            shape(8).fill(Color.primary.opacity(0.035)).overlay(shape(8).strokeBorder(Color.primary.opacity(0.09)))
        case .azure:
            shape(palette.cornerRadius).fill(palette.surface)
                .overlay(shape(palette.cornerRadius).strokeBorder(palette.border))
                .shadow(color: .black.opacity(palette.isDark || palette.isUltra ? 0 : 0.05), radius: 2, y: 1)
        case .windowsXP:
            // An XP group box: an etched, slightly rounded frame on a lighter beige.
            shape(4).fill(Color(hex: 0xF4F3EC)).overlay(shape(4).strokeBorder(Color(hex: 0xD0D0BF)))
        }
    }

    private func shape(_ radius: CGFloat) -> RoundedRectangle { RoundedRectangle(cornerRadius: radius) }
}

/// One row: a right-aligned label (with a colon) in the column's label
/// width, then the control. Without a label the control lines up with the
/// labelled rows' controls; with no label column it starts at the leading edge.
struct SettingsRow<Content: View>: View {
    @Environment(\.settingsLabelWidth) private var labelWidth
    let label: String?
    var alignment: VerticalAlignment = .firstTextBaseline
    @ViewBuilder let content: () -> Content

    init(_ label: String? = nil, alignment: VerticalAlignment = .firstTextBaseline, @ViewBuilder content: @escaping () -> Content) {
        self.label = label
        self.alignment = alignment
        self.content = content
    }

    var body: some View {
        HStack(alignment: alignment, spacing: 8) {
            if labelWidth > 0 {
                Text(label.map { "\($0):" } ?? "")
                    .lineLimit(1)
                    .frame(width: labelWidth, alignment: .trailing)
                    .accessibilityHidden(label == nil)
            }
            VStack(alignment: .leading, spacing: 4) { content() }
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// A short secondary line (orange for a warning, red for an error).
struct SettingsNote: View {
    enum Kind { case info, warning, error }
    let text: String
    var kind: Kind = .info

    init(_ text: String, kind: Kind = .info) {
        self.text = text
        self.kind = kind
    }

    var body: some View {
        ThemeReader { palette in
            Text(text)
                .font(palette.theme == .native ? .caption : palette.font(palette.bodySize - 2))
                .foregroundStyle(color(palette))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func color(_ palette: ThemePalette) -> Color {
        switch kind {
        case .info: palette.theme == .native ? Color.secondary : palette.secondaryText
        case .warning: .orange
        case .error: .red
        }
    }
}

/// Indents a dependent option under the one it depends on.
extension View {
    func settingsIndent() -> some View { padding(.leading, 20) }
}

/// Popover state for `InfoButton` (`@State` needs full Xcode; `@StateObject` doesn't).
private final class PopoverState: ObservableObject {
    @Published var shown = false
}

/// An ⓘ button: `text` as a tooltip on hover and in a popover on click.
struct InfoButton: View {
    let text: String
    var label = "More information"
    @StateObject private var state = PopoverState()

    init(_ text: String, label: String = "More information") {
        self.text = text
        self.label = label
    }

    var body: some View {
        Button { state.shown.toggle() } label: {
            Image(systemName: "info.circle")
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.borderless)
        .help(text)
        .accessibilityLabel(label)
        .accessibilityHint(text)
        .popover(isPresented: $state.shown, arrowEdge: .bottom) {
            Text(text)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: 300, alignment: .leading)
                .padding(12)
                .appAppearanceInPopover()
        }
    }
}
