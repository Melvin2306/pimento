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

    /// Finds `az`: on macOS in the usual Homebrew locations first, then in `$PATH`.
    public static func locate(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        platform: HostPlatform = .current,
        isExecutable: (String) -> Bool = AzureCLI.isExecutable
    ) -> String? {
        if platform == .macOS {
            for path in candidatePaths where isExecutable(path) { return path }
        }
        for dir in searchPath(environment, platform: platform).split(separator: platform.pathListSeparator) where !dir.isEmpty {
            let folder = platform == .windows ? String(dir).trimmingCharacters(in: CharacterSet(charactersIn: "\"")) : String(dir)
            for name in executableNames(platform: platform) {
                let path = platform.join(folder, name)
                if isExecutable(path) { return path }
            }
        }
        return nil
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
        if let bin = parent(Substring(az)), let root = parent(bin), !root.isEmpty {
            let python = platform.join(String(root), "python.exe")
            if fileExists(python) { return (python, ["-IBm", "azure.cli"] + arguments) }
        }
        let plain = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._:/@=-")
        guard arguments.allSatisfy({ !$0.isEmpty && $0.unicodeScalars.allSatisfy(plain.contains) }) else {
            throw AzureCLIError.failed("Refusing to pass these arguments through cmd.exe to \(az).")
        }
        let windows = environment.first { $0.key.uppercased() == "SYSTEMROOT" }?.value ?? #"C:\Windows"#
        let cmd = environment.first { $0.key.uppercased() == "COMSPEC" }?.value ?? platform.join(windows, "System32", "cmd.exe")
        return (cmd, ["/d", "/c", az] + arguments)
    }

    /// Runs `az` with `arguments` off the main thread and returns its stdout.
    public static func run(_ arguments: [String], azPath: String? = nil, timeout: TimeInterval = 90) async throws -> Data {
        try NetworkGuard.check("the Azure CLI (az \(arguments.prefix(2).joined(separator: " ")))")
        guard let az = azPath ?? locate() else { throw AzureCLIError.notFound }
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Result { try runSync(az: az, arguments: arguments, timeout: timeout) })
            }
        }
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

    private static func runSync(az: String, arguments: [String], timeout: TimeInterval) throws -> Data {
        let platform = HostPlatform.current
        var env = ProcessInfo.processInfo.environment
        let (executable, argv) = try launch(az: az, arguments: arguments, platform: platform, environment: env)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = argv
        if platform != .windows {
            let extra = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
            env["PATH"] = env["PATH"].map { "\($0):\(extra)" } ?? extra
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
        do { try process.run() } catch { throw AzureCLIError.failed(error.localizedDescription) }

        // Drain both pipes concurrently so neither can fill up and block az.
        let errData = Box(Data()), timedOut = Box(false)
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            errData.value = err.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        let killer = DispatchWorkItem {
            guard process.isRunning else { return }
            timedOut.value = true
            terminateTree(process)
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        group.wait()
        killer.cancel()

        if timedOut.value { throw AzureCLIError.timedOut }
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
    static func terminateTree(_ process: Process) {
        let pid = process.processIdentifier
        guard pid > 0 else { return }
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
        #else
        guard getpgid(pid) == pid, pid != getpgrp() else {
            // Not a group leader (or already reaped): end only the process.
            if process.isRunning { process.terminate() }
            return
        }
        kill(-pid, SIGTERM)
        DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
            if kill(-pid, 0) == 0 { kill(-pid, SIGKILL) }
        }
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
