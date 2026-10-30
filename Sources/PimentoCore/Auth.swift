import Foundation

/// The signed-in user, read from the ARM access token's claims.
public struct Identity: Equatable, Sendable {
    public let objectId: String
    public let name: String?
    public let upn: String?
    public let tenantId: String?

    public init(objectId: String, name: String?, upn: String?, tenantId: String?) {
        self.objectId = objectId
        self.name = name
        self.upn = upn
        self.tenantId = tenantId
    }

    public var displayName: String { name ?? upn ?? objectId }
}

public enum JWT {
    /// Decodes the (unverified) claims of a JWT. We only read our own token to
    /// find our object id; ARM verifies it, we don't need to.
    public static func claims(_ token: String) -> [String: Any]? {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2 else { return nil }
        var b64 = parts[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        b64 += String(repeating: "=", count: (4 - b64.count % 4) % 4)
        guard let data = Data(base64Encoded: b64),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return object
    }

    public static func identity(fromToken token: String) -> Identity? {
        guard let c = claims(token), let oid = c["oid"] as? String, !oid.isEmpty else { return nil }
        return Identity(
            objectId: oid,
            name: c["name"] as? String,
            upn: (c["upn"] as? String) ?? (c["unique_name"] as? String) ?? (c["preferred_username"] as? String),
            tenantId: c["tid"] as? String
        )
    }
}

public protocol TokenProvider: Sendable {
    /// A fresh ARM bearer token. Implementations must not persist or log it.
    func accessToken() async throws -> String
}

public enum AzureCLIError: Error, LocalizedError, Equatable {
    case notFound
    case failed(String)
    case timedOut
    case emptyToken

    /// The command that most likely fixes a token error.
    public static func loginCommand(tenant: String?) -> String {
        guard let tenant, !tenant.isEmpty else { return "az login" }
        return "az login --tenant \(tenant)"
    }

    public var errorDescription: String? {
        switch self {
        case .notFound:
            "Azure CLI (az) not found. \(AzureCLI.installHint())"
        case .failed(let stderr):
            "az could not get an access token for Azure Resource Manager.\n\n" + stderr
        case .timedOut:
            "az did not answer within 90 seconds."
        case .emptyToken:
            "az returned an empty token."
        }
    }

    /// True when re-running `az login` is the likely fix.
    public var needsLogin: Bool {
        switch self {
        case .failed, .emptyToken, .timedOut: true
        case .notFound: false
        }
    }
}

/// Runs the user's `az` binary. Arguments are passed as an argv array, never
/// through a shell (on Windows, see `launch`).
public enum AzureCLI {
    /// Tried before `$PATH` on macOS: apps launched from Finder get a minimal PATH.
    public static let candidatePaths = ["/opt/homebrew/bin/az", "/usr/local/bin/az"]

    /// How to install the Azure CLI here.
    public static func installHint(platform: HostPlatform = .current) -> String {
        switch platform {
        case .macOS: "Install it with `brew install azure-cli`."
        case .linux: "Install it from https://learn.microsoft.com/cli/azure/install-azure-cli-linux."
        case .windows: "Install it with `winget install -e --id Microsoft.AzureCLI`."
        }
    }

    /// The names `az` has in a `PATH` folder: `az`; on Windows `az.cmd` (the
    /// installer's), `az.bat` (pip) or `az.exe`.
    static func executableNames(platform: HostPlatform) -> [String] {
        platform == .windows ? ["az.cmd", "az.bat", "az.exe"] : ["az"]
    }

    /// `PATH` (`Path` on Windows, where variable names ignore case).
    static func searchPath(_ environment: [String: String], platform: HostPlatform) -> String {
        if let path = environment["PATH"] { return path }
        guard platform == .windows else { return "" }
        return environment.first { $0.key.uppercased() == "PATH" }?.value ?? ""
    }

    /// Finds `az`: on macOS in the usual Homebrew locations first, then in
    /// `$PATH`. Only absolute `PATH` folders count: an empty or relative entry
    /// (`.`, `bin`) means the current directory, where anyone who can write
    /// there could leave an `az`. On macOS and Linux the file and its folder
    /// must belong to root or you and be writable by nobody else
    /// (`isTrusted`); otherwise the next candidate is tried.
    public static func locate(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        platform: HostPlatform = .current,
        isExecutable: (String) -> Bool = AzureCLI.isExecutable,
        isTrusted: (String) -> Bool = AzureCLI.isTrusted
    ) -> String? {
        if platform == .macOS {
            for path in candidatePaths where isExecutable(path) && isTrusted(path) { return path }
        }
        for dir in searchPath(environment, platform: platform).split(separator: platform.pathListSeparator) {
            let folder = platform == .windows ? String(dir).trimmingCharacters(in: CharacterSet(charactersIn: "\"")) : String(dir)
            guard isAbsolute(folder, platform: platform) else { continue }
            for name in executableNames(platform: platform) {
                let path = platform.join(folder, name)
                if isExecutable(path) && isTrusted(path) { return path }
            }
        }
        return nil
    }

    /// `/…` on macOS and Linux; `C:\…`, `C:/…` or `\\server\…` on Windows.
    static func isAbsolute(_ path: String, platform: HostPlatform) -> Bool {
        guard platform == .windows else { return path.hasPrefix("/") }
        if path.hasPrefix(#"\\"#) { return true }
        let chars = Array(path)
        return chars.count >= 3 && chars[0].isASCII && chars[0].isLetter && chars[1] == ":" && (chars[2] == "\\" || chars[2] == "/")
    }

    /// The real file and its folder belong to root or you, and nobody else
    /// may change them (`PathTrust`). Always true on Windows (ACLs).
    public static func isTrusted(_ path: String) -> Bool {
        #if os(Windows)
        return true
        #else
        let real = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        let folder = URL(fileURLWithPath: real).deletingLastPathComponent().path
        return [real, folder].allSatisfy { PathTrust.info(at: $0).map { PathTrust.isTrusted($0, user: PathTrust.currentUser) } ?? false }
        #endif
    }

    private static let resolvedLock = NSLock()
    nonisolated(unsafe) private static var resolved: String?

    /// `locate()`, once: the absolute path found first is used for every
    /// later run of this process (as long as it is still there), so a
    /// changed `PATH` or a new `az` earlier on it cannot swap it.
    public static func resolvedPath() -> String? {
        resolvedLock.withLock {
            if let resolved, isExecutable(resolved) { return resolved }
            resolved = locate()
            return resolved
        }
    }

    /// An executable file; on Windows any file (az.cmd has no execute bit).
    public static func isExecutable(_ path: String) -> Bool {
        #if os(Windows)
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && !isDirectory.boolValue
        #else
        return FileManager.default.isExecutableFile(atPath: path)
        #endif
    }

    /// What to start for `az arguments`. Elsewhere `az` itself. On Windows,
    /// `az.cmd` is a batch file, which CreateProcess cannot run and cmd.exe
    /// would parse (with its own quoting rules). So the installer's layout
    /// (`…\wbin\az.cmd` next to `…\python.exe`) runs Python directly, the way
    /// az.cmd does; another batch file goes through `cmd.exe /d /c` only when
    /// every argument is plain (letters, digits and `._:/@=-`), else it is refused.
    public static func launch(
        az: String, arguments: [String], platform: HostPlatform = .current,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) throws -> (executable: String, arguments: [String]) {
        let lower = az.lowercased()
        guard platform == .windows, lower.hasSuffix(".cmd") || lower.hasSuffix(".bat") else { return (az, arguments) }
        func parent(_ path: Substring) -> Substring? {
            path.lastIndex(where: { $0 == "\\" || $0 == "/" }).map { path[..<$0] }
        }
        // Only the installer's own layout: `<CLI2>\wbin\az.cmd` beside `<CLI2>\python.exe`.
        if let bin = parent(Substring(az)), let root = parent(bin), !root.isEmpty,
           bin.split(whereSeparator: { $0 == "\\" || $0 == "/" }).last?.lowercased() == "wbin" {
            let python = platform.join(String(root), "python.exe")
            if fileExists(python) { return (python, ["-IBm", "azure.cli"] + arguments) }
        }
        let plain = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._:/@=-")
        guard arguments.allSatisfy({ !$0.isEmpty && $0.unicodeScalars.allSatisfy(plain.contains) }) else {
            throw AzureCLIError.failed("Refusing to pass these arguments through cmd.exe to \(az).")
        }
        // cmd.exe parses the batch file's path too: absolute, and none of its special characters.
        let special = CharacterSet(charactersIn: "\"%^&|<>!\r\n")
        guard isAbsolute(az, platform: platform), az.rangeOfCharacter(from: special) == nil else {
            throw AzureCLIError.failed("Refusing to run \(az) through cmd.exe: not an absolute path without special characters.")
        }
        let windows = environment.first { $0.key.uppercased() == "SYSTEMROOT" }?.value ?? #"C:\Windows"#
        let system = platform.join(windows, "System32", "cmd.exe")
        let comspec = environment.first { $0.key.uppercased() == "COMSPEC" }?.value
        let cmd = comspec.flatMap { isAbsolute($0, platform: platform) && $0.lowercased().hasSuffix("\\cmd.exe") ? $0 : nil } ?? system
        return (cmd, ["/d", "/c", az] + arguments)
    }

    /// The most `az` may write to stdout (a long `account list`) and stderr;
    /// beyond that it is ended and the run fails.
    static let maxOutput = 16 << 20
    static let maxErrorOutput = 1 << 20

    /// Runs `az` with `arguments` off the main thread and returns its stdout.
    /// Cancelling the task ends `az` and everything it started.
    public static func run(_ arguments: [String], azPath: String? = nil, timeout: TimeInterval = 90) async throws -> Data {
        try NetworkGuard.check("the Azure CLI (az \(arguments.prefix(2).joined(separator: " ")))")
        guard let az = azPath ?? resolvedPath() else { throw AzureCLIError.notFound }
        let control = RunControl()
        let data = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    continuation.resume(with: Result { try runSync(az: az, arguments: arguments, timeout: timeout, control: control) })
                }
            }
        } onCancel: {
            control.cancel()
        }
        try Task.checkCancellation()
        return data
    }

    /// The running `az` and whether its task was cancelled, between the task
    /// and the thread that waits for `az`.
    final class RunControl: @unchecked Sendable {
        private let lock = NSLock()
        private var process: Process?
        private var cancelled = false

        /// Registers `process`; false (and it is not started) when already cancelled.
        func start(_ process: Process) -> Bool {
            lock.withLock {
                guard !cancelled else { return false }
                self.process = process
                return true
            }
        }

        func cancel() {
            let running = lock.withLock { () -> Process? in
                cancelled = true
                return process
            }
            if let running, running.isRunning { _ = terminateTree(running) }
        }

        var isCancelled: Bool { lock.withLock { cancelled } }
    }

    /// Set from another thread: the pipe reader and the timeout.
    private final class Box<T>: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: T
        init(_ value: T) { stored = value }
        var value: T {
            get { lock.withLock { stored } }
            set { lock.withLock { stored = newValue } }
        }
    }

    /// The `PATH` az runs with (its `#!/usr/bin/env bash` and Python look
    /// things up in it): your absolute folders, then the usual system ones;
    /// empty and relative entries (the current directory) are dropped.
    static func childPath(_ path: String?) -> String {
        let extra = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        let own = (path ?? "").split(separator: ":").map(String.init).filter { $0.hasPrefix("/") }
        return (own + extra).joined(separator: ":")
    }

    /// Reads `handle` to its end, keeping at most `limit` bytes; `overflow`
    /// runs once when more arrives (the rest is read and dropped, so the
    /// writer is never blocked on a full pipe).
    static func read(_ handle: FileHandle, limit: Int, overflow: () -> Void) -> (data: Data, overflowed: Bool) {
        var data = Data()
        var overflowed = false
        while true {
            let chunk = handle.availableData
            if chunk.isEmpty { break }
            if overflowed { continue }
            if data.count + chunk.count > limit {
                overflowed = true
                overflow()
                continue
            }
            data += chunk
        }
        return (data, overflowed)
    }

    private static func runSync(az: String, arguments: [String], timeout: TimeInterval, control: RunControl = RunControl()) throws -> Data {
        let platform = HostPlatform.current
        var env = ProcessInfo.processInfo.environment
        let (executable, argv) = try launch(az: az, arguments: arguments, platform: platform, environment: env)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = argv
        if platform != .windows {
            env["PATH"] = childPath(env["PATH"])
        } else if executable.lowercased().hasSuffix("python.exe") {
            env["AZ_INSTALLER"] = "MSI" // what az.cmd sets
        }
        env["AZURE_CORE_NO_COLOR"] = "1"
        env["AZURE_CORE_COLLECT_TELEMETRY"] = "0"
        process.environment = env
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice
        guard control.start(process) else { throw CancellationError() }
        do { try process.run() } catch { throw AzureCLIError.failed(error.localizedDescription) }
        // Cancelled between registering and starting: end it now.
        if control.isCancelled { control.cancel() }

        // Drain both pipes concurrently so neither can fill up and block az.
        let errData = Box(Data()), timedOut = Box(false), tooMuch = Box(false)
        let escalation = Box<DispatchWorkItem?>(nil)
        let endForOverflow = {
            tooMuch.value = true
            escalation.value = terminateTree(process)
        }
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            errData.value = read(err.fileHandleForReading, limit: maxErrorOutput, overflow: endForOverflow).data
            group.leave()
        }
        let killer = DispatchWorkItem {
            guard process.isRunning else { return }
            timedOut.value = true
            escalation.value = terminateTree(process)
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
        let outData = read(out.fileHandleForReading, limit: maxOutput, overflow: endForOverflow).data
        process.waitUntilExit()
        group.wait()
        killer.cancel()
        // Everything that held the pipes is gone: no SIGKILL for a group id
        // that may be reused later.
        escalation.value?.cancel()

        if control.isCancelled { throw CancellationError() }
        if timedOut.value { throw AzureCLIError.timedOut }
        if tooMuch.value { throw AzureCLIError.failed("az wrote more than \(maxOutput >> 20) MB; it was ended.") }
        if process.terminationReason == .uncaughtSignal {
            throw AzureCLIError.failed("az was ended by signal \(process.terminationStatus).")
        }
        guard process.terminationStatus == 0 else {
            let stderr = String(decoding: errData.value, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw AzureCLIError.failed(stderr.isEmpty ? "az exited with status \(process.terminationStatus)" : stderr)
        }
        return outData
    }
}

extension AzureCLI {
    /// Ends `process` and everything it started. `terminate()` alone ends
    /// only the process itself (az's wrapper script, or cmd.exe), and a
    /// Python child still holding the output pipe would keep the read
    /// waiting long past the timeout.
    ///
    /// - macOS, Linux: Foundation starts the process in a process group of its
    ///   own; the group gets SIGTERM, and SIGKILL 3 s later if any of it is
    ///   left. (Should the process not lead its own group, only it is ended:
    ///   never signal Pimento's own group.)
    /// - Windows: `taskkill /T /F` ends the process tree.
    ///
    /// Returns the scheduled SIGKILL, for the caller to cancel once the
    /// group has let go of the pipes (its id may be reused afterwards).
    @discardableResult
    static func terminateTree(_ process: Process) -> DispatchWorkItem? {
        let pid = process.processIdentifier
        guard pid > 0 else { return nil }
        #if os(Windows)
        let system = ProcessInfo.processInfo.environment.first { $0.key.uppercased() == "SYSTEMROOT" }?.value ?? #"C:\Windows"#
        let taskkill = Process()
        taskkill.executableURL = URL(fileURLWithPath: HostPlatform.windows.join(system, "System32", "taskkill.exe"))
        taskkill.arguments = ["/T", "/F", "/PID", String(pid)]
        taskkill.standardInput = FileHandle.nullDevice
        taskkill.standardOutput = FileHandle.nullDevice
        taskkill.standardError = FileHandle.nullDevice
        if (try? taskkill.run()) != nil { taskkill.waitUntilExit() }
        if process.isRunning { process.terminate() }
        return nil
        #else
        guard getpgid(pid) == pid, pid != getpgrp() else {
            // Not a group leader (or already reaped): end only the process.
            if process.isRunning { process.terminate() }
            return nil
        }
        kill(-pid, SIGTERM)
        let escalate = DispatchWorkItem {
            if kill(-pid, 0) == 0 { kill(-pid, SIGKILL) }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 3, execute: escalate)
        return escalate
        #endif
    }
}

/// Borrows the token from the user's own `az` session: activations are made
/// as the user, exactly like in the portal.
public struct AzureCLITokenProvider: TokenProvider {
    /// `nil` uses the tenant of az's current account (`az account show`).
    public let tenantId: String?
    public let azPath: String?

    public init(tenantId: String? = nil, azPath: String? = nil) {
        self.tenantId = tenantId
        self.azPath = azPath
    }

    public func arguments() -> [String] {
        var args = ["account", "get-access-token"]
        if let tenantId, !tenantId.isEmpty { args += ["--tenant", tenantId] }
        return args + ["--resource", ARM.resource, "--query", "accessToken", "--output", "tsv", "--only-show-errors"]
    }

    public func accessToken() async throws -> String {
        let data = try await AzureCLI.run(arguments(), azPath: azPath)
        let token = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { throw AzureCLIError.emptyToken }
        return token
    }
}
