import Foundation
import Testing
@testable import PimentoCore

@Suite("CLI presets and policy maximum")
struct CLIPresetTests {
    // MARK: Parsing

    @Test func parsesPresetAndMaxHours() throws {
        guard case .activate(let o) = try CLIParser.parse(["activate", "--preset", "On-call", "--hours", "max"]).command else {
            Issue.record("expected activate"); return
        }
        #expect(o.preset == "On-call")
        #expect(o.duration == .maximum)
        #expect(o.justification.isEmpty)  // may come from the preset
        #expect(throws: CLIParseError.conflicting("--preset", "filters, --role, --id or --all")) {
            try CLIParser.parse(["activate", "--preset", "x", "prod", "-j", "x"])
        }
        #expect(throws: CLIParseError.invalidHours("forever")) {
            try CLIParser.parse(["activate", "--all", "-j", "x", "--hours", "forever"])
        }
    }

    @Test func parsesPresetsSubcommands() throws {
        #expect(try CLIParser.parse(["presets"]).command == .presets(.list(PresetListOptions())))
        var list = PresetListOptions()
        list.json = true
        #expect(try CLIParser.parse(["presets", "--json"]).command == .presets(.list(list)))
        guard case .presets(.show(let show)) = try CLIParser.parse(["presets", "show", "On-call", "-t", "contoso.onmicrosoft.com"]).command else {
            Issue.record("expected show"); return
        }
        #expect(show.name == "On-call" && show.tenant == "contoso.onmicrosoft.com")
        guard case .presets(.save(let save)) = try CLIParser.parse(
            ["presets", "save", "On-call", "prod", "--role", "Owner", "-j", "on-call", "--hours", "max", "--exact", "-f"]).command else {
            Issue.record("expected save"); return
        }
        #expect(save.name == "On-call")
        #expect(save.criteria.filters == ["prod"] && save.criteria.roles == ["Owner"])
        #expect(save.exact && save.force)
        #expect(save.justification == "on-call" && save.duration == .maximum)
        guard case .presets(.delete(let del)) = try CLIParser.parse(["presets", "rm", "On-call"]).command else {
            Issue.record("expected delete"); return
        }
        #expect(del.name == "On-call")

        #expect(throws: CLIParseError.missingPresetName("show")) { try CLIParser.parse(["presets", "show"]) }
        #expect(throws: CLIParseError.noSelection) { try CLIParser.parse(["presets", "save", "x"]) }
        #expect(throws: CLIParseError.unknownPresetCommand("rename")) { try CLIParser.parse(["presets", "rename", "a", "b"]) }
        #expect(try CLIParser.parse(["help", "presets"]).command == .help(topic: "presets"))
        #expect(CLIHelp.text(for: "presets").contains("PIMENTO_PRESETS"))
    }

    // MARK: Policy maximum

    @Test func durationsAreCappedAtEachRolesPolicy() async {
        let h = CLIHarness()
        // Reader allows 8 h, Contributor 4 h (CLIHarness.policyMaxima).
        #expect(await h.run("activate", "--all", "-j", "INC-42", "--hours", "6", "--dry-run") == 0)
        #expect(h.out.contains("for up to 6 hours"))
        #expect(h.out.contains(#""duration" : "PT6H""#))
        #expect(h.out.contains(#""duration" : "PT4H""#))
        #expect(h.out.contains("4 h (max)"))
        #expect(h.out.contains("1 role capped at the policy maximum (asked 6 h)"))
        let gets = await h.transport.requests.filter { $0.url?.path.hasSuffix("roleManagementPolicyAssignments") == true }
        #expect(gets.count == 2)  // only the roles that will be activated
        #expect(await h.puts.isEmpty)
    }

    @Test func hoursMaxUsesEachPolicyAndFallsBackWhenUnknown() async throws {
        let h = CLIHarness()
        #expect(await h.run("activate", "--all", "-j", "x", "--hours", "max", "--dry-run", "--json") == 0)
        let doc = try #require(try JSONSerialization.jsonObject(with: Data(h.out.utf8)) as? [String: Any])
        #expect(doc["duration"] as? String == "max")
        #expect(doc["hours"] == nil)
        let planned = (doc["results"] as? [[String: Any]] ?? []).filter { $0["outcome"] as? String == "planned" }
        let byRole = Dictionary(uniqueKeysWithValues: planned.map { (($0["role"] as? [String: Any])?["roleName"] as? String ?? "", $0) })
        #expect(byRole["Reader"]?["duration"] as? String == "PT8H")
        #expect(byRole["Contributor"]?["duration"] as? String == "PT4H")
        #expect(byRole["Contributor"]?["maxDuration"] as? String == "PT4H")
        #expect(h.err.contains("for the longest each role allows"))

        let failing = CLIHarness()
        failing.policy = { _ in (Data(#"{"error": {"code": "AuthorizationFailed"}}"#.utf8), 403) }
        #expect(await failing.run("activate", "--all", "-j", "x", "--hours", "max", "--dry-run") == 0)
        #expect(failing.out.contains(#""duration" : "PT8H""#))
        #expect(!failing.out.contains(#""duration" : "PT4H""#))
        #expect(failing.out.contains("policy maximum unknown for 2 roles, using 8 h"))
    }

    @Test func realActivationSendsTheCappedDuration() async throws {
        let h = CLIHarness()
        #expect(await h.run("activate", "Staging", "-j", "x", "--hours", "12", "--yes") == 0)
        let puts = await h.puts
        #expect(puts.count == 1)
        let body = try #require(puts.first?.httpBody.flatMap { try JSONSerialization.jsonObject(with: $0) as? [String: Any] })
        let schedule = (body["properties"] as? [String: Any])?["scheduleInfo"] as? [String: Any]
        #expect((schedule?["expiration"] as? [String: Any])?["duration"] as? String == "PT4H")
    }

    @Test func listShowsAndExportsThePolicyMaximum() async throws {
        let h = CLIHarness()
        #expect(await h.run("list") == 0)
        #expect(h.out.split(separator: "\n").first?.contains("MAX") == true)
        let json = CLIHarness()
        #expect(await json.run("list", "--json") == 0)
        let doc = try #require(try JSONSerialization.jsonObject(with: Data(json.out.utf8)) as? [String: Any])
        let roles = try #require(doc["roles"] as? [[String: Any]])
        let owner = try #require(roles.first { $0["roleName"] as? String == "Owner" })
        #expect(owner["maxDuration"] as? String == "PT2H")
        let policy = try #require(owner["policy"] as? [String: Any])
        #expect(policy["status"] as? String == "loaded")
        #expect(policy["requiresApproval"] as? Bool == true)
        #expect(policy["requiresJustification"] as? Bool == true)
        #expect(roles.first { $0["roleName"] as? String == "Contributor" }?["maxDuration"] as? String == "PT4H")
    }

    // MARK: Presets

    func writePresets(_ h: CLIHarness, _ presets: [Preset]) throws {
        try PresetStore(url: h.presetsURL).save(PresetLibrary(presets: presets))
    }

    @Test func activatePresetUsesItsJustificationAndDurationAndReportsMissingRoles() async throws {
        let h = CLIHarness()
        let reader = try Fixture.role("Contoso Production", "Reader")
        let owner = try Fixture.role("Contoso Production", "Owner")
        let gone = PresetRole(scope: "/subscriptions/dddddddd-0000-0000-0000-00000000000d",
                              roleDefinitionId: "/providers/Microsoft.Authorization/roleDefinitions/\(EligibleRole.ownerRoleGUID)",
                              roleName: "Owner", scopeName: "Fabrikam Legacy")
        try writePresets(h, [Preset(name: "On-call", tenantId: nil, roles: [PresetRole(reader), PresetRole(owner), gone],
                                    justification: "on-call rotation", duration: .hours(2))])
        #expect(await h.run("activate", "--preset", "on-call", "--dry-run") == 0)
        #expect(h.out.contains("missing  Owner · Fabrikam Legacy: no longer eligible, left out"))
        #expect(h.out.contains("skip  Owner · Contoso Production: already active"))
        #expect(h.out.contains("Would activate 1 role for up to 2 hours (preset On-call)"))
        #expect(h.out.contains("Justification: on-call rotation"))
        #expect(h.out.contains(#""duration" : "PT2H""#))

        // -j and --hours win over the preset's.
        let o = CLIHarness()
        try writePresets(o, [Preset(name: "On-call", tenantId: nil, roles: [PresetRole(reader), gone], justification: "on-call rotation", duration: .hours(2))])
        #expect(await o.run("activate", "--preset", "On-call", "-j", "INC-7", "--hours", "max", "--dry-run", "--json") == 0)
        let doc = try #require(try JSONSerialization.jsonObject(with: Data(o.out.utf8)) as? [String: Any])
        #expect(doc["justification"] as? String == "INC-7")
        #expect(doc["preset"] as? String == "On-call")
        #expect(doc["duration"] as? String == "max")
        let missing = try #require(doc["missing"] as? [[String: Any]])
        #expect(missing.count == 1 && missing[0]["scopeName"] as? String == "Fabrikam Legacy")
        #expect((doc["summary"] as? [String: Int])?["planned"] == 1)
    }

    @Test func activatePresetNeedsAJustificationFromSomewhere() async throws {
        let h = CLIHarness()
        try writePresets(h, [Preset(name: "Read", tenantId: nil, roles: [PresetRole(try Fixture.role("Contoso Production", "Reader"))])])
        #expect(await h.run("activate", "--preset", "Read", "--dry-run") == 2)
        #expect(h.err.contains("justification"))
    }

    @Test func activatePresetWhoseRolesAreAllGoneFails() async throws {
        let h = CLIHarness()
        let gone = PresetRole(scope: "/subscriptions/dddddddd-0000-0000-0000-00000000000d", roleDefinitionId: "r", roleName: "Owner", scopeName: "Fabrikam Legacy")
        try writePresets(h, [Preset(name: "Old", tenantId: nil, roles: [gone], justification: "x")])
        #expect(await h.run("activate", "--preset", "Old", "--yes") == 1)
        #expect(h.err.contains("None of the preset's roles"))
        #expect(await h.puts.isEmpty)
    }

    @Test func activatePresetOfAnotherTenantIsAUsageError() async throws {
        let h = CLIHarness()
        h.tokens = StaticTokenProvider(token: fakeToken(["oid": Fixture.userOID, "tid": "11111111-2222-4333-8444-555555555555"]))
        h.variables[TenantResolver.environmentVariable] = "11111111-2222-4333-8444-555555555555"
        try writePresets(h, [Preset(name: "Fab", tenantId: "99999999-2222-4333-8444-555555555555",
                                    roles: [PresetRole(scope: "/s", roleDefinitionId: "r")], justification: "x")])
        #expect(await h.run("activate", "--preset", "Fab", "--dry-run") == 2)
        #expect(h.err.contains("--tenant 99999999-2222-4333-8444-555555555555"))
        #expect(await h.run("activate", "--preset", "Nope", "--dry-run") == 1)
    }

    /// A preset's tenant goes to `az --tenant` like `--tenant`, so it is
    /// checked like `--tenant` (the presets file can be edited by hand).
    @Test func aPresetTenantThatIsNoTenantIsRefused() async throws {
        for bad in ["--allow-no-subscriptions", "contoso", "a b.example", "-t.example"] {
            for command in [["activate", "--preset", "Odd", "--dry-run"], ["deactivate", "--preset", "Odd", "--dry-run"]] {
                let h = CLIHarness()
                try writePresets(h, [Preset(name: "Odd", tenantId: bad, roles: [PresetRole(scope: "/s", roleDefinitionId: "r")], justification: "x")])
                #expect(await h.run(command) == 2, "\(bad) \(command[0])")
                #expect(h.err.contains("is not a tenant GUID or domain"))
                #expect(await h.transport.requests.isEmpty)
                #expect(h.givenTokens.value?.isEmpty ?? true)
            }
        }
        #expect(try Preset(name: "Ok", tenantId: " contoso.example ").checkedTenantId() == "contoso.example")
        #expect(try Preset(name: "Any", tenantId: nil).checkedTenantId() == nil)
    }

    @Test func savePresetFromFiltersThenListShowAndDelete() async throws {
        let h = CLIHarness()
        let tid = "11111111-2222-4333-8444-555555555555"
        h.tokens = StaticTokenProvider(token: fakeToken(["oid": Fixture.userOID, "tid": tid]))
        #expect(await h.run("presets", "save", "Prod read", "production", "--role", "Reader", "-j", "look", "--hours", "max") == 0)
        #expect(h.out.contains("Saved preset “Prod read” (0 roles + 1 rule) for tenant \(tid)."))
        #expect(h.out.contains("It matches 1 role now:"))
        #expect(h.out.contains("pimento activate --preset 'Prod read'"))
        let saved = try PresetStore(url: h.presetsURL).load().presets
        #expect(saved.count == 1)
        #expect(saved[0].tenantId == tid && saved[0].match == [PresetRule(filters: ["production"], roles: ["Reader"])])
        #expect(saved[0].duration == .maximum && saved[0].justification == "look")

        // A second save with the same name needs --force.
        #expect(await h.run("presets", "save", "prod READ", "Staging", "--exact") == 1)
        #expect(h.err.contains("already exists"))
        #expect(await h.run("presets", "save", "prod READ", "Staging", "--exact", "--force") == 0)
        let replaced = try PresetStore(url: h.presetsURL).load().presets
        #expect(replaced.count == 1 && replaced[0].roles.map(\.scopeName) == ["Contoso Staging"] && replaced[0].match.isEmpty)

        let list = CLIHarness()
        list.variables = h.variables
        #expect(await list.run("presets", "list") == 0)
        #expect(list.out.contains("prod READ"))
        #expect(list.out.contains("1 role"))
        #expect(list.out.contains("11111111"))

        let show = CLIHarness()
        show.variables = h.variables
        #expect(await show.run("presets", "show", "Prod Read", "--json") == 0)
        let doc = try #require(try JSONSerialization.jsonObject(with: Data(show.out.utf8)) as? [String: Any])
        #expect(doc["name"] as? String == "prod READ")
        #expect((doc["roles"] as? [[String: Any]])?.first?["roleName"] as? String == "Contributor")

        let del = CLIHarness()
        del.variables = h.variables
        #expect(await del.run("presets", "delete", "prod read") == 0)
        #expect(try PresetStore(url: h.presetsURL).load().presets.isEmpty)
        #expect(await del.run("presets", "delete", "prod read") == 1)
    }

    @Test func exactSaveWithoutMatchesSavesNothing() async throws {
        let h = CLIHarness()
        #expect(await h.run("presets", "save", "x", "no-such-resource", "--exact") == 1)
        #expect(!FileManager.default.fileExists(atPath: h.presetsURL.path))
    }

    @Test func emptyListAndNewerFile() async throws {
        let h = CLIHarness()
        #expect(await h.run("presets") == 0)
        #expect(h.err.contains("No presets yet"))
        #expect(await h.transport.requests.isEmpty)  // offline

        let newer = CLIHarness()
        try FileManager.default.createDirectory(at: newer.presetsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"version": 9, "presets": []}"#.utf8).write(to: newer.presetsURL)
        #expect(await newer.run("presets", "list") == 1)
        #expect(newer.err.contains("newer Pimento"))
        #expect(await newer.run("activate", "--preset", "x", "--dry-run") == 1)
    }
}
