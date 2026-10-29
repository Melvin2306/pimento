import Foundation
import Testing
@testable import PimentoCore

@Suite("CLI parser")
struct CLIParserTests {
    func command(_ args: String...) throws -> CLICommand { try CLIParser.parse(args).command }

    @Test func noArgumentsShowsHelp() throws {
        #expect(try CLIParser.parse([]) == CLIInvocation(.help(topic: nil)))
        #expect(try command("help") == .help(topic: nil))
        #expect(try command("--help") == .help(topic: nil))
        // `--help COMMAND` like `help COMMAND`.
        #expect(try command("--help", "activate") == .help(topic: "activate"))
        #expect(try command("-h", "wait") == .help(topic: "wait"))
        #expect(throws: CLIParseError.unknownCommand("bogus")) { try command("--help", "bogus") }
        #expect(try command("help", "activate") == .help(topic: "activate"))
        #expect(try command("activate", "--help") == .help(topic: "activate"))
        #expect(try command("list", "-h") == .help(topic: "list"))
        #expect(try command("version") == .version)
        #expect(try command("--version") == .version)
    }

    @Test func listCollectsFiltersRolesAndState() throws {
        guard case .list(let o) = try command("list", "prod", "--role", "Owner", "--role=Reader", "--active",
                                              "--tenant=00000000-0000-0000-0000-0000000c0de0", "--json", "Staging")
        else { Issue.record("expected list"); return }
        #expect(o.criteria.filters == ["prod", "Staging"])
        #expect(o.criteria.roles == ["Owner", "Reader"])
        #expect(o.criteria.state == .active)
        #expect(o.tenant == "00000000-0000-0000-0000-0000000c0de0")
        #expect(o.json)
        guard case .list(let plain) = try command("list") else { Issue.record("expected list"); return }
        #expect(plain == ListOptions())
        guard case .list(let eligible) = try command("list", "--eligible", "-t", "contoso.onmicrosoft.com") else {
            Issue.record("expected list"); return
        }
        #expect(eligible.criteria.state == .eligible)
        #expect(eligible.tenant == "contoso.onmicrosoft.com")
    }

    @Test func activateCollectsEveryOption() throws {
        guard case .activate(let o) = try command(
            "activate", "prod", "--role", "Reader", "-j", "  INC-42 hotfix ", "--hours", "4", "-y", "--dry-run",
            "--max-parallel", "3", "--json", "-t", "contoso.onmicrosoft.com")
        else { Issue.record("expected activate"); return }
        #expect(o.criteria.filters == ["prod"])
        #expect(o.criteria.roles == ["Reader"])
        #expect(o.justification == "INC-42 hotfix")
        #expect(o.duration == .hours(4))
        #expect(o.assumeYes)
        #expect(o.dryRun)
        #expect(o.maxParallel == 3)
        #expect(o.json)
        #expect(!o.all)
        #expect(o.tenant == "contoso.onmicrosoft.com")

        guard case .activate(let defaults) = try command("activate", "--all", "--justification", "x") else {
            Issue.record("expected activate"); return
        }
        #expect(defaults.all)
        #expect(defaults.duration == nil)
        #expect(defaults.maxParallel == 8)
        #expect(!defaults.assumeYes && !defaults.dryRun && !defaults.json)
    }

    @Test func activateNeedsASelectionAndAJustification() {
        #expect(throws: CLIParseError.noSelection) { try CLIParser.parse(["activate", "-j", "x"]) }
        #expect(throws: CLIParseError.noSelection) { try CLIParser.parse(["activate", "-j", "x", "--yes", "--dry-run"]) }
        #expect(throws: CLIParseError.missingJustification) { try CLIParser.parse(["activate", "--all"]) }
        #expect(throws: CLIParseError.missingJustification) { try CLIParser.parse(["activate", "prod", "-j", "   "]) }
    }

    @Test func numbersAreValidated() {
        #expect(throws: CLIParseError.invalidHours("four")) {
            try CLIParser.parse(["activate", "--all", "-j", "x", "--hours", "four"])
        }
        #expect(throws: CLIParseError.outOfRange(flag: "--hours", value: 25, range: 1...24)) {
            try CLIParser.parse(["activate", "--all", "-j", "x", "--hours", "25"])
        }
        #expect(throws: CLIParseError.outOfRange(flag: "--max-parallel", value: 0, range: 1...16)) {
            try CLIParser.parse(["activate", "--all", "-j", "x", "--max-parallel", "0"])
        }
    }

    @Test func usageErrors() {
        #expect(throws: CLIParseError.unknownCommand("frobnicate")) { try CLIParser.parse(["frobnicate"]) }
        #expect(throws: CLIParseError.unknownCommand("nope")) { try CLIParser.parse(["help", "nope"]) }
        #expect(throws: CLIParseError.expectedCommand("--tenant")) { try CLIParser.parse(["--tenant", "x.example.com"]) }
        #expect(throws: CLIParseError.unknownOption("--frob", command: "list")) { try CLIParser.parse(["list", "--frob"]) }
        #expect(throws: CLIParseError.unknownOption("--all", command: "list")) { try CLIParser.parse(["list", "--all"]) }
        #expect(throws: CLIParseError.missingValue("--tenant")) { try CLIParser.parse(["list", "--tenant"]) }
        #expect(throws: CLIParseError.missingValue("-j")) { try CLIParser.parse(["activate", "--all", "-j", "--yes"]) }
        #expect(throws: CLIParseError.missingValue("--role")) { try CLIParser.parse(["list", "--role="]) }
        #expect(throws: CLIParseError.valueNotAllowed("--json")) { try CLIParser.parse(["list", "--json=yes"]) }
        #expect(throws: CLIParseError.conflicting("--active", "--eligible")) { try CLIParser.parse(["list", "--active", "--eligible"]) }
        #expect(throws: CLIParseError.unexpectedArgument("prod", command: "status")) { try CLIParser.parse(["status", "prod"]) }
        #expect(throws: CLIParseError.unexpectedArgument("x", command: "version")) { try CLIParser.parse(["version", "x"]) }
        for error in [CLIParseError.noSelection, .missingJustification, .unknownCommand("x")] {
            #expect(error.errorDescription?.isEmpty == false)
        }
    }

    @Test func doubleDashEndsOptions() throws {
        guard case .list(let o) = try command("list", "--", "--weird-name") else { Issue.record("expected list"); return }
        #expect(o.criteria.filters == ["--weird-name"])
    }

    @Test func completions() throws {
        #expect(try command("completions", "zsh") == .completions(.zsh))
        #expect(try command("completions", "fish") == .completions(.fish))
        #expect(throws: CLIParseError.missingShell) { try CLIParser.parse(["completions"]) }
        #expect(throws: CLIParseError.unknownShell("tcsh")) { try CLIParser.parse(["completions", "tcsh"]) }
        for shell in CompletionShell.allCases {
            let script = CLIHelp.completionScript(for: shell)
            for name in ["list", "activate", "status", "tenants", "justification", "dry-run", "max-parallel"] {
                #expect(script.contains(name), "\(shell) completion lacks \(name)")
            }
        }
    }

    @Test func everyCommandHasHelp() {
        for name in CLICommand.names {
            #expect(CLIHelp.text(for: name).contains("Usage: pimento"), "no help for \(name)")
        }
        #expect(CLIHelp.text(for: nil).contains("Exit codes"))
    }
}

@Suite("CLI legacy flags (0.1.0)")
struct CLILegacyTests {
    @Test func listAndTenantsMapToSubcommandsWithANote() throws {
        let list = try CLIParser.parse(["--list", "--tenant", "contoso.onmicrosoft.com"])
        var expected = ListOptions()
        expected.tenant = "contoso.onmicrosoft.com"
        #expect(list.command == .list(expected))
        #expect(list.deprecation?.contains("pimento list") == true)

        let tenants = try CLIParser.parse(["--tenants"])
        #expect(tenants.command == .tenants(TenantsOptions()))
        #expect(tenants.deprecation?.contains("pimento tenants") == true)
    }

    @Test func dryRunKeepsItsOldMeaning() throws {
        let call = try CLIParser.parse(["--dry-run", "-j", "INC-42", "--hours", "4", "--role", "owner", "prod"])
        guard case .activate(let o) = call.command else { Issue.record("expected activate"); return }
        #expect(o.dryRun)
        #expect(!o.assumeYes)
        // Substring match on the role, as in 0.1.0.
        #expect(o.criteria.roles == ["*owner*"])
        #expect(o.criteria.filters == ["prod"])
        #expect(o.duration == .hours(4))
        #expect(!o.all)
        #expect(call.deprecation?.contains("pimento activate --dry-run") == true)

        // Without filters, 0.1.0 planned every eligible role.
        guard case .activate(let all) = try CLIParser.parse(["--dry-run", "-j", "x", "-t", "x.example.com"]).command else {
            Issue.record("expected activate"); return
        }
        #expect(all.all)
        #expect(all.dryRun)
        #expect(all.criteria.filters.isEmpty)
        #expect(all.tenant == "x.example.com")
    }

    @Test func helpVersionAndConflicts() throws {
        #expect(try CLIParser.parse(["--list", "--help"]).command == .help(topic: "list"))
        #expect(try CLIParser.parse(["--dry-run", "-h"]).command == .help(topic: "activate"))
        #expect(try CLIParser.parse(["--version"]).deprecation == nil)
        #expect(throws: CLIParseError.self) { try CLIParser.parse(["--list", "--dry-run"]) }
    }

    @Test func appLaunchArgumentsOnlyCarryTheTenant() {
        #expect(LaunchArguments.tenant(in: ["-NSDocumentRevisionsDebugMode", "YES", "--tenant", "contoso.onmicrosoft.com"])
            == "contoso.onmicrosoft.com")
        #expect(LaunchArguments.tenant(in: ["--tenant=x.example.com"]) == "x.example.com")
        #expect(LaunchArguments.tenant(in: ["-t", "y.example.com"]) == "y.example.com")
        #expect(LaunchArguments.tenant(in: ["--tenant"]) == nil)
        #expect(LaunchArguments.tenant(in: []) == nil)
        #expect(LaunchArguments.isLegacyCLICall(["--list"]))
        #expect(LaunchArguments.isLegacyCLICall(["--tenant", "x.example.com", "--dry-run"]))
        #expect(!LaunchArguments.isLegacyCLICall(["--tenant", "x.example.com"]))
        #expect(!LaunchArguments.isLegacyCLICall(["-NSDocumentRevisionsDebugMode", "YES"]))
    }
}

@Suite("Role selection")
struct RoleCriteriaTests {
    func role(_ name: String, scope: String = "/subscriptions/s1", scopeName: String = "Contoso Production",
              active: Bool = false) -> EligibleRole {
        EligibleRole(id: "\(scope)|\(name)", eligibilityScheduleId: "e", roleDefinitionId: "/x/\(name)", roleName: name,
                     scope: scope, scopeName: scopeName, scopeType: "subscription", membership: .direct, isActive: active)
    }

    @Test func roleNamesMatchWholeAndCaseInsensitively() {
        #expect(RoleCriteria.glob("owner", matches: "Owner"))
        #expect(!RoleCriteria.glob("owner", matches: "Storage Blob Data Owner"))
        #expect(RoleCriteria.glob("*owner", matches: "Storage Blob Data Owner"))
        #expect(RoleCriteria.glob("*", matches: "Reader"))
        #expect(RoleCriteria.glob("key vault*officer", matches: "Key Vault Secrets Officer"))
        #expect(!RoleCriteria.glob("key vault*officer", matches: "Key Vault Reader"))
        #expect(!RoleCriteria.glob("read", matches: "Reader"))
        #expect(RoleCriteria.glob("*read*", matches: "Reader"))
    }

    @Test func filtersAreORedAndRolesNarrowThem() {
        let roles = [
            role("Owner"), role("Reader"),
            role("Contributor", scope: "/subscriptions/s2", scopeName: "Contoso Staging"),
            role("Owner", scope: "/subscriptions/s3/resourceGroups/rg-app", scopeName: "rg-app", active: true),
        ]
        #expect(RoleCriteria(filters: ["PROD", "staging"]).apply(roles).count == 3)
        #expect(RoleCriteria(filters: ["prod"], roles: ["owner"]).apply(roles).map(\.roleName) == ["Owner"])
        #expect(RoleCriteria(roles: ["owner"]).apply(roles).count == 2)
        #expect(RoleCriteria(roles: ["owner"], state: .eligible).apply(roles).count == 1)
        #expect(RoleCriteria(state: .active).apply(roles).map(\.scopeName) == ["rg-app"])
        #expect(RoleCriteria().apply(roles).count == 4)
        #expect(!RoleCriteria().hasSelection)
        #expect(RoleCriteria(roles: ["x"]).hasSelection)
    }

    @Test func scopeFiltersMatchTheScopeAndBelowIt() {
        let sub = role("Reader", scope: "/subscriptions/S3")
        let rg = role("Owner", scope: "/subscriptions/s3/resourceGroups/rg-app")
        let other = role("Owner", scope: "/subscriptions/s30")
        let c = RoleCriteria(filters: ["/subscriptions/s3/"])
        #expect(c.apply([sub, rg, other]).map(\.id) == [sub.id, rg.id])
        #expect(RoleCriteria(filters: ["/subscriptions/s3/resourcegroups/rg-app"]).apply([sub, rg]).map(\.id) == [rg.id])
    }
}
