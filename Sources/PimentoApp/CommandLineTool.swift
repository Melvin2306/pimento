import AppKit
import Foundation
import PimentoCore

/// The `pimento` command-line tool bundled with the app.
enum CommandLineTool {
    /// The CLI shipped with this app (Contents/Helpers/pimento) or, when running
    /// from `swift run`, the `pimento` built next to the app binary.
    nonisolated static var toolPath: String? {
        let fm = FileManager.default
        let bundle = Bundle.main.bundleURL
        if bundle.pathExtension == "app" {
            let path = bundle.appendingPathComponent("Contents/Helpers/pimento").path
            return fm.isExecutableFile(atPath: path) ? path : nil
        }
        // Not in a bundle. (Inside one, MacOS/pimento would be the app itself
        // on a case-insensitive disk, hence the check above.)
        guard let dir = Bundle.main.executableURL?.deletingLastPathComponent() else { return nil }
        let path = dir.appendingPathComponent("pimento").path
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
}
