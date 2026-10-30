import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import PimentoCore

@Suite("CLI: deactivate, renew, extend parsing")
struct CLILifecycleParserTests {
    func command(_ args: String...) throws -> CLICommand { try CLIParser.parse(args).command }

    @Test func deactivateCollectsItsOptions() throws {
        guard case .deactivate(let o) = try command(
            "deactivate", "contoso", "--role", "Owner", "-j", " done ", "--yes", "--dry-run", "--json", "--max-parallel", "2")
        else { Issue.record("expected deactivate"); return }
        #expect(o.criteria.filters == ["contoso"])
        #expect(o.criteria.roles == ["Owner"])
        #expect(o.criteria.state == .active)
        #expect(o.justification == "done")
        #expect(o.assumeYes && o.dryRun && o.json)
        #expect(o.maxParallel == 2)
        // The justification is optional for deactivate.
        guard case .deactivate(let all) = try command("deactivate", "--all") else { Issue.record("expected deactivate"); return }
        #expect(all.all && all.justification.isEmpty)
        guard case .deactivate(let preset) = try command("deactivate", "--preset", "On-call") else { Issue.record("expected deactivate"); return }
        #expect(preset.preset == "On-call")
    }

    @Test func renewNeedsAJustificationAndTakesHours() throws {
        guard case .renew(let o) = try command("renew", "--role", "Contributor", "-j", "still on it", "--hours", "max")
        else { Issue.record("expected renew"); return }
        #expect(o.duration == .maximum)
        #expect(throws: CLIParseError.missingJustificationFor("renew")) { try command("renew", "--all") }
        // With a preset the justification may come from the preset.
        guard case .renew = try command("renew", "--preset", "On-call") else { Issue.record("expected renew"); return }
    }

    @Test func extendNeedsSelectionJustificationAndValidDays() throws {
        guard case .extend(let o) = try command("extend", "fabrikam", "-j", "longer project", "--days", "90")
        else { Issue.record("expected extend"); return }
        #expect(o.days == 90)
        #expect(o.criteria.filters == ["fabrikam"])
        guard case .extend(let d) = try command("extend", "--all", "-j", "x") else { Issue.record("expected extend"); return }
        #expect(d.days == ExtendOptionsRange.defaultDays)
        #expect(throws: CLIParseError.missingJustificationFor("extend")) { try command("extend", "--all") }
        #expect(throws: CLIParseError.outOfRange(flag: "--days", value: 400, range: ExtendOptionsRange.days)) {
            try command("extend", "--all", "-j", "x", "--days", "400")
        }
    }

    @Test func usageErrors() {
        #expect(throws: CLIParseError.noActiveSelection("deactivate")) { try command("deactivate") }
        #expect(throws: CLIParseError.noActiveSelection("renew")) { try command("renew", "-j", "x") }
        #expect(throws: CLIParseError.noActiveSelection("extend")) { try command("extend", "-j", "x") }
        #expect(throws: CLIParseError.unknownOption("--hours", command: "deactivate")) { try command("deactivate", "--all", "--hours", "2") }
        #expect(throws: CLIParseError.unknownOption("--preset", command: "extend")) { try command("extend", "--preset", "x", "-j", "y") }
        #expect(throws: CLIParseError.conflicting("--preset", "filters, --role or --all")) { try command("deactivate", "--preset", "x", "--all") }
        #expect(CLIParseError.noActiveSelection("deactivate").errorDescription?.contains("--preset") == true)
    }

    @Test func helpAndCompletionsKnowTheNewCommands() throws {
        for name in ["deactivate", "renew", "extend"] {
            #expect(try command(name, "--help") == .help(topic: name))
            #expect(CLIHelp.text(for: name).hasPrefix("Usage: pimento \(name)"))
            #expect(CLIHelp.text(for: nil).contains("  \(name) "))
            for shell in CompletionShell.allCases { #expect(CLIHelp.completionScript(for: shell).contains(name)) }
        }
        #expect(CLIHelp.text(for: "renew").contains("NOT active"))
        #expect(CLIHelp.text(for: "extend").contains("PendingAdminDecision"))
    }
}

/// Answers PUTs by request type: SelfDeactivate → Revoked, SelfActivate →
/// the success fixture, SelfExtend → PendingAdminDecision.
@Sendable func lifecyclePUT(_ request: URLRequest) throws -> (Data, Int) {
    let body = try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any]
    switch (body?["properties"] as? [String: Any])?["requestType"] as? String {
    case "SelfDeactivate": return (Data(#"{"properties":{"status":"Revoked"}}"#.utf8), 201)
    case "SelfExtend": return (Data(#"{"properties":{"status":"PendingAdminDecision"}}"#.utf8), 201)
    default: return (try Fixture.data("success-response"), 201)
    }
}

func requestTypes(_ requests: [URLRequest]) -> [String] {
    requests.compactMap { r in
        let body = try? JSONSerialization.jsonObject(with: r.httpBody ?? Data()) as? [String: Any]
        return (body?["properties"] as? [String: Any])?["requestType"] as? String
    }
}

/// Owner capped at 2 h like the default fake policy, but without approval
/// (the default one requires it, and Renew leaves those alone).
@Sendable func noApprovalPolicy(_ request: URLRequest) throws -> (Data, Int) {
    guard let guid = filteredRoleGUID(request) else { return (Data(), 400) }
    return (policyResponse(roleGUID: guid, maxDuration: CLIHarness.policyMaxima[guid] ?? "PT8H"), 200)
}

@Suite("CLI: deactivate, renew, extend")
struct CLILifecycleRunnerTests {
    @Test func deactivateDryRunSendsNothing() async {
        let h = CLIHarness(put: lifecyclePUT)
        #expect(await h.run("deactivate", "--role", "Owner", "--dry-run") == 0)
        #expect(await h.puts.isEmpty)
        #expect(h.out.contains("Would deactivate 2 roles"))
        #expect(h.out.contains("\"requestType\" : \"SelfDeactivate\""))
        #expect(!h.out.contains("scheduleInfo"))
    }

    @Test func deactivateWithYesEndsTheMatchingActiveRoles() async throws {
        let h = CLIHarness(put: lifecyclePUT)
        #expect(await h.run("deactivate", "rg-app-dev", "--yes", "--json") == 0)
        let puts = await h.puts
        #expect(requestTypes(puts) == ["SelfDeactivate"])
        #expect(puts[0].url!.path.contains("/resourceGroups/rg-app-dev/"))
        let doc = try #require(try JSONSerialization.jsonObject(with: Data(h.out.utf8)) as? [String: Any])
        #expect(doc["action"] as? String == "deactivate")
        let summary = try #require(doc["summary"] as? [String: Any])
        #expect(summary["deactivated"] as? Int == 1)
        #expect(summary["failed"] as? Int == 0)
        #expect(h.err.contains("ended"))
    }

    @Test func deactivateOnlyConsidersActiveRoles() async {
        let h = CLIHarness(put: lifecyclePUT)
        // Contoso Staging's activation has ended: nothing active matches.
        #expect(await h.run("deactivate", "staging", "--yes") == 1)
        #expect(h.err.contains("No active role matches"))
        #expect(await h.puts.isEmpty)
    }

    @Test func deactivateRefusesWithoutAnswerAndAsksOnATerminal() async {
        let script = CLIHarness(put: lifecyclePUT)
        #expect(await script.run("deactivate", "--all") == 2)
        #expect(script.err.contains("Refusing to deactivate without confirmation"))
        #expect(await script.puts.isEmpty)

        let no = CLIHarness(answers: ["n"], put: lifecyclePUT)
        no.stdinIsTTY = true
        #expect(await no.run("deactivate", "--all") == 1)
        #expect(no.err.contains("Deactivate 2 roles, including 2 Owner? [y/N]"))
        #expect(await no.puts.isEmpty)

        let yes = CLIHarness(answers: ["y"], put: lifecyclePUT)
        yes.stdinIsTTY = true
        #expect(await yes.run("deactivate", "--all") == 0)
        #expect(requestTypes(await yes.puts) == ["SelfDeactivate", "SelfDeactivate"])
    }

    @Test func tooSoonIsReportedWithTheTimeAndNotSent() async {
        let h = CLIHarness(put: lifecyclePUT)
        // Two minutes after the fixtures' activations started.
        h.now = AzureDate.parse("2026-10-29T09:44:19Z")!
        #expect(await h.run("deactivate", "rg-app-dev", "--yes") == 1)
        #expect(await h.puts.isEmpty)
        #expect(h.out.contains("too soon"))
        #expect(h.out.contains("can be ended from 09:47"))
        #expect(h.out.contains("only 5 minutes after it started"))
    }

    @Test func renewEndsAndActivatesAgain() async throws {
        let h = CLIHarness(put: lifecyclePUT)
        h.policy = noApprovalPolicy
        #expect(await h.run("renew", "rg-app-dev", "-j", "still deploying", "--hours", "3", "--yes", "--json") == 0)
        let puts = await h.puts
        #expect(requestTypes(puts) == ["SelfDeactivate", "SelfActivate"])
        let on = try #require(try JSONSerialization.jsonObject(with: puts[1].httpBody!) as? [String: Any])
        let props = try #require(on["properties"] as? [String: Any])
        #expect(props["justification"] as? String == "still deploying")
        // The fake policy caps Owner at 2 h (3 were asked).
        let schedule = try #require(props["scheduleInfo"] as? [String: Any])
        #expect((schedule["expiration"] as? [String: Any])?["duration"] as? String == "PT2H")
        let doc = try #require(try JSONSerialization.jsonObject(with: Data(h.out.utf8)) as? [String: Any])
        #expect(doc["action"] as? String == "renew")
        #expect((doc["summary"] as? [String: Any])?["renewed"] as? Int == 1)
        let result = try #require((doc["results"] as? [[String: Any]])?.first)
        #expect(result["outcome"] as? String == "renewed")
        #expect(h.err.contains("In between it is NOT active"))
    }

    @Test func renewDryRunShowsBothRequests() async throws {
        let h = CLIHarness(put: lifecyclePUT)
        h.policy = noApprovalPolicy
        #expect(await h.run("renew", "rg-app-dev", "-j", "x", "--dry-run", "--json") == 0)
        #expect(await h.puts.isEmpty)
        let doc = try #require(try JSONSerialization.jsonObject(with: Data(h.out.utf8)) as? [String: Any])
        let result = try #require((doc["results"] as? [[String: Any]])?.first)
        #expect(result["outcome"] as? String == "planned")
        let requests = try #require(result["requests"] as? [[String: Any]])
        #expect(requests.count == 2)
        let types = requests.compactMap { (($0["body"] as? [String: Any])?["properties"] as? [String: Any])?["requestType"] as? String }
        #expect(types == ["SelfDeactivate", "SelfActivate"])
        #expect(result["duration"] as? String == "PT2H")
    }

    @Test func renewLeavesRolesThatNeedApprovalAlone() async {
        let h = CLIHarness(put: lifecyclePUT)
        h.policy = { request in
            guard let guid = filteredRoleGUID(request) else { return (Data(), 400) }
            return (policyResponse(roleGUID: guid, maxDuration: "PT8H", approval: true), 200)
        }
        #expect(await h.run("renew", "--all", "-j", "x", "--yes") == 1)
        #expect(await h.puts.isEmpty)
        #expect(h.out.contains("requires approval"))
    }

    @Test func extendSkipsActivationsAndPointsToRenew() async {
        let h = CLIHarness(put: lifecyclePUT)
        #expect(await h.run("extend", "contoso", "-j", "longer", "--yes") == 1)
        #expect(await h.puts.isEmpty)
        #expect(h.out.contains("is a PIM activation, left out"))
        #expect(h.out.contains("pimento renew"))
        #expect(h.err.contains("No admin-assigned, time-bound active assignment matches"))
    }

    @Test func extendRequestsAnExtensionOfATimeBoundAssignment() async throws {
        let h = CLIHarness(put: lifecyclePUT)
        #expect(await h.run("extend", "fabrikam", "-j", "project runs longer", "--days", "7", "--yes") == 0)
        let puts = await h.puts
        #expect(requestTypes(puts) == ["SelfExtend"])
        let body = try #require(try JSONSerialization.jsonObject(with: puts[0].httpBody!) as? [String: Any])
        let props = try #require(body["properties"] as? [String: Any])
        #expect((props["targetRoleAssignmentScheduleId"] as? String)?.hasSuffix("/roleAssignmentSchedules/tb1") == true)
        let expiration = (props["scheduleInfo"] as? [String: Any])?["expiration"] as? [String: Any]
        #expect(expiration?["endDateTime"] as? String == "2026-11-12T12:00:00.000Z")
        #expect(h.out.contains("submitted"))
        #expect(h.out.contains("PendingAdminDecision"))
        #expect(h.out.contains("An administrator of each resource must approve"))
    }

    @Test func renewAndExtendRefuseWithoutAnswerAndAskOnATerminal() async {
        for args in [["renew", "rg-app-dev", "-j", "x"], ["extend", "fabrikam", "-j", "x", "--days", "7"]] {
            let script = CLIHarness(put: lifecyclePUT)
            script.policy = noApprovalPolicy
            #expect(await script.run(args) == 2, "\(args[0]) without --yes and without a terminal")
            #expect(script.err.contains("Refusing to \(args[0])"))
            #expect(await script.puts.isEmpty)

            let no = CLIHarness(answers: ["n"], put: lifecyclePUT)
            no.policy = noApprovalPolicy
            no.stdinIsTTY = true
            #expect(await no.run(args) == 1)
            #expect(no.err.contains("[y/N]"))
            #expect(await no.puts.isEmpty, "\(args[0]) answered no")

            let yes = CLIHarness(answers: ["y"], put: lifecyclePUT)
            yes.policy = noApprovalPolicy
            yes.stdinIsTTY = true
            _ = await yes.run(args)
            #expect(await !yes.puts.isEmpty, "\(args[0]) answered yes")
        }
    }

    @Test func extendDryRunSendsNothing() async throws {
        let h = CLIHarness(put: lifecyclePUT)
        #expect(await h.run("extend", "fabrikam", "-j", "x", "--days", "7", "--dry-run") == 0)
        #expect(await h.puts.isEmpty)
        #expect(await h.transport.requests.allSatisfy { $0.httpMethod == "GET" })
    }
}
