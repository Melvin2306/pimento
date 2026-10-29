import AppKit
import Foundation
import PimentoCore
import SwiftUI

// The command-line tool is the separate `pimento` binary (bundled at
// Contents/Helpers/pimento). For one release, the old read-only flags on the
// app binary (`--list`, `--dry-run`, `--tenants`, `--version`, `--help`) are
// handed to it; anything else opens the app.
let launchArguments = Array(CommandLine.arguments.dropFirst())
if LaunchArguments.isLegacyCLICall(launchArguments) {
    CommandLineTool.forwardLegacyCall(launchArguments)
}
PimentoApp.main()

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated {
            // A Dock icon, or the menu bar only (Settings › General › Menu bar).
            // Also needed when launched as a bare executable (`swift run`)
            // rather than a .app, which starts without any.
            DockIcon.apply(AppModel.shared.prefs, reactivate: false, atLaunch: true)
            NSApp.activate(ignoringOtherApps: true)
            AppAppearance.apply(AppModel.shared.appearance)
            // Starts the menu bar countdown's timer.
            _ = MenuBarClock.shared
        }
        Task { @MainActor in Notifier.setUp() }
    }

    /// With the menu bar extra, closing the window keeps Pimento running there.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        MainActor.assumeIsolated { AppPresence.terminatesAfterLastWindowClosed(AppModel.shared.prefs) }
    }
}

struct PimentoApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    // One model for the app's lifetime. (Not `@State`: in the macOS 26 SDK that is a
    // macro whose plugin ships only with full Xcode, and the app builds with the
    // Command Line Tools alone.)
    private var model: AppModel { AppModel.shared }
    /// Whether the menu bar extra is shown: read from the stored setting,
    /// which `AppModel` saves on every change, so the scene follows it live.
    @AppStorage(Preferences.showInMenuBarKey) private var showInMenuBar = Preferences().showInMenuBar

    var body: some Scene {
        Window(AppInfo.name, id: "main") {
            AppThemed { ContentView() }
                .environment(model)
                .frame(minWidth: 960, minHeight: 520)
        }
        .defaultSize(width: 1180, height: 720)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About \(AppInfo.name)") { showAboutPanel() }
            }
            CommandGroup(after: .appSettings) {
                Button("Install Command Line Tool…") { CommandLineTool.install() }
                Button("Uninstall Command Line Tool…") { CommandLineTool.uninstall() }
            }
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .toolbar) {
                Button("Refresh") { Task { await model.refresh() } }
                    .keyboardShortcut("r")
                    .disabled(model.loadState == .loading || model.isActivating)
                Divider()
                Button("Select All Eligible") { model.selectAllEligible() }
                    .keyboardShortcut("a", modifiers: [.command, .shift])
                    .disabled(model.isActivating)
                Button("Clear Selection") { model.clearSelection() }
                    .keyboardShortcut("d", modifiers: [.command, .shift])
                    .disabled((model.checked.isEmpty && model.checkedActive.isEmpty) || model.isActivating)
                Button("Preview Requests…") { model.buildDryRun() }
                    .keyboardShortcut(.return, modifiers: [.command, .option])
                    .disabled(!model.canActivate)
                Button("Scheduled Activations…") { model.openScheduled() }
                    .keyboardShortcut("l", modifiers: [.command, .shift])
                    .disabled(model.identity == nil)
                Button("Approvals…") { model.openApprovals() }
                    .keyboardShortcut("p", modifiers: [.command, .shift])
                    .disabled(model.identity == nil)
                Button("History…") { model.openHistory() }
                    .keyboardShortcut("h", modifiers: [.command, .shift])
                Button("Clear Results") { model.clearResults() }
                    .keyboardShortcut("k")
                    .disabled(model.progress.isEmpty || model.isActivating)
                Divider()
                Button("Renew Selected Active Roles…") { model.requestRenewal() }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                    .disabled(!model.canChangeActive)
                Button("End Selected Active Roles…") { model.requestDeactivation() }
                    .keyboardShortcut("e", modifiers: [.command, .shift])
                    .disabled(!model.canChangeActive)
                Divider()
                Button("Choose Tenant…") { model.openTenantPicker() }
                    .keyboardShortcut("t", modifiers: [.command, .shift])
                    .disabled(model.isActivating)
            }
            CommandMenu("Presets") {
                PresetMenuItems(shortcuts: true)
                    .environment(model)
            }
            CommandGroup(replacing: .help) {
                Button("\(AppInfo.name) on GitHub") { NSWorkspace.shared.open(AppInfo.repositoryURL) }
                Button("Report an Issue") { NSWorkspace.shared.open(AppInfo.issuesURL) }
            }
        }

        // ⌘, opens it from the app menu.
        Settings {
            AppThemed { SettingsView() }
                .environment(model)
        }

        // Active roles with their countdown, presets and quick actions.
        MenuBarExtra(isInserted: menuBarInserted) {
            MenuBarContent(model: model, clock: MenuBarClock.shared)
                .environment(model)
        } label: {
            MenuBarLabel(model: model, clock: MenuBarClock.shared)
        }
        .menuBarExtraStyle(.window)
    }

    /// Removing the item from the menu bar (⌘-drag) turns the setting off.
    private var menuBarInserted: Binding<Bool> {
        Binding(get: { showInMenuBar }, set: { shown in MainActor.assumeIsolated { model.prefs.showInMenuBar = shown } })
    }

    private func showAboutPanel() {
        let credits = NSMutableAttributedString(
            string: "\(AppInfo.tagline).\nUses your own Azure CLI session. MIT licensed.\n\n",
            attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor])
        credits.append(NSAttributedString(
            string: AppInfo.repositoryURL.absoluteString.replacingOccurrences(of: "https://", with: ""),
            attributes: [.font: NSFont.systemFont(ofSize: 11), .link: AppInfo.repositoryURL]))
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        credits.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: credits.length))
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: AppInfo.name,
            .applicationVersion: AppInfo.version,
            .version: "",
            .credits: credits,
        ])
        NSApp.activate(ignoringOtherApps: true)
    }
}
