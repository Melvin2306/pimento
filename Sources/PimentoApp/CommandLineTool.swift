import AppKit
import Foundation
import PimentoCore

/// "Install / Uninstall Command Line Tool…" in the app menu: symlinks the
/// bundled `pimento` tool into /usr/local/bin (administrator password) or
/// ~/.local/bin (no password). The path logic is in `CLIInstaller` (tested).
@MainActor
enum CommandLineTool {
    /// The CLI shipped with this app (Contents/Helpers/pimento) or, when running
    /// from `swift run`, the `pimento` built next to the app binary.
    nonisolated static var toolPath: String? {
        let fm = FileManager.default
        let bundle = Bundle.main.bundleURL
        if bundle.pathExtension == "app" {
            let path = bundle.appendingPathComponent(CLIInstaller.bundlePath).path
            return fm.isExecutableFile(atPath: path) ? path : nil
        }
        // Not in a bundle. (Inside one, MacOS/pimento would be the app itself
        // on a case-insensitive disk, hence the check above.)
        guard let dir = Bundle.main.executableURL?.deletingLastPathComponent() else { return nil }
        let path = dir.appendingPathComponent(CLIInstaller.toolName).path
        return fm.isExecutableFile(atPath: path) ? path : nil
    }

    /// Replaces this process with the bundled CLI (0.1.0's `Pimento --list` etc.).
    nonisolated static func forwardLegacyCall(_ args: [String]) -> Never {
        guard let tool = toolPath else {
            fputs("error: the pimento command-line tool is not bundled with this build. Use `swift run pimento …`.\n", stderr)
            exit(2)
        }
        let argv = ([tool] + args).map { strdup($0) } + [nil]
        execv(tool, argv)
        fputs("error: could not start \(tool): \(String(cString: strerror(errno)))\n", stderr)
        exit(1)
    }

    static var home: String { FileManager.default.homeDirectoryForCurrentUser.path }

    // MARK: Install

    static func install() {
        guard let source = toolPath else {
            inform("The command-line tool is not available",
                   "This copy of Pimento has no bundled `pimento` tool. Build the app with scripts/bundle.sh, "
                       + "or download the command-line tool on its own from the releases page.")
            return
        }
        let alert = NSAlert()
        alert.messageText = "Install the pimento command-line tool?"
        alert.informativeText = """
        Pimento links its command-line tool into a folder on your PATH, so you can run \
        `pimento list` or `pimento activate` in Terminal. The link points into this app: \
        if you move or delete Pimento.app, install again.

        /usr/local/bin is on every PATH but needs an administrator password. \
        ~/.local/bin needs no password, but it must be on your PATH.
        """
        alert.addButton(withTitle: "Install in /usr/local/bin")
        alert.addButton(withTitle: "Install in ~/.local/bin")
        alert.addButton(withTitle: "Cancel")
        let location: CLIInstallLocation
        switch alert.runModal() {
        case .alertFirstButtonReturn: location = .system
        case .alertSecondButtonReturn: location = .user
        default: return
        }
        let link = location.linkPath(home: home)
        // Everyone (root too) runs /usr/local/bin/pimento: it must not lead
        // to a file that another user could replace.
        if location == .system, let weak = CLIInstaller.untrustedSource(source) {
            inform("Pimento.app is in a folder others can change",
                   "\(weak) can be changed by another user, so a pimento in /usr/local/bin would run whatever they put there. "
                       + "Move Pimento.app to /Applications (or your own Applications folder) and try again, or install in ~/.local/bin.")
            return
        }
        switch CLIInstaller.installAction(source: source, linkPath: link, state: CLIInstaller.state(at: link)) {
        case .upToDate:
            inform("Already installed", "\(link) already points to this app's command-line tool.")
            return
        case .blocked:
            inform("A file is in the way",
                   "\(link) exists and is not a symbolic link, so Pimento leaves it alone. Remove it and try again.")
            return
        case .notOwned(let target, let owner):
            inform("Another user's link is in the way",
                   "\(link) points to \(target) and belongs to another user (uid \(owner)), so Pimento leaves it alone. "
                       + "Have it removed and try again.")
            return
        case .conflict(let target):
            guard confirm("Replace the existing pimento?",
                          "\(link) points to \(target), which is not Pimento's command-line tool. Replace the link?",
                          button: "Replace")
            else { return }
        case .create, .replace:
            break
        }
        Task {
            let error = await createLink(source: source, at: link, location: location)
            if let error {
                inform("The command-line tool was not installed", error)
                return
            }
            var text = "Run `pimento help` in a new Terminal window to get started."
            if location == .user {
                text += "\n\nIf the shell says “command not found”, add ~/.local/bin to your PATH, e.g. in ~/.zshrc:\n"
                    + "export PATH=\"$HOME/.local/bin:$PATH\""
            }
            inform("Installed \(location.displayDirectory(home: home))/pimento", text)
        }
    }

    /// Creates the link, as root via macOS's password prompt when the folder is not writable.
    /// Returns an error message, or nil on success.
    private static func createLink(source: String, at link: String, location: CLIInstallLocation) async -> String? {
        let fm = FileManager.default
        let dir = location.directory(home: home)
        let parent = URL(fileURLWithPath: dir).deletingLastPathComponent().path
        let writable = fm.fileExists(atPath: dir) ? fm.isWritableFile(atPath: dir) : fm.isWritableFile(atPath: parent)
        if location == .user || writable {
            do {
                try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
                if case .symlink = CLIInstaller.state(at: link) { try fm.removeItem(atPath: link) }
                try fm.createSymbolicLink(atPath: link, withDestinationPath: source)
                return nil
            } catch {
                return error.localizedDescription
            }
        }
        return await runAsAdmin(CLIInstaller.installCommand(source: source, linkPath: link),
                                prompt: "Pimento wants to link \(link) to \(source).")
    }

    // MARK: Uninstall

    static func uninstall() {
        let source = toolPath
        var removed: [String] = [], foreign: [String] = [], needsAdmin: [String] = [], errors: [String] = []
        for location in CLIInstallLocation.allCases {
            let link = location.linkPath(home: home)
            switch CLIInstaller.uninstallAction(source: source, linkPath: link, state: CLIInstaller.state(at: link)) {
            case .notInstalled:
                continue
            case .notOurs(let target):
                foreign.append(target == link ? link : "\(link) → \(target)")
            case .remove:
                do {
                    try FileManager.default.removeItem(atPath: link)
                    removed.append(link)
                } catch {
                    if location == .system { needsAdmin.append(link) } else { errors.append("\(link): \(error.localizedDescription)") }
                }
            }
        }
        Task {
            if !needsAdmin.isEmpty {
                let command = needsAdmin.map(CLIInstaller.uninstallCommand(linkPath:)).joined(separator: " && ")
                if let error = await runAsAdmin(command, prompt: "Pimento wants to remove its command-line tool.") {
                    errors.append(error)
                } else {
                    removed += needsAdmin
                }
            }
            var lines: [String] = []
            if !removed.isEmpty { lines.append("Removed:\n" + removed.joined(separator: "\n")) }
            if !foreign.isEmpty { lines.append("Left alone (not Pimento's):\n" + foreign.joined(separator: "\n")) }
            if !errors.isEmpty { lines.append("Failed:\n" + errors.joined(separator: "\n")) }
            let title = errors.isEmpty
                ? (removed.isEmpty ? "The command-line tool is not installed" : "Command-line tool uninstalled")
                : "The command-line tool was not fully uninstalled"
            inform(title, lines.isEmpty ? "Neither /usr/local/bin nor ~/.local/bin has a pimento link." : lines.joined(separator: "\n\n"))
        }
    }

    // MARK: Helpers

    /// `osascript … with administrator privileges`. Returns an error message, or nil on success.
    private nonisolated static func runAsAdmin(_ command: String, prompt: String) async -> String? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
                process.arguments = ["-e", CLIInstaller.adminAppleScript(command, prompt: prompt)]
                let err = Pipe()
                process.standardError = err
                process.standardOutput = FileHandle.nullDevice
                do { try process.run() } catch {
                    continuation.resume(returning: error.localizedDescription)
                    return
                }
                let data = err.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                guard process.terminationStatus != 0 else {
                    continuation.resume(returning: nil)
                    return
                }
                let message = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                continuation.resume(returning: message.contains("-128") ? "Cancelled." : message)
            }
        }
    }

    private static func inform(_ title: String, _ text: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.runModal()
    }

    private static func confirm(_ title: String, _ text: String, button: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.alertStyle = .warning
        alert.addButton(withTitle: button)
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }
}
