import AppKit
import Foundation
import Observation
import PimentoCore
import SwiftUI
@preconcurrency import UserNotifications

// Demo mode in the app: `--demo`, `PIMENTO_DEMO=1`, or Pimento › Demo Mode
// (which restarts the app). Everything Azure-facing runs on the demo
// simulator, settings live in their own defaults suite, presets, history and
// sign-in settings in `…/Pimento/Demo`, tokens in memory. Nothing is sent
// anywhere; leaving demo mode restarts Pimento with the user's own setup.

/// The time the app reads: the real time, or the demo clock's.
enum AppClock {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var demoClock: DemoClock?

    /// Set once at launch, in demo mode.
    static func use(_ clock: DemoClock?) { lock.withLock { demoClock = clock } }

    static var demo: DemoClock? { lock.withLock { demoClock } }
    static var isDemo: Bool { demo != nil }

    static func now() -> Date { demo?.now() ?? Date() }

    /// Real seconds until the app clock shows `date` (at least 1); nil when
    /// the demo clock stands still and never gets there.
    static func realInterval(until date: Date) -> TimeInterval? {
        guard let demo else { return max(1, date.timeIntervalSinceNow) }
        return demo.realInterval(until: date)
    }

    /// The real moment the app clock shows `date`; nil on a frozen clock.
    static func realDate(for date: Date) -> Date? {
        guard let demo else { return date }
        let rate = demo.rate
        guard rate > 0 else { return nil }
        return Date().addingTimeInterval(date.timeIntervalSince(demo.now()) / rate)
    }

    /// What the app clock shows at the real moment `real`.
    static func appDate(fromReal real: Date) -> Date {
        guard let demo else { return real }
        return demo.now().addingTimeInterval(real.timeIntervalSinceNow * demo.rate)
    }
}

/// What the app runs against: the user's own setup, or the demo's.
@MainActor
enum AppRuntime {
    /// The demo session, in demo mode.
    private(set) static var demo: DemoSession?
    /// `UserDefaults.standard`, or the demo's own suite.
    private(set) static var defaults: UserDefaults = .standard

    static var isDemo: Bool { demo != nil }

    /// `--demo-reset`: start the demo from its original data even with
    /// "Keep demo changes" on (Demo › Reset Demo Data).
    static let resetArgument = "--demo-reset"

    /// How the simulator behaves in the app: a little latency, so progress shows.
    static var appBehavior: DemoAzure.Behavior {
        var b = DemoAzure.Behavior()
        b.latency = 0.12...0.4
        return b
    }

    /// Called once in main.swift, before anything reads a setting.
    /// `suiteName` / `directory`: where the demo keeps its settings and files.
    static func configure(arguments: [String], environment: [String: String], suiteName: String = DemoMode.defaultsSuite,
                          directory: URL? = nil) {
        guard DemoMode.isRequested(arguments: arguments, environment: environment),
              let suite = UserDefaults(suiteName: suiteName) else { return }
        // Nothing of the demo may reach the network, whatever path a bug takes.
        NetworkGuard.blockForProcess()
        let options = DemoOptions.load(from: suite).applying(environment: environment)
        let workspace = DemoWorkspace(directory: directory ?? DemoMode.dataDirectory(environment: environment))
        let session = DemoSession(options: options, workspace: workspace, behavior: appBehavior)
        if arguments.contains(resetArgument) || !options.keepChanges || !workspace.isSeeded {
            suite.removePersistentDomain(forName: suiteName)
            options.save(to: suite)
            AppModel.seedDemoDefaults(suite)
            try? workspace.reset(now: session.clock.now())
        }
        defaults = suite
        demo = session
        AppClock.use(session.clock)
    }
}

/// The Demo menu and badge: the demo's own options, and switching in and out.
@MainActor
@Observable
final class DemoController {
    static let shared = DemoController()

    private(set) var options: DemoOptions

    private init() {
        options = AppRuntime.demo?.options ?? DemoOptions()
    }

    var isDemo: Bool { AppRuntime.isDemo }
    var showsBadge: Bool { isDemo && !options.hideBadge }
    var isFrozen: Bool { options.frozenAt != nil }

    private func save() { if isDemo { options.save(to: AppRuntime.defaults) } }

    func setHideBadge(_ on: Bool) {
        options.hideBadge = on
        save()
    }

    func setKeepChanges(_ on: Bool) {
        options.keepChanges = on
        save()
    }

    /// Takes effect at once (the clock keeps its current time).
    func setSpeed(_ speed: Double) {
        options.speed = speed
        save()
        if !isFrozen { AppRuntime.demo?.clock.rate = speed }
    }

    /// Demo › Demo Mode: restart into or out of demo mode, after asking.
    func toggleDemoMode() {
        if isDemo {
            confirmRestart(
                title: "Leave demo mode?",
                message: "Pimento restarts with your own Azure session, settings, presets and history. The demo's notifications are removed.",
                button: "Restart Without Demo") { AppRelaunch.restart(demo: false) }
        } else {
            confirmRestart(
                title: "Switch to demo mode?",
                message: "Pimento restarts with a simulated Azure and synthetic data (Contoso, Fabrikam and friends), for trying every feature "
                    + "and for screenshots. Nothing is sent to Azure, and your own settings, presets, history and sign-in are not touched. "
                    + "Pimento › Demo Mode brings you back.",
                button: "Restart in Demo Mode") { AppRelaunch.restart(demo: true) }
        }
    }

    /// Demo › Reset Demo Data.
    func resetDemoData() {
        confirmRestart(
            title: "Reset the demo data?",
            message: "Pimento restarts with the original demo roles, requests, presets, history and settings.",
            button: "Reset and Restart") { AppRelaunch.restart(demo: true, reset: true) }
    }

    /// Demo › Freeze Clock at 10:30: needs a restart (the demo data is set
    /// out around the clock's time).
    func setFrozen(_ on: Bool) {
        confirmRestart(
            title: on ? "Freeze the demo clock at 10:30?" : "Let the demo clock run?",
            message: on
                ? "Pimento restarts in demo mode with the clock standing at 10:30 today: tidy times for screenshots. "
                    + "While it stands still, nothing expires, starts or gets decided."
                : "Pimento restarts in demo mode with the clock running from the current time.",
            button: "Restart") {
                self.options.frozenAt = on ? DemoMode.tidyMinutes : nil
                self.save()
                AppRelaunch.restart(demo: true, reset: true)
            }
    }

    private func confirmRestart(title: String, message: String, button: String, action: @escaping () -> Void) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: button)
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn { action() }
    }
}

/// Starts a new Pimento (in or out of demo mode) and quits this one.
@MainActor
enum AppRelaunch {
    static func restart(demo: Bool, reset: Bool = false) {
        let bundle = Bundle.main.bundleURL
        guard bundle.pathExtension == "app" else {
            let alert = NSAlert()
            alert.messageText = "Restart Pimento yourself"
            alert.informativeText = demo ? "Run it with --demo (or PIMENTO_DEMO=1) for demo mode." : "Run it without --demo to leave demo mode."
            alert.runModal()
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        configuration.activates = true
        configuration.arguments = demo ? [DemoMode.argument] + (reset ? [AppRuntime.resetArgument] : []) : []
        configuration.environment = [DemoMode.environmentVariable: demo ? "1" : "0"]
        if AppRuntime.isDemo { DemoNotifications.withdraw() }
        NSWorkspace.shared.openApplication(at: bundle, configuration: configuration) { _, error in
            Task { @MainActor in
                if let error {
                    let alert = NSAlert(error: error)
                    alert.runModal()
                    return
                }
                NSApp.terminate(nil)
            }
        }
    }
}

/// Demo notifications carry a mark, so they can be told apart from real
/// ones, and are withdrawn when the demo ends.
enum DemoNotifications {
    static let key = "pimento.demo"

    /// `content` marked as the demo's, in demo mode.
    static func tagged(_ content: UNNotificationContent) -> UNNotificationContent {
        guard AppClock.isDemo, content.userInfo[key] == nil,
              let copy = content.mutableCopy() as? UNMutableNotificationContent else { return content }
        copy.userInfo[key] = true
        copy.threadIdentifier = "demo-" + copy.threadIdentifier
        return copy
    }

    /// A notification of the mode the app runs in (demo ones in demo mode only).
    static func isOwn(_ content: UNNotificationContent) -> Bool {
        (content.userInfo[key] as? Bool == true) == AppClock.isDemo
    }

    /// Removes every demo notification, pending or delivered.
    static func withdraw() {
        guard Bundle.main.bundleIdentifier != nil, Bundle.main.bundleURL.pathExtension == "app" else { return }
        let center = UNUserNotificationCenter.current()
        center.getPendingNotificationRequests { requests in
            let ids = requests.filter { $0.content.userInfo[key] as? Bool == true }.map(\.identifier)
            if !ids.isEmpty { center.removePendingNotificationRequests(withIdentifiers: ids) }
        }
        center.getDeliveredNotifications { notes in
            let ids = notes.filter { $0.request.content.userInfo[key] as? Bool == true }.map(\.request.identifier)
            if !ids.isEmpty { center.removeDeliveredNotifications(withIdentifiers: ids) }
        }
    }
}

extension AppModel {
    /// The demo's starting settings: tidy recent justifications and tickets,
    /// Contoso as the tenant, the menu bar showing the time left.
    static func seedDemoDefaults(_ defaults: UserDefaults) {
        var prefs = Preferences()
        prefs.menuBarShowsRemainingTime = true
        prefs.save(to: defaults)
        defaults.set(DemoSeed.recentJustifications, forKey: Keys.recentJustifications)
        if let data = try? JSONEncoder().encode(DemoSeed.recentTickets) { defaults.set(data, forKey: Keys.recentTickets) }
        defaults.set("ServiceNow", forKey: Keys.lastTicketSystem)
        defaults.set(DemoDirectory.contoso.id, forKey: Keys.tenant)
    }
}

// MARK: - Views

/// Opens a sign-in or Azure page in the browser, unless the network is
/// blocked (demo mode): then nothing opens (`BrowserLaunch.guarded`).
@MainActor
enum AzureWebPage {
    @discardableResult
    static func open(_ url: URL) -> Bool {
        BrowserLaunch.guarded(url) { NSWorkspace.shared.open($0) }
    }
}

/// The small "Demo" pill (toolbar, menu bar popover), unless hidden for screenshots.
struct DemoBadge: View {
    var compact = false
    private var controller: DemoController { .shared }

    var body: some View {
        if controller.showsBadge {
            Text("Demo")
                .font(.system(size: compact ? 10 : 11, weight: .semibold))
                .padding(.horizontal, compact ? 6 : 8)
                .padding(.vertical, compact ? 1 : 2)
                .foregroundStyle(Color.orange)
                .background(Capsule().fill(Color.orange.opacity(0.16)))
                .overlay(Capsule().strokeBorder(Color.orange.opacity(0.35), lineWidth: 0.5))
                .help("Demo mode: simulated Azure and synthetic data; nothing is sent. Pimento › Demo Mode leaves it.")
                .accessibilityLabel("Demo mode")
        }
    }
}

/// The demo's card in Settings › General (demo mode only), in the leading
/// column under Refresh.
struct DemoSettingsSection: View {
    private var controller: DemoController { .shared }

    var body: some View {
        if controller.isDemo {
            SettingsGroup("Demo mode") {
                SettingsRow("Badge") {
                    Toggle("Hide demo badge", isOn: Binding(
                        get: { controller.options.hideBadge }, set: { controller.setHideBadge($0) }))
                        .help("For screenshots: no Demo badge in the toolbar or the menu bar popover")
                }
                SettingsRow("Demo data") {
                    Toggle("Keep changes between launches", isOn: Binding(
                        get: { controller.options.keepChanges }, set: { controller.setKeepChanges($0) }))
                }
                SettingsRow {
                    SettingsNote("Simulated Azure and synthetic data; nothing is sent.")
                }
            } accessory: {
                InfoButton("The Demo menu resets the data, freezes the clock at 10:30 or speeds it up. "
                    + "Pimento › Demo Mode leaves demo mode.", label: "About demo mode")
            }
        }
    }
}

/// Pimento › Demo Mode, and the Demo menu in demo mode.
struct DemoCommands: Commands {
    var body: some Commands {
        CommandGroup(after: .appSettings) {
            DemoModeToggle()
        }
        // The Demo menu only in demo mode; Pimento › Demo Mode switches.
        if AppRuntime.isDemo {
            CommandMenu("Demo") {
                DemoMenuItems()
            }
        }
    }
}

private struct DemoModeToggle: View {
    private var controller: DemoController { .shared }

    var body: some View {
        Toggle("Demo Mode", isOn: Binding(get: { controller.isDemo }, set: { _ in controller.toggleDemoMode() }))
    }
}

private struct DemoMenuItems: View {
    private var controller: DemoController { .shared }

    var body: some View {
        if controller.isDemo {
            Button("Reset Demo Data…") { controller.resetDemoData() }
            Divider()
            Toggle("Freeze Clock at 10:30…", isOn: Binding(get: { controller.isFrozen }, set: { controller.setFrozen($0) }))
            Picker("Clock Speed", selection: Binding(get: { controller.options.speed }, set: { controller.setSpeed($0) })) {
                ForEach(DemoOptions.speeds, id: \.self) { speed in
                    Text(speed == 1 ? "Real Time" : "\(Int(speed))× Faster").tag(speed)
                }
            }
            .disabled(controller.isFrozen)
            Divider()
            Toggle("Hide Demo Badge", isOn: Binding(get: { controller.options.hideBadge }, set: { controller.setHideBadge($0) }))
            Toggle("Keep Demo Changes", isOn: Binding(get: { controller.options.keepChanges }, set: { controller.setKeepChanges($0) }))
            Divider()
            Button("Leave Demo Mode…") { controller.toggleDemoMode() }
        }
    }
}
