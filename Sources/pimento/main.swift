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
    makeService: { tenantId, readOnly in
        // The token comes from `az` on demand, stays in memory, and goes only
        // to management.azure.com. Read-only commands cannot send a write.
        let transport: HTTPTransport = readOnly ? ReadOnlyTransport(URLSessionTransport()) : URLSessionTransport()
        return PIMService(transport: transport, tokens: AzureCLITokenProvider(tenantId: tenantId))
    },
    loadTenants: { preferred in
        try await TenantDirectory.load(preferredTenant: preferred, transport: ReadOnlyTransport(URLSessionTransport()))
    },
    // Shared with the app; $PIMENTO_HISTORY points elsewhere.
    history: HistoryStore(environment: ProcessInfo.processInfo.environment)
)

// A closed pipe (`pimento list | head`) should end quietly, not crash.
signal(SIGPIPE, SIG_IGN)

let status = await CLIRunner(environment: environment).run(Array(CommandLine.arguments.dropFirst()))
exit(status)
