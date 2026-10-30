import PimentoCore
import SwiftUI

/// Settings › Appearance: the theme as cards with a small preview, the mode
/// as a segmented control (with the time-of-day schedule in one row), and
/// the role table's optional columns.
struct AppearanceSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        SettingsPaneContainer {
            SettingsGroup("Theme") {
                HStack(spacing: 12) {
                    ForEach(AppTheme.allCases, id: \.self) { theme in
                        ThemeCard(theme: theme, selected: model.prefs.theme == theme) { model.prefs.theme = theme }
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Theme")
                SettingsNote("Azure-style and Windows XP-style are inspired by those designs; Pimento is not affiliated with Microsoft.")
            }

            SettingsGroup("Mode") {
                SettingsRow {
                    Picker("Mode", selection: appearanceMode) {
                        ForEach(AppearanceMode.allCases, id: \.self) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .fixedSize()
                    .disabled(!model.prefs.theme.supportsDarkMode)
                    .help("Light, dark, ultra dark (pure black), by time of day, or follow the system's appearance")
                    if let note = SettingsText.lightOnlyNote(theme: model.prefs.theme, mode: model.prefs.appearanceMode) {
                        SettingsNote(note)
                    }
                }
                if model.prefs.effectiveAppearance == .timeOfDay {
                    SettingsRow { TimeOfDayFields() }
                }
            }

            SettingsGroup("Table columns") {
                SettingsRow {
                    HStack(spacing: 18) {
                        ForEach(AppModel.Column.allCases, id: \.self) { column in
                            Toggle(column.title, isOn: Binding(
                                get: { model.isColumnVisible(column) },
                                set: { model.setColumn(column, visible: $0) }))
                        }
                        InfoButton("You can also right-click a column header.", label: "About table columns")
                    }
                }
            }
        }
    }

    /// Shows Light while a light-only theme is selected; the stored choice
    /// applies again after switching back.
    private var appearanceMode: Binding<AppearanceMode> {
        Binding(
            get: { model.prefs.effectiveAppearance },
            set: { model.prefs.appearanceMode = $0 })
    }
}

/// A theme to pick: a small preview window in that theme, its name and one line.
private struct ThemeCard: View {
    @Environment(\.appTheme) private var current
    @Environment(\.colorScheme) private var scheme
    @Environment(\.ultraDark) private var ultra
    let theme: AppTheme
    let selected: Bool
    let action: () -> Void

    var body: some View {
        let palette = ThemePalette(current, scheme, ultra: ultra)
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                ThemePreview(theme: theme, dark: scheme == .dark && theme.supportsDarkMode, ultra: ultra && theme.supportsDarkMode)
                    .frame(height: 92)
                HStack(spacing: 6) {
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(selected ? palette.theme == .native ? Color.accentColor : palette.accent : Color.secondary)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(theme.title).fontWeight(.medium)
                        SettingsNote(theme.summary)
                    }
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(selected ? accent(palette).opacity(0.08) : .clear))
            .overlay(RoundedRectangle(cornerRadius: 8)
                .strokeBorder(selected ? accent(palette) : Color.primary.opacity(0.12), lineWidth: selected ? 2 : 1))
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .help(theme.details)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(theme.title)
        .accessibilityHint(theme.details)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    private func accent(_ palette: ThemePalette) -> Color {
        palette.theme == .native ? Color.accentColor : palette.accent
    }
}

/// A miniature main window in `theme`: title bar, a list with a checked row,
/// and the Activate button. Drawn with shapes, no screenshots.
private struct ThemePreview: View {
    let theme: AppTheme
    let dark: Bool
    let ultra: Bool

    var body: some View {
        let palette = ThemePalette(theme, dark ? .dark : .light, ultra: ultra)
        VStack(spacing: 0) {
            titleBar(palette)
            VStack(alignment: .leading, spacing: 5) {
                VStack(spacing: 0) {
                    row(palette, checked: false, width: 0.7)
                    row(palette, checked: true, width: 0.55)
                    row(palette, checked: false, width: 0.8)
                }
                .background(listBackground(palette))
                .overlay(Rectangle().strokeBorder(theme == .native ? Color.clear : palette.border))
                HStack {
                    Capsule().fill(secondaryText(palette).opacity(0.35)).frame(width: 44, height: 4)
                    Spacer()
                    button(palette)
                }
            }
            .padding(7)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(page(palette))
        }
        .clipShape(RoundedRectangle(cornerRadius: theme == .windowsXP ? 5 : 6))
        .overlay(RoundedRectangle(cornerRadius: theme == .windowsXP ? 5 : 6).strokeBorder(Color.black.opacity(0.15)))
        .accessibilityHidden(true)
    }

    @ViewBuilder private func titleBar(_ palette: ThemePalette) -> some View {
        let lights = HStack(spacing: 3) {
            Circle().fill(Color(hex: 0xFF5F57))
            Circle().fill(Color(hex: 0xFEBC2E))
            Circle().fill(Color(hex: 0x28C840))
        }
        .frame(height: 6)
        switch theme {
        case .native:
            HStack { lights; Spacer() }
                .padding(.horizontal, 6)
                .frame(height: 16)
                .background(ultra ? Color.black : Color(hex: dark ? 0x2C2C2E : 0xE9E9E9))
        case .azure:
            HStack(spacing: 5) {
                lights
                Capsule().fill(Color.white.opacity(0.55)).frame(width: 30, height: 3)
                Spacer()
            }
            .padding(.horizontal, 6)
            .frame(height: 16)
            .background(palette.headerBackground)
        case .windowsXP:
            HStack {
                Capsule().fill(Color.white.opacity(0.85)).frame(width: 34, height: 3)
                Spacer()
                RoundedRectangle(cornerRadius: 2).fill(Color(hex: 0xE2563B))
                    .overlay(RoundedRectangle(cornerRadius: 2).strokeBorder(Color.white.opacity(0.8), lineWidth: 0.5))
                    .frame(width: 9, height: 9)
            }
            .padding(.horizontal, 6)
            .frame(height: 16)
            .background(XPTitleBar.gradient)
        }
    }

    private func row(_ palette: ThemePalette, checked: Bool, width: CGFloat) -> some View {
        let fill: Color = switch theme {
        case .native: checked ? Color(hex: 0x0A84FF).opacity(dark ? 0.45 : 0.2) : .clear
        default: checked ? palette.selection : .clear
        }
        let bar: Color = checked && theme == .windowsXP ? .white.opacity(0.9) : secondaryText(palette).opacity(0.45)
        return GeometryReader { geo in
            HStack(spacing: 4) {
                RoundedRectangle(cornerRadius: 1)
                    .strokeBorder(bar, lineWidth: 0.8)
                    .frame(width: 5, height: 5)
                Capsule().fill(bar).frame(width: (geo.size.width - 20) * width, height: 3)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 4)
            .frame(maxHeight: .infinity)
        }
        .frame(height: 11)
        .background(fill)
    }

    @ViewBuilder private func button(_ palette: ThemePalette) -> some View {
        switch theme {
        case .native:
            Capsule().fill(Color(hex: 0x0A84FF)).frame(width: 30, height: 10)
        case .azure:
            Rectangle().fill(palette.accentFill).frame(width: 30, height: 10)
        case .windowsXP:
            RoundedRectangle(cornerRadius: 4)
                .fill(LinearGradient(colors: [Color(hex: 0x6BBE5F), Color(hex: 0x2E8B2E)], startPoint: .top, endPoint: .bottom))
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color(hex: 0x1E5E1E), lineWidth: 0.5))
                .frame(width: 30, height: 11)
        }
    }

    private func page(_ palette: ThemePalette) -> Color {
        guard theme == .native else { return palette.page }
        return ultra ? .black : Color(hex: dark ? 0x1E1E1E : 0xF5F5F5)
    }

    private func listBackground(_ palette: ThemePalette) -> Color {
        guard theme == .native else { return palette.listBackground }
        return ultra ? .black : Color(hex: dark ? 0x262626 : 0xFFFFFF)
    }

    private func secondaryText(_ palette: ThemePalette) -> Color {
        guard theme == .native else { return palette.secondaryText }
        return dark ? Color(hex: 0xA0A0A0) : Color(hex: 0x6E6E73)
    }
}

/// Settings › Appearance › By time of day, in one row: when light, dark and
/// ultra dark start, then what applies now. The rules are on `AppearanceSchedule`.
private struct TimeOfDayFields: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 14) {
            timePicker("Light from", \.lightFrom)
            timePicker("Dark from", \.darkFrom)
            HStack(spacing: 4) {
                Toggle("Ultra dark from", isOn: Binding(
                    get: { model.prefs.appearanceSchedule.ultraDarkEnabled },
                    set: { model.prefs.appearanceSchedule.ultraDarkEnabled = $0 }))
                DatePicker("Ultra dark from", selection: time(\.ultraDarkFrom), displayedComponents: .hourAndMinute)
                    .labelsHidden()
                    .disabled(!model.prefs.appearanceSchedule.ultraDarkEnabled)
            }
        }
        .fixedSize()
        VStack(alignment: .leading, spacing: 2) {
            SettingsNote(nowText)
            if let note {
                SettingsNote(note)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func timePicker(_ title: String, _ keyPath: WritableKeyPath<AppearanceSchedule, ClockTime>) -> some View {
        DatePicker(title, selection: time(keyPath), displayedComponents: .hourAndMinute)
    }

    /// A clock time as today's date at that time, for `DatePicker`.
    private func time(_ keyPath: WritableKeyPath<AppearanceSchedule, ClockTime>) -> Binding<Date> {
        Binding(
            get: {
                let t = model.prefs.appearanceSchedule[keyPath: keyPath]
                return Calendar.current.date(bySettingHour: t.hour, minute: t.minute, second: 0, of: Date()) ?? Date()
            },
            set: { date in
                let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
                model.prefs.appearanceSchedule[keyPath: keyPath] = ClockTime(hour: parts.hour ?? 0, minute: parts.minute ?? 0)
            })
    }

    /// Two-digit hours like the time fields: `07:00` (or `07:00 AM`).
    private static let timeStyle = Date.FormatStyle().hour(.twoDigits(amPM: .abbreviated)).minute(.twoDigits)

    private static func label(_ time: ClockTime) -> String {
        let date = Calendar.current.date(bySettingHour: time.hour, minute: time.minute, second: 0, of: Date()) ?? Date()
        return date.formatted(timeStyle)
    }

    /// "Now: Dark until 23:00". Reads `model.appearance`, which changes at
    /// each boundary, so the text follows the clock.
    private var nowText: String {
        _ = model.appearance
        let status = model.prefs.appearanceSchedule.status(at: AppClock.now(), calendar: .autoupdatingCurrent)
        guard let until = status.until else { return "Now: \(status.mode.title), all day" }
        return "Now: \(status.mode.title) until \(until.formatted(Self.timeStyle))"
    }

    private var note: String? {
        let schedule = model.prefs.appearanceSchedule
        switch schedule.adjustment {
        case .noLightPeriod?:
            return "Light and Dark start at the same time, so it is dark all day."
        case .ultraDarkStartsWithDark?:
            return "Ultra dark cannot start while it is light, so it starts with Dark at \(Self.label(schedule.darkFrom))."
        case nil:
            return nil
        }
    }
}
