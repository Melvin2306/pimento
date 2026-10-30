import Foundation

/// Keep-alive: roles you mark are renewed shortly before they expire, during
/// working hours, so long sessions do not drop out. The decisions live here,
/// pure and clock-injected; `KeepAliveSession` reads Azure and sends.
///
/// **How a role is continued.** PIM has no self-service extension:
/// `SelfExtend` and `SelfRenew` are requests an administrator must approve
/// (README › Ending and renewing). Renew (end, then activate) leaves the role
/// off for minutes. But PIM accepts a `SelfActivate` with a later
/// `scheduleInfo.startDateTime` while the role is active, for a start after
/// the current activation ends (README › Scheduled activations). Keep-alive
/// therefore schedules the next activation to start exactly when the current
/// one ends (`handOverLead` before the end): one request, nothing ended, and
/// no gap beyond the seconds PIM takes to switch. A start before the end
/// would overlap and is refused (`RoleAssignmentExists`). When that hand-over
/// cannot be placed or does not start (the Mac slept through it, the request
/// failed), keep-alive activates the lapsed role again as soon as it can,
/// inside working hours: then there is a gap.
///
/// **The rules.**
/// - Only roles whose policy is known and needs no approval (a renewal would
///   wait for an approver).
/// - Only inside working hours, and never past their end: the last renewal of
///   the day is shortened to end with them, in whole hours (or the policy's
///   own maximum when it is shorter), and skipped when not even that fits.
/// - The new activation carries the justification and ticket of the one it
///   continues (a preset's justification when that is unknown); when the
///   policy needs something that is not known, it is skipped (with a notice).
/// - A role ended early (by you, anywhere) is not brought back; a role that
///   lapsed before working hours began is not started (keep-alive keeps
///   activations going, it does not start your day).
/// - Failures back off (1, 5, 15 minutes) and stop after `maxFailures` per
///   role per working-hours window.
public enum KeepAlive {
    /// How long before the end the continuation is scheduled.
    public static let handOverLead: TimeInterval = 15 * 60
    /// Closer to the end than this, a scheduled start would count as "now"
    /// (PIM, `ScheduleTime.immediateSlack`) and overlap: wait for the end.
    public static let minimumLead: TimeInterval = 2 * 60
    /// A continuation gets this long after its start to be listed as active
    /// before it counts as not started.
    public static let startGrace: TimeInterval = 3 * 60
    /// A role listed as inactive more than this before its known end was ended early.
    public static let endedEarlySlack: TimeInterval = 60
    /// Waits after the 1st, 2nd, 3rd failure.
    public static let retryDelays: [TimeInterval] = [60, 5 * 60, 15 * 60]
    /// Failures per role per working-hours window before keep-alive gives up on it.
    public static let maxFailures = 4
    /// A scheduled request starting this close to an activation's end continues it.
    public static let continuationSlack: TimeInterval = 5 * 60

    /// The minutes of an activation that starts `room` seconds before the end
    /// of working hours, for a role that would get `cap` minutes: `cap` when
    /// it fits, else the most whole hours that fit (Pimento asks for whole
    /// hours or the policy maximum, see `RequestedDuration`); nil when not
    /// even one hour fits.
    public static func clippedMinutes(cap: Int, room: TimeInterval) -> Int? {
        let roomMinutes = Int((room / 60).rounded(.down))
        if cap <= roomMinutes { return cap }
        let hours = roomMinutes / 60
        guard hours >= 1 else { return nil }
        return hours * 60
    }

    /// Whether `request` looks like a continuation keep-alive scheduled: made
    /// at most `handOverLead` (plus slack) before its start. A request you
    /// scheduled further ahead is never withdrawn by keep-alive.
    static func looksLikeContinuation(_ request: ScheduledRequest) -> Bool {
        guard let created = request.createdOn else { return false }
        return request.start.timeIntervalSince(created) <= handOverLead + continuationSlack
    }

    /// A continuation that must be withdrawn before it starts: paused; the
    /// activation it continues was ended (`deactivatedAt`: your latest
    /// `SelfDeactivate` of the role, from anywhere) or replaced. Also finds
    /// one that is not in `track` (sent before a restart, or by another
    /// Pimento) among the pending requests.
    static func withdrawal(
        role: EligibleRole, scheduled: [ScheduledRequest], track: KeepAliveTrack, paused: Bool, now: Date, deactivatedAt: Date?
    ) -> KeepAliveTrack.HandOver? {
        let end = role.isActive ? role.activeUntil.flatMap { $0 > now ? $0 : nil } : nil
        let continuesEnd = { (h: KeepAliveTrack.HandOver) in end.map { abs(h.start.timeIntervalSince($0)) <= continuationSlack } ?? false }
        // Pimento's own (tracked), then pending ones that look like a continuation (not tracked).
        var candidates: [(handOver: KeepAliveTrack.HandOver, created: Date?, tracked: Bool)] = []
        if let h = track.handOver, h.start > now { candidates.append((h, h.created, true)) }
        for r in scheduled where r.start > now && looksLikeContinuation(r)
            && r.name.caseInsensitiveCompare(track.handOver?.requestName ?? "") != .orderedSame {
            candidates.append((KeepAliveTrack.HandOver(r), r.createdOn, false))
        }
        for (h, created, tracked) in candidates {
            if paused && (tracked || continuesEnd(h)) { return h }
            // Ended (by you, anywhere) after it was scheduled.
            if let d = deactivatedAt, d <= now, let created, d > created { return h }
            if end != nil {
                // Active, but not the activation Pimento continued (ended and activated again).
                if tracked && !continuesEnd(h) { return h }
            } else if let lastEnd = track.lastEnd, now < lastEnd.addingTimeInterval(-endedEarlySlack),
                      tracked || abs(h.start.timeIntervalSince(lastEnd)) <= continuationSlack {
                // Not active before its end: ended early.
                return h
            }
        }
        return nil
    }

    /// What `role` (kept alive by `rule`) needs at `now`. `track` is what
    /// keep-alive remembers about it (see `KeepAliveTrack.observe`), `pending`
    /// its scheduled or waiting requests, `deactivatedAt` when you last ended
    /// it (`SelfDeactivate`, from anywhere; `RequestHistory.deactivations`).
    public static func decide(
        role: EligibleRole, rule: KeepAliveRule, policy: PolicyLookup?, pending: [ScheduledRequest], track: KeepAliveTrack,
        hours: WorkingHours, paused: Bool, now: Date, calendar: Calendar, deactivatedAt: Date? = nil
    ) -> KeepAliveStatus {
        let scheduled = pending.filter { $0.kind == .scheduled }
        // Withdrawals come first (also paused, whatever the policy): they never grant anything. They back off like
        // renewals, but are tried once more shortly before the start whatever the backoff says.
        if let h = withdrawal(role: role, scheduled: scheduled, track: track, paused: paused, now: now, deactivatedAt: deactivatedAt) {
            if let at = track.retryAt.map({ min($0, h.start.addingTimeInterval(-minimumLead)) }), now < at {
                return .retryLater(at: at, failures: track.failures)
            }
            return .act(.cancel(h))
        }
        if paused { return .paused }
        guard let lookup = policy else { return .excluded(.policyLoading) }
        guard let p = lookup.policy else { return .excluded(.policyUnknown) }
        if p.requiresApproval { return .excluded(.needsApproval) }
        // A request of yours waits for an approver (the policy changed since it was read): never another one.
        if pending.contains(where: { $0.kind == .awaitingApproval }) { return .excluded(.needsApproval) }
        let window = hours.window(containing: now, calendar: calendar)
        let cap = EffectiveDuration.resolve(rule.requested, policyMaxMinutes: p.maxMinutes, fallbackHours: ActivationRequestBuilder.defaultHours).minutes

        // Checked only when keep-alive would send something.
        func ready(_ make: (String, TicketInfo?) -> KeepAliveAction) -> KeepAliveStatus {
            if let at = track.retryAt, now < at { return .retryLater(at: at, failures: track.failures) }
            if track.failures >= maxFailures { return .gaveUp(failures: track.failures) }
            guard let justification = (track.justification ?? rule.justification)?
                .trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty else { return .blocked(.needsJustification) }
            let ticket = track.ticket.flatMap { $0.isEmpty ? nil : $0 }
            if p.requiresTicket, ticket?.isComplete != true { return .blocked(.needsTicket) }
            return .act(make(justification, ticket))
        }

        if role.isActive, let end = role.activeUntil, end > now {
            if let r = scheduled.first(where: { abs($0.start.timeIntervalSince(end)) <= continuationSlack }) {
                return .continued(start: r.start, until: r.end)
            }
            if let h = track.handOver, abs(h.start.timeIntervalSince(end)) <= continuationSlack {
                return .continued(start: h.start, until: h.until)
            }
            guard let window else { return .outsideHours(next: hours.nextWindow(after: now, calendar: calendar)?.start) }
            guard end < window.end else { return .endsAfterHours(windowEnd: window.end) }
            guard let minutes = clippedMinutes(cap: cap, room: window.end.timeIntervalSince(end)) else {
                return .lastOfDay(end: end, windowEnd: window.end)
            }
            let due = end.addingTimeInterval(-handOverLead)
            if now < due { return .waiting(until: due) }
            // Too close to the end to schedule: activate once it has ended.
            if end.timeIntervalSince(now) < minimumLead { return .waiting(until: end.addingTimeInterval(30)) }
            return ready { .handOver(start: end, minutes: minutes, clipped: minutes < cap, justification: $0, ticket: $1) }
        }
        if role.isActive && role.activeUntil == nil { return .noEnd }

        // Not active (or its end has passed and the listing has not caught up).
        // A continuation that is starting (or an activation just sent) gets a moment to be listed.
        if let h = track.handOver, h.start <= now, now < h.start.addingTimeInterval(startGrace) {
            return .continued(start: h.start, until: h.until)
        }
        // Ended by you after it started (seen in your requests: also when
        // Pimento was asleep or not running at the time).
        let endedByYou = deactivatedAt.map { d in d <= now && track.lastStart.map { d > $0 } == true } ?? false
        if let lastEnd = track.lastEnd, endedByYou || now < lastEnd.addingTimeInterval(-endedEarlySlack) {
            // Ended before its time: not brought back (a continuation Pimento
            // scheduled for it was withdrawn above).
            return .endedEarly
        }
        if let h = track.handOver, now < h.start.addingTimeInterval(startGrace) {
            return .continued(start: h.start, until: h.until)
        }
        if let r = scheduled.first(where: { $0.start.timeIntervalSince(now) <= handOverLead }) {
            return .continued(start: r.start, until: r.end)
        }
        guard let lastEnd = track.lastEnd else { return .notActive }
        guard let window, lastEnd >= window.start else { return .notActive }
        guard let minutes = clippedMinutes(cap: cap, room: window.end.timeIntervalSince(now)) else {
            return .lastOfDay(end: lastEnd, windowEnd: window.end)
        }
        return ready { .activateNow(minutes: minutes, clipped: minutes < cap, justification: $0, ticket: $1) }
    }
}

/// How one role is kept alive: per role (the defaults) or by a preset.
public struct KeepAliveRule: Equatable, Sendable {
    /// What each renewal asks for (capped at the policy maximum, clipped to working hours).
    public var requested: RequestedDuration
    /// Sent when the justification of the activation being continued is unknown.
    public var justification: String?
    /// The preset that keeps the role alive, if any.
    public var preset: String?

    public init(requested: RequestedDuration = .maximum, justification: String? = nil, preset: String? = nil) {
        self.requested = requested
        self.justification = justification
        self.preset = preset
    }

    /// The rules for `roles`: per-role keys (`ReminderRole.key`) get the
    /// defaults; roles of presets with keep-alive on get the preset's
    /// duration and justification (a preset wins over the per-role mark).
    public static func resolve(perRole: Set<String>, presets: [Preset], roles: [EligibleRole]) -> [String: KeepAliveRule] {
        var rules: [String: KeepAliveRule] = [:]
        for role in roles {
            let key = ReminderRole.key(role.policyKey)
            if perRole.contains(key) { rules[key] = KeepAliveRule() }
        }
        for preset in presets where preset.keepAlive {
            for role in preset.resolve(in: roles).roles {
                rules[ReminderRole.key(role.policyKey)] = KeepAliveRule(
                    requested: preset.duration ?? .maximum, justification: preset.trimmedJustification, preset: preset.name)
            }
        }
        return rules
    }
}

/// Why a kept role cannot be kept alive at all.
public enum KeepAliveExclusion: String, Equatable, Sendable {
    /// Its policy requires approval: a renewal would wait for an approver.
    case needsApproval
    /// Its policy could not be read, so whether it needs approval is unknown.
    case policyUnknown
    /// Its policy is being read.
    case policyLoading
    /// It can grant access (Owner, User Access Administrator, RBAC
    /// Administrator) and keeping it alive was not confirmed
    /// (`KeepAliveConsent`).
    case notConfirmed
}

/// Keeping a role alive that can grant access to anyone (Owner, User Access
/// Administrator, RBAC Administrator) is confirmed once, when it is marked,
/// while *Confirm before activating Owner roles* is on (the app), or at the
/// prompt of `pimento keep-alive` (or by `--yes`, as for `activate`).
public enum KeepAliveConsent {
    /// The roles among `roles` that need the confirmation: access-granting
    /// ones whose key (`ReminderRole.key`) is not in `confirmed`, one per
    /// scope + role. None when the confirmation is off.
    public static func needingConfirmation(_ roles: [EligibleRole], confirmed: Set<String>, enabled: Bool) -> [EligibleRole] {
        guard enabled else { return [] }
        var seen = Set<String>()
        return roles.filter { role in
            let key = ReminderRole.key(role.policyKey)
            return role.grantsAccess && !confirmed.contains(key) && seen.insert(key).inserted
        }
    }

    /// The keys of `roles` that can grant access (to remember as confirmed).
    public static func accessKeys(_ roles: [EligibleRole]) -> Set<String> {
        Set(roles.filter(\.grantsAccess).map { ReminderRole.key($0.policyKey) })
    }

    /// The question: which roles, and what keeping them alive means.
    public static func message(_ roles: [EligibleRole]) -> String {
        let lines = roles.prefix(8).map { "• \($0.roleName) · \($0.scopeName)" }
        let more = roles.count > 8 ? ["… and \(roles.count - 8) more"] : []
        return "\(roles.count == 1 ? "This role" : "These roles") can grant access to anyone on the resource. Pimento will renew "
            + "\(roles.count == 1 ? "it" : "them") automatically during working hours, without asking again, until you turn keep-alive off.\n\n"
            + (lines + more).joined(separator: "\n")
    }
}

/// Why a renewal that is due cannot be sent.
public enum KeepAliveBlock: String, Equatable, Sendable {
    /// The justification of the activation is unknown (and no preset gives one).
    case needsJustification
    /// Its policy requires a ticket and the activation's ticket is unknown.
    case needsTicket
}

/// What keep-alive sends.
public enum KeepAliveAction: Equatable, Sendable {
    /// A `SelfActivate` that starts when the current activation ends.
    case handOver(start: Date, minutes: Int, clipped: Bool, justification: String, ticket: TicketInfo?)
    /// The activation lapsed inside working hours: a `SelfActivate` now.
    case activateNow(minutes: Int, clipped: Bool, justification: String, ticket: TicketInfo?)
    /// Withdraw a continuation (the role was ended early or activated again, or keep-alive is paused).
    case cancel(KeepAliveTrack.HandOver)

    public var minutes: Int? {
        switch self {
        case .handOver(_, let m, _, _, _), .activateNow(let m, _, _, _): m
        case .cancel: nil
        }
    }
}

/// Where a kept role stands.
public enum KeepAliveStatus: Equatable, Sendable {
    /// Something to send now.
    case act(KeepAliveAction)
    /// Active; the continuation is scheduled at `until`.
    case waiting(until: Date)
    /// A continuation is scheduled (or starting) at `start`.
    case continued(start: Date, until: Date?)
    /// Not active: kept alive once you activate it.
    case notActive
    /// Active without an end: nothing to renew.
    case noEnd
    /// Ended before its time: not brought back.
    case endedEarly
    /// Outside working hours; `next`: when they start again.
    case outsideHours(next: Date?)
    /// The activation lasts to the end of working hours anyway.
    case endsAfterHours(windowEnd: Date)
    /// Not even an hour fits between `end` and the end of working hours.
    case lastOfDay(end: Date, windowEnd: Date)
    case excluded(KeepAliveExclusion)
    case blocked(KeepAliveBlock)
    /// Failed `failures` times; tries again at `at`.
    case retryLater(at: Date, failures: Int)
    /// Failed too often in this window: tries again in the next one.
    case gaveUp(failures: Int)
    case paused

    public var action: KeepAliveAction? {
        if case .act(let a) = self { return a }
        return nil
    }

    /// A continuation is to be withdrawn.
    public var isWithdrawal: Bool {
        if case .act(.cancel) = self { return true }
        return false
    }

    /// Whether the role can be kept alive at all (approval, unreadable policy: no).
    public var isExcluded: Bool {
        if case .excluded(let why) = self { return why != .policyLoading }
        return false
    }

    /// Something the user should look at (shown in the warning colour).
    public var needsAttention: Bool {
        switch self {
        case .excluded(let why): why != .policyLoading
        case .blocked, .gaveUp, .retryLater: true
        default: false
        }
    }

    /// When the role should be looked at again; nil: only when something changes.
    public func nextCheck(now: Date) -> Date? {
        switch self {
        case .act: now
        case .waiting(let until): until
        case .continued(let start, _):
            // Shortly before it starts (a role ended meanwhile gets it withdrawn), then once it should have started.
            start.addingTimeInterval(-KeepAlive.minimumLead) > now
                ? start.addingTimeInterval(-KeepAlive.minimumLead) : max(now, start).addingTimeInterval(KeepAlive.startGrace)
        case .outsideHours(let next): next
        case .retryLater(let at, _): at
        case .excluded(.policyUnknown), .excluded(.policyLoading): now.addingTimeInterval(10 * 60)
        default: nil
        }
    }

    /// One line for the table's tooltip, the menu bar and `pimento keep-alive`.
    public func summary(now: Date, timeZone: TimeZone = .current) -> String {
        let t = { KeepAliveText.clock($0, now: now, timeZone: timeZone) }
        switch self {
        case .act(.handOver(let start, _, _, _, _)): return "continuing it at \(t(start))"
        case .act(.activateNow): return "it lapsed: activating it again"
        case .act(.cancel): return "withdrawing its scheduled continuation"
        case .waiting(let until): return "renews at \(t(until))"
        case .continued(let start, let until):
            return "continues at \(t(start))" + (until.map { " until \(t($0))" } ?? "")
        case .notActive: return "kept alive once you activate it"
        case .noEnd: return "active without an end: nothing to renew"
        case .endedEarly: return "ended early: not renewed"
        case .outsideHours(let next): return "outside working hours" + (next.map { " (from \(t($0)))" } ?? "")
        case .endsAfterHours(let end): return "lasts past the end of working hours (\(t(end)))"
        case .lastOfDay(let end, let windowEnd):
            return "ends at \(t(end)): less than an hour of working hours left (until \(t(windowEnd)))"
        case .excluded(.needsApproval): return "not possible: its policy requires approval"
        case .excluded(.policyUnknown): return "not possible: its policy could not be read"
        case .excluded(.policyLoading): return "reading its policy…"
        case .excluded(.notConfirmed): return "not confirmed: it can grant access; mark it with Keep Alive to confirm"
        case .blocked(.needsJustification): return "skipped: the activation's justification is unknown"
        case .blocked(.needsTicket): return "skipped: its policy requires a ticket and the activation's ticket is unknown"
        case .retryLater(let at, let n): return "failed \(n == 1 ? "once" : "\(n) times"), trying again at \(t(at))"
        case .gaveUp(let n): return "gave up after \(n) failures: renew it yourself"
        case .paused: return "paused"
        }
    }
}

/// What keep-alive remembers about one role between passes (in memory).
public struct KeepAliveTrack: Equatable, Sendable {
    /// A continuation Pimento sent: scheduled at `start`, or activated then.
    public struct HandOver: Equatable, Sendable {
        public var start: Date
        public var until: Date
        /// The request's name (GUID), to cancel it.
        public var requestName: String
        public var scope: String
        public var roleDefinitionId: String
        /// When it was sent (nil: unknown).
        public var created: Date?

        public init(start: Date, until: Date, requestName: String, scope: String, roleDefinitionId: String, created: Date? = nil) {
            self.start = start
            self.until = until
            self.requestName = requestName
            self.scope = scope
            self.roleDefinitionId = roleDefinitionId
            self.created = created
        }

        /// A pending scheduled request (one Pimento did not track).
        init(_ r: ScheduledRequest) {
            self.init(start: r.start, until: r.end ?? r.start, requestName: r.name, scope: r.scope, roleDefinitionId: r.roleDefinitionId,
                      created: r.createdOn)
        }
    }

    /// The end of the activation last seen active.
    public var lastEnd: Date?
    /// Its start: a `SelfDeactivate` after it means you ended it.
    public var lastStart: Date?
    /// Of the activation being kept alive: sent again with the next one.
    public var justification: String?
    public var ticket: TicketInfo?
    /// The start of the working-hours window the counters belong to.
    public var window: Date?
    public var failures = 0
    public var retryAt: Date?
    public var lastError: String?
    public var handOver: HandOver?
    /// Notices already given in this window (blocked, last of the day).
    public var noticed: Set<String> = []

    public init() {}

    /// Notes what the listing says about the role: its end, and the
    /// justification and ticket of its activation (`info`, from your requests).
    public mutating func observe(_ role: EligibleRole, info: ActivationRequestInfo?, now: Date) {
        guard role.isActive else { return }
        if let end = role.activeUntil, end > now {
            lastEnd = end
            if let since = role.activeSince { lastStart = since }
            // The continuation is the activation now listed.
            if let h = handOver, h.start <= now.addingTimeInterval(KeepAlive.endedEarlySlack),
               abs(end.timeIntervalSince(h.until)) <= KeepAlive.continuationSlack || (role.activeSince.map { $0 >= h.start.addingTimeInterval(-60) } ?? false) {
                handOver = nil
            }
        } else if role.activeUntil == nil {
            lastEnd = nil
        }
        if let info {
            if let j = info.justification?.nonEmpty { justification = j }
            if let t = info.ticket, !t.isEmpty { ticket = t }
        }
    }

    /// Counters start over in each working-hours window.
    public mutating func enter(window start: Date?) {
        guard let start, start != window else { return }
        window = start
        failures = 0
        retryAt = nil
        noticed = []
    }

    mutating func failed(_ message: String, now: Date) {
        failures += 1
        lastError = message
        retryAt = failures <= KeepAlive.retryDelays.count ? now.addingTimeInterval(KeepAlive.retryDelays[failures - 1]) : nil
    }

    mutating func succeeded() {
        failures = 0
        retryAt = nil
        lastError = nil
    }
}

/// The justification and ticket of one of your requests.
public struct ActivationRequestInfo: Equatable, Sendable {
    public var justification: String?
    public var ticket: TicketInfo?

    public init(justification: String?, ticket: TicketInfo?) {
        self.justification = justification
        self.ticket = ticket
    }
}

extension RequestHistory {
    /// Justification and ticket of each request, by lower-cased request name.
    public var activationInfo: [String: ActivationRequestInfo] {
        var result: [String: ActivationRequestInfo] = [:]
        for item in items {
            guard let name = (item.name ?? item.id.map(RoleMatcher.lastPathComponent))?.lowercased() else { continue }
            let p = item.properties
            result[name] = ActivationRequestInfo(
                justification: p?.justification?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty,
                ticket: TicketInfo.make(number: p?.ticketInfo?.ticketNumber, system: p?.ticketInfo?.ticketSystem))
        }
        return result
    }

    /// When you last ended each role (`SelfDeactivate`, from anywhere, any
    /// status), by role key (`ReminderRole.key`).
    public var deactivations: [String: Date] {
        var result: [String: Date] = [:]
        for item in items {
            guard let p = item.properties,
                  p.requestType?.caseInsensitiveCompare(RequestAction.deactivate.requestType) == .orderedSame,
                  let scope = p.scope, let roleDefinitionId = p.roleDefinitionId, let created = AzureDate.parse(p.createdOn)
            else { continue }
            let key = ReminderRole.key(RoleMatcher.key(scope: scope, roleDefinitionId: roleDefinitionId))
            result[key] = max(result[key] ?? created, created)
        }
        return result
    }

    /// What the current activation of `role` was requested with, if known.
    public static func info(for role: EligibleRole, in infos: [String: ActivationRequestInfo]) -> ActivationRequestInfo? {
        guard role.isActive, let schedule = role.activeScheduleId else { return nil }
        return infos[RoleMatcher.lastPathComponent(schedule).lowercased()]
    }
}

/// Every kept role's track, by role key (`ReminderRole.key`).
public struct KeepAliveBook: Equatable, Sendable {
    public var tracks: [String: KeepAliveTrack] = [:]

    public init() {}

    public subscript(key: String) -> KeepAliveTrack {
        get { tracks[key] ?? KeepAliveTrack() }
        set { tracks[key] = newValue }
    }

    /// Stops keeping `key` alive: forgets it, and returns the continuation
    /// Pimento scheduled that has not started yet (to withdraw).
    public mutating func remove(_ key: String, now: Date) -> KeepAliveTrack.HandOver? {
        let h = tracks.removeValue(forKey: key)?.handOver
        return h.flatMap { $0.start > now ? $0 : nil }
    }

    /// Pausing: what lapses meanwhile is not brought back on resume, and the
    /// continuations not started yet are returned (to withdraw) and
    /// forgotten: after a resume, a role is continued again. (One whose
    /// withdrawal failed is still pending, and is seen there.)
    public mutating func pause(now: Date) -> [String: KeepAliveTrack.HandOver] {
        var withdraw: [String: KeepAliveTrack.HandOver] = [:]
        for key in tracks.keys {
            tracks[key]?.lastEnd = nil
            if let h = tracks[key]?.handOver, h.start > now {
                withdraw[key] = h
                tracks[key]?.handOver = nil
            }
        }
        return withdraw
    }

    /// Records how `action` for `role` went; returns what to tell the user.
    public mutating func record(
        _ action: KeepAliveAction, outcome: KeepAliveOutcome, role: EligibleRole, key: String, now: Date
    ) -> KeepAliveEvent {
        var track = self[key]
        defer { self[key] = track }
        switch (action, outcome) {
        case (.handOver(let start, let minutes, let clipped, _, _), .request(let o, let requestId)):
            switch o {
            case .scheduled(_, let s, let until):
                track.succeeded()
                let end = until ?? s.addingTimeInterval(TimeInterval(minutes) * 60)
                track.handOver = .init(start: s, until: end, requestName: requestId, scope: role.scope, roleDefinitionId: role.roleDefinitionId,
                                       created: now)
                return .renewed(role: role, start: s, until: end, clipped: clipped, lapsedAt: nil)
            case .activated(let status, let until) where ActivationOutcome.isGranted(status: status) && !o.isAwaitingApproval:
                track.succeeded()
                let end = until ?? start.addingTimeInterval(TimeInterval(minutes) * 60)
                track.handOver = .init(start: start, until: end, requestName: requestId, scope: role.scope, roleDefinitionId: role.roleDefinitionId,
                                       created: now)
                return .renewed(role: role, start: start, until: end, clipped: clipped, lapsedAt: nil)
            default:
                track.failed(o.summary, now: now)
                return .failed(role: role, message: Self.message(o, overlap: true), retryAt: track.retryAt, failures: track.failures)
            }
        case (.activateNow(let minutes, let clipped, _, _), .request(let o, let requestId)):
            if case .activated(let status, let until) = o, ActivationOutcome.isGranted(status: status), !o.isAwaitingApproval {
                track.succeeded()
                let end = until ?? now.addingTimeInterval(TimeInterval(minutes) * 60)
                let lapsed = track.lastEnd
                track.lastEnd = end
                track.lastStart = now
                track.handOver = .init(start: now, until: end, requestName: requestId, scope: role.scope, roleDefinitionId: role.roleDefinitionId,
                                       created: now)
                return .renewed(role: role, start: now, until: end, clipped: clipped, lapsedAt: lapsed)
            }
            track.failed(o.summary, now: now)
            return .failed(role: role, message: Self.message(o, overlap: false), retryAt: track.retryAt, failures: track.failures)
        case (.cancel, .cancel(let c)):
            switch c {
            case .canceled, .notCancellable:
                track.handOver = nil
                track.lastEnd = nil
                return .withdrawn(role: role)
            case .failed:
                track.failed(c.summary, now: now)
                return .failed(role: role, message: "Could not withdraw its continuation: \(c.summary)", retryAt: track.retryAt,
                               failures: track.failures)
            }
        default:
            track.failed("unexpected answer", now: now)
            return .failed(role: role, message: "unexpected answer", retryAt: track.retryAt, failures: track.failures)
        }
    }

    static func message(_ o: ActivationOutcome, overlap: Bool) -> String {
        if o == .alreadyActive {
            return overlap
                ? "PIM refused a continuation that would overlap the current activation (RoleAssignmentExists)"
                : "PIM still lists the old activation (RoleAssignmentExists)"
        }
        return o.summary
    }
}

/// The answer to one keep-alive action.
public enum KeepAliveOutcome: Equatable, Sendable {
    /// An activation request's outcome, and the request's name.
    case request(ActivationOutcome, requestId: String)
    case cancel(CancelOutcome)
}

/// What a pass did, for notifications and the CLI's output.
public enum KeepAliveEvent: Equatable, Sendable {
    /// Continued from `start` (the current end, or now when it had lapsed at `lapsedAt`) to `until`.
    case renewed(role: EligibleRole, start: Date, until: Date, clipped: Bool, lapsedAt: Date?)
    /// `retryAt` nil: gave up for this window.
    case failed(role: EligibleRole, message: String, retryAt: Date?, failures: Int)
    /// A continuation was withdrawn (the role was ended or replaced, or keep-alive is paused).
    case withdrawn(role: EligibleRole)
    /// A due renewal could not be sent (once per window).
    case blocked(role: EligibleRole, KeepAliveBlock)
    /// Keep-alive stops for today: not even an hour fits (once per window).
    case lastOfDay(role: EligibleRole, end: Date, windowEnd: Date)

    public var role: EligibleRole {
        switch self {
        case .renewed(let r, _, _, _, _), .failed(let r, _, _, _), .withdrawn(let r), .blocked(let r, _), .lastOfDay(let r, _, _): r
        }
    }

    public var isFailure: Bool {
        switch self {
        case .failed, .blocked: true
        default: false
        }
    }

    /// The notification: `Renewed Contributor until 18:00`, …
    public func notice(now: Date, timeZone: TimeZone = .current) -> (title: String, body: String) {
        let t = { KeepAliveText.clock($0, now: now, timeZone: timeZone) }
        let r = role
        switch self {
        case .renewed(_, let start, let until, let clipped, let lapsedAt):
            var body: String
            if let lapsedAt {
                body = "\(r.scopeName): it had ended at \(t(lapsedAt)) (asleep, or Pimento was not running); activated again now."
            } else {
                body = "\(r.scopeName): the next activation starts when the current one ends at \(t(start)), without a gap."
            }
            if clipped { body += " Shortened to end with your working hours." }
            return ("Renewed \(r.roleName) until \(t(until))", body)
        case .failed(_, let message, let retryAt, let failures):
            let next = retryAt.map { "Trying again at \(t($0))." }
                ?? "Gave up after \(failures) attempts until your next working hours: renew it yourself."
            return ("Could not renew \(r.roleName)", "\(r.scopeName): \(message). \(next)")
        case .withdrawn:
            return ("Withdrew the continuation of \(r.roleName)",
                    "\(r.scopeName): it was ended, replaced or keep-alive is paused, so its scheduled continuation was withdrawn.")
        case .blocked(_, .needsJustification):
            return ("Not renewing \(r.roleName)", "\(r.scopeName): the justification of its activation is unknown. Renew it yourself.")
        case .blocked(_, .needsTicket):
            return ("Not renewing \(r.roleName)",
                    "\(r.scopeName): its policy requires a ticket and the activation's ticket is unknown. Renew it yourself with a ticket.")
        case .lastOfDay(_, let end, let windowEnd):
            return ("\(r.roleName) ends at \(t(end))",
                    "\(r.scopeName): less than an hour is left until your working hours end at \(t(windowEnd)), so keep-alive stops for today.")
        }
    }
}

/// One pass of keep-alive over the kept roles: pure.
public enum KeepAlivePlanner {
    public struct Item: Equatable, Sendable {
        public let key: String
        public let role: EligibleRole
        public let rule: KeepAliveRule
        public var status: KeepAliveStatus
    }

    /// The kept roles among `roles` (one row per scope + role, direct rows
    /// first) with what each needs now. Updates `book` with what the listing
    /// says (`KeepAliveTrack.observe`), the window counters and ended-early roles.
    public static func plan(
        roles: [EligibleRole], rules: [String: KeepAliveRule], policies: [RoleMatcher.Key: PolicyLookup],
        infos: [String: ActivationRequestInfo], pending: [ScheduledRequest], book: inout KeepAliveBook,
        hours: WorkingHours, paused: Bool, now: Date, calendar: Calendar, confirmedAccess: Set<String>? = nil,
        deactivations: [String: Date] = [:]
    ) -> [Item] {
        var byKey: [String: EligibleRole] = [:]
        var order: [String] = []
        for role in roles {
            let key = ReminderRole.key(role.policyKey)
            guard rules[key] != nil else { continue }
            if let existing = byKey[key] {
                // The active row, then the direct one.
                if (!existing.isActive && role.isActive) || (existing.isActive == role.isActive && existing.membership != .direct && role.membership == .direct) {
                    byKey[key] = role
                }
                continue
            }
            byKey[key] = role
            order.append(key)
        }
        let window = hours.window(containing: now, calendar: calendar)
        let pendingByKey = Dictionary(grouping: pending) { ReminderRole.key($0.policyKey) }
        return order.map { key in
            let role = byKey[key]!, rule = rules[key]!
            var track = book[key]
            track.enter(window: window?.start)
            track.observe(role, info: RequestHistory.info(for: role, in: infos), now: now)
            // Paused: what lapses meanwhile is not brought back on resume (`KeepAliveBook.pause`).
            if paused { track.lastEnd = nil }
            var status = KeepAlive.decide(
                role: role, rule: rule, policy: policies[role.policyKey], pending: pendingByKey[key] ?? [], track: track,
                hours: hours, paused: paused, now: now, calendar: calendar, deactivatedAt: deactivations[key])
            // An access-granting role nobody confirmed: never sent (a withdrawal is).
            if role.grantsAccess, confirmedAccess.map({ !$0.contains(key) }) == true, !status.isWithdrawal {
                status = paused ? .paused : .excluded(.notConfirmed)
            }
            if status == .endedEarly { track.lastEnd = nil }
            book[key] = track
            return Item(key: key, role: role, rule: rule, status: status)
        }
    }

    /// The soonest moment any item should be looked at again.
    public static func nextCheck(_ items: [Item], now: Date) -> Date? {
        items.compactMap { $0.status.nextCheck(now: now) }.min()
    }

    /// Notices given once per window: a blocked renewal, the last of the day.
    public static func onceEvents(_ items: [Item], book: inout KeepAliveBook) -> [KeepAliveEvent] {
        items.compactMap { item in
            let event: KeepAliveEvent, tag: String
            switch item.status {
            case .blocked(let why): (event, tag) = (.blocked(role: item.role, why), why.rawValue)
            case .lastOfDay(let end, let windowEnd): (event, tag) = (.lastOfDay(role: item.role, end: end, windowEnd: windowEnd), "lastOfDay")
            default: return nil
            }
            guard book[item.key].noticed.insert(tag).inserted else { return nil }
            return event
        }
    }
}

public enum KeepAliveText {
    /// `14:20` today, `Mon 08:00` on another day.
    public static func clock(_ date: Date, now: Date, timeZone: TimeZone = .current) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = calendar.isDate(date, inSameDayAs: now) ? "HH:mm" : "EEE HH:mm"
        return f.string(from: date)
    }
}
