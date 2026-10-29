import Foundation

/// One eligibility in a preset, identified by scope + role definition
/// (compared case-insensitively, by role GUID). The names are only for display,
/// for example when the eligibility no longer exists.
public struct PresetRole: Codable, Hashable, Sendable {
    public var scope: String
    public var roleDefinitionId: String
    public var roleName: String?
    public var scopeName: String?

    public init(scope: String, roleDefinitionId: String, roleName: String? = nil, scopeName: String? = nil) {
        self.scope = scope
        self.roleDefinitionId = roleDefinitionId
        self.roleName = roleName
        self.scopeName = scopeName
    }

    public init(_ role: EligibleRole) {
        self.init(scope: role.scope, roleDefinitionId: role.roleDefinitionId, roleName: role.roleName, scopeName: role.scopeName)
    }

    public var key: RoleMatcher.Key { RoleMatcher.key(scope: scope, roleDefinitionId: roleDefinitionId) }

    /// `Owner · Contoso Production`.
    public var label: String {
        "\(roleName ?? RoleMatcher.lastPathComponent(roleDefinitionId)) · \(scopeName ?? RoleMatcher.lastPathComponent(scope))"
    }
}

/// A pattern in a preset: the same selection as `pimento list FILTER… --role NAME`.
/// It picks whatever matches at activation time.
public struct PresetRule: Codable, Hashable, Sendable {
    /// Resource filters, OR-ed: a name substring, or an ARM scope prefix when it starts with `/`.
    public var filters: [String]
    /// Role names, OR-ed, whole name, `*` as wildcard.
    public var roles: [String]

    public init(filters: [String] = [], roles: [String] = []) {
        self.filters = filters
        self.roles = roles
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        filters = try c.decodeIfPresent([String].self, forKey: .filters) ?? []
        roles = try c.decodeIfPresent([String].self, forKey: .roles) ?? []
    }

    public var criteria: RoleCriteria { RoleCriteria(filters: filters, roles: roles) }

    /// A rule without filters or roles would match everything: never stored.
    public var isEmpty: Bool { filters.isEmpty && roles.isEmpty }

    /// `prod staging --role Owner`, as typed on the command line.
    public var label: String {
        (filters.map { $0.contains(" ") ? "\"\($0)\"" : $0 } + roles.map { "--role \($0.contains(" ") ? "\"\($0)\"" : $0)" })
            .joined(separator: " ")
    }
}

/// A named set of eligibilities with an optional default justification and
/// duration ("On-call": all Owner roles on the production subscriptions).
public struct Preset: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    /// The tenant (GUID) the preset belongs to; nil means any tenant.
    public var tenantId: String?
    /// Exact eligibilities.
    public var roles: [PresetRole]
    /// Patterns, resolved at activation time.
    public var match: [PresetRule]
    public var justification: String?
    public var duration: RequestedDuration?
    public var createdAt: Date?
    public var updatedAt: Date?

    public init(
        id: UUID = UUID(), name: String, tenantId: String?, roles: [PresetRole] = [], match: [PresetRule] = [],
        justification: String? = nil, duration: RequestedDuration? = nil, createdAt: Date? = nil, updatedAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.tenantId = tenantId
        self.roles = roles
        self.match = match
        self.justification = justification
        self.duration = duration
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    enum CodingKeys: String, CodingKey {
        case id, name, tenantId, roles, match, justification, duration, createdAt, updatedAt
    }

    /// Lenient: unknown keys are ignored, a missing id gets a new one, and an
    /// unreadable duration is dropped rather than failing the whole file.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decodeIfPresent(UUID.self, forKey: .id)) ?? UUID()
        name = try c.decode(String.self, forKey: .name)
        tenantId = try c.decodeIfPresent(String.self, forKey: .tenantId)
        roles = try c.decodeIfPresent([PresetRole].self, forKey: .roles) ?? []
        match = (try c.decodeIfPresent([PresetRule].self, forKey: .match) ?? []).filter { !$0.isEmpty }
        justification = try c.decodeIfPresent(String.self, forKey: .justification)
        duration = (try? c.decodeIfPresent(String.self, forKey: .duration)).flatMap { $0.flatMap(RequestedDuration.init(stringValue:)) }
        createdAt = try? c.decodeIfPresent(Date.self, forKey: .createdAt)
        updatedAt = try? c.decodeIfPresent(Date.self, forKey: .updatedAt)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encodeIfPresent(tenantId, forKey: .tenantId)
        try c.encode(roles, forKey: .roles)
        if !match.isEmpty { try c.encode(match, forKey: .match) }
        try c.encodeIfPresent(justification?.nonEmpty, forKey: .justification)
        try c.encodeIfPresent(duration?.stringValue, forKey: .duration)
        try c.encodeIfPresent(createdAt, forKey: .createdAt)
        try c.encodeIfPresent(updatedAt, forKey: .updatedAt)
    }

    /// True for presets of `tenantId`, presets for any tenant, and every
    /// preset when the tenant is not known yet.
    public func applies(toTenant tenantId: String?) -> Bool {
        guard let mine = self.tenantId, let tenantId else { return true }
        return mine.caseInsensitiveCompare(tenantId) == .orderedSame
    }

    public var trimmedJustification: String? {
        justification?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
    }

    /// `3 roles`, `2 roles + 1 rule`.
    public var summary: String {
        var parts = ["\(roles.count) role\(roles.count == 1 ? "" : "s")"]
        if !match.isEmpty { parts.append("\(match.count) rule\(match.count == 1 ? "" : "s")") }
        return parts.joined(separator: " + ")
    }

    /// The preset's roles among `rows` (the current eligibilities).
    public func resolve(in rows: [EligibleRole]) -> PresetResolution {
        // Prefer direct eligibilities when a scope + role is held twice.
        var byKey: [RoleMatcher.Key: EligibleRole] = [:]
        for row in rows {
            if let existing = byKey[row.policyKey], existing.membership == .direct || row.membership != .direct { continue }
            byKey[row.policyKey] = row
        }
        var picked: [RoleMatcher.Key] = []
        var seen = Set<RoleMatcher.Key>()
        var missing: [PresetRole] = []
        for item in roles {
            if byKey[item.key] != nil {
                if seen.insert(item.key).inserted { picked.append(item.key) }
            } else if !missing.contains(where: { $0.key == item.key }) {
                missing.append(item)
            }
        }
        var unmatched: [PresetRule] = []
        for rule in match {
            let hits = rows.filter(rule.criteria.matches).map(\.policyKey)
            if hits.isEmpty { unmatched.append(rule) }
            for key in hits where seen.insert(key).inserted { picked.append(key) }
        }
        let order = Dictionary(rows.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { a, _ in a })
        let resolved = picked.compactMap { byKey[$0] }.sorted { (order[$0.id] ?? 0) < (order[$1.id] ?? 0) }
        return PresetResolution(roles: resolved, missing: missing, unmatchedRules: unmatched)
    }
}

/// A preset applied to the current eligibilities.
public struct PresetResolution: Equatable, Sendable {
    /// Every eligibility the preset picks, active ones included, in table order.
    public var roles: [EligibleRole]
    /// Exact roles that are no longer among your eligibilities.
    public var missing: [PresetRole]
    /// Rules that match nothing right now.
    public var unmatchedRules: [PresetRule]

    public var eligible: [EligibleRole] { roles.filter { !$0.isActive } }
    public var active: [EligibleRole] { roles.filter(\.isActive) }
}

public enum PresetError: Error, Equatable, LocalizedError {
    case emptyName
    case duplicateName(String)
    case notFound(String)
    case ambiguous(String, tenants: [String])
    case otherTenant(String, tenantId: String)
    case noRoles
    case unsupportedVersion(Int)
    case unreadable(String)

    public var errorDescription: String? {
        switch self {
        case .emptyName: "A preset needs a name."
        case .duplicateName(let n): "A preset named “\(n)” already exists in this tenant."
        case .notFound(let n): "No preset named “\(n)”. `pimento presets list` shows the saved ones."
        case .ambiguous(let n, let tenants):
            "There are presets named “\(n)” in \(tenants.count) tenants (\(tenants.joined(separator: ", "))). Pick one with --tenant."
        case .otherTenant(let n, let t): "The preset “\(n)” belongs to tenant \(t). Use --tenant \(t)."
        case .noRoles: "A preset needs at least one role or rule."
        case .unsupportedVersion(let v):
            "The presets file was written by a newer Pimento (format \(v); this one reads up to \(PresetLibrary.currentVersion)). Update Pimento."
        case .unreadable(let why): "Could not read the presets file: \(why)"
        }
    }
}

/// Every saved preset: the contents of the presets file. A plain value;
/// `PresetStore` reads and writes it.
public struct PresetLibrary: Equatable, Sendable {
    public static let currentVersion = 1

    public var presets: [Preset]

    public init(presets: [Preset] = []) { self.presets = presets }

    /// The presets that apply to `tenantId`, sorted by name.
    public func presets(forTenant tenantId: String?) -> [Preset] {
        presets.filter { $0.applies(toTenant: tenantId) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    public static func sameName(_ a: String, _ b: String) -> Bool {
        a.trimmingCharacters(in: .whitespaces).caseInsensitiveCompare(b.trimmingCharacters(in: .whitespaces)) == .orderedSame
    }

    /// Presets with this name (case-insensitive) in any tenant.
    public func named(_ name: String) -> [Preset] { presets.filter { Self.sameName($0.name, name) } }

    /// The preset called `name` for `tenantId`. Without a tenant, the name must
    /// be unique. Errors say whether it exists elsewhere.
    public func find(_ name: String, tenantId: String?) throws -> Preset {
        let all = named(name)
        guard !all.isEmpty else { throw PresetError.notFound(name) }
        if let tenantId {
            if let exact = all.first(where: { $0.tenantId?.caseInsensitiveCompare(tenantId) == .orderedSame }) { return exact }
            if let any = all.first(where: { $0.tenantId == nil }) { return any }
            throw PresetError.otherTenant(all[0].name, tenantId: all[0].tenantId ?? "")
        }
        guard all.count == 1 else { throw PresetError.ambiguous(all[0].name, tenants: all.map { $0.tenantId ?? "any" }) }
        return all[0]
    }

    /// Adds or updates `preset` (by id). Names are unique per tenant; with
    /// `replacing`, a preset of the same name in the same tenant is replaced.
    @discardableResult
    public mutating func save(_ preset: Preset, replacing: Bool = false, now: Date = Date()) throws -> Preset {
        var p = preset
        p.name = p.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !p.name.isEmpty else { throw PresetError.emptyName }
        guard !p.roles.isEmpty || !p.match.isEmpty else { throw PresetError.noRoles }
        let clash = presets.first { $0.id != p.id && Self.sameName($0.name, p.name) && Self.sameTenant($0.tenantId, p.tenantId) }
        if let clash {
            guard replacing else { throw PresetError.duplicateName(p.name) }
            presets.removeAll { $0.id == clash.id }
            p.createdAt = p.createdAt ?? clash.createdAt
        }
        p.updatedAt = now
        if let i = presets.firstIndex(where: { $0.id == p.id }) {
            p.createdAt = p.createdAt ?? presets[i].createdAt
            presets[i] = p
        } else {
            p.createdAt = p.createdAt ?? now
            presets.append(p)
        }
        return p
    }

    public mutating func rename(_ id: UUID, to name: String, now: Date = Date()) throws {
        guard var p = presets.first(where: { $0.id == id }) else { return }
        p.name = name
        try save(p, now: now)
    }

    public mutating func delete(_ id: UUID) { presets.removeAll { $0.id == id } }

    public static func sameTenant(_ a: String?, _ b: String?) -> Bool {
        switch (a, b) {
        case (nil, nil): true
        case let (x?, y?): x.caseInsensitiveCompare(y) == .orderedSame
        default: false
        }
    }

    // MARK: File format

    struct File: Codable {
        var version: Int
        var presets: [Preset]
    }

    /// `{"version": 1, "presets": [...]}`. A newer format is refused, so an
    /// older Pimento never rewrites (and loses) what a newer one stored.
    public static func decode(_ data: Data) throws -> PresetLibrary {
        struct Header: Decodable { let version: Int? }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let header: Header
        do { header = try decoder.decode(Header.self, from: data) } catch { throw PresetError.unreadable(error.localizedDescription) }
        let version = header.version ?? 1
        guard version <= currentVersion else { throw PresetError.unsupportedVersion(version) }
        do {
            return PresetLibrary(presets: try decoder.decode(File.self, from: data).presets)
        } catch {
            throw PresetError.unreadable(String(describing: error))
        }
    }

    public func encoded() -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return (try? encoder.encode(File(version: Self.currentVersion, presets: presets))) ?? Data()
    }
}

/// The presets file, shared by the app and the CLI:
/// `~/Library/Application Support/Pimento/presets.json`, or `$PIMENTO_PRESETS`.
public struct PresetStore: Sendable {
    public static let environmentVariable = "PIMENTO_PRESETS"

    public let url: URL

    public init(url: URL) { self.url = url }

    public init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.init(url: Self.location(environment: environment))
    }

    public static func location(environment: [String: String], home: String = NSHomeDirectory()) -> URL {
        if let custom = environment[environmentVariable]?.trimmingCharacters(in: .whitespaces), !custom.isEmpty {
            let expanded = custom == "~" ? home : custom.hasPrefix("~/") ? home + custom.dropFirst() : custom
            return URL(fileURLWithPath: expanded)
        }
        #if os(macOS)
        let base = URL(fileURLWithPath: home).appendingPathComponent("Library/Application Support", isDirectory: true)
        #else
        let base = environment["XDG_DATA_HOME"].map { URL(fileURLWithPath: $0) }
            ?? URL(fileURLWithPath: home).appendingPathComponent(".local/share", isDirectory: true)
        #endif
        return base.appendingPathComponent("Pimento", isDirectory: true).appendingPathComponent("presets.json")
    }

    /// The saved presets; an empty library when the file does not exist yet.
    public func load() throws -> PresetLibrary {
        guard FileManager.default.fileExists(atPath: url.path) else { return PresetLibrary() }
        let data: Data
        do { data = try Data(contentsOf: url) } catch { throw PresetError.unreadable(error.localizedDescription) }
        if data.allSatisfy({ $0 == 0x20 || $0 == 0x0A || $0 == 0x0D || $0 == 0x09 }) { return PresetLibrary() }
        return try PresetLibrary.decode(data)
    }

    /// Writes atomically, readable only by you.
    public func save(_ library: PresetLibrary) throws {
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try library.encoded().write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    /// Reads the file, applies `change` and writes it back, so that a preset
    /// saved meanwhile by the CLI or the app is not lost.
    @discardableResult
    public func update<T>(_ change: (inout PresetLibrary) throws -> T) throws -> (PresetLibrary, T) {
        var library = try load()
        let result = try change(&library)
        try save(library)
        return (library, result)
    }
}
