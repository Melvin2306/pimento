import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// What a role's PIM policy demands when you activate it yourself (the
/// `EndUser` / `Assignment` rules of its role-management policy).
public struct RolePolicy: Equatable, Sendable {
    /// Longest activation the policy allows, in seconds; nil when it sets none.
    public var maximumDuration: TimeInterval?
    public var requiresJustification = false
    public var requiresTicket = false
    public var requiresMFA = false
    public var requiresApproval = false
    /// Conditional Access authentication context the activation needs, if any.
    public var authenticationContext: String?
    public var policyId: String?

    public init(
        maximumDuration: TimeInterval? = nil, requiresJustification: Bool = false, requiresTicket: Bool = false,
        requiresMFA: Bool = false, requiresApproval: Bool = false, authenticationContext: String? = nil, policyId: String? = nil
    ) {
        self.maximumDuration = maximumDuration
        self.requiresJustification = requiresJustification
        self.requiresTicket = requiresTicket
        self.requiresMFA = requiresMFA
        self.requiresApproval = requiresApproval
        self.authenticationContext = authenticationContext
        self.policyId = policyId
    }

    /// The maximum in whole minutes (rounded down, at least 1).
    public var maxMinutes: Int? {
        guard let s = maximumDuration, s > 0 else { return nil }
        return max(1, Int(s / 60))
    }

    public var maxDurationISO: String? { maxMinutes.map { ISODuration.format(minutes: $0) } }
}

/// A policy lookup for one scope + role.
public enum PolicyLookup: Equatable, Sendable {
    case loaded(RolePolicy)
    /// ARM returned no policy assignment for the role at that scope.
    case notFound
    case failed(String)

    public var policy: RolePolicy? {
        if case .loaded(let p) = self { return p }
        return nil
    }

    public var maxMinutes: Int? { policy?.maxMinutes }
}

/// Reads `roleManagementPolicyAssignments` responses.
public enum RolePolicyParser {
    /// One effective rule; only the fields Pimento reads.
    struct Rule: Decodable {
        struct Target: Decodable {
            let caller: String?
            let level: String?
        }

        struct Setting: Decodable {
            let isApprovalRequired: Bool?
        }

        let id: String?
        let ruleType: String?
        let target: Target?
        let maximumDuration: String?
        let isExpirationRequired: Bool?
        let enabledRules: [String]?
        let setting: Setting?
        let isEnabled: Bool?
        let claimValue: String?
    }

    struct Assignment: Decodable {
        struct Properties: Decodable {
            let roleDefinitionId: String?
            let policyId: String?
            let effectiveRules: [Rule]?
        }

        let properties: Properties?
    }

    /// The policy in an ARM list response, preferring the assignment for
    /// `roleDefinitionId` (by role GUID). nil when the list is empty.
    public static func parse(_ data: Data, roleDefinitionId: String? = nil) throws -> RolePolicy? {
        let list = try JSONDecoder().decode(ARMList<Assignment>.self, from: data)
        let wanted = roleDefinitionId.map { RoleMatcher.key(scope: "", roleDefinitionId: $0).role }
        let match = list.value.first { a in
            guard let wanted, let id = a.properties?.roleDefinitionId else { return false }
            return RoleMatcher.key(scope: "", roleDefinitionId: id).role == wanted
        } ?? list.value.first
        guard let props = match?.properties else { return nil }
        var policy = policy(from: props.effectiveRules ?? [])
        policy.policyId = props.policyId
        return policy
    }

    static func isEndUserAssignment(_ rule: Rule, _ kind: String) -> Bool {
        if let id = rule.id, id.caseInsensitiveCompare("\(kind)_EndUser_Assignment") == .orderedSame { return true }
        guard rule.ruleType?.caseInsensitiveCompare("RoleManagementPolicy\(kind)Rule") == .orderedSame,
              rule.target?.caller?.caseInsensitiveCompare("EndUser") == .orderedSame,
              rule.target?.level?.caseInsensitiveCompare("Assignment") == .orderedSame else { return false }
        return true
    }

    static func policy(from rules: [Rule]) -> RolePolicy {
        var p = RolePolicy()
        for rule in rules {
            if isEndUserAssignment(rule, "Expiration") {
                p.maximumDuration = ISODuration.parse(rule.maximumDuration)
            } else if isEndUserAssignment(rule, "Enablement") {
                let enabled = Set((rule.enabledRules ?? []).map { $0.lowercased() })
                p.requiresJustification = enabled.contains("justification")
                p.requiresTicket = enabled.contains("ticketing")
                p.requiresMFA = enabled.contains("multifactorauthentication")
            } else if isEndUserAssignment(rule, "Approval") {
                p.requiresApproval = rule.setting?.isApprovalRequired ?? false
            } else if isEndUserAssignment(rule, "AuthenticationContext") {
                p.authenticationContext = rule.isEnabled == true ? (rule.claimValue ?? "") : nil
            }
        }
        return p
    }
}

extension ARM {
    /// `GET {scope}/providers/Microsoft.Authorization/roleManagementPolicyAssignments?$filter=roleDefinitionId eq '…'`
    /// The policy assignments of `scope` for one role. The scope is a path as
    /// `ARMScope.path` makes it (ASCII allowlist), the filter is encoded with
    /// the same ASCII allowlist; nil for a scope that cannot be a path.
    public static func policyAssignmentsURL(scope: String, roleDefinitionId: String) -> URL? {
        var allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        allowed.insert(charactersIn: "-._~/")
        guard let path = ARMScope.path(scope),
              let filter = "roleDefinitionId eq '\(roleDefinitionId)'".addingPercentEncoding(withAllowedCharacters: allowed)
        else { return nil }
        return URL(string: "\(baseURL)\(path)/providers/Microsoft.Authorization/roleManagementPolicyAssignments?api-version=\(apiVersion)&$filter=\(filter)")
    }
}

extension PIMService {
    /// The policy of every distinct scope + role in `roles`, at most
    /// `maxConcurrent` GETs at a time. A failed lookup is reported as
    /// `.failed`, never thrown; only a missing token throws. Read-only.
    public func loadPolicies(
        for roles: [EligibleRole],
        maxConcurrent: Int = 6,
        onResult: @escaping @Sendable (RoleMatcher.Key, PolicyLookup) async -> Void = { _, _ in }
    ) async throws -> [RoleMatcher.Key: PolicyLookup] {
        var unique: [RoleMatcher.Key: EligibleRole] = [:]
        for role in roles where unique[role.policyKey] == nil { unique[role.policyKey] = role }
        guard !unique.isEmpty else { return [:] }
        let token = try await tokens.accessToken()
        var results: [RoleMatcher.Key: PolicyLookup] = [:]
        await withTaskGroup(of: (RoleMatcher.Key, PolicyLookup).self) { group in
            var pending = unique.sorted { ($0.key.scope, $0.key.role) < ($1.key.scope, $1.key.role) }.makeIterator()
            func enqueue(_ item: (key: RoleMatcher.Key, value: EligibleRole)) {
                group.addTask { (item.key, await self.loadPolicy(for: item.value, token: token)) }
            }
            for _ in 0..<max(1, maxConcurrent) {
                guard let next = pending.next() else { break }
                enqueue(next)
            }
            while let (key, lookup) = await group.next() {
                results[key] = lookup
                await onResult(key, lookup)
                if let next = pending.next() { enqueue(next) }
            }
        }
        return results
    }

    func loadPolicy(for role: EligibleRole, token: String) async -> PolicyLookup {
        guard let url = ARM.policyAssignmentsURL(scope: role.scope, roleDefinitionId: role.roleDefinitionId) else {
            return .failed(ActivationRequestError.invalidScope(role.scope).localizedDescription)
        }
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        do {
            let (data, status) = try await transport.send(request)
            guard status == 200 else {
                let env = try? JSONDecoder().decode(ARMErrorEnvelope.self, from: data)
                return .failed([env?.error?.code, env?.error?.message].compactMap { $0 }.joined(separator: ": ").nonEmpty ?? "HTTP \(status)")
            }
            guard let policy = try RolePolicyParser.parse(data, roleDefinitionId: role.roleDefinitionId) else { return .notFound }
            return .loaded(policy)
        } catch {
            return .failed(error.localizedDescription)
        }
    }
}

extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
