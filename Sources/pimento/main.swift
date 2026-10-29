// The `pimento` command-line tool. Foundation and PimentoCore only, no AppKit,
// so it stays small (and could build on Linux). All logic is in
// PimentoCore/CLI; this file wires it to the real terminal and network.
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import PimentoCore

func terminalWidth() -> Int? {
    var size = winsize()
    if ioctl(STDOUT_FILENO, UInt(TIOCGWINSZ), &size) == 0, size.ws_col > 0 { return Int(size.ws_col) }
    return ProcessInfo.processInfo.environment["COLUMNS"].flatMap(Int.init)
}

let stdoutIsTTY = isatty(STDOUT_FILENO) != 0

/// `open URL` on macOS, `xdg-open URL` elsewhere; false when that fails.
func openInBrowser(_ url: URL) -> Bool {
    #if os(macOS)
    let tool = "/usr/bin/open"
    #else
    let tool = "/usr/bin/xdg-open"
    #endif
    guard FileManager.default.isExecutableFile(atPath: tool) else { return false }
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

let environment = CLIEnvironment(
    write: { text, stream in
        let handle = stream == .out ? FileHandle.standardOutput : FileHandle.standardError
        handle.write(Data(text.utf8))
    },
    readLine: { Swift.readLine(strippingNewline: true) },
    stdoutIsTTY: stdoutIsTTY,
    stderrIsTTY: isatty(STDERR_FILENO) != 0,
    stdinIsTTY: isatty(STDIN_FILENO) != 0,
    terminalWidth: stdoutIsTTY ? terminalWidth() : nil,
    variables: ProcessInfo.processInfo.environment,
    makeService: { tokens, readOnly in
        // Tokens come from `az` or Pimento's sign-in on demand, stay in memory,
        // and go only to management.azure.com. Read-only commands cannot send a write.
        let transport: HTTPTransport = readOnly ? ReadOnlyTransport(URLSessionTransport()) : URLSessionTransport()
        return PIMService(transport: transport, tokens: tokens)
    },
    loadTenants: { preferred, tokens in
        let transport = ReadOnlyTransport(URLSessionTransport())
        guard let tokens else { return try await TenantDirectory.load(preferredTenant: preferred, transport: transport) }
        return TenantDirectory.sorted(try await TenantDirectory.fetchARM(tokens: tokens, transport: transport))
    },
    // Shared with the app; $PIMENTO_HISTORY points elsewhere.
    history: HistoryStore(environment: ProcessInfo.processInfo.environment),
    // Pimento's own sign-in: settings shared with the app, refresh tokens in the
    // Keychain (or ~/.config/pimento/tokens.json), sign-in data only to
    // login.microsoftonline.com.
    signIn: CLISignIn(
        settings: AuthSettingsStore(),
        store: TokenStores.standard(),
        transport: URLSessionTransport(),
        openURL: { url in openInBrowser(url) })
)

// A closed pipe (`pimento list | head`) should end quietly, not crash.
signal(SIGPIPE, SIG_IGN)

let status = await CLIRunner(environment: environment).run(Array(CommandLine.arguments.dropFirst()))
exit(status)
