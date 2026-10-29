import Foundation
import Testing
@testable import PimentoCore

@Suite("Ticket information")
struct TicketTests {
    @Test func trimsAndKnowsWhenItIsComplete() {
        #expect(TicketInfo.make(number: "  ", system: nil) == nil)
        let number = TicketInfo(number: " CHG-1001 ", system: "")
        #expect(number.ticketNumber == "CHG-1001" && number.ticketSystem == nil)
        #expect(!number.isComplete && !number.isEmpty)
        let full = TicketInfo(number: "CHG-1001", system: "ServiceNow")
        #expect(full.isComplete)
        #expect(full.label == "CHG-1001 (ServiceNow)")
        #expect(number.label == "CHG-1001")
    }

    @Test func goesIntoTheRequestBodyOnlyWhenGiven() throws {
        let role = try Fixture.role("Contoso Staging", "Contributor")
        let with = try ActivationRequestBuilder.body(
            for: role, principalId: Fixture.userOID, justification: "x", minutes: 60, now: Fixture.now,
            ticket: TicketInfo(number: "CHG-1001", system: "ServiceNow"))
        let json = try #require(try JSONSerialization.jsonObject(with: ActivationRequestBuilder.encode(with)) as? [String: Any])
        let ticket = try #require((json["properties"] as? [String: Any])?["ticketInfo"] as? [String: String])
        #expect(ticket == ["ticketNumber": "CHG-1001", "ticketSystem": "ServiceNow"])

        let without = try ActivationRequestBuilder.body(for: role, principalId: Fixture.userOID, justification: "x", minutes: 60, now: Fixture.now)
        #expect(!String(decoding: ActivationRequestBuilder.encode(without), as: UTF8.self).contains("ticketInfo"))
        let empty = try ActivationRequestBuilder.body(
            for: role, principalId: Fixture.userOID, justification: "x", minutes: 60, now: Fixture.now, ticket: TicketInfo(number: "", system: " "))
        #expect(empty.properties.ticketInfo == nil)

        // A plan sends it with every request; a number alone is passed on as is.
        let plans = try ActivationRequestBuilder.plan(
            [role, try Fixture.role("Contoso Production", "Reader")], principalId: Fixture.userOID, justification: "x",
            now: Fixture.now, ticket: TicketInfo(number: "INC-7", system: nil)
        ) { _ in EffectiveDuration(minutes: 60, requested: .hours(1), policyMaxMinutes: nil) }
        #expect(plans.allSatisfy { $0.body.properties.ticketInfo == TicketInfo(number: "INC-7", system: nil) })
    }

    @Test func rolesWhosePolicyRequiresATicket() throws {
        let rows = try Fixture.rows()
        let staging = try Fixture.role("Contoso Staging", "Contributor")
        let policies: [RoleMatcher.Key: PolicyLookup] = [
            staging.policyKey: .loaded(RolePolicy(requiresTicket: true)),
            try Fixture.role("Contoso Production", "Reader").policyKey: .loaded(RolePolicy(requiresJustification: true)),
            try Fixture.role("rg-app-dev", "Owner").policyKey: .failed("HTTP 403"),
        ]
        let lookup: (EligibleRole) -> PolicyLookup? = { policies[$0.policyKey] }
        #expect(TicketRequirement.rolesNeedingTicket(rows, policy: lookup).map(\.id) == [staging.id])
        #expect(TicketRequirement.missing(rows, ticket: nil, policy: lookup).map(\.id) == [staging.id])
        #expect(TicketRequirement.missing(rows, ticket: TicketInfo(number: "CHG-1", system: nil), policy: lookup).map(\.id) == [staging.id])
        #expect(TicketRequirement.missing(rows, ticket: TicketInfo(number: "CHG-1", system: "Jira"), policy: lookup).isEmpty)
    }

    @Test func ticketingRuleFailuresSayWhatToGive() {
        let data = Data(#"{"error":{"code":"RoleAssignmentRequestPolicyValidationFailed","message":"The following policy rules failed: [\"TicketingRule\"]"}}"#.utf8)
        let outcome = ActivationResponseMapper.outcome(statusCode: 400, data: data, requestedAt: Fixture.now, hours: 1)
        #expect(outcome == .policyViolation(rules: ["TicketingRule"], message: "The following policy rules failed: [\"TicketingRule\"]"))
        #expect(outcome.summary == "Policy: a ticket is required: give a ticket number and ticket system")
    }

    @Test func recentTicketsAreMostRecentFirstWithoutDuplicates() {
        let a = TicketInfo(number: "CHG-1", system: "ServiceNow"), b = TicketInfo(number: "CHG-2", system: "ServiceNow")
        var recent = TicketInfo.recording(a, in: [])
        recent = TicketInfo.recording(b, in: recent)
        recent = TicketInfo.recording(a, in: recent)
        #expect(recent == [a, b])
        #expect(TicketInfo.recording(TicketInfo(number: nil, system: "Jira"), in: recent) == recent)
        #expect(TicketInfo.recording(nil, in: recent) == recent)
        #expect(TicketInfo.recording(TicketInfo(number: "X", system: nil), in: recent, limit: 2).count == 2)
    }

    @Test func presetsKeepADefaultTicketSystem() throws {
        let preset = Preset(name: "Changes", tenantId: nil, justification: "release", ticketSystem: " ServiceNow ")
        let data = try JSONEncoder().encode(preset)
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["ticketSystem"] as? String == "ServiceNow")
        let back = try JSONDecoder().decode(Preset.self, from: data)
        #expect(back.trimmedTicketSystem == "ServiceNow")
        // Older files without the key still load.
        let old = try JSONDecoder().decode(Preset.self, from: Data(#"{"name":"Old","roles":[]}"#.utf8))
        #expect(old.ticketSystem == nil)
        #expect(CLIJSON.PresetDoc(preset).ticketSystem == "ServiceNow")
    }
}
