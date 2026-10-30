import Foundation

// `pimento pending`, `pimento wait` (requester side) and `pimento approvals`,
// `pimento approve`, `pimento deny` (approver side).

extension CLIJSON {
    public struct Requester: Encodable, Equatable, Sendable {
        public let objectId: String
        public let name: String?
        public let email: String?
    }

    /// One request in `pimento approvals|approve|deny --json`.
    public struct ApprovalDoc: Encodable, Equatable, Sendable {
        public let id: String
        public let name: String
        public let approvalId: String
        /// The stage a decision goes to; absent when none waits for you.
        public let stageId: String?
        public let requester: Requester
        public let roleName: String
        public let roleDefinitionId: String
        public let scope: String
        public let scopeName: String
        public let scopeType: String
        public let isOwner: Bool
        public let status: String
        public let start: String?
        public let end: String?
        public let duration: String?
        public let justification: String?
        public let ticketNumber: String?
        public let ticketSystem: String?
        public let createdOn: String?
        public let expiresAt: String?

        public init(_ r: ApprovalRequest) {
            id = r.id
            name = r.name
            approvalId = r.approvalId
            stageId = r.stage?.id
            requester = Requester(objectId: r.requesterId, name: r.requesterName, email: r.requesterEmail)
            roleName = r.roleName
            roleDefinitionId = r.roleDefinitionId
            scope = r.scope
            scopeName = r.scopeName
            scopeType = r.scopeType
            isOwner = r.isOwner
            status = r.status
            start = r.start.map(AzureDate.format)
            end = r.end.map(AzureDate.format)
            duration = r.durationMinutes.map { ISODuration.format(minutes: $0) }
            justification = r.justification
            ticketNumber = r.ticketNumber
            ticketSystem = r.ticketSystem
            createdOn = r.createdOn.map(AzureDate.format)
            expiresAt = r.expiresAt.map(AzureDate.format)
        }
    }

    public struct ApprovalList: Encodable, Equatable, Sendable {
        public let tenantId: String?
        public let user: User
        /// False when Azure refused to list approvals for you (`note` says why).
        public let available: Bool
        public let note: String?
        public let requests: [ApprovalDoc]
    }

    public struct DecisionResult: Encodable, Equatable, Sendable {
        /// `approved`, `denied`, `planned` (dry run), `skipped` (no stage waits for you) or `failed`.
        public let outcome: String
        public let request: ApprovalDoc
        public let code: String?
        public let message: String?
        /// Dry run: the PATCH and its body.
        public let url: String?
        public let body: ApprovalDecisionBody?

        public init(_ plan: PlannedDecision, outcome: DecisionOutcome?, dryRun: Bool) {
            request = ApprovalDoc(plan.request)
            url = dryRun ? plan.url?.absoluteString : nil
            body = dryRun && plan.url != nil ? plan.body : nil
            switch outcome {
            case nil:
                self.outcome = plan.url == nil ? "skipped" : "planned"
                code = nil
                message = plan.url == nil ? DecisionOutcome.noOpenStageMessage : nil
            case .decided(let d)?:
                self.outcome = d.pastTense; code = nil; message = nil
            case .notPending(let m)?:
                self.outcome = "skipped"; code = nil; message = m
            case .failed(let c, let m)?:
                self.outcome = "failed"; code = c; message = m
            }
        }
    }

    public struct Decisions: Encodable, Equatable, Sendable {
        public struct Summary: Encodable, Equatable, Sendable {
            public var decided = 0
            public var skipped = 0
            public var failed = 0
            public var planned = 0
        }

        /// `approve` or `deny`.
        public let decision: String
        public let dryRun: Bool
        public let tenantId: String?
        public let user: User
        public let justification: String
        public let results: [DecisionResult]
        public let notFound: [String]?
        public let summary: Summary

        init(decision: ApprovalDecision, dryRun: Bool, tenantId: String?, user: User, justification: String,
             results: [DecisionResult], notFound: [String]) {
            self.decision = decision.command
            self.dryRun = dryRun
            self.tenantId = tenantId
            self.user = user
            self.justification = justification
            self.results = results
            self.notFound = notFound.isEmpty ? nil : notFound
            var s = Summary()
            for r in results {
                switch r.outcome {
                case "approved", "denied": s.decided += 1
                case "planned": s.planned += 1
                case "skipped": s.skipped += 1
                default: s.failed += 1
                }
            }
            summary = s
        }
    }

    public struct WaitResult: Encodable, Equatable, Sendable {
        /// What was asked for (an id or its start).
        public let target: String
        /// `approved`, `denied`, `expired`, `canceled`, `failed`, `timeout` or `notFound`.
        public let outcome: String
        public let status: String?
        public let request: PendingRequest?
        /// Approved: when the activation ends.
        public let until: String?
        public let reviewer: String?
        public let reviewJustification: String?
    }

    public struct Waiting: Encodable, Equatable, Sendable {
        public struct Summary: Encodable, Equatable, Sendable {
            public var approved = 0
            public var rejected = 0
            public var timedOut = 0
            public var notFound = 0
        }

        public let tenantId: String?
        public let user: User
        /// Seconds.
        public let timeout: Int
        public let results: [WaitResult]
        public let summary: Summary

        init(tenantId: String?, user: User, timeout: TimeInterval, results: [WaitResult]) {
            self.tenantId = tenantId
            self.user = user
            self.timeout = Int(timeout)
            self.results = results
            var s = Summary()
            for r in results {
                switch r.outcome {
                case "approved": s.approved += 1
                case "timeout": s.timedOut += 1
                case "notFound": s.notFound += 1
                default: s.rejected += 1
                }
            }
            summary = s
        }
    }
}

/// Picks items by request id: each target is the start of exactly one name
/// (`exact`: each target is a whole name).
public enum RequestIdSelection {
    /// A whole request id: a GUID (36 characters).
    public static func isFullId(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespaces)
        return t.count == 36 && UUID(uuidString: t) != nil
    }

    public static func pick<T>(_ items: [T], name: (T) -> String, targets: [String], exact: Bool = false) throws -> (picked: [T], notFound: [String]) {
        var picked: [T] = []
        var seen = Set<String>()
        var notFound: [String] = []
        for target in targets {
            let t = target.trimmingCharacters(in: .whitespaces).lowercased()
            var hits: [T] = []
            var hitNames = Set<String>()
            for item in items where (exact ? name(item).lowercased() == t : name(item).lowercased().hasPrefix(t))
                && hitNames.insert(name(item).lowercased()).inserted {
                hits.append(item)
            }
            if hits.count > 1 { throw CLIParseError.ambiguousRequestId(target, matches: hits.count) }
            guard let hit = hits.first else { notFound.append(target); continue }
            if seen.insert(name(hit).lowercased()).inserted { picked.append(hit) }
        }
        return (picked, notFound)
    }
}

extension CLIRunner {
    /// `12m ago`, `3h 05m ago`; empty when unknown.
    func age(_ date: Date?, now: Date) -> String {
        guard let date else { return "" }
        let text = CLIFormat.timeLeft(until: now, now: date)
        return text == "expired" ? "just now" : "\(text) ago"
    }

    /// `in 23h 50m`, or `expired`; empty when unknown.
    func expiry(_ date: Date?, now: Date) -> String {
        guard let date else { return "" }
        let left = CLIFormat.timeLeft(until: date, now: now)
        return left == "expired" ? left : "in \(left)"
    }

    // MARK: pending

    func pending(_ o: PendingOptions) async throws -> CLIExit {
        let tenant = try resolveTenant(o.tenant)
        let identity: Identity, requests: [ScheduledRequest]
        do { (_, identity, requests) = try await loadPending(tenant, readOnly: true) } catch { return report(error, tenant: tenant.tenantId) }
        let waiting = requests.filter { $0.kind == .awaitingApproval }
        let tenantId = identity.tenantId ?? tenant.tenantId
        if o.json {
            out(CLIJSON.encode(CLIJSON.PendingList(tenantId: tenantId, user: .init(identity), requests: waiting.map(CLIJSON.PendingRequest.init))))
            return .success
        }
        guard !waiting.isEmpty else {
            out("No requests of yours wait for approval.")
            return .success
        }
        let now = env.now()
        var table = TextTable(headers: ["ID", "ROLE", "RESOURCE", "FOR", "ASKED", "EXPIRES", "STATUS"], flexible: [1, 2])
        for r in waiting {
            let expires = expiry(r.expiresAt, now: now)
            table.append([
                .init(r.shortId, .dim),
                .init(r.isOwner ? "\(r.roleName) (!)" : r.roleName, r.isOwner ? .strong : .plain),
                .init(r.scopeName),
                .init(r.durationMinutes.map { DurationText.short(minutes: $0) } ?? "", .dim),
                .init(age(r.createdOn, now: now), .dim),
                .init(expires, expires == "expired" ? .bad : .dim),
                .init(r.status, .warn),
            ])
        }
        table.render(style: outStyle, maxWidth: env.terminalWidth).forEach { out($0) }
        if env.stdoutIsTTY {
            out(outStyle.dim("\(CLIFormat.plural(waiting.count, "request")) awaiting approval · `pimento wait --all` waits for the decision, "
                + "`pimento cancel ID` withdraws one"))
        }
        return .success
    }

    // MARK: wait

    func wait(_ o: WaitOptions) async throws -> CLIExit {
        let tenant = try resolveTenant(o.tenant)
        let service = makeService(tenant.tenantId, true)
        var history: RequestHistory
        do { history = try await service.loadRequestHistory(now: env.now()) } catch { return report(error, tenant: tenant.tenantId) }
        let tenantId = history.identity.tenantId ?? tenant.tenantId
        let human = humanWriter(json: o.json)
        let style = o.json ? errStyle : outStyle
        let tz = env.timeZone

        // What each target is: a request, and how it stands.
        var order: [(target: String, request: ScheduledRequest?)] = []
        var results: [String: CLIJSON.WaitResult] = [:]
        var tracker = ApprovalTracker()
        if o.all {
            let waiting = history.pending.filter { $0.kind == .awaitingApproval }
            guard !waiting.isEmpty else {
                human("No requests of yours wait for approval.")
                if o.json { out(CLIJSON.encode(CLIJSON.Waiting(tenantId: tenantId, user: .init(history.identity), timeout: o.timeout, results: []))) }
                return .success
            }
            tracker.track(waiting)
            order = waiting.map { ($0.name, $0) }
        } else {
            let (picked, notFound) = try RequestIdSelection.pick(
                history.items, name: { $0.name ?? $0.id.map(RoleMatcher.lastPathComponent) ?? "" }, targets: o.targets)
            for target in o.targets {
                let t = target.lowercased()
                guard notFound.contains(target) == false,
                      let item = picked.first(where: { ($0.name ?? "").lowercased().hasPrefix(t) }),
                      let request = ScheduledRequestParser.describe(item, kind: .awaitingApproval)
                else {
                    order.append((target, nil))
                    results[target.lowercased()] = CLIJSON.WaitResult(target: target, outcome: "notFound", status: nil, request: nil,
                                                                      until: nil, reviewer: nil, reviewJustification: nil)
                    continue
                }
                order.append((target, request))
                if let resolution = ApprovalTracker.resolution(of: item) {
                    let review = resolution.isApproved ? nil : await service.review(approvalId: request.approvalId)
                    results[request.name.lowercased()] = waitResult(target: target, request: request, resolution: resolution,
                                                                    status: request.status, review: review)
                } else {
                    tracker.track([request])
                }
            }
        }

        func line(_ target: String, _ request: ScheduledRequest?, _ r: CLIJSON.WaitResult, now: Date) -> String {
            let name = request.map { "\($0.roleName) · \($0.scopeName) (\($0.shortId))" } ?? target
            let words = [r.reviewJustification.map { "“\($0)”" }, r.reviewer.map { "by \($0)" }].compactMap { $0 }.joined(separator: " ")
            switch r.outcome {
            case "approved":
                let until = r.until.flatMap(AzureDate.parse).map { " until " + CLIFormat.clock($0, now: now, timeZone: tz) } ?? ""
                if let request, request.start > now.addingTimeInterval(ScheduleTime.immediateSlack) {
                    return style.green("approved") + "   \(name): starts \(ScheduleTime.label(request.start, now: now, timeZone: tz))\(until)"
                }
                return style.green("approved") + "   \(name): active\(until)"
            case "denied": return style.red("denied") + "     \(name)" + (words.isEmpty ? "" : ": \(words)")
            case "expired": return style.red("expired") + "    \(name): no approver decided within 24 hours"
            case "canceled": return style.yellow("cancelled") + "  \(name)"
            case "timeout": return style.yellow("timeout") + "    \(name): still awaiting approval after \(WaitTimeout.label(o.timeout))"
            case "notFound": return style.yellow("not found") + "  \(target): no request of yours with this id"
            default: return style.red("failed") + "     \(name): \(r.status ?? "failed")"
            }
        }

        let now0 = env.now()
        for (target, request) in order {
            let key = (request?.name ?? target).lowercased()
            if let r = results[key] { human(line(target, request, r, now: now0)) }
        }
        let deadline = now0.addingTimeInterval(o.timeout)
        if !tracker.isEmpty {
            human(style.dim("Waiting for \(CLIFormat.plural(tracker.count, "request")) to be decided "
                + "(up to \(WaitTimeout.label(o.timeout)), checking every \(WaitTimeout.label(WaitOptions.pollInterval)))…"))
        }
        while !tracker.isEmpty {
            let remaining = deadline.timeIntervalSince(env.now())
            if remaining <= 0 { break }
            await env.sleep(min(WaitOptions.pollInterval, remaining))
            do {
                history = try await service.loadRequestHistory(now: env.now())
            } catch {
                if CLIExit.code(for: error) == .auth { return report(error, tenant: tenant.tenantId) }
                human(style.yellow("note:") + " could not read your requests (\(error.localizedDescription)); trying again")
                continue
            }
            let before = Set(tracker.pending.keys)
            let transitions = tracker.update(items: history.items, principalId: history.identity.objectId, now: env.now(), trackNew: false)
            for t in transitions {
                let review = t.resolution.isApproved ? nil : await service.review(approvalId: t.request.approvalId)
                let target = order.first { $0.request?.name.lowercased() == t.request.name.lowercased() }?.target ?? t.request.name
                let r = waitResult(target: target, request: t.request, resolution: t.resolution, status: t.status, review: review)
                results[t.request.name.lowercased()] = r
                human(line(target, t.request, r, now: env.now()))
            }
            // A request that vanished from the listing (rare): reported as not found.
            for name in before.subtracting(tracker.pending.keys) where results[name] == nil {
                let entry = order.first { $0.request?.name.lowercased() == name }
                let r = CLIJSON.WaitResult(target: entry?.target ?? name, outcome: "notFound", status: nil,
                                           request: entry?.request.map(CLIJSON.PendingRequest.init), until: nil, reviewer: nil, reviewJustification: nil)
                results[name] = r
                human(line(entry?.target ?? name, entry?.request, r, now: env.now()))
            }
        }
        for request in tracker.pending.values.sorted(by: { $0.name < $1.name }) {
            let target = order.first { $0.request?.name.lowercased() == request.name.lowercased() }?.target ?? request.name
            let r = CLIJSON.WaitResult(target: target, outcome: "timeout", status: request.status, request: .init(request),
                                       until: nil, reviewer: nil, reviewJustification: nil)
            results[request.name.lowercased()] = r
            human(line(target, request, r, now: env.now()))
        }

        let all = order.compactMap { results[($0.request?.name ?? $0.target).lowercased()] }
        let doc = CLIJSON.Waiting(tenantId: tenantId, user: .init(history.identity), timeout: o.timeout, results: all)
        var parts: [String] = []
        if doc.summary.approved > 0 { parts.append("\(doc.summary.approved) approved") }
        if doc.summary.rejected > 0 { parts.append(style.red("\(doc.summary.rejected) not approved")) }
        if doc.summary.timedOut > 0 { parts.append(style.yellow("\(doc.summary.timedOut) still waiting")) }
        if doc.summary.notFound > 0 { parts.append(style.yellow("\(doc.summary.notFound) not found")) }
        human((parts.isEmpty ? ["nothing to wait for"] : parts).joined(separator: ", ") + ".")
        if o.json { out(CLIJSON.encode(doc)) }
        return Self.waitExit(doc.summary)
    }

    /// 1 when anything was denied, expired, cancelled, failed or not found;
    /// else 4 when something is still waiting; else 0.
    static func waitExit(_ s: CLIJSON.Waiting.Summary) -> CLIExit {
        if s.rejected > 0 || s.notFound > 0 { return .failure }
        if s.timedOut > 0 { return .timeout }
        return .success
    }

    func waitResult(target: String, request: ScheduledRequest, resolution: RequestResolution, status: String, review: ReviewInfo?) -> CLIJSON.WaitResult {
        var until: Date?
        if case .approved(let u) = resolution { until = u }
        return CLIJSON.WaitResult(
            target: target, outcome: resolution.label, status: status.isEmpty ? nil : status, request: .init(request),
            until: until.map(AzureDate.format), reviewer: review?.reviewer, reviewJustification: review?.justification)
    }

    // MARK: approvals

    func approvalTable(_ requests: [ApprovalRequest], now: Date, style: TerminalStyle, json: Bool) -> [String] {
        var table = TextTable(headers: ["ID", "REQUESTER", "ROLE", "RESOURCE", "FOR", "ASKED", "EXPIRES", "JUSTIFICATION", "TICKET"],
                              flexible: [1, 3, 7])
        for r in requests {
            let expires = expiry(r.expiresAt, now: now)
            table.append([
                // The whole id: `approve ID --yes` takes only that.
                .init(r.name, .dim),
                .init(r.requesterName ?? r.requesterEmail ?? r.requesterId),
                .init(r.grantsAccess ? "\(r.roleName) (!)" : r.roleName, r.grantsAccess ? .strong : .plain),
                .init(r.scopeName),
                .init(r.durationMinutes.map { DurationText.short(minutes: $0) } ?? "", .dim),
                .init(age(r.createdOn, now: now), .dim),
                .init(expires, expires == "expired" ? .bad : .dim),
                .init(r.justification ?? ""),
                .init(r.ticket?.label ?? "", .dim),
            ])
        }
        return table.render(style: style, maxWidth: json ? nil : env.terminalWidth)
    }

    func approvals(_ o: ApprovalsOptions) async throws -> CLIExit {
        let tenant = try resolveTenant(o.tenant)
        let service = makeService(tenant.tenantId, true)
        let identity: Identity, inbox: ApprovalInbox
        do { (identity, inbox) = try await service.loadApprovalInbox() } catch { return report(error, tenant: tenant.tenantId) }
        let tenantId = identity.tenantId ?? tenant.tenantId
        if o.json {
            out(CLIJSON.encode(CLIJSON.ApprovalList(
                tenantId: tenantId, user: .init(identity), available: inbox.unavailable == nil, note: inbox.unavailable,
                requests: inbox.requests.map(CLIJSON.ApprovalDoc.init))))
            return .success
        }
        guard !inbox.isEmpty else {
            out("You have no approvals to review.")
            if env.stdoutIsTTY, let why = inbox.unavailable { out(outStyle.dim("(Azure lists no approvals for you here: \(why))")) }
            return .success
        }
        approvalTable(inbox.requests, now: env.now(), style: outStyle, json: false).forEach { out($0) }
        if env.stdoutIsTTY {
            out(outStyle.dim("\(CLIFormat.plural(inbox.requests.count, "request")) to review · "
                + "`pimento approve ID -j TEXT` or `pimento deny ID -j TEXT` (--yes takes the whole ID)"))
        }
        return .success
    }

    // MARK: approve / deny

    func decide(_ o: DecideOptions) async throws -> CLIExit {
        let verb = o.decision.command
        let confirm = ConfirmationPolicy.decide(dryRun: o.dryRun, assumeYes: o.assumeYes, interactive: env.stdinIsTTY)
        if confirm == .refuse { throw ConfirmationRequired(command: verb) }
        let tenant = try resolveTenant(o.tenant)
        // A dry run gets a GET-only transport: it cannot send the PATCH.
        let service = makeService(tenant.tenantId, o.dryRun)
        let identity: Identity, inbox: ApprovalInbox
        do { (identity, inbox) = try await service.loadApprovalInbox() } catch { return report(error, tenant: tenant.tenantId) }
        let tenantId = identity.tenantId ?? tenant.tenantId
        let human = humanWriter(json: o.json)
        let style = o.json ? errStyle : outStyle
        let now = env.now()

        // Without a prompt (--yes), only the exact request named is decided.
        let (picked, notFound) = try RequestIdSelection.pick(
            inbox.requests, name: \.name, targets: o.targets, exact: o.assumeYes && !o.dryRun)
        let plans = try PlannedDecision.plan(await service.resolvingStages(picked), decision: o.decision, justification: o.justification)
        let sendable = plans.filter { $0.url != nil }
        let unsendable = plans.filter { $0.url == nil }

        func json(_ outcomes: [String: DecisionOutcome]) -> CLIJSON.Decisions {
            CLIJSON.Decisions(
                decision: o.decision, dryRun: o.dryRun, tenantId: tenantId, user: .init(identity), justification: o.justification,
                results: plans.map { CLIJSON.DecisionResult($0, outcome: outcomes[$0.request.name], dryRun: o.dryRun) }, notFound: notFound)
        }

        for id in notFound { human(style.yellow("not found") + "  \(id): not among the requests you can decide") }
        guard !plans.isEmpty else {
            err(inbox.isEmpty ? "You have no approvals to review." : "No request matches. `pimento approvals` lists them.")
            if o.json { out(CLIJSON.encode(json([:]))) }
            return .failure
        }
        let owners = sendable.filter(\.request.isOwner).count
        let admins = sendable.filter(\.request.isAccessAdministrator).count
        human((o.dryRun ? "Would \(verb) " : "\(o.decision.rawValue) ")
            + "\(CLIFormat.plural(plans.count, "request")) in tenant \(tenantId ?? defaultTenantLabel):")
        approvalTable(plans.map(\.request), now: now, style: style, json: o.json).forEach { human("  " + $0) }
        if o.decision == .approve, owners > 0 {
            human(style.boldRed("Warning:") + " \(CLIFormat.plural(owners, "Owner role")) (!): full control of the resource, including access.")
        }
        if o.decision == .approve, admins > 0 {
            human(style.boldRed("Warning:") + " \(CLIFormat.plural(admins, "access administrator role")) (!): "
                + "can grant anyone any role on the resource, Owner included.")
        }
        human(o.decision == .approve
            ? "The requesters get the roles as requested (for the duration shown)."
            : "The requesters do not get the roles; they see your justification.")
        human("Justification: \(o.justification)")
        for p in unsendable {
            human(style.yellow("skip") + "  \(p.request.roleName) · \(p.request.scopeName) (\(p.request.name)): \(DecisionOutcome.noOpenStageMessage)")
        }
        guard !sendable.isEmpty else {
            if o.json { out(CLIJSON.encode(json([:]))) }
            return .failure
        }
        if o.dryRun {
            if !o.json {
                for p in sendable {
                    out()
                    out(style.dim("# \(p.request.roleName) · \(p.request.scopeName) for \(p.request.requesterLabel)"))
                    out("PATCH \(p.url!.absoluteString)")
                    out(p.prettyBody)
                }
                out()
            }
            human("Dry run: \(CLIFormat.plural(sendable.count, "decision")) built, none sent.")
            if o.json { out(CLIJSON.encode(json([:]))) }
            return notFound.isEmpty && unsendable.isEmpty ? .success : .failure
        }
        if confirm == .ask {
            write("\(o.decision.rawValue) \(CLIFormat.plural(sendable.count, "request"))"
                + "\(o.decision == .approve ? ApprovalRequest.privilegedNote(owners: owners, admins: admins) : "")? [y/N] ", .err)
            guard ConfirmationPolicy.isYes(env.readLine()) else {
                err("Nothing was sent.")
                return .failure
            }
        }
        let box = DecisionOutcomeBox()
        do {
            try await service.decide(sendable) { p, outcome in
                box.set(p.request.name, outcome)
                let name = "\(p.request.roleName) · \(p.request.scopeName) for \(p.request.requesterName ?? p.request.requesterLabel)"
                switch outcome {
                case .decided(let d):
                    human((d == .approve ? style.green("approved") : style.yellow("denied")) + (d == .approve ? "   " : "     ") + name)
                case .notPending:
                    human(style.yellow("skipped") + "    \(name): \(outcome.summary)")
                case .failed:
                    human(style.red("failed") + "     \(name): \(outcome.summary)")
                }
            }
        } catch {
            return report(error, tenant: tenant.tenantId)
        }
        let outcomes = box.all
        let doc = json(outcomes)
        var parts = ["\(doc.summary.decided) \(o.decision.pastTense)"]
        if doc.summary.skipped > 0 { parts.append(style.yellow("\(doc.summary.skipped) skipped")) }
        if doc.summary.failed > 0 { parts.append(style.red("\(doc.summary.failed) failed")) }
        if !notFound.isEmpty { parts.append(style.yellow("\(notFound.count) not found")) }
        human(parts.joined(separator: ", ") + ".")
        if o.json { out(CLIJSON.encode(doc)) }
        let failures = outcomes.values.filter(\.isFailure)
        if !failures.isEmpty, failures.allSatisfy(\.isAuthFailure) {
            err(loginHint(tenant: tenant.tenantId))
            return .auth
        }
        return failures.isEmpty && notFound.isEmpty && unsendable.isEmpty ? .success : .failure
    }
}

final class DecisionOutcomeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: DecisionOutcome] = [:]

    func set(_ id: String, _ outcome: DecisionOutcome) {
        lock.lock()
        values[id] = outcome
        lock.unlock()
    }

    var all: [String: DecisionOutcome] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }
}
