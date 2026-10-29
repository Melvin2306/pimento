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

/// ARM error envelope: `{"error": {"code": "...", "message": "..."}}`.
public struct ARMErrorEnvelope: Decodable, Sendable {
    public struct Body: Decodable, Sendable {
        public let code: String?
        public let message: String?
    }

    public let error: Body?
}
