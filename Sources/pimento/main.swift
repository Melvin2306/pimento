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
#if os(macOS)
import CoreServices
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

/// Redirect pages written for the browser; removed when sign-in is over.
let redirectPages = RedirectPages()

/// Opens the sign-in page; false when that fails. The authorize URL (state,
/// nonce, PKCE challenge) never becomes a process argument, where other local
/// users could read it: macOS asks LaunchServices directly (no child process);
/// Linux runs `xdg-open` (from PATH) on a private redirect page that holds the
/// URL (`BrowserLaunch`); Windows hands that page's path to `ShellExecuteW`
/// (the default browser, through the `.html` file association): no shell
/// string, no `cmd.exe`, and the URL in no command line.
func openInBrowser(_ url: URL) -> Bool {
    #if os(macOS)
    return LSOpenCFURLRef(url as CFURL, nil) == noErr
    #elseif os(Windows)
    guard let page = BrowserLaunch.openThroughPage(url, open: { path in
        // The shell may hand the file to a COM-based handler: COM must be set
        // up on this thread (and is undone again if this call set it up).
        let com = CoInitializeEx(nil, DWORD(COINIT_APARTMENTTHREADED.rawValue) | DWORD(COINIT_DISABLE_OLE1DDE.rawValue))
        defer { if com >= 0 { CoUninitialize() } }
        let result = path.withCString(encodedAs: UTF16.self) { file in
            "open".withCString(encodedAs: UTF16.self) { verb in
                ShellExecuteW(nil, verb, file, nil, nil, SW_SHOWNORMAL)
            }
        }
        // ShellExecute reports success as a value above 32.
        return Int(bitPattern: result) > 32
    }) else { return false }
    redirectPages.add(page)
    return true
    #else
    // Absolute PATH folders only: an empty or relative entry is the current directory.
    let path = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"
    let tool = (path.split(separator: ":").filter { $0.hasPrefix("/") }.map { "\($0)/xdg-open" } + ["/usr/bin/xdg-open"])
        .first { FileManager.default.isExecutableFile(atPath: $0) && AzureCLI.isTrusted($0) }
    guard let tool else { return false }
    guard let page = BrowserLaunch.openThroughPage(url, open: { file in
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = [file]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }) else { return false }
    redirectPages.add(page)
    return true
    #endif
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

/// Raw bytes from stdin for `pimento mcp`'s bounded line reader; retried
/// when a signal interrupts the read. On Windows fd 0 is in text mode, as
/// `readLine` reads it.
@Sendable func readStdin(_ buffer: UnsafeMutableRawPointer, _ count: Int) -> Int {
    #if os(Windows)
    return Int(_read(0, buffer, UInt32(min(count, Int(Int32.max)))))
    #else
    while true {
        let n = read(0, buffer, count)
        if n < 0, errno == EINTR { continue }
        return n
    }
    #endif
}

var environment = CLIEnvironment(
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
        openURL: { url in BrowserLaunch.guarded(url, openInBrowser) },
        endBrowserSignIn: { redirectPages.removeAll() })
)

environment.readInput = readStdin
// Only `pimento version --check` uses it: one GET of GitHub's latest release
// (UpdateCheckTransport refuses anything else). No other command goes online.
environment.updateTransport = UpdateCheckTransport()
// The app's bundled CLI is updated with the app, not with the installer.
environment.executablePath = Bundle.main.executableURL?.resolvingSymlinksInPath().path

#if !os(Windows)
// A closed pipe (`pimento list | head`) should end quietly, not crash.
signal(SIGPIPE, SIG_IGN)
#endif

let arguments = Array(CommandLine.arguments.dropFirst())
// Demo mode never reaches the network: block it for the whole process.
if (try? CLIParser.parse(arguments))?.demo == true || DemoMode.isOn(variables[DemoMode.environmentVariable]) {
    NetworkGuard.blockForProcess()
}
let status = await CLIRunner(environment: environment).run(arguments)
redirectPages.removeAll()
exit(status)
