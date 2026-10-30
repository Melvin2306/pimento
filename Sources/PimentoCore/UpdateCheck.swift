import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// The update check: one GET of GitHub's "latest release" of the repository,
// compared with `AppInfo.version`. It only tells: nothing is downloaded or
// installed. The answer is untrusted: the tag must be a strict semantic
// version, drafts and pre-releases are ignored, and the links Pimento opens
// are built from the version on github.com/Melvin2306/pimento, never taken
// from the JSON.

/// A semantic version (semver.org 2.0.0), parsed strictly: `1.2.3`,
/// `1.2.3-rc.1`, optionally `+build` (ignored, as semver says).
public struct SemanticVersion: Comparable, Hashable, Sendable, CustomStringConvertible {
    public let major: Int
    public let minor: Int
    public let patch: Int
    /// The pre-release identifiers (`["rc", "1"]`); empty for a release.
    public let prerelease: [String]

    /// Longer strings are refused before parsing.
    public static let maxLength = 64
    /// Digits per numeric identifier (no overflow, no absurd numbers).
    static let maxDigits = 9

    /// nil unless `text` is a valid semantic version. `allowPrefix`: accept a
    /// leading `v` (tags); `allowBuild`: accept `+build` metadata.
    public init?(_ text: String, allowPrefix: Bool = false, allowBuild: Bool = true) {
        guard !text.isEmpty, text.utf8.count <= Self.maxLength, text.allSatisfy({ $0.isASCII }) else { return nil }
        var rest = Substring(text)
        if allowPrefix, rest.first == "v" { rest = rest.dropFirst() }
        if let plus = rest.firstIndex(of: "+") {
            guard allowBuild else { return nil }
            let build = rest[rest.index(after: plus)...]
            guard Self.identifiers(build, numericRule: false) != nil else { return nil }
            rest = rest[..<plus]
        }
        var pre: [String] = []
        if let dash = rest.firstIndex(of: "-") {
            guard let ids = Self.identifiers(rest[rest.index(after: dash)...], numericRule: true) else { return nil }
            pre = ids
            rest = rest[..<dash]
        }
        let core = rest.split(separator: ".", omittingEmptySubsequences: false)
        guard core.count == 3, let major = Self.number(core[0]), let minor = Self.number(core[1]), let patch = Self.number(core[2])
        else { return nil }
        self.major = major
        self.minor = minor
        self.patch = patch
        prerelease = pre
    }

    public init(_ major: Int, _ minor: Int, _ patch: Int, prerelease: [String] = []) {
        self.major = major
        self.minor = minor
        self.patch = patch
        self.prerelease = prerelease
    }

    public var isPrerelease: Bool { !prerelease.isEmpty }

    /// `1.2.3` or `1.2.3-rc.1` (no build metadata).
    public var description: String {
        "\(major).\(minor).\(patch)" + (prerelease.isEmpty ? "" : "-" + prerelease.joined(separator: "."))
    }

    /// Semver precedence: the numbers, then a release above its pre-releases,
    /// then the pre-release identifiers one by one (numeric ones numerically
    /// and below alphanumeric ones; a shorter list first when all else is equal).
    public static func < (a: SemanticVersion, b: SemanticVersion) -> Bool {
        if (a.major, a.minor, a.patch) != (b.major, b.minor, b.patch) {
            return (a.major, a.minor, a.patch) < (b.major, b.minor, b.patch)
        }
        switch (a.prerelease.isEmpty, b.prerelease.isEmpty) {
        case (true, true), (true, false): return false
        case (false, true): return true
        case (false, false): break
        }
        for (x, y) in zip(a.prerelease, b.prerelease) where x != y {
            switch (Int(x), Int(y)) {
            case let (i?, j?): return i < j
            case (.some, nil): return true
            case (nil, .some): return false
            case (nil, nil): return x < y
            }
        }
        return a.prerelease.count < b.prerelease.count
    }

    /// A numeric identifier: digits only, no leading zero, at most `maxDigits`.
    private static func number(_ s: Substring) -> Int? {
        guard !s.isEmpty, s.count <= maxDigits, s.allSatisfy({ ("0"..."9").contains($0) }), s == "0" || s.first != "0" else { return nil }
        return Int(s)
    }

    /// Dot-separated, non-empty `[0-9A-Za-z-]` identifiers; with
    /// `numericRule`, a numeric one has no leading zero.
    private static func identifiers(_ s: Substring, numericRule: Bool) -> [String]? {
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        guard !parts.isEmpty else { return nil }
        for part in parts {
            guard !part.isEmpty, part.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }) else { return nil }
            if numericRule, part.allSatisfy({ ("0"..."9").contains($0) }), part.count > 1, part.first == "0" { return nil }
        }
        return parts.map(String.init)
    }
}

/// A published release, reduced to what Pimento uses. Its links are built
/// from the version on `UpdateCheck.repositoryPrefix`.
public struct ReleaseInfo: Equatable, Sendable, Codable {
    public let version: SemanticVersion
    /// When GitHub says it was published (shown only; nil when absent or unreadable).
    public let publishedAt: Date?
    /// The disk image of the release (`Pimento-<version>.dmg`, else `Pimento.dmg`),
    /// when its asset list has one.
    public let diskImageName: String?

    public init(version: SemanticVersion, publishedAt: Date? = nil, diskImageName: String? = nil) {
        self.version = version
        self.publishedAt = publishedAt
        self.diskImageName = diskImageName
    }

    /// The tag Pimento's releases use: `v1.2.3`.
    public var tag: String { "v\(version)" }

    /// `https://github.com/Melvin2306/pimento/releases/tag/v1.2.3`.
    public var releasePageURL: URL { URL(string: UpdateCheck.repositoryPrefix + "releases/tag/" + tag)! }

    /// `https://github.com/Melvin2306/pimento/releases/download/v1.2.3/Pimento-1.2.3.dmg`.
    public var diskImageURL: URL? {
        diskImageName.map { URL(string: UpdateCheck.repositoryPrefix + "releases/download/" + tag + "/" + $0)! }
    }

    enum CodingKeys: String, CodingKey { case version, publishedAt, diskImageName }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let text = try c.decode(String.self, forKey: .version)
        guard let version = SemanticVersion(text) else {
            throw DecodingError.dataCorruptedError(forKey: .version, in: c, debugDescription: "not a semantic version")
        }
        self.version = version
        publishedAt = try c.decodeIfPresent(Date.self, forKey: .publishedAt)
        let name = try c.decodeIfPresent(String.self, forKey: .diskImageName)
        diskImageName = name.flatMap { UpdateCheck.diskImageNames(for: version).contains($0) ? $0 : nil }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(version.description, forKey: .version)
        try c.encodeIfPresent(publishedAt, forKey: .publishedAt)
        try c.encodeIfPresent(diskImageName, forKey: .diskImageName)
    }
}

/// What a check found.
public struct UpdateCheckResult: Equatable, Sendable {
    public let current: SemanticVersion
    /// nil: the repository has no published (non-draft, non-pre-release) release.
    public let latest: ReleaseInfo?

    public init(current: SemanticVersion, latest: ReleaseInfo?) {
        self.current = current
        self.latest = latest
    }

    /// The latest release when it is newer than this build.
    public var update: ReleaseInfo? { latest.flatMap { $0.version > current ? $0 : nil } }
}

public enum UpdateCheckError: Error, LocalizedError, Equatable {
    /// `PIMENTO_NO_UPDATE_CHECK` or demo mode: no request was made.
    case disabled(String)
    /// GitHub answered with another status than 200 (or 404: no release).
    case http(Int)
    /// GitHub's API rate limit for this address (HTTP 403 or 429).
    case rateLimited
    /// The answer was not the release JSON Pimento expects.
    case invalidResponse(String)
    /// No answer in time, or a network error.
    case network(String)

    public var errorDescription: String? {
        switch self {
        case .disabled(let why): why
        case .http(let status): "GitHub answered HTTP \(status)."
        case .rateLimited: "GitHub's rate limit for unauthenticated requests is used up for now. Try again in an hour."
        case .invalidResponse(let why): "GitHub's answer was not understood (\(why))."
        case .network(let message): message
        }
    }
}

public enum UpdateCheck {
    /// The only URL the check requests.
    public static let endpoint = URL(string: "https://api.github.com/repos/Melvin2306/pimento/releases/latest")!
    /// Links Pimento opens must start with this.
    public static let repositoryPrefix = "https://github.com/Melvin2306/pimento/"
    /// `PIMENTO_NO_UPDATE_CHECK=1` turns the check off, in the app and the CLI.
    public static let disableVariable = "PIMENTO_NO_UPDATE_CHECK"
    /// The automatic check runs at most this often.
    public static let interval: TimeInterval = 24 * 60 * 60
    /// Per request (no data for this long: give up).
    public static let timeout: TimeInterval = 10
    /// The whole check, however slowly the answer arrives.
    public static let deadline: TimeInterval = 20
    /// A larger answer is refused (a release's JSON is a few kilobytes).
    public static let maxResponseBytes = 1 << 20

    /// The only header that says who asks (GitHub's API requires a User-Agent).
    public static var userAgent: String { "Pimento/\(AppInfo.version)" }

    /// The installer one-liners (README › Install the command-line tool).
    public static let installScript = "curl -fsSL https://raw.githubusercontent.com/Melvin2306/pimento/main/scripts/install.sh | sh"
    public static let installPowerShell = "irm https://raw.githubusercontent.com/Melvin2306/pimento/main/scripts/install.ps1 | iex"

    public static func installCommand(platform: HostPlatform = .current) -> String {
        platform == .windows ? installPowerShell : installScript
    }

    /// Why checks are off: `PIMENTO_NO_UPDATE_CHECK` set to 1/true/yes/on,
    /// or demo mode (offline by design). nil: checks may run.
    public static func disabledReason(environment: [String: String], demo: Bool) -> String? {
        if demo { return "Demo mode is offline: Pimento does not check for updates." }
        if DemoMode.isOn(environment[disableVariable]) { return "Update checks are turned off by \(disableVariable)." }
        return nil
    }

    /// Whether the automatic check is due: never checked, a day or more ago,
    /// or a "last check" in the future (the clock was set back).
    public static func isDue(lastCheck: Date?, now: Date, interval: TimeInterval = interval) -> Bool {
        guard let lastCheck else { return true }
        let elapsed = now.timeIntervalSince(lastCheck)
        return elapsed >= interval || elapsed < -60
    }

    /// When the next automatic check is due.
    public static func nextCheck(after lastCheck: Date?, now: Date, interval: TimeInterval = interval) -> Date {
        guard let lastCheck, !isDue(lastCheck: lastCheck, now: now, interval: interval) else { return now }
        return lastCheck.addingTimeInterval(interval)
    }

    /// Whether Pimento may open `url`: HTTPS on github.com, inside the
    /// repository, without credentials, port, query tricks or `..`.
    public static func isAllowedToOpen(_ url: URL) -> Bool {
        guard let c = URLComponents(url: url, resolvingAgainstBaseURL: false), c.scheme == "https",
              c.host?.lowercased() == "github.com", c.port == nil, c.user == nil, c.password == nil,
              c.query == nil, c.fragment == nil
        else { return false }
        let path = c.percentEncodedPath
        let prefix = "/Melvin2306/pimento/"
        guard path.lowercased().hasPrefix(prefix.lowercased()), !path.contains("%"), !path.contains("//") else { return false }
        return !path.split(separator: "/").contains { $0 == ".." || $0 == "." }
    }

    /// The GET the check sends: no cookies, no cache, no credentials; only
    /// `User-Agent: Pimento/<version>` and the API's media type.
    public static func request() -> URLRequest {
        var r = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: timeout)
        r.httpMethod = "GET"
        r.httpShouldHandleCookies = false
        r.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        r.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        r.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        return r
    }

    /// The disk image names a release of `version` may have, preferred first.
    static func diskImageNames(for version: SemanticVersion) -> [String] { ["Pimento-\(version).dmg", "Pimento.dmg"] }

    /// The release JSON, decoded with only the fields Pimento reads.
    struct ReleaseJSON: Decodable {
        struct Asset: Decodable { let name: String? }
        let tag_name: String?
        let draft: Bool?
        let prerelease: Bool?
        let published_at: String?
        let assets: [Asset]?
    }

    /// Reads GitHub's answer: nil when there is no published release (404,
    /// or the "latest" is a draft or pre-release, which `latest` should never
    /// be). Anything unexpected throws.
    public static func parse(_ data: Data, status: Int) throws -> ReleaseInfo? {
        switch status {
        case 200: break
        case 404: return nil
        case 403, 429: throw UpdateCheckError.rateLimited
        default: throw UpdateCheckError.http(status)
        }
        guard data.count <= maxResponseBytes else { throw UpdateCheckError.invalidResponse("more than \(maxResponseBytes / 1024) KB") }
        let json: ReleaseJSON
        do { json = try JSONDecoder().decode(ReleaseJSON.self, from: data) } catch {
            throw UpdateCheckError.invalidResponse("not a release")
        }
        guard let tag = json.tag_name else { throw UpdateCheckError.invalidResponse("no tag") }
        if json.draft == true || json.prerelease == true { return nil }
        guard let version = SemanticVersion(tag, allowPrefix: true, allowBuild: false) else {
            throw UpdateCheckError.invalidResponse("the tag is not a version")
        }
        // A tag like v1.0.0-rc.1 published as a release is still a pre-release.
        if version.isPrerelease { return nil }
        let names = Set((json.assets ?? []).compactMap(\.name))
        let image = diskImageNames(for: version).first { names.contains($0) }
        let published = json.published_at.flatMap { $0.utf8.count <= 40 ? AzureDate.parse($0) : nil }
        return ReleaseInfo(version: version, publishedAt: published, diskImageName: image)
    }

    /// Asks GitHub for the latest release and compares it with `current`.
    /// `transport` is wrapped in `UpdateCheckTransport`, so the request can
    /// only be the GET of `endpoint`.
    public static func check(current: String = AppInfo.version, transport: HTTPTransport,
                             deadline: TimeInterval = deadline) async throws -> UpdateCheckResult {
        guard let currentVersion = SemanticVersion(current) else {
            throw UpdateCheckError.invalidResponse("this build's version \(current) is not a semantic version")
        }
        let guarded = transport is UpdateCheckTransport ? transport : UpdateCheckTransport(transport)
        let (data, status): (Data, Int)
        do {
            (data, status) = try await withDeadline(deadline) { try await guarded.send(request()) }
        } catch let error as UpdateCheckError {
            throw error
        } catch let error as NetworkGuard.Blocked {
            throw UpdateCheckError.disabled(error.localizedDescription)
        } catch is CancellationError {
            throw UpdateCheckError.network("The check was cancelled.")
        } catch {
            throw UpdateCheckError.network(error.localizedDescription)
        }
        return UpdateCheckResult(current: currentVersion, latest: try parse(data, status: status))
    }

    /// `operation`, or `UpdateCheckError.network` after `seconds`.
    static func withDeadline<T: Sendable>(_ seconds: TimeInterval, _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
                throw UpdateCheckError.network("GitHub did not answer within \(Int(seconds)) seconds.")
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw CancellationError() }
            return first
        }
    }
}

/// Wraps a transport and refuses anything but the GET of
/// `UpdateCheck.endpoint`, so the check cannot be turned into another request.
public struct UpdateCheckTransport: HTTPTransport {
    public struct Refused: Error, LocalizedError, Equatable {
        public let url: String
        public var errorDescription: String? { "Refused to send an update check to \(url)." }
    }

    let base: HTTPTransport

    public init(_ base: HTTPTransport = URLSessionTransport()) { self.base = base }

    public func send(_ request: URLRequest) async throws -> (Data, Int) {
        guard request.httpMethod ?? "GET" == "GET", request.url == UpdateCheck.endpoint, request.httpBody == nil else {
            throw Refused(url: request.url?.absoluteString ?? "?")
        }
        return try await base.send(request)
    }
}

/// The last automatic or manual check, kept between launches (the app's
/// defaults): when it ran and what it found.
public struct UpdateCheckRecord: Equatable, Sendable, Codable {
    /// The last attempt, successful or not (the next automatic one waits a day).
    public var checkedAt: Date
    /// What the last successful check found; nil: no published release (or
    /// no check has worked yet).
    public var latest: ReleaseInfo?
    /// Why the last attempt failed; nil when it worked.
    public var error: String?

    public init(checkedAt: Date, latest: ReleaseInfo?, error: String? = nil) {
        self.checkedAt = checkedAt
        self.latest = latest
        self.error = error
    }

    /// The record after a check at `date`: its result, or the error with the
    /// last known release kept.
    public func updated(at date: Date, with result: Result<UpdateCheckResult, Error>) -> UpdateCheckRecord {
        switch result {
        case .success(let r): UpdateCheckRecord(checkedAt: date, latest: r.latest)
        case .failure(let e): UpdateCheckRecord(checkedAt: date, latest: latest, error: e.localizedDescription)
        }
    }

    /// The release to offer: newer than `current` and not dismissed.
    public func update(current: String = AppInfo.version, dismissed: String? = nil) -> ReleaseInfo? {
        guard let latest, let current = SemanticVersion(current), latest.version > current else { return nil }
        if let dismissed, SemanticVersion(dismissed) == latest.version { return nil }
        return latest
    }

    enum Key {
        static let record = "updates.lastCheck"
        static let dismissed = "updates.dismissedVersion"
    }

    /// The stored record; nil when there is none or it does not decode.
    public static func load(from store: PreferenceStore) -> UpdateCheckRecord? {
        guard let data = store.object(forKey: Key.record) as? Data else { return nil }
        return try? JSONDecoder().decode(UpdateCheckRecord.self, from: data)
    }

    public func save(to store: PreferenceStore) {
        if let data = try? JSONEncoder().encode(self) { store.set(data, forKey: Key.record) }
    }

    /// The version whose notice was dismissed (it stays hidden until a newer one).
    public static func dismissedVersion(in store: PreferenceStore) -> String? {
        (store.object(forKey: Key.dismissed) as? String).flatMap { SemanticVersion($0)?.description }
    }

    public static func setDismissedVersion(_ version: String?, in store: PreferenceStore) {
        if let version { store.set(version, forKey: Key.dismissed) } else { store.removeObject(forKey: Key.dismissed) }
    }
}

/// The update check's texts, for the app and the CLI.
public enum UpdateText {
    /// "Pimento 0.2.0 is available."
    public static func available(_ release: ReleaseInfo, appName: String = AppInfo.name) -> String {
        "\(appName) \(release.version) is available."
    }

    /// The details under it: the running version and how to update.
    public static func availableDetails(_ release: ReleaseInfo, current: String = AppInfo.version) -> String {
        "You have \(current). Download the new version and drag it onto Applications to replace this one. "
            + "Nothing is downloaded or installed automatically."
    }

    /// The manual check's answer when there is nothing newer.
    public static func upToDate(current: String = AppInfo.version, latest: ReleaseInfo?) -> String {
        guard let latest, let mine = SemanticVersion(current), latest.version < mine else {
            return "\(AppInfo.name) \(current) is the latest version."
        }
        return "\(AppInfo.name) \(current) is newer than the latest release (\(latest.version))."
    }

    /// Settings › General: what the last check found and when.
    public static func status(record: UpdateCheckRecord?, current: String = AppInfo.version, now: Date,
                              calendar: Calendar = .autoupdatingCurrent, locale: Locale = .autoupdatingCurrent) -> String {
        guard let record else { return "Not checked yet." }
        let when = checkedLabel(record.checkedAt, now: now, calendar: calendar, locale: locale)
        if let error = record.error { return "Could not check \(when): \(error)" }
        if let update = record.update(current: current) {
            return "\(AppInfo.name) \(update.version) is available (this is \(current)). Checked \(when)."
        }
        return "\(AppInfo.name) \(current) is up to date. Checked \(when)."
    }

    /// "today at 10:32", "yesterday at 09:00", "on 28 Oct 2026".
    public static func checkedLabel(_ date: Date, now: Date, calendar: Calendar = .autoupdatingCurrent,
                                    locale: Locale = .autoupdatingCurrent) -> String {
        var cal = calendar
        cal.locale = locale
        let time = date.formatted(Date.FormatStyle(date: .omitted, time: .shortened, locale: locale, calendar: cal, timeZone: cal.timeZone))
        if cal.isDate(date, inSameDayAs: now) { return "today at \(time)" }
        if let yesterday = cal.date(byAdding: .day, value: -1, to: now), cal.isDate(date, inSameDayAs: yesterday) {
            return "yesterday at \(time)"
        }
        return "on " + date.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted, locale: locale, calendar: cal, timeZone: cal.timeZone))
    }

    /// `pimento version --check`: current and latest version, and how to update.
    /// `bundledWithApp`: this `pimento` is the one inside Pimento.app.
    public static func cliReport(_ result: UpdateCheckResult, platform: HostPlatform = .current, bundledWithApp: Bool = false) -> [String] {
        let date: (Date?) -> String = { d in
            d.map { " (released \(AzureDate.format($0).prefix(10)))" } ?? ""
        }
        var lines = ["current  \(result.current)"]
        guard let latest = result.latest else {
            lines.append("latest   none published yet")
            lines.append("pimento is up to date.")
            return lines
        }
        lines.append("latest   \(latest.version)\(date(latest.publishedAt))")
        guard let update = result.update else {
            lines.append(latest.version == result.current ? "pimento is up to date." : "pimento is up to date (newer than the latest release).")
            return lines
        }
        lines.append("")
        lines.append("A newer version is available: \(update.releasePageURL.absoluteString)")
        if bundledWithApp {
            lines.append("This pimento is the one inside Pimento.app: update the app (Pimento.dmg from the release page),")
            lines.append("and the command line tool is updated with it.")
        } else {
            lines.append("To update, re-run the installer:")
            lines.append("  \(UpdateCheck.installCommand(platform: platform))")
        }
        return lines
    }

    /// Whether `executablePath` is inside an app bundle (`….app/Contents/…`).
    public static func isBundledWithApp(_ executablePath: String?) -> Bool {
        guard let path = executablePath else { return false }
        return path.contains(".app/Contents/")
    }
}
