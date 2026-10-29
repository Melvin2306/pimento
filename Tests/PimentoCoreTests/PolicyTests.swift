import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import PimentoCore

@Suite("ISO 8601 durations")
struct ISODurationTests {
    @Test(arguments: [
        ("PT8H", 8.0 * 3600), ("PT30M", 1800), ("P1D", 86400), ("PT1H30M", 5400),
        ("P365D", 365.0 * 86400), ("PT0.5H", 1800), ("pt2h", 7200), ("P1DT2H", 93600), ("PT45S", 45), ("P1W", 604_800),
    ])
    func parses(text: String, seconds: Double) {
        #expect(ISODuration.parse(text) == seconds)
    }

    @Test(arguments: ["", "8H", "P", "PT", "PTH", "P8H", "PT8X", "PT8", "8", "PT1H30", "P1DT", "TP1H"])
    func rejectsMalformed(text: String) {
        #expect(ISODuration.parse(text) == nil)
    }

    @Test func formatsMinutes() {
        #expect(ISODuration.format(minutes: 480) == "PT8H")
        #expect(ISODuration.format(minutes: 30) == "PT30M")
        #expect(ISODuration.format(minutes: 90) == "PT1H30M")
        #expect(ISODuration.format(minutes: 1440) == "PT24H")
        #expect(DurationText.short(minutes: 480) == "8 h")
        #expect(DurationText.short(minutes: 30) == "30 min")
        #expect(DurationText.short(minutes: 90) == "1 h 30 min")
    }

    @Test func requestedDurationSpellings() {
        #expect(RequestedDuration(argument: "max") == .maximum)
        #expect(RequestedDuration(argument: "MAXIMUM") == .maximum)
        #expect(RequestedDuration(argument: "4") == .hours(4))
        #expect(RequestedDuration(argument: "0") == nil)
        #expect(RequestedDuration(argument: "25") == nil)
        #expect(RequestedDuration(argument: "4h") == nil)
        #expect(RequestedDuration.maximum.stringValue == "max")
        #expect(RequestedDuration.hours(4).stringValue == "PT4H")
        #expect(RequestedDuration(stringValue: "PT4H") == .hours(4))
        #expect(RequestedDuration(stringValue: "max") == .maximum)
        // Only whole hours within 1-24 are stored durations.
        #expect(RequestedDuration(stringValue: "PT90M") == nil)
        #expect(RequestedDuration(stringValue: "P2D") == nil)
        #expect(RequestedDuration(stringValue: "soon") == nil)
    }
}

@Suite("Policy maximum")
struct EffectiveDurationTests {
    @Test func askedDurationWithinTheMaximumIsKept() {
        let d = EffectiveDuration.resolve(.hours(8), policyMaxMinutes: 480, fallbackHours: 8)
        #expect(d.minutes == 480)
        #expect(!d.isClamped && d.note == nil)
        #expect(d.label == "8 h (max 8 h)")
        #expect(d.iso == "PT8H")
    }

    @Test func askedDurationAboveTheMaximumIsCapped() {
        let d = EffectiveDuration.resolve(.hours(12), policyMaxMinutes: 240, fallbackHours: 8)
        #expect(d.minutes == 240)
        #expect(d.isClamped)
        #expect(d.label == "4 h (max 4 h)")
        #expect(d.note == "capped at the role's maximum of 4 h (asked 12 h)")
    }

    @Test func maximumTakesThePolicyValue() {
        let d = EffectiveDuration.resolve(.maximum, policyMaxMinutes: 90, fallbackHours: 8)
        #expect(d.minutes == 90)
        #expect(d.iso == "PT1H30M")
        #expect(!d.isClamped && !d.isFallback)
    }

    @Test func unknownPolicyFallsBack() {
        let max = EffectiveDuration.resolve(.maximum, policyMaxMinutes: nil, fallbackHours: 8)
        #expect(max.minutes == 480)
        #expect(max.isFallback)
        #expect(max.note == "maximum unknown, using 8 h")
        #expect(max.label == "8 h")
        let asked = EffectiveDuration.resolve(.hours(3), policyMaxMinutes: nil, fallbackHours: 8)
        #expect(asked.minutes == 180)
        #expect(!asked.isClamped && asked.note == nil)
    }

    @Test func neverMoreThanADay() {
        #expect(EffectiveDuration.resolve(.maximum, policyMaxMinutes: 3 * 1440, fallbackHours: 8).minutes == 1440)
        #expect(EffectiveDuration.resolve(.hours(24), policyMaxMinutes: 0, fallbackHours: 8).minutes == 1440)
    }

    @Test func plansCarryPerRoleDurations() throws {
        let rows = try Fixture.rows().filter { !$0.isActive }
        let plans = try ActivationRequestBuilder.plan(rows, principalId: "me", justification: "x", now: Fixture.now) { role in
            EffectiveDuration.resolve(.hours(8), policyMaxMinutes: role.roleName == "Reader" ? 90 : nil, fallbackHours: 8)
        }
        let byName = Dictionary(uniqueKeysWithValues: plans.map { ($0.role.roleName, $0) })
        #expect(byName["Reader"]?.body.duration == "PT1H30M")
        #expect(byName["Reader"]?.duration.isClamped == true)
        #expect(byName["Contributor"]?.body.duration == "PT8H")
        #expect(throws: ActivationRequestError.invalidMinutes(0)) {
            try ActivationRequestBuilder.body(for: rows[0], principalId: "me", justification: "x", minutes: 0, now: Fixture.now)
        }
    }

    @Test func outcomeFallbackExpiryUsesMinutes() {
        let o = ActivationResponseMapper.outcome(statusCode: 201, data: Data("{}".utf8), requestedAt: Fixture.now, minutes: 90)
        #expect(o == .activated(status: "", until: Fixture.now.addingTimeInterval(5400)))
    }
}

@Suite("Role management policies")
struct RolePolicyTests {
    @Test func parsesTheEndUserRules() throws {
        let policy = try #require(try RolePolicyParser.parse(Fixture.data("role-policy-assignments")))
        // The admin rules (P365D, P180D) are not what applies to activation.
        #expect(policy.maximumDuration == 5400)
        #expect(policy.maxMinutes == 90)
        #expect(policy.maxDurationISO == "PT1H30M")
        #expect(policy.requiresJustification)
        #expect(policy.requiresTicket)
        #expect(policy.requiresMFA)
        #expect(policy.requiresApproval)
        #expect(policy.authenticationContext == "c1")
        #expect(policy.policyId?.hasSuffix("roleManagementPolicies/00000000-1111-2222-3333-444444444444") == true)
    }

    @Test func defaultPolicyShape() throws {
        let policy = try #require(try RolePolicyParser.parse(policyResponse(roleGUID: "r", maxDuration: "PT8H")))
        #expect(policy.maxMinutes == 480)
        #expect(policy.requiresJustification && !policy.requiresTicket && !policy.requiresMFA && !policy.requiresApproval)
        #expect(policy.authenticationContext == nil)
        let none = try #require(try RolePolicyParser.parse(policyResponse(roleGUID: "r", maxDuration: nil)))
        #expect(none.maxMinutes == nil)
    }

    @Test func emptyListHasNoPolicy() throws {
        #expect(try RolePolicyParser.parse(Data(#"{"value": []}"#.utf8)) == nil)
        #expect(throws: (any Error).self) { try RolePolicyParser.parse(Data("<html>".utf8)) }
    }

    @Test func picksTheAssignmentOfTheRequestedRole() throws {
        func item(_ guid: String, _ max: String) -> String {
            #"{"properties": {"roleDefinitionId": "/subscriptions/x/providers/Microsoft.Authorization/roleDefinitions/\#(guid)", "effectiveRules": [{"id": "Expiration_EndUser_Assignment", "maximumDuration": "\#(max)"}]}}"#
        }
        let data = Data(#"{"value": [\#(item("aaaa", "PT1H")), \#(item("BBBB", "PT3H"))]}"#.utf8)
        #expect(try RolePolicyParser.parse(data, roleDefinitionId: "/providers/Microsoft.Authorization/roleDefinitions/bbbb")?.maxMinutes == 180)
        #expect(try RolePolicyParser.parse(data)?.maxMinutes == 60)
    }

    @Test func matchesRulesByTypeAndTargetWithoutAnId() throws {
        let data = Data(#"""
        {"value": [{"properties": {"effectiveRules": [
          {"ruleType": "RoleManagementPolicyExpirationRule", "maximumDuration": "PT2H", "target": {"caller": "EndUser", "level": "Assignment"}},
          {"ruleType": "RoleManagementPolicyExpirationRule", "maximumDuration": "PT9H", "target": {"caller": "EndUser", "level": "Eligibility"}},
          {"ruleType": "RoleManagementPolicyApprovalRule", "setting": {"isApprovalRequired": true}, "target": {"caller": "EndUser", "level": "Assignment"}}
        ]}}]}
        """#.utf8)
        let policy = try #require(try RolePolicyParser.parse(data))
        #expect(policy.maxMinutes == 120)
        #expect(policy.requiresApproval)
    }

    @Test func urlFiltersByRoleDefinition() throws {
        let url = ARM.policyAssignmentsURL(
            scope: "/subscriptions/aaaaaaaa-0000-0000-0000-00000000000a/resourceGroups/rg-app-dev/",
            roleDefinitionId: "/subscriptions/aaaaaaaa-0000-0000-0000-00000000000a/providers/Microsoft.Authorization/roleDefinitions/\(EligibleRole.ownerRoleGUID)")
        #expect(url.host == "management.azure.com")
        #expect(url.path == "/subscriptions/aaaaaaaa-0000-0000-0000-00000000000a/resourceGroups/rg-app-dev/providers/Microsoft.Authorization/roleManagementPolicyAssignments")
        #expect(url.absoluteString.contains("api-version=2020-10-01&$filter=roleDefinitionId%20eq%20%27/subscriptions/"))
        let filter = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "$filter" }?.value
        #expect(filter == "roleDefinitionId eq '/subscriptions/aaaaaaaa-0000-0000-0000-00000000000a/providers/Microsoft.Authorization/roleDefinitions/\(EligibleRole.ownerRoleGUID)'")
    }

    @Test func serviceLoadsOncePerScopeAndRoleWithBoundedConcurrency() async throws {
        let transport = RecordingTransport(delayNanos: 20_000_000) { request in
            guard let guid = filteredRoleGUID(request) else { return (Data(), 400) }
            if guid == "acdd72a7-3385-48ef-bd42-f606fba81ae7" {
                return (Data(#"{"error": {"code": "AuthorizationFailed", "message": "no"}}"#.utf8), 403)
            }
            if guid == "b24988ac-6180-42a0-ab88-20f7382dd24c" { return (Data(#"{"value": []}"#.utf8), 200) }
            return (policyResponse(roleGUID: guid, maxDuration: "PT2H"), 200)
        }
        let service = PIMService(transport: transport, tokens: StaticTokenProvider())
        var rows = try Fixture.rows()
        rows.append(rows[0])  // the same scope + role twice: one lookup
        let results = try await service.loadPolicies(for: rows, maxConcurrent: 2)
        let requests = await transport.requests
        #expect(requests.count == 4)
        #expect(requests.allSatisfy { $0.httpMethod == "GET" && $0.url?.host == "management.azure.com" })
        #expect(await transport.peakInFlight <= 2)
        func lookup(_ role: String, _ scope: String) throws -> PolicyLookup? {
            results[try Fixture.role(scope, role).policyKey]
        }
        #expect(try lookup("Owner", "Contoso Production")?.maxMinutes == 120)
        #expect(try lookup("Reader", "Contoso Production") == .failed("AuthorizationFailed: no"))
        #expect(try lookup("Contributor", "Contoso Staging") == .notFound)
    }

    @Test func noRolesNoRequests() async throws {
        let transport = RecordingTransport { _ in (Data(), 500) }
        let service = PIMService(transport: transport, tokens: StaticTokenProvider())
        #expect(try await service.loadPolicies(for: []).isEmpty)
        #expect(await transport.requests.isEmpty)
    }
}
