import AppKit
import Observation
import PimentoCore
import SwiftUI

// The menu bar extra (Settings › General › Menu bar): an icon with the number
// of active roles (and optionally the soonest end), and a popover with the
// active roles' countdowns, Renew / End Now, presets, and links into the app.
// The views get `AppModel` as a value, like table cells: the extra's window
// is not one of the app's windows and updates on its own schedule.

// MARK: - Icon

/// The template glyph (pepper shield with a keyhole) from `scripts/make-icon.swift`,
/// bundled as MenuBarIcon.png; a system symbol when run unbundled.
@MainActor
enum MenuBarIcon {
    static let image: NSImage = {
        let image = Bundle.main.image(forResource: "MenuBarIcon")
            ?? NSImage(systemSymbolName: "checkmark.shield", accessibilityDescription: nil)
            ?? NSImage(size: NSSize(width: 18, height: 18))
        image.isTemplate = true
        image.accessibilityDescription = AppInfo.name
        return image
    }()
}

// MARK: - Clock

/// The one timer behind every countdown of the menu bar extra. It fires only
/// when something visible changes (`MenuBarStatus.nextTick`): each second
/// while the popover is open, otherwise at most about once a minute, and not
/// at all without active roles. Re-planned whenever the roles or settings change.
@MainActor
@Observable
final class MenuBarClock {
    static let shared = MenuBarClock(model: .shared)

    /// What the countdowns are computed against.
    private(set) var now = AppClock.now()
    /// The popover is on screen: the countdown shows seconds.
    var popoverOpen = false

    @ObservationIgnored private let model: AppModel
    @ObservationIgnored private var timer: Timer?

    init(model: AppModel) {
        self.model = model
        plan()
    }

    /// Re-reads the time and plans the next tick.
    func tick() {
        now = AppClock.now()
        plan()
    }

    private func plan() {
        timer?.invalidate()
        timer = nil
        // Re-plan when anything read here changes: the roles (refresh,
        // activation), the settings, the popover opening or closing.
        let (next, open) = withObservationTracking {
            let date = AppClock.now()
            let prefs = model.prefs
            let open = popoverOpen
            guard prefs.showInMenuBar else { return (nil as Date?, open) }
            let ends = model.menuBarEntries(now: date).compactMap(\.until)
            return (MenuBarStatus.nextTick(after: date, ends: ends, showsRemainingTime: prefs.menuBarShowsRemainingTime,
                                           popoverOpen: open), open)
        } onChange: { [weak self] in
            Task { @MainActor in self?.tick() }
        }
        // In demo mode the clock may run faster or stand still.
        guard let next, let fire = AppClock.realDate(for: next) else { return }
        let timer = Timer(fire: max(fire, Date(timeIntervalSinceNow: AppClock.isDemo ? 0.25 : 0)), interval: 0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer.tolerance = open ? 0.05 : 0.5
        // `.common`: also while a menu is tracking.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }
}

// MARK: - Label

/// The menu bar item: the glyph, plus `2` or `2 · 1:24` while roles are active.
struct MenuBarLabel: View {
    let model: AppModel
    let clock: MenuBarClock

    var body: some View {
        let entries = model.menuBarEntries(now: clock.now)
        let text = MenuBarStatus.badgeText(entries, now: clock.now, showsRemainingTime: model.prefs.menuBarShowsRemainingTime)
        HStack(spacing: 3) {
            Image(nsImage: MenuBarIcon.image)
            if let text {
                Text(text).monospacedDigit()
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(MenuBarStatus.accessibilityText(entries, now: clock.now))
    }
}

// MARK: - Popover

/// The popover: the root of the menu bar extra's window.
struct MenuBarContent: View {
    let model: AppModel
    let clock: MenuBarClock
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        MenuBarPanel(model: model, clock: clock, actions: actions)
            .appTheme(model.prefs.theme, ultra: model.appearance == .ultraDark)
            .background(WindowVisibility { open in
                guard clock.popoverOpen != open else { return }
                clock.popoverOpen = open
                // A confirmation left open would act on stale targets next time.
                if open { model.menuBarOpened() } else { model.menuBarPrompt = nil }
            })
    }

    private var actions: MenuBarActions {
        MenuBarActions(
            openApp: { showApp() },
            openScheduled: { showApp { model.openScheduled() } },
            openApprovals: { showApp { model.openApprovals() } },
            openSettings: {
                NSApp.activate(ignoringOtherApps: true)
                openSettings()
            })
    }

    /// Brings up the main window (opening it again if it was closed), then `then`.
    private func showApp(then: (() -> Void)? = nil) {
        model.menuBarPrompt = nil
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
        then?()
    }
}

/// What the popover's links do; the window and Settings scenes are opened by
/// `MenuBarContent`, which has their environment actions.
struct MenuBarActions {
    var openApp: () -> Void = {}
    var openScheduled: () -> Void = {}
    var openApprovals: () -> Void = {}
    var openSettings: () -> Void = {}
}

/// The popover's content, in the theme chosen in Settings.
struct MenuBarPanel: View {
    let model: AppModel
    let clock: MenuBarClock
    var actions = MenuBarActions()
    @Environment(\.appTheme) private var theme
    @Environment(\.colorScheme) private var scheme
    @Environment(\.ultraDark) private var ultra

    static let width: CGFloat = 340
    /// Rows shown per section; the rest are in the main window.
    static let rowLimit = 8

    var body: some View {
        let palette = ThemePalette(theme, scheme, ultra: ultra)
        let colors = MenuBarColors(theme: theme, palette: palette)
        VStack(alignment: .leading, spacing: 0) {
            MenuBarHeader(model: model, colors: colors)
            if model.updates.notice != nil {
                MenuBarUpdateNotice(updates: model.updates, colors: colors)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
            }
            if let banner = model.banner {
                MenuBarBanner(banner: banner, colors: colors) { model.banner = nil }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
            }
            divider(colors)
            if model.menuBarPrompt != nil {
                MenuBarPromptView(model: model, colors: colors)
            } else {
                MenuBarActiveSection(model: model, clock: clock, colors: colors, openApp: actions.openApp)
                divider(colors)
                MenuBarPresetSection(model: model, colors: colors, openApp: actions.openApp)
                divider(colors)
                MenuBarLinks(model: model, colors: colors, actions: actions)
                if !model.keptRoles.isEmpty || model.prefs.keepAlivePaused {
                    divider(colors)
                    MenuBarKeepAliveRow(model: model, colors: colors)
                }
            }
            divider(colors)
            MenuBarFooter(model: model, colors: colors, actions: actions)
        }
        .frame(width: Self.width)
        .background(colors.background)
    }

    private func divider(_ colors: MenuBarColors) -> some View {
        Rectangle().fill(colors.divider).frame(height: 1)
    }
}

/// The popover's colours: the system's for the native look (on the panel's
/// own material), the palette's otherwise and in ultra dark.
struct MenuBarColors {
    let theme: AppTheme
    let palette: ThemePalette

    private var native: Bool { theme == .native && !palette.isUltra }

    var background: Color { native ? .clear : palette.page }
    var surface: Color { native ? Color(nsColor: .quaternaryLabelColor).opacity(0.5) : palette.surface }
    var text: Color { native ? .primary : palette.text }
    var secondary: Color { native ? .secondary : palette.secondaryText }
    var warning: Color { native ? .orange : palette.warning }
    var danger: Color { native ? .red : palette.danger }
    var accent: Color { native ? .accentColor : palette.accent }
    var divider: Color { native ? Color(nsColor: .separatorColor) : palette.border }
    var headerBackground: Color? {
        switch theme {
        case .native: palette.isUltra ? .black : nil
        case .azure: palette.headerBackground
        case .windowsXP: nil
        }
    }
    var headerText: Color { theme == .native ? text : .white }
}

private struct MenuBarHeader: View {
    let model: AppModel
    let colors: MenuBarColors

    var body: some View {
        HStack(spacing: 8) {
            Image(nsImage: MenuBarIcon.image)
                .renderingMode(.template)
                .foregroundStyle(colors.headerText)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(AppInfo.name).font(.headline).foregroundStyle(colors.headerText)
                    DemoBadge(compact: true)
                }
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(colors.headerText.opacity(0.8))
                    .lineLimit(2)
            }
            Spacer(minLength: 4)
            if model.loadState == .loading || model.isActivating {
                ProgressView().controlSize(.small)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background {
            if colors.theme == .windowsXP {
                XPTitleBar.gradient
            } else if let fill = colors.headerBackground {
                fill
            }
        }
    }

    private var subtitle: String {
        if let tenantError = model.tenantError { return tenantError }
        switch model.loadState {
        case .failed(let message, let needsLogin):
            return needsLogin ? model.signedOutHint : message
        case .idle where model.awaitingManualRefresh:
            return "\(model.tenantLabel) · not loaded yet"
        default:
            let n = model.menuBarEntries(now: AppClock.now()).count
            return "\(model.tenantLabel) · \(n == 0 ? "no active roles" : n == 1 ? "1 active role" : "\(n) active roles")"
        }
    }
}

private struct MenuBarBanner: View {
    let banner: AppModel.Banner
    let colors: MenuBarColors
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: icon).foregroundStyle(tint)
            Text(banner.text)
                .font(.caption)
                .foregroundStyle(colors.text)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button(action: dismiss) { Image(systemName: "xmark").font(.caption2) }
                .buttonStyle(.borderless)
                .help("Dismiss")
                .accessibilityLabel("Dismiss message")
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6).fill(colors.surface))
    }

    private var icon: String {
        switch banner.kind {
        case .info: "info.circle"
        case .success: "checkmark.circle"
        case .error: "exclamationmark.triangle"
        }
    }

    private var tint: Color {
        switch banner.kind {
        case .info: colors.accent
        case .success: colors.theme == .native ? .green : colors.palette.success
        case .error: colors.danger
        }
    }
}

private struct SectionTitle: View {
    let title: String
    let colors: MenuBarColors

    var body: some View {
        Text(title.uppercased())
            .font(.caption2.weight(.semibold))
            .foregroundStyle(colors.secondary)
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 2)
    }
}

// MARK: Active roles

private struct MenuBarActiveSection: View {
    let model: AppModel
    let clock: MenuBarClock
    let colors: MenuBarColors
    let openApp: () -> Void

    var body: some View {
        let entries = model.menuBarEntries(now: clock.now)
        VStack(alignment: .leading, spacing: 0) {
            SectionTitle(title: "Active roles", colors: colors)
            if entries.isEmpty {
                Text(model.roles.isEmpty ? "Roles not loaded yet." : "No active roles.")
                    .font(.callout)
                    .foregroundStyle(colors.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
            } else {
                ForEach(entries.prefix(MenuBarPanel.rowLimit)) { entry in
                    MenuBarRoleRow(model: model, entry: entry, now: clock.now, seconds: clock.popoverOpen, colors: colors)
                }
                if entries.count > MenuBarPanel.rowLimit {
                    Button("\(entries.count - MenuBarPanel.rowLimit) more in \(AppInfo.name)…", action: openApp)
                        .buttonStyle(.borderless)
                        .font(.caption)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 4)
                }
            }
        }
        .padding(.bottom, 6)
    }
}

private struct MenuBarRoleRow: View {
    let model: AppModel
    let entry: MenuBarStatus.Entry
    let now: Date
    let seconds: Bool
    let colors: MenuBarColors

    var body: some View {
        let role = entry.role
        let remaining = entry.remaining(at: now)
        let warning = MenuBarStatus.isWarning(remaining: remaining, lead: model.prefs.reminderLead)
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(role.roleName).fontWeight(.medium).foregroundStyle(colors.text)
                    if role.isOwner {
                        Image(systemName: "exclamationmark.shield.fill")
                            .font(.caption)
                            .foregroundStyle(colors.warning)
                            .help("Owner role")
                            .accessibilityLabel("Owner")
                    }
                    if model.keepAliveRule(for: role) != nil {
                        Image(systemName: model.prefs.keepAlivePaused ? "pause.circle" : "arrow.triangle.2.circlepath")
                            .font(.caption)
                            .foregroundStyle(model.keepAliveStatus(for: role)?.needsAttention == true ? colors.warning : colors.secondary)
                            .help(model.keepAliveText(for: role))
                            .accessibilityLabel(model.keepAliveText(for: role))
                    }
                }
                .lineLimit(1)
                Text(role.scopeName)
                    .font(.caption)
                    .foregroundStyle(colors.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 4)
            if case .running(let text)? = model.progress[role.id] {
                ProgressView().controlSize(.mini)
                Text(text).font(.caption).foregroundStyle(colors.secondary)
            } else {
                Text(remaining.map { MenuBarStatus.countdownText(remaining: $0, seconds: seconds) } ?? "no end")
                    .font(.system(.body, design: .rounded).monospacedDigit())
                    .fontWeight(warning ? .semibold : .regular)
                    .foregroundStyle(warning ? colors.warning : colors.text)
                    .help(remaining.map { "Ends in \(MenuBarStatus.spokenText(remaining: $0))" + (entry.until.map { ", at \($0.formatted(date: .omitted, time: .shortened))" } ?? "") } ?? "No end time")
                    .accessibilityLabel(remaining.map { "ends in \(MenuBarStatus.spokenText(remaining: $0))" } ?? "no end time")
                Button { model.menuBarAsk(.renew, for: role) } label: {
                    Image(systemName: "arrow.clockwise.circle")
                }
                .help("Renew: end and activate again for a fresh duration (asks first)")
                .accessibilityLabel("Renew \(role.roleName) on \(role.scopeName)")
                Button { model.menuBarAsk(.end, for: role) } label: {
                    Image(systemName: "stop.circle")
                }
                .help("End now (asks first)")
                .accessibilityLabel("End \(role.roleName) on \(role.scopeName) now")
            }
        }
        .buttonStyle(.borderless)
        .disabled(model.isActivating || model.identity == nil)
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
    }
}

// MARK: Presets

private struct MenuBarPresetSection: View {
    let model: AppModel
    let colors: MenuBarColors
    let openApp: () -> Void

    var body: some View {
        let presets = model.visiblePresets
        VStack(alignment: .leading, spacing: 0) {
            SectionTitle(title: "Presets", colors: colors)
            if presets.isEmpty {
                Text(model.presetFileError == nil ? "No presets for this tenant. Save one in \(AppInfo.name)." : "The presets file cannot be read.")
                    .font(.callout)
                    .foregroundStyle(colors.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
            } else {
                ForEach(presets.prefix(MenuBarPanel.rowLimit)) { preset in
                    MenuBarPresetRow(model: model, preset: preset, colors: colors)
                }
                if presets.count > MenuBarPanel.rowLimit {
                    Button("\(presets.count - MenuBarPanel.rowLimit) more in \(AppInfo.name)…", action: openApp)
                        .buttonStyle(.borderless)
                        .font(.caption)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 4)
                }
            }
        }
        .padding(.bottom, 6)
    }
}

private struct MenuBarPresetRow: View {
    let model: AppModel
    let preset: Preset
    let colors: MenuBarColors

    var body: some View {
        let resolution = model.roles.isEmpty ? nil : preset.resolve(in: model.roles)
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(preset.name).fontWeight(.medium).foregroundStyle(colors.text).lineLimit(1)
                Text(detail(resolution))
                    .font(.caption)
                    .foregroundStyle(colors.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            Button("Activate") { model.menuBarActivatePreset(preset) }
                .themedButton(.secondary)
                .controlSize(.small)
                .disabled(resolution == nil || resolution?.eligible.isEmpty == true || model.isActivating || model.identity == nil)
                .help(preset.trimmedJustification == nil
                    ? "Activate its roles now; asks for a justification"
                    : "Activate its roles now with the preset's justification")
                .accessibilityLabel("Activate preset \(preset.name)")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
    }

    private func detail(_ resolution: PresetResolution?) -> String {
        var parts: [String] = []
        if let resolution {
            let eligible = resolution.eligible.count, active = resolution.active.count
            if eligible == 0 && active > 0 { parts.append("all active") }
            else if eligible == 0 { parts.append("no eligible roles") }
            else { parts.append("\(eligible) to activate" + (active > 0 ? ", \(active) active" : "")) }
        } else {
            parts.append(preset.summary)
        }
        if let d = preset.duration { parts.append(d.label) }
        if preset.trimmedJustification == nil { parts.append("asks for a justification") }
        return parts.joined(separator: " · ")
    }
}

// MARK: Prompt

/// The inline confirmation: the main window's alert texts, with Cancel and
/// the same action, plus the justification field where one is needed.
private struct MenuBarPromptView: View {
    let model: AppModel
    let colors: MenuBarColors

    var body: some View {
        @Bindable var model = model
        if let prompt = model.menuBarPrompt {
            VStack(alignment: .leading, spacing: 10) {
                Text(title(prompt)).font(.headline).foregroundStyle(colors.text)
                ScrollView {
                    Text(message(prompt))
                        .font(.callout)
                        .foregroundStyle(colors.text)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxHeight: 230)
                if showsJustification(prompt) {
                    TextField("Justification", text: $model.justification, prompt: Text("Why you need the access"))
                        .textFieldStyle(.roundedBorder)
                        .themedTextField()
                        .onSubmit { if model.menuBarCanConfirm { model.menuBarConfirm() } }
                        .accessibilityLabel("Justification")
                }
                HStack {
                    Spacer()
                    Button("Cancel") { model.menuBarPrompt = nil }
                        .themedButton(.secondary)
                        .keyboardShortcut(.cancelAction)
                    Button(confirmTitle(prompt), role: isDestructive(prompt) ? .destructive : nil) { model.menuBarConfirm() }
                        .themedButton(.primary(warning: isDestructive(prompt)))
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                        .disabled(!model.menuBarCanConfirm)
                }
            }
            .padding(12)
        }
    }

    private func title(_ prompt: MenuBarPrompt) -> String {
        switch prompt {
        case .end: model.deactivateConfirmationTitle
        case .renew: model.renewConfirmationTitle
        case .owner: model.ownerConfirmationTitle
        case .presetJustification(let preset): "Justification for “\(preset.name)”"
        }
    }

    private func message(_ prompt: MenuBarPrompt) -> String {
        switch prompt {
        case .end: return model.deactivateConfirmationMessage
        case .renew: return model.renewConfirmationMessage
        case .owner: return model.ownerConfirmationMessage
        case .presetJustification:
            let roles = model.checkedRoles
            let lines = roles.prefix(6).map { "• \($0.roleName) · \($0.scopeName)" }.joined(separator: "\n")
            return "The preset has no justification. \(roles.count) role\(roles.count == 1 ? "" : "s") to activate for \(model.durationSummary):\n\n"
                + lines + (roles.count > 6 ? "\n… and \(roles.count - 6) more" : "")
        }
    }

    private func showsJustification(_ prompt: MenuBarPrompt) -> Bool {
        switch prompt {
        case .renew, .presetJustification: true
        case .end, .owner: false
        }
    }

    private func confirmTitle(_ prompt: MenuBarPrompt) -> String {
        switch prompt {
        case .end: "End Now"
        case .renew: "Renew"
        case .owner: model.activateTitle
        case .presetJustification: model.prefs.confirmOwnerRoles && !model.checkedOwnerRoles.isEmpty ? "Continue" : model.activateTitle
        }
    }

    private func isDestructive(_ prompt: MenuBarPrompt) -> Bool {
        switch prompt {
        case .end, .renew, .owner: true
        case .presetJustification: false
        }
    }
}

// MARK: Links and footer

private struct MenuBarLinks: View {
    let model: AppModel
    let colors: MenuBarColors
    let actions: MenuBarActions

    var body: some View {
        HStack(spacing: 14) {
            Button(action: actions.openScheduled) {
                Label(model.scheduledCount > 0 ? "Scheduled (\(model.scheduledCount))" : "Scheduled", systemImage: "calendar.badge.clock")
            }
            .help("Your scheduled activations and requests waiting for approval")
            Button(action: actions.openApprovals) {
                Label(model.approvalCount > 0 ? "Approvals (\(model.approvalCount))" : "Approvals", systemImage: "checkmark.seal")
            }
            .help("Requests you can approve or deny")
            .accessibilityLabel(model.approvalCount > 0 ? "Approvals, \(model.approvalCount) waiting" : "Approvals")
            Spacer(minLength: 0)
            if model.awaitingApprovalCount > 0 {
                Text("\(model.awaitingApprovalCount) awaiting approval")
                    .font(.caption)
                    .foregroundStyle(colors.secondary)
            }
        }
        .buttonStyle(.borderless)
        .font(.callout)
        .disabled(model.identity == nil)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

private struct MenuBarFooter: View {
    let model: AppModel
    let colors: MenuBarColors
    let actions: MenuBarActions

    var body: some View {
        HStack(spacing: 14) {
            Button("Open \(AppInfo.name)", action: actions.openApp)
                .keyboardShortcut("o")
            Button("Refresh") { Task { await model.refresh() } }
                .keyboardShortcut("r")
                .disabled(model.loadState == .loading || model.isActivating || model.tenantError != nil)
            Spacer(minLength: 0)
            Button("Settings…", action: actions.openSettings)
                .keyboardShortcut(",")
            Button("Quit") { NSApp.terminate(nil) }
                .keyboardShortcut("q")
        }
        .buttonStyle(.borderless)
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

// MARK: - Visibility

/// Reports whether the hosting window is on screen. The menu bar extra's
/// window is hidden rather than closed, and `onAppear` alone is not called
/// each time it opens, so this follows the window's own notifications.
private struct WindowVisibility: NSViewRepresentable {
    let onChange: (Bool) -> Void

    func makeNSView(context: Context) -> Probe {
        let probe = Probe()
        probe.onChange = onChange
        return probe
    }

    func updateNSView(_ probe: Probe, context: Context) { probe.onChange = onChange }

    final class Probe: NSView {
        var onChange: ((Bool) -> Void)?
        private var observers: [NSObjectProtocol] = []

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            guard let window else {
                onChange?(false)
                return
            }
            let names = [NSWindow.didChangeOcclusionStateNotification, NSWindow.didBecomeKeyNotification,
                         NSWindow.didResignKeyNotification, NSWindow.willCloseNotification]
            observers = names.map { name in
                NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] note in
                    MainActor.assumeIsolated { self?.report(closing: note.name == NSWindow.willCloseNotification) }
                }
            }
            report(closing: false)
        }

        private func report(closing: Bool) {
            guard let window else { return }
            onChange?(!closing && window.isVisible && window.occlusionState.contains(.visible))
        }

        deinit {
            observers.forEach(NotificationCenter.default.removeObserver)
        }
    }
}
