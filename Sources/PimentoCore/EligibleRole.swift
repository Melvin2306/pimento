import Foundation

public enum Membership: Hashable, Sendable {
    case direct
    case group(String)

    public var label: String {
        switch self {
        case .direct: "Direct"
        case .group(let name): "Group: \(name)"
        }
    }
}

/// One row of the UI: an eligibility, enriched with whether it is active right now.
public struct EligibleRole: Identifiable, Hashable, Sendable {
    /// The eligibility schedule *instance* id (unique per row).
    public let id: String
    /// Goes into `linkedRoleEligibilityScheduleId` of the activation request.
    public let eligibilityScheduleId: String
    public let roleDefinitionId: String
    public let roleName: String
    /// ARM scope path, e.g. `/subscriptions/<id>` or `/subscriptions/<id>/resourceGroups/<rg>`.
    public let scope: String
    public let scopeName: String
    /// Raw ARM scope type (`subscription`, `resourcegroup`, …).
    public let scopeType: String
    public let membership: Membership
    /// ABAC condition on the eligibility, if any; copied verbatim on activation.
    public let condition: String?
    public let conditionVersion: String?
    public var isActive: Bool
    public var activeUntil: Date?

    public init(
        id: String, eligibilityScheduleId: String, roleDefinitionId: String, roleName: String,
        scope: String, scopeName: String, scopeType: String, membership: Membership,
        condition: String? = nil, conditionVersion: String? = nil,
        isActive: Bool = false, activeUntil: Date? = nil
    ) {
        self.id = id
        self.eligibilityScheduleId = eligibilityScheduleId
        self.roleDefinitionId = roleDefinitionId
        self.roleName = roleName
        self.scope = scope
        self.scopeName = scopeName
        self.scopeType = scopeType
        self.membership = membership
        self.condition = condition
        self.conditionVersion = conditionVersion
        self.isActive = isActive
        self.activeUntil = activeUntil
    }

    public static let ownerRoleGUID = "8e3af657-a8ff-443c-a75c-2fe8c4bcb635"

    public var roleGUID: String { RoleMatcher.lastPathComponent(roleDefinitionId).lowercased() }

    public var isOwner: Bool {
        roleGUID == Self.ownerRoleGUID || roleName.caseInsensitiveCompare("Owner") == .orderedSame
    }

    public var hasCondition: Bool { !(condition ?? "").isEmpty }

    /// Scope + role: identifies the eligibility across refreshes (presets) and
    /// its PIM policy. Two rows share it when you are eligible both directly
    /// and through a group.
    public var policyKey: RoleMatcher.Key { RoleMatcher.key(scope: scope, roleDefinitionId: roleDefinitionId) }

    public var scopeTypeLabel: String {
        switch scopeType.lowercased() {
        case "subscription": "Subscription"
        case "resourcegroup": "Resource group"
        case "managementgroup": "Management group"
        case "": "Resource"
        default: scopeType.prefix(1).uppercased() + scopeType.dropFirst()
        }
    }

    /// Lower sorts first: eligible before active, then by expiry.
    public var statusSortKey: Double {
        guard isActive else { return 0 }
        return activeUntil?.timeIntervalSince1970 ?? .greatestFiniteMagnitude
    }
}

/// Turns the two ARM listings into UI rows.
public enum RoleMatcher {
    /// Scope + role GUID identifies "this eligibility is currently activated".
    /// The role GUID (not the full id) is used because the roleDefinitionId path
    /// is prefixed with whatever subscription it was read through.
    public struct Key: Hashable, Sendable {
        public let scope: String
        public let role: String
    }

    public static func key(scope: String, roleDefinitionId: String) -> Key {
        var normalizedScope = scope.lowercased()
        while normalizedScope.count > 1, normalizedScope.hasSuffix("/") { normalizedScope.removeLast() }
        return Key(scope: normalizedScope, role: lastPathComponent(roleDefinitionId).lowercased())
    }

    static func lastPathComponent(_ id: String) -> String {
        id.split(separator: "/").last.map(String.init) ?? id
    }

    /// Active (Activated, not yet expired) assignments → latest end time per key.
    /// The value is `nil` when the instance has no end date.
    public static func activeIndex(_ assignments: [AssignmentScheduleInstance], now: Date = Date()) -> [Key: Date?] {
        var index: [Key: Date?] = [:]
        for item in assignments {
            let p = item.properties
            guard p.assignmentType?.caseInsensitiveCompare("Activated") == .orderedSame else { continue }
            let end = AzureDate.parse(p.endDateTime)
            if let end, end <= now { continue }
            let k = key(scope: p.scope, roleDefinitionId: p.roleDefinitionId)
            if let existing = index[k] {
                // Keep the later expiry; nil (open-ended) wins.
                guard let current = existing else { continue }
                if end == nil || end! > current { index[k] = end }
            } else {
                index[k] = end
            }
        }
        return index
    }

    public static func rows(
        eligibilities: [EligibilityScheduleInstance],
        assignments: [AssignmentScheduleInstance],
        now: Date = Date()
    ) -> [EligibleRole] {
        let active = activeIndex(assignments, now: now)
        var seen = Set<String>()
        var rows: [EligibleRole] = []
        for e in eligibilities {
            guard seen.insert(e.id.lowercased()).inserted else { continue }
            let p = e.properties
            let x = p.expandedProperties
            let membership: Membership
            if p.memberType?.caseInsensitiveCompare("Group") == .orderedSame {
                membership = .group(x?.principal?.displayName ?? "group")
            } else {
                membership = .direct
            }
            let k = key(scope: p.scope, roleDefinitionId: p.roleDefinitionId)
            let activeEntry = active[k]
            rows.append(EligibleRole(
                id: e.id,
                eligibilityScheduleId: p.roleEligibilityScheduleId,
                roleDefinitionId: p.roleDefinitionId,
                roleName: x?.roleDefinition?.displayName ?? lastPathComponent(p.roleDefinitionId),
                scope: p.scope,
                scopeName: x?.scope?.displayName ?? lastPathComponent(p.scope),
                scopeType: x?.scope?.type ?? inferScopeType(p.scope),
                membership: membership,
                condition: (p.condition?.isEmpty == false) ? p.condition : nil,
                conditionVersion: p.conditionVersion,
                isActive: activeEntry != nil,
                activeUntil: activeEntry ?? nil
            ))
        }
        return rows.sorted {
            let a = $0.scopeName.lowercased(), b = $1.scopeName.lowercased()
            return a != b ? a < b : $0.roleName < $1.roleName
        }
    }

    static func inferScopeType(_ scope: String) -> String {
        let parts = scope.lowercased().split(separator: "/")
        if parts.contains("providers"), parts.count > 4 { return "resource" }
        if parts.contains("resourcegroups") { return "resourcegroup" }
        if parts.contains("subscriptions") { return "subscription" }
        if parts.contains("managementgroups") { return "managementgroup" }
        return ""
    }
}
