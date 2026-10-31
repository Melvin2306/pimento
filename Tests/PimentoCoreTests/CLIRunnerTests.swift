import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import PimentoCore

/// Drives `CLIRunner` against the fixtures. Activations go to a fake transport:
/// no test talks to Azure.
final class CLIHarness: @unchecked Sendable {
    private let lock = NSLock()
    private var outText = ""
    private var errText = ""
    private var answers: [String]
    let transport: RecordingTransport
    var stdinIsTTY = false
    var stdoutIsTTY = false
    var width: Int?
    var variables: [String: String]
    private var clockValue = Fixture.now
    /// The harness's clock; `sleep` (for `wait`) moves it forward.
    var now: Date {
        get { lock.withLock { clockValue } }
        set { lock.withLock { clockValue = newValue } }
    }
    /// Every `sleep` the command asked for, in seconds.
    var sleeps: [TimeInterval] { lock.withLock { sleepLog } }
    private var sleepLog: [TimeInterval] = []
    var tokens: TokenProvider = StaticTokenProvider()
    var tenants: [TenantInfo] = []
    /// Pimento sign-in: an in-memory token store, a temporary settings file,
    /// a fake token endpoint (offline unless set) and a fake browser.
    let tokenStore = InMemoryTokenStore()
    let authSettings = AuthSettingsStore(url: temporaryPresetsURL().deletingLastPathComponent().appendingPathComponent("auth.json"))
    var signInTransport: HTTPTransport = OfflineTransport()
    var openURL: @Sendable (URL) async -> Bool = { _ in false }
    /// How often `login` said a browser sign-in was over.
    let browserSignInsEnded = TestBox<Int>(0)
    /// Whether `login` may use the browser.
    var browserSignIn = LoopbackListener.isSupported
    /// Use the tokens of the auth source (`--auth`) instead of `tokens`.
    var useAuthTokens = false
    /// The token providers the commands asked for, in order.
    let givenTokens = TestBox<[TokenProvider]>([])
    /// The preferred tenant each `loadTenants` was given.
    let givenPreferredTenants = TestBox<[String?]>([])

    /// Policy maxima the fake ARM returns, by role GUID: Owner 2 h (with
    /// approval), Contributor 4 h, anything else 8 h.
    static let policyMaxima = [
        EligibleRole.ownerRoleGUID: "PT2H",
        "b24988ac-6180-42a0-ab88-20f7382dd24c": "PT4H",
    ]

    static func defaultPolicy(_ request: URLRequest) throws -> (Data, Int) {
        guard let guid = filteredRoleGUID(request) else { return (Data(), 400) }
        return (policyResponse(roleGUID: guid, maxDuration: policyMaxima[guid] ?? "PT8H", approval: guid == EligibleRole.ownerRoleGUID), 200)
    }

    /// Each harness gets its own presets file, so no test touches the real one.
    let presetsURL = temporaryPresetsURL()
    /// … and its own history file.
    let historyStore = HistoryStore(url: temporaryHistoryURL())

    private var policyHandler: @Sendable (URLRequest) throws -> (Data, Int) = CLIHarness.defaultPolicy
    private var postHandler: @Sendable (URLRequest) throws -> (Data, Int) = { _ in (Data(), 200) }
    private var getHandler: (@Sendable (URLRequest) throws -> (Data, Int)?)?
    private var patchHandler: @Sendable (URLRequest) throws -> (Data, Int) = { _ in (Data(), 200) }
    /// How the fake ARM answers PATCHes (approval decisions; default: 200).
    var patch: @Sendable (URLRequest) throws -> (Data, Int) {
        get { lock.withLock { patchHandler } }
        set { lock.withLock { patchHandler = newValue } }
    }
    /// Answers GETs before the fixtures when it returns something (nil: fixtures).
    var get: (@Sendable (URLRequest) throws -> (Data, Int)?)? {
        get { lock.withLock { getHandler } }
        set { lock.withLock { getHandler = newValue } }
    }
    /// How the fake ARM answers POSTs (cancel; default: 200).
    var post: @Sendable (URLRequest) throws -> (Data, Int) {
        get { lock.withLock { postHandler } }
        set { lock.withLock { postHandler = newValue } }
    }
    /// How the fake ARM answers policy GETs (default: `defaultPolicy`).
    var policy: @Sendable (URLRequest) throws -> (Data, Int) {
        get { lock.withLock { policyHandler } }
        set { lock.withLock { policyHandler = newValue } }
    }

    init(answers: [String] = [], put: @escaping @Sendable (URLRequest) throws -> (Data, Int) = { _ in
        (try Fixture.data("success-response"), 201)
    }) {
        self.answers = answers
        variables = [PresetStore.environmentVariable: presetsURL.path]
        weak var weakSelf: CLIHarness?
        transport = RecordingTransport { request in
            if request.httpMethod == "PUT" { return try put(request) }
            if request.httpMethod == "POST" { return try weakSelf?.post(request) ?? (Data(), 200) }
            if request.httpMethod == "PATCH" { return try weakSelf?.patch(request) ?? (Data(), 200) }
            if let answer = try weakSelf?.get?(request) { return answer }
            let path = request.url!.absoluteString
            if path.contains("roleAssignmentApprovals/"), path.contains("/stages") { return (try Fixture.data("approval-stages"), 200) }
            if path.contains("roleAssignmentApprovals?") { return (try Fixture.data("approvals"), 200) }
            if path.contains("roleAssignmentScheduleRequests?"), path.contains("asApprover()") { return (try Fixture.data("approver-requests"), 200) }
            if request.url!.path.hasSuffix("roleManagementPolicyAssignments") {
                return try (weakSelf?.policy ?? CLIHarness.defaultPolicy)(request)
            }
            let url = request.url!.absoluteString
            if url.contains("roleEligibilityScheduleInstances") { return (try Fixture.data("eligibilities"), 200) }
            if url.contains("roleAssignmentScheduleInstances") { return (try Fixture.data("assignments"), 200) }
            if url.contains("roleAssignmentScheduleRequests?") { return (try Fixture.data("schedule-requests"), 200) }
            return (Data(), 404)
        }
        weakSelf = self
    }

    var out: String { lock.withLock { outText } }
    var err: String { lock.withLock { errText } }

    var puts: [URLRequest] { get async { await transport.requests.filter { $0.httpMethod == "PUT" } } }
    var posts: [URLRequest] { get async { await transport.requests.filter { $0.httpMethod == "POST" } } }

    func environment() -> CLIEnvironment {
        let transport = transport, tokens = tokens, tenants = tenants
        return CLIEnvironment(
            write: { [self] text, stream in
                lock.withLock { if stream == .out { outText += text } else { errText += text } }
            },
            readLine: { [self] in lock.withLock { answers.isEmpty ? nil : answers.removeFirst() } },
            stdoutIsTTY: stdoutIsTTY, stderrIsTTY: stdoutIsTTY, stdinIsTTY: stdinIsTTY,
            terminalWidth: width, variables: variables,
            now: { [self] in now }, timeZone: TimeZone(identifier: "UTC")!,
            makeService: { [self] given, readOnly in
                givenTokens.value = (givenTokens.value ?? []) + [given]
                return CLIEnvironment.liveService(tokens: useAuthTokens ? given : tokens, readOnly: readOnly, base: transport)
            },
            loadTenants: { [self] preferred, given in
                givenPreferredTenants.value = (givenPreferredTenants.value ?? []) + [preferred]
                if let given { givenTokens.value = (givenTokens.value ?? []) + [given] }
                return tenants
            },
            sleep: { [self] seconds in
                lock.withLock {
                    sleepLog.append(seconds)
                    clockValue = clockValue.addingTimeInterval(seconds)
                }
            },
            history: historyStore,
            signIn: CLISignIn(settings: authSettings, store: tokenStore, transport: signInTransport, openURL: openURL,
                              browserSignIn: browserSignIn,
                              endBrowserSignIn: { [browserSignInsEnded] in browserSignInsEnded.value = (browserSignInsEnded.value ?? 0) + 1 }))
    }

    @discardableResult
    func run(_ args: String...) async -> Int32 {
        await run(args)
    }

    @discardableResult
    func run(_ args: [String]) async -> Int32 {
        await CLIRunner(environment: environment()).run(args)
    }
}

struct FailingTokens: TokenProvider {
    var error: Error = AzureCLIError.failed("AADSTS70043: The refresh token has expired")
    func accessToken() async throws -> String { throw error }
}

@Suite("CLI commands")
struct CLIRunnerTests {
    @Test func listPipedPrintsPlainAlignedRows() async throws {
        let h = CLIHarness()
        #expect(await h.run("list") == 0)
        let lines = h.out.split(separator: "\n").map(String.init)
        #expect(lines.count == 5)
        #expect(lines[0].hasPrefix("RESOURCE"))
        #expect(lines[0].contains("COND"))
        #expect(!h.out.contains("\u{1B}["))
        #expect(!h.out.contains("Signed in"))
        #expect(lines.allSatisfy { !$0.hasSuffix(" ") })
        // Columns line up: ROLE starts at the same offset in every row.
        let roleColumn = lines[0].range(of: "ROLE")!.lowerBound.utf16Offset(in: lines[0])
        #expect(lines.dropFirst().allSatisfy { $0.count > roleColumn && $0[$0.index($0.startIndex, offsetBy: roleColumn - 1)] == " " })
        #expect(lines.contains { $0.contains("Contoso Production") && $0.contains("active until 18:42 (6h 42m left)") })
        #expect(lines.contains { $0.contains("Contoso Staging") && $0.hasSuffix("eligible") })
        #expect(await h.puts.isEmpty)
    }

    @Test func listOnATerminalAddsColourAndContext() async {
        let h = CLIHarness()
        h.stdoutIsTTY = true
        #expect(await h.run("list", "--eligible") == 0)
        #expect(h.out.contains("Signed in as Test User <test@example.com>"))
        #expect(h.out.contains("\u{1B}["))
        #expect(h.out.contains("2 roles, 0 active"))

        let plain = CLIHarness()
        plain.stdoutIsTTY = true
        plain.variables = ["NO_COLOR": "1"]
        #expect(await plain.run("list") == 0)
        #expect(!plain.out.contains("\u{1B}["))
    }

    @Test func listFiltersAndJSON() async throws {
        let h = CLIHarness()
        #expect(await h.run("list", "--json", "--role", "owner") == 0)
        let doc = try #require(try JSONSerialization.jsonObject(with: Data(h.out.utf8)) as? [String: Any])
        #expect(Set(doc.keys) == ["roles", "user"])
        let user = try #require(doc["user"] as? [String: Any])
        #expect(user["objectId"] as? String == Fixture.userOID)
        let roles = try #require(doc["roles"] as? [[String: Any]])
        #expect(roles.count == 2)
        let first = roles[0]
        #expect(first["roleName"] as? String == "Owner")
        #expect(first["isOwner"] as? Bool == true)
        #expect(first["grantsAccess"] as? Bool == true)
        #expect(first["isActive"] as? Bool == true)
        #expect(first["activeUntil"] as? String == "2026-10-29T18:42:17.913Z")
        #expect(first["membership"] as? String == "direct")
        #expect(first["secondsLeft"] == nil)
        for key in ["id", "scope", "scopeName", "scopeType", "roleDefinitionId", "eligibilityScheduleId", "hasCondition"] {
            #expect(first[key] != nil, "missing \(key)")
        }
    }

    @Test func statusListsActiveRolesSoonestFirst() async throws {
        let h = CLIHarness()
        #expect(await h.run("status") == 0)
        let lines = h.out.split(separator: "\n").map(String.init)
        #expect(lines.count == 3)
        #expect(lines[0].hasPrefix("LEFT"))
        #expect(lines[1].hasPrefix("6h 42m") && lines[1].contains("Contoso Production"))
        #expect(lines[2].hasPrefix("8h 00m") && lines[2].contains("rg-app-dev"))

        let json = CLIHarness()
        #expect(await json.run("status", "--json") == 0)
        let doc = try #require(try JSONSerialization.jsonObject(with: Data(json.out.utf8)) as? [String: Any])
        let roles = try #require(doc["roles"] as? [[String: Any]])
        #expect(roles.map { $0["secondsLeft"] as? Int } == [6 * 3600 + 42 * 60 + 17, 8 * 3600])

        let later = CLIHarness()
        later.now = AzureDate.parse("2026-10-29T21:00:00Z")!
        #expect(await later.run("status") == 0)
        #expect(later.out == "No active roles.\n")
    }

    @Test func tenantsTableAndJSON() async throws {
        let h = CLIHarness()
        h.tenants = [
            TenantInfo(id: "00000000-0000-0000-0000-0000000c0de0", displayName: "Contoso", defaultDomain: "contoso.onmicrosoft.com"),
            TenantInfo(id: "00000000-0000-0000-0000-00000fab41c0"),
        ]
        #expect(await h.run("tenants") == 0)
        #expect(h.out.contains("00000000-0000-0000-0000-0000000c0de0  Contoso    contoso.onmicrosoft.com"))
        #expect(h.out.contains("(unnamed)"))

        let json = CLIHarness()
        json.tenants = h.tenants
        #expect(await json.run("tenants", "--json") == 0)
        let doc = try #require(try JSONSerialization.jsonObject(with: Data(json.out.utf8)) as? [String: [[String: Any]]])
        #expect(doc["tenants"]?.first?["displayName"] as? String == "Contoso")
        #expect(doc["tenants"]?.last?["displayName"] == nil)

        // No tenants: an answer, exit 0 in both modes; the table says why on stderr.
        let none = CLIHarness()
        #expect(await none.run("tenants") == 0)
        #expect(none.out.isEmpty)
        #expect(none.err.contains("note: no tenants") && none.err.contains("az login"))
        let noneJSON = CLIHarness()
        #expect(await noneJSON.run("tenants", "--json") == 0)
        let empty = try #require(try JSONSerialization.jsonObject(with: Data(noneJSON.out.utf8)) as? [String: [Any]])
        #expect(empty["tenants"]?.isEmpty == true)
        #expect(noneJSON.err.isEmpty)
        let pimento = CLIHarness()
        #expect(await pimento.run("tenants", "--auth", "pimento") == 0)
        #expect(pimento.err.contains("pimento login") && !pimento.err.contains("az login"))

        // The tenant is --tenant, else $PIMENTO_TENANT, as the README says.
        let env = CLIHarness()
        env.variables[TenantResolver.environmentVariable] = "contoso.onmicrosoft.com"
        _ = await env.run("tenants")
        _ = await env.run("tenants", "-t", "fabrikam.onmicrosoft.com")
        #expect(env.givenPreferredTenants.value == ["contoso.onmicrosoft.com", "fabrikam.onmicrosoft.com"])
    }

    // MARK: activate safety

    @Test func activateWithoutSelectionIsAUsageError() async {
        let h = CLIHarness()
        h.stdinIsTTY = true
        #expect(await h.run("activate", "-j", "x", "--yes") == 2)
        #expect(h.err.contains("--all"))
        #expect(await h.transport.requests.isEmpty)
    }

    @Test func activateRefusesNonInteractivelyWithoutYes() async {
        let h = CLIHarness()
        #expect(await h.run("activate", "--role", "Reader", "-j", "x") == 2)
        #expect(h.err.contains("--yes"))
        // Stops before touching Azure at all.
        #expect(await h.transport.requests.isEmpty)
    }

    @Test func dryRunPrintsRequestsAndSendsNothing() async {
        let h = CLIHarness()
        #expect(await h.run("activate", "--all", "-j", "INC-42", "--hours", "2", "--dry-run") == 0)
        #expect(h.out.contains("PUT https://management.azure.com/subscriptions/aaaaaaaa-0000-0000-0000-00000000000a/providers/Microsoft.Authorization/roleAssignmentScheduleRequests/"))
        #expect(h.out.contains(#""duration" : "PT2H""#))
        #expect(h.out.contains("Dry run: 2 requests built, none sent."))
        #expect(h.out.contains("skip  Owner · Contoso Production: already active until 18:42"))
        #expect(await h.puts.isEmpty)
        #expect(await h.transport.requests.allSatisfy { $0.httpMethod == "GET" })
    }

    @Test func dryRunJSONHasThePlannedRequests() async throws {
        let h = CLIHarness()
        #expect(await h.run("activate", "--role", "reader", "-j", "x", "--dry-run", "--json") == 0)
        let doc = try #require(try JSONSerialization.jsonObject(with: Data(h.out.utf8)) as? [String: Any])
        #expect(doc["dryRun"] as? Bool == true)
        #expect(doc["hours"] as? Int == 8)
        let results = try #require(doc["results"] as? [[String: Any]])
        #expect(results.count == 1)
        #expect(results[0]["outcome"] as? String == "planned")
        let request = try #require(results[0]["request"] as? [String: Any])
        #expect(request["method"] as? String == "PUT")
        let body = try #require(request["body"] as? [String: Any])
        let props = try #require(body["properties"] as? [String: Any])
        #expect(props["requestType"] as? String == "SelfActivate")
        #expect(props["principalId"] as? String == Fixture.userOID)
        #expect((doc["summary"] as? [String: Int])?["planned"] == 1)
        // The plan goes to stderr so stdout stays pure JSON.
        #expect(h.err.contains("Would activate 1 role"))
        #expect(await h.puts.isEmpty)
    }

    @Test func yesActivatesThroughTheFakeTransport() async {
        let h = CLIHarness()
        #expect(await h.run("activate", "--role", "Reader", "-j", "INC-42", "--hours", "4", "--yes") == 0)
        let puts = await h.puts
        #expect(puts.count == 1)
        #expect(puts[0].url?.host == "management.azure.com")
        #expect(h.out.contains("activated  Reader · Contoso Production until 16:00"))
        #expect(h.out.contains("1 activated."))
    }

    @Test func promptOnATerminalHonoursTheAnswer() async {
        let no = CLIHarness(answers: ["n"])
        no.stdinIsTTY = true
        #expect(await no.run("activate", "Staging", "-j", "x") == 1)
        #expect(no.err.contains("Activate 1 role? [y/N]"))
        #expect(no.err.contains("Nothing was sent"))
        #expect(await no.puts.isEmpty)

        let eof = CLIHarness(answers: [])
        eof.stdinIsTTY = true
        #expect(await eof.run("activate", "Staging", "-j", "x") == 1)
        #expect(await eof.puts.isEmpty)

        let yes = CLIHarness(answers: ["YES"])
        yes.stdinIsTTY = true
        #expect(await yes.run("activate", "Staging", "-j", "x") == 0)
        #expect(await yes.puts.count == 1)
    }

    @Test func ownerRolesAreHighlightedInThePlanAndPrompt() async {
        let h = CLIHarness(answers: ["n"])
        h.stdinIsTTY = true
        h.now = AzureDate.parse("2026-10-29T19:00:00Z")!  // the Contoso Owner activation has ended
        #expect(await h.run("activate", "--role", "owner", "-j", "x") == 1)
        #expect(h.out.contains("Owner (!)"))
        #expect(h.out.contains("Warning: 1 Owner role (!)"))
        #expect(h.err.contains("including 1 Owner? [y/N]"))
        #expect(await h.puts.isEmpty)
    }

    @Test func nothingToActivateWhenEverythingMatchingIsActive() async {
        let h = CLIHarness()
        #expect(await h.run("activate", "--role", "owner", "-j", "x", "--yes") == 0)
        #expect(h.out.contains("Nothing to activate: all 2 matching roles are already active."))
        #expect(await h.puts.isEmpty)

        let none = CLIHarness()
        #expect(await none.run("activate", "no-such-resource", "-j", "x", "--yes") == 1)
        #expect(await none.puts.isEmpty)
    }

    @Test func exitCodesFollowTheOutcomes() async throws {
        let policy = CLIHarness { _ in (try Fixture.data("error-policy"), 400) }
        #expect(await policy.run("activate", "--all", "-j", "x", "--yes") == 1)
        #expect(policy.out.contains("failed"))
        #expect(policy.out.contains("2 failed"))

        let token = CLIHarness { _ in (try Fixture.data("error-token"), 401) }
        #expect(await token.run("activate", "--all", "-j", "x", "--yes") == 3)
        #expect(token.err.contains("az login"))

        let exists = CLIHarness { _ in (try Fixture.data("error-exists"), 400) }
        #expect(await exists.run("activate", "--all", "-j", "x", "--yes", "--json") == 0)
        let doc = try #require(try JSONSerialization.jsonObject(with: Data(exists.out.utf8)) as? [String: Any])
        // 2 already active at load time + 2 that ARM says are active.
        #expect((doc["summary"] as? [String: Int])?["skipped"] == 4)
        #expect((doc["results"] as? [[String: Any]])?.count == 4)
    }

    @Test func authAndUsageErrors() async {
        let h = CLIHarness()
        h.tokens = FailingTokens()
        #expect(await h.run("list") == 3)
        #expect(h.err.contains("AADSTS70043"))
        #expect(h.err.contains("hint: sign in with `az login`"))

        let tenant = CLIHarness()
        tenant.tokens = FailingTokens()
        #expect(await tenant.run("status", "--tenant", "contoso.onmicrosoft.com") == 3)
        #expect(tenant.err.contains("az login --tenant contoso.onmicrosoft.com"))

        let usage = CLIHarness()
        #expect(await usage.run("list", "--bogus") == 2)
        #expect(await usage.run("list", "--tenant", "not a tenant") == 2)
        #expect(await usage.transport.requests.isEmpty)

        let env = CLIHarness()
        env.variables = [TenantResolver.environmentVariable: "bad value"]
        #expect(await env.run("list") == 2)
    }

    @Test func deprecatedFlagsStillWorkWithANote() async {
        let h = CLIHarness()
        #expect(await h.run("--list") == 0)
        #expect(h.err.contains("note: `pimento --list` is deprecated"))
        #expect(h.out.hasPrefix("RESOURCE"))

        let dry = CLIHarness()
        #expect(await dry.run("--dry-run", "-j", "x", "--role", "own") == 0)
        #expect(dry.out.contains("Nothing to activate"))
        #expect(await dry.puts.isEmpty)
    }

    @Test func versionHelpAndCompletions() async {
        let h = CLIHarness()
        #expect(await h.run("version") == 0)
        #expect(h.out == "pimento \(AppInfo.version)\n")
        let help = CLIHarness()
        #expect(await help.run() == 0)
        #expect(help.out.contains("Commands:"))
        let zsh = CLIHarness()
        #expect(await zsh.run("completions", "zsh") == 0)
        #expect(zsh.out.hasPrefix("#compdef pimento"))
    }
}

@Suite("CLI policy and formatting")
struct CLIPolicyTests {
    @Test func confirmationPolicy() {
        #expect(ConfirmationPolicy.decide(dryRun: true, assumeYes: false, interactive: false) == .proceed)
        #expect(ConfirmationPolicy.decide(dryRun: false, assumeYes: true, interactive: false) == .proceed)
        #expect(ConfirmationPolicy.decide(dryRun: false, assumeYes: false, interactive: true) == .ask)
        #expect(ConfirmationPolicy.decide(dryRun: false, assumeYes: false, interactive: false) == .refuse)
        #expect(ConfirmationPolicy.isYes(" y\n"))
        #expect(ConfirmationPolicy.isYes("Yes"))
        #expect(!ConfirmationPolicy.isYes("yep"))
        #expect(!ConfirmationPolicy.isYes(""))
        #expect(!ConfirmationPolicy.isYes(nil))
    }

    @Test func exitCodeForErrors() {
        #expect(CLIExit.code(for: CLIParseError.noSelection) == .usage)
        #expect(CLIExit.code(for: TenantError.invalid("x")) == .usage)
        #expect(CLIExit.code(for: ConfirmationRequired()) == .usage)
        #expect(CLIExit.code(for: ActivationRequestError.invalidDuration(30)) == .usage)
        #expect(CLIExit.code(for: ActivationRequestError.missingPrincipal) == .auth)
        #expect(CLIExit.code(for: AzureCLIError.notFound) == .auth)
        #expect(CLIExit.code(for: AzureCLIError.failed("x")) == .auth)
        #expect(CLIExit.code(for: PIMServiceError.noIdentity) == .auth)
        #expect(CLIExit.code(for: PIMServiceError.http(401, "")) == .auth)
        #expect(CLIExit.code(for: PIMServiceError.http(400, "ExpiredAuthenticationToken: old")) == .auth)
        #expect(CLIExit.code(for: PIMServiceError.http(403, "AuthorizationFailed")) == .failure)
        #expect(CLIExit.code(for: ReadOnlyTransport.WriteRefused(method: "PUT")) == .failure)
    }

    @Test func exitCodeForOutcomes() {
        let ok = ActivationOutcome.activated(status: "Provisioned", until: nil)
        let token = ActivationOutcome.failed(code: "InvalidAuthenticationToken", message: "")
        let policy = ActivationOutcome.policyViolation(rules: ["MfaRule"], message: "")
        #expect(CLIExit.code(for: []) == .success)
        #expect(CLIExit.code(for: [ok, .alreadyActive]) == .success)
        #expect(CLIExit.code(for: [ok, policy]) == .failure)
        #expect(CLIExit.code(for: [ok, token]) == .auth)
        #expect(CLIExit.code(for: [token, policy]) == .failure)
    }

    @Test func colourOnlyOnATerminalWithoutNoColor() {
        #expect(TerminalStyle.detect(isTTY: true, environment: [:]).colors)
        #expect(!TerminalStyle.detect(isTTY: false, environment: [:]).colors)
        #expect(!TerminalStyle.detect(isTTY: true, environment: ["NO_COLOR": "1"]).colors)
        #expect(TerminalStyle.detect(isTTY: true, environment: ["NO_COLOR": ""]).colors)
        #expect(!TerminalStyle.detect(isTTY: true, environment: ["TERM": "dumb"]).colors)
        #expect(TerminalStyle(colors: false).red("x") == "x")
        #expect(TerminalStyle(colors: true).red("x") == "\u{1B}[31mx\u{1B}[0m")
    }

    @Test func tableAlignsAndFitsTheTerminal() {
        var table = TextTable(headers: ["NAME", "ROLE", "STATUS"], flexible: [0])
        table.append([.init("Contoso Production Subscription"), .init("Owner", .strong), .init("eligible", .dim)])
        table.append([.init("rg-app"), .init("Reader"), .init("active")])
        let plain = table.render(style: TerminalStyle(colors: false))
        #expect(plain == [
            "NAME                             ROLE    STATUS",
            "Contoso Production Subscription  Owner   eligible",
            "rg-app                           Reader  active",
        ])
        let narrow = table.render(style: TerminalStyle(colors: false), maxWidth: 34)
        #expect(narrow[1] == "Contoso Product…  Owner   eligible")
        #expect(narrow.allSatisfy { $0.count <= 34 })
        // Never below the minimum width, even when the terminal is tiny.
        #expect(table.widths(maxWidth: 5)[0] == TextTable.minFlexibleWidth)
        // Colour wraps the text, not the padding.
        let coloured = table.render(style: TerminalStyle(colors: true))
        #expect(coloured[1].contains("\u{1B}[1;31mOwner\u{1B}[0m   "))
    }

    @Test func timeFormatting() {
        let now = Fixture.now
        #expect(CLIFormat.timeLeft(until: now.addingTimeInterval(30), now: now) == "<1m")
        #expect(CLIFormat.timeLeft(until: now.addingTimeInterval(45 * 60), now: now) == "45m")
        #expect(CLIFormat.timeLeft(until: now.addingTimeInterval(2 * 3600 + 5 * 60 + 59), now: now) == "2h 05m")
        #expect(CLIFormat.timeLeft(until: now.addingTimeInterval(27 * 3600), now: now) == "1d 3h")
        #expect(CLIFormat.timeLeft(until: now.addingTimeInterval(-1), now: now) == "expired")
        let utc = TimeZone(identifier: "UTC")!
        #expect(CLIFormat.clock(now.addingTimeInterval(3600), now: now, timeZone: utc) == "13:00")
        #expect(CLIFormat.clock(now.addingTimeInterval(20 * 3600), now: now, timeZone: utc) == "Oct 30 08:00")
        #expect(CLIFormat.plural(1, "role") == "1 role")
        #expect(CLIFormat.plural(3, "role") == "3 roles")
    }
}

@Suite("Command-line tool install paths")
struct CLIInstallTests {
    let home = "/Users/ada"
    let source = "/Applications/Pimento.app/Contents/Helpers/pimento"

    @Test func locations() {
        #expect(CLIInstallLocation.system.linkPath(home: home) == "/usr/local/bin/pimento")
        #expect(CLIInstallLocation.user.linkPath(home: home) == "/Users/ada/.local/bin/pimento")
        #expect(CLIInstallLocation.user.linkPath(home: home + "/") == "/Users/ada/.local/bin/pimento")
        #expect(CLIInstallLocation.user.displayDirectory(home: home) == "~/.local/bin")
    }

    @Test func installDecisions() {
        let link = "/usr/local/bin/pimento"
        #expect(CLIInstaller.installAction(source: source, linkPath: link, state: .missing) == .create)
        #expect(CLIInstaller.installAction(source: source, linkPath: link, state: .symlink(source)) == .upToDate)
        #expect(CLIInstaller.installAction(source: source, linkPath: link,
                                           state: .symlink("../../../Applications/Pimento.app/Contents/Helpers/pimento")) == .upToDate)
        let old = "/Users/ada/Downloads/Pimento.app/Contents/Helpers/pimento"
        #expect(CLIInstaller.installAction(source: source, linkPath: link, state: .symlink(old)) == .replace(previous: old))
        #expect(CLIInstaller.installAction(source: source, linkPath: link, state: .symlink("../Cellar/pimento/0.2.0/bin/pimento"))
            == .conflict("/usr/local/Cellar/pimento/0.2.0/bin/pimento"))
        #expect(CLIInstaller.installAction(source: source, linkPath: link, state: .other) == .blocked)
    }

    @Test func uninstallOnlyRemovesPimentoLinks() {
        let link = "/Users/ada/.local/bin/pimento"
        #expect(CLIInstaller.uninstallAction(source: source, linkPath: link, state: .missing) == .notInstalled)
        #expect(CLIInstaller.uninstallAction(source: source, linkPath: link, state: .symlink(source)) == .remove)
        #expect(CLIInstaller.uninstallAction(source: nil, linkPath: link,
                                             state: .symlink("/Volumes/x/Pimento.app/Contents/Helpers/pimento")) == .remove)
        #expect(CLIInstaller.uninstallAction(source: source, linkPath: link, state: .symlink("/opt/tools/pimento"))
            == .notOurs("/opt/tools/pimento"))
        #expect(CLIInstaller.uninstallAction(source: source, linkPath: link, state: .other) == .notOurs(link))
        #expect(!CLIInstaller.isBundledTool("/Contents/Helpers/pimento"))
        #expect(!CLIInstaller.isBundledTool("/x/Pimento/Contents/Helpers/pimento"))
    }

    /// A link another user owns is never reported as installed, replaced or
    /// removed, wherever it points.
    @Test func linksOfOtherUsersAreLeftAlone() {
        let link = "/usr/local/bin/pimento"
        #expect(CLIInstaller.installAction(source: source, linkPath: link, state: .foreignSymlink(source, owner: 501))
            == .notOwned(target: source, owner: 501))
        #expect(CLIInstaller.installAction(source: source, linkPath: link,
                                           state: .foreignSymlink("/tmp/Pimento.app/Contents/Helpers/pimento", owner: 502))
            == .notOwned(target: "/tmp/Pimento.app/Contents/Helpers/pimento", owner: 502))
        #expect(CLIInstaller.uninstallAction(source: source, linkPath: link, state: .foreignSymlink(source, owner: 501))
            == .notOurs(source))
    }

    /// /usr/local/bin/pimento must not lead to a file someone else can swap.
    @Test func aSystemLinkNeedsASourceOnlyRootOrYouCanChange() {
        let me: UInt32 = 501
        func info(_ table: [String: PathTrust.Info]) -> (String) -> PathTrust.Info? { { table[$0] } }
        let root = PathTrust.Info(owner: 0, group: 0, mode: 0o755)
        let applications = PathTrust.Info(owner: 0, group: 80, mode: 0o775)
        let mine = PathTrust.Info(owner: me, group: 20, mode: 0o755)
        let tool = "/Applications/Pimento.app/Contents/Helpers/pimento"
        var tree: [String: PathTrust.Info] = [
            "/": root, "/Applications": applications, "/Applications/Pimento.app": mine,
            "/Applications/Pimento.app/Contents": mine, "/Applications/Pimento.app/Contents/Helpers": mine, tool: mine,
        ]
        #expect(PathTrust.firstUntrusted(tool, user: me, info: info(tree)) == nil)
        // Another user's bundle, a group-writable folder (not wheel/admin), a world-writable one.
        tree["/Applications/Pimento.app"] = PathTrust.Info(owner: 502, group: 20, mode: 0o755)
        #expect(PathTrust.firstUntrusted(tool, user: me, info: info(tree)) == "/Applications/Pimento.app")
        tree["/Applications/Pimento.app"] = PathTrust.Info(owner: me, group: 20, mode: 0o775)
        #expect(PathTrust.firstUntrusted(tool, user: me, info: info(tree)) == "/Applications/Pimento.app")
        tree["/Applications/Pimento.app"] = mine
        tree["/Applications/Pimento.app/Contents/Helpers"] = PathTrust.Info(owner: me, group: 20, mode: 0o757)
        #expect(PathTrust.firstUntrusted(tool, user: me, info: info(tree)) == "/Applications/Pimento.app/Contents/Helpers")
        // Missing information is not trust.
        tree["/Applications/Pimento.app/Contents/Helpers"] = nil
        #expect(PathTrust.firstUntrusted(tool, user: me, info: info(tree)) == "/Applications/Pimento.app/Contents/Helpers")
        // A sticky world-writable folder of root's (/tmp) is fine above your own folder.
        let shared = ["/": root, "/tmp": PathTrust.Info(owner: 0, group: 0, mode: 0o1777), "/tmp/a": mine]
        #expect(PathTrust.firstUntrusted("/tmp/a", user: me, info: info(shared)) == nil)
        #expect(PathTrust.firstUntrusted("/tmp/a", user: 777, info: info(shared)) == "/tmp/a")
    }

    @Test func commandsAreQuotedForShellAndAppleScript() {
        #expect(CLIInstaller.shellQuote("it's") == #"'it'\''s'"#)
        let cmd = CLIInstaller.installCommand(source: "/Applications/My \"Apps\"/Pimento.app/Contents/Helpers/pimento",
                                              linkPath: "/usr/local/bin/pimento")
        #expect(cmd == #"/bin/mkdir -p '/usr/local/bin' && { [ ! -e '/usr/local/bin/pimento' ] || [ -L '/usr/local/bin/pimento' ]; } && /bin/ln -sfn '/Applications/My "Apps"/Pimento.app/Contents/Helpers/pimento' '/usr/local/bin/pimento'"#)
        #expect(CLIInstaller.uninstallCommand(linkPath: "/usr/local/bin/pimento") == "{ [ ! -L '/usr/local/bin/pimento' ] || /bin/rm -f '/usr/local/bin/pimento'; }")
        let script = CLIInstaller.adminAppleScript(#"echo "a\b""#, prompt: "Pimento")
        #expect(script == #"do shell script "echo \"a\\b\"" with prompt "Pimento" with administrator privileges"#)
    }

    #if !os(Windows)
    /// Runs `command` with /bin/sh; its exit status.
    func sh(_ command: String) throws -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", command]
        try p.run()
        p.waitUntilExit()
        return p.terminationStatus
    }

    /// The commands run as root after the password prompt re-check the path:
    /// a real file that appeared since the check is never replaced or removed.
    @Test func installAndUninstallCommandsLeaveRealFilesAlone() throws {
        let fm = FileManager.default
        let dir = TestTemp.url("install")
        defer { try? fm.removeItem(at: dir) }
        let link = dir.appendingPathComponent("bin/pimento").path
        let source = dir.appendingPathComponent("Pimento.app/Contents/Helpers/pimento").path
        // Missing: created.
        #expect(try sh(CLIInstaller.installCommand(source: source, linkPath: link)) == 0)
        #expect(try fm.destinationOfSymbolicLink(atPath: link) == source)
        // A link: replaced.
        let other = dir.appendingPathComponent("Old.app/Contents/Helpers/pimento").path
        #expect(try sh(CLIInstaller.installCommand(source: other, linkPath: link)) == 0)
        #expect(try fm.destinationOfSymbolicLink(atPath: link) == other)
        #expect(try sh(CLIInstaller.uninstallCommand(linkPath: link)) == 0)
        #expect(!fm.fileExists(atPath: link))
        // A real file: neither replaced nor removed.
        try Data("mine".utf8).write(to: URL(fileURLWithPath: link))
        #expect(try sh(CLIInstaller.installCommand(source: source, linkPath: link)) != 0)
        _ = try sh(CLIInstaller.uninstallCommand(linkPath: link))
        #expect(try String(contentsOfFile: link, encoding: .utf8) == "mine")
    }
    #endif

    /// The symlink into Pimento.app is a macOS (app) feature; Windows symlinks need extra rights.
    @Test(.enabled(if: HostPlatform.current != .windows, "macOS app feature; symlinks need privileges on Windows"))
    func readsLinkStateFromDisk() throws {
        let dir = TestTemp.url("install")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let link = dir.appendingPathComponent("pimento").path
        #expect(CLIInstaller.state(at: link) == .missing)
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: source)
        #expect(CLIInstaller.state(at: link) == .symlink(source))
        let file = dir.appendingPathComponent("file").path
        FileManager.default.createFile(atPath: file, contents: Data())
        #expect(CLIInstaller.state(at: file) == .other)
        // Owned by you (the test runs as the link's owner): yours; anyone else's: foreign.
        #expect(CLIInstaller.state(at: link, user: PathTrust.currentUser) == .symlink(source))
        if PathTrust.currentUser != 0 {
            #expect(CLIInstaller.state(at: link, user: PathTrust.currentUser + 1) == .foreignSymlink(source, owner: PathTrust.currentUser))
        }
    }

    /// "Already installed" only when the link really ends at this app's tool
    /// (through folder links too); otherwise the real target is reported.
    @Test(.enabled(if: HostPlatform.current != .windows, "macOS app feature; symlinks need privileges on Windows"))
    func upToDateOnlyWhenTheLinkEndsAtThisTool() throws {
        let fm = FileManager.default
        let dir = TestTemp.url("install-real")
        defer { try? fm.removeItem(at: dir) }
        let app = dir.appendingPathComponent("Pimento.app/Contents/Helpers")
        let other = dir.appendingPathComponent("Other.app/Contents/Helpers")
        try fm.createDirectory(at: app, withIntermediateDirectories: true)
        try fm.createDirectory(at: other, withIntermediateDirectories: true)
        let source = app.appendingPathComponent("pimento").path
        fm.createFile(atPath: source, contents: Data())
        fm.createFile(atPath: other.appendingPathComponent("pimento").path, contents: Data())
        let link = dir.appendingPathComponent("bin/pimento").path
        #expect(CLIInstaller.installAction(source: source, linkPath: link, state: .symlink(source)) == .upToDate)
        // A link through a folder link that leads to another app: that app's tool.
        let alias = dir.appendingPathComponent("Alias.app").path
        try fm.createSymbolicLink(atPath: alias, withDestinationPath: dir.appendingPathComponent("Other.app").path)
        let viaAlias = alias + "/Contents/Helpers/pimento"
        let real = URL(fileURLWithPath: other.appendingPathComponent("pimento").path).resolvingSymlinksInPath().path
        #expect(CLIInstaller.installAction(source: source, linkPath: link, state: .symlink(viaAlias)) == .replace(previous: real))
        // A different path that ends at this tool is this tool.
        let mine = dir.appendingPathComponent("Mine.app").path
        try fm.createSymbolicLink(atPath: mine, withDestinationPath: dir.appendingPathComponent("Pimento.app").path)
        #expect(CLIInstaller.installAction(source: source, linkPath: link, state: .symlink(mine + "/Contents/Helpers/pimento")) == .upToDate)
    }
}

@Suite("CLI live wiring")
struct CLILiveWiringTests {
    func put() -> URLRequest {
        var request = URLRequest(url: URL(string: "https://management.azure.com/x")!)
        request.httpMethod = "PUT"
        return request
    }

    @Test func readOnlyServicesRefuseWritesBeforeTheNetwork() async throws {
        let base = RecordingTransport { _ in (Data(), 201) }
        let service = CLIEnvironment.liveService(tokens: StaticTokenProvider(), readOnly: true, base: base)
        await #expect(throws: ReadOnlyTransport.WriteRefused.self) { _ = try await service.transport.send(put()) }
        _ = try await service.transport.send(URLRequest(url: URL(string: "https://management.azure.com/y")!))
        #expect(await base.requests.map { $0.httpMethod ?? "GET" } == ["GET"])
    }

    /// The app reads and previews through `readOnly` (SECURITY.md: previews
    /// go through a transport that refuses anything but GET).
    @Test func aReadOnlyCopyOfAWritingServiceRefusesWrites() async throws {
        let base = RecordingTransport { _ in (Data(), 201) }
        let writing = PIMService(transport: base, tokens: StaticTokenProvider())
        let reading = writing.readOnly
        await #expect(throws: ReadOnlyTransport.WriteRefused.self) { _ = try await reading.transport.send(put()) }
        let role = try Fixture.role("Contoso Staging", "Contributor")
        let plans = try ActivationRequestBuilder.plan([role], principalId: Fixture.userOID, justification: "x", hours: 1, now: Fixture.now)
        let outcome = TestBox<ActivationOutcome>()
        try await reading.execute(plans) { _, o in outcome.value = o }
        #expect(outcome.value?.isFailure == true)
        #expect(await base.requests.isEmpty)
        // Wrapped once, and the copy records nothing.
        #expect((reading.readOnly.transport as? ReadOnlyTransport)?.base is RecordingTransport)
        #expect(reading.history == nil)
        #expect(try await writing.transport.send(put()).1 == 201)
    }

    @Test func writingServicesSendWrites() async throws {
        let base = RecordingTransport { _ in (Data(), 201) }
        let service = CLIEnvironment.liveService(tokens: StaticTokenProvider(), readOnly: false, base: base)
        #expect(try await service.transport.send(put()).1 == 201)
        #expect(await base.requests.map(\.httpMethod) == ["PUT"])
    }

    @Test func byDefaultTheNetworkIsURLSessionWithoutRedirects() throws {
        let writing = CLIEnvironment.liveService(tokens: StaticTokenProvider(), readOnly: false)
        #expect(writing.transport is URLSessionTransport)
        let reading = CLIEnvironment.liveService(tokens: StaticTokenProvider(), readOnly: true)
        let wrapper = try #require(reading.transport as? ReadOnlyTransport)
        #expect(wrapper.base is URLSessionTransport)
    }

    @Test func tenantsWithTokensComeFromARMReadOnlyAndSorted() async throws {
        let page1 = try Fixture.data("arm-tenants-page1"), page2 = try Fixture.data("arm-tenants-page2")
        let base = RecordingTransport { request in
            (request.url?.query?.contains("skiptoken") == true ? page2 : page1, 200)
        }
        let tenants = try await CLIEnvironment.liveTenants(preferredTenant: nil, tokens: StaticTokenProvider(), base: base)
        #expect(tenants == TenantDirectory.sorted(tenants))
        #expect(tenants.count == 3)
        #expect(await base.requests.allSatisfy { $0.httpMethod == "GET" && $0.url?.host == "management.azure.com" })
    }

    #if !os(Windows)
    /// Without tokens: az's view (az is a stand-in that fails here), and ARM
    /// through a read-only transport.
    @Test func tenantsWithoutTokensAskAzAndNeverWrite() async throws {
        let dir = TestTemp.url("az")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let az = dir.appendingPathComponent("az")
        try Data("#!/bin/sh\nexit 1\n".utf8).write(to: az)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: az.path)
        let base = RecordingTransport { _ in (Data(), 500) }
        let tenants = try await CLIEnvironment.liveTenants(preferredTenant: nil, tokens: nil, base: base, azPath: az.path)
        #expect(tenants.isEmpty)
        #expect(await base.requests.isEmpty)
    }
    #endif
}
