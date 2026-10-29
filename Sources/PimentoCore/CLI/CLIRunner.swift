import Foundation

/// Everything the `pimento` command touches outside itself: the terminal, the
/// environment, the clock, and how it reaches Azure. `main.swift` passes the
/// real thing; tests pass buffers and a fake transport.
public struct CLIEnvironment: Sendable {
    public enum Stream: Sendable { case out, err }

    public var write: @Sendable (String, Stream) -> Void
    /// One line from stdin (the confirmation answer); nil at end of input.
    public var readLine: @Sendable () -> String?
    public var stdoutIsTTY: Bool
    public var stderrIsTTY: Bool
    public var stdinIsTTY: Bool
    /// Columns of the terminal, when stdout is one.
    public var terminalWidth: Int?
    public var variables: [String: String]
    public var now: @Sendable () -> Date
    public var timeZone: TimeZone
    /// The service for a tenant. `readOnly` services must refuse every write.
    public var makeService: @Sendable (_ tenantId: String?, _ readOnly: Bool) -> PIMService
    public var loadTenants: @Sendable (_ preferredTenant: String?) async throws -> [TenantInfo]

    public init(
        write: @escaping @Sendable (String, Stream) -> Void,
        readLine: @escaping @Sendable () -> String?,
        stdoutIsTTY: Bool, stderrIsTTY: Bool, stdinIsTTY: Bool,
        terminalWidth: Int?,
        variables: [String: String],
        now: @escaping @Sendable () -> Date = { Date() },
        timeZone: TimeZone = .current,
        makeService: @escaping @Sendable (String?, Bool) -> PIMService,
        loadTenants: @escaping @Sendable (String?) async throws -> [TenantInfo]
    ) {
        self.write = write
        self.readLine = readLine
        self.stdoutIsTTY = stdoutIsTTY
        self.stderrIsTTY = stderrIsTTY
        self.stdinIsTTY = stdinIsTTY
        self.terminalWidth = terminalWidth
        self.variables = variables
        self.now = now
        self.timeZone = timeZone
        self.makeService = makeService
        self.loadTenants = loadTenants
    }
}

/// The `pimento` command. `run` never exits the process; it returns the status.
public struct CLIRunner: Sendable {
    let env: CLIEnvironment
    let outStyle: TerminalStyle
    let errStyle: TerminalStyle

    public init(environment: CLIEnvironment) {
        env = environment
        outStyle = TerminalStyle.detect(isTTY: environment.stdoutIsTTY, environment: environment.variables)
        errStyle = TerminalStyle.detect(isTTY: environment.stderrIsTTY, environment: environment.variables)
    }

    func out(_ s: String = "") { env.write(s + "\n", .out) }
    func err(_ s: String) { env.write(s + "\n", .err) }

    public func run(_ arguments: [String]) async -> Int32 {
        let invocation: CLIInvocation
        do {
            invocation = try CLIParser.parse(arguments)
        } catch {
            err(errStyle.red("error:") + " " + error.localizedDescription)
            return CLIExit.usage.rawValue
        }
        if let note = invocation.deprecation { err(errStyle.yellow("note:") + " " + note) }
        do {
            return try await run(invocation.command).rawValue
        } catch {
            return report(error).rawValue
        }
    }

    func run(_ command: CLICommand) async throws -> CLIExit {
        switch command {
        case .help(let topic):
            out(CLIHelp.text(for: topic))
            return .success
        case .version:
            out("pimento \(AppInfo.version)")
            return .success
        case .completions(let shell):
            out(CLIHelp.completionScript(for: shell))
            return .success
        case .tenants(let o): return try await tenants(o)
        case .list(let o): return try await list(o)
        case .status(let o): return try await status(o)
        case .activate(let o): return try await activate(o)
        }
    }

    /// Prints an error with a hint and maps it to an exit status.
    func report(_ error: Error, tenant: String? = nil) -> CLIExit {
        err(errStyle.red("error:") + " " + error.localizedDescription)
        let code = CLIExit.code(for: error)
        if code == .auth, (error as? AzureCLIError) != .notFound {
            err("hint: sign in with `\(AzureCLIError.loginCommand(tenant: tenant ?? env.variables[TenantResolver.environmentVariable]))`")
        }
        return code
    }

    func resolveTenant(_ flag: String?) throws -> TenantSelection {
        try TenantResolver.resolve(commandLine: flag, environment: env.variables, saved: nil)
    }

    func load(_ tenant: TenantSelection, readOnly: Bool = true) async throws -> (PIMService, RoleSnapshot) {
        let service = env.makeService(tenant.tenantId, readOnly)
        return (service, try await service.loadRoles(now: env.now()))
    }

    // MARK: tenants

    func tenants(_ o: TenantsOptions) async throws -> CLIExit {
        let preferred = try o.tenant.map { try resolveTenant($0).tenantId } ?? nil
        let tenants = try await env.loadTenants(preferred)
        if o.json {
            out(CLIJSON.encode(CLIJSON.TenantList(tenants: tenants.map(CLIJSON.Tenant.init))))
            return .success
        }
        guard !tenants.isEmpty else {
            err("az knows no tenants. Run `az login` first.")
            return .auth
        }
        var table = TextTable(headers: ["TENANT ID", "NAME", "DOMAIN"], flexible: [1, 2])
        for t in tenants {
            table.append([
                .init(t.id, .dim),
                .init(t.name ?? "(unnamed)", t.isNamed ? .plain : .dim),
                .init(t.detail ?? "", .dim),
            ])
        }
        table.render(style: outStyle, maxWidth: env.terminalWidth).forEach { out($0) }
        return .success
    }

    // MARK: list

    func list(_ o: ListOptions) async throws -> CLIExit {
        let tenant = try resolveTenant(o.tenant)
        let snapshot: RoleSnapshot
        do { snapshot = try await load(tenant).1 } catch { return report(error, tenant: tenant.tenantId) }
        let roles = o.criteria.apply(snapshot.roles)
        if o.json {
            out(CLIJSON.encode(CLIJSON.RoleList(
                tenantId: snapshot.identity.tenantId ?? tenant.tenantId,
                user: .init(snapshot.identity), roles: roles.map { CLIJSON.Role($0) })))
            return .success
        }
        let interactive = env.stdoutIsTTY
        if interactive { out(outStyle.dim(signedIn(snapshot, tenant))) }
        guard !roles.isEmpty else {
            err(snapshot.roles.isEmpty ? "You have no eligible Azure-resource roles in this tenant." : "No roles match.")
            return .success
        }
        roleTable(roles, now: env.now()).render(style: outStyle, maxWidth: env.terminalWidth).forEach { out($0) }
        if interactive {
            let active = roles.filter(\.isActive).count
            out(outStyle.dim("\(CLIFormat.plural(roles.count, "role")), \(active) active"))
        }
        return .success
    }

    func signedIn(_ snapshot: RoleSnapshot, _ tenant: TenantSelection) -> String {
        let who = [snapshot.identity.name, snapshot.identity.upn.map { "<\($0)>" }].compactMap { $0 }.joined(separator: " ")
        let tid = snapshot.identity.tenantId ?? tenant.tenantId ?? "az's default tenant"
        return "Signed in as \(who.isEmpty ? snapshot.identity.objectId : who) · tenant \(tid)"
    }

    public func roleTable(_ roles: [EligibleRole], now: Date) -> TextTable {
        let showCondition = roles.contains(where: \.hasCondition)
        var headers = ["RESOURCE", "TYPE", "ROLE", "MEMBERSHIP"]
        if showCondition { headers.append("COND") }
        headers.append("STATUS")
        var table = TextTable(headers: headers, flexible: [0, 2, 3])
        for r in roles {
            var row: [TextTable.Cell] = [
                .init(r.scopeName),
                .init(r.scopeTypeLabel, .dim),
                .init(r.roleName, r.isOwner ? .strong : .plain),
                .init(r.membership.label, .dim),
            ]
            if showCondition { row.append(.init(r.hasCondition ? "yes" : "", .dim)) }
            row.append(statusCell(r, now: now))
            table.append(row)
        }
        return table
    }

    func statusCell(_ r: EligibleRole, now: Date) -> TextTable.Cell {
        guard r.isActive else { return .init("eligible", .dim) }
        guard let until = r.activeUntil else { return .init("active (no end)", .good) }
        let text = "active until \(CLIFormat.clock(until, now: now, timeZone: env.timeZone)) (\(CLIFormat.timeLeft(until: until, now: now)) left)"
        return .init(text, .good)
    }

    // MARK: status

    /// Active roles, soonest-expiring first; open-ended ones last.
    public static func activeRolesByExpiry(_ roles: [EligibleRole]) -> [EligibleRole] {
        roles.filter(\.isActive).sorted { a, b in
            switch (a.activeUntil, b.activeUntil) {
            case let (x?, y?) where x != y: return x < y
            case (_?, nil): return true
            case (nil, _?): return false
            default: return (a.scopeName.lowercased(), a.roleName) < (b.scopeName.lowercased(), b.roleName)
            }
        }
    }

    func status(_ o: StatusOptions) async throws -> CLIExit {
        let tenant = try resolveTenant(o.tenant)
        let snapshot: RoleSnapshot
        do { snapshot = try await load(tenant).1 } catch { return report(error, tenant: tenant.tenantId) }
        let now = env.now()
        let active = Self.activeRolesByExpiry(snapshot.roles)
        if o.json {
            out(CLIJSON.encode(CLIJSON.RoleList(
                tenantId: snapshot.identity.tenantId ?? tenant.tenantId,
                user: .init(snapshot.identity), roles: active.map { CLIJSON.Role($0, now: now) })))
            return .success
        }
        if env.stdoutIsTTY { out(outStyle.dim(signedIn(snapshot, tenant))) }
        guard !active.isEmpty else {
            out("No active roles.")
            return .success
        }
        var table = TextTable(headers: ["LEFT", "UNTIL", "ROLE", "RESOURCE", "TYPE"], flexible: [2, 3])
        for r in active {
            let left = r.activeUntil.map { CLIFormat.timeLeft(until: $0, now: now) } ?? "no end"
            let soon = r.activeUntil.map { $0.timeIntervalSince(now) < 15 * 60 } ?? false
            table.append([
                .init(left, soon ? .warn : .good),
                .init(r.activeUntil.map { CLIFormat.clock($0, now: now, timeZone: env.timeZone) } ?? "", .dim),
                .init(r.roleName, r.isOwner ? .strong : .plain),
                .init(r.scopeName),
                .init(r.scopeTypeLabel, .dim),
            ])
        }
        table.render(style: outStyle, maxWidth: env.terminalWidth).forEach { out($0) }
        return .success
    }

    // MARK: activate

    func activate(_ o: ActivateOptions) async throws -> CLIExit {
        // Decide before touching Azure: a script without --yes stops here.
        let policy = ConfirmationPolicy.decide(dryRun: o.dryRun, assumeYes: o.assumeYes, interactive: env.stdinIsTTY)
        if policy == .refuse { throw ConfirmationRequired() }

        let tenant = try resolveTenant(o.tenant)
        // A dry run gets a GET-only transport: it cannot send a PUT even by mistake.
        let service: PIMService, snapshot: RoleSnapshot
        do { (service, snapshot) = try await load(tenant, readOnly: o.dryRun) } catch { return report(error, tenant: tenant.tenantId) }
        let now = env.now()
        let matched = o.criteria.apply(snapshot.roles)
        guard !matched.isEmpty else {
            err(snapshot.roles.isEmpty
                ? "You have no eligible Azure-resource roles in this tenant."
                : "No eligible role matches. `pimento list` shows what there is.")
            return .failure
        }
        let skipped = matched.filter(\.isActive)
        let plans = try ActivationRequestBuilder.plan(
            matched.filter { !$0.isActive }, principalId: snapshot.identity.objectId,
            justification: o.justification, hours: o.hours, now: now)

        // Human-readable progress goes to stdout, or to stderr when stdout is JSON.
        let toStderr = o.json, runner = self
        let human: @Sendable (String) -> Void = { line in toStderr ? runner.err(line) : runner.out(line) }
        let style = o.json ? errStyle : outStyle
        let tenantLabel = snapshot.identity.tenantId ?? tenant.tenantId ?? "az's default tenant"

        func json(_ outcomes: [String: ActivationOutcome]) -> CLIJSON.Activation {
            let byRole = Dictionary(plans.map { ($0.role.id, $0) }, uniquingKeysWith: { a, _ in a })
            let results = matched.map { role in
                CLIJSON.Result(role: role, outcome: outcomes[role.id], plan: byRole[role.id])
            }
            return CLIJSON.Activation(
                dryRun: o.dryRun, tenantId: tenantLabel == "az's default tenant" ? nil : tenantLabel,
                user: .init(snapshot.identity), hours: o.hours, justification: o.justification,
                results: results, summary: .init(results))
        }

        for r in skipped {
            let until = r.activeUntil.map { " until " + CLIFormat.clock($0, now: now, timeZone: env.timeZone) } ?? ""
            human(style.dim("skip  \(r.roleName) · \(r.scopeName): already active\(until)"))
        }
        guard !plans.isEmpty else {
            human("Nothing to activate: \(skipped.count == 1 ? "the matching role is" : "all \(skipped.count) matching roles are") already active.")
            if o.json { out(CLIJSON.encode(json([:]))) }
            return .success
        }

        let owners = plans.filter(\.role.isOwner).count
        human((o.dryRun ? "Would activate " : "Activate ")
            + "\(CLIFormat.plural(plans.count, "role")) for \(CLIFormat.plural(o.hours, "hour")) in tenant \(tenantLabel):")
        var table = TextTable(headers: ["ROLE", "RESOURCE", "TYPE", "MEMBERSHIP"], flexible: [0, 1, 3])
        for p in plans {
            table.append([
                .init(p.role.isOwner ? "\(p.role.roleName) (!)" : p.role.roleName, p.role.isOwner ? .strong : .plain),
                .init(p.role.scopeName),
                .init(p.role.scopeTypeLabel, .dim),
                .init(p.role.membership.label, .dim),
            ])
        }
        table.render(style: style, maxWidth: o.json ? nil : env.terminalWidth).forEach { human("  " + $0) }
        if owners > 0 {
            human(style.boldRed("Warning:") + " \(CLIFormat.plural(owners, "Owner role")) (!): full control of the resource, including access.")
        }
        human("Justification: \(o.justification)")

        if o.dryRun {
            if !o.json {
                for p in plans {
                    out()
                    out(style.dim("# \(p.role.roleName) · \(p.role.scopeName)"))
                    out("PUT \(p.url.absoluteString)")
                    out(p.prettyBody)
                }
                out()
            }
            human("Dry run: \(CLIFormat.plural(plans.count, "request")) built, none sent.")
            if o.json { out(CLIJSON.encode(json([:]))) }
            return .success
        }

        if policy == .ask {
            env.write("Activate \(CLIFormat.plural(plans.count, "role"))\(owners > 0 ? ", including \(owners) Owner" : "")? [y/N] ", .err)
            guard ConfirmationPolicy.isYes(env.readLine()) else {
                err("Cancelled. Nothing was sent.")
                return .failure
            }
        }

        let collected = OutcomeBox()
        let tz = env.timeZone
        do {
            try await service.execute(plans, maxConcurrent: o.maxParallel) { plan, outcome in
                collected.set(plan.role.id, outcome)
                human(Self.resultLine(plan.role, outcome, now: now, timeZone: tz, style: style))
            }
        } catch {
            return report(error, tenant: tenant.tenantId)
        }
        let outcomes = collected.all
        let summary = CLIJSON.Summary(json(outcomes).results)
        var parts = ["\(summary.activated) activated"]
        if summary.submitted > 0 { parts.append("\(summary.submitted) submitted for approval") }
        if summary.skipped > 0 { parts.append("\(summary.skipped) already active") }
        if summary.failed > 0 { parts.append(style.red("\(summary.failed) failed")) }
        human(parts.joined(separator: ", ") + ".")
        if o.json { out(CLIJSON.encode(json(outcomes))) }
        let code = CLIExit.code(for: Array(outcomes.values))
        if code == .auth { err("hint: sign in with `\(AzureCLIError.loginCommand(tenant: tenant.tenantId))`") }
        return code
    }

    public static func resultLine(
        _ role: EligibleRole, _ outcome: ActivationOutcome, now: Date, timeZone: TimeZone, style: TerminalStyle
    ) -> String {
        let name = "\(role.roleName) · \(role.scopeName)"
        switch outcome {
        case .activated(let status, let until):
            guard ActivationOutcome.isGranted(status: status) else {
                return style.yellow("submitted") + "  \(name): \(status)"
            }
            let when = until.map { " until " + CLIFormat.clock($0, now: now, timeZone: timeZone) } ?? ""
            return style.green("activated") + "  \(name)\(when)"
        case .alreadyActive:
            return style.dim("skipped") + "    \(name): already active"
        case .policyViolation, .failed:
            return style.red("failed") + "     \(name): \(outcome.summary)"
        }
    }
}

/// Outcomes collected from the concurrent activation callbacks.
final class OutcomeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: ActivationOutcome] = [:]

    func set(_ id: String, _ outcome: ActivationOutcome) {
        lock.lock()
        values[id] = outcome
        lock.unlock()
    }

    var all: [String: ActivationOutcome] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }
}
