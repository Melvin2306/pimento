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
        reminderLead: TimeInterval = ActivationSummary.defaultReminderLead,
        now: Date = Date(),
        timeZone: TimeZone = .current
    ) {
        var activated: [(role: EligibleRole, until: Date?)] = []
        var skipped = 0
        var failed: [(role: EligibleRole, outcome: ActivationOutcome)] = []
        for plan in planned {
            guard let outcome = outcomes[plan.id] else { continue }
            switch outcome {
            case .activated(_, let until): activated.append((plan.role, until))
            case .alreadyActive: skipped += 1
            case .policyViolation, .failed: failed.append((plan.role, outcome))
            }
        }
        guard !activated.isEmpty || skipped > 0 || !failed.isEmpty else { return nil }

        let time = Date.FormatStyle(date: .omitted, time: .shortened, timeZone: timeZone)
        func line(_ role: EligibleRole) -> String { "\(role.roleName) · \(role.scopeName)" }
        func list(_ roles: [EligibleRole]) -> String {
            let shown = roles.prefix(Self.listed).map(line)
            let more = roles.count - shown.count
            return (shown + (more > 0 ? ["and \(more) more"] : [])).joined(separator: "\n")
        }
        func plural(_ n: Int, _ noun: String) -> String { "\(n) \(noun)\(n == 1 ? "" : "s")" }

        isFailure = !failed.isEmpty
        if failed.isEmpty {
            title = activated.isEmpty
                ? "\(plural(skipped, "role")) already active"
                : "\(plural(activated.count, "role")) activated"
        } else {
            title = activated.isEmpty
                ? "Activation failed for \(plural(failed.count, "role"))"
                : "\(activated.count) activated, \(failed.count) failed"
        }

        var parts: [String] = []
        if !activated.isEmpty {
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
        if !failed.isEmpty {
            parts.append("Failed:\n" + list(failed.map(\.role)))
        }
        if skipped > 0 && !activated.isEmpty || skipped > 0 && !failed.isEmpty {
            parts.append("\(skipped) already active")
        }
        body = parts.joined(separator: "\n")

        // One reminder per expiry minute, listing the roles that expire then.
        var byMinute: [Date: [EligibleRole]] = [:]
        for item in activated {
            guard let until = item.until else { continue }
            let minute = Date(timeIntervalSince1970: (until.timeIntervalSince1970 / 60).rounded(.down) * 60)
            byMinute[minute, default: []].append(item.role)
        }
        reminders = byMinute.keys.sorted().compactMap { minute in
            let fireAt = minute.addingTimeInterval(-reminderLead)
            guard fireAt > now else { return nil }
            let roles = byMinute[minute]!
            return Reminder(
                id: Self.reminderPrefix + String(Int(minute.timeIntervalSince1970)),
                fireAt: fireAt,
                title: "\(plural(roles.count, "PIM role")) expire\(roles.count == 1 ? "s" : "") at \(minute.formatted(time))",
                body: list(roles)
            )
        }
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
