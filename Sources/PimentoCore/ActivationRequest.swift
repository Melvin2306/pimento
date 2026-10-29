import Foundation

/// What a `roleAssignmentScheduleRequests` PUT asks PIM to do.
public enum RequestAction: String, Equatable, Sendable, CaseIterable {
    /// `SelfActivate`: activate an eligibility for a while.
    case activate = "SelfActivate"
    /// `SelfDeactivate`: end an activation early (not in its first 5 minutes).
    case deactivate = "SelfDeactivate"
    /// `SelfExtend`: ask an administrator to extend an expiring assignment.
    /// PIM files it as `PendingAdminDecision`; nothing changes until an
    /// administrator of the resource approves it.
    case extend = "SelfExtend"

    public var requestType: String { rawValue }
}

/// Body of `PUT {scope}/providers/Microsoft.Authorization/roleAssignmentScheduleRequests/{guid}`.
/// Optional fields are left out of the JSON when nil (synthesized `encodeIfPresent`).
public struct ActivationRequestBody: Encodable, Equatable, Sendable {
    public struct Expiration: Encodable, Equatable, Sendable {
        /// `AfterDuration` (with `duration`) or `AfterDateTime` (with `endDateTime`).
        public let type: String
        public let duration: String?
        public let endDateTime: String?

        public init(type: String, duration: String? = nil, endDateTime: String? = nil) {
            self.type = type
            self.duration = duration
            self.endDateTime = endDateTime
        }
    }

    public struct ScheduleInfo: Encodable, Equatable, Sendable {
        public let startDateTime: String
        public let expiration: Expiration
    }

    public struct Properties: Encodable, Equatable, Sendable {
        public let principalId: String
        public let roleDefinitionId: String
        public let requestType: String
        /// The eligibility an activation (or its deactivation) belongs to.
        public let linkedRoleEligibilityScheduleId: String?
        /// The assignment schedule an extension is for.
        public let targetRoleAssignmentScheduleId: String?
        public let justification: String
        /// Not sent for `SelfDeactivate`.
        public let scheduleInfo: ScheduleInfo?
        public let condition: String?
        public let conditionVersion: String?

        public init(
            principalId: String, roleDefinitionId: String, requestType: String,
            linkedRoleEligibilityScheduleId: String? = nil, targetRoleAssignmentScheduleId: String? = nil,
            justification: String, scheduleInfo: ScheduleInfo?, condition: String? = nil, conditionVersion: String? = nil
        ) {
            self.principalId = principalId
            self.roleDefinitionId = roleDefinitionId
            self.requestType = requestType
            self.linkedRoleEligibilityScheduleId = linkedRoleEligibilityScheduleId
            self.targetRoleAssignmentScheduleId = targetRoleAssignmentScheduleId
            self.justification = justification
            self.scheduleInfo = scheduleInfo
            self.condition = condition
            self.conditionVersion = conditionVersion
        }
    }

    public let properties: Properties

    /// The `duration` asked for, if any.
    public var duration: String? { properties.scheduleInfo?.expiration.duration }
}

public enum ActivationRequestError: Error, Equatable, LocalizedError {
    case missingJustification
    case invalidDuration(Int)
    case invalidMinutes(Int)
    case missingPrincipal
    case notActive
    case invalidDays(Int)

    public var errorDescription: String? {
        switch self {
        case .missingJustification: "A justification is required."
        case .invalidDuration(let h): "Duration must be 1–\(ActivationRequestBuilder.maxHours) hours (got \(h))."
        case .invalidMinutes(let m): "Duration must be 1 minute to \(ActivationRequestBuilder.maxHours) hours (got \(m) minutes)."
        case .missingPrincipal: "Could not determine your user object id from the token."
        case .notActive: "The role is not active."
        case .invalidDays(let d): "--days must be \(ExtendOptionsRange.days.lowerBound)-\(ExtendOptionsRange.days.upperBound) (got \(d))."
        }
    }
}

/// A fully built request: what dry-run shows and what a real run sends.
public struct PlannedRequest: Identifiable, Sendable, Equatable {
    public var id: String { role.id }
    public let role: EligibleRole
    public let url: URL
    public let body: ActivationRequestBody
    public let requestedAt: Date
    /// The duration this role is requested for, after the policy cap.
    /// Unused for a deactivation.
    public let duration: EffectiveDuration
    public var action: RequestAction = .activate
    /// When a scheduled activation starts; nil: right away.
    public var start: Date?

    public init(role: EligibleRole, url: URL, body: ActivationRequestBody, requestedAt: Date,
                duration: EffectiveDuration, action: RequestAction = .activate, start: Date? = nil) {
        self.role = role
        self.url = url
        self.body = body
        self.requestedAt = requestedAt
        self.duration = duration
        self.action = action
        self.start = start
    }

    /// When the activation ends if PIM grants it as asked.
    public var plannedEnd: Date { (start ?? requestedAt).addingTimeInterval(TimeInterval(duration.minutes) * 60) }

    public var minutes: Int { duration.minutes }

    public var bodyJSON: Data { ActivationRequestBuilder.encode(body) }

    public var prettyBody: String { String(decoding: bodyJSON, as: UTF8.self) }
}

public enum ActivationRequestBuilder {
    /// The longest activation Azure PIM allows for any role. A role's own policy
    /// is usually stricter (8 hours by default); ARM then rejects the request with
    /// an `ExpirationRule` violation.
    public static let maxHours = 24
    /// PIM's default maximum activation duration, and the app's default.
    public static let defaultHours = 8

    public static func isoDuration(hours: Int) -> String { "PT\(hours)H" }

    public static func body(
        for role: EligibleRole,
        principalId: String,
        justification: String,
        hours: Int,
        now: Date
    ) throws -> ActivationRequestBody {
        guard (1...maxHours).contains(hours) else { throw ActivationRequestError.invalidDuration(hours) }
        return try body(for: role, principalId: principalId, justification: justification, minutes: hours * 60, now: now)
    }

    public static func body(
        for role: EligibleRole,
        principalId: String,
        justification: String,
        minutes: Int,
        now: Date,
        start: Date? = nil
    ) throws -> ActivationRequestBody {
        let justification = justification.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !justification.isEmpty else { throw ActivationRequestError.missingJustification }
        guard (1...maxHours * 60).contains(minutes) else { throw ActivationRequestError.invalidMinutes(minutes) }
        guard !principalId.isEmpty else { throw ActivationRequestError.missingPrincipal }
        let (condition, conditionVersion) = copiedCondition(role.condition, role.conditionVersion)
        return ActivationRequestBody(properties: .init(
            // Always the user, also for group-inherited eligibilities.
            principalId: principalId,
            roleDefinitionId: role.roleDefinitionId,
            requestType: "SelfActivate",
            linkedRoleEligibilityScheduleId: role.eligibilityScheduleId,
            justification: justification,
            scheduleInfo: .init(
                // A later start schedules the activation (PIM: `Granted` until then).
                startDateTime: AzureDate.format(start ?? now),
                expiration: .init(type: "AfterDuration", duration: ISODuration.format(minutes: minutes))
            ),
            condition: condition,
            conditionVersion: conditionVersion
        ))
    }

    /// An ABAC condition must be sent back verbatim (with its version, `2.0`
    /// when none is given), otherwise the request fails validation.
    static func copiedCondition(_ condition: String?, _ version: String?) -> (String?, String?) {
        guard let condition, !condition.isEmpty else { return (nil, nil) }
        return (condition, version?.isEmpty == false ? version : "2.0")
    }

    /// The justification sent with a deactivation when none is given.
    public static let defaultDeactivationJustification = "Ended early with Pimento"

    /// `SelfDeactivate` for the activation of `role`. No schedule; the
    /// eligibility and any condition are those the activation was made with.
    public static func deactivationBody(
        for role: EligibleRole, principalId: String, justification: String = ""
    ) throws -> ActivationRequestBody {
        guard !principalId.isEmpty else { throw ActivationRequestError.missingPrincipal }
        guard role.isActive else { throw ActivationRequestError.notActive }
        let text = justification.trimmingCharacters(in: .whitespacesAndNewlines)
        let (condition, conditionVersion) = copiedCondition(role.condition, role.conditionVersion)
        return ActivationRequestBody(properties: .init(
            principalId: principalId,
            roleDefinitionId: role.roleDefinitionId,
            requestType: RequestAction.deactivate.requestType,
            linkedRoleEligibilityScheduleId: role.eligibilityScheduleId,
            justification: text.isEmpty ? defaultDeactivationJustification : text,
            scheduleInfo: nil,
            condition: condition,
            conditionVersion: conditionVersion
        ))
    }

    /// One `SelfDeactivate` per activation: rows that share a scope + role
    /// (eligible directly and through a group) are one activation.
    public static func deactivationPlan(
        _ roles: [EligibleRole],
        principalId: String,
        justification: String = "",
        now: Date = Date(),
        makeId: () -> UUID = UUID.init
    ) throws -> [PlannedRequest] {
        var seen = Set<RoleMatcher.Key>()
        return try roles.filter { seen.insert($0.policyKey).inserted }.map { role in
            PlannedRequest(
                role: role,
                url: url(for: role, requestId: makeId()),
                body: try deactivationBody(for: role, principalId: principalId, justification: justification),
                requestedAt: now,
                duration: EffectiveDuration(minutes: 0, requested: .hours(0), policyMaxMinutes: nil),
                action: .deactivate)
        }
    }

    /// `SelfExtend` for an admin-assigned time-bound assignment: asks for it
    /// to end `days` after its current end. An administrator of the resource has to
    /// approve it and sets the final dates.
    public static func extensionBody(
        for assignment: ActiveAssignment, principalId: String, justification: String, days: Int
    ) throws -> ActivationRequestBody {
        let text = justification.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw ActivationRequestError.missingJustification }
        guard !principalId.isEmpty else { throw ActivationRequestError.missingPrincipal }
        guard ExtendOptionsRange.days.contains(days) else { throw ActivationRequestError.invalidDays(days) }
        let (condition, conditionVersion) = copiedCondition(assignment.condition, assignment.conditionVersion)
        let start = assignment.start ?? assignment.end
        let end = assignment.end.addingTimeInterval(TimeInterval(days) * 86400)
        return ActivationRequestBody(properties: .init(
            principalId: principalId,
            roleDefinitionId: assignment.roleDefinitionId,
            requestType: RequestAction.extend.requestType,
            targetRoleAssignmentScheduleId: assignment.scheduleId,
            justification: text,
            scheduleInfo: .init(
                startDateTime: AzureDate.format(start),
                expiration: .init(type: "AfterDateTime", endDateTime: AzureDate.format(end))),
            condition: condition,
            conditionVersion: conditionVersion
        ))
    }

    /// One `SelfExtend` per assignment.
    public static func extensionPlan(
        _ assignments: [ActiveAssignment],
        principalId: String,
        justification: String,
        days: Int,
        now: Date = Date(),
        makeId: () -> UUID = UUID.init
    ) throws -> [PlannedRequest] {
        try assignments.map { a in
            PlannedRequest(
                role: a.asRole,
                url: url(scope: a.scope, requestId: makeId()),
                body: try extensionBody(for: a, principalId: principalId, justification: justification, days: days),
                requestedAt: now,
                duration: EffectiveDuration(minutes: days * 1440, requested: .hours(0), policyMaxMinutes: nil),
                action: .extend)
        }
    }

    public static func url(scope rawScope: String, requestId: UUID) -> URL {
        var scope = rawScope
        if !scope.hasPrefix("/") { scope = "/" + scope }
        while scope.count > 1, scope.hasSuffix("/") { scope.removeLast() }
        let path = "\(ARM.baseURL)\(scope)/providers/Microsoft.Authorization/roleAssignmentScheduleRequests/\(requestId.uuidString.lowercased())?api-version=\(ARM.apiVersion)"
        return URL(string: path)!
    }

    public static func url(for role: EligibleRole, requestId: UUID) -> URL {
        url(scope: role.scope, requestId: requestId)
    }

    /// The same number of hours for every role (no policy cap).
    public static func plan(
        _ roles: [EligibleRole],
        principalId: String,
        justification: String,
        hours: Int,
        now: Date = Date(),
        makeId: () -> UUID = UUID.init
    ) throws -> [PlannedRequest] {
        guard (1...maxHours).contains(hours) else { throw ActivationRequestError.invalidDuration(hours) }
        return try plan(roles, principalId: principalId, justification: justification, now: now, makeId: makeId) { _ in
            EffectiveDuration(minutes: hours * 60, requested: .hours(hours), policyMaxMinutes: nil)
        }
    }

    /// One request per role, each for `duration(role)`: the asked duration
    /// capped at that role's policy maximum (see `EffectiveDuration.resolve`).
    /// `start`: a later start schedules the activations; nil starts them now.
    public static func plan(
        _ roles: [EligibleRole],
        principalId: String,
        justification: String,
        now: Date = Date(),
        start: Date? = nil,
        makeId: () -> UUID = UUID.init,
        duration: (EligibleRole) -> EffectiveDuration
    ) throws -> [PlannedRequest] {
        try roles.map { role in
            let d = duration(role)
            return PlannedRequest(
                role: role,
                url: url(for: role, requestId: makeId()),
                body: try body(for: role, principalId: principalId, justification: justification, minutes: d.minutes,
                               now: now, start: start),
                requestedAt: now,
                duration: d,
                start: start
            )
        }
    }

    public static func encode(_ body: ActivationRequestBody) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(body)) ?? Data()
    }
}

public enum ExtendOptionsRange {
    /// How many days `pimento extend` may ask for.
    public static let days = 1...365
    public static let defaultDays = 30
}
