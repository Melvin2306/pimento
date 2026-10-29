import Foundation

/// Where Azure access tokens come from.
public enum AuthSource: String, Codable, CaseIterable, Sendable {
    /// The user's Azure CLI session (`az account get-access-token`). The default.
    case az
    /// Pimento's own sign-in (Microsoft identity platform, public client).
    case pimento

    public var title: String {
        switch self {
        case .az: "Azure CLI"
        case .pimento: "Pimento sign-in"
        }
    }

    /// `az` (also `azure-cli`, `cli`) or `pimento`, any case.
    public init?(argument: String) {
        switch argument.trimmingCharacters(in: .whitespaces).lowercased() {
        case "az", "azure-cli", "azurecli", "cli": self = .az
        case "pimento", "signin", "sign-in": self = .pimento
        default: return nil
        }
    }
}

/// The auth source in use, and where that choice came from.
public struct AuthSelection: Equatable, Sendable {
    public enum Origin: String, Sendable {
        case commandLine, environment, saved, `default`
    }

    public let source: AuthSource
    public let origin: Origin

    public init(source: AuthSource, origin: Origin) {
        self.source = source
        self.origin = origin
    }

    /// Set outside the app (flag or environment); Settings cannot change it.
    public var isOverride: Bool { origin == .commandLine || origin == .environment }
}

public enum AuthSourceError: Error, Equatable, LocalizedError {
    case invalid(String)

    public var errorDescription: String? {
        switch self {
        case .invalid(let v): "“\(v)” is not an auth source. Use az or pimento."
        }
    }
}

public enum AuthSourceResolver {
    public static let environmentVariable = "PIMENTO_AUTH"
    public static let clientIdVariable = "PIMENTO_CLIENT_ID"

    /// Order: `--auth`, `$PIMENTO_AUTH`, the saved setting, then the Azure CLI.
    /// An invalid flag or environment value throws.
    public static func resolve(commandLine: String?, environment: [String: String], saved: AuthSource?) throws -> AuthSelection {
        if let flag = clean(commandLine) {
            guard let source = AuthSource(argument: flag) else { throw AuthSourceError.invalid(flag) }
            return AuthSelection(source: source, origin: .commandLine)
        }
        if let value = clean(environment[environmentVariable]) {
            guard let source = AuthSource(argument: value) else { throw AuthSourceError.invalid(value) }
            return AuthSelection(source: source, origin: .environment)
        }
        if let saved { return AuthSelection(source: saved, origin: .saved) }
        return AuthSelection(source: .az, origin: .default)
    }

    /// Order: `--client-id`, `$PIMENTO_CLIENT_ID`, the saved setting, then
    /// the one the signed-in account was obtained with. Lower-cased GUID.
    public static func clientId(commandLine: String?, environment: [String: String], saved: String?, account: String? = nil) throws -> String {
        for candidate in [clean(commandLine), clean(environment[clientIdVariable])] {
            guard let value = candidate else { continue }
            guard MicrosoftIdentity.isValidClientId(value) else { throw SignInError.invalidClientId(value) }
            return value.lowercased()
        }
        for candidate in [clean(saved), clean(account)] {
            if let value = candidate, MicrosoftIdentity.isValidClientId(value) { return value.lowercased() }
        }
        throw SignInError.missingClientId
    }

    static func clean(_ s: String?) -> String? {
        let t = s?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (t?.isEmpty ?? true) ? nil : t
    }
}

/// Sign-in settings shared by the app and the CLI. No secrets: the refresh
/// tokens are in the token store.
public struct AuthSettings: Codable, Equatable, Sendable {
    public var source: AuthSource?
    /// The app registration's client ID.
    public var clientId: String?
    /// The account used for tokens (`SignedInAccount.id`); nil: the most recent.
    public var accountId: String?
    /// A claims challenge Azure answered with (MFA, Conditional Access): sent
    /// with the next browser sign-in, then cleared. Not a secret.
    public var claimsChallenge: String?

    public init(source: AuthSource? = nil, clientId: String? = nil, accountId: String? = nil, claimsChallenge: String? = nil) {
        self.source = source
        self.clientId = clientId
        self.accountId = accountId
        self.claimsChallenge = claimsChallenge
    }

    private enum CodingKeys: String, CodingKey { case source, clientId, accountId, claimsChallenge }

    /// Unknown sources and malformed IDs read as unset.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        source = (try? c.decodeIfPresent(String.self, forKey: .source)).flatMap { $0.flatMap(AuthSource.init(rawValue:)) }
        clientId = (try? c.decodeIfPresent(String.self, forKey: .clientId))?.flatMap { MicrosoftIdentity.isValidClientId($0) ? $0.lowercased() : nil }
        accountId = try? c.decodeIfPresent(String.self, forKey: .accountId)
        claimsChallenge = (try? c.decodeIfPresent(String.self, forKey: .claimsChallenge))?.flatMap { ClaimsChallenge.isJSONObject($0) ? $0 : nil }
    }
}

/// `auth.json` next to the presets, in `PimentoPaths.dataDirectory`, mode 600
/// (where there are POSIX modes).
public struct AuthSettingsStore: Sendable {
    public let url: URL

    public init(url: URL) { self.url = url }

    public init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.init(url: Self.location(environment: environment))
    }

    public static func location(
        environment: [String: String], home: String = NSHomeDirectory(), platform: HostPlatform = .current
    ) -> URL {
        URL(fileURLWithPath: platform.join(
            PimentoPaths.dataDirectoryPath(environment: environment, home: home, platform: platform), "auth.json"))
    }

    /// The saved settings; empty when the file is missing or unreadable.
    public func load() -> AuthSettings {
        guard let data = try? Data(contentsOf: url), let settings = try? JSONDecoder().decode(AuthSettings.self, from: data) else {
            return AuthSettings()
        }
        return settings
    }

    public func save(_ settings: AuthSettings) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try PrivateFile.write(try encoder.encode(settings), to: url)
    }

    /// Reads, changes and writes back the settings.
    @discardableResult
    public func update(_ change: (inout AuthSettings) -> Void) throws -> AuthSettings {
        var settings = load()
        change(&settings)
        try save(settings)
        return settings
    }
}
