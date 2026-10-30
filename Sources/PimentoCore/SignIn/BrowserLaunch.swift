#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation

/// How the CLI opens the sign-in page without putting its URL in a process's
/// arguments. The authorize URL carries `state`, `nonce` and the PKCE
/// challenge; another local user can read process arguments (`/proc/PID/cmdline`
/// on Linux without `hidepid`), and with those values could hand the loopback
/// listener a code for an account of their own. So the opener (`xdg-open` on
/// Linux, the shell on Windows) is given only the path of a private redirect
/// page; on macOS the CLI asks LaunchServices directly, with no child process.
public enum BrowserLaunch {
    /// A redirect page: `index.html` (0600) in a fresh folder (0700) that no
    /// other user can list or read. `remove()` deletes both.
    public struct RedirectPage: Sendable {
        public let file: URL
        public let directory: URL

        public func remove() {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    /// The page: a meta refresh to `url`, and a link for browsers that ignore it.
    static func html(for url: URL) -> String {
        let target = escape(url.absoluteString.replacingOccurrences(of: "'", with: "%27"))
        return """
        <!doctype html>
        <html><head><meta charset="utf-8">
        <meta name="referrer" content="no-referrer">
        <meta http-equiv="refresh" content="0; url='\(target)'">
        <title>Pimento sign-in</title></head>
        <body><p>Opening the Microsoft sign-in page… <a href="\(target)">Continue</a></p></body></html>

        """
    }

    static func escape(_ s: String) -> String {
        var out = ""
        for ch in s {
            switch ch {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "'": out += "&#39;"
            default: out.append(ch)
            }
        }
        return out
    }

    /// Writes the redirect page for `url` into a new private folder in `base`.
    public static func writeRedirectPage(for url: URL, in base: URL = FileManager.default.temporaryDirectory) throws -> RedirectPage {
        let data = Data(html(for: url).utf8)
        #if os(Windows)
        // The temporary folder is in the user's profile, which other users cannot read.
        let directory = base.appendingPathComponent("pimento-signin-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let file = directory.appendingPathComponent("index.html")
        try data.write(to: file, options: .withoutOverwriting)
        return RedirectPage(file: file, directory: directory)
        #else
        // mkdtemp: a new folder, mode 0700, with a name nobody could guess or pre-create.
        var template = Array(base.appendingPathComponent("pimento-signin-XXXXXXXX").path.utf8CString)
        let made = template.withUnsafeMutableBufferPointer { mkdtemp($0.baseAddress!) }
        guard made != nil else { throw CocoaError(.fileWriteNoPermission, userInfo: [NSFilePathErrorKey: base.path]) }
        let directory = URL(fileURLWithPath: String(cString: template), isDirectory: true)
        let file = directory.appendingPathComponent("index.html")
        let page = RedirectPage(file: file, directory: directory)
        let fd = open(file.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else {
            page.remove()
            throw CocoaError(.fileWriteNoPermission, userInfo: [NSFilePathErrorKey: file.path])
        }
        let ok = data.withUnsafeBytes { buffer -> Bool in
            var offset = 0
            while offset < buffer.count {
                let n = write(fd, buffer.baseAddress! + offset, buffer.count - offset)
                guard n > 0 else { return false }
                offset += n
            }
            return true
        }
        _ = close(fd)
        guard ok else {
            page.remove()
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: file.path])
        }
        return page
        #endif
    }

    /// Opens `url` through a redirect page: `open` gets only the page's path.
    /// Returns the page (to remove once sign-in is over), or nil when the page
    /// could not be written or `open` failed (the page is removed then).
    public static func openThroughPage(
        _ url: URL, in base: URL = FileManager.default.temporaryDirectory, open: (String) -> Bool
    ) -> RedirectPage? {
        guard let page = try? writeRedirectPage(for: url, in: base) else { return nil }
        guard open(page.file.path) else {
            page.remove()
            return nil
        }
        return page
    }
}

/// The redirect pages of this process, removed when sign-in is over (and
/// again before the CLI exits).
public final class RedirectPages: @unchecked Sendable {
    private let lock = NSLock()
    private var pages: [BrowserLaunch.RedirectPage] = []

    public init() {}

    public func add(_ page: BrowserLaunch.RedirectPage) {
        lock.withLock { pages.append(page) }
    }

    public func removeAll() {
        let all = lock.withLock { () -> [BrowserLaunch.RedirectPage] in
            defer { pages = [] }
            return pages
        }
        all.forEach { $0.remove() }
    }
}
