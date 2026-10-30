#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
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
    /// A symlink, with its target as stored (may be relative), owned by you or root.
    case symlink(String)
    /// A symlink owned by another user: whatever it points to, Pimento never
    /// reports it as installed, replaces or removes it.
    case foreignSymlink(String, owner: UInt32)
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
    /// A link another user owns (`CLILinkState.foreignSymlink`): left alone.
    case notOwned(target: String, owner: UInt32)
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
        case .foreignSymlink(let raw, let owner):
            return .notOwned(target: resolve(target: raw, linkPath: linkPath), owner: owner)
        case .symlink(let raw):
            // Where it really ends up (through folder links too), which is
            // what `pimento` runs and what the app reports.
            let target = realPath(resolve(target: raw, linkPath: linkPath))
            if target == realPath(source) { return .upToDate }
            return isBundledTool(target) ? .replace(previous: target) : .conflict(target)
        }
    }

    /// `path` with every symlink in it followed (as far as they exist).
    static func realPath(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().standardized.path
    }

    /// Removes only links to Pimento's tool (this app's, or another Pimento.app's).
    public static func uninstallAction(source: String?, linkPath: String, state: CLILinkState) -> CLIUninstallAction {
        switch state {
        case .missing:
            return .notInstalled
        case .other:
            return .notOurs(linkPath)
        case .foreignSymlink(let raw, _):
            return .notOurs(resolve(target: raw, linkPath: linkPath))
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

    /// Reads what is at `path` without following a final symlink. A link
    /// owned by anyone but `user` or root is a `foreignSymlink`.
    public static func state(at path: String, user: UInt32 = PathTrust.currentUser, fileManager: FileManager = .default) -> CLILinkState {
        if let target = try? fileManager.destinationOfSymbolicLink(atPath: path) {
            // attributesOfItem does not follow the final link (lstat).
            if let owner = (try? fileManager.attributesOfItem(atPath: path))?[.ownerAccountID] as? NSNumber,
               owner.uint32Value != 0, owner.uint32Value != user {
                return .foreignSymlink(target, owner: owner.uint32Value)
            }
            return .symlink(target)
        }
        return fileManager.fileExists(atPath: path) ? .other : .missing
    }

    /// For a link in /usr/local/bin, which every user (and root) runs: the
    /// first folder or file on the way to `source` that someone other than
    /// root or `user` could change (`PathTrust`), or nil when there is none.
    /// A root-owned link to a tool in such a place would let that someone
    /// run code as whoever types `pimento`.
    public static func untrustedSource(_ source: String, user: UInt32 = PathTrust.currentUser,
                                       info: (String) -> PathTrust.Info? = PathTrust.info(at:)) -> String? {
        PathTrust.firstUntrusted(realPath(source), user: user, info: info)
    }
}

/// Who could change a file or folder: its owner and mode, without following
/// a final symlink.
public enum PathTrust {
    public struct Info: Equatable, Sendable {
        public let owner: UInt32
        public let group: UInt32
        /// Permission bits including sticky (`0o1777`).
        public let mode: UInt16

        public init(owner: UInt32, group: UInt32, mode: UInt16) {
            self.owner = owner
            self.group = group
            self.mode = mode
        }
    }

    /// The groups that may share a system folder: wheel (0) and, on macOS, admin (80).
    static let systemGroups: Set<UInt32> = [0, 80]

    public static var currentUser: UInt32 {
        #if os(Windows)
        0
        #else
        UInt32(getuid())
        #endif
    }

    public static func info(at path: String) -> Info? {
        guard let a = try? FileManager.default.attributesOfItem(atPath: path),
              let owner = (a[.ownerAccountID] as? NSNumber)?.uint32Value,
              let group = (a[.groupOwnerAccountID] as? NSNumber)?.uint32Value,
              let mode = (a[.posixPermissions] as? NSNumber)?.uint16Value
        else { return nil }
        return Info(owner: owner, group: group, mode: mode)
    }

    /// Trusted: owned by root or `user`, not writable by others (unless
    /// sticky and root's, like /tmp: nobody else can replace what is in it),
    /// and writable by its group only for wheel or admin.
    public static func isTrusted(_ i: Info, user: UInt32) -> Bool {
        guard i.owner == 0 || i.owner == user else { return false }
        if i.mode & 0o002 != 0, !(i.owner == 0 && i.mode & 0o1000 != 0) { return false }
        if i.mode & 0o020 != 0, !systemGroups.contains(i.group) { return false }
        return true
    }

    /// `path` and each folder above it up to `/`: the first one that is
    /// missing or not trusted, else nil.
    public static func firstUntrusted(_ path: String, user: UInt32, info: (String) -> Info?) -> String? {
        var current = URL(fileURLWithPath: path).standardized
        while true {
            let p = current.path
            guard let i = info(p), isTrusted(i, user: user) else { return p }
            if p == "/" || p.isEmpty { return nil }
            let parent = current.deletingLastPathComponent().standardized
            if parent.path == p { return nil }
            current = parent
        }
    }
}
