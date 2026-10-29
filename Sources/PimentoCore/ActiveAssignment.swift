import Foundation

/// An admin-assigned, time-bound active role assignment of the user (not a PIM
/// activation): `pimento extend` asks for these to be extended.
public struct ActiveAssignment: Identifiable, Hashable, Sendable {
    public let id: String
    /// `roleAssignmentSchedules` id: `targetRoleAssignmentScheduleId` of the request.
    public let scheduleId: String
    public let roleDefinitionId: String
    public let roleName: String
    public let scope: String
    public let scopeName: String
    public let scopeType: String
    public let start: Date?
    public let end: Date
    public let condition: String?
    public let conditionVersion: String?

    public init(
        id: String, scheduleId: String, roleDefinitionId: String, roleName: String,
        scope: String, scopeName: String, scopeType: String, start: Date?, end: Date,
        condition: String? = nil, conditionVersion: String? = nil
    ) {
        self.id = id
        self.scheduleId = scheduleId
        self.roleDefinitionId = roleDefinitionId
        self.roleName = roleName
        self.scope = scope
        self.scopeName = scopeName
        self.scopeType = scopeType
        self.start = start
        self.end = end
        self.condition = condition
        self.conditionVersion = conditionVersion
    }

    public var isOwner: Bool {
        RoleMatcher.lastPathComponent(roleDefinitionId).lowercased() == EligibleRole.ownerRoleGUID
            || roleName.caseInsensitiveCompare("Owner") == .orderedSame
    }

    public var hasCondition: Bool { !(condition ?? "").isEmpty }

    public var policyKey: RoleMatcher.Key { RoleMatcher.key(scope: scope, roleDefinitionId: roleDefinitionId) }

    /// As a table row: active until `end`, no eligibility.
    public var asRole: EligibleRole {
        EligibleRole(id: id, eligibilityScheduleId: "", roleDefinitionId: roleDefinitionId, roleName: roleName,
                     scope: scope, scopeName: scopeName, scopeType: scopeType, membership: .direct,
                     condition: condition, conditionVersion: conditionVersion,
                     isActive: true, activeUntil: end, activeSince: start, activeScheduleId: scheduleId)
    }

    public var scopeTypeLabel: String { asRole.scopeTypeLabel }
}
