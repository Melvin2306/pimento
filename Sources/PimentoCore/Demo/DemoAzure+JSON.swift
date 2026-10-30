import Foundation

// The JSON the simulator answers with: the shapes ARM documents (and
// Pimento's fixtures record), with every field Pimento reads.

extension DemoAzure {
    /// `pairs` without the nil values.
    static func obj(_ pairs: KeyValuePairs<String, Any?>) -> [String: Any] {
        var result: [String: Any] = [:]
        for (key, value) in pairs {
            if let value { result[key] = value }
        }
        return result
    }

    static func encode(_ object: Any) -> Data {
        (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
    }

    static func ok(_ object: Any) -> (Data, Int) { (encode(object), 200) }
    static func created(_ object: Any) -> (Data, Int) { (encode(object), 201) }

    /// ARM's error envelope.
    static func error(_ status: Int, _ code: String, _ message: String) -> (Data, Int) {
        (encode(["error": ["code": code, "message": message]]), status)
    }

    /// The approvals endpoints' `{"Message": …}`.
    static func message(_ status: Int, _ text: String) -> (Data, Int) { (encode(["Message": text]), status) }

    static func oauthError(_ status: Int, _ error: String, _ description: String, code: Int) -> (Data, Int) {
        (encode(["error": error, "error_description": description, "error_codes": [code]]), status)
    }

    static var unauthenticated: (Data, Int) {
        error(401, "InvalidAuthenticationToken", "The access token is invalid.")
    }

    static func badApiVersion(_ version: String?) -> (Data, Int) {
        error(400, "InvalidApiVersionParameter", "The api-version '\(version ?? "")' is invalid for this resource type.")
    }

    static func unsupportedFilter(_ filter: String) -> (Data, Int) {
        error(400, "UnsupportedQuery", "The filter '\(filter)' is not supported at this scope.")
    }

    static func date(_ date: Date?) -> String? { date.map(AzureDate.format) }

    static func json(principal p: DemoPrincipal) -> [String: Any] {
        obj(["id": p.id, "displayName": p.displayName, "email": p.email, "type": p.type])
    }

    static func json(role: DemoRole, at scope: DemoScope) -> [String: Any] {
        ["id": role.definitionId(at: scope), "displayName": role.name, "type": "BuiltInRole"]
    }

    static func json(scope: DemoScope) -> [String: Any] {
        ["id": scope.path, "displayName": scope.displayName, "type": scope.type]
    }

    static func json(tenant t: DemoTenant) -> [String: Any] {
        obj([
            "id": "/tenants/\(t.id)", "tenantId": t.id, "tenantCategory": t.category, "countryCode": t.displayName == nil ? nil : "US",
            "displayName": t.displayName, "defaultDomain": t.defaultDomain, "domains": t.defaultDomain.map { [$0] }, "tenantType": "AAD",
        ])
    }

    static func json(eligibility e: DemoEligibility, user: DemoPrincipal) -> [String: Any] {
        let principal = e.group ?? user
        return [
            "id": e.instanceId,
            "name": RoleMatcher.lastPathComponent(e.instanceId),
            "type": "Microsoft.Authorization/roleEligibilityScheduleInstances",
            "properties": obj([
                "roleEligibilityScheduleId": e.scheduleId,
                "scope": e.scope.path,
                "roleDefinitionId": e.role.definitionId(at: e.scope),
                "principalId": principal.id,
                "principalType": principal.type,
                "status": "Provisioned",
                "memberType": e.group == nil ? "Direct" : "Group",
                "condition": e.condition,
                "conditionVersion": e.condition == nil ? nil : "2.0",
                "expandedProperties": [
                    "principal": json(principal: principal),
                    "roleDefinition": json(role: e.role, at: e.scope),
                    "scope": json(scope: e.scope),
                ] as [String: Any],
            ]),
        ]
    }

    static func json(assignment a: DemoAssignment, user: DemoPrincipal) -> [String: Any] {
        [
            "id": a.instanceId,
            "name": RoleMatcher.lastPathComponent(a.instanceId),
            "type": "Microsoft.Authorization/roleAssignmentScheduleInstances",
            "properties": obj([
                "scope": a.scope.path,
                "roleDefinitionId": a.role.definitionId(at: a.scope),
                "principalId": user.id,
                "principalType": "User",
                "roleAssignmentScheduleId": a.scheduleId,
                "status": "Provisioned",
                "assignmentType": a.kind.rawValue,
                "memberType": "Direct",
                "startDateTime": date(a.start),
                "endDateTime": date(a.end),
                "linkedRoleEligibilityScheduleId": a.linkedEligibilityScheduleId,
                "condition": a.condition,
                "conditionVersion": a.condition == nil ? nil : "2.0",
                "createdOn": date(a.start),
                "expandedProperties": [
                    "principal": json(principal: user),
                    "roleDefinition": json(role: a.role, at: a.scope),
                    "scope": json(scope: a.scope),
                ] as [String: Any],
            ]),
        ]
    }

    static func json(request r: DemoRequest) -> [String: Any] {
        let isDeactivation = r.requestType == RequestAction.deactivate.requestType
        let expiration: [String: Any] = r.end != nil
            ? obj(["type": "AfterDateTime", "endDateTime": date(r.end)])
            : obj(["type": "AfterDuration", "duration": r.minutes.map { ISODuration.format(minutes: $0) }])
        return [
            "id": r.id,
            "name": r.name,
            "type": "Microsoft.Authorization/RoleAssignmentScheduleRequests",
            "properties": obj([
                "scope": r.scope.path,
                "roleDefinitionId": r.role.definitionId(at: r.scope),
                "principalId": r.principal.id,
                "principalType": r.principal.type,
                "requestType": r.requestType,
                "status": r.status,
                "approvalId": r.approvalId.map { "/providers/Microsoft.Authorization/roleAssignmentApprovals/\($0)" },
                "scheduleInfo": isDeactivation ? nil : ["startDateTime": AzureDate.format(r.start), "expiration": expiration] as [String: Any],
                "justification": r.justification,
                "ticketInfo": r.ticket.map { obj(["ticketNumber": $0.ticketNumber, "ticketSystem": $0.ticketSystem]) },
                "requestorId": r.principal.id,
                "createdOn": date(r.createdOn),
                "linkedRoleEligibilityScheduleId": r.linkedEligibilityScheduleId,
                "targetRoleAssignmentScheduleId": r.targetScheduleId
                    ?? (isDeactivation ? nil : "\(r.scope.path)/providers/Microsoft.Authorization/roleAssignmentSchedules/\(r.name)"),
                "condition": r.condition,
                "conditionVersion": r.condition == nil ? nil : "2.0",
                "expandedProperties": [
                    "principal": json(principal: r.principal),
                    "roleDefinition": json(role: r.role, at: r.scope),
                    "scope": json(scope: r.scope),
                ] as [String: Any],
            ]),
        ]
    }

    static func json(stage a: DemoApproval, caller: String) -> [String: Any] {
        let reviewer = a.reviewedBy.map { p in
            ["principalId": p.id, "principalName": p.displayName, "principalType": "User", "userPrincipalName": p.email ?? ""]
        }
        return [
            "id": "/providers/Microsoft.Authorization/roleAssignmentApprovals/\(a.id)/stages/\(a.stageId)",
            "name": a.stageId,
            "type": "Microsoft.Authorization/roleAssignmentApprovals/stages",
            "properties": obj([
                "displayName": "Approval stage 1",
                "status": a.status,
                "assignedToMe": a.approvers.contains { $0.id == caller },
                "reviewResult": a.reviewResult,
                "justification": a.justification,
                "reviewedBy": reviewer,
                "reviewedDateTime": date(a.reviewedAt),
            ]),
        ]
    }

    static func json(approval a: DemoApproval, caller: String) -> [String: Any] {
        [
            "id": "/providers/Microsoft.Authorization/roleAssignmentApprovals/\(a.id)",
            "name": a.id,
            "type": "Microsoft.Authorization/roleAssignmentApprovals",
            "properties": ["stages": [json(stage: a, caller: caller)]],
        ]
    }

    /// A `roleManagementPolicyAssignments` item with the end-user rules of the eligibility's policy.
    static func json(policyOf e: DemoEligibility) -> [String: Any] {
        let p = e.policy
        func rule(_ id: String, _ type: String, _ caller: String, _ extra: [String: Any]) -> [String: Any] {
            ["id": id, "ruleType": "RoleManagementPolicy\(type)Rule", "target": ["caller": caller, "level": "Assignment"]]
                .merging(extra) { a, _ in a }
        }
        var enabled: [String] = []
        if p.mfa { enabled.append("MultiFactorAuthentication") }
        if p.justification { enabled.append("Justification") }
        if p.ticket { enabled.append("Ticketing") }
        let policyId = "\(e.scope.path)/providers/Microsoft.Authorization/roleManagementPolicies/\(DemoID.uuid("policy-\(e.key)"))"
        let megan: [String: Any] = ["id": DemoDirectory.megan.id, "description": DemoDirectory.megan.displayName, "userType": "User"]
        let stages: [Any] = p.approval ? [["approvalStageTimeOutInDays": 1, "primaryApprovers": [megan]] as [String: Any]] : []
        let approval: [String: Any] = ["isApprovalRequired": p.approval, "approvalMode": "SingleStage", "approvalStages": stages]
        let rules: [[String: Any]] = [
            rule("Expiration_Admin_Assignment", "Expiration", "Admin", ["isExpirationRequired": false, "maximumDuration": "P180D"]),
            rule("Expiration_EndUser_Assignment", "Expiration", "EndUser",
                 ["isExpirationRequired": true, "maximumDuration": ISODuration.format(minutes: p.maxMinutes)]),
            rule("Enablement_EndUser_Assignment", "Enablement", "EndUser", ["enabledRules": enabled]),
            rule("Approval_EndUser_Assignment", "Approval", "EndUser", ["setting": approval]),
            rule("AuthenticationContext_EndUser_Assignment", "AuthenticationContext", "EndUser", ["isEnabled": false]),
        ]
        let properties: [String: Any] = [
            "scope": e.scope.path, "roleDefinitionId": e.role.definitionId(at: e.scope), "policyId": policyId, "effectiveRules": rules,
        ]
        return [
            "id": "\(e.scope.path)/providers/Microsoft.Authorization/roleManagementPolicyAssignments/\(DemoID.uuid("policy-\(e.key)"))_\(e.role.guid)",
            "type": "Microsoft.Authorization/RoleManagementPolicyAssignment",
            "properties": properties,
        ]
    }
}
