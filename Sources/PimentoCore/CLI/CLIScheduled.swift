import Foundation

/// Which pending requests `pimento cancel` is about.
public struct CancelSelection: Equatable, Sendable {
    /// In the order of `pending` (soonest first).
    public var requests: [ScheduledRequest] = []
    /// Targets that look like request ids but match no pending request.
    public var unknownIds: [String] = []

    /// A target of at least 4 characters made of hex digits and dashes is
    /// tried as the start of a request id first; anything else (and an id
    /// that matches nothing) is a resource filter as in `pimento list`.
    /// `roles` narrows the filters (and `--all`), not the ids.
    public static func select(_ pending: [ScheduledRequest], targets: [String], roles: [String], all: Bool) throws -> CancelSelection {
        var picked = Set<String>()
        var filters: [String] = []
        var unknown: [String] = []
        for target in targets {
            let t = target.trimmingCharacters(in: .whitespaces)
            guard !t.isEmpty else { continue }
            if isIdLike(t) {
                let hits = pending.filter { $0.name.lowercased().hasPrefix(t.lowercased()) }
                if hits.count > 1 { throw CLIParseError.ambiguousRequestId(t, matches: hits.count) }
                if let hit = hits.first {
                    picked.insert(hit.name)
                    continue
                }
                if t.count >= 8, !pending.contains(where: { RoleCriteria(filters: [t], roles: roles).matches($0.asRole) }) {
                    unknown.append(t)
                    continue
                }
            }
            filters.append(t)
        }
        if !filters.isEmpty || !roles.isEmpty || all {
            let criteria = RoleCriteria(filters: filters, roles: roles)
            for r in pending where criteria.matches(r.asRole) { picked.insert(r.name) }
        }
        return CancelSelection(requests: pending.filter { picked.contains($0.name) }, unknownIds: unknown)
    }

    static func isIdLike(_ s: String) -> Bool {
        s.count >= 4 && s.allSatisfy { $0.isHexDigit || $0 == "-" } && s.contains(where: \.isHexDigit)
    }
}

extension CLIJSON {
    /// One pending request in `pimento scheduled|cancel --json`.
    public struct PendingRequest: Encodable, Equatable, Sendable {
        public let id: String
        public let name: String
        /// `scheduled` or `awaitingApproval`.
        public let kind: String
        public let status: String
        public let start: String
        public let end: String?
        public let duration: String?
        public let roleName: String
        public let roleDefinitionId: String
        public let scope: String
        public let scopeName: String
        public let scopeType: String
        public let justification: String?
        public let ticketNumber: String?
        public let ticketSystem: String?
        public let createdOn: String?
        /// A request waiting for approval: when PIM lets it expire (24 hours).
        public let expiresAt: String?

        public init(_ r: ScheduledRequest) {
            id = r.id
            name = r.name
            kind = r.kind.rawValue
            status = r.status
            start = AzureDate.format(r.start)
            end = r.end.map(AzureDate.format)
            duration = r.durationMinutes.map { ISODuration.format(minutes: $0) }
            roleName = r.roleName
            roleDefinitionId = r.roleDefinitionId
            scope = r.scope
            scopeName = r.scopeName
            scopeType = r.scopeType
            justification = r.justification
            ticketNumber = r.ticketNumber
            ticketSystem = r.ticketSystem
            createdOn = r.createdOn.map(AzureDate.format)
            expiresAt = r.expiresAt.map(AzureDate.format)
        }
    }

    public struct PendingList: Encodable, Equatable, Sendable {
        public let tenantId: String?
        public let user: User
        public let requests: [PendingRequest]
    }

    public struct CancelResult: Encodable, Equatable, Sendable {
        /// `cancelled`, `planned` (dry run) or `failed`.
        public let outcome: String
        public let request: PendingRequest
        public let code: String?
        public let message: String?
        /// The POST that cancels it (dry run).
        public let url: String?

        public init(_ r: ScheduledRequest, outcome: CancelOutcome?) {
            request = PendingRequest(r)
            switch outcome {
            case nil:
                self.outcome = "planned"; code = nil; message = nil; url = r.cancelURL?.absoluteString
            case .canceled?:
                self.outcome = "cancelled"; code = nil; message = nil; url = nil
            case .notCancellable(let m)?:
                self.outcome = "failed"; code = CancelOutcome.notCancellableCode; message = m; url = nil
            case .failed(let c, let m)?:
                self.outcome = "failed"; code = c; message = m; url = nil
            }
        }
    }

    public struct Cancellation: Encodable, Equatable, Sendable {
        public struct Summary: Encodable, Equatable, Sendable {
            public var cancelled = 0
            public var failed = 0
            public var planned = 0
        }

        public let dryRun: Bool
        public let tenantId: String?
        public let user: User
        public let results: [CancelResult]
        /// Ids given that match no pending request.
        public let notFound: [String]?
        public let summary: Summary

        init(dryRun: Bool, tenantId: String?, user: User, results: [CancelResult], notFound: [String]) {
            self.dryRun = dryRun
            self.tenantId = tenantId
            self.user = user
            self.results = results
            self.notFound = notFound.isEmpty ? nil : notFound
            var s = Summary()
            for r in results {
                switch r.outcome {
                case "cancelled": s.cancelled += 1
                case "planned": s.planned += 1
                default: s.failed += 1
                }
            }
            summary = s
        }
    }
}

/// `pimento scheduled` and `pimento cancel`.
extension CLIRunner {
    func loadPending(_ tenant: TenantSelection, readOnly: Bool) async throws -> (PIMService, Identity, [ScheduledRequest]) {
        let service = env.makeService(tenant.tenantId, readOnly)
        let (identity, requests) = try await service.loadScheduledRequests(now: env.now())
        return (service, identity, requests)
    }

    func pendingTable(_ requests: [ScheduledRequest], now: Date, style: TerminalStyle, json: Bool) -> [String] {
        var table = TextTable(headers: ["ID", "STARTS", "FOR", "ROLE", "RESOURCE", "STATUS"], flexible: [3, 4])
        for r in requests {
            let starts = r.kind == .scheduled
                ? "\(ScheduleTime.label(r.start, now: now, timeZone: env.timeZone)) (in \(CLIFormat.timeLeft(until: r.start, now: now)))"
                : "on approval"
            table.append([
                .init(r.shortId, .dim),
                .init(starts),
                .init(r.durationMinutes.map { DurationText.short(minutes: $0) } ?? "", .dim),
                .init(r.isOwner ? "\(r.roleName) (!)" : r.roleName, r.isOwner ? .strong : .plain),
                .init(r.scopeName),
                .init(r.kind == .scheduled ? r.status : "\(r.status) (awaiting approval)", r.kind == .scheduled ? .good : .warn),
            ])
        }
        return table.render(style: style, maxWidth: json ? nil : env.terminalWidth)
    }

    // MARK: scheduled

    func scheduled(_ o: ScheduledOptions) async throws -> CLIExit {
        let tenant = try resolveTenant(o.tenant)
        let identity: Identity, requests: [ScheduledRequest]
        do { (_, identity, requests) = try await loadPending(tenant, readOnly: true) } catch { return report(error, tenant: tenant.tenantId) }
        let tenantId = identity.tenantId ?? tenant.tenantId
        if o.json {
            out(CLIJSON.encode(CLIJSON.PendingList(tenantId: tenantId, user: .init(identity), requests: requests.map(CLIJSON.PendingRequest.init))))
            return .success
        }
        guard !requests.isEmpty else {
            out("No scheduled or pending activations.")
            return .success
        }
        pendingTable(requests, now: env.now(), style: outStyle, json: false).forEach { out($0) }
        if env.stdoutIsTTY {
            out(outStyle.dim("\(CLIFormat.plural(requests.count, "request")) · cancel with `pimento cancel ID`"))
        }
        return .success
    }

    // MARK: cancel

    func cancel(_ o: CancelOptions) async throws -> CLIExit {
        let confirm = ConfirmationPolicy.decide(dryRun: o.dryRun, assumeYes: o.assumeYes, interactive: env.stdinIsTTY)
        if confirm == .refuse { throw ConfirmationRequired(command: "cancel") }
        let tenant = try resolveTenant(o.tenant)
        let service: PIMService, identity: Identity, pending: [ScheduledRequest]
        do { (service, identity, pending) = try await loadPending(tenant, readOnly: o.dryRun) } catch { return report(error, tenant: tenant.tenantId) }
        let tenantId = identity.tenantId ?? tenant.tenantId
        let selection = try CancelSelection.select(pending, targets: o.targets, roles: o.roles, all: o.all)
        let now = env.now()
        let human = humanWriter(json: o.json)
        let style = o.json ? errStyle : outStyle

        func json(_ outcomes: [String: CancelOutcome]) -> CLIJSON.Cancellation {
            CLIJSON.Cancellation(
                dryRun: o.dryRun, tenantId: tenantId, user: .init(identity),
                results: selection.requests.map { CLIJSON.CancelResult($0, outcome: outcomes[$0.name]) },
                notFound: selection.unknownIds)
        }

        for id in selection.unknownIds { human(style.yellow("not found") + "  \(id): no pending request with this id") }
        guard !selection.requests.isEmpty else {
            err(pending.isEmpty
                ? "You have no scheduled or pending activations."
                : "No pending request matches. `pimento scheduled` lists them.")
            if o.json { out(CLIJSON.encode(json([:]))) }
            return .failure
        }
        human((o.dryRun ? "Would cancel " : "Cancel ") + "\(CLIFormat.plural(selection.requests.count, "request")) in tenant \(tenantId ?? "az's default tenant"):")
        pendingTable(selection.requests, now: now, style: style, json: o.json).forEach { human("  " + $0) }
        if o.dryRun {
            if !o.json {
                out()
                for r in selection.requests { out("POST \(r.cancelURL?.absoluteString ?? "(invalid request id)")") }
                out()
            }
            human("Dry run: nothing was cancelled.")
            if o.json { out(CLIJSON.encode(json([:]))) }
            return selection.unknownIds.isEmpty ? .success : .failure
        }
        if confirm == .ask {
            env.write("Cancel \(CLIFormat.plural(selection.requests.count, "request"))? [y/N] ", .err)
            guard ConfirmationPolicy.isYes(env.readLine()) else {
                err("Nothing was cancelled.")
                return .failure
            }
        }
        let box = CancelOutcomeBox()
        let tz = env.timeZone
        do {
            try await service.cancel(selection.requests) { r, outcome in
                box.set(r.name, outcome)
                let name = "\(r.roleName) · \(r.scopeName)"
                switch outcome {
                case .canceled:
                    let when = r.kind == .scheduled ? " (was to start \(ScheduleTime.label(r.start, now: now, timeZone: tz)))" : ""
                    human(style.green("cancelled") + "  \(name)\(when)")
                default:
                    human(style.red("failed") + "     \(name): \(outcome.summary)")
                }
            }
        } catch {
            return report(error, tenant: tenant.tenantId)
        }
        let outcomes = box.all
        let doc = json(outcomes)
        var parts = ["\(doc.summary.cancelled) cancelled"]
        if doc.summary.failed > 0 { parts.append(style.red("\(doc.summary.failed) failed")) }
        if !selection.unknownIds.isEmpty { parts.append(style.yellow("\(selection.unknownIds.count) not found")) }
        human(parts.joined(separator: ", ") + ".")
        if o.json { out(CLIJSON.encode(doc)) }
        let failures = outcomes.values.filter(\.isFailure)
        if !failures.isEmpty, failures.allSatisfy(\.isAuthFailure) {
            err("hint: sign in with `\(AzureCLIError.loginCommand(tenant: tenant.tenantId))`")
            return .auth
        }
        return failures.isEmpty && selection.unknownIds.isEmpty ? .success : .failure
    }
}

final class CancelOutcomeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: CancelOutcome] = [:]

    func set(_ id: String, _ outcome: CancelOutcome) {
        lock.lock()
        values[id] = outcome
        lock.unlock()
    }

    var all: [String: CancelOutcome] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }
}
