import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import PimentoCore

/// Answers a SelfActivate PUT with `Granted` and the start it asked for.
@Sendable func scheduledPUT(_ request: URLRequest) throws -> (Data, Int) {
    let body = try #require(try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any])
    let props = try #require(body["properties"] as? [String: Any])
    let schedule = try #require(props["scheduleInfo"] as? [String: Any])
    let doc: [String: Any] = ["properties": ["status": "Granted", "requestType": "SelfActivate", "scheduleInfo": schedule]]
    return (try JSONSerialization.data(withJSONObject: doc), 201)
}

func requestProperties(_ request: URLRequest?) throws -> [String: Any] {
    let request = try #require(request)
    let doc = try #require(try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any])
    return try #require(doc["properties"] as? [String: Any])
}

@Sendable func ticketPolicy(_ request: URLRequest) throws -> (Data, Int) {
    guard let guid = filteredRoleGUID(request) else { return (Data(), 400) }
    return (policyResponse(roleGUID: guid, maxDuration: "PT8H", enabled: ["Justification", "Ticketing"]), 200)
}

@Suite("CLI: --at, --ticket, scheduled, cancel parsing")
struct CLIScheduleParserTests {
    func command(_ args: String...) throws -> CLICommand { try CLIParser.parse(args).command }

    @Test func activateTakesAStartAndATicket() throws {
        guard case .activate(let o) = try command(
            "activate", "staging", "-j", "x", "--at", "tomorrow 08:00", "--ticket", "CHG-1", "--ticket-system", "Jira")
        else { Issue.record("expected activate"); return }
        #expect(o.at == "tomorrow 08:00")
        #expect(o.ticketNumber == "CHG-1" && o.ticketSystem == "Jira")
        guard case .activate(let rel) = try command("activate", "--all", "-j", "x", "--at", "+1h") else { Issue.record("expected activate"); return }
        #expect(rel.at == "+1h")
        guard case .activate(let preset) = try command("activate", "--preset", "Changes", "--ticket", "CHG-2") else { Issue.record("expected activate"); return }
        #expect(preset.ticketNumber == "CHG-2" && preset.ticketSystem == nil)
        #expect(throws: CLIParseError.missingValue("--at")) { try command("activate", "--all", "-j", "x", "--at") }
    }

    @Test func scheduledAndCancel() throws {
        guard case .scheduled(let s) = try command("scheduled", "--json", "-t", "contoso.example") else { Issue.record("expected scheduled"); return }
        #expect(s.json && s.tenant == "contoso.example")
        #expect(throws: CLIParseError.unexpectedArgument("x", command: "scheduled")) { try command("scheduled", "x") }
        guard case .cancel(let c) = try command("cancel", "5f0c1d2e", "rg-app-dev", "--role", "Owner", "--yes", "--dry-run", "--json")
        else { Issue.record("expected cancel"); return }
        #expect(c.targets == ["5f0c1d2e", "rg-app-dev"])
        #expect(c.roles == ["Owner"])
        #expect(c.assumeYes && c.dryRun && c.json && !c.all)
        guard case .cancel(let all) = try command("cancel", "--all") else { Issue.record("expected cancel"); return }
        #expect(all.all)
        #expect(throws: CLIParseError.noCancelSelection) { try command("cancel") }
        #expect(throws: CLIParseError.unknownOption("--hours", command: "cancel")) { try command("cancel", "--all", "--hours", "1") }
    }

    @Test func presetsSaveTakesATicketSystem() throws {
        guard case .presets(.save(let o)) = try command("presets", "save", "Changes", "prod", "--ticket-system", "ServiceNow")
        else { Issue.record("expected presets save"); return }
        #expect(o.ticketSystem == "ServiceNow")
    }

    @Test func helpAndCompletionsKnowTheNewCommands() throws {
        for name in ["scheduled", "cancel"] {
            #expect(try command(name, "--help") == .help(topic: name))
            #expect(CLIHelp.text(for: name).hasPrefix("Usage: pimento \(name)"))
            #expect(CLIHelp.text(for: nil).contains("  \(name) "))
            for shell in CompletionShell.allCases { #expect(CLIHelp.completionScript(for: shell).contains(name)) }
        }
        let activate = CLIHelp.text(for: "activate")
        for flag in ["--at WHEN", "--ticket NUMBER", "--ticket-system NAME", "workday 08:00", "tomorrow 08:00"] {
            #expect(activate.contains(flag))
        }
        for shell in CompletionShell.allCases {
            #expect(CLIHelp.completionScript(for: shell).contains("ticket-system"))
            #expect(CLIHelp.completionScript(for: shell).contains("at"))
        }
    }

    @Test func cancelSelectionByIdPrefixFilterAndRole() throws {
        func req(_ name: String, _ scopeName: String, _ role: String) -> ScheduledRequest {
            ScheduledRequest(id: "/x/\(name)", name: name, scope: "/subscriptions/s/resourceGroups/\(scopeName)", roleDefinitionId: "r/\(role)",
                             roleName: role, scopeName: scopeName, scopeType: "resourcegroup", status: "Granted",
                             start: Fixture.now.addingTimeInterval(3600), end: nil)
        }
        let pending = [req("abcd1111-0000", "rg-cafe", "Owner"), req("abcd2222-0000", "rg-web", "Reader"), req("ef001111-0000", "rg-web", "Owner")]
        #expect(try CancelSelection.select(pending, targets: ["abcd1"], roles: [], all: false).requests.map(\.name) == ["abcd1111-0000"])
        #expect(throws: CLIParseError.ambiguousRequestId("abcd", matches: 2)) {
            try CancelSelection.select(pending, targets: ["abcd"], roles: [], all: false)
        }
        // Not an id: a resource filter.
        #expect(try CancelSelection.select(pending, targets: ["web"], roles: [], all: false).requests.count == 2)
        #expect(try CancelSelection.select(pending, targets: ["rg-cafe"], roles: [], all: false).requests.map(\.scopeName) == ["rg-cafe"])
        // An id that matches no request is not found, never a filter: `cafe` and
        // `ef00` (hex) would otherwise pick rg-cafe or a name containing them.
        let miss = try CancelSelection.select(pending, targets: ["cafe"], roles: [], all: false)
        #expect(miss.requests.isEmpty)
        #expect(miss.unknownIds == ["cafe"])
        let missLong = try CancelSelection.select(pending, targets: ["0000-cafe"], roles: [], all: false)
        #expect(missLong.requests.isEmpty)
        #expect(missLong.unknownIds == ["0000-cafe"])
        #expect(try CancelSelection.select(pending, targets: ["web"], roles: ["owner"], all: false).requests.map(\.name) == ["ef001111-0000"])
        #expect(try CancelSelection.select(pending, targets: [], roles: [], all: true).requests.count == 3)
        let unknown = try CancelSelection.select(pending, targets: ["deadbeef", "abcd1"], roles: [], all: false)
        #expect(unknown.unknownIds == ["deadbeef"])
        #expect(unknown.requests.count == 1)
    }
}

@Suite("CLI: scheduled activation and tickets")
struct CLIScheduleRunnerTests {
    @Test func activateAtSchedulesTheRoles() async throws {
        let h = CLIHarness(put: scheduledPUT)
        #expect(await h.run("activate", "staging", "-j", "release", "--at", "tomorrow 08:00", "--yes", "--json") == 0)
        let puts = await h.puts
        #expect(puts.count == 1)
        let schedule = try #require(try requestProperties(puts[0])["scheduleInfo"] as? [String: Any])
        // The harness runs in UTC: tomorrow 08:00 is 2026-10-30T08:00Z.
        #expect(schedule["startDateTime"] as? String == "2026-10-30T08:00:00.000Z")
        let doc = try #require(try JSONSerialization.jsonObject(with: Data(h.out.utf8)) as? [String: Any])
        #expect(doc["start"] as? String == "2026-10-30T08:00:00.000Z")
        #expect((doc["summary"] as? [String: Any])?["scheduled"] as? Int == 1)
        let result = try #require((doc["results"] as? [[String: Any]])?.first)
        #expect(result["outcome"] as? String == "scheduled")
        #expect(result["start"] as? String == "2026-10-30T08:00:00.000Z")
        #expect(result["status"] as? String == "Granted")
        #expect(h.err.contains("Schedule 1 role for up to 8 hours, starting Fri 08:00 (in 20h 00m)"))
        #expect(h.err.contains("scheduled  Contributor · Contoso Staging: starts Fri 08:00 until 12:00"))
        #expect(h.err.contains("1 scheduled."))
    }

    @Test func activeRolesAreScheduledOnlyWhenTheyHaveEndedByTheStart() async throws {
        // Both Owner activations run past 13:00: nothing to schedule.
        let soon = CLIHarness(put: scheduledPUT)
        #expect(await soon.run("activate", "--role", "Owner", "-j", "x", "--at", "+1h", "--yes") == 0)
        #expect(await soon.puts.isEmpty)
        #expect(soon.out.contains("still active at the start until 18:42"))
        #expect(soon.out.contains("Nothing to schedule"))
        // Both have ended by tomorrow morning: PIM accepts a schedule while active.
        let later = CLIHarness(put: scheduledPUT)
        #expect(await later.run("activate", "--role", "Owner", "-j", "x", "--at", "2026-10-30 08:00", "--yes") == 0)
        #expect(await later.puts.count == 2)
        #expect(later.out.contains("2 scheduled."))
    }

    @Test func aBadStartStopsBeforeAzure() async {
        let h = CLIHarness(put: scheduledPUT)
        #expect(await h.run("activate", "--all", "-j", "x", "--at", "yesterday 08:00", "--yes") == 2)
        #expect(h.err.contains("--at: Cannot read the start time"))
        #expect(await h.transport.requests.isEmpty)
        let far = CLIHarness(put: scheduledPUT)
        #expect(await far.run("activate", "--all", "-j", "x", "--at", "+40d", "--yes") == 2)
        #expect(far.err.contains("more than 30 days ahead"))
    }

    @Test func dryRunShowsTheScheduledBody() async {
        let h = CLIHarness(put: scheduledPUT)
        #expect(await h.run("activate", "staging", "-j", "x", "--at", "2026-10-30T09:30:00Z", "--dry-run") == 0)
        #expect(await h.puts.isEmpty)
        #expect(h.out.contains("Would schedule 1 role"))
        #expect(h.out.contains("\"startDateTime\" : \"2026-10-30T09:30:00.000Z\""))
    }

    @Test func aRequiredTicketIsCheckedBeforeSending() async throws {
        let missing = CLIHarness(put: scheduledPUT)
        missing.policy = ticketPolicy
        #expect(await missing.run("activate", "staging", "-j", "x", "--yes") == 2)
        #expect(missing.err.contains("This role needs a ticket"))
        #expect(missing.err.contains("Contributor · Contoso Staging"))
        #expect(missing.err.contains("--ticket NUMBER --ticket-system NAME"))
        #expect(await missing.puts.isEmpty)
        // A number without a system is not enough either.
        let half = CLIHarness()
        half.policy = ticketPolicy
        #expect(await half.run("activate", "staging", "-j", "x", "--ticket", "CHG-1", "--yes") == 2)

        let ok = CLIHarness()
        ok.policy = ticketPolicy
        #expect(await ok.run("activate", "staging", "-j", "x", "--ticket", "CHG-1", "--ticket-system", "ServiceNow", "--yes") == 0)
        let ticket = try #require(try requestProperties(await ok.puts.first)["ticketInfo"] as? [String: String])
        #expect(ticket == ["ticketNumber": "CHG-1", "ticketSystem": "ServiceNow"])
        #expect(ok.out.contains("Ticket: CHG-1 (ServiceNow)"))
    }

    @Test func anyRoleTakesAnOptionalTicket() async throws {
        let h = CLIHarness()
        #expect(await h.run("activate", "staging", "-j", "x", "--ticket", "INC-9", "--yes") == 0)
        let ticket = try #require(try requestProperties(await h.puts.first)["ticketInfo"] as? [String: String])
        #expect(ticket == ["ticketNumber": "INC-9"])
    }

    @Test func thePresetsTicketSystemCompletesTheNumber() async throws {
        let h = CLIHarness()
        h.policy = ticketPolicy
        try PresetStore(url: h.presetsURL).save(PresetLibrary(presets: [
            Preset(name: "Changes", tenantId: nil, match: [PresetRule(filters: ["staging"])], justification: "change", ticketSystem: "ServiceNow"),
        ]))
        #expect(await h.run("activate", "--preset", "Changes", "--ticket", "CHG-7", "--yes") == 0)
        let ticket = try #require(try requestProperties(await h.puts.first)["ticketInfo"] as? [String: String])
        #expect(ticket == ["ticketNumber": "CHG-7", "ticketSystem": "ServiceNow"])
        // Without --ticket the preset's system alone is not sent.
        let none = CLIHarness()
        try PresetStore(url: none.presetsURL).save(PresetLibrary(presets: [
            Preset(name: "Changes", tenantId: nil, match: [PresetRule(filters: ["staging"])], justification: "change", ticketSystem: "ServiceNow"),
        ]))
        #expect(await none.run("activate", "--preset", "Changes", "--yes") == 0)
        #expect(try requestProperties(await none.puts.first)["ticketInfo"] == nil)
    }

    @Test func ticketingRuleFailuresAreExplained() async {
        let h = CLIHarness(put: { _ in
            (Data(#"{"error":{"code":"RoleAssignmentRequestPolicyValidationFailed","message":"The following policy rules failed: [\"TicketingRule\"]"}}"#.utf8), 400)
        })
        #expect(await h.run("activate", "staging", "-j", "x", "--yes") == 1)
        #expect(h.out.contains("a ticket is required: give a ticket number and ticket system"))
    }
}

@Suite("CLI: scheduled and cancel")
struct CLIPendingRunnerTests {
    @Test func scheduledListsPendingRequestsReadOnly() async throws {
        let h = CLIHarness()
        #expect(await h.run("scheduled") == 0)
        let lines = h.out.split(separator: "\n").map(String.init)
        #expect(lines[0].hasPrefix("ID"))
        #expect(lines.count == 4)
        #expect(lines[1].hasPrefix("7a1b2c3d") && lines[1].contains("on approval") && lines[1].contains("awaiting approval"))
        #expect(lines[2].hasPrefix("5f0c1d2e") && lines[2].contains("Fri 07:00 (in 19h 00m)") && lines[2].contains("Owner (!)"))
        #expect(lines[3].contains("Mon 08:00") && lines[3].contains("8 h"))
        #expect(await h.puts.isEmpty)
        #expect(await h.posts.isEmpty)

        let json = CLIHarness()
        #expect(await json.run("scheduled", "--json") == 0)
        let doc = try #require(try JSONSerialization.jsonObject(with: Data(json.out.utf8)) as? [String: Any])
        let requests = try #require(doc["requests"] as? [[String: Any]])
        #expect(requests.map { $0["kind"] as? String } == ["awaitingApproval", "scheduled", "scheduled"])
        #expect(requests[1]["start"] as? String == "2026-10-30T07:00:00.000Z")
        #expect(requests[1]["duration"] as? String == "PT2H")
        #expect(requests[0]["ticketNumber"] as? String == "CHG-1001")
    }

    @Test func cancelByIdPostsToItsCancelURL() async throws {
        let h = CLIHarness()
        #expect(await h.run("cancel", "5f0c1d2e", "--yes", "--json") == 0)
        let posts = await h.posts
        #expect(posts.count == 1)
        #expect(posts[0].url!.path == "/subscriptions/cccccccc-0000-0000-0000-00000000000c/resourceGroups/rg-app-dev/providers/Microsoft.Authorization/roleAssignmentScheduleRequests/5f0c1d2e-0000-4000-8000-000000000001/cancel")
        let doc = try #require(try JSONSerialization.jsonObject(with: Data(h.out.utf8)) as? [String: Any])
        #expect((doc["summary"] as? [String: Any])?["cancelled"] as? Int == 1)
        #expect(h.err.contains("cancelled  Owner · rg-app-dev (was to start Fri 07:00)"))
    }

    @Test func cancelByFilterOrRoleAndDryRun() async {
        let dry = CLIHarness()
        #expect(await dry.run("cancel", "--all", "--dry-run") == 0)
        #expect(await dry.posts.isEmpty)
        #expect(dry.out.contains("Would cancel 3 requests"))
        #expect(dry.out.contains("POST https://management.azure.com/subscriptions/bbbbbbbb-0000-0000-0000-00000000000b/providers/Microsoft.Authorization/roleAssignmentScheduleRequests/7a1b2c3d-0000-4000-8000-000000000002/cancel?api-version=2020-10-01"))

        let role = CLIHarness()
        #expect(await role.run("cancel", "--role", "Contributor", "--yes") == 0)
        #expect(await role.posts.map { $0.url!.path.contains("7a1b2c3d") } == [true])
    }

    @Test func cancelAsksRefusesAndReportsFailures() async {
        let script = CLIHarness()
        #expect(await script.run("cancel", "--all") == 2)
        #expect(script.err.contains("Refusing to cancel without confirmation"))
        #expect(await script.posts.isEmpty)

        let no = CLIHarness(answers: ["n"])
        no.stdinIsTTY = true
        #expect(await no.run("cancel", "--all") == 1)
        #expect(no.err.contains("Cancel 3 requests? [y/N]"))
        #expect(await no.posts.isEmpty)

        let gone = CLIHarness()
        gone.post = { _ in (Data(#"{"error":{"code":"RequestCannotBeCancelled","message":"Request is not in cancellable state."}}"#.utf8), 400) }
        #expect(await gone.run("cancel", "5f0c", "--yes") == 1)
        #expect(gone.out.contains("Cannot be cancelled any more"))

        let unknown = CLIHarness()
        #expect(await unknown.run("cancel", "deadbeef", "--yes") == 1)
        #expect(unknown.out.contains("not found  deadbeef"))
        #expect(unknown.err.contains("No pending request matches"))
        #expect(await unknown.posts.isEmpty)

        // A hex target that is no request's id sends nothing.
        let miss = CLIHarness()
        #expect(await miss.run("cancel", "cccccccc", "--yes") == 1)
        #expect(miss.out.contains("not found  cccccccc"))
        #expect(await miss.posts.isEmpty)
        let filter = CLIHarness()
        #expect(await filter.run("cancel", "cccccccc-0000", "--dry-run") == 1)
        #expect(!filter.out.contains("Would cancel"))
    }
}
