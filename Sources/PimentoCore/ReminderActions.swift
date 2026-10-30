import Foundation

/// A role named in an expiry reminder: enough to find it again after a
/// refresh (scope + role GUID) and to list it.
public struct ReminderRole: Equatable, Hashable, Sendable {
    /// `scope|roleGUID`, lower-case (`RoleMatcher.Key`).
    public let key: String
    /// `Contributor · contoso-dev`.
    public let line: String
    public let isOwner: Bool

    public init(key: String, line: String, isOwner: Bool = false) {
        self.key = key
        self.line = line
        self.isOwner = isOwner
    }

    public init(_ role: EligibleRole) {
        self.init(key: Self.key(role.policyKey), line: "\(role.roleName) · \(role.scopeName)", isOwner: role.isOwner)
    }

    public static func key(_ k: RoleMatcher.Key) -> String { "\(k.scope)|\(k.role)" }
}

/// The actions on an expiry reminder ("Renew", "End now") and the data the
/// reminder carries for them. UserNotifications wiring stays in the app; the
/// identifiers, the payload and what to do with a tap live here, tested.
public enum ReminderAction: String, CaseIterable, Sendable {
    /// Deactivate and activate again, for the same duration as before.
    case renew = "pimento.reminder.renew"
    /// Deactivate now.
    case end = "pimento.reminder.end"

    /// `UNNotificationCategory` identifier of expiry reminders.
    public static let categoryIdentifier = "pimento.expiry-reminder"

    public var title: String {
        switch self {
        case .renew: "Renew"
        case .end: "End Now"
        }
    }

    /// Ending access is destructive (red in the notification).
    public var isDestructive: Bool { self == .end }

    /// Both act on Azure, so both need the app (and the az token) running;
    /// Renew may ask for a justification or the Owner confirmation.
    public var opensApp: Bool { self == .renew }

    /// Both send a write to Azure as you: macOS asks to unlock first, so
    /// neither can be pressed on the lock screen by someone else.
    public var requiresAuthentication: Bool { true }
}

/// What an expiry reminder carries in `userInfo`: property-list values only.
public struct ReminderPayload: Equatable, Sendable {
    public var roles: [ReminderRole]
    /// The tenant the roles are in (nil: az's default tenant).
    public var tenantId: String?
    /// The justification of the activation, when the user keeps recent
    /// justifications; Renew reuses it. Otherwise Renew asks.
    public var justification: String?
    /// The duration the roles were activated for, to renew them alike.
    public var duration: RequestedDuration?

    public init(roles: [ReminderRole], tenantId: String? = nil, justification: String? = nil, duration: RequestedDuration? = nil) {
        self.roles = roles
        self.tenantId = tenantId
        self.justification = justification
        self.duration = duration
    }

    enum Keys {
        static let keys = "roleKeys"
        static let lines = "roleLines"
        static let owners = "ownerKeys"
        static let tenant = "tenantId"
        static let justification = "justification"
        static let duration = "duration"
    }

    public var userInfo: [String: Any] {
        var info: [String: Any] = [
            Keys.keys: roles.map(\.key),
            Keys.lines: roles.map(\.line),
            Keys.owners: roles.filter(\.isOwner).map(\.key),
        ]
        if let tenantId { info[Keys.tenant] = tenantId }
        if let justification, !justification.isEmpty { info[Keys.justification] = justification }
        if let duration { info[Keys.duration] = duration.stringValue }
        return info
    }

    /// nil when `userInfo` is not a reminder payload (or names no role).
    public init?(userInfo: [AnyHashable: Any]) {
        guard let keys = userInfo[Keys.keys] as? [String], !keys.isEmpty else { return nil }
        let lines = userInfo[Keys.lines] as? [String] ?? []
        let owners = Set(userInfo[Keys.owners] as? [String] ?? [])
        roles = keys.enumerated().map { i, key in
            ReminderRole(key: key, line: i < lines.count ? lines[i] : key, isOwner: owners.contains(key))
        }
        tenantId = userInfo[Keys.tenant] as? String
        justification = (userInfo[Keys.justification] as? String).flatMap { $0.isEmpty ? nil : $0 }
        duration = (userInfo[Keys.duration] as? String).flatMap(RequestedDuration.init(stringValue:))
    }

    /// The payload without `ended` roles; nil when none is left (the
    /// reminder should then be removed).
    public func removing(_ ended: Set<String>) -> ReminderPayload? {
        var copy = self
        copy.roles.removeAll { ended.contains($0.key) }
        return copy.roles.isEmpty ? nil : copy
    }

    /// The rows of `roles` this reminder is about that are still active.
    public func matchingActive(in roles: [EligibleRole]) -> [EligibleRole] {
        let wanted = Set(self.roles.map(\.key))
        return roles.filter { $0.isActive && wanted.contains(ReminderRole.key($0.policyKey)) }
    }

    /// Whether the reminder's tenant is `current` (both nil counts).
    public func isTenant(_ current: String?) -> Bool {
        switch (tenantId, current) {
        case (nil, _): true
        case (let a?, let b?): a.caseInsensitiveCompare(b) == .orderedSame
        case (_?, nil): false
        }
    }
}

/// What to do with pending reminders once some roles were ended or renewed.
public enum ReminderUpdate: Equatable, Sendable {
    /// Nothing left in it: remove.
    case remove(id: String)
    /// Re-schedule under the same identifier with the remaining roles.
    case replace(ActivationSummary.Reminder, ReminderPayload)

    /// For each pending reminder (`id`, payload) that names one of `ended`.
    public static func updates(
        pending: [(id: String, fireAt: Date, payload: ReminderPayload)],
        ended: Set<String>,
        timeZone: TimeZone = .current
    ) -> [ReminderUpdate] {
        pending.compactMap { item in
            guard item.payload.roles.contains(where: { ended.contains($0.key) }) else { return nil }
            guard let rest = item.payload.removing(ended), let minute = ActivationSummary.expiry(ofReminder: item.id) else {
                return .remove(id: item.id)
            }
            let reminder = ActivationSummary.reminder(
                expiringAt: minute, roles: rest.roles, fireAt: item.fireAt, timeZone: timeZone, id: item.id)
            return .replace(reminder, rest)
        }
    }
}
