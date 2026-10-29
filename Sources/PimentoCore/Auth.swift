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
            "Azure CLI (az) not found. Install it with `brew install azure-cli`."
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
/// through a shell.
public enum AzureCLI {
    public static let candidatePaths = ["/opt/homebrew/bin/az", "/usr/local/bin/az"]

    /// Finds `az` in the usual Homebrew locations, then `$PATH`. Apps launched
    /// from Finder get a minimal PATH, hence the fixed candidates first.
    public static func locate(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> String? {
        for path in candidatePaths where isExecutable(path) { return path }
        for dir in (environment["PATH"] ?? "").split(separator: ":") where !dir.isEmpty {
            let path = "\(dir)/az"
            if isExecutable(path) { return path }
        }
        return nil
    }

    /// Runs `az` with `arguments` off the main thread and returns its stdout.
    public static func run(_ arguments: [String], azPath: String? = nil, timeout: TimeInterval = 90) async throws -> Data {
        guard let az = azPath ?? locate() else { throw AzureCLIError.notFound }
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Result { try runSync(az: az, arguments: arguments, timeout: timeout) })
            }
        }
    }

    private static func runSync(az: String, arguments: [String], timeout: TimeInterval) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: az)
        process.arguments = arguments
        var env = ProcessInfo.processInfo.environment
        let extra = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        env["PATH"] = env["PATH"].map { "\($0):\(extra)" } ?? extra
        env["AZURE_CORE_NO_COLOR"] = "1"
        env["AZURE_CORE_COLLECT_TELEMETRY"] = "0"
        process.environment = env
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { throw AzureCLIError.failed(error.localizedDescription) }

        // Drain both pipes concurrently so neither can fill up and block az.
        var errData = Data()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            errData = err.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        let killer = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        group.wait()
        killer.cancel()

        if process.terminationReason == .uncaughtSignal { throw AzureCLIError.timedOut }
        guard process.terminationStatus == 0 else {
            let stderr = String(decoding: errData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw AzureCLIError.failed(stderr.isEmpty ? "az exited with status \(process.terminationStatus)" : stderr)
        }
        return outData
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
