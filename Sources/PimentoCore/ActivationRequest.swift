import Foundation

/// Body of `PUT {scope}/providers/Microsoft.Authorization/roleAssignmentScheduleRequests/{guid}`.
public struct ActivationRequestBody: Encodable, Equatable, Sendable {
    public struct Expiration: Encodable, Equatable, Sendable {
        public let type: String
        public let duration: String
    }

    public struct ScheduleInfo: Encodable, Equatable, Sendable {
        public let startDateTime: String
        public let expiration: Expiration
    }

    public struct Properties: Encodable, Equatable, Sendable {
        public let principalId: String
        public let roleDefinitionId: String
        public let requestType: String
        public let linkedRoleEligibilityScheduleId: String
        public let justification: String
        public let scheduleInfo: ScheduleInfo
        /// Omitted from the JSON when nil (synthesized `encodeIfPresent`).
        public let condition: String?
        public let conditionVersion: String?
    }

    public let properties: Properties
}

public enum ActivationRequestError: Error, Equatable, LocalizedError {
    case missingJustification
    case invalidDuration(Int)
    case missingPrincipal

    public var errorDescription: String? {
        switch self {
        case .missingJustification: "A justification is required."
        case .invalidDuration(let h): "Duration must be 1–\(ActivationRequestBuilder.maxHours) hours (got \(h))."
        case .missingPrincipal: "Could not determine your user object id from the token."
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
    public let hours: Int

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
        let justification = justification.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !justification.isEmpty else { throw ActivationRequestError.missingJustification }
        guard (1...maxHours).contains(hours) else { throw ActivationRequestError.invalidDuration(hours) }
        guard !principalId.isEmpty else { throw ActivationRequestError.missingPrincipal }
        // An eligibility with an ABAC condition must have it sent back
        // verbatim, otherwise the request fails policy validation.
        let condition = role.hasCondition ? role.condition : nil
        return ActivationRequestBody(properties: .init(
            // Always the user, also for group-inherited eligibilities.
            principalId: principalId,
            roleDefinitionId: role.roleDefinitionId,
            requestType: "SelfActivate",
            linkedRoleEligibilityScheduleId: role.eligibilityScheduleId,
            justification: justification,
            scheduleInfo: .init(
                startDateTime: AzureDate.format(now),
                expiration: .init(type: "AfterDuration", duration: isoDuration(hours: hours))
            ),
            condition: condition,
            conditionVersion: condition == nil ? nil : (role.conditionVersion?.isEmpty == false ? role.conditionVersion : "2.0")
        ))
    }

    public static func url(for role: EligibleRole, requestId: UUID) -> URL {
        var scope = role.scope
        if !scope.hasPrefix("/") { scope = "/" + scope }
        while scope.count > 1, scope.hasSuffix("/") { scope.removeLast() }
        let path = "\(ARM.baseURL)\(scope)/providers/Microsoft.Authorization/roleAssignmentScheduleRequests/\(requestId.uuidString.lowercased())?api-version=\(ARM.apiVersion)"
        return URL(string: path)!
    }

    public static func plan(
        _ roles: [EligibleRole],
        principalId: String,
        justification: String,
        hours: Int,
        now: Date = Date(),
        makeId: () -> UUID = UUID.init
    ) throws -> [PlannedRequest] {
        try roles.map { role in
            PlannedRequest(
                role: role,
                url: url(for: role, requestId: makeId()),
                body: try body(for: role, principalId: principalId, justification: justification, hours: hours, now: now),
                requestedAt: now,
                hours: hours
            )
        }
    }

    public static func encode(_ body: ActivationRequestBody) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(body)) ?? Data()
    }
}
