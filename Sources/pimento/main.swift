// The `pimento` command-line tool. Foundation and PimentoCore only, no AppKit,
// so it stays small and builds on macOS, Linux and Windows. All logic is in
// PimentoCore/CLI; this file wires it to the real terminal and network.
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif os(Windows)
import ucrt
import WinSDK
#endif
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import PimentoCore

/// Whether file descriptor 0, 1 or 2 is a terminal (a console on Windows;
/// mintty and other pipes-based terminals count as no terminal there).
func isTerminal(_ fd: Int32) -> Bool {
    #if os(Windows)
    _isatty(fd) != 0
    #else
    isatty(fd) != 0
    #endif
}

func terminalWidth() -> Int? {
    #if os(Windows)
    var info = CONSOLE_SCREEN_BUFFER_INFO()
    if GetConsoleScreenBufferInfo(GetStdHandle(STD_OUTPUT_HANDLE), &info) {
        let width = Int(info.srWindow.Right) - Int(info.srWindow.Left) + 1
        if width > 0 { return width }
    }
    #else
    var size = winsize()
    if ioctl(STDOUT_FILENO, UInt(TIOCGWINSZ), &size) == 0, size.ws_col > 0 { return Int(size.ws_col) }
    #endif
    return ProcessInfo.processInfo.environment["COLUMNS"].flatMap(Int.init)
}

#if os(Windows)
/// Turns on ANSI escape sequences for a console handle (Windows 10 and
/// later); false when it is not a console or the console cannot do it.
func enableVirtualTerminal(_ which: DWORD) -> Bool {
    var mode: DWORD = 0
    guard let handle = GetStdHandle(which), handle != INVALID_HANDLE_VALUE, GetConsoleMode(handle, &mode) else { return false }
    if mode & DWORD(ENABLE_VIRTUAL_TERMINAL_PROCESSING) != 0 { return true }
    return SetConsoleMode(handle, mode | DWORD(ENABLE_VIRTUAL_TERMINAL_PROCESSING))
}

// Output is UTF-8 (·, ›, ✓); the console's code page usually is not.
_ = SetConsoleOutputCP(UINT(CP_UTF8))
#endif

let stdoutIsTTY = isTerminal(1)
let stderrIsTTY = isTerminal(2)
var variables = ProcessInfo.processInfo.environment
#if os(Windows)
// No colours on a console that cannot show them (`NO_COLOR` turns them off).
if (stdoutIsTTY && !enableVirtualTerminal(STD_OUTPUT_HANDLE)) || (stderrIsTTY && !enableVirtualTerminal(STD_ERROR_HANDLE)) {
    variables["NO_COLOR"] = "1"
}
#endif

/// `open URL` on macOS, `xdg-open URL` (from PATH) on Linux; false when that
/// fails. Windows has no browser sign-in yet (`LoopbackListener.isSupported`),
/// so nothing is opened there.
func openInBrowser(_ url: URL) -> Bool {
    #if os(macOS)
    let tool: String? = "/usr/bin/open"
    #elseif os(Windows)
    let tool: String? = nil
    #else
    let path = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"
    let tool = (path.split(separator: ":").map { "\($0)/xdg-open" } + ["/usr/bin/xdg-open"])
        .first { FileManager.default.isExecutableFile(atPath: $0) }
    #endif
    guard let tool, FileManager.default.isExecutableFile(atPath: tool) else { return false }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: tool)
    process.arguments = [url.absoluteString]
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    do { try process.run() } catch { return false }
    process.waitUntilExit()
    return process.terminationStatus == 0
}

/// EPIPE, as `FileHandle` reports it (directly or as the underlying error).
func isBrokenPipe(_ error: Error) -> Bool {
    let ns = error as NSError
    if ns.domain == NSPOSIXErrorDomain { return ns.code == Int(EPIPE) }
    if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError, underlying.domain == NSPOSIXErrorDomain {
        return underlying.code == Int(EPIPE)
    }
    return false
}

let environment = CLIEnvironment(
    write: { text, stream in
        let handle = stream == .out ? FileHandle.standardOutput : FileHandle.standardError
        // `write(_:)` raises an Objective-C exception on a closed pipe, which
        // Swift cannot catch; the throwing variant reports it.
        do { try handle.write(contentsOf: Data(text.utf8)) } catch {
            guard stream == .out else { return }
            // The reader went away (`pimento history --csv | head -1`): stop
            // quietly. Any other output error is one.
            exit(isBrokenPipe(error) ? 0 : 74)
        }
    },
    readLine: { Swift.readLine(strippingNewline: true) },
    stdoutIsTTY: stdoutIsTTY,
    stderrIsTTY: stderrIsTTY,
    stdinIsTTY: isTerminal(0),
    terminalWidth: stdoutIsTTY ? terminalWidth() : nil,
    variables: variables,
    // Tokens come from `az` or Pimento's sign-in on demand, stay in memory,
    // and go only to management.azure.com. Read-only commands cannot send a write.
    makeService: { tokens, readOnly in CLIEnvironment.liveService(tokens: tokens, readOnly: readOnly) },
    loadTenants: { preferred, tokens in try await CLIEnvironment.liveTenants(preferredTenant: preferred, tokens: tokens) },
    // Shared with the app; $PIMENTO_HISTORY points elsewhere.
    history: HistoryStore(environment: ProcessInfo.processInfo.environment),
    // Pimento's own sign-in: settings shared with the app, refresh tokens in the
    // Keychain on macOS (else the token file), sign-in data only to
    // login.microsoftonline.com.
    signIn: CLISignIn(
        settings: AuthSettingsStore(),
        store: TokenStores.standard(),
        transport: URLSessionTransport(),
        openURL: { url in openInBrowser(url) })
)

#if !os(Windows)
// A closed pipe (`pimento list | head`) should end quietly, not crash.
signal(SIGPIPE, SIG_IGN)
#endif

let status = await CLIRunner(environment: environment).run(Array(CommandLine.arguments.dropFirst()))
exit(status)
