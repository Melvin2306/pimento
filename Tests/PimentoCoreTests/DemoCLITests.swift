import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import PimentoCore

/// Records every use of the real (non-demo) dependencies a `--demo` command
/// must never touch.
final class TrapLog: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String] = []
    func record(_ what: String) { lock.withLock { entries.append(what) } }
    var all: [String] { lock.withLock { entries } }
}

/// A token store that only records: the demo must use its own, in memory.
struct TrapTokenStore: TokenStore {
    let log: TrapLog
    var label: String { "trap" }
    func accounts() throws -> [SignedInAccount] { log.record("accounts"); return [] }
    func refreshToken(for accountId: String) throws -> String? { log.record("refreshToken"); return nil }
    func save(_ account: SignedInAccount, refreshToken: String) throws { log.record("save") }
    func replaceRefreshToken(_ accountId: String, expected: String, with rotated: String) throws -> Bool {
        log.record("replaceRefreshToken"); return false
    }
    func remove(_ accountId: String) throws { log.record("remove") }
    func removeAll() throws { log.record("removeAll") }
}

/// A transport that only records.
struct TrapTransport: HTTPTransport {
    let log: TrapLog
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        log.record("send \(request.url?.absoluteString ?? "")")
        throw URLError(.notConnectedToInternet)
    }
}

/// `pimento` with real-looking but trapped dependencies: a demo command may
/// use none of them.
final class DemoCLIRun: @unchecked Sendable {
    let traps = TrapLog()
    let folder = TestTemp.url("demo-cli")
    let out = TestBox<String>("")
    let err = TestBox<String>("")
    let monitor = NetworkGuard.Monitor()
    var variables: [String: String]
    static let now = AzureDate.parse("2026-10-30T14:05:00Z")!

    init(variables: [String: String] = [:]) {
        // Real-looking settings the demo must ignore, and files it must not create.
        self.variables = [
            TenantResolver.environmentVariable: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee",
            AuthSourceResolver.environmentVariable: "pimento",
            PresetStore.environmentVariable: folder.appendingPathComponent("presets.json").path,
            HistoryStore.environmentVariable: folder.appendingPathComponent("history.jsonl").path,
            DemoMode.clockVariable: "10:30",
        ].merging(variables) { _, new in new }
    }

    var environment: CLIEnvironment {
        let traps = traps, out = out, err = err
        var env = CLIEnvironment(
            write: { text, stream in
                let box = stream == .out ? out : err
                box.value = (box.value ?? "") + text
            },
            readLine: { nil }, stdoutIsTTY: false, stderrIsTTY: false, stdinIsTTY: false, terminalWidth: nil,
            variables: variables, now: { DemoCLIRun.now }, timeZone: TimeZone(identifier: "UTC")!,
            makeService: { tokens, readOnly in
                traps.record("makeService")
                return PIMService(transport: TrapTransport(log: traps), tokens: tokens)
            },
            loadTenants: { _, _ in traps.record("loadTenants"); return [] },
            sleep: { _ in traps.record("sleep") },
            history: HistoryStore(url: folder.appendingPathComponent("history.jsonl")),
            signIn: CLISignIn(settings: AuthSettingsStore(url: folder.appendingPathComponent("auth.json")), store: TrapTokenStore(log: traps),
                              transport: TrapTransport(log: traps), openURL: { _ in traps.record("openURL"); return false }))
        env.azureCLITokens = { _ in traps.record("az"); return StaticTokenProvider() }
        return env
    }

    @discardableResult
    func run(_ args: String...) async -> Int32 {
        out.value = ""
        err.value = ""
        let env = environment
        return await NetworkGuard.$monitor.withValue(monitor) { await CLIRunner(environment: env).run(args) }
    }

    var stdout: String { out.value ?? "" }
    var stderr: String { err.value ?? "" }

    /// Nothing real was used, no file was created, nothing tried the network.
    func expectIsolated(sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(traps.all.isEmpty, "real dependencies used: \(traps.all)", sourceLocation: sourceLocation)
        #expect(!FileManager.default.fileExists(atPath: folder.path), "the real files were created", sourceLocation: sourceLocation)
        #expect(monitor.blocked.isEmpty, "tried the network: \(monitor.blocked)", sourceLocation: sourceLocation)
    }
}

@Suite("Demo: pimento --demo")
struct DemoCLITests {
    @Test func parsesTheGlobalFlagAnywhereBeforeDoubleDash() throws {
        #expect(try CLIParser.parse(["--demo", "list"]).demo)
        #expect(try CLIParser.parse(["list", "--demo", "--json"]).demo)
        #expect(try CLIParser.parse(["list", "--demo", "--json"]) == CLIInvocation(.list({
            var o = ListOptions()
            o.json = true
            return o
        }()), demo: true))
        let literal = try CLIParser.parse(["list", "--", "--demo"])
        #expect(!literal.demo)
        guard case .list(let o) = literal.command else { Issue.record("expected list"); return }
        #expect(o.criteria.filters == ["--demo"])
        #expect(CLIHelp.text(for: nil).contains("--demo"))
    }

    @Test func listAndStatusShowTheDemoRolesOnTheTidyClock() async {
        let cli = DemoCLIRun()
        #expect(await cli.run("--demo", "list") == 0)
        #expect(cli.stdout.contains("Contoso Production"))
        #expect(cli.stdout.contains("Group: sg-platform-oncall"))
        #expect(cli.stdout.contains("active until 10:38 (8m left)"))
        #expect(await cli.run("status", "--demo") == 0)
        #expect(cli.stdout.contains("13:10"))
        #expect(cli.stdout.contains("15:40"))
        cli.expectIsolated()
    }

    @Test func theEnvironmentVariableTurnsItOnToo() async {
        let cli = DemoCLIRun(variables: [DemoMode.environmentVariable: "1"])
        #expect(await cli.run("whoami") == 0)
        #expect(cli.stdout.contains("Alex Wilber <alex.wilber@contoso.example>"))
        #expect(cli.stdout.contains("Pimento sign-in"))
        cli.expectIsolated()
    }

    @Test func everyWriteCommandWorksAgainstTheSimulator() async throws {
        let cli = DemoCLIRun()
        #expect(await cli.run("--demo", "activate", "Contoso Staging", "--role", "Owner", "-j", "Rebuild", "-y") == 0)
        #expect(cli.stdout.contains("activated  Owner · Contoso Staging until 14:30"))
        #expect(await cli.run("--demo", "activate", "Contoso Production", "--role", "Owner", "-j", "Rotate", "-y") == 0)
        #expect(cli.stdout.contains("awaiting approval  Owner · Contoso Production"))
        #expect(await cli.run("--demo", "activate", "rg-contoso-data-prod", "--role", "Contributor", "-j", "Backfill", "-y") == 2)
        #expect(cli.stderr.contains("needs a ticket"))
        #expect(await cli.run("--demo", "activate", "Contoso Root", "-j", "Review", "--at", "tomorrow 08:00", "-y") == 0)
        #expect(cli.stdout.contains("scheduled  Reader · Contoso Root"))
        #expect(await cli.run("--demo", "deactivate", "Contoso Development", "-y") == 0)
        #expect(cli.stdout.contains("ended      Contributor · Contoso Development"))
        #expect(await cli.run("--demo", "renew", "Contoso Development", "-j", "Again", "-y") == 0)
        #expect(cli.stdout.contains("renewed    Contributor · Contoso Development until 18:30"))
        #expect(await cli.run("--demo", "extend", "--all", "-j", "Audit", "-y") == 0)
        #expect(cli.stdout.contains("PendingAdminDecision"))
        #expect(await cli.run("--demo", "cancel", "--all", "-y") == 0)
        #expect(cli.stdout.contains("cancelled  Contributor · Contoso Staging"))
        cli.expectIsolated()
    }

    @Test func idSelectsOneRoleWhereAScopeFilterMatchesSeveral() async throws {
        // What a launcher does: read `list --json`, pick one row, act on its id.
        let cli = DemoCLIRun()
        #expect(await cli.run("--demo", "list", "--json", "--role", "Contributor") == 0)
        let list = try #require(try JSONSerialization.jsonObject(with: Data(cli.stdout.utf8)) as? [String: Any])
        let roles = try #require(list["roles"] as? [[String: Any]])
        let staging = try #require(roles.first { $0["scopeName"] as? String == "Contoso Staging" })
        let id = try #require(staging["id"] as? String), scope = try #require(staging["scope"] as? String)
        #expect(roles.filter { $0["scope"] as? String == scope }.count == 1)
        // A scope filter also matches the roles below it: Contoso Production has
        // Contributor on two resource groups too.
        let prod = try #require(roles.first { $0["scopeName"] as? String == "Contoso Production" }?["scope"] as? String)
        #expect(await cli.run("--demo", "list", prod, "--role", "Contributor", "--json") == 0)
        let byScope = try #require(try JSONSerialization.jsonObject(with: Data(cli.stdout.utf8)) as? [String: Any])
        #expect(((byScope["roles"] as? [[String: Any]])?.count ?? 0) > 1)
        #expect(await cli.run("--demo", "list", "--id", id, "--json") == 0)
        let one = try #require(try JSONSerialization.jsonObject(with: Data(cli.stdout.utf8)) as? [String: Any])
        #expect((one["roles"] as? [[String: Any]])?.count == 1)
        #expect(await cli.run("--demo", "activate", "--id", id, "--justification=Release", "--hours", "2", "-y", "--json") == 0)
        let result = try #require(try JSONSerialization.jsonObject(with: Data(cli.stdout.utf8)) as? [String: Any])
        let results = try #require(result["results"] as? [[String: Any]])
        #expect(results.count == 1)
        #expect(results.first?["outcome"] as? String == "activated")
        #expect(((results.first?["role"] as? [String: Any])?["scopeName"] as? String) == "Contoso Staging")
        // Deactivate by the id of an active role from `status --json`.
        #expect(await cli.run("--demo", "status", "--json") == 0)
        let status = try #require(try JSONSerialization.jsonObject(with: Data(cli.stdout.utf8)) as? [String: Any])
        let dev = try #require((status["roles"] as? [[String: Any]])?.first { $0["scopeName"] as? String == "Contoso Development" })
        #expect(await cli.run("--demo", "deactivate", "--id", try #require(dev["id"] as? String), "-y") == 0)
        #expect(cli.stdout.contains("ended      Contributor · Contoso Development"))
        #expect(!cli.stdout.contains("Contoso Production"))
        cli.expectIsolated()
    }

    @Test func approverCommandsListApproveAndDeny() async throws {
        let cli = DemoCLIRun()
        #expect(await cli.run("--demo", "approvals", "--json") == 0)
        let data = Data(cli.stdout.utf8)
        let list = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let requests = try #require(list["requests"] as? [[String: Any]])
        #expect(requests.count == 2)
        let meganId = try #require(requests.first { ($0["requester"] as? [String: Any])?["name"] as? String == "Megan Bowen" }?["name"] as? String)
        // `--yes` decides whole request ids only.
        #expect(await cli.run("--demo", "approve", String(meganId.prefix(8)), "-j", "Planned", "-y") != 0)
        #expect(await cli.run("--demo", "approve", meganId, "-j", "Planned", "-y") == 0)
        #expect(cli.stdout.contains("approved   Owner · Contoso Production for Megan Bowen"))
        #expect(await cli.run("--demo", "approvals") == 0)
        #expect(cli.stdout.contains("Diego Siciliani"))
        cli.expectIsolated()
    }

    @Test func waitSeesTheSimulatedApproverDecideOnTheVirtualClock() async throws {
        // `wait` in its own command: the request it waits for is the seeded
        // demo state's, so ask for one first in the same session.
        let session = DemoSession(options: DemoOptions(), clock: DemoClock.manual(at: DemoCLIRun.now),
                                  workspace: DemoWorkspace.temporary(), timeZone: TimeZone(identifier: "UTC")!) { _ in }
        defer { session.workspace.remove() }
        try session.workspace.reset(now: DemoCLIRun.now)
        let cli = DemoCLIRun()
        var env = CLIEnvironment.demo(from: cli.environment, session: session)
        let clock = session.clock
        env.sleep = { clock.advance(by: $0) }
        let runner = CLIRunner(environment: env)
        let first = await NetworkGuard.$monitor.withValue(cli.monitor) {
            await runner.run(["activate", "Contoso Production", "--role", "Owner", "-j", "Rotate", "-y"])
        }
        #expect(first == 0)
        cli.out.value = ""
        let waited = await NetworkGuard.$monitor.withValue(cli.monitor) { await runner.run(["wait", "--all"]) }
        #expect(waited == 0)
        #expect(cli.stdout.contains("approved"))
        cli.expectIsolated()
    }

    @Test func readOnlyCommandsAndSignIn() async throws {
        let cli = DemoCLIRun()
        #expect(await cli.run("--demo", "tenants") == 0)
        #expect(cli.stdout.contains("Northwind Traders"))
        #expect(cli.stdout.contains("(unnamed)"))
        #expect(await cli.run("--demo", "presets") == 0)
        #expect(cli.stdout.contains("On-call"))
        #expect(cli.stdout.contains("Release day"))
        #expect(cli.stdout.contains("Data team"))
        #expect(await cli.run("--demo", "history", "--limit", "5") == 0)
        #expect(cli.stderr.contains("Showing the newest 5 of 44"), "\(cli.stderr)")
        #expect(await cli.run("--demo", "history", "--csv") == 0)
        #expect(cli.stdout.split(whereSeparator: \.isNewline).count == 45)
        #expect(await cli.run("--demo", "scheduled") == 0)
        #expect(cli.stdout.contains("Sat 08:00"))
        #expect(await cli.run("--demo", "login", "--device-code") == 0)
        #expect(cli.stderr.contains("DEMO-4821"))
        #expect(await cli.run("--demo", "list", "--tenant", "fabrikam.example") == 0)
        #expect(cli.stdout.contains("Fabrikam Analytics"))
        #expect(await cli.run("--demo", "activate", "--all", "--dry-run", "-j", "Look", "--ticket", "CHG-1", "--ticket-system", "ServiceNow") == 0)
        #expect(cli.stdout.contains("Dry run"))
        cli.expectIsolated()
    }

    @Test func savingAPresetChangesOnlyTheDemoFolder() async throws {
        let cli = DemoCLIRun()
        #expect(await cli.run("--demo", "presets", "save", "Mine", "Contoso Root", "-j", "x") == 0)
        #expect(cli.stdout.contains("Mine"))
        cli.expectIsolated()
    }
}
