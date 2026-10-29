import Foundation

/// The operating system Pimento runs on. Code that differs per platform takes
/// one (defaulting to `current`), so tests can check every platform's answer.
public enum HostPlatform: String, CaseIterable, Sendable {
    case macOS, linux, windows

    public static var current: HostPlatform {
        #if os(macOS)
        .macOS
        #elseif os(Windows)
        .windows
        #else
        .linux
        #endif
    }

    /// `PATH`'s separator.
    public var pathListSeparator: Character { self == .windows ? ";" : ":" }

    /// Joins path components with this platform's separator.
    public func join(_ base: String, _ components: String...) -> String {
        let separator = self == .windows ? "\\" : "/"
        return components.reduce(base) { path, next in
            path.hasSuffix(separator) || path.hasSuffix("/") ? path + next : path + separator + next
        }
    }
}

/// Where Pimento keeps its files (presets, history, sign-in settings and, off
/// macOS, the token file):
///
/// - macOS: `~/Library/Application Support/Pimento` (shared with the app)
/// - Linux: `$XDG_CONFIG_HOME/pimento`, else `~/.config/pimento`
/// - Windows: `%APPDATA%\Pimento`, else `<home>\AppData\Roaming\Pimento`
public enum PimentoPaths {
    public static func dataDirectoryPath(
        environment: [String: String], home: String = NSHomeDirectory(), platform: HostPlatform = .current
    ) -> String {
        switch platform {
        case .macOS:
            return platform.join(home, "Library", "Application Support", "Pimento")
        case .linux:
            return platform.join(xdgConfigHome(environment: environment, home: home, platform: platform), "pimento")
        case .windows:
            let appData = nonEmpty(environment["APPDATA"]) ?? platform.join(home, "AppData", "Roaming")
            return platform.join(appData, "Pimento")
        }
    }

    public static func dataDirectory(
        environment: [String: String], home: String = NSHomeDirectory(), platform: HostPlatform = .current
    ) -> URL {
        URL(fileURLWithPath: dataDirectoryPath(environment: environment, home: home, platform: platform), isDirectory: true)
    }

    /// `$XDG_CONFIG_HOME`, else `~/.config`.
    public static func xdgConfigHome(environment: [String: String], home: String, platform: HostPlatform = .current) -> String {
        nonEmpty(environment["XDG_CONFIG_HOME"]) ?? platform.join(home, ".config")
    }

    /// The folder as help texts show it.
    public static func displayDataDirectory(platform: HostPlatform = .current) -> String {
        switch platform {
        case .macOS: "~/Library/Application Support/Pimento"
        case .linux: "~/.config/pimento"
        case .windows: "%APPDATA%\\Pimento"
        }
    }

    /// A file in the folder, as help texts show it.
    public static func displayFile(_ name: String, platform: HostPlatform = .current) -> String {
        displayDataDirectory(platform: platform) + (platform == .windows ? "\\" : "/") + name
    }

    /// Expands a leading `~` (`~`, `~/…`, and `~\…` on Windows) to `home`.
    public static func expandTilde(_ path: String, home: String = NSHomeDirectory(), platform: HostPlatform = .current) -> String {
        if path == "~" { return home }
        if path.hasPrefix("~/") || (platform == .windows && path.hasPrefix("~\\")) {
            return platform.join(home, String(path.dropFirst(2)))
        }
        return path
    }

    static func nonEmpty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespaces), !value.isEmpty else { return nil }
        return value
    }
}
