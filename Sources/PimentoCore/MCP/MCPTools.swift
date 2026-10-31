import Foundation

/// One tool as `tools/list` shows it.
struct MCPToolDefinition: Sendable {
    let name: String
    let title: String
    let description: String
    let fields: [MCPField]
    let isWrite: Bool
    let destructive: Bool
    /// Reaches Azure (false: only local files).
    let openWorld: Bool

    var json: JSONValue {
        [
            "name": .string(name),
            "title": .string(title),
            "description": .string(description),
            "inputSchema": MCPSchema.json(fields),
            "annotations": [
                "title": .string(title),
                "readOnlyHint": .bool(!isWrite),
                "destructiveHint": .bool(destructive),
                "idempotentHint": .bool(!isWrite),
                "openWorldHint": .bool(openWorld),
            ],
        ]
    }
}

/// What a tool call answers: text for the model (the structured result as
/// JSON, or an error), and the structured result.
struct MCPToolResult: Sendable {
    var text: String
    var structured: JSONValue?
    var isError: Bool

    static func failure(_ message: String) -> MCPToolResult {
        MCPToolResult(text: message, structured: nil, isError: true)
    }

    static func success(_ value: JSONValue) -> MCPToolResult {
        MCPToolResult(text: value.serialized, structured: value, isError: false)
    }

    /// The `CallToolResult` fields. Every string passes `MCPText.redact`:
    /// no file path or token reaches the model, whatever an error said.
    var json: JSONValue {
        var o: [String: JSONValue] = [
            "content": [["type": "text", "text": .string(MCPText.redact(text))]],
            "isError": .bool(isError),
        ]
        if let structured { o["structuredContent"] = MCPText.redact(structured) }
        return .object(o)
    }
}

/// What the tools need from outside: the CLI passes its services (with the
/// auth source it resolved, recording writes in the history as `mcp`), its
/// presets and history files, and its clock.
public struct MCPBackend: Sendable {
    /// A service for `tenantId` (nil: the auth source's default). `readOnly`
    /// services refuse anything but GET.
    public var service: @Sendable (_ tenantId: String?, _ readOnly: Bool) -> PIMService
    /// The tenants the signed-in account can reach (read-only).
    public var tenants: @Sendable (_ tenantId: String?) async throws -> [TenantInfo]
    /// A tool's `tenant` argument (nil: none given) to the tenant to use, as
    /// `--tenant` would be (then `$PIMENTO_TENANT`, then the default).
    public var resolveTenant: @Sendable (_ argument: String?) throws -> String?
    public var presets: PresetStore
    public var history: HistoryStore?
    public var now: @Sendable () -> Date
    public var timeZone: TimeZone

    public init(service: @escaping @Sendable (String?, Bool) -> PIMService,
                tenants: @escaping @Sendable (String?) async throws -> [TenantInfo],
                resolveTenant: @escaping @Sendable (String?) throws -> String?,
                presets: PresetStore, history: HistoryStore?, now: @escaping @Sendable () -> Date, timeZone: TimeZone) {
        self.service = service
        self.tenants = tenants
        self.resolveTenant = resolveTenant
        self.presets = presets
        self.history = history
        self.now = now
        self.timeZone = timeZone
    }
}

/// A write, planned (read-only) and ready to be confirmed and sent.
struct MCPWritePlan: Sendable {
    enum Kind: String, Sendable { case activate, deactivate, renew }

    let kind: Kind
    /// The tenant as the services are asked for it.
    let tenantArgument: String?
    /// The tenant the token is for.
    let tenantId: String?
    let user: Identity
    let justification: String
    var ticket: TicketInfo?
    let requested: RequestedDuration?
    var activations: [PlannedRequest] = []
    var deactivations: [PlannedRequest] = []
    var renewals: [RenewPlan] = []
    /// Roles in the selection that are not sent, with their outcome (nil:
    /// skipped, `skipReason`).
    var leftOut: [(role: EligibleRole, outcome: ActivationOutcome?, reason: String)] = []
    var missing: [PresetRole] = []
    var notes: [String] = []
    let preset: String?

    var isEmpty: Bool { activations.isEmpty && deactivations.isEmpty && renewals.isEmpty }

    /// The roles that will be changed, in order.
    var roles: [EligibleRole] { activations.map(\.role) + deactivations.map(\.role) + renewals.map(\.role) }

    var privileged: [EligibleRole] { roles.filter(MCPToolbox.isPrivileged) }

    /// What the user confirms, without request ids or times: the same plan
    /// made again a minute later has the same fingerprint, a different one
    /// (another account, role, duration, ticket or justification) does not.
    var fingerprint: String {
        var lines: [String] = [kind.rawValue, tenantId?.lowercased() ?? "", user.objectId.lowercased(), justification, ticket?.label ?? ""]
        var items: [String] = []
        for p in activations { items.append("a|\(p.role.policyKey.scope)|\(p.role.policyKey.role)|\(p.duration.minutes)") }
        for p in deactivations { items.append("d|\(p.role.policyKey.scope)|\(p.role.policyKey.role)") }
        for p in renewals { items.append("r|\(p.role.policyKey.scope)|\(p.role.policyKey.role)|\(p.duration.minutes)|\(p.ticket?.label ?? "")") }
        lines += items.sorted()
        return lines.joined(separator: "\n")
    }
}

enum MCPPrepared: Sendable {
    case success(MCPWritePlan)
    case failure(MCPToolResult)
}

/// The tools of `pimento mcp`: read tools always, write tools only with
/// `--allow-activate`. Writes are planned on a read-only service first; only
/// `execute` uses a service that can send a PUT.
public struct MCPToolbox: Sendable {
    let backend: MCPBackend
    /// At most this many roles per write call.
    static let maxRolesPerWrite = 20
    static let writeToolNames: Set<String> = ["activate_roles", "deactivate_roles", "renew_roles"]

    public init(backend: MCPBackend) { self.backend = backend }

    /// Owner, User Access Administrator, Role Based Access Control
    /// Administrator: roles that can give anyone access.
    static func isPrivileged(_ role: EligibleRole) -> Bool {
        AccessGrantingRole.matches(roleDefinitionId: role.roleDefinitionId, roleName: role.roleName)
    }

    // MARK: Definitions

    static let tenantField = MCPField("tenant", .string(maxLength: 253, check: { TenantResolver.isValid($0) ? nil : "not a tenant GUID or domain" }),
                                      "Tenant GUID or domain. Default: the server's tenant (--tenant, $PIMENTO_TENANT, else the sign-in's).")

    static func checkScope(_ s: String) -> String? {
        if s.hasPrefix("/"), ARMScope.path(s) == nil { return "not a valid ARM scope" }
        return nil
    }

    static func checkRoleName(_ s: String) -> String? {
        s.contains("*") ? "wildcards are not allowed here; give the exact role name" : nil
    }

    static let targetsField = MCPField(
        "roles", .array(.object([
            MCPField("role", .string(maxLength: 128, check: { checkRoleName($0) }), required: true, "Exact role name, e.g. Reader (case-insensitive)."),
            MCPField("scope", .string(maxLength: 1024, check: { checkScope($0) }), required: true,
                     "The ARM scope from list_eligible_roles (/subscriptions/…), or the exact resource name if it is unique."),
        ]), maxItems: maxRolesPerWrite),
        "The roles, each by exact role name and scope (as list_eligible_roles shows them). Use either roles or preset.")

    static let presetField = MCPField("preset", .string(maxLength: 100), "A saved Pimento preset (list_presets) instead of roles.")

    static let justificationText = MCPArgType.string(maxLength: 500)

    static let ticketFields = [
        MCPField("ticket_number", .string(maxLength: 100), "Ticket number, for roles whose policy requires a ticket (see list_eligible_roles)."),
        MCPField("ticket_system", .string(maxLength: 100), "Ticket system (ServiceNow, Jira, …); goes with ticket_number."),
    ]

    static let readTools: [MCPToolDefinition] = [
        MCPToolDefinition(
            name: "list_tenants", title: "List tenants",
            description: "Lists the Microsoft Entra tenants the signed-in account can reach (id, name, domain). Read-only.",
            fields: [], isWrite: false, destructive: false, openWorld: true),
        MCPToolDefinition(
            name: "list_eligible_roles", title: "List eligible PIM roles",
            description: "Lists the Azure resource roles the user is eligible for in a tenant, whether each is active and until when, "
                + "and its PIM policy: the longest activation (maxDuration, ISO 8601), whether it needs approval, a ticket, a justification or MFA. "
                + "highPrivilege marks Owner, User Access Administrator and Role Based Access Control Administrator. Read-only.",
            fields: [
                tenantField,
                MCPField("resource", .string(maxLength: 1024),
                         "Only resources whose name contains this text, or (starting with /) this ARM scope and everything below it."),
                MCPField("role", .string(maxLength: 128), "Only this role name (case-insensitive; * is a wildcard)."),
                MCPField("state", .enumeration(["any", "active", "eligible"]), "any (default), active, or eligible (not active)."),
            ],
            isWrite: false, destructive: false, openWorld: true),
        MCPToolDefinition(
            name: "list_active_roles", title: "List active PIM roles",
            description: "Lists the roles that are active now, soonest-expiring first, with when each ends (activeUntil) and the minutes left. Read-only.",
            fields: [tenantField], isWrite: false, destructive: false, openWorld: true),
        MCPToolDefinition(
            name: "list_presets", title: "List presets",
            description: "Lists the user's saved Pimento presets (named sets of roles with a default justification and duration). Read-only, local.",
            fields: [tenantField], isWrite: false, destructive: false, openWorld: false),
        MCPToolDefinition(
            name: "list_pending_approvals", title: "List requests awaiting approval",
            description: "Lists the user's own activation requests that wait for an approver's decision, with when they expire. Read-only.",
            fields: [tenantField], isWrite: false, destructive: false, openWorld: true),
        MCPToolDefinition(
            name: "get_history", title: "Pimento history",
            description: "What Pimento (app, CLI, keep-alive and this server) sent and how it went, newest first. Read-only, local.",
            fields: [
                MCPField("since", .string(maxLength: 40), "7d, 24h, today, yesterday, 2026-10-01, or ISO 8601."),
                MCPField("until", .string(maxLength: 40), "As since."),
                MCPField("actions", .array(.enumeration(HistoryAction.known.map(\.rawValue)), maxItems: 8), "Only these actions."),
                MCPField("outcomes", .array(.enumeration(HistoryResult.known.map(\.rawValue)), maxItems: 8), "Only these outcomes."),
                MCPField("text", .string(maxLength: 200), "Words that must all appear (role, resource, justification, ticket, request id)."),
                MCPField("limit", .integer(1...500), "At most this many records (default 50)."),
            ],
            isWrite: false, destructive: false, openWorld: false),
    ]

    static let writeTools: [MCPToolDefinition] = [
        MCPToolDefinition(
            name: "activate_roles", title: "Activate PIM roles",
            description: "Activates eligible roles for the user (PIM SelfActivate), each for `hours` capped at its policy maximum. "
                + "The user is asked to confirm the exact plan before anything is sent; a role that needs approval is submitted "
                + "and waits for an approver. Roles that are already active are skipped. Name roles exactly (list_eligible_roles), "
                + "give the user's real reason as the justification, and do not retry if the user declines.",
            fields: [tenantField, targetsField, presetField,
                     MCPField("justification", justificationText, required: true, "Why the user needs the roles (sent to Azure and recorded)."),
                     MCPField("hours", .integer(1...ActivationRequestBuilder.maxHours),
                              "Duration in hours (default: the preset's, else 8), capped at each role's policy maximum.")] + ticketFields,
            isWrite: true, destructive: false, openWorld: true),
        MCPToolDefinition(
            name: "deactivate_roles", title: "Deactivate PIM roles",
            description: "Ends active roles now (PIM SelfDeactivate). The user is asked to confirm first. PIM refuses to end an "
                + "activation in its first 5 minutes.",
            fields: [tenantField, targetsField, presetField,
                     MCPField("justification", justificationText, "Why (optional).")],
            isWrite: true, destructive: true, openWorld: true),
        MCPToolDefinition(
            name: "renew_roles", title: "Renew PIM roles",
            description: "Ends active roles and activates them again for a fresh duration (capped at the policy maximum). The role "
                + "is off for a few minutes in between. Roles whose policy needs approval are not renewed. The user is asked to confirm first.",
            fields: [tenantField, targetsField, presetField,
                     MCPField("justification", justificationText, required: true, "Why the user needs the roles longer."),
                     MCPField("hours", .integer(1...ActivationRequestBuilder.maxHours),
                              "New duration in hours (default: the preset's, else 8), capped at the policy maximum.")] + ticketFields,
            isWrite: true, destructive: true, openWorld: true),
    ]

    /// The tools this server offers. Depends only on how it was started.
    func definitions(_ config: MCPConfiguration) -> [MCPToolDefinition] {
        config.allowActivate ? Self.readTools + Self.writeTools : Self.readTools
    }

    // MARK: Shared

    /// The tenant for a call: the pinned one (`--tenant`) if any, which the
    /// call may only repeat; else the argument, `$PIMENTO_TENANT` or the default.
    func tenant(_ args: MCPArguments, _ config: MCPConfiguration) throws -> String? {
        let given = args.string("tenant")
        if let pinned = config.tenant {
            if let given, given.caseInsensitiveCompare(pinned) != .orderedSame {
                throw MCPArgumentError(message: "This server is limited to tenant \(pinned) (--tenant); it cannot use \(MCPText.clip(given, 80)).")
            }
            return pinned
        }
        return try backend.resolveTenant(given)
    }

    /// A failure result for an error from Azure, the auth source or a file.
    static func failure(_ error: Error, doing what: String) -> MCPToolResult {
        if let e = error as? MCPArgumentError { return .failure(e.message) }
        var message = error.localizedDescription
        if CLIExit.code(for: error) == .auth {
            message += " The user needs to sign in again (`az login`, or `pimento login`) outside this conversation."
        }
        return .failure("Could not \(what): \(MCPText.clip(message, 600))")
    }

    static func roleJSON(_ r: EligibleRole, now: Date, policy: PolicyLookup?) -> JSONValue {
        var o: [String: JSONValue] = [
            "roleName": .string(r.roleName),
            "roleDefinitionId": .string(r.roleDefinitionId),
            "scope": .string(r.scope),
            "scopeName": .string(r.scopeName),
            "scopeType": .string(r.scopeTypeLabel),
            "highPrivilege": .bool(isPrivileged(r)),
            "isActive": .bool(r.isActive),
            "hasCondition": .bool(r.hasCondition),
        ]
        switch r.membership {
        case .direct: o["membership"] = "direct"
        case .group(let g): o["membership"] = "group"; o["group"] = .string(g)
        }
        if r.isActive, let until = r.activeUntil {
            o["activeUntil"] = .string(AzureDate.format(until))
            o["minutesLeft"] = .int(max(0, Int(until.timeIntervalSince(now) / 60)))
        }
        if let policy {
            var p: [String: JSONValue] = [:]
            switch policy {
            case .loaded(let rp):
                p["status"] = "loaded"
                if let iso = rp.maxDurationISO { p["maxDuration"] = .string(iso) }
                p["requiresApproval"] = .bool(rp.requiresApproval)
                p["requiresTicket"] = .bool(rp.requiresTicket)
                p["requiresJustification"] = .bool(rp.requiresJustification)
                p["requiresMfa"] = .bool(rp.requiresMFA)
                if let c = rp.authenticationContext, !c.isEmpty { p["authenticationContext"] = .string(c) }
            case .notFound: p["status"] = "notFound"
            case .failed(let why): p["status"] = "failed"; p["error"] = .string(MCPText.clip(why, 300))
            }
            o["policy"] = .object(p)
        }
        return .object(o)
    }

    static func user(_ identity: Identity) -> JSONValue {
        var o: [String: JSONValue] = [:]
        if let n = identity.name { o["name"] = .string(n) }
        if let u = identity.upn { o["upn"] = .string(u) }
        return .object(o)
    }

    // MARK: Read tools

    func read(_ name: String, _ args: MCPArguments, config: MCPConfiguration) async -> MCPToolResult {
        do {
            switch name {
            case "list_tenants": return try await listTenants(config)
            case "list_eligible_roles": return try await listEligible(args, config)
            case "list_active_roles": return try await listActive(args, config)
            case "list_presets": return try listPresets(args, config)
            case "list_pending_approvals": return try await listPending(args, config)
            case "get_history": return try await history(args, config)
            default: return .failure("Unknown tool \(name).")
            }
        } catch {
            return Self.failure(error, doing: "run \(name)")
        }
    }

    func listTenants(_ config: MCPConfiguration) async throws -> MCPToolResult {
        var tenants = try await backend.tenants(config.tenant ?? backend.resolveTenant(nil))
        // A pinned server names only its own tenant: by the GUID its token
        // has, else by the GUID or default domain it was pinned with.
        if let pinned = config.tenant {
            let id = await pinnedTenantId(pinned) ?? pinned
            tenants = tenants.filter {
                $0.id.caseInsensitiveCompare(id) == .orderedSame || $0.defaultDomain?.caseInsensitiveCompare(pinned) == .orderedSame
            }
        }
        let list: [JSONValue] = tenants.map { t in
            var o: [String: JSONValue] = ["id": .string(t.id)]
            if let n = t.displayName { o["displayName"] = .string(n) }
            if let d = t.defaultDomain { o["defaultDomain"] = .string(d) }
            return .object(o)
        }
        var result: [String: JSONValue] = ["tenants": .array(list)]
        if let pinned = config.tenant { result["note"] = .string("This server only works in tenant \(pinned).") }
        return .success(.object(result))
    }

    func listEligible(_ args: MCPArguments, _ config: MCPConfiguration) async throws -> MCPToolResult {
        let tenant = try tenant(args, config)
        let service = backend.service(tenant, true)
        let now = backend.now()
        let snapshot = try await service.loadRoles(now: now)
        var criteria = RoleCriteria()
        if let r = args.string("resource") { criteria.filters = [r] }
        if let r = args.string("role") { criteria.roles = [r] }
        criteria.state = RoleCriteria.State(rawValue: args.string("state") ?? "any") ?? .any
        let roles = criteria.apply(snapshot.roles)
        let policies = (try? await service.loadPolicies(for: roles)) ?? [:]
        return .success([
            "tenantId": snapshot.identity.tenantId.map(JSONValue.string) ?? .null,
            "user": Self.user(snapshot.identity),
            "roles": .array(roles.map { Self.roleJSON($0, now: now, policy: policies[$0.policyKey] ?? .failed("not loaded")) }),
            "count": .int(roles.count),
        ])
    }

    func listActive(_ args: MCPArguments, _ config: MCPConfiguration) async throws -> MCPToolResult {
        let tenant = try tenant(args, config)
        let now = backend.now()
        let snapshot = try await backend.service(tenant, true).loadRoles(now: now)
        let active = CLIRunner.activeRolesByExpiry(snapshot.roles)
        return .success([
            "tenantId": snapshot.identity.tenantId.map(JSONValue.string) ?? .null,
            "user": Self.user(snapshot.identity),
            "roles": .array(active.map { Self.roleJSON($0, now: now, policy: nil) }),
            "count": .int(active.count),
        ])
    }

    func listPresets(_ args: MCPArguments, _ config: MCPConfiguration) throws -> MCPToolResult {
        let tenant = try tenant(args, config)
        let library = try backend.presets.load()
        let presets = tenant.map { library.presets(forTenant: $0) } ?? library.presets(forTenant: nil)
        // The CLI's JSON shape, without where the file is.
        return .success(["presets": .array(try presets.map { try JSONValue.encoding(CLIJSON.PresetDoc($0)) })])
    }

    func listPending(_ args: MCPArguments, _ config: MCPConfiguration) async throws -> MCPToolResult {
        let tenant = try tenant(args, config)
        let (identity, requests) = try await backend.service(tenant, true).loadScheduledRequests(now: backend.now())
        let waiting = requests.filter { $0.kind == .awaitingApproval }
        return .success([
            "tenantId": identity.tenantId.map(JSONValue.string) ?? .null,
            "requests": .array(try waiting.map { try JSONValue.encoding(CLIJSON.PendingRequest($0)) }),
            "count": .int(waiting.count),
        ])
    }

    /// The GUID of the pinned tenant (`--tenant`, which may be a domain), as
    /// the token for it says, like the other tools; nil when it cannot be told.
    func pinnedTenantId(_ pinned: String) async -> String? {
        if UUID(uuidString: pinned) != nil { return pinned }
        guard let token = try? await backend.service(pinned, true).tokens.accessToken() else { return nil }
        return JWT.identity(fromToken: token)?.tenantId
    }

    func history(_ args: MCPArguments, _ config: MCPConfiguration) async throws -> MCPToolResult {
        guard let store = backend.history else { return .failure("No history is kept here.") }
        let now = backend.now()
        func date(_ key: String) throws -> Date? {
            guard let raw = args.string(key) else { return nil }
            guard let d = HistoryDate.parse(raw, now: now, timeZone: backend.timeZone, endOfDay: key == "until") else {
                throw MCPArgumentError(message: "\(key) takes 7d, 24h, today, yesterday, a date (2026-10-01) or ISO 8601.")
            }
            return d
        }
        let filter = HistoryFilter(
            since: try date("since"), until: try date("until"),
            actions: Set((args.strings("actions") ?? []).map(HistoryAction.init(rawValue:))),
            results: Set((args.strings("outcomes") ?? []).map(HistoryResult.init(rawValue:))),
            text: args.string("text") ?? "")
        var records = store.records(now: now)
        var note: String?
        // A pinned server shows only its tenant's records; none when the
        // pin cannot be resolved to a tenant id.
        if let pinned = config.tenant {
            if let id = await pinnedTenantId(pinned) {
                records = records.filter { $0.tenantId?.caseInsensitiveCompare(id) == .orderedSame }
                note = "Only records of tenant \(pinned) (this server is limited to it)."
            } else {
                records = []
                note = "This server is limited to tenant \(pinned), which could not be resolved to a tenant id, so no records are shown."
            }
        }
        let matching = filter.apply(records)
        let shown = Array(matching.prefix(args.int("limit") ?? 50))
        var result: [String: JSONValue] = [
            "records": .array(try shown.map { try JSONValue.encoding($0) }),
            "total": .int(matching.count),
            "recording": .bool(store.loadSettings().enabled),
        ]
        if let note { result["note"] = .string(note) }
        return .success(.object(result))
    }
}

// MARK: - Writes

extension MCPToolbox {
    struct Selection {
        var roles: [EligibleRole]
        var missing: [PresetRole] = []
        var preset: Preset?
        var notes: [String] = []
    }

    /// The roles a write call names, among `rows`: exact role + scope pairs,
    /// or a preset. Every named pair must exist; a resource name that fits
    /// several scopes is refused rather than guessed.
    func select(_ args: MCPArguments, rows: [EligibleRole], tenantId: String?, alias: String? = nil) throws -> Selection {
        let targets = args.objects("roles")
        let presetName = args.string("preset")
        switch (targets, presetName) {
        case (nil, nil): throw MCPArgumentError(message: "Name the roles (roles: [{role, scope}]) or a preset.")
        case (.some, .some): throw MCPArgumentError(message: "Use either roles or preset, not both.")
        default: break
        }
        var picked: [EligibleRole] = []
        var selection = Selection(roles: [])
        if let presetName {
            let library = try backend.presets.load()
            let preset = try library.find(presetName, tenantId: tenantId, alias: alias)
            let resolution = preset.resolve(in: rows)
            picked = resolution.roles
            selection.missing = resolution.missing
            selection.preset = preset
            for rule in resolution.unmatchedRules { selection.notes.append("The preset's rule `\(rule.label)` matches no role.") }
        } else {
            for target in targets ?? [] {
                let role = target.string("role") ?? "", scope = target.string("scope") ?? ""
                let byRole = rows.filter { $0.roleName.caseInsensitiveCompare(role) == .orderedSame }
                let matches: [EligibleRole]
                if scope.hasPrefix("/") {
                    let wanted = RoleMatcher.key(scope: scope, roleDefinitionId: "").scope
                    matches = byRole.filter { RoleMatcher.key(scope: $0.scope, roleDefinitionId: "").scope == wanted }
                } else {
                    matches = byRole.filter { $0.scopeName.caseInsensitiveCompare(scope) == .orderedSame }
                }
                let scopes = Set(matches.map(\.policyKey.scope))
                if matches.isEmpty {
                    throw MCPArgumentError(message: "No eligible role \(MCPText.clip(role, 80)) on \(MCPText.clip(scope, 200)) in this tenant. list_eligible_roles shows the user's roles; nothing was sent.")
                }
                if scopes.count > 1 {
                    throw MCPArgumentError(message: "\(MCPText.clip(scope, 200)) names \(scopes.count) scopes for \(MCPText.clip(role, 80)); give the ARM scope instead: "
                        + matches.map(\.scope).sorted().joined(separator: ", ") + ". Nothing was sent.")
                }
                picked += matches
            }
        }
        // One row per scope + role, the direct eligibility first.
        var byKey: [RoleMatcher.Key: Int] = [:]
        for role in picked {
            if let i = byKey[role.policyKey] {
                if selection.roles[i].membership != .direct, role.membership == .direct { selection.roles[i] = role }
                continue
            }
            byKey[role.policyKey] = selection.roles.count
            selection.roles.append(role)
        }
        guard selection.roles.count <= Self.maxRolesPerWrite else {
            throw MCPArgumentError(message: "That is \(selection.roles.count) roles; at most \(Self.maxRolesPerWrite) per call. Nothing was sent.")
        }
        return selection
    }

    static func ticket(_ args: MCPArguments, preset: Preset?) throws -> TicketInfo? {
        let number = args.string("ticket_number"), system = args.string("ticket_system")
        if system != nil, number == nil { throw MCPArgumentError(message: "ticket_system goes with ticket_number.") }
        return TicketInfo.make(number: number, system: system ?? (number != nil ? preset?.trimmedTicketSystem : nil))
    }

    /// The roles a keep-alive preset covers: the Pimento app renews those
    /// during working hours, beyond the duration in the confirmation, with
    /// this activation's justification (roles kept alive one by one in the
    /// app are not known here).
    static func keepAliveNotes(_ roles: [EligibleRole], presets: [Preset]) -> [String] {
        let rules = KeepAliveRule.resolve(perRole: [], presets: presets, roles: roles)
        var byPreset: [String: [EligibleRole]] = [:]
        for role in roles {
            if let preset = rules[ReminderRole.key(role.policyKey)]?.preset { byPreset[preset, default: []].append(role) }
        }
        return byPreset.keys.sorted().map { preset in
            let names = byPreset[preset]!.map { "\($0.roleName) on \($0.scopeName)" }.joined(separator: ", ")
            return "\(names) \(byPreset[preset]!.count == 1 ? "is" : "are") kept alive by the preset “\(preset)”: the Pimento app renews "
                + "\(byPreset[preset]!.count == 1 ? "it" : "them") during working hours, beyond this duration, with this justification."
        }
    }

    func privilegeRefusal(_ roles: [EligibleRole], _ config: MCPConfiguration, verb: String) -> MCPToolResult? {
        let privileged = roles.filter(Self.isPrivileged)
        guard !privileged.isEmpty, !config.allowPrivileged else { return nil }
        let names = privileged.map { "\($0.roleName) on \($0.scopeName)" }.joined(separator: ", ")
        return .failure("Refused, nothing was sent: \(names) can grant anyone access to the resource (high privilege), and this server "
            + "was not started with --allow-privileged. The user can \(verb) \(privileged.count == 1 ? "it" : "them") with `pimento \(verb)` or the app.")
    }

    /// Plans a write on a read-only service. Every refusal is decided here,
    /// before the user is asked anything.
    func prepare(_ name: String, _ args: MCPArguments, config: MCPConfiguration) async -> MCPPrepared {
        do {
            let tenant = try tenant(args, config)
            let service = backend.service(tenant, true)
            let now = backend.now()
            let snapshot = try await service.loadRoles(now: now)
            let tenantId = snapshot.identity.tenantId ?? tenant
            let selection = try select(args, rows: snapshot.roles, tenantId: tenantId, alias: tenant)
            let principal = snapshot.identity.objectId
            let preset = selection.preset
            let requested: RequestedDuration = args.int("hours").map { .hours($0) } ?? preset?.duration ?? .hours(ActivationRequestBuilder.defaultHours)
            let justification = args.string("justification") ?? ""
            var plan = MCPWritePlan(
                kind: MCPWritePlan.Kind(rawValue: String(name.prefix { $0 != "_" })) ?? .activate,
                tenantArgument: tenant, tenantId: tenantId, user: snapshot.identity, justification: justification,
                ticket: nil, requested: name == "deactivate_roles" ? nil : requested, missing: selection.missing,
                notes: selection.notes, preset: preset?.name)
            if selection.roles.isEmpty {
                return .failure(.failure("None of the preset's roles are among the user's eligible roles in this tenant. Nothing was sent."))
            }

            switch name {
            case "activate_roles":
                let ticket = try Self.ticket(args, preset: preset)
                let (skipped, toActivate) = ActivationPlanning.split(selection.roles, start: nil)
                plan.leftOut = skipped.map { ($0, nil, "already active") }
                if let refusal = privilegeRefusal(toActivate, config, verb: "activate") { return .failure(refusal) }
                let policies = toActivate.isEmpty ? [:] : ((try? await service.loadPolicies(for: toActivate)) ?? [:])
                let unknown = toActivate.filter { policies[$0.policyKey]?.policy == nil }
                if !unknown.isEmpty {
                    return .failure(.failure("The PIM policy of \(unknown.map { "\($0.roleName) on \($0.scopeName)" }.joined(separator: ", ")) "
                        + "could not be read, so its maximum duration and approval requirement are unknown. This server only activates "
                        + "roles whose policy it can read. Nothing was sent."))
                }
                let needTicket = TicketRequirement.missing(toActivate, ticket: ticket) { policies[$0.policyKey] }
                if !needTicket.isEmpty {
                    return .failure(.failure("The policy of \(needTicket.map { "\($0.roleName) on \($0.scopeName)" }.joined(separator: ", ")) "
                        + "requires a ticket: pass ticket_number and ticket_system. Nothing was sent."))
                }
                plan.ticket = ticket
                plan.activations = try ActivationPlanning.activationPlans(
                    toActivate, policies: policies, principalId: principal, justification: justification,
                    requested: requested, ticket: ticket, now: now)
                let approval = toActivate.filter { policies[$0.policyKey]?.policy?.requiresApproval == true }
                if !approval.isEmpty {
                    plan.notes.append("\(approval.count == 1 ? "1 role needs" : "\(approval.count) roles need") an approver's decision; it stays inactive until then.")
                }

            case "deactivate_roles":
                let lifecycle = RoleLifecycle.select(selection.roles, now: now)
                plan.deactivations = try ActivationRequestBuilder.deactivationPlan(
                    lifecycle.ready, principalId: principal, justification: justification, now: now)
                plan.leftOut = lifecycle.tooSoon.map { ($0, .tooSoon(possibleAt: RoleLifecycle.earliestDeactivation(of: $0)), "") }
                    + lifecycle.inactive.map { ($0, nil, "not active") }

            default: // renew_roles
                let given = try Self.ticket(args, preset: preset)
                if let refusal = privilegeRefusal(selection.roles.filter(\.isActive), config, verb: "renew") { return .failure(refusal) }
                let renewal = try await service.planRenewal(
                    selection.roles, principalId: principal, justification: justification, requested: requested, given: given, now: now)
                plan.ticket = given
                plan.renewals = renewal.plans
                let s = renewal.selection
                plan.leftOut = (s.tooSoon + s.needsApproval + s.policyUnknown + s.needsTicket).map { ($0, renewal.outcomes[$0.id], "") }
                    + s.inactive.map { ($0, nil, "not active") }
            }
            if plan.kind != .deactivate {
                let presets = (try? backend.presets.load())?.presets(forTenant: tenantId) ?? []
                plan.notes += Self.keepAliveNotes(plan.roles, presets: presets)
            }
            return .success(plan)
        } catch {
            return .failure(Self.failure(error, doing: "plan the request"))
        }
    }

    /// Sends a confirmed plan and reports every role's outcome. The only
    /// place that uses a service which can write; every write it sends is
    /// recorded in the history.
    func execute(_ plan: MCPWritePlan) async -> MCPToolResult {
        let collected = OutcomeBox()
        for item in plan.leftOut { if let o = item.outcome { collected.set(item.role.id, o) } }
        if !plan.isEmpty {
            let service = backend.service(plan.tenantArgument, false)
            do {
                switch plan.kind {
                case .activate:
                    try await service.execute(plan.activations, maxConcurrent: 4) { p, o in collected.set(p.role.id, o) }
                case .deactivate:
                    try await service.execute(plan.deactivations, maxConcurrent: 4) { p, o in collected.set(p.role.id, o) }
                case .renew:
                    try await service.renew(plan.renewals, maxConcurrent: 4) { p, o in collected.set(p.role.id, o) }
                }
            } catch {
                return Self.failure(error, doing: "send the requests")
            }
        }
        let outcomes = collected.all
        var results: [CLIJSON.Result] = []
        for p in plan.activations { results.append(CLIJSON.Result(role: p.role, outcome: outcomes[p.role.id], plan: p)) }
        for p in plan.deactivations { results.append(CLIJSON.Result(role: p.role, outcome: outcomes[p.role.id], plan: p)) }
        for p in plan.renewals {
            results.append(CLIJSON.Result(role: p.role, outcome: outcomes[p.role.id], plan: p.deactivation, followUp: p.plannedActivation))
        }
        for item in plan.leftOut {
            results.append(CLIJSON.Result(role: item.role, outcome: outcomes[item.role.id], plan: nil, skipReason: item.reason))
        }
        let operation: ActivationSummary.Operation = switch plan.kind {
        case .activate: .activate
        case .deactivate: .deactivate
        case .renew: .renew
        }
        let summary = CLIJSON.Summary(results, operation: operation)
        var notes = plan.notes
        if plan.isEmpty { notes.append("Nothing to send: \(plan.kind == .activate ? "the roles are already active" : "no role can be changed now").") }
        if outcomes.values.contains(where: \.isAwaitingApproval) {
            notes.append("Roles awaiting approval are not active until an approver decides (24 hours at most). list_pending_approvals shows them.")
        }
        do {
            var doc: [String: JSONValue] = [
                "action": .string(plan.kind.rawValue),
                "tenantId": plan.tenantId.map(JSONValue.string) ?? .null,
                "results": .array(try results.map { try Self.resultJSON($0) }),
                "summary": try JSONValue.encoding(summary),
            ]
            if !plan.justification.isEmpty { doc["justification"] = .string(plan.justification) }
            if let preset = plan.preset { doc["preset"] = .string(preset) }
            if !plan.missing.isEmpty {
                doc["missing"] = .array(plan.missing.map { .string($0.label) })
                notes.append("\(plan.missing.count) of the preset's roles are no longer eligible and were left out.")
            }
            if !notes.isEmpty { doc["notes"] = .array(notes.map(JSONValue.string)) }
            var result = MCPToolResult.success(.object(doc))
            result.isError = summary.failed > 0 && summary.activated + summary.submitted + (summary.deactivated ?? 0) + (summary.renewed ?? 0) == 0
            return result
        } catch {
            return .failure("Sent, but the result could not be shown: \(error.localizedDescription). get_history lists what happened.")
        }
    }

    /// The CLI's result shape, without the request bodies (dry runs only) and
    /// the eligibility ids.
    static func resultJSON(_ r: CLIJSON.Result) throws -> JSONValue {
        guard case .object(var o) = try JSONValue.encoding(r) else { return .null }
        o["request"] = nil
        o["requests"] = nil
        if case .object(var role)? = o["role"] {
            role["id"] = nil
            role["eligibilityScheduleId"] = nil
            if let name = role["roleName"]?.stringValue, let def = role["roleDefinitionId"]?.stringValue {
                role["highPrivilege"] = .bool(AccessGrantingRole.matches(roleDefinitionId: def, roleName: name))
            }
            o["role"] = .object(role)
        }
        return .object(o)
    }
}

// MARK: - Confirmation

/// The question the user is asked before a write, through MCP elicitation.
enum MCPConfirmation {
    /// The key of the confirmation in `inputRequests` / `inputResponses`.
    static let inputKey = "pimento_confirm"
    static let confirmField = "confirm"
    static let privilegedField = "confirm_high_privilege"

    /// `elicitation/create` params (form mode). `mode` exists from
    /// 2025-11-25 on; earlier clients get the request without it.
    static func request(for plan: MCPWritePlan, withMode: Bool = true) -> JSONValue {
        var properties: [String: JSONValue] = [
            confirmField: [
                "type": "boolean",
                "title": .string(confirmTitle(plan)),
                "description": "Check to send exactly what is listed above. Leave unchecked, or decline, to send nothing.",
                "default": false,
            ],
        ]
        var required: [JSONValue] = [.string(confirmField)]
        if !plan.privileged.isEmpty {
            properties[privilegedField] = [
                "type": "boolean",
                "title": "I understand these roles can grant anyone access",
                "description": "Owner, User Access Administrator and Role Based Access Control Administrator can give any identity access to the resource.",
                "default": false,
            ]
            required.append(.string(privilegedField))
        }
        var params: [String: JSONValue] = [
            "message": .string(message(for: plan)),
            "requestedSchema": ["type": "object", "properties": .object(properties), "required": .array(required)],
        ]
        if withMode { params["mode"] = "form" }
        return .object(params)
    }

    static func confirmTitle(_ plan: MCPWritePlan) -> String {
        let n = plan.roles.count
        let roles = n == 1 ? "1 role" : "\(n) roles"
        return switch plan.kind {
        case .activate: "Activate \(roles)"
        case .deactivate: "Deactivate \(roles)"
        case .renew: "Renew \(roles)"
        }
    }

    /// What the user reads. Built by the server from Azure's data and the
    /// plan; the agent's own text (the justification and ticket) is quoted,
    /// shortened and made printable.
    static func message(for plan: MCPWritePlan) -> String {
        let verb = switch plan.kind {
        case .activate: "ACTIVATE"
        case .deactivate: "DEACTIVATE"
        case .renew: "RENEW (end and activate again)"
        }
        var lines = ["An AI agent asks Pimento to \(verb) \(plan.roles.count == 1 ? "this Azure role" : "these \(plan.roles.count) Azure roles") "
            + "for \(MCPText.clip(plan.user.upn ?? plan.user.name ?? "you", 120)) in tenant \(MCPText.clip(plan.tenantId ?? "(default)", 80)):", ""]
        var n = 0
        func line(_ role: EligibleRole, _ detail: String) {
            n += 1
            let flag = MCPToolbox.isPrivileged(role) ? " [HIGH PRIVILEGE]" : ""
            lines.append("\(n). \(MCPText.clip(role.roleName, 80))\(flag) on \"\(MCPText.clip(role.scopeName, 120))\" (\(role.scopeTypeLabel))\(detail)")
            // Display names are not unique (rg-app in a dev and a prod
            // subscription): the scope says which one the agent picked.
            lines.append("   \(MCPText.clip(role.scope, 300))")
        }
        for p in plan.activations { line(p.role, " for \(durationText(p.duration))") }
        for p in plan.deactivations { line(p.role, ": ends now") }
        for p in plan.renewals { line(p.role, ": off for a few minutes, then active for \(durationText(p.duration))") }
        lines.append("")
        if !plan.justification.isEmpty { lines.append("Justification (from the agent): \"\(MCPText.clip(plan.justification, 500))\"") }
        if let t = plan.ticket { lines.append("Ticket (from the agent): \(MCPText.clip(t.label, 220))") }
        if plan.kind == .renew, plan.ticket == nil, plan.renewals.contains(where: { $0.ticket != nil }) {
            lines.append("Ticket: each activation's original ticket.")
        }
        if !plan.privileged.isEmpty {
            lines.append("")
            lines.append("WARNING: \(plan.privileged.count == 1 ? "1 role" : "\(plan.privileged.count) roles") marked HIGH PRIVILEGE can grant anyone access to the resource.")
        }
        for note in plan.notes { lines.append("Note: \(MCPText.clip(note, 300))") }
        lines.append("")
        lines.append("Only confirm if you asked for this. Nothing is sent unless you check the box and accept.")
        return lines.joined(separator: "\n")
    }

    static func durationText(_ d: EffectiveDuration) -> String {
        if d.isClamped, case .hours(let h) = d.requested { return "\(d.text) (asked \(h) h; capped at the policy maximum)" }
        return d.text
    }

    /// nil when the user accepted with every box checked; else what to tell the model.
    static func refusal(_ answer: JSONValue, plan: MCPWritePlan) -> MCPToolResult? {
        guard answer["action"]?.stringValue == "accept" else {
            let action = answer["action"]?.stringValue == "decline" ? "declined" : "dismissed"
            return .failure("The user \(action) the confirmation. Nothing was sent. Do not retry unless the user asks again.")
        }
        guard answer["content"]?[confirmField]?.boolValue == true else {
            return .failure("The user did not confirm (the box was not checked). Nothing was sent. Do not retry unless the user asks again.")
        }
        if !plan.privileged.isEmpty, answer["content"]?[privilegedField]?.boolValue != true {
            return .failure("The user did not confirm the high-privilege roles. Nothing was sent. Do not retry unless the user asks again.")
        }
        return nil
    }
}
