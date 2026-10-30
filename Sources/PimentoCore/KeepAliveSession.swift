import Foundation

/// What one keep-alive pass saw and did.
public struct KeepAlivePassResult: Sendable {
    public var identity: Identity
    public var roles: [EligibleRole]
    /// The kept roles and where each stands after the pass.
    public var items: [KeepAlivePlanner.Item]
    /// What was sent and how it went, plus once-per-window notices.
    public var events: [KeepAliveEvent]
    /// What would have been sent (dry run), or what was sent.
    public var actions: [KeepAlivePlanner.Item]
    /// When to run the next pass (nil: only when something changes).
    public var nextCheck: Date?
}

/// Keep-alive's memory across passes (the tracks and the policies read so
/// far) and the pass itself: read, decide (`KeepAlivePlanner`), send. Shared
/// by the app and `pimento keep-alive`.
public actor KeepAliveSession {
    public private(set) var book = KeepAliveBook()
    private var policies: [RoleMatcher.Key: PolicyLookup] = [:]

    public init() {}

    /// Stops keeping `key` alive; returns the continuation to withdraw, if any.
    public func remove(_ key: String, now: Date) -> KeepAliveTrack.HandOver? { book.remove(key, now: now) }

    /// See `KeepAliveBook.pause`.
    public func pause(now: Date) -> [String: KeepAliveTrack.HandOver] { book.pause(now: now) }

    /// Forgets everything (another tenant or account).
    public func reset() {
        book = KeepAliveBook()
        policies = [:]
    }

    /// Forgets that `keys` were active, so they are not brought back (you
    /// ended them).
    public func forgetEnds(_ keys: Set<String>) {
        for key in keys where book.tracks[key] != nil { book.tracks[key]?.lastEnd = nil }
    }

    /// Reads your roles, your requests and the kept roles' policies, decides,
    /// and (unless `dryRun`) sends the continuations, late activations and
    /// withdrawals that are due. `reader` reads (GET only); `writer` sends and
    /// records the history. Throws when the reads fail: nothing is sent then.
    public func pass(
        reader: PIMService, writer: PIMService, perRole: Set<String>, presets: [Preset], hours: WorkingHours, paused: Bool,
        calendar: Calendar, clock: @Sendable () -> Date, dryRun: Bool = false, maxConcurrent: Int = 4
    ) async throws -> KeepAlivePassResult {
        let now = clock()
        let snapshot = try await reader.loadRoles(now: now)
        let history = try await reader.loadRequestHistory(now: now)
        let rules = KeepAliveRule.resolve(perRole: perRole, presets: presets, roles: snapshot.roles)
        let kept = snapshot.roles.filter { rules[ReminderRole.key($0.policyKey)] != nil }
        let missing = kept.filter { role in
            switch policies[role.policyKey] {
            case nil, .failed?: true
            default: false
            }
        }
        if !missing.isEmpty, let loaded = try? await reader.loadPolicies(for: missing) {
            policies.merge(loaded) { _, new in new }
        }
        let infos = history.activationInfo
        var items = KeepAlivePlanner.plan(
            roles: snapshot.roles, rules: rules, policies: policies, infos: infos, pending: history.pending, book: &book,
            hours: hours, paused: paused, now: now, calendar: calendar)
        let due = items.filter { $0.status.action != nil }
        var events: [KeepAliveEvent] = []
        if !dryRun, !due.isEmpty {
            events = await send(due, writer: writer, principalId: snapshot.identity.objectId, now: now, maxConcurrent: maxConcurrent)
            // Where each stands now: acted roles show their continuation or retry.
            let after = clock()
            items = KeepAlivePlanner.plan(
                roles: snapshot.roles, rules: rules, policies: policies, infos: infos, pending: history.pending, book: &book,
                hours: hours, paused: paused, now: after, calendar: calendar
            ).map { item in
                // Do not report a second action that was not sent.
                guard item.status.action != nil else { return item }
                var i = item
                i.status = .retryLater(at: after.addingTimeInterval(KeepAlive.retryDelays[0]), failures: book[item.key].failures)
                return i
            }
        }
        events += KeepAlivePlanner.onceEvents(items, book: &book)
        return KeepAlivePassResult(
            identity: snapshot.identity, roles: snapshot.roles, items: items, events: events, actions: due,
            nextCheck: KeepAlivePlanner.nextCheck(items, now: clock()))
    }

    /// Sends the due actions (activations with `execute`, a few at a time,
    /// recorded in the history; withdrawals with `cancel`) and records the outcomes.
    private func send(_ due: [KeepAlivePlanner.Item], writer: PIMService, principalId: String, now: Date,
                      maxConcurrent: Int) async -> [KeepAliveEvent] {
        var plans: [(item: KeepAlivePlanner.Item, plan: PlannedRequest)] = []
        var cancels: [(item: KeepAlivePlanner.Item, request: ScheduledRequest)] = []
        var events: [KeepAliveEvent] = []
        for item in due {
            guard let action = item.status.action else { continue }
            let request: (start: Date?, minutes: Int, justification: String, ticket: TicketInfo?)
            switch action {
            case .handOver(let start, let minutes, _, let justification, let ticket):
                request = (start, minutes, justification, ticket)
            case .activateNow(let minutes, _, let justification, let ticket):
                request = (nil, minutes, justification, ticket)
            case .cancel(let h):
                cancels.append((item, ScheduledRequest(
                    id: "", name: h.requestName, scope: h.scope, roleDefinitionId: h.roleDefinitionId, roleName: item.role.roleName,
                    scopeName: item.role.scopeName, scopeType: item.role.scopeType, status: "Granted", start: h.start, end: h.until)))
                continue
            }
            let (startAt, minutes, justification, ticket) = request
            do {
                let plan = try ActivationRequestBuilder.plan(
                    [RenewPlan.asEligible(item.role)], principalId: principalId, justification: justification, now: now,
                    start: startAt, ticket: ticket
                ) { _ in EffectiveDuration(minutes: minutes, requested: item.rule.requested, policyMaxMinutes: nil) }
                plans.append((item, plan[0]))
            } catch {
                events.append(book.record(action, outcome: .request(.failed(code: "InvalidRequest", message: error.localizedDescription), requestId: ""),
                                          role: item.role, key: item.key, now: now))
            }
        }
        if !plans.isEmpty {
            let box = KeepAliveOutcomeBox()
            do {
                try await writer.execute(plans.map(\.plan), maxConcurrent: maxConcurrent) { plan, outcome in
                    box.set(plan.requestId, outcome)
                }
            } catch {
                for p in plans { box.set(p.plan.requestId, .failed(code: "Auth", message: error.localizedDescription)) }
            }
            for (item, plan) in plans {
                let outcome = box.get(plan.requestId) ?? .failed(code: "NotSent", message: "not sent")
                events.append(book.record(item.status.action!, outcome: .request(outcome, requestId: plan.requestId),
                                          role: item.role, key: item.key, now: now))
            }
        }
        if !cancels.isEmpty {
            let box = KeepAliveCancelBox()
            do {
                try await writer.cancel(cancels.map(\.request)) { request, outcome in box.set(request.name, outcome) }
            } catch {
                for c in cancels { box.set(c.request.name, .failed(code: "Auth", message: error.localizedDescription)) }
            }
            for (item, request) in cancels {
                events.append(book.record(item.status.action!, outcome: .cancel(box.get(request.name) ?? .failed(code: "NotSent", message: "not sent")),
                                          role: item.role, key: item.key, now: now))
            }
        }
        return events
    }

    /// Withdraws continuations Pimento scheduled (on pause, or when a role is
    /// no longer kept alive). Failures are left: they start as scheduled.
    public static func withdraw(_ handOvers: [KeepAliveTrack.HandOver], writer: PIMService) async -> [CancelOutcome] {
        guard !handOvers.isEmpty else { return [] }
        let requests = handOvers.map { h in
            ScheduledRequest(id: "", name: h.requestName, scope: h.scope, roleDefinitionId: h.roleDefinitionId,
                             roleName: RoleMatcher.lastPathComponent(h.roleDefinitionId), scopeName: RoleMatcher.lastPathComponent(h.scope),
                             scopeType: RoleMatcher.inferScopeType(h.scope), status: "Granted", start: h.start, end: h.until)
        }
        let box = KeepAliveCancelBox()
        do {
            try await writer.cancel(requests) { r, o in box.set(r.name, o) }
        } catch {
            return requests.map { _ in .failed(code: "Auth", message: error.localizedDescription) }
        }
        return requests.map { box.get($0.name) ?? .failed(code: "NotSent", message: "not sent") }
    }
}

private final class KeepAliveOutcomeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: ActivationOutcome] = [:]
    func set(_ id: String, _ o: ActivationOutcome) { lock.withLock { values[id] = o } }
    func get(_ id: String) -> ActivationOutcome? { lock.withLock { values[id] } }
}

private final class KeepAliveCancelBox: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: CancelOutcome] = [:]
    func set(_ id: String, _ o: CancelOutcome) { lock.withLock { values[id] = o } }
    func get(_ id: String) -> CancelOutcome? { lock.withLock { values[id] } }
}
