import Foundation
import Testing
@testable import PimentoCore

@Suite("CLI: pimento keep-alive")
struct CLIKeepAliveTests {
    func command(_ args: String...) throws -> CLICommand { try CLIParser.parse(args).command }

    @Test func parsesSelectionDaysAndWindow() throws {
        guard case .keepAlive(let o) = try command("keep-alive", "contoso-dev", "--role", "Contributor", "--days", "mon-thu",
                                                   "--window", "07:30-19:00", "--hours", "4", "-j", "On call", "-y") else {
            Issue.record("expected keep-alive")
            return
        }
        #expect(o.criteria.filters == ["contoso-dev"])
        #expect(o.criteria.roles == ["Contributor"])
        #expect(o.hours == WorkingHours(days: [2, 3, 4, 5], start: ClockTime(hour: 7, minute: 30), end: ClockTime(hour: 19, minute: 0)))
        #expect(o.duration == .hours(4))
        #expect(o.justification == "On call")
        #expect(o.assumeYes)
        guard case .keepAlive(let defaults) = try command("keep-alive", "--all") else { Issue.record("expected keep-alive"); return }
        #expect(defaults.hours == WorkingHours())
        #expect(defaults.duration == nil)
    }

    @Test func refusesUnreadableOrMissingInput() {
        #expect(throws: CLIParseError.invalidDays("someday")) { try CLIParser.parse(["keep-alive", "--all", "--days", "someday"]) }
        #expect(throws: CLIParseError.invalidWindow("8am")) { try CLIParser.parse(["keep-alive", "--all", "--window", "8am"]) }
        #expect(throws: CLIParseError.noActiveSelection("keep-alive")) { try CLIParser.parse(["keep-alive"]) }
        #expect(throws: CLIParseError.conflicting("--preset", "filters, --role or --all")) {
            try CLIParser.parse(["keep-alive", "--preset", "On-call", "--all"])
        }
        #expect(throws: CLIParseError.unknownOption("--json", command: "keep-alive")) { try CLIParser.parse(["keep-alive", "--all", "--json"]) }
        #expect(CLIParseError.noActiveSelection("keep-alive").localizedDescription.contains("which roles to keep alive"))
    }

    @Test func hasHelpAndCompletions() {
        #expect(CLIHelp.text(for: "keep-alive").contains("Usage: pimento keep-alive"))
        #expect(CLIHelp.text(for: nil).contains("keep-alive"))
        for shell in CompletionShell.allCases {
            #expect(CLIHelp.completionScript(for: shell).contains("keep-alive"), "\(shell)")
        }
    }

    @Test func refusesToRunUnattendedWithoutYes() async {
        let cli = DemoCLIRun()
        #expect(await cli.run("--demo", "keep-alive", "--all") == 2)
        #expect(cli.stderr.contains("Refusing to keep-alive without confirmation"))
    }

    @Test func aDryRunShowsThePlanAndSendsNothing() async {
        let cli = DemoCLIRun()
        #expect(await cli.run("--demo", "keep-alive", "kv-contoso-prod", "--dry-run") == 0)
        #expect(cli.stdout.contains("Would keep 1 role alive"))
        #expect(cli.stdout.contains("Mon–Fri 08:00–18:00"))
        #expect(cli.stdout.contains("continuing it at 10:38"))
        #expect(cli.stdout.contains("Dry run: nothing sent."))
        cli.expectIsolated()
    }

    @Test func itContinuesRolesAgainstTheSimulator() async {
        let cli = DemoCLIRun()
        var o = KeepAliveOptions()
        o.criteria.filters = ["kv-contoso-prod", "Contoso Production"]
        o.assumeYes = true
        o.maxPasses = 3
        let env = cli.environment
        let code = await NetworkGuard.$monitor.withValue(cli.monitor) {
            await CLIRunner(environment: env).runDemo(CLIInvocation(.keepAlive(o), demo: true))
        }
        #expect(code == 0)
        let out = cli.stdout
        // Key Vault Secrets User ends at 10:38 (1-hour policy, ticket from its request): continued without a gap.
        #expect(out.contains("renewed  Key Vault Secrets User · kv-contoso-prod until 11:38: continues at 10:38, no gap"))
        // Owner on Contoso Production needs approval: left alone.
        #expect(out.contains("Owner · Contoso Production: not possible: its policy requires approval"))
        // Contributor on Contoso Production (ends 13:10) waits for its turn.
        #expect(out.contains("Contributor · Contoso Production: renews at 12:55"))
        // The next pass sees the continuation active.
        #expect(out.contains("Key Vault Secrets User · kv-contoso-prod: renews at 11:23"))
        cli.expectIsolated()
    }
}

@Suite("CLI: pimento keep-alive and roles that grant access")
struct CLIKeepAliveConsentTests {
    @Test func thePromptNamesRolesThatGrantAccessAndNoSendsNothing() async {
        let cli = DemoCLIRun()
        var env = cli.environment
        env.stdinIsTTY = true
        env.readLine = { "n" }
        let o: KeepAliveOptions = {
            var o = KeepAliveOptions()
            o.criteria.filters = ["Contoso Staging"]
            o.maxPasses = 1
            return o
        }()
        let code = await NetworkGuard.$monitor.withValue(cli.monitor) {
            await CLIRunner(environment: env).runDemo(CLIInvocation(.keepAlive(o), demo: true))
        }
        #expect(code == 1)
        #expect(cli.stdout.contains("can grant access to anyone on the resource"))
        #expect(cli.stdout.contains("Owner (!)"))
        #expect(cli.stdout.contains("User Access Administrator (!)"))
        #expect(cli.stderr.contains("that can grant access until you stop it (Ctrl-C)? [y/N]"))
        #expect(cli.stderr.contains("Cancelled. Nothing was sent."))
        #expect(CLIHelp.text(for: "keep-alive").contains("only when confirmed"))
        cli.expectIsolated()
    }
}
