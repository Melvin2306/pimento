import Foundation

/// `ticketInfo` of an activation request. PIM checks it when the role's policy
/// has `Ticketing` among the enabled end-user rules (`TicketingRule` fails
/// otherwise); any other role accepts it as extra information.
public struct TicketInfo: Codable, Hashable, Sendable {
    public var ticketNumber: String?
    public var ticketSystem: String?

    /// Trims both; empty values become nil.
    public init(number: String?, system: String?) {
        ticketNumber = number?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
        ticketSystem = system?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
    }

    /// nil when neither a number nor a system is given.
    public static func make(number: String?, system: String?) -> TicketInfo? {
        let t = TicketInfo(number: number, system: system)
        return t.isEmpty ? nil : t
    }

    public var isEmpty: Bool { ticketNumber == nil && ticketSystem == nil }

    /// Both a number and a system: what a ticket-requiring policy needs.
    public var isComplete: Bool { ticketNumber != nil && ticketSystem != nil }

    /// `CHG-1001 (ServiceNow)`.
    public var label: String {
        switch (ticketNumber, ticketSystem) {
        case let (n?, s?): "\(n) (\(s))"
        case let (n?, nil): n
        case let (nil, s?): "(\(s))"
        default: ""
        }
    }

    /// `recent` with `ticket` moved to the front, de-duplicated and capped.
    public static func recording(_ ticket: TicketInfo?, in recent: [TicketInfo], limit: Int = 10) -> [TicketInfo] {
        guard let ticket, ticket.ticketNumber != nil else { return recent }
        return Array(([ticket] + recent.filter { $0 != ticket }).prefix(max(0, limit)))
    }
}

/// Which roles need ticket information, from their PIM policies.
public enum TicketRequirement {
    /// Roles whose policy requires a ticket. Roles with an unknown policy
    /// (not loaded, failed) are not counted: PIM will say so if needed.
    public static func rolesNeedingTicket(_ roles: [EligibleRole], policy: (EligibleRole) -> PolicyLookup?) -> [EligibleRole] {
        roles.filter { policy($0)?.policy?.requiresTicket == true }
    }

    /// Roles that need a ticket while `ticket` lacks a number or a system.
    public static func missing(_ roles: [EligibleRole], ticket: TicketInfo?, policy: (EligibleRole) -> PolicyLookup?) -> [EligibleRole] {
        if ticket?.isComplete == true { return [] }
        return rolesNeedingTicket(roles, policy: policy)
    }
}
