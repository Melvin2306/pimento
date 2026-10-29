import Foundation
import Testing
@testable import PimentoCore

@Suite("Eligibility ↔ active matching")
struct RoleMatcherTests {
    @Test func buildsOneRowPerEligibilitySortedByResourceThenRole() throws {
        let rows = try Fixture.rows()
        #expect(rows.map { "\($0.scopeName)/\($0.roleName)" } == [
            "Contoso Production/Owner",
            "Contoso Production/Reader",
            "Contoso Staging/Contributor",
            "rg-app-dev/Owner",
        ])
    }

    @Test func activatedInstanceMatchesDespiteScopeCaseAndTrailingSlash() throws {
        let owner = try Fixture.role("Contoso Production", "Owner")
        #expect(owner.isActive)
        #expect(owner.activeUntil == AzureDate.parse("2026-10-29T18:42:17.913Z"))
    }

    @Test func permanentAssignedInstanceDoesNotCountAsActivated() throws {
        let reader = try Fixture.role("Contoso Production", "Reader")
        #expect(!reader.isActive)
        #expect(reader.activeUntil == nil)
    }

    @Test func expiredActivationIsNotActive() throws {
        let contributor = try Fixture.role("Contoso Staging", "Contributor")
        #expect(!contributor.isActive)
    }

    @Test func roleIsMatchedByGUIDAndLatestExpiryWins() throws {
        // The later activation's roleDefinitionId is read through another subscription.
        let rgOwner = try Fixture.role("rg-app-dev", "Owner")
        #expect(rgOwner.isActive)
        #expect(rgOwner.activeUntil == AzureDate.parse("2026-10-29T20:00:00.500Z"))
    }

    @Test func membershipConditionAndScopeTypeAreMapped() throws {
        let contributor = try Fixture.role("Contoso Staging", "Contributor")
        #expect(contributor.membership == .group("Platform Engineers"))
        #expect(contributor.membership.label == "Group: Platform Engineers")
        #expect(!contributor.hasCondition)
        #expect(contributor.scopeTypeLabel == "Subscription")

        let owner = try Fixture.role("Contoso Production", "Owner")
        #expect(owner.membership == .direct)
        #expect(owner.hasCondition)
        #expect(owner.conditionVersion == "2.0")
        #expect(owner.isOwner)
        #expect(owner.eligibilityScheduleId.hasSuffix("/roleEligibilitySchedules/sched-1"))

        #expect(try Fixture.role("rg-app-dev", "Owner").scopeTypeLabel == "Resource group")
        #expect(try !Fixture.role("Contoso Production", "Reader").isOwner)
    }

    @Test func keyNormalisesScopeAndRoleDefinition() {
        let a = RoleMatcher.key(scope: "/subscriptions/ABC/", roleDefinitionId: "/subscriptions/X/providers/Microsoft.Authorization/roleDefinitions/8E3AF657-A8FF-443C-A75C-2FE8C4BCB635")
        let b = RoleMatcher.key(scope: "/subscriptions/abc", roleDefinitionId: "/providers/Microsoft.Authorization/roleDefinitions/8e3af657-a8ff-443c-a75c-2fe8c4bcb635")
        #expect(a == b)
    }

    @Test func missingExpandedPropertiesFallBackToIds() throws {
        let json = """
        {"value":[{"id":"/subscriptions/s1/providers/Microsoft.Authorization/roleEligibilityScheduleInstances/i1",
          "properties":{"roleEligibilityScheduleId":"/subscriptions/s1/providers/Microsoft.Authorization/roleEligibilitySchedules/e1",
          "scope":"/subscriptions/s1/resourceGroups/rg1","roleDefinitionId":"/providers/Microsoft.Authorization/roleDefinitions/guid-1"}}]}
        """
        let list = try JSONDecoder().decode(ARMList<EligibilityScheduleInstance>.self, from: Data(json.utf8))
        let row = try #require(RoleMatcher.rows(eligibilities: list.value, assignments: []).first)
        #expect(row.roleName == "guid-1")
        #expect(row.scopeName == "rg1")
        #expect(row.scopeType == "resourcegroup")
        #expect(row.membership == .direct)
        #expect(!row.isActive)
    }

    @Test func duplicateInstancesAreCollapsed() throws {
        let e = try Fixture.eligibilities()
        let rows = RoleMatcher.rows(eligibilities: e + e, assignments: [], now: Fixture.now)
        #expect(rows.count == e.count)
    }
}

@Suite("Date parsing")
struct AzureDateTests {
    @Test(arguments: [
        ("2026-10-29T21:21:12.603Z", 1_793_308_872.603),
        ("2026-10-29T09:42:19.66Z", 1_793_266_939.66),
        ("2026-10-29T18:42:17.9130000Z", 1_793_299_337.913),
        ("2026-10-29T12:00:00Z", 1_793_275_200.0),
        ("2026-10-29T14:00:00+02:00", 1_793_275_200.0),
    ])
    func parsesARMDateShapes(input: String, epoch: Double) throws {
        let date = try #require(AzureDate.parse(input))
        #expect(abs(date.timeIntervalSince1970 - epoch) < 0.001)
    }

    @Test func rejectsEmptyAndGarbage() {
        #expect(AzureDate.parse(nil) == nil)
        #expect(AzureDate.parse("") == nil)
        #expect(AzureDate.parse("not a date") == nil)
    }

    @Test func formatsUTCWithMilliseconds() {
        #expect(AzureDate.format(Date(timeIntervalSince1970: 1_793_275_200.25)) == "2026-10-29T12:00:00.250Z")
    }
}
