import AppKit
import PimentoCore
import SwiftUI

// The look chosen in Settings › General › Appearance. Only styling lives here:
// every view keeps its controls, actions, shortcuts and accessibility labels,
// and with `.native` each modifier below returns its content unchanged.
//
// The themed looks are inspired by the Azure portal and Windows XP. They use
// only colours and shapes; no Microsoft logo, icon, wallpaper, sound or font is
// bundled (Segoe UI and Tahoma are used only when the Mac already has them).

// MARK: - Environment

// A classic key: the `@Entry` macro needs full Xcode.
private struct AppThemeKey: EnvironmentKey {
    static let defaultValue: AppTheme = .native
}

extension EnvironmentValues {
    var appTheme: AppTheme {
        get { self[AppThemeKey.self] }
        set { self[AppThemeKey.self] = newValue }
    }
}

// MARK: - Palette

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: opacity)
    }
}

/// Colours and fonts of one theme in one colour scheme. Only read for the
/// Azure and XP themes; the native look uses the system styles directly.
struct ThemePalette {
    let theme: AppTheme
    let isDark: Bool

    init(_ theme: AppTheme, _ scheme: ColorScheme) {
        self.theme = theme
        // XP had no dark mode: its windows are forced to the light appearance.
        isDark = scheme == .dark && theme == .azure
    }

    private func pick(azure light: UInt32, _ dark: UInt32, xp: UInt32) -> Color {
        Color(hex: theme == .windowsXP ? xp : isDark ? dark : light)
    }

    /// Window / page background.
    var page: Color { pick(azure: 0xFAF9F8, 0x1B1A19, xp: 0xECE9D8) }
    /// Cards, the list area and text fields.
    var surface: Color { pick(azure: 0xFFFFFF, 0x252423, xp: 0xFFFFFF) }
    /// The bottom bar.
    var bar: Color { pick(azure: 0xFFFFFF, 0x252423, xp: 0xECE9D8) }
    var border: Color { pick(azure: 0xEDEBE9, 0x3B3A39, xp: 0x7F9DB9) }
    var fieldBorder: Color { pick(azure: 0x8A8886, 0x8A8886, xp: 0x7F9DB9) }
    var text: Color { pick(azure: 0x323130, 0xF3F2F1, xp: 0x000000) }
    var secondaryText: Color { pick(azure: 0x605E5C, 0xC8C6C4, xp: 0x5A5A5A) }

    var accent: Color { pick(azure: 0x0078D4, 0x2899F5, xp: 0x316AC5) }
    var accentFill: Color { pick(azure: 0x0078D4, 0x0078D4, xp: 0x316AC5) }
    var accentHover: Color { pick(azure: 0x106EBE, 0x106EBE, xp: 0x2C5FB3) }
    var accentPressed: Color { pick(azure: 0x005A9E, 0x005A9E, xp: 0x2552A0) }

    /// Checked rows.
    var selection: Color { pick(azure: 0xDEECF9, 0x004578, xp: 0x316AC5) }
    var selectionText: Color { pick(azure: 0x323130, 0xFFFFFF, xp: 0xFFFFFF) }
    var rowHover: Color { pick(azure: 0xF3F2F1, 0x323130, xp: 0xC1D2EE) }

    var success: Color { pick(azure: 0x107C10, 0x92C353, xp: 0x1E7B1E) }
    var successFill: Color { pick(azure: 0xDFF6DD, 0x2D3B1E, xp: 0xE3F4DC) }
    var danger: Color { pick(azure: 0xA4262C, 0xF1707B, xp: 0xC00000) }
    var dangerFill: Color { pick(azure: 0xFDE7E9, 0x442726, xp: 0xFDE3E3) }
    var warning: Color { pick(azure: 0xD83B01, 0xFC9867, xp: 0xC25A00) }
    var warningFill: Color { pick(azure: 0xFED9CC, 0x4A2A1C, xp: 0xFFF1C9) }
    var neutralFill: Color { pick(azure: 0xF3F2F1, 0x3B3A39, xp: 0xF1EFE2) }
    var infoFill: Color { pick(azure: 0xF3F2F1, 0x323130, xp: 0xFFFFE1) }

    /// The Azure top strip.
    var headerBackground: Color { pick(azure: 0x1B1A19, 0x0B0A0A, xp: 0x0058EE) }

    var cornerRadius: CGFloat { theme == .windowsXP ? 3 : 2 }

    // MARK: Fonts

    /// The theme's UI font, if the Mac has it; nil means the system font.
    var fontName: String? {
        switch theme {
        case .native: nil
        case .azure: Self.segoeUI
        case .windowsXP: Self.tahoma
        }
    }

    var bodySize: CGFloat { theme == .windowsXP ? 12 : 13 }

    func font(_ size: CGFloat? = nil, weight: Font.Weight = .regular) -> Font {
        let size = size ?? bodySize
        guard let fontName else { return .system(size: size, weight: weight) }
        return .custom(fontName, size: size).weight(weight)
    }

    // Looked up once. Nothing is bundled: without the font, the system one is used.
    private static let segoeUI = installedFont(["Segoe UI"])
    private static let tahoma = installedFont(["Tahoma", "Verdana"])

    private static func installedFont(_ names: [String]) -> String? {
        names.first { NSFont(name: $0, size: 12) != nil }
    }
}

/// Reads the theme and colour scheme and hands the palette to `content`.
struct ThemeReader<Content: View>: View {
    @Environment(\.appTheme) private var theme
    @Environment(\.colorScheme) private var scheme
    @ViewBuilder let content: (ThemePalette) -> Content

    var body: some View { content(ThemePalette(theme, scheme)) }
}

// MARK: - Window root

/// A window's content in the theme chosen in Settings, applied live.
struct AppThemed<Content: View>: View {
    @Environment(AppModel.self) private var model
    @ViewBuilder let content: () -> Content

    var body: some View { content().appTheme(model.prefs.theme) }
}

extension View {
    /// Puts `theme` into the environment, with its font, accent and window
    /// appearance (XP is always light). For a window's root view.
    func appTheme(_ theme: AppTheme) -> some View {
        modifier(ThemeRoot(theme: theme))
    }

    /// The themed page background; nothing for the native look.
    func themedPageBackground() -> some View {
        modifier(PageBackground())
    }
}

struct ThemeRoot: ViewModifier {
    let theme: AppTheme

    func body(content: Content) -> some View {
        content
            .modifier(ThemeFontAndTint())
            .modifier(ForceLight(enabled: theme == .windowsXP))
            .environment(\.appTheme, theme)
            .background(WindowAppearance(forceLight: theme == .windowsXP))
    }
}

private struct ThemeFontAndTint: ViewModifier {
    @Environment(\.appTheme) private var theme
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        if theme == .native {
            content
        } else {
            let palette = ThemePalette(theme, scheme)
            content
                .font(palette.font())
                .tint(palette.accent)
        }
    }
}

/// XP has no dark mode: SwiftUI views resolve light at once, while
/// `WindowAppearance` turns the window's AppKit controls light.
private struct ForceLight: ViewModifier {
    let enabled: Bool

    func body(content: Content) -> some View {
        if enabled { content.environment(\.colorScheme, .light) } else { content }
    }
}

private struct PageBackground: ViewModifier {
    @Environment(\.appTheme) private var theme
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        if theme == .native {
            content
        } else {
            content.background(ThemePalette(theme, scheme).page)
        }
    }
}

/// Sets the hosting window's appearance: light for XP, the system's otherwise.
/// (`preferredColorScheme(nil)` does not reliably hand a window back to the
/// system appearance, so this sets `NSWindow.appearance` directly.)
private struct WindowAppearance: NSViewRepresentable {
    let forceLight: Bool

    func makeNSView(context: Context) -> AppearanceView { AppearanceView() }

    func updateNSView(_ view: AppearanceView, context: Context) {
        view.forceLight = forceLight
    }

    final class AppearanceView: NSView {
        var forceLight = false {
            didSet { if forceLight != oldValue { apply() } }
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            apply()
        }

        /// Whether this view set the window's appearance (and so must undo it).
        private var forced = false

        private func apply() {
            guard let window, forceLight || forced else { return }
            forced = forceLight
            let appearance = forceLight ? NSAppearance(named: .aqua) : nil
            // Not during SwiftUI's update pass: the change re-renders the window.
            DispatchQueue.main.async { window.appearance = appearance }
        }
    }
}

// MARK: - Header strip

/// The strip at the top of the main window: a dark portal-style top bar for
/// Azure, a glossy blue title bar for XP, nothing for the native look (the
/// native toolbar stays in every theme).
struct ThemeHeader: View {
    @Environment(AppModel.self) private var model
    @Environment(\.appTheme) private var theme
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        switch theme {
        case .native: EmptyView()
        case .azure: azure(ThemePalette(theme, scheme))
        case .windowsXP: xp(ThemePalette(theme, scheme))
        }
    }

    private var counts: String {
        "\(model.roles.count) eligible · \(model.activeCount) active"
    }

    private func azure(_ palette: ThemePalette) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 14, weight: .regular))
                    .accessibilityHidden(true)
                Text(AppInfo.name)
                    .font(palette.font(15, weight: .semibold))
                Rectangle().fill(.white.opacity(0.25)).frame(width: 1, height: 16)
                Text("Privileged access")
                    .font(palette.font(13))
                    .opacity(0.85)
                Spacer(minLength: 12)
                if let identity = model.identity {
                    VStack(alignment: .trailing, spacing: 0) {
                        Text(identity.displayName)
                            .font(palette.font(12))
                            .lineLimit(1)
                        Text(model.tenantLabel.uppercased())
                            .font(palette.font(10))
                            .opacity(0.75)
                            .lineLimit(1)
                    }
                    Image(systemName: "person.crop.circle")
                        .font(.system(size: 20, weight: .light))
                        .accessibilityHidden(true)
                }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .frame(height: 40)
            .background(palette.headerBackground)

            // Page title, as on a portal blade.
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("My roles")
                    .font(palette.font(20, weight: .semibold))
                    .foregroundStyle(palette.text)
                Text("Azure resources")
                    .font(palette.font(13))
                    .foregroundStyle(palette.secondaryText)
                Spacer()
                if model.identity != nil {
                    Text(counts)
                        .font(palette.font(12))
                        .foregroundStyle(palette.secondaryText)
                        .monospacedDigit()
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 14)
            .padding(.bottom, 10)
        }
        .accessibilityElement(children: .combine)
    }

    private func xp(_ palette: ThemePalette) -> some View {
        HStack(spacing: 7) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 18, height: 18)
                .shadow(color: .black.opacity(0.35), radius: 0.5, x: 1, y: 1)
                .accessibilityHidden(true)
            Text(model.identity == nil ? AppInfo.name : "\(AppInfo.name) - \(model.tenantLabel)")
                .font(palette.font(13, weight: .bold))
                .foregroundStyle(.white)
                .shadow(color: Color(hex: 0x0A1F6E).opacity(0.9), radius: 0, x: 1, y: 1)
                .lineLimit(1)
            Spacer(minLength: 12)
            if model.identity != nil {
                Text(counts)
                    .font(palette.font(11, weight: .bold))
                    .foregroundStyle(.white)
                    .shadow(color: Color(hex: 0x0A1F6E).opacity(0.8), radius: 0, x: 1, y: 1)
                    .monospacedDigit()
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 30)
        .background(XPTitleBarBackground())
        .accessibilityElement(children: .combine)
    }
}

/// The Luna title bar: a glossy blue band, lighter near the top, with a
/// highlight line along the top edge and a darker one at the bottom.
struct XPTitleBarBackground: View {
    var body: some View {
        LinearGradient(
            stops: [
                .init(color: Color(hex: 0x0A5FE8), location: 0),
                .init(color: Color(hex: 0x3A93FF), location: 0.12),
                .init(color: Color(hex: 0x2A7DF5), location: 0.3),
                .init(color: Color(hex: 0x0058EE), location: 0.55),
                .init(color: Color(hex: 0x0053E0), location: 0.85),
                .init(color: Color(hex: 0x0047D6), location: 1),
            ],
            startPoint: .top, endPoint: .bottom)
            .overlay(alignment: .top) {
                Rectangle().fill(Color.white.opacity(0.45)).frame(height: 1)
            }
            .overlay(alignment: .bottom) {
                Rectangle().fill(Color(hex: 0x00309C)).frame(height: 1)
            }
    }
}

// MARK: - Lists, bars, dividers

extension View {
    /// Frames the role table: an Azure card or an XP list box.
    func themedListArea() -> some View { modifier(ListArea()) }
    /// The bottom bar's background (the caller keeps `.background(.bar)` for native).
    func themedBar() -> some View { modifier(BarBackground()) }
    /// A checked-row highlight and text colour for one table cell.
    func themedCell(checked: Bool) -> some View { modifier(CellHighlight(checked: checked)) }
    /// A flat text field with a thin border (the caller keeps `.roundedBorder` for native).
    func themedTextField(focused: Bool = false) -> some View { modifier(TextFieldChrome(focused: focused)) }
    /// A themed form (Settings): page background behind the grouped sections.
    func themedForm() -> some View { modifier(FormChrome()) }
}

/// `Divider()` natively; a line in the theme's border colour otherwise.
struct ThemedDivider: View {
    @Environment(\.appTheme) private var theme
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        switch theme {
        case .native:
            Divider()
        case .azure:
            Rectangle().fill(ThemePalette(theme, scheme).border).frame(height: 1)
        case .windowsXP:
            // XP's etched separator: shadow line over a white one.
            VStack(spacing: 0) {
                Rectangle().fill(Color(hex: 0xACA899)).frame(height: 1)
                Rectangle().fill(Color.white).frame(height: 1)
            }
        }
    }
}

private struct ListArea: ViewModifier {
    @Environment(\.appTheme) private var theme
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        let palette = ThemePalette(theme, scheme)
        switch theme {
        case .native:
            content
        case .azure:
            content
                .scrollContentBackground(.hidden)
                .background(palette.surface)
                .clipShape(RoundedRectangle(cornerRadius: palette.cornerRadius))
                .overlay(RoundedRectangle(cornerRadius: palette.cornerRadius).strokeBorder(palette.border))
                .shadow(color: .black.opacity(palette.isDark ? 0 : 0.06), radius: 2, y: 1)
                .padding(.horizontal, 20)
                .padding(.top, 6)
                .padding(.bottom, 14)
        case .windowsXP:
            content
                .scrollContentBackground(.hidden)
                .background(palette.surface)
                .overlay(Rectangle().strokeBorder(palette.border))
                .padding(10)
        }
    }
}

private struct BarBackground: ViewModifier {
    @Environment(\.appTheme) private var theme
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        let palette = ThemePalette(theme, scheme)
        switch theme {
        case .native:
            content
        case .azure:
            content.background(palette.bar)
        case .windowsXP:
            content.background(
                LinearGradient(colors: [Color(hex: 0xF3F1E6), Color(hex: 0xE3DFCB)], startPoint: .top, endPoint: .bottom))
        }
    }
}

private struct CellHighlight: ViewModifier {
    @Environment(\.appTheme) private var theme
    @Environment(\.colorScheme) private var scheme
    let checked: Bool

    func body(content: Content) -> some View {
        if theme == .native {
            content
        } else {
            let palette = ThemePalette(theme, scheme)
            content
                .foregroundStyle(checked ? palette.selectionText : palette.text)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                // Covers the cell spacing so a checked row reads as one band.
                .background(
                    Rectangle()
                        .fill(checked ? palette.selection : .clear)
                        .padding(.horizontal, -12)
                        .padding(.vertical, -4))
        }
    }
}

private struct TextFieldChrome: ViewModifier {
    @Environment(\.appTheme) private var theme
    @Environment(\.colorScheme) private var scheme
    let focused: Bool

    func body(content: Content) -> some View {
        if theme == .native {
            content
        } else {
            let palette = ThemePalette(theme, scheme)
            content
                .textFieldStyle(.plain)
                .foregroundStyle(palette.text)
                .padding(.horizontal, 7)
                .padding(.vertical, 5)
                .background(palette.surface)
                .overlay {
                    RoundedRectangle(cornerRadius: theme == .azure ? 2 : 0)
                        .strokeBorder(focused && theme == .azure ? palette.accentFill : palette.fieldBorder,
                                      lineWidth: focused && theme == .azure ? 2 : 1)
                }
        }
    }
}

private struct FormChrome: ViewModifier {
    @Environment(\.appTheme) private var theme
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        if theme == .native {
            content
        } else {
            content
                .scrollContentBackground(.hidden)
                .background(ThemePalette(theme, scheme).page)
        }
    }
}

// MARK: - Buttons

enum ThemedButtonKind {
    /// The main action (Activate). `warning`: Owner roles are selected.
    case primary(warning: Bool = false)
    /// Default / outlined buttons.
    case secondary
}

extension View {
    /// Applies the theme's button style. Put it *before* the native
    /// `.buttonStyle(...)`: the innermost style wins, so the native one
    /// applies only to the native theme.
    func themedButton(_ kind: ThemedButtonKind) -> some View {
        modifier(ThemedButtonModifier(kind: kind))
    }
}

private struct ThemedButtonModifier: ViewModifier {
    @Environment(\.appTheme) private var theme
    let kind: ThemedButtonKind

    func body(content: Content) -> some View {
        switch theme {
        case .native: content
        case .azure: content.buttonStyle(AzureButtonStyle(kind: kind))
        case .windowsXP: content.buttonStyle(XPButtonStyle(kind: kind))
        }
    }
}

/// Hover state for button styles (`@State` needs full Xcode; `@StateObject` doesn't).
private final class HoverState: ObservableObject {
    @Published var hovering = false
}

struct AzureButtonStyle: ButtonStyle {
    let kind: ThemedButtonKind

    func makeBody(configuration: Configuration) -> some View {
        StyledButton(kind: kind, configuration: configuration)
    }

    private struct StyledButton: View {
        let kind: ThemedButtonKind
        let configuration: Configuration
        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.colorScheme) private var scheme
        @StateObject private var hover = HoverState()

        var body: some View {
            let palette = ThemePalette(.azure, scheme)
            let pressed = configuration.isPressed
            let hovering = hover.hovering && isEnabled
            configuration.label
                .font(palette.font(13, weight: .semibold))
                .lineLimit(1)
                .padding(.horizontal, 16)
                .frame(minHeight: 30)
                .foregroundStyle(foreground(palette))
                .background(background(palette, pressed: pressed, hovering: hovering))
                .overlay {
                    if case .secondary = kind {
                        RoundedRectangle(cornerRadius: 2)
                            .strokeBorder(isEnabled ? palette.fieldBorder : palette.border)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 2))
                .contentShape(Rectangle())
                .onHover { hover.hovering = $0 }
        }

        private func foreground(_ palette: ThemePalette) -> Color {
            switch kind {
            case .primary:
                isEnabled ? .white : palette.secondaryText.opacity(0.7)
            case .secondary:
                isEnabled ? palette.text : palette.secondaryText.opacity(0.7)
            }
        }

        private func background(_ palette: ThemePalette, pressed: Bool, hovering: Bool) -> Color {
            switch kind {
            case .primary(let warning):
                guard isEnabled else { return palette.neutralFill }
                if warning {
                    return Color(hex: pressed ? 0xA62D01 : hovering ? 0xC13501 : 0xD83B01)
                }
                return pressed ? palette.accentPressed : hovering ? palette.accentHover : palette.accentFill
            case .secondary:
                guard isEnabled else { return palette.surface }
                return pressed ? Color(hex: palette.isDark ? 0x484644 : 0xEDEBE9)
                    : hovering ? Color(hex: palette.isDark ? 0x3B3A39 : 0xF3F2F1) : palette.surface
            }
        }
    }
}

struct XPButtonStyle: ButtonStyle {
    let kind: ThemedButtonKind

    func makeBody(configuration: Configuration) -> some View {
        StyledButton(kind: kind, configuration: configuration)
    }

    private struct StyledButton: View {
        let kind: ThemedButtonKind
        let configuration: Configuration
        @Environment(\.isEnabled) private var isEnabled
        @StateObject private var hover = HoverState()

        var body: some View {
            switch kind {
            case .primary(let warning): go(warning: warning)
            case .secondary: standard
            }
        }

        private var palette: ThemePalette { ThemePalette(.windowsXP, .light) }

        /// Bold italic, like the XP start button. Tahoma has no italic face,
        /// so Verdana's is used when the Mac has it; else the system's.
        private static let goFont: Font = NSFont(name: "Verdana-BoldItalic", size: 13) != nil
            ? .custom("Verdana-BoldItalic", size: 13)
            : .system(size: 14, weight: .bold).italic()

        /// The rounded light button with a dark blue border and an orange hover glow.
        private var standard: some View {
            let pressed = configuration.isPressed
            let hovering = hover.hovering && isEnabled
            let shape = RoundedRectangle(cornerRadius: 3)
            return configuration.label
                .font(palette.font(12))
                .lineLimit(1)
                .foregroundStyle(isEnabled ? Color.black : Color(hex: 0xA19E8E))
                .padding(.horizontal, 12)
                .frame(minWidth: 75, minHeight: 23)
                .background(
                    LinearGradient(
                        colors: pressed
                            ? [Color(hex: 0xE3E2DA), Color(hex: 0xF2F1EC)]
                            : [Color.white, Color(hex: 0xF3F2EE), Color(hex: 0xECEBE6), Color(hex: 0xD6D0C5)],
                        startPoint: .top, endPoint: .bottom))
                .clipShape(shape)
                .overlay {
                    if hovering && !pressed {
                        // The hot-tracking glow: an orange band inside the border.
                        shape.inset(by: 1).strokeBorder(
                            LinearGradient(colors: [Color(hex: 0xFFF0CF), Color(hex: 0xF8B330), Color(hex: 0xE59700)],
                                           startPoint: .top, endPoint: .bottom),
                            lineWidth: 2)
                    }
                }
                .overlay(shape.strokeBorder(isEnabled ? Color(hex: 0x003C74) : Color(hex: 0xC9C7BA)))
                .contentShape(shape)
                .onHover { hover.hovering = $0 }
        }

        /// The green "go" button for Activate (orange when Owner roles are selected).
        private func go(warning: Bool) -> some View {
            let pressed = configuration.isPressed
            let hovering = hover.hovering && isEnabled
            let shape = RoundedRectangle(cornerRadius: 9)
            let colors: [Color] = if !isEnabled {
                [Color(hex: 0xB9C7B2), Color(hex: 0x9DAE96)]
            } else if warning {
                [Color(hex: 0xF7B55A), Color(hex: 0xE8892B), Color(hex: 0xD06F12), Color(hex: 0xE0832A)]
            } else if pressed {
                [Color(hex: 0x2A7A2A), Color(hex: 0x2E8B2E), Color(hex: 0x3C9E3C)]
            } else if hovering {
                [Color(hex: 0x7CC870), Color(hex: 0x4CB04C), Color(hex: 0x33963A), Color(hex: 0x3FA346)]
            } else {
                [Color(hex: 0x6BBE5F), Color(hex: 0x3C9E3C), Color(hex: 0x2E8B2E), Color(hex: 0x379837)]
            }
            return configuration.label
                .font(Self.goFont)
                .lineLimit(1)
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(isEnabled ? 0.55 : 0.2), radius: 0, x: 1, y: 1)
                .padding(.horizontal, 18)
                .frame(minHeight: 28)
                .background(LinearGradient(colors: colors, startPoint: .top, endPoint: .bottom))
                .overlay(alignment: .top) {
                    // Gloss on the upper half.
                    shape.fill(LinearGradient(colors: [.white.opacity(pressed ? 0.05 : 0.35), .white.opacity(0)],
                                              startPoint: .top, endPoint: .bottom))
                        .frame(height: 13)
                        .padding(.horizontal, 3)
                        .padding(.top, 1)
                }
                .clipShape(shape)
                .overlay(shape.strokeBorder(isEnabled ? Color(hex: warning ? 0x9A4C00 : 0x1E5E1E) : Color(hex: 0x8C9C86)))
                .shadow(color: .black.opacity(isEnabled ? 0.25 : 0), radius: 1, x: 1, y: 1)
                .contentShape(shape)
                .onHover { hover.hovering = $0 }
        }
    }
}

// MARK: - Status badges

/// A portal-style badge: tinted fill, coloured text, optional icon.
struct ThemeBadge: View {
    let text: String
    let symbol: String?
    let foreground: Color
    let fill: Color
    let font: Font

    var body: some View {
        HStack(spacing: 4) {
            if let symbol {
                Image(systemName: symbol).imageScale(.small).accessibilityHidden(true)
            }
            Text(text).lineLimit(1).truncationMode(.tail)
        }
        .font(font)
        .foregroundStyle(foreground)
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .background(fill, in: RoundedRectangle(cornerRadius: 2))
    }
}
