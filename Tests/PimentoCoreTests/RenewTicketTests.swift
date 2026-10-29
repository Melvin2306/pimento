import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import PimentoCore

/// `asTarget()` requests where the activation behind the Contoso Production
/// Owner (schedule `a1`) was requested with a ticket; the one behind the
/// rg-app-dev Owner (`a5`) without.
@Sendable func ticketHistory(_ request: URLRequest) throws -> (Data, Int)? {
    guard request.url!.absoluteString.contains("roleAssignmentScheduleRequests?") else { return nil }
    let doc: [String: Any] = ["value": [
        ["name": "a1", "properties": ["principalId": Fixture.userOID, "requestType": "SelfActivate", "status": "Provisioned",
                                      "ticketInfo": ["ticketNumber": "CHG-1001", "ticketSystem": "ServiceNow"]]],
        ["name": "a5", "properties": ["principalId": Fixture.userOID, "requestType": "SelfActivate", "status": "Provisioned"]],
    ]]
    return (try JSONSerialization.data(withJSONObject: doc), 200)
}

private func ticketInfo(_ request: URLRequest) throws -> [String: String]? {
    let doc = try #require(try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any])
    return (doc["properties"] as? [String: Any])?["ticketInfo"] as? [String: String]
}

@Suite("Renew: tickets")
struct RenewTicketTests {
    @Test func aGivenTicketWinsOverTheOriginal() {
        let given = TicketInfo(number: "CHG-2", system: "Jira"), original = TicketInfo(number: "CHG-1", system: "ServiceNow")
        #expect(RenewTicket.choose(given: given, original: original) == given)
        #expect(RenewTicket.choose(given: nil, original: original) == original)
        #expect(RenewTicket.choose(given: TicketInfo(number: " ", system: nil), original: nil) == nil)
    }

    @Test func missingOnlyWhenThePolicyRequiresOne() throws {
        let role = try Fixture.role("Contoso Production", "Owner")
        let needs = PolicyLookup.loaded(RolePolicy(maximumDuration: 3600, requiresTicket: true))
        #expect(RenewTicket.isMissing(role, ticket: nil, policy: needs))
        #expect(RenewTicket.isMissing(role, ticket: TicketInfo(number: "CHG-1", system: nil), policy: needs))
        #expect(!RenewTicket.isMissing(role, ticket: TicketInfo(number: "CHG-1", system: "ServiceNow"), policy: needs))
        #expect(!RenewTicket.isMissing(role, ticket: nil, policy: .loaded(RolePolicy(maximumDuration: 3600))))
        #expect(!RenewTicket.isMissing(role, ticket: nil, policy: nil))
    }

    @Test func selectionSkipsRolesWithoutATicketAndApprovalComesFirst() throws {
        let production = try Fixture.role("Contoso Production", "Owner")
        let dev = try Fixture.role("rg-app-dev", "Owner")
        let s = RoleLifecycle.select([production, dev], now: Fixture.now, forRenewal: true,
                                     needsTicket: { _ in true }, requiresApproval: { $0.id == production.id })
        #expect(s.needsApproval.map(\.id) == [production.id])
        #expect(s.needsTicket.map(\.id) == [dev.id])
        #expect(s.ready.isEmpty && !s.isEmpty)
        // Deactivation ignores tickets.
        #expect(RoleLifecycle.select([dev], now: Fixture.now, needsTicket: { _ in true }).ready.map(\.id) == [dev.id])
    }

    @Test func theRenewalCarriesTheTicketOnEveryAttempt() throws {
        let owner = try Fixture.role("Contoso Production", "Owner")
        let ticket = TicketInfo(number: "CHG-1001", system: "ServiceNow")
        let plans = try ActivationRequestBuilder.renewPlan([owner], principalId: "me", justification: "x", now: Fixture.now,
                                                           ticket: { _ in ticket }) { _ in
            EffectiveDuration.resolve(.hours(1), policyMaxMinutes: nil, fallbackHours: 8)
        }
        let plan = try #require(plans.first)
        #expect(plan.ticket == ticket)
        #expect(plan.plannedActivation.body.properties.ticketInfo == ticket)
        #expect(plan.deactivation.body.properties.ticketInfo == nil)
        #expect(try plan.activation(now: Fixture.now.addingTimeInterval(10)).body.properties.ticketInfo == ticket)
        // No ticket: none sent.
        let bare = try ActivationRequestBuilder.renewPlan([owner], principalId: "me", justification: "x", now: Fixture.now) { _ in plan.duration }
        #expect(bare[0].plannedActivation.body.properties.ticketInfo == nil)
    }

    @Test func cliReusesTheOriginalTicketAndSkipsRolesWithoutOne() async throws {
        let h = CLIHarness(put: lifecyclePUT)
        h.policy = ticketPolicy
        h.get = ticketHistory
        #expect(await h.run("renew", "--role", "Owner", "-j", "on-call", "--yes", "--json") == 1)
        let puts = await h.puts
        #expect(requestTypes(puts) == ["SelfDeactivate", "SelfActivate"])
        #expect(puts[1].url!.path.hasPrefix("/subscriptions/aaaaaaaa-0000-0000-0000-00000000000a/"))
        #expect(try ticketInfo(puts[1]) == ["ticketNumber": "CHG-1001", "ticketSystem": "ServiceNow"])
        #expect(h.err.contains("its policy requires a ticket and the ticket of the current activation is unknown"))
        #expect(h.err.contains("Ticket: the one each activation was requested with (CHG-1001 (ServiceNow))"))
        let doc = try #require(try JSONSerialization.jsonObject(with: Data(h.out.utf8)) as? [String: Any])
        let results = try #require(doc["results"] as? [[String: Any]])
        #expect(results.contains { $0["code"] as? String == "TicketRequired" && ($0["role"] as? [String: Any])?["scopeName"] as? String == "rg-app-dev" })
    }

    @Test func cliTicketFlagsCoverEveryRole() async throws {
        let h = CLIHarness(put: lifecyclePUT)
        h.policy = ticketPolicy
        h.get = ticketHistory
        #expect(await h.run("renew", "--role", "Owner", "-j", "on-call", "--ticket", "CHG-7", "--ticket-system", "Jira", "--yes") == 0)
        let activations = await h.puts.filter { (try? ticketInfo($0)) != nil }
        #expect(activations.count == 2)
        #expect(try activations.allSatisfy { try ticketInfo($0) == ["ticketNumber": "CHG-7", "ticketSystem": "Jira"] })
        #expect(h.out.contains("Ticket: CHG-7 (Jira)"))
        #expect(h.out.contains("2 renewed"))
    }

    @Test func cliRenewParsesTicketFlags() throws {
        guard case .renew(let o) = try CLIParser.parse(["renew", "--all", "-j", "x", "--ticket", "CHG-1", "--ticket-system", "ServiceNow"]).command
        else { Issue.record("expected renew"); return }
        #expect(o.ticketNumber == "CHG-1" && o.ticketSystem == "ServiceNow")
        #expect(throws: CLIParseError.unknownOption("--ticket", command: "deactivate")) {
            try CLIParser.parse(["deactivate", "--all", "--ticket", "x"])
        }
        #expect(CLIHelp.text(for: "renew").contains("--ticket NUMBER"))
    }
}
