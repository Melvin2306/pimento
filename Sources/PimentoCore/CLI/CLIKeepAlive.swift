import Foundation

/// `pimento keep-alive`: the app's keep-alive as a foreground loop, for
/// Linux and Windows, servers, or a terminal tab. Same rules
/// (`KeepAlive`), same session (`KeepAliveSession`). Asks once (or `--yes`),
/// then runs until Ctrl-C, printing what it does.
extension CLIRunner {
    /// Longest wait between passes: new activations of matching roles are
    /// noticed within this.
    static let keepAliveMaxIdle: TimeInterval = 10 * 60
    static let keepAliveMinIdle: TimeInterval = 30
    /// After a failed read (network, throttling): wait this long, then try again.
    static let keepAliveReadRetry: TimeInterval = 5 * 60

    func keepAlive(_ o: KeepAliveOptions) async throws -> CLIExit {
        let confirm = ConfirmationPolicy.decide(dryRun: o.dryRun, assumeYes: o.assumeYes, interactive: env.stdinIsTTY)
        if confirm == .refuse { throw ConfirmationRequired(command: "keep-alive") }
        let s: Selected
        switch try await select(tenant: o.tenant, preset: o.preset, criteria: o.criteria, readOnly: o.dryRun) {
        case .exit(let code): return code
        case .ok(let selected): s = selected
        }
        let style = outStyle
        let hours = o.hours
        guard !hours.days.isEmpty else { throw CLIParseError.invalidDays("") }
        // What to keep alive, re-resolved at every pass so that roles you
        // activate later are kept alive too: the preset, or the selection as a rule.
        var rule: Preset
        if var p = s.preset {
            p.keepAlive = true
            if let d = o.duration { p.duration = d }
            if !o.justification.isEmpty { p.justification = o.justification }
            rule = p
        } else {
            let criteria = o.all ? PresetRule(roles: ["*"]) : PresetRule(filters: o.criteria.filters, roles: o.criteria.roles)
            rule = Preset(name: "command line", tenantId: s.tenantId, match: [criteria],
                          justification: o.justification.nonEmpty, duration: o.duration ?? .maximum, keepAlive: true)
        }
        if rule.duration == nil { rule.duration = .maximum }
        for m in s.missing { out(style.yellow("missing") + "  \(m.label): no longer eligible, left out") }
        let session = KeepAliveSession()
        let reader = s.service.readOnly
        let clock = env.now
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = env.timeZone
        let tz = env.timeZone
        // Access-granting roles (Owner, User Access Administrator, RBAC
        // Administrator) are kept alive only when confirmed: at the prompt
        // (those listed there), or by --yes (as for `activate`). nil: all.
        var confirmedAccess: Set<String>? = o.assumeYes ? nil : []
        func pass(dryRun: Bool) async throws -> KeepAlivePassResult {
            try await session.pass(reader: reader, writer: dryRun ? reader : s.service, perRole: [], presets: [rule], hours: hours,
                                   paused: false, calendar: calendar, clock: clock, dryRun: dryRun,
                                   confirmedAccess: dryRun ? nil : confirmedAccess)
        }

        // The plan: what is kept alive and where each role stands.
        let first: KeepAlivePassResult
        do { first = try await pass(dryRun: true) } catch { return report(error, tenant: s.tenant.tenantId) }
        guard !first.items.isEmpty else {
            err(s.preset != nil
                ? "None of the preset's roles are among your roles in tenant \(s.tenantLabel)."
                : "No role matches. `pimento list` shows your roles.")
            return .failure
        }
        let now = clock()
        out((o.dryRun ? "Would keep " : "Keep ") + "\(CLIFormat.plural(first.items.count, "role")) alive"
            + "\(s.preset.map { " (preset \($0.name))" } ?? "") in tenant \(s.tenantLabel), \(hours.label) (\(tz.identifier)):")
        var table = TextTable(headers: ["ROLE", "RESOURCE", "LEFT", "KEEP-ALIVE"], flexible: [0, 1, 3])
        for item in first.items {
            let r = item.role
            table.append([
                .init(r.grantsAccess ? "\(r.roleName) (!)" : r.roleName, r.grantsAccess ? .strong : .plain),
                .init(r.scopeName),
                .init(r.isActive ? (r.activeUntil.map { CLIFormat.timeLeft(until: $0, now: now) } ?? "no end") : "not active", .dim),
                .init(item.status.summary(now: now, timeZone: tz), item.status.needsAttention ? .strong : .plain),
            ])
        }
        table.render(style: style, maxWidth: env.terminalWidth).forEach { out("  " + $0) }
        out("Each role is continued by a new activation that starts when the current one ends (no gap), with the same "
            + "justification and ticket, for \(rule.duration.flatMap(\.hours).map { "\($0) h (capped at its policy)" } ?? "the longest its policy allows"), and never past "
            + "\(hours.end.text). A role that lapsed meanwhile is activated again (with a gap). Roles whose policy requires approval are "
            + "left alone.")
        let access = first.items.filter { $0.role.grantsAccess && !$0.status.isExcluded }
        let owners = access.count
        if owners > 0 {
            out(style.boldRed("Warning:") + " \(CLIFormat.plural(owners, "role")) (!) can grant access to anyone on the resource "
                + "(Owner, User Access Administrator, RBAC Administrator) and will be renewed without asking again.")
        }
        if o.dryRun {
            for item in first.actions {
                out(style.dim("would  \(item.role.roleName) · \(item.role.scopeName): \(item.status.summary(now: now, timeZone: tz))"))
            }
            out("Dry run: nothing sent.")
            return .success
        }
        if confirm == .ask {
            write("Keep \(CLIFormat.plural(first.items.count, "role")) alive\(owners > 0 ? ", including \(owners) that can grant access" : "") until you stop it (Ctrl-C)? [y/N] ", .err)
            guard ConfirmationPolicy.isYes(env.readLine()) else {
                err("Cancelled. Nothing was sent.")
                return .failure
            }
            // Confirmed: the access-granting roles listed. One that matches
            // later is not kept alive (run again, or with --yes).
            confirmedAccess = Set(access.map(\.key))
        }
        out(style.dim("Running. Ctrl-C stops; continuations already scheduled still start (`pimento scheduled`, `pimento cancel`)."))

        var shown: [String: String] = [:]
        var passes = 0
        while true {
            let result: KeepAlivePassResult
            do {
                result = try await pass(dryRun: false)
            } catch {
                let code = CLIExit.code(for: error)
                if code == .auth { return report(error, tenant: s.tenant.tenantId) }
                err(style.yellow("warn") + "   \(CLIFormat.clock(clock(), now: clock(), timeZone: tz))  reading your roles failed: "
                    + "\(error.localizedDescription). Trying again in \(Int(Self.keepAliveReadRetry / 60)) minutes.")
                passes += 1
                if let max = o.maxPasses, passes >= max { return .failure }
                await env.sleep(Self.keepAliveReadRetry)
                continue
            }
            let at = clock()
            let stamp = CLIFormat.clock(at, now: at, timeZone: tz)
            for event in result.events {
                out("\(stamp)  " + Self.keepAliveLine(event, now: at, timeZone: tz, style: style))
            }
            for item in result.items {
                let line = item.status.summary(now: at, timeZone: tz)
                guard shown[item.key] != line else { continue }
                shown[item.key] = line
                out(style.dim("\(stamp)  status  \(item.role.roleName) · \(item.role.scopeName): \(line)"))
            }
            noteClaims(in: result.events.compactMap { event -> ActivationOutcome? in
                if case .failed(_, let message, _, _) = event { return .failed(code: "", message: message) }
                return nil
            }, tenant: s.tenantId)
            passes += 1
            if let max = o.maxPasses, passes >= max { return .success }
            let next = result.nextCheck ?? at.addingTimeInterval(Self.keepAliveMaxIdle)
            await env.sleep(min(Self.keepAliveMaxIdle, max(Self.keepAliveMinIdle, next.timeIntervalSince(at))))
        }
    }

    static func keepAliveLine(_ event: KeepAliveEvent, now: Date, timeZone: TimeZone, style: TerminalStyle) -> String {
        let name = "\(event.role.roleName) · \(event.role.scopeName)"
        let t = { CLIFormat.clock($0, now: now, timeZone: timeZone) }
        switch event {
        case .renewed(_, let start, let until, let clipped, let lapsedAt):
            let how = lapsedAt.map { "activated again (it ended at \(t($0)))" } ?? "continues at \(t(start)), no gap"
            return style.green("renewed") + "  \(name) until \(t(until)): \(how)" + (clipped ? ", shortened to working hours" : "")
        case .failed(_, let message, let retryAt, let failures):
            let next = retryAt.map { "trying again at \(t($0))" } ?? "gave up after \(failures) failures until the next working hours"
            return style.red("failed") + "   \(name): \(message); \(next)"
        case .withdrawn:
            return style.yellow("stopped") + "  \(name): ended or replaced, its scheduled continuation was withdrawn"
        case .blocked(_, let why):
            return style.yellow("skipped") + "  \(name): " + (why == .needsTicket
                ? "its policy requires a ticket and the activation's ticket is unknown"
                : "the activation's justification is unknown (give one with -j)")
        case .lastOfDay(_, let end, let windowEnd):
            return style.dim("done") + "     \(name): ends at \(t(end)), less than an hour before \(t(windowEnd))"
        }
    }
}
