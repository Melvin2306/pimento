import Foundation
import Testing
@testable import PimentoCore

/// A fake token endpoint for the CLI: device code, then tokens; refreshes for
/// any tenant. `nonce`: what the id token echoes (the browser sign-in's).
func fakeLogin(pendingPolls: Int = 1, nonce: @escaping @Sendable () -> String? = { nil }) -> RecordingTransport {
    let polls = TestBox<Int>(0)
    return RecordingTransport { request in
        if request.url!.path.hasSuffix("/devicecode") {
            return (Data(#"{"device_code":"DC","user_code":"WXYZ-1234","verification_uri":"https://microsoft.com/devicelogin","expires_in":900,"interval":5}"#.utf8), 200)
        }
        let f = formFields(request)
        if f["grant_type"] == "urn:ietf:params:oauth:grant-type:device_code" {
            polls.value = (polls.value ?? 0) + 1
            if polls.value! <= pendingPolls { return (oauthError("authorization_pending"), 400) }
        }
        return (tokenAnswer(tenant: request.url!.pathComponents[1] == "organizations" ? homeTenant : request.url!.pathComponents[1],
                            nonce: nonce()), 200)
    }
}

extension CLIHarness {
    func signedIn() throws -> SignedInAccount {
        let account = SignedInAccount(objectId: Fixture.userOID, homeTenantId: homeTenant, tenantId: homeTenant, username: "test@example.com",
                                      name: "Test User", clientId: testClientId, signedInAt: Fixture.now)
        try tokenStore.save(account, refreshToken: "rt-0")
        return account
    }
}

@Suite("CLI: --auth, login, logout, whoami")
struct CLIAuthTests {
    @Test func authFlagIsAcceptedAnywhere() throws {
        #expect(try CLIParser.parse(["--auth", "pimento", "list"]).auth == "pimento")
        #expect(try CLIParser.parse(["list", "--auth=az", "prod"]) == CLIInvocation(.list({
            var o = ListOptions(); o.criteria.filters = ["prod"]; return o
        }()), auth: "az"))
        #expect(try CLIParser.parse(["status", "--auth", "pimento", "--json"]).auth == "pimento")
        // After `--` it is a filter.
        guard case .list(let o) = try CLIParser.parse(["list", "--", "--auth"]).command else { Issue.record("expected list"); return }
        #expect(o.criteria.filters == ["--auth"])
        #expect(throws: CLIParseError.missingValue("--auth")) { try CLIParser.parse(["list", "--auth"]) }
        #expect(throws: CLIParseError.missingValue("--auth")) { try CLIParser.parse(["list", "--auth", "--json"]) }
        #expect(throws: CLIParseError.missingValue("--auth")) { try CLIParser.parse(["list", "--auth="]) }
    }

    @Test func aBadAuthSourceBlocksOnlyCommandsThatNeedAzure() async {
        for args in [["help"], ["version"], ["presets", "list"], ["history"], ["logout"], ["completions", "zsh"]] {
            let h = CLIHarness()
            h.variables[AuthSourceResolver.environmentVariable] = "bogus"
            #expect(await h.run(args) == 0, "\(args)")
            #expect(h.err.contains("not an auth source"))
        }
        let list = CLIHarness()
        list.variables[AuthSourceResolver.environmentVariable] = "bogus"
        #expect(await list.run("list") == 2)
        #expect(await list.transport.requests.isEmpty)
    }

    @Test func parseLoginLogoutWhoami() throws {
        var login = LoginOptions()
        login.deviceCode = true
        login.clientId = testClientId
        login.tenant = "contoso.example"
        #expect(try CLIParser.parse(["login", "--device-code", "--client-id", testClientId, "-t", "contoso.example"]).command == .login(login))
        #expect(try CLIParser.parse(["login"]).command == .login(LoginOptions()))
        #expect(throws: CLIParseError.invalidClientId("nope")) { try CLIParser.parse(["login", "--client-id", "nope"]) }
        #expect(throws: CLIParseError.self) { try CLIParser.parse(["login", "extra"]) }
        var logout = LogoutOptions()
        logout.all = true
        #expect(try CLIParser.parse(["logout", "--all"]).command == .logout(logout))
        #expect(throws: CLIParseError.self) { try CLIParser.parse(["logout", "--tenant", "x"]) }
        var who = WhoamiOptions()
        who.json = true
        #expect(try CLIParser.parse(["whoami", "--json"]).command == .whoami(who))
        #expect(try CLIParser.parse(["login", "--help"]).command == .help(topic: "login"))
        for name in ["login", "logout", "whoami"] {
            #expect(CLIHelp.text(for: name).contains("Usage: pimento \(name)"))
            for shell in CompletionShell.allCases { #expect(CLIHelp.completionScript(for: shell).contains(name)) }
        }
        for shell in CompletionShell.allCases {
            let script = CLIHelp.completionScript(for: shell)
            #expect(script.contains("auth") && script.contains("device-code") && script.contains("client-id"))
        }
        #expect(CLIHelp.text(for: nil).contains("--auth SOURCE"))
    }

    @Test func defaultIsTheAzureCLI() async throws {
        let h = CLIHarness()
        #expect(await h.run("list") == 0)
        #expect(h.givenTokens.value?.first is AzureCLITokenProvider)
    }

    @Test func precedenceFlagEnvironmentSetting() async throws {
        // `tokens` answers either way: this is only about which provider is built.
        let h = CLIHarness()
        try h.authSettings.save(AuthSettings(source: .pimento))
        #expect(await h.run("status") == 0)
        #expect(h.givenTokens.value?.last is BrokerTokenProvider)
        #expect(await h.run("status", "--auth", "az") == 0)
        #expect(h.givenTokens.value?.last is AzureCLITokenProvider)
        h.variables[AuthSourceResolver.environmentVariable] = "az"
        #expect(await h.run("status") == 0)
        #expect(h.givenTokens.value?.last is AzureCLITokenProvider)
        #expect(await h.run("status", "--auth", "pimento") == 0)
        #expect(h.givenTokens.value?.last is BrokerTokenProvider)
        #expect(await h.run("status", "--auth", "msal") == 2)
        #expect(h.err.contains("not an auth source"))
        h.variables[AuthSourceResolver.environmentVariable] = "bogus"
        #expect(await h.run("status") == 2)
    }

    @Test func pimentoWithoutAccountSaysHowToSignIn() async throws {
        let h = CLIHarness()
        h.useAuthTokens = true
        #expect(await h.run("list", "--auth", "pimento") == 3)
        #expect(h.err.contains("Not signed in with Pimento"))
        #expect(h.err.contains("hint: sign in with `pimento login`"))
        #expect(!h.err.contains("az login"))
    }

    @Test func pimentoTokensReachARMPerTenant() async throws {
        let h = CLIHarness()
        let login = fakeLogin()
        h.signInTransport = login
        h.useAuthTokens = true
        _ = try h.signedIn()
        #expect(await h.run("list", "--auth", "pimento") == 0)
        #expect(await h.run("list", "--auth", "pimento", "--tenant", otherTenant) == 0)
        let tokenCalls = await login.requests
        #expect(tokenCalls.map { $0.url!.host! } == ["login.microsoftonline.com", "login.microsoftonline.com"])
        #expect(tokenCalls.map { $0.url!.pathComponents[1] } == [homeTenant, otherTenant])
        // ARM got the bearer token from the refresh.
        let arm = await h.transport.requests
        #expect(arm.allSatisfy { $0.url!.host == "management.azure.com" })
        let bearer = try #require(arm.first?.value(forHTTPHeaderField: "Authorization"))
        #expect(JWT.claims(String(bearer.dropFirst("Bearer ".count)))?["tid"] as? String == homeTenant)
    }

    @Test func loginWithDeviceCode() async throws {
        let h = CLIHarness()
        h.signInTransport = fakeLogin(pendingPolls: 1)
        #expect(await h.run("login", "--device-code", "--client-id", testClientId) == 0)
        #expect(h.err.contains("https://microsoft.com/devicelogin") && h.err.contains("WXYZ-1234"))
        #expect(h.out.contains("Signed in as Test User <test@example.com>"))
        #expect(h.err.contains("now the auth source"))
        #expect(h.sleeps == [5, 5])
        let settings = h.authSettings.load()
        #expect(settings.source == .pimento && settings.clientId == testClientId)
        #expect(settings.accountId == "\(Fixture.userOID).\(homeTenant)")
        #expect(try h.tokenStore.refreshToken(for: settings.accountId!) == "rt-1")
        // The CLI now uses Pimento sign-in by default.
        h.useAuthTokens = true
        #expect(await h.run("status") == 0)
        #expect(h.givenTokens.value?.last is BrokerTokenProvider)
    }

    @Test func loginAndLogoutWarnWhenTheSettingsCannotBeSaved() async throws {
        let h = CLIHarness()
        h.signInTransport = fakeLogin(pendingPolls: 0)
        // A folder where auth.json should be: every write fails.
        try FileManager.default.createDirectory(at: h.authSettings.url, withIntermediateDirectories: true)
        #expect(await h.run("login", "--device-code", "--client-id", testClientId) == 0)
        #expect(h.err.contains("could not save the sign-in settings"))
        #expect(!h.err.contains("now the auth source"))
        #expect(await h.run("logout") == 0)
        #expect(h.err.components(separatedBy: "could not save the sign-in settings").count == 3)
    }

    @Test(.enabled(if: LoopbackListener.isSupported, "no loopback listener on Windows"))
    func loginWithTheBrowserPassesASavedClaimsChallenge() async throws {
        let h = CLIHarness()
        let opened = TestBox<URL>()
        h.signInTransport = fakeLogin { opened.value.flatMap { query($0)["nonce"] } }
        let challenge = #"{"access_token":{"acrs":{"essential":true,"value":"c1"}}}"#
        try h.authSettings.save(AuthSettings(clientId: testClientId, claimsChallenge: challenge))
        h.openURL = { url in
            opened.value = url
            let q = query(url)
            let port = UInt16(URL(string: q["redirect_uri"]!)!.port!)
            DispatchQueue.global().async { browse(port: port, "/?code=c&state=\(q["state"]!)") }
            return true
        }
        #expect(await h.run("login", "--json") == 0)
        let url = try #require(opened.value)
        #expect(query(url)["claims"] == challenge)
        #expect(h.err.contains(url.absoluteString))
        #expect(h.out.contains("\"source\" : \"pimento\""))
        #expect(h.authSettings.load().claimsChallenge == nil)
    }

    /// Windows has no browser sign-in: `login` uses a device code by itself.
    @Test func loginWithoutABrowserUsesADeviceCode() async throws {
        let h = CLIHarness()
        h.browserSignIn = false
        h.signInTransport = fakeLogin()
        h.openURL = { _ in
            Issue.record("no browser without browser sign-in")
            return false
        }
        #expect(await h.run("login", "--client-id", testClientId) == 0)
        #expect(h.err.contains("Browser sign-in is not available on this platform"))
        #expect(h.err.contains("https://microsoft.com/devicelogin") && h.err.contains("WXYZ-1234"))
        #expect(h.out.contains("Signed in as Test User <test@example.com>"))
    }

    @Test(.enabled(if: !LoopbackListener.isSupported, "Windows only"))
    func listenerIsUnavailableOnWindows() {
        #expect(throws: SignInError.self) { _ = try LoopbackListener() }
    }

    @Test func loginNeedsAClientId() async throws {
        let h = CLIHarness()
        #expect(await h.run("login", "--device-code") == 2)
        #expect(h.err.contains(AuthSourceResolver.clientIdVariable))
        h.variables[AuthSourceResolver.clientIdVariable] = "not-a-guid"
        #expect(await h.run("login", "--device-code") == 2)
        #expect(h.err.contains("not a client ID"))
    }

    @Test func loginReportsAADSTSErrors() async throws {
        let h = CLIHarness()
        h.signInTransport = RecordingTransport { _ in
            (oauthError("unauthorized_client", "AADSTS700016: Application not found", codes: [700016]), 400)
        }
        #expect(await h.run("login", "--device-code", "--client-id", testClientId) == 1)
        #expect(h.err.contains("client ID was not found"))
        #expect(h.authSettings.load().source == nil)
    }

    @Test func logoutForgetsTheAccountAndFallsBackToAz() async throws {
        let h = CLIHarness()
        let account = try h.signedIn()
        try h.authSettings.save(AuthSettings(source: .pimento, clientId: testClientId, accountId: account.id))
        #expect(await h.run("logout") == 0)
        #expect(h.out.contains("Signed out Test User <test@example.com>."))
        #expect(try h.tokenStore.accounts().isEmpty)
        #expect(h.authSettings.load() == AuthSettings(source: nil, clientId: testClientId, accountId: nil))
        #expect(await h.run("logout") == 0)
        #expect(h.out.contains("Not signed in with Pimento"))
    }

    @Test func logoutAllAsJSON() async throws {
        let h = CLIHarness()
        _ = try h.signedIn()
        try h.tokenStore.save(SignedInAccount(objectId: "o2", homeTenantId: otherTenant, tenantId: otherTenant, username: "b@example.com",
                                              name: nil, clientId: testClientId, signedInAt: Fixture.now), refreshToken: "x")
        #expect(await h.run("logout", "--all", "--json") == 0)
        #expect(h.out.contains("\"remaining\" : 0"))
        #expect(try h.tokenStore.accounts().isEmpty)
    }

    @Test func whoami() async throws {
        let h = CLIHarness()
        #expect(await h.run("whoami") == 0)
        #expect(h.out.contains("Auth source: Azure CLI (default)"))
        #expect(h.out.contains("Signed in as Test User <test@example.com>"))
        #expect(!h.out.contains("Pimento sign-in ("))

        let p = CLIHarness()
        p.signInTransport = fakeLogin()
        p.useAuthTokens = true
        _ = try p.signedIn()
        #expect(await p.run("whoami", "--auth", "pimento") == 0)
        #expect(p.out.contains("Auth source: Pimento sign-in (--auth)"))
        #expect(p.out.contains("Pimento sign-in (memory)"))
        #expect(p.out.contains("* Test User <test@example.com>"))
        #expect(await p.run("whoami", "--auth", "pimento", "--json") == 0)
        #expect(p.out.contains("\"isDefault\" : true") && p.out.contains("\"origin\" : \"commandLine\""))
    }

    @Test func whoamiWithoutSignInExits3() async throws {
        let h = CLIHarness()
        h.useAuthTokens = true
        #expect(await h.run("whoami", "--auth", "pimento") == 3)
        #expect(h.out.contains("no accounts; run `pimento login`"))
        #expect(h.err.contains("pimento login"))
    }

    @Test func expiredSignInKeepsTheClaimsChallenge() async throws {
        let h = CLIHarness()
        let challenge = #"{"access_token":{"capolids":{"essential":true,"values":["p1"]}}}"#
        h.signInTransport = RecordingTransport { _ in
            (oauthError("invalid_grant", "AADSTS50076: MFA required", codes: [50076], claims: challenge), 400)
        }
        h.useAuthTokens = true
        _ = try h.signedIn()
        #expect(await h.run("list", "--auth", "pimento", "--tenant", otherTenant) == 3)
        #expect(h.err.contains("Multi-factor authentication is required"))
        #expect(h.err.contains("pimento login --tenant \(otherTenant)"))
        #expect(h.authSettings.load().claimsChallenge == challenge)
    }

    @Test func activationClaimsChallengeIsRemembered() async throws {
        let message = "The role requires an authentication context. Retry with a token that has the claims: "
            + "&claims=%7B%22access_token%22%3A%7B%22acrs%22%3A%7B%22essential%22%3Atrue%2C%22value%22%3A%22c1%22%7D%7D%7D"
        let body = try JSONSerialization.data(withJSONObject: ["error": ["code": "RoleAssignmentRequestAcrsValidationFailed", "message": message]])
        let h = CLIHarness(put: { _ in (body, 400) })
        h.signInTransport = fakeLogin()
        h.useAuthTokens = true
        _ = try h.signedIn()
        #expect(await h.run("activate", "--auth", "pimento", "Staging", "-j", "test", "--yes") == 1)
        #expect(h.err.contains("Azure asks for more verification"))
        #expect(h.authSettings.load().claimsChallenge == #"{"access_token":{"acrs":{"essential":true,"value":"c1"}}}"#)
    }

    @Test func claimsChallengeExtraction() {
        #expect(ClaimsChallenge.find(in: "no challenge here") == nil)
        #expect(ClaimsChallenge.find(in: "x &claims=%7B%22a%22%3A1%7D more") == #"{"a":1}"#)
        let b64 = Data(#"{"access_token":{"nbf":{"essential":true}}}"#.utf8).base64EncodedString()
        #expect(ClaimsChallenge.find(in: #"Bearer error="insufficient_claims", claims="\#(b64)""#) == #"{"access_token":{"nbf":{"essential":true}}}"#)
        #expect(ClaimsChallenge.find(in: "claims=notjson") == nil)
        #expect(ActivationOutcome.failed(code: "X", message: "claims=%7B%7D").claimsChallenge == "{}")
        #expect(ActivationOutcome.alreadyActive.claimsChallenge == nil)
    }
}
