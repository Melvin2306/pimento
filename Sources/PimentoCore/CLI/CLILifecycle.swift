import Foundation

/// `pimento deactivate`, `pimento renew` and `pimento extend`: the commands
/// that change roles that are already active. Same safety rules as
/// `activate`: an explicit selection, the plan first, a prompt on a terminal,
/// `--yes` required without one, and `--dry-run` on a GET-only transport.
extension CLIRunner {
    struct Selected {
        let service: PIMService
        let snapshot: RoleSnapshot
        let tenant: TenantSelection
        let tenantId: String?
        let preset: Preset?
        let matched: [EligibleRole]
        let missing: [PresetRole]

        var tenantLabel: String { tenantId ?? "az's default tenant" }
    }

    enum Selection {
        case ok(Selected)
        case exit(CLIExit)
    }

    /// Loads the roles and picks the ones a preset or the filters name.
    func select(tenant flag: String?, preset name: String?, criteria: RoleCriteria, readOnly: Bool) async throws -> Selection {
        let store = PresetStore(environment: env.variables)
        var library: PresetLibrary?
        var tenant = try resolveTenant(flag)
        if let name {
            library = try store.load()
            if tenant.tenantId == nil, let only = library?.named(name), only.count == 1, let tid = only[0].tenantId {
                tenant = TenantSelection(tenantId: tid, source: .commandLine)
            }
        }
        let service: PIMService, snapshot: RoleSnapshot
        do { (service, snapshot) = try await load(tenant, readOnly: readOnly) } catch { return .exit(report(error, tenant: tenant.tenantId)) }
        let tenantId = snapshot.identity.tenantId ?? tenant.tenantId
        if let name, let library {
            let p = try library.find(name, tenantId: tenantId)
            let resolution = p.resolve(in: snapshot.roles)
            for rule in resolution.unmatchedRules {
                err(errStyle.yellow("note:") + " the preset's rule `\(rule.label)` matches no role")
            }
            return .ok(Selected(service: service, snapshot: snapshot, tenant: tenant, tenantId: tenantId, preset: p,
                                matched: resolution.roles, missing: resolution.missing))
        }
        return .ok(Selected(service: service, snapshot: snapshot, tenant: tenant, tenantId: tenantId, preset: nil,
                            matched: criteria.apply(snapshot.roles), missing: []))
    }

    /// Prints to stdout, or to stderr when stdout is JSON.
    func humanWriter(json: Bool) -> @Sendable (String) -> Void {
        let runner = self
        return { line in json ? runner.err(line) : runner.out(line) }
    }

    func activeTable(_ roles: [EligibleRole], now: Date, style: TerminalStyle, json: Bool, extra: ((EligibleRole) -> TextTable.Cell)? = nil, extraHeader: String = "") -> [String] {
        var headers = ["ROLE", "RESOURCE", "TYPE", "LEFT"]
        if extra != nil { headers.append(extraHeader) }
        var table = TextTable(headers: headers, flexible: [0, 1])
        for r in roles {
            var row: [TextTable.Cell] = [
                .init(r.isOwner ? "\(r.roleName) (!)" : r.roleName, r.isOwner ? .strong : .plain),
                .init(r.scopeName),
                .init(r.scopeTypeLabel, .dim),
                .init(r.activeUntil.map { CLIFormat.timeLeft(until: $0, now: now) } ?? "no end", .dim),
            ]
            if let extra { row.append(extra(r)) }
            table.append(row)
        }
        return table.render(style: style, maxWidth: json ? nil : env.terminalWidth)
    }

    func printSkips(_ selection: RoleLifecycle.Selection, now: Date, style: TerminalStyle, human: (String) -> Void) {
        for r in selection.inactive {
            human(style.dim("skip  \(r.roleName) · \(r.scopeName): not active"))
        }
        for r in selection.tooSoon {
            human(Self.resultLine(r, .tooSoon(possibleAt: RoleLifecycle.earliestDeactivation(of: r)), now: now, timeZone: env.timeZone, style: style))
        }
        for r in selection.needsApproval {
            human(style.yellow("skip") + "  \(r.roleName) · \(r.scopeName): its policy requires approval, "
                + "so after ending it you would wait for an approver. Not renewed.")
        }
        for r in selection.needsTicket {
            human(style.yellow("skip") + "  \(r.roleName) · \(r.scopeName): its policy requires a ticket and the ticket of "
                + "the current activation is unknown. Add --ticket NUMBER --ticket-system NAME. Not renewed.")
        }
    }

    func summaryLine(_ summary: CLIJSON.Summary, missing: Int, style: TerminalStyle) -> String {
        var parts: [String] = []
        if let n = summary.deactivated { parts.append("\(n) deactivated") }
        if let n = summary.renewed { parts.append("\(n) renewed") }
        if summary.activated > 0 { parts.append("\(summary.activated) activated") }
        if summary.submitted > 0 { parts.append("\(summary.submitted) submitted for approval") }
        if summary.skipped > 0 { parts.append("\(summary.skipped) skipped") }
        if summary.failed > 0 { parts.append(style.red("\(summary.failed) failed")) }
        if missing > 0 { parts.append(style.yellow("\(missing) missing")) }
        return (parts.isEmpty ? ["nothing done"] : parts).joined(separator: ", ") + "."
    }

    // MARK: deactivate

    func deactivate(_ o: LifecycleOptions) async throws -> CLIExit {
        let confirm = ConfirmationPolicy.decide(dryRun: o.dryRun, assumeYes: o.assumeYes, interactive: env.stdinIsTTY)
        if confirm == .refuse { throw ConfirmationRequired(command: "deactivate") }
        let s: Selected
        switch try await select(tenant: o.tenant, preset: o.preset, criteria: o.criteria, readOnly: o.dryRun) {
        case .exit(let code): return code
        case .ok(let selected): s = selected
        }
        let now = env.now()
        let human = humanWriter(json: o.json)
        let style = o.json ? errStyle : outStyle
        for m in s.missing { human(style.yellow("missing") + "  \(m.label): no longer eligible, left out") }

        let selection = RoleLifecycle.select(s.matched, now: now)
        let plans = try ActivationRequestBuilder.deactivationPlan(
            selection.ready, principalId: s.snapshot.identity.objectId, justification: o.justification, now: now)
        var outcomes: [String: ActivationOutcome] = [:]
        for r in selection.tooSoon { outcomes[r.id] = .tooSoon(possibleAt: RoleLifecycle.earliestDeactivation(of: r)) }

        func json(_ outcomes: [String: ActivationOutcome]) -> CLIJSON.Lifecycle {
            let byRole = Dictionary(plans.map { ($0.role.id, $0) }, uniquingKeysWith: { a, _ in a })
            let roles = selection.ready + selection.tooSoon + selection.inactive
            let results = roles.map { CLIJSON.Result(role: $0, outcome: outcomes[$0.id], plan: byRole[$0.id], skipReason: "not active") }
            return CLIJSON.Lifecycle(
                action: "deactivate", dryRun: o.dryRun, tenantId: s.tenantId, user: .init(s.snapshot.identity),
                preset: s.preset?.name, justification: plans.first?.body.properties.justification, duration: nil,
                results: results, missing: s.missing.isEmpty ? nil : s.missing.map(CLIJSON.MissingRole.init),
                summary: .init(results, operation: .deactivate))
        }

        guard !selection.isEmpty else {
            err(s.preset != nil
                ? "None of the preset's roles are among your roles in tenant \(s.tenantLabel)."
                : "No active role matches. `pimento status` shows what is active.")
            if o.json { out(CLIJSON.encode(json([:]))) }
            return .failure
        }
        printSkips(selection, now: now, style: style, human: human)
        guard !plans.isEmpty else {
            if selection.tooSoon.isEmpty {
                human("Nothing to deactivate: \(selection.inactive.count == 1 ? "the matching role is" : "the matching roles are") not active.")
                if o.json { out(CLIJSON.encode(json(outcomes))) }
                return .success
            }
            human("Nothing to deactivate yet: PIM ends an activation only 5 minutes after it started.")
            if o.json { out(CLIJSON.encode(json(outcomes))) }
            return .failure
        }

        let owners = plans.filter(\.role.isOwner).count
        human((o.dryRun ? "Would deactivate " : "Deactivate ")
            + "\(CLIFormat.plural(plans.count, "role"))\(s.preset.map { " (preset \($0.name))" } ?? "") in tenant \(s.tenantLabel):")
        activeTable(plans.map(\.role), now: now, style: style, json: o.json).forEach { human("  " + $0) }
        human("Access through \(plans.count == 1 ? "this role" : "these roles") ends now (PIM removes the assignment within seconds).")
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
            if o.json { out(CLIJSON.encode(json(outcomes))) }
            return selection.tooSoon.isEmpty ? .success : .failure
        }
        if confirm == .ask {
            env.write("Deactivate \(CLIFormat.plural(plans.count, "role"))\(owners > 0 ? ", including \(owners) Owner" : "")? [y/N] ", .err)
            guard ConfirmationPolicy.isYes(env.readLine()) else {
                err("Cancelled. Nothing was sent.")
                return .failure
            }
        }
        let collected = OutcomeBox()
        for (id, outcome) in outcomes { collected.set(id, outcome) }
        let tz = env.timeZone
        do {
            try await s.service.execute(plans, maxConcurrent: o.maxParallel) { plan, outcome in
                collected.set(plan.role.id, outcome)
                human(Self.resultLine(plan.role, outcome, now: now, timeZone: tz, style: style))
            }
        } catch {
            return report(error, tenant: s.tenant.tenantId)
        }
        let all = collected.all
        let doc = json(all)
        human(summaryLine(doc.summary, missing: s.missing.count, style: style))
        if o.json { out(CLIJSON.encode(doc)) }
        let code = CLIExit.code(for: Array(all.values))
        if code == .auth { err(loginHint(tenant: s.tenant.tenantId)) }
        noteClaims(in: Array(all.values), tenant: s.tenantId)
        return code
    }

    // MARK: renew

    func renew(_ o: LifecycleOptions) async throws -> CLIExit {
        let confirm = ConfirmationPolicy.decide(dryRun: o.dryRun, assumeYes: o.assumeYes, interactive: env.stdinIsTTY)
        if confirm == .refuse { throw ConfirmationRequired(command: "renew") }
        let s: Selected
        switch try await select(tenant: o.tenant, preset: o.preset, criteria: o.criteria, readOnly: o.dryRun) {
        case .exit(let code): return code
        case .ok(let selected): s = selected
        }
        let justification = o.justification.isEmpty ? (s.preset?.trimmedJustification ?? "") : o.justification
        guard !justification.isEmpty else { throw CLIParseError.missingJustificationFor("renew") }
        let requested = o.duration ?? s.preset?.duration ?? .hours(ActivationRequestBuilder.defaultHours)
        let now = env.now()
        let human = humanWriter(json: o.json)
        let style = o.json ? errStyle : outStyle
        for m in s.missing { human(style.yellow("missing") + "  \(m.label): no longer eligible, left out") }

        let active = s.matched.filter(\.isActive)
        let policies = await self.policies(for: active, service: s.service)
        // The ticket to send again: --ticket, else the one the activation was requested with.
        let given = TicketInfo.make(number: o.ticketNumber,
                                    system: o.ticketSystem ?? (o.ticketNumber != nil ? s.preset?.trimmedTicketSystem : nil))
        let originals = active.isEmpty ? [:] : ((try? await s.service.loadRequestHistory(now: now))?.activationTickets ?? [:])
        func ticket(_ role: EligibleRole) -> TicketInfo? {
            RenewTicket.choose(given: given, original: RequestHistory.ticket(for: role, in: originals))
        }
        let selection = RoleLifecycle.select(
            s.matched, now: now, forRenewal: true,
            needsTicket: { RenewTicket.isMissing($0, ticket: ticket($0), policy: policies[$0.policyKey]) },
            requiresApproval: { policies[$0.policyKey]?.policy?.requiresApproval == true })
        let plans = try ActivationRequestBuilder.renewPlan(
            selection.ready, principalId: s.snapshot.identity.objectId, justification: justification, now: now, ticket: ticket
        ) { role in
            EffectiveDuration.resolve(requested, policyMaxMinutes: policies[role.policyKey]?.maxMinutes,
                                      fallbackHours: ActivationRequestBuilder.defaultHours)
        }
        var outcomes: [String: ActivationOutcome] = [:]
        for r in selection.tooSoon { outcomes[r.id] = .tooSoon(possibleAt: RoleLifecycle.earliestDeactivation(of: r)) }
        for r in selection.needsApproval {
            outcomes[r.id] = .failed(code: "ApprovalRequired", message: "the role's policy requires approval; renewing would leave it off until approved")
        }
        for r in selection.needsTicket {
            outcomes[r.id] = .failed(code: "TicketRequired",
                                     message: "the role's policy requires a ticket and the current activation's is unknown; add --ticket NUMBER --ticket-system NAME")
        }

        func json(_ outcomes: [String: ActivationOutcome]) -> CLIJSON.Lifecycle {
            let byRole = Dictionary(plans.map { ($0.role.id, $0) }, uniquingKeysWith: { a, _ in a })
            let roles = selection.ready + selection.tooSoon + selection.needsApproval + selection.needsTicket + selection.inactive
            let results = roles.map { role in
                CLIJSON.Result(role: role, outcome: outcomes[role.id], plan: byRole[role.id]?.deactivation,
                               followUp: byRole[role.id]?.plannedActivation, skipReason: "not active")
            }
            return CLIJSON.Lifecycle(
                action: "renew", dryRun: o.dryRun, tenantId: s.tenantId, user: .init(s.snapshot.identity),
                preset: s.preset?.name, justification: justification, duration: requested.stringValue,
                results: results, missing: s.missing.isEmpty ? nil : s.missing.map(CLIJSON.MissingRole.init),
                summary: .init(results, operation: .renew))
        }

        guard !selection.isEmpty else {
            err(s.preset != nil
                ? "None of the preset's roles are among your roles in tenant \(s.tenantLabel)."
                : "No active role matches. `pimento status` shows what is active.")
            if o.json { out(CLIJSON.encode(json([:]))) }
            return .failure
        }
        printSkips(selection, now: now, style: style, human: human)
        guard !plans.isEmpty else {
            let onlyInactive = selection.tooSoon.isEmpty && selection.needsApproval.isEmpty && selection.needsTicket.isEmpty
            human(onlyInactive ? "Nothing to renew: the matching roles are not active. Use `pimento activate`." : "Nothing to renew.")
            if o.json { out(CLIJSON.encode(json(outcomes))) }
            return onlyInactive ? .success : .failure
        }

        let owners = plans.filter(\.role.isOwner).count
        human((o.dryRun ? "Would renew " : "Renew ")
            + "\(CLIFormat.plural(plans.count, "role"))\(s.preset.map { " (preset \($0.name))" } ?? "") in tenant \(s.tenantLabel):")
        let byRole = Dictionary(plans.map { ($0.role.id, $0) }, uniquingKeysWith: { a, _ in a })
        activeTable(plans.map(\.role), now: now, style: style, json: o.json, extra: { role in
            byRole[role.id].map { Self.durationCell($0.duration) } ?? .init("")
        }, extraHeader: "NEW DURATION").forEach { human("  " + $0) }
        human(style.yellow("Warning:") + " each role is deactivated and then activated again. In between it is NOT active: "
            + "PIM accepts the new activation only once it has removed the old one, typically after 1-3 minutes "
            + "(Pimento keeps trying for 5). Operations that need the role fail meanwhile. If activating again fails, the role stays off.")
        if owners > 0 {
            human(style.boldRed("Warning:") + " \(CLIFormat.plural(owners, "Owner role")) (!): full control of the resource, including access.")
        }
        human("Justification: \(justification)")
        if let given { human("Ticket: \(given.label)") }
        let reused = plans.filter { given == nil && $0.ticket != nil }
        if !reused.isEmpty {
            human("Ticket: the one each activation was requested with (\(Set(reused.compactMap { $0.ticket?.label }).sorted().joined(separator: ", ")))")
        }
        if o.dryRun {
            if !o.json {
                for p in plans {
                    out()
                    out(style.dim("# \(p.role.roleName) · \(p.role.scopeName): 1. end"))
                    out("PUT \(p.deactivation.url.absoluteString)")
                    out(p.deactivation.prettyBody)
                    out(style.dim("# 2. activate again (new request id and start time when sent)"))
                    out("PUT \(p.plannedActivation.url.absoluteString)")
                    out(p.plannedActivation.prettyBody)
                }
                out()
            }
            human("Dry run: \(CLIFormat.plural(plans.count * 2, "request")) built, none sent.")
            if o.json { out(CLIJSON.encode(json(outcomes))) }
            return outcomes.isEmpty ? .success : .failure
        }
        if confirm == .ask {
            env.write("Renew \(CLIFormat.plural(plans.count, "role"))\(owners > 0 ? ", including \(owners) Owner" : "") (off for a few minutes)? [y/N] ", .err)
            guard ConfirmationPolicy.isYes(env.readLine()) else {
                err("Cancelled. Nothing was sent.")
                return .failure
            }
        }
        let collected = OutcomeBox()
        for (id, outcome) in outcomes { collected.set(id, outcome) }
        let tz = env.timeZone
        do {
            try await s.service.renew(plans, maxConcurrent: min(o.maxParallel, 4), onPhase: { plan, phase in
                if case .reactivating(let attempt) = phase, attempt > 1 {
                    human(style.dim("wait   \(plan.role.roleName) · \(plan.role.scopeName): PIM still holds the old activation, trying again (attempt \(attempt))"))
                }
            }) { plan, outcome in
                collected.set(plan.role.id, outcome)
                human(Self.resultLine(plan.role, outcome, now: now, timeZone: tz, style: style))
            }
        } catch {
            return report(error, tenant: s.tenant.tenantId)
        }
        let all = collected.all
        let doc = json(all)
        human(summaryLine(doc.summary, missing: s.missing.count, style: style))
        if o.json { out(CLIJSON.encode(doc)) }
        let code = CLIExit.code(for: Array(all.values))
        if code == .auth { err(loginHint(tenant: s.tenant.tenantId)) }
        noteClaims(in: Array(all.values), tenant: s.tenantId)
        return code
    }

    // MARK: extend

    func extend(_ o: ExtendOptions) async throws -> CLIExit {
        let confirm = ConfirmationPolicy.decide(dryRun: o.dryRun, assumeYes: o.assumeYes, interactive: env.stdinIsTTY)
        if confirm == .refuse { throw ConfirmationRequired(command: "extend") }
        let s: Selected
        switch try await select(tenant: o.tenant, preset: nil, criteria: o.criteria, readOnly: o.dryRun) {
        case .exit(let code): return code
        case .ok(let selected): s = selected
        }
        let now = env.now()
        let human = humanWriter(json: o.json)
        let style = o.json ? errStyle : outStyle
        let assignments = s.snapshot.timeBoundAssignments.filter(o.criteria.matches)
        let active = RoleLifecycle.select(s.matched, now: now)
        let activations = active.ready + active.tooSoon
        let plans = try ActivationRequestBuilder.extensionPlan(
            assignments, principalId: s.snapshot.identity.objectId, justification: o.justification, days: o.days, now: now)

        func json(_ outcomes: [String: ActivationOutcome]) -> CLIJSON.Lifecycle {
            let byRole = Dictionary(plans.map { ($0.role.id, $0) }, uniquingKeysWith: { a, _ in a })
            var results = plans.map { CLIJSON.Result(role: $0.role, outcome: outcomes[$0.role.id], plan: byRole[$0.role.id]) }
            results += activations.map {
                CLIJSON.Result(role: $0, outcome: nil, plan: nil, skipReason: "PIM activation: use `pimento renew`")
            }
            return CLIJSON.Lifecycle(
                action: "extend", dryRun: o.dryRun, tenantId: s.tenantId, user: .init(s.snapshot.identity),
                preset: nil, justification: o.justification, duration: "P\(o.days)D",
                results: results, missing: nil, summary: .init(results, operation: .extend))
        }

        if !activations.isEmpty {
            human(style.yellow("note:") + " \(CLIFormat.plural(activations.count, "matching role")) "
                + "\(activations.count == 1 ? "is a PIM activation" : "are PIM activations"), left out. PIM does not let you extend "
                + "an activation yourself: it files the request for an administrator and keeps the end time. "
                + "Use `pimento renew` to start a fresh activation.")
        }
        guard !plans.isEmpty else {
            err("No admin-assigned, time-bound active assignment matches. `extend` is for those; "
                + "activations are renewed with `pimento renew`.")
            if o.json { out(CLIJSON.encode(json([:]))) }
            return .failure
        }
        human((o.dryRun ? "Would request " : "Request ")
            + "an extension by \(CLIFormat.plural(o.days, "day")) for \(CLIFormat.plural(plans.count, "assignment")) in tenant \(s.tenantLabel):")
        activeTable(plans.map(\.role), now: now, style: style, json: o.json).forEach { human("  " + $0) }
        human("An administrator of each resource must approve; until then nothing changes.")
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
        if confirm == .ask {
            env.write("Request \(CLIFormat.plural(plans.count, "extension"))? [y/N] ", .err)
            guard ConfirmationPolicy.isYes(env.readLine()) else {
                err("Cancelled. Nothing was sent.")
                return .failure
            }
        }
        let collected = OutcomeBox()
        let tz = env.timeZone
        do {
            try await s.service.execute(plans, maxConcurrent: 4) { plan, outcome in
                collected.set(plan.role.id, outcome)
                human(Self.resultLine(plan.role, outcome, now: now, timeZone: tz, style: style))
            }
        } catch {
            return report(error, tenant: s.tenant.tenantId)
        }
        let all = collected.all
        let doc = json(all)
        human(summaryLine(doc.summary, missing: 0, style: style))
        if o.json { out(CLIJSON.encode(doc)) }
        let code = CLIExit.code(for: Array(all.values))
        if code == .auth { err(loginHint(tenant: s.tenant.tenantId)) }
        noteClaims(in: Array(all.values), tenant: s.tenantId)
        return code
    }
}
