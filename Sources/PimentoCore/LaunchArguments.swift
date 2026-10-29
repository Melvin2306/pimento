import Foundation

/// The app's launch arguments: only `--tenant` matters to the GUI.
public enum LaunchArguments {
    /// `--tenant X`, `-t X` or `--tenant=X`; anything else is ignored (macOS
    /// passes its own arguments, e.g. `-NSDocumentRevisionsDebugMode YES`).
    public static func tenant(in args: [String]) -> String? {
        var tenant: String?
        var i = 0
        while i < args.count {
            let arg = args[i]
            if arg.hasPrefix("--tenant=") {
                tenant = String(arg.dropFirst("--tenant=".count))
            } else if arg == "--tenant" || arg == "-t", i + 1 < args.count, !args[i + 1].hasPrefix("-") {
                tenant = args[i + 1]
                i += 1
            }
            i += 1
        }
        return tenant
    }

    /// The read-only CLI flags the app binary understood in 0.1.0. For one more
    /// release the app hands such a call to the bundled `pimento` tool.
    public static let legacyCLIFlags: Set<String> = ["--list", "--dry-run", "--tenants", "--version", "--help", "-h"]

    public static func isLegacyCLICall(_ args: [String]) -> Bool { args.contains(where: legacyCLIFlags.contains) }
}
