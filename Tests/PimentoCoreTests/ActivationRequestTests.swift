import Foundation
import Testing
@testable import PimentoCore

@Suite("Activation request construction")
struct ActivationRequestTests {
    func json(_ body: ActivationRequestBody) throws -> [String: Any] {
        let object = try JSONSerialization.jsonObject(with: ActivationRequestBuilder.encode(body)) as? [String: Any]
        return try #require(object?["properties"] as? [String: Any])
    }

    @Test func conditionIsCopiedVerbatimWithVersion() throws {
        let owner = try Fixture.role("Contoso Production", "Owner")
        let body = try ActivationRequestBuilder.body(
            for: owner, principalId: Fixture.userOID, justification: "INC-1 debug", hours: 8, now: Fixture.now)
        let p = try json(body)
        #expect(p["condition"] as? String == owner.condition)
        #expect((p["condition"] as? String)?.contains("ActionMatches{'Microsoft.Authorization/roleAssignments/write'}") == true)
        #expect(p["conditionVersion"] as? String == "2.0")
    }

    @Test func noConditionMeansNoConditionKeys() throws {
        let reader = try Fixture.role("Contoso Production", "Reader")
        let body = try ActivationRequestBuilder.body(
            for: reader, principalId: Fixture.userOID, justification: "x", hours: 1, now: Fixture.now)
        let p = try json(body)
        #expect(p["condition"] == nil)
        #expect(p["conditionVersion"] == nil)
    }

    @Test func conditionVersionDefaultsTo2WhenMissing() throws {
        let base = try Fixture.role("Contoso Production", "Owner")
        let role = EligibleRole(
            id: base.id, eligibilityScheduleId: base.eligibilityScheduleId, roleDefinitionId: base.roleDefinitionId,
            roleName: base.roleName, scope: base.scope, scopeName: base.scopeName, scopeType: base.scopeType,
            membership: base.membership, condition: "@Resource[x] StringEquals 'y'", conditionVersion: nil)
        let body = try ActivationRequestBuilder.body(for: role, principalId: "me", justification: "x", hours: 8, now: Fixture.now)
        #expect(body.properties.conditionVersion == "2.0")
    }

    @Test func coreFieldsMatchTheReferenceScript() throws {
        // Group-inherited eligibility: principalId must still be the user, not the group.
        let contributor = try Fixture.role("Contoso Staging", "Contributor")
        let body = try ActivationRequestBuilder.body(
            for: contributor, principalId: Fixture.userOID, justification: "  on-call  \n", hours: 3, now: Fixture.now)
        let p = try json(body)
        #expect(p["principalId"] as? String == Fixture.userOID)
        #expect(p["requestType"] as? String == "SelfActivate")
        #expect(p["roleDefinitionId"] as? String == contributor.roleDefinitionId)
        #expect(p["linkedRoleEligibilityScheduleId"] as? String == contributor.eligibilityScheduleId)
        #expect(p["justification"] as? String == "on-call")
        let schedule = try #require(p["scheduleInfo"] as? [String: Any])
        #expect(schedule["startDateTime"] as? String == "2026-10-29T12:00:00.000Z")
        let expiration = try #require(schedule["expiration"] as? [String: Any])
        #expect(expiration["type"] as? String == "AfterDuration")
        #expect(expiration["duration"] as? String == "PT3H")
        #expect(Set(p.keys) == ["principalId", "roleDefinitionId", "requestType", "linkedRoleEligibilityScheduleId",
                                "justification", "scheduleInfo"])
    }

    @Test(arguments: [0, 25, -1])
    func rejectsDurationsOutsidePolicy(hours: Int) throws {
        let role = try Fixture.role("Contoso Production", "Reader")
        #expect(throws: ActivationRequestError.invalidDuration(hours)) {
            try ActivationRequestBuilder.body(for: role, principalId: "me", justification: "x", hours: hours, now: Fixture.now)
        }
    }

    @Test(arguments: 1...24)
    func acceptsOneToTwentyFourHours(hours: Int) throws {
        let role = try Fixture.role("Contoso Production", "Reader")
        let body = try ActivationRequestBuilder.body(for: role, principalId: "me", justification: "x", hours: hours, now: Fixture.now)
        #expect(body.duration == "PT\(hours)H")
    }

    @Test func rejectsBlankJustificationAndMissingPrincipal() throws {
        let role = try Fixture.role("Contoso Production", "Reader")
        #expect(throws: ActivationRequestError.missingJustification) {
            try ActivationRequestBuilder.body(for: role, principalId: "me", justification: " \n\t", hours: 8, now: Fixture.now)
        }
        #expect(throws: ActivationRequestError.missingPrincipal) {
            try ActivationRequestBuilder.body(for: role, principalId: "", justification: "x", hours: 8, now: Fixture.now)
        }
    }

    @Test func urlTargetsTheEligibilityScopeWithANewGUID() throws {
        let rgOwner = try Fixture.role("rg-app-dev", "Owner")
        let id = UUID(uuidString: "0F1E2D3C-4B5A-6978-8796-A5B4C3D2E1F0")!
        let url = ActivationRequestBuilder.url(for: rgOwner, requestId: id)
        #expect(url.absoluteString ==
            "https://management.azure.com/subscriptions/cccccccc-0000-0000-0000-00000000000c/resourceGroups/rg-app-dev"
            + "/providers/Microsoft.Authorization/roleAssignmentScheduleRequests/0f1e2d3c-4b5a-6978-8796-a5b4c3d2e1f0?api-version=2020-10-01")
    }

    @Test func planUsesOneFreshRequestIdPerRole() throws {
        let rows = try Fixture.rows()
        let plans = try ActivationRequestBuilder.plan(rows, principalId: "me", justification: "x", hours: 8, now: Fixture.now)
        #expect(plans.count == rows.count)
        #expect(Set(plans.map(\.url)).count == rows.count)
        #expect(plans.allSatisfy { $0.prettyBody.contains("\"requestType\" : \"SelfActivate\"") })
    }
}
