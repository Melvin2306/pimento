import AppKit
import Foundation
import PimentoCore
import SwiftUI

// `pimento --list`, `--dry-run …`, `--tenants`, `--help`, `--version` run a
// read-only CLI; anything else opens the app.
let options: CLIOptions
do {
    options = try CLIOptions.parse(Array(CommandLine.arguments.dropFirst()))
} catch {
    fputs("error: \(error.localizedDescription)\n", stderr)
    exit(64)
}

if options.mode == .app {
    PimentoApp.main()
} else {
    Task {
        let code = await CLI.run(options)
        exit(code)
    }
    dispatchMain()
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Needed when launched as a bare executable (`swift run`) rather than a .app.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        Task { @MainActor in Notifier.setUp() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

struct PimentoApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    // One model for the app's lifetime. (Not `@State`: in the macOS 26 SDK that is a
    // macro whose plugin ships only with full Xcode, and the app builds with the
    // Command Line Tools alone.)
    private var model: AppModel { AppModel.shared }

    var body: some Scene {
        Window(AppInfo.name, id: "main") {
            ContentView()
                .environment(model)
                .frame(minWidth: 960, minHeight: 520)
        }
        .defaultSize(width: 1180, height: 720)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About \(AppInfo.name)") { showAboutPanel() }
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
                    .disabled(model.checked.isEmpty || model.isActivating)
                Button("Preview Requests…") { model.buildDryRun() }
                    .keyboardShortcut(.return, modifiers: [.command, .option])
                    .disabled(!model.canActivate)
                Button("Clear Results") { model.clearResults() }
                    .keyboardShortcut("k")
                    .disabled(model.progress.isEmpty || model.isActivating)
                Divider()
                Button("Choose Tenant…") { model.openTenantPicker() }
                    .keyboardShortcut("t", modifiers: [.command, .shift])
                    .disabled(model.isActivating)
            }
            CommandGroup(replacing: .help) {
                Button("\(AppInfo.name) on GitHub") { NSWorkspace.shared.open(AppInfo.repositoryURL) }
                Button("Report an Issue") { NSWorkspace.shared.open(AppInfo.issuesURL) }
            }
        }

        // ⌘, opens it from the app menu.
        Settings {
            SettingsView()
                .environment(model)
        }
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
