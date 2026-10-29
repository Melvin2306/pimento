import Foundation

/// What to tell the user once a batch of activations is done: the text of the
/// completion notification and the expiry reminders to schedule. Pure, so the
/// wording is unit-tested; posting is the app's job.
public struct ActivationSummary: Equatable, Sendable {
    public struct Reminder: Equatable, Sendable {
        /// Stable per expiry minute, so a re-run replaces instead of duplicating.
        public let id: String
        public let fireAt: Date
        public let title: String
        public let body: String
        /// The roles it is about (`ReminderRole.key`), for its actions and for
        /// taking a role out when it is ended or renewed.
        public var roles: [ReminderRole] = []

        public init(id: String, fireAt: Date, title: String, body: String, roles: [ReminderRole] = []) {
            self.id = id
            self.fireAt = fireAt
            self.title = title
            self.body = body
            self.roles = roles
        }
    }

    /// What was done to the roles.
    public enum Operation: Sendable {
        case activate, deactivate, renew, extend
    }

    public let title: String
    public let body: String
    public let isFailure: Bool
    public let reminders: [Reminder]

    /// How long before expiry a reminder fires, unless the caller says otherwise.
    public static let defaultReminderLead: TimeInterval = 10 * 60
    static let listed = 3
    static let reminderPrefix = "expiry-"

    /// - Parameter reminderLead: how long before expiry each reminder fires.
    public init?(
        planned: [PlannedRequest],
        outcomes: [String: ActivationOutcome],
        operation: Operation = .activate,
        reminderLead: TimeInterval = ActivationSummary.defaultReminderLead,
        now: Date = Date(),
        timeZone: TimeZone = .current
    ) {
        self.init(roles: planned.map(\.role), outcomes: outcomes, operation: operation,
                  reminderLead: reminderLead, now: now, timeZone: timeZone)
    }

    /// `roles` with their outcomes by role id; roles without one are left out.
    public init?(
        roles: [EligibleRole],
        outcomes: [String: ActivationOutcome],
        operation: Operation = .activate,
        reminderLead: TimeInterval = ActivationSummary.defaultReminderLead,
        now: Date = Date(),
        timeZone: TimeZone = .current
    ) {
        var activated: [(role: EligibleRole, until: Date?)] = []
        var awaiting: [EligibleRole] = []
        var scheduled: [(role: EligibleRole, start: Date)] = []
        var ended: [EligibleRole] = []
        var skipped = 0
        var failed: [(role: EligibleRole, outcome: ActivationOutcome)] = []
        for role in roles {
            guard let outcome = outcomes[role.id] else { continue }
            switch outcome {
            case .activated where operation != .extend && outcome.isAwaitingApproval: awaiting.append(role)
            case .activated(_, let until), .renewed(let until): activated.append((role, until))
            case .alreadyActive, .notActive: skipped += 1
            case .deactivated: ended.append(role)
            case .scheduled(_, let start, _): scheduled.append((role, start))
            case .policyViolation, .failed, .tooSoon: failed.append((role, outcome))
            }
        }
        guard !activated.isEmpty || !awaiting.isEmpty || !scheduled.isEmpty || !ended.isEmpty || skipped > 0 || !failed.isEmpty else { return nil }

        let time = Date.FormatStyle(date: .omitted, time: .shortened, timeZone: timeZone)
        func line(_ role: EligibleRole) -> String { "\(role.roleName) · \(role.scopeName)" }
        func list(_ roles: [EligibleRole]) -> String {
            let shown = roles.prefix(Self.listed).map(line)
            let more = roles.count - shown.count
            return (shown + (more > 0 ? ["and \(more) more"] : [])).joined(separator: "\n")
        }
        func plural(_ n: Int, _ noun: String) -> String { "\(n) \(noun)\(n == 1 ? "" : "s")" }

        isFailure = !failed.isEmpty
        // Only scheduled (a start later): say so instead of "activated".
        let onlyScheduled = activated.isEmpty && !scheduled.isEmpty
        let (done, verb, noun, skippedText): (Int, String, String, String) = switch operation {
        case .activate where onlyScheduled: (scheduled.count, "scheduled", "Scheduling", "already active")
        case .activate: (activated.count, "activated", "Activation", "already active")
        case .renew: (activated.count, "renewed", "Renewal", "not active")
        case .extend: (activated.count, "requested", "Extension request", "not active")
        case .deactivate: (ended.count, "deactivated", "Deactivation", "not active")
        }
        if failed.isEmpty, done == 0, !awaiting.isEmpty {
            title = "\(plural(awaiting.count, "role")) awaiting approval"
        } else if failed.isEmpty {
            title = done == 0
                ? "\(plural(skipped, "role")) \(skippedText)"
                : operation == .extend ? "Extension requested for \(plural(done, "role"))" : "\(plural(done, "role")) \(verb)"
        } else {
            title = done == 0
                ? "\(noun) failed for \(plural(failed.count, "role"))"
                : "\(done) \(verb), \(failed.count) failed"
        }

        var parts: [String] = []
        if !ended.isEmpty {
            parts.append(list(ended))
        }
        if !activated.isEmpty, operation == .extend {
            parts.append("Waiting for an administrator to approve")
            parts.append(list(activated.map(\.role)))
        } else if !activated.isEmpty {
            let untils = activated.compactMap(\.until)
            if let first = untils.min() {
                let last = untils.max()!
                let span = first.formatted(time) == last.formatted(time)
                    ? "Active until \(first.formatted(time))"
                    : "Active until \(first.formatted(time))–\(last.formatted(time))"
                parts.append(span)
            }
            parts.append(list(activated.map(\.role)))
        }
        if !awaiting.isEmpty {
            parts.append("Awaiting approval (an approver has 24 hours to decide)")
            parts.append(list(awaiting))
        }
        if !scheduled.isEmpty {
            let starts = Set(scheduled.map { ScheduleTime.label($0.start, now: now, timeZone: timeZone) }).sorted()
            parts.append((onlyScheduled ? "" : "\(scheduled.count) scheduled, ") + "starts " + starts.joined(separator: ", "))
            parts.append(list(scheduled.map(\.role)))
        }
        if !failed.isEmpty {
            parts.append("Failed:\n" + list(failed.map(\.role)))
        }
        if skipped > 0 && (done > 0 || !failed.isEmpty) {
            parts.append("\(skipped) \(skippedText)")
        }
        body = parts.joined(separator: "\n")

        // One reminder per expiry minute, listing the roles that expire then.
        var byMinute: [Date: [EligibleRole]] = [:]
        for item in activated where operation != .extend {
            guard let until = item.until else { continue }
            let minute = Date(timeIntervalSince1970: (until.timeIntervalSince1970 / 60).rounded(.down) * 60)
            byMinute[minute, default: []].append(item.role)
        }
        reminders = byMinute.keys.sorted().compactMap { minute in
            let fireAt = minute.addingTimeInterval(-reminderLead)
            guard fireAt > now else { return nil }
            var seen = Set<String>()
            let roles = byMinute[minute]!.map(ReminderRole.init).filter { seen.insert($0.key).inserted }
            return Self.reminder(expiringAt: minute, roles: roles, fireAt: fireAt, timeZone: timeZone)
        }
    }

    /// The reminder for `roles` expiring at `minute`.
    public static func reminder(expiringAt minute: Date, roles: [ReminderRole], fireAt: Date, timeZone: TimeZone = .current) -> Reminder {
        let time = Date.FormatStyle(date: .omitted, time: .shortened, timeZone: timeZone)
        let shown = roles.prefix(listed).map(\.line)
        let more = roles.count - shown.count
        let n = roles.count
        return Reminder(
            id: reminderPrefix + String(Int(minute.timeIntervalSince1970)),
            fireAt: fireAt,
            title: "\(n) PIM role\(n == 1 ? "" : "s") expire\(n == 1 ? "s" : "") at \(minute.formatted(time))",
            body: (shown + (more > 0 ? ["and \(more) more"] : [])).joined(separator: "\n"),
            roles: roles)
    }

    /// The expiry minute a reminder identifier stands for.
    public static func expiry(ofReminder identifier: String) -> Date? {
        guard isReminder(identifier), let epoch = Int(identifier.dropFirst(reminderPrefix.count)) else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(epoch))
    }

    /// Whether the completion notification is wanted: `enabled`, and with
    /// `onlyFailures` only when something failed.
    public func postsCompletion(enabled: Bool, onlyFailures: Bool) -> Bool {
        enabled && (!onlyFailures || isFailure)
    }

    /// True for the identifiers of expiry reminders (to cancel or reschedule them).
    public static func isReminder(_ identifier: String) -> Bool { identifier.hasPrefix(reminderPrefix) }

    /// When the reminder `identifier` should fire with a new lead time, or nil
    /// when that moment has passed (or the identifier is not a reminder).
    public static func rescheduledFireDate(for identifier: String, reminderLead: TimeInterval, now: Date = Date()) -> Date? {
        guard isReminder(identifier), let epoch = Int(identifier.dropFirst(reminderPrefix.count)) else { return nil }
        let fireAt = Date(timeIntervalSince1970: TimeInterval(epoch)).addingTimeInterval(-reminderLead)
        return fireAt > now ? fireAt : nil
    }
}
