import Foundation

/// ARM API constants for Azure-resource PIM.
public enum ARM {
    public static let baseURL = "https://management.azure.com"
    public static let resource = "https://management.azure.com/"
    public static let host = "management.azure.com"
    public static let apiVersion = "2020-10-01"
    /// Tenant-level listing with `asTarget()` returns every eligibility of the
    /// caller, including the ones inherited through group membership.
    public static var eligibilityInstancesURL: URL {
        URL(string: "\(baseURL)/providers/Microsoft.Authorization/roleEligibilityScheduleInstances?api-version=\(apiVersion)&$filter=asTarget()")!
    }

    public static var assignmentInstancesURL: URL {
        URL(string: "\(baseURL)/providers/Microsoft.Authorization/roleAssignmentScheduleInstances?api-version=\(apiVersion)&$filter=asTarget()")!
    }

    /// A list response's `nextLink`, only when it points back to ARM over
    /// HTTPS: the bearer token is never sent anywhere else, nor in the clear.
    /// The host must be spelled out (not percent-encoded) and the link may
    /// carry no user name or password.
    public static func followableNextLink(_ link: String?) -> URL? {
        guard let url = link.flatMap(URL.init(string:)), url.scheme?.lowercased() == "https",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.percentEncodedHost?.lowercased() == host, url.host?.lowercased() == host,
              components.percentEncodedUser == nil, components.percentEncodedPassword == nil,
              url.port == nil || url.port == 443 else { return nil }
        return url
    }

    /// The most pages and items one listing may take before it is stopped
    /// with an error (`PIMServiceError.listingTooLong`) instead of being cut
    /// short without a word or running forever.
    public static let maxPages = 100
    public static let maxItems = 20_000
}

/// One page of an ARM list response.
public struct ARMList<Item: Decodable>: Decodable {
    public let value: [Item]
    public let nextLink: String?
}

public struct ExpandedProperties: Decodable, Sendable, Hashable {
    public struct Entity: Decodable, Sendable, Hashable {
        public let id: String?
        public let displayName: String?
        public let type: String?
        /// The principal's e-mail (requests list it for the requester).
        public let email: String?
    }

    public let principal: Entity?
    public let roleDefinition: Entity?
    public let scope: Entity?
}

/// `roleEligibilityScheduleInstances` item (only the fields we use).
public struct EligibilityScheduleInstance: Decodable, Sendable {
    public struct Properties: Decodable, Sendable {
        public let roleEligibilityScheduleId: String
        public let scope: String
        public let roleDefinitionId: String
        public let principalId: String?
        public let memberType: String?
        public let condition: String?
        public let conditionVersion: String?
        public let endDateTime: String?
        public let expandedProperties: ExpandedProperties?
    }

    public let id: String
    public let properties: Properties
}

/// `roleAssignmentScheduleInstances` item (only the fields we use).
public struct AssignmentScheduleInstance: Decodable, Sendable {
    public struct Properties: Decodable, Sendable {
        public let scope: String
        public let roleDefinitionId: String
        /// `Activated` (a PIM activation) or `Assigned` (an admin assignment).
        public let assignmentType: String?
        public let memberType: String?
        public let startDateTime: String?
        public let endDateTime: String?
        public let linkedRoleEligibilityScheduleId: String?
        /// The schedule behind this instance: `targetRoleAssignmentScheduleId`
        /// of an extension request.
        public let roleAssignmentScheduleId: String?
        public let principalId: String?
        public let condition: String?
        public let conditionVersion: String?
        public let expandedProperties: ExpandedProperties?
    }

    public let id: String?
    public let properties: Properties
}

/// ARM error envelope: `{"error": {"code": "...", "message": "..."}}`. The
/// approvals endpoints (`roleAssignmentApprovals`) answer `{"Message": "..."}`
/// instead; that ends up in `topLevelMessage`.
public struct ARMErrorEnvelope: Decodable, Sendable {
    public struct Body: Decodable, Sendable {
        public let code: String?
        public let message: String?
    }

    public let error: Body?
    public let topLevelMessage: String?

    enum CodingKeys: String, CodingKey {
        case error, upperMessage = "Message", message
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        error = try? c.decodeIfPresent(Body.self, forKey: .error)
        topLevelMessage = (try? c.decodeIfPresent(String.self, forKey: .upperMessage))
            ?? (try? c.decodeIfPresent(String.self, forKey: .message))
    }

    /// `code: message` of an error answer, or nil when `data` holds neither.
    public static func describe(_ data: Data) -> String? {
        guard let env = try? JSONDecoder().decode(ARMErrorEnvelope.self, from: data) else { return nil }
        let parts = [env.error?.code, env.error?.message ?? env.topLevelMessage].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: ": ")
    }
}
