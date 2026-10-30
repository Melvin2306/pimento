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
    /// When the current activation started (nil: not active, or unknown).
    /// PIM refuses to end an activation in its first five minutes.
    public var activeSince: Date?
    /// The `roleAssignmentSchedules` id of the current activation, if known.
    public var activeScheduleId: String?
    /// The eligibility the current activation was made with (its instance's
    /// `linkedRoleEligibilityScheduleId`), if known. With eligibilities both
    /// direct and through a group, it may be the other row's.
    public var activeEligibilityScheduleId: String?

    public init(
        id: String, eligibilityScheduleId: String, roleDefinitionId: String, roleName: String,
        scope: String, scopeName: String, scopeType: String, membership: Membership,
        condition: String? = nil, conditionVersion: String? = nil,
        isActive: Bool = false, activeUntil: Date? = nil,
        activeSince: Date? = nil, activeScheduleId: String? = nil, activeEligibilityScheduleId: String? = nil
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
        self.activeSince = activeSince
        self.activeScheduleId = activeScheduleId
        self.activeEligibilityScheduleId = activeEligibilityScheduleId
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

    /// The current activation of a scope + role.
    public struct Activation: Equatable, Sendable {
        /// nil: open-ended.
        public var end: Date?
        public var start: Date?
        public var scheduleId: String?
        /// `linkedRoleEligibilityScheduleId` of the instance.
        public var eligibilityScheduleId: String?
    }

    /// Active (Activated, not yet expired) assignments → latest end time per key.
    /// The value is `nil` when the instance has no end date.
    public static func activeIndex(_ assignments: [AssignmentScheduleInstance], now: Date = Date()) -> [Key: Date?] {
        activations(assignments, now: now).mapValues(\.end)
    }

    /// Active (Activated, not yet expired) assignments per key; of several, the
    /// one that ends last (an open-ended one wins).
    public static func activations(_ assignments: [AssignmentScheduleInstance], now: Date = Date()) -> [Key: Activation] {
        var index: [Key: Activation] = [:]
        for item in assignments {
            let p = item.properties
            guard p.assignmentType?.caseInsensitiveCompare("Activated") == .orderedSame else { continue }
            let end = AzureDate.parse(p.endDateTime)
            if let end, end <= now { continue }
            let k = key(scope: p.scope, roleDefinitionId: p.roleDefinitionId)
            let activation = Activation(end: end, start: AzureDate.parse(p.startDateTime), scheduleId: p.roleAssignmentScheduleId,
                                        eligibilityScheduleId: p.linkedRoleEligibilityScheduleId.flatMap { $0.isEmpty ? nil : $0 })
            if let existing = index[k] {
                // Keep the later expiry; nil (open-ended) wins.
                guard let current = existing.end else { continue }
                if end == nil || end! > current { index[k] = activation }
            } else {
                index[k] = activation
            }
        }
        return index
    }

    /// Admin-assigned (not activated) assignments of the user with an end
    /// date, still running: the ones `SelfExtend` is for.
    public static func timeBoundAssignments(_ assignments: [AssignmentScheduleInstance], now: Date = Date()) -> [ActiveAssignment] {
        var seen = Set<String>()
        return assignments.compactMap { item -> ActiveAssignment? in
            let p = item.properties
            guard p.assignmentType?.caseInsensitiveCompare("Assigned") == .orderedSame,
                  p.memberType.map({ $0.caseInsensitiveCompare("Direct") == .orderedSame }) ?? true,
                  let end = AzureDate.parse(p.endDateTime), end > now,
                  let scheduleId = p.roleAssignmentScheduleId,
                  seen.insert(scheduleId.lowercased()).inserted
            else { return nil }
            let x = p.expandedProperties
            return ActiveAssignment(
                id: item.id ?? scheduleId, scheduleId: scheduleId, roleDefinitionId: p.roleDefinitionId,
                roleName: x?.roleDefinition?.displayName ?? lastPathComponent(p.roleDefinitionId),
                scope: p.scope, scopeName: x?.scope?.displayName ?? lastPathComponent(p.scope),
                scopeType: x?.scope?.type ?? inferScopeType(p.scope),
                start: AzureDate.parse(p.startDateTime), end: end,
                condition: (p.condition?.isEmpty == false) ? p.condition : nil, conditionVersion: p.conditionVersion)
        }
        .sorted { $0.end < $1.end }
    }

    public static func rows(
        eligibilities: [EligibilityScheduleInstance],
        assignments: [AssignmentScheduleInstance],
        now: Date = Date()
    ) -> [EligibleRole] {
        let active = activations(assignments, now: now)
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
                activeUntil: activeEntry?.end,
                activeSince: activeEntry?.start,
                activeScheduleId: activeEntry?.scheduleId,
                activeEligibilityScheduleId: activeEntry?.eligibilityScheduleId
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
