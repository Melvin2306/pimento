import Foundation

/// Where "Install Command Line Tool…" can put the `pimento` symlink.
public enum CLIInstallLocation: String, CaseIterable, Sendable {
    /// `/usr/local/bin`: on everyone's PATH; usually needs an administrator password.
    case system
    /// `~/.local/bin`: no password; must be on your PATH.
    case user

    public func directory(home: String) -> String {
        switch self {
        case .system: "/usr/local/bin"
        case .user: (home.hasSuffix("/") ? String(home.dropLast()) : home) + "/.local/bin"
        }
    }

    public func linkPath(home: String) -> String { directory(home: home) + "/" + CLIInstaller.toolName }

    /// `/usr/local/bin` or `~/.local/bin`.
    public func displayDirectory(home: String) -> String {
        switch self {
        case .system: directory(home: home)
        case .user: "~/.local/bin"
        }
    }
}

/// What is at the link path right now.
public enum CLILinkState: Equatable, Sendable {
    case missing
    /// A symlink, with its target as stored (may be relative).
    case symlink(String)
    /// A file or directory that is not a symlink.
    case other
}

public enum CLIInstallAction: Equatable, Sendable {
    /// Nothing there: create the link.
    case create
    /// A link to another Pimento.app (an older copy, a moved app): replace it.
    case replace(previous: String)
    /// Already points at this app's tool.
    case upToDate
    /// A link to something that isn't Pimento's tool: ask before replacing it.
    case conflict(String)
    /// A real file or folder: never replaced; the user has to remove it.
    case blocked
}

public enum CLIUninstallAction: Equatable, Sendable {
    case remove
    case notInstalled
    /// Leave it alone: it isn't a link to a Pimento.app.
    case notOurs(String)
}

/// The symlink logic behind the app's "Install / Uninstall Command Line Tool…"
/// menu items. Pure, apart from `state(at:)`.
public enum CLIInstaller {
    public static let toolName = "pimento"
    /// Where the CLI sits inside the app bundle.
    public static let bundlePath = "Contents/Helpers/pimento"

    /// The absolute, standardized target of a symlink stored at `linkPath`.
    public static func resolve(target: String, linkPath: String) -> String {
        let url = target.hasPrefix("/")
            ? URL(fileURLWithPath: target)
            : URL(fileURLWithPath: linkPath).deletingLastPathComponent().appendingPathComponent(target)
        return url.standardized.path
    }

    static func standardized(_ path: String) -> String { URL(fileURLWithPath: path).standardized.path }

    /// True for the CLI inside any `….app` bundle (`/Applications/Pimento.app/Contents/Helpers/pimento`).
    public static func isBundledTool(_ path: String) -> Bool {
        let parts = path.split(separator: "/")
        guard parts.count >= 4 else { return false }
        return parts.suffix(3).joined(separator: "/") == bundlePath && parts[parts.count - 4].hasSuffix(".app")
    }

    public static func installAction(source: String, linkPath: String, state: CLILinkState) -> CLIInstallAction {
        switch state {
        case .missing:
            return .create
        case .other:
            return .blocked
        case .symlink(let raw):
            let target = resolve(target: raw, linkPath: linkPath)
            if target == standardized(source) { return .upToDate }
            return isBundledTool(target) ? .replace(previous: target) : .conflict(target)
        }
    }

    /// Removes only links to Pimento's tool (this app's, or another Pimento.app's).
    public static func uninstallAction(source: String?, linkPath: String, state: CLILinkState) -> CLIUninstallAction {
        switch state {
        case .missing:
            return .notInstalled
        case .other:
            return .notOurs(linkPath)
        case .symlink(let raw):
            let target = resolve(target: raw, linkPath: linkPath)
            if let source, target == standardized(source) { return .remove }
            return isBundledTool(target) ? .remove : .notOurs(target)
        }
    }

    /// `'…'` for /bin/sh, with embedded single quotes escaped.
    public static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }

    /// Creates or replaces the link, as root after the password prompt. It
    /// checks again right before `ln`: a real file or folder that appeared
    /// at the path since `installAction` looked is never overwritten.
    public static func installCommand(source: String, linkPath: String) -> String {
        let dir = URL(fileURLWithPath: linkPath).deletingLastPathComponent().path
        let link = shellQuote(linkPath)
        return "/bin/mkdir -p \(shellQuote(dir)) && { [ ! -e \(link) ] || [ -L \(link) ]; } && /bin/ln -sfn \(shellQuote(source)) \(link)"
    }

    /// Removes the link only if it still is one.
    public static func uninstallCommand(linkPath: String) -> String {
        let link = shellQuote(linkPath)
        return "{ [ ! -L \(link) ] || /bin/rm -f \(link); }"
    }

    /// AppleScript that runs `command` as root after macOS's password prompt.
    public static func adminAppleScript(_ command: String, prompt: String) -> String {
        func quoted(_ s: String) -> String {
            "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }
        return "do shell script \(quoted(command)) with prompt \(quoted(prompt)) with administrator privileges"
    }

    /// Reads what is at `path` without following a final symlink.
    public static func state(at path: String, fileManager: FileManager = .default) -> CLILinkState {
        if let target = try? fileManager.destinationOfSymbolicLink(atPath: path) { return .symlink(target) }
        return fileManager.fileExists(atPath: path) ? .other : .missing
    }
}
