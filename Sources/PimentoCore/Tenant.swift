import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Which Entra tenant to talk to, and where that choice came from.
public struct TenantSelection: Equatable, Sendable {
    public enum Source: String, Sendable {
        /// `--tenant <id>` on the command line.
        case commandLine
        /// The `PIMENTO_TENANT` environment variable.
        case environment
        /// Picked in the app and remembered.
        case saved
        /// Nothing chosen: use the tenant of az's current account.
        case azDefault
    }

    /// `nil` means "whatever az is currently signed in to".
    public let tenantId: String?
    public let source: Source

    public init(tenantId: String?, source: Source) {
        self.tenantId = tenantId
        self.source = source
    }

    /// Set outside the app (flag or environment); the UI cannot change it.
    public var isOverride: Bool { source == .commandLine || source == .environment }
}

public enum TenantError: Error, Equatable, LocalizedError {
    case invalid(String)

    public var errorDescription: String? {
        switch self {
        case .invalid(let value):
            "“\(value)” is not a tenant ID or domain. Use a GUID such as "
                + "00000000-0000-0000-0000-000000000000 or a domain such as contoso.onmicrosoft.com."
        }
    }
}

public enum TenantResolver {
    public static let environmentVariable = "PIMENTO_TENANT"

    /// A tenant GUID or a verified domain. The value ends up as an argv entry
    /// for az, so it must not look like a flag.
    public static func isValid(_ value: String) -> Bool {
        guard (1...253).contains(value.count), !value.hasPrefix("-"), !value.hasPrefix("."), !value.hasSuffix(".") else {
            return false
        }
        if UUID(uuidString: value) != nil { return true }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-")
        return value.contains(".") && value.unicodeScalars.allSatisfy(allowed.contains)
    }

    /// Order: command line, environment, saved setting, az's current tenant.
    /// An invalid flag or environment value throws; an invalid saved value is ignored.
    public static func resolve(
        commandLine: String?,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        saved: String?
    ) throws -> TenantSelection {
        func clean(_ s: String?) -> String? {
            let t = s?.trimmingCharacters(in: .whitespacesAndNewlines)
            return (t?.isEmpty ?? true) ? nil : t
        }
        let candidates: [(String?, TenantSelection.Source)] = [
            (clean(commandLine), .commandLine),
            (clean(environment[environmentVariable]), .environment),
            (clean(saved), .saved),
        ]
        for case let (value?, source) in candidates {
            if isValid(value) { return TenantSelection(tenantId: value, source: source) }
            if source != .saved { throw TenantError.invalid(value) }
        }
        return TenantSelection(tenantId: nil, source: .azDefault)
    }
}

/// A tenant the signed-in az user can reach.
public struct TenantInfo: Identifiable, Hashable, Sendable {
    /// Lower-case tenant GUID.
    public let id: String
    public let displayName: String?
    public let defaultDomain: String?
    /// ARM's `tenantCategory`: `Home`, `ProjectedBy` or `ManagedBy` (Azure Lighthouse).
    public let category: String?

    public init(id: String, displayName: String? = nil, defaultDomain: String? = nil, category: String? = nil) {
        self.id = id
        self.displayName = displayName
        self.defaultDomain = defaultDomain
        self.category = category
    }

    /// The display name, else the default domain; `nil` when az and ARM know neither.
    public var name: String? { displayName ?? defaultDomain }
    public var isNamed: Bool { name != nil }
    /// First block of the GUID, enough to tell unnamed tenants apart.
    public var shortId: String { String(id.prefix(8)) }

    /// What menus and the toolbar show: the name, or "Unnamed tenant 1a2b3c4d".
    public var label: String { name ?? "Unnamed tenant \(shortId)" }

    /// Secondary line: the domain when the name is the display name.
    public var detail: String? { displayName == nil ? nil : defaultDomain }

    /// True for tenants the user reaches through Azure Lighthouse delegation.
    public var isManaged: Bool { category?.caseInsensitiveCompare("ManagedBy") == .orderedSame }

    /// Case-insensitive match on name, domain or ID (empty query matches all).
    public func matches(_ query: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return true }
        return [displayName, defaultDomain, id].contains { $0?.localizedCaseInsensitiveContains(q) ?? false }
    }
}

/// Builds the tenant list from ARM's `/tenants` listing and az's local account cache.
public enum TenantDirectory {
    /// ARM's tenant listing. Unlike `az account tenant list`, it carries display
    /// names and domains for every tenant of the signed-in account.
    public static let armTenantsURL = URL(string: "\(ARM.baseURL)/tenants?api-version=2022-12-01")!
    static let maxPages = 20

    /// Parses `az account list --all --output json` (one entry per subscription)
    /// and/or `az account tenant list --output json` (one entry per tenant), and
    /// returns one entry per distinct tenant, sorted for display.
    public static func parse(_ documents: [Data]) -> [TenantInfo] {
        merge(documents.map(parseAzure))
    }

    /// One az document, unsorted, possibly with duplicates.
    static func parseAzure(_ data: Data) -> [TenantInfo] {
        struct Entry: Decodable {
            let tenantId: String?
            let tenantDisplayName: String?
            let tenantDefaultDomain: String?
            let displayName: String?
            let defaultDomain: String?
            let tenantCategory: String?
        }
        guard let entries = try? JSONDecoder().decode([Entry].self, from: data) else { return [] }
        return entries.compactMap { e in
            guard let id = normalizedId(e.tenantId) else { return nil }
            return TenantInfo(
                id: id,
                displayName: realName(e.tenantDisplayName) ?? realName(e.displayName),
                defaultDomain: realName(e.tenantDefaultDomain) ?? realName(e.defaultDomain),
                category: realName(e.tenantCategory))
        }
    }

    /// One page of ARM's `GET /tenants`. The next link is returned only when it
    /// points back to `management.azure.com` over HTTPS: the bearer token is
    /// never sent anywhere else.
    public static func parseARMPage(_ data: Data) -> (tenants: [TenantInfo], next: URL?)? {
        struct Item: Decodable {
            let tenantId: String?
            let displayName: String?
            let defaultDomain: String?
            let tenantCategory: String?
        }
        guard let page = try? JSONDecoder().decode(ARMList<Item>.self, from: data) else { return nil }
        let tenants = page.value.compactMap { item -> TenantInfo? in
            guard let id = normalizedId(item.tenantId) else { return nil }
            return TenantInfo(
                id: id, displayName: realName(item.displayName),
                defaultDomain: realName(item.defaultDomain), category: realName(item.tenantCategory))
        }
        let next = page.nextLink.flatMap(URL.init(string:)).flatMap { $0.scheme == "https" && $0.host == ARM.host ? $0 : nil }
        return (tenants, next)
    }

    /// Merges sources given in priority order (ARM first, then az's account
    /// list, then az's tenant list). Each field takes the first real value any
    /// source has, so a name from a later source still fills a gap. Sorted for
    /// display: by name, unnamed tenants last.
    public static func merge(_ sources: [[TenantInfo]]) -> [TenantInfo] {
        var order: [String] = []
        var byId: [String: TenantInfo] = [:]
        for tenant in sources.joined() {
            guard let existing = byId[tenant.id] else {
                order.append(tenant.id)
                byId[tenant.id] = tenant
                continue
            }
            byId[tenant.id] = TenantInfo(
                id: tenant.id,
                displayName: existing.displayName ?? tenant.displayName,
                defaultDomain: existing.defaultDomain ?? tenant.defaultDomain,
                category: existing.category ?? tenant.category)
        }
        return sorted(order.compactMap { byId[$0] })
    }

    /// Named tenants by name (then domain), unnamed ones last by ID.
    public static func sorted(_ tenants: [TenantInfo]) -> [TenantInfo] {
        tenants.sorted { a, b in
            switch (a.name, b.name) {
            case (nil, nil): return a.id < b.id
            case (nil, _): return false
            case (_, nil): return true
            case let (x?, y?):
                let order = x.localizedStandardCompare(y)
                if order != .orderedSame { return order == .orderedAscending }
                return (a.defaultDomain ?? a.id) < (b.defaultDomain ?? b.id)
            }
        }
    }

    /// What the picker lists: matches for `query`, without the hidden tenants
    /// unless `showHidden`. The current tenant always stays visible.
    public static func visible(
        _ tenants: [TenantInfo], query: String = "", hidden: Set<String>, showHidden: Bool, current: String?
    ) -> [TenantInfo] {
        let current = current?.lowercased()
        return tenants.filter { t in
            (showHidden || !hidden.contains(t.id) || t.id == current) && t.matches(query)
        }
    }

    /// Lower-case GUID, or nil for anything that is not one.
    static func normalizedId(_ raw: String?) -> String? {
        guard let raw = raw?.trimmingCharacters(in: .whitespaces), UUID(uuidString: raw) != nil else { return nil }
        return raw.lowercased()
    }

    /// A non-empty value that is not just a GUID (some sources echo the ID as the name).
    static func realName(_ raw: String?) -> String? {
        guard let s = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty, UUID(uuidString: s) == nil else {
            return nil
        }
        return s
    }

    /// Every tenant of the signed-in account from ARM's `GET /tenants`,
    /// following `nextLink` pages on management.azure.com only. Read-only.
    public static func fetchARM(tokens: TokenProvider, transport: HTTPTransport = URLSessionTransport()) async throws -> [TenantInfo] {
        let token = try await tokens.accessToken()
        var tenants: [TenantInfo] = []
        var next: URL? = armTenantsURL
        var pages = 0
        while let url = next, pages < maxPages {
            pages += 1
            var request = URLRequest(url: url, timeoutInterval: 30)
            request.httpMethod = "GET"
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            let (data, status) = try await transport.send(request)
            guard status == 200 else {
                let env = try? JSONDecoder().decode(ARMErrorEnvelope.self, from: data)
                throw PIMServiceError.http(status, [env?.error?.code, env?.error?.message].compactMap { $0 }.joined(separator: ": "))
            }
            guard let page = parseARMPage(data) else { throw PIMServiceError.http(status, "unexpected /tenants response") }
            tenants += page.tenants
            next = page.next
        }
        return tenants
    }

    /// Every tenant the user can reach, named where possible. ARM's `/tenants`
    /// listing (token for `preferredTenant`, else az's default tenant) supplies
    /// most names; az's account cache fills in the rest. Any source may fail;
    /// the others still count. Nothing is changed anywhere.
    public static func load(
        preferredTenant: String? = nil,
        transport: HTTPTransport = URLSessionTransport(),
        azPath: String? = nil
    ) async throws -> [TenantInfo] {
        async let accounts = try? AzureCLI.run(["account", "list", "--all", "--output", "json", "--only-show-errors"], azPath: azPath)
        async let tenantList = try? AzureCLI.run(["account", "tenant", "list", "--output", "json", "--only-show-errors"], azPath: azPath)
        async let arm = armWithFallback(preferredTenant: preferredTenant, transport: transport, azPath: azPath)
        let (armTenants, accountData, tenantData) = await (arm, accounts, tenantList)
        let azSources = [accountData, tenantData].compactMap { $0 }
        if armTenants == nil, azSources.isEmpty, azPath == nil, AzureCLI.locate() == nil { throw AzureCLIError.notFound }
        return merge([armTenants ?? []] + azSources.map(parseAzure))
    }

    private static func armWithFallback(preferredTenant: String?, transport: HTTPTransport, azPath: String?) async -> [TenantInfo]? {
        if let preferredTenant,
           let tenants = try? await fetchARM(tokens: AzureCLITokenProvider(tenantId: preferredTenant, azPath: azPath), transport: transport) {
            return tenants
        }
        return try? await fetchARM(tokens: AzureCLITokenProvider(tenantId: nil, azPath: azPath), transport: transport)
    }
}
