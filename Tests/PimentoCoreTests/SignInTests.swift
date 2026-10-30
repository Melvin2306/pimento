#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif os(Windows)
import WinSDK
#endif
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import PimentoCore

let testClientId = "0f0e0d0c-0b0a-4009-8008-070605040302"
let homeTenant = "11111111-2222-4333-8444-555555555555"
let otherTenant = "22222222-3333-4444-8555-666666666666"

func hex(_ bytes: [UInt8]) -> String { bytes.map { String(format: "%02x", $0) }.joined() }

/// The fields of a form-encoded request body.
func formFields(_ request: URLRequest) -> [String: String] {
    TokenRequest.formDecode(String(decoding: request.httpBody ?? Data(), as: UTF8.self))
}

/// A token endpoint answer for a synthetic account.
func tokenAnswer(tenant: String = homeTenant, refresh: String? = "rt-1", expiresIn: Int = 3600, nonce: String? = nil,
                 access: String = "at") -> Data {
    var id: [String: Any] = ["oid": Fixture.userOID, "tid": tenant, "preferred_username": "test@example.com", "name": "Test User"]
    if let nonce { id["nonce"] = nonce }
    let accessToken = fakeToken(["oid": Fixture.userOID, "tid": tenant, "name": "Test User", "upn": "test@example.com", "x": access])
    var body: [String: Any] = [
        "token_type": "Bearer", "access_token": accessToken, "expires_in": expiresIn,
        "scope": "https://management.azure.com/user_impersonation", "id_token": fakeToken(id),
        "client_info": Base64URL.encode(Array(#"{"uid":"\#(Fixture.userOID)","utid":"\#(homeTenant)"}"#.utf8)),
    ]
    if let refresh { body["refresh_token"] = refresh }
    return try! JSONSerialization.data(withJSONObject: body)
}

func oauthError(_ error: String, _ description: String = "", codes: [Int] = [], claims: String? = nil) -> Data {
    var body: [String: Any] = ["error": error, "error_description": description, "error_codes": codes]
    if let claims { body["claims"] = claims }
    return try! JSONSerialization.data(withJSONObject: body)
}

func query(_ url: URL) -> [String: String] {
    Dictionary((URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") },
               uniquingKeysWith: { a, _ in a })
}

final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date
    init(_ start: Date = Fixture.now) { value = start }
    var now: Date { lock.withLock { value } }
    func advance(_ seconds: TimeInterval) { lock.withLock { value = value.addingTimeInterval(seconds) } }
}

@Suite("Sign-in: PKCE, URLs and request bodies")
struct OAuthBuildingBlockTests {
    @Test func sha256KnownVectors() {
        #expect(hex(SHA256.hash([])) == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        #expect(hex(SHA256.hash(Array("abc".utf8))) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        // Two blocks (56 bytes forces the length into a second block).
        #expect(hex(SHA256.hash(Array("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq".utf8)))
            == "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1")
    }

    @Test func pkceMatchesRFC7636AppendixB() {
        let pkce = PKCE(verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
        #expect(pkce.challenge == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
        #expect(PKCE.method == "S256")
    }

    @Test func generatedVerifiersAreLongRandomAndURLSafe() {
        let a = PKCE.generate(), b = PKCE.generate()
        #expect(a.verifier.count == 43)
        #expect(a.verifier != b.verifier)
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
        #expect(a.verifier.unicodeScalars.allSatisfy(allowed.contains))
        #expect(!a.challenge.contains("=") && !a.challenge.contains("+") && !a.challenge.contains("/"))
    }

    @Test func stateAndNonceAreFreshPerRequest() {
        let a = AuthorizationRequest(clientId: testClientId, authority: "organizations", redirectURI: "http://localhost:5000")
        let b = AuthorizationRequest(clientId: testClientId, authority: "organizations", redirectURI: "http://localhost:5000")
        #expect(a.state != b.state && a.nonce != b.nonce && a.state != a.nonce)
        #expect(a.state.count >= 32)
    }

    @Test func authorizeURL() {
        var request = AuthorizationRequest(clientId: testClientId, authority: "organizations", redirectURI: "http://localhost:51234",
                                           pkce: PKCE(verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"), state: "st", nonce: "nn")
        var url = request.url
        #expect(url.absoluteString.hasPrefix("https://login.microsoftonline.com/organizations/oauth2/v2.0/authorize?"))
        var q = query(url)
        #expect(q["client_id"] == testClientId)
        #expect(q["response_type"] == "code")
        #expect(q["response_mode"] == "query")
        #expect(q["redirect_uri"] == "http://localhost:51234")
        #expect(q["scope"] == "https://management.azure.com/user_impersonation offline_access openid profile")
        #expect(q["state"] == "st" && q["nonce"] == "nn")
        #expect(q["code_challenge"] == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
        #expect(q["code_challenge_method"] == "S256")
        #expect(q["prompt"] == "select_account")
        #expect(q["claims"] == nil && q["login_hint"] == nil && q["client_secret"] == nil)

        request.claims = #"{"access_token":{"acrs":{"essential":true,"value":"c1"}}}"#
        request.loginHint = "test+1@example.com"
        url = request.url
        q = query(url)
        #expect(q["claims"] == request.claims)
        #expect(q["login_hint"] == "test+1@example.com")
        #expect(url.absoluteString.contains("test%2B1%40example.com") || url.absoluteString.contains("test%2B1@example.com"))
    }

    @Test func authorityValidation() throws {
        #expect(try MicrosoftIdentity.authority(nil) == "organizations")
        #expect(try MicrosoftIdentity.authority("  ") == "organizations")
        #expect(try MicrosoftIdentity.authority(homeTenant) == homeTenant)
        #expect(try MicrosoftIdentity.authority("contoso.onmicrosoft.com") == "contoso.onmicrosoft.com")
        #expect(throws: TenantError.self) { try MicrosoftIdentity.authority("../evil") }
        #expect(throws: TenantError.self) { try MicrosoftIdentity.authority("a/b.com") }
    }

    @Test func clientIdValidation() {
        #expect(MicrosoftIdentity.isValidClientId(testClientId))
        #expect(MicrosoftIdentity.isValidClientId(" \(testClientId.uppercased()) "))
        #expect(!MicrosoftIdentity.isValidClientId("pimento"))
        #expect(!MicrosoftIdentity.isValidClientId(""))
    }

    @Test func authorizationCodeBody() {
        let auth = AuthorizationRequest(clientId: testClientId, authority: homeTenant, redirectURI: "http://localhost:6000",
                                        pkce: PKCE(verifier: "verifier-123"), state: "s", nonce: "n")
        let r = TokenRequest.authorizationCode("code/with+chars", request: auth)
        #expect(r.httpMethod == "POST")
        #expect(r.url?.absoluteString == "https://login.microsoftonline.com/\(homeTenant)/oauth2/v2.0/token")
        #expect(r.value(forHTTPHeaderField: "Content-Type") == "application/x-www-form-urlencoded")
        let f = formFields(r)
        #expect(f == [
            "client_id": testClientId, "grant_type": "authorization_code", "scope": MicrosoftIdentity.scope,
            "code": "code/with+chars", "redirect_uri": "http://localhost:6000", "code_verifier": "verifier-123", "client_info": "1",
        ])
        let raw = String(decoding: r.httpBody!, as: UTF8.self)
        #expect(raw.contains("code=code%2Fwith%2Bchars"))
        #expect(raw.contains("scope=https%3A%2F%2Fmanagement.azure.com%2Fuser_impersonation%20offline_access"))
        #expect(!raw.contains("client_secret"))
    }

    @Test func refreshBody() {
        var f = formFields(TokenRequest.refresh("rt", clientId: testClientId, authority: otherTenant))
        #expect(f == ["client_id": testClientId, "grant_type": "refresh_token", "scope": MicrosoftIdentity.scope,
                      "refresh_token": "rt", "client_info": "1"])
        f = formFields(TokenRequest.refresh("rt", clientId: testClientId, authority: otherTenant, claims: #"{"a":1}"#))
        #expect(f["claims"] == #"{"a":1}"#)
        #expect(TokenRequest.refresh("rt", clientId: testClientId, authority: otherTenant).url?.path == "/\(otherTenant)/oauth2/v2.0/token")
    }

    @Test func deviceCodeBodies() {
        let start = TokenRequest.deviceCode(clientId: testClientId, authority: "organizations")
        #expect(start.url?.absoluteString == "https://login.microsoftonline.com/organizations/oauth2/v2.0/devicecode")
        #expect(formFields(start) == ["client_id": testClientId, "scope": MicrosoftIdentity.scope])
        let poll = TokenRequest.deviceCodeToken("DC-1", clientId: testClientId, authority: "organizations")
        #expect(poll.url?.path == "/organizations/oauth2/v2.0/token")
        #expect(formFields(poll) == ["client_id": testClientId, "grant_type": "urn:ietf:params:oauth:grant-type:device_code",
                                     "device_code": "DC-1", "client_info": "1"])
    }

    @Test func formEncodingIsStrict() {
        #expect(TokenRequest.formEncode([("a b", "x&y=z/ü~._-")]) == "a%20b=x%26y%3Dz%2F%C3%BC~._-")
        #expect(TokenRequest.formDecode("a=1+2&b=%2F&c") == ["a": "1 2", "b": "/", "c": ""])
    }

    @Test func signInTransportOnlyTalksToTheTokenEndpoints() async throws {
        let inner = RecordingTransport { _ in (Data("{}".utf8), 200) }
        let t = SignInTransport(inner)
        _ = try await t.send(TokenRequest.refresh("rt", clientId: testClientId, authority: "organizations"))
        _ = try await t.send(TokenRequest.deviceCode(clientId: testClientId, authority: "organizations"))
        for bad in ["https://login.example.com/x/oauth2/v2.0/token", "http://login.microsoftonline.com/x/oauth2/v2.0/token",
                    "https://management.azure.com/x/oauth2/v2.0/token", "https://login.microsoftonline.com:444/x/oauth2/v2.0/token",
                    "https://login.microsoftonline.com/x/oauth2/v2.0/authorize"] {
            var r = URLRequest(url: URL(string: bad)!)
            r.httpMethod = "POST"
            await #expect(throws: SignInTransport.Refused.self) { _ = try await t.send(r) }
        }
        var get = TokenRequest.refresh("rt", clientId: testClientId, authority: "organizations")
        get.httpMethod = "GET"
        await #expect(throws: SignInTransport.Refused.self) { _ = try await t.send(get) }
        #expect(await inner.requests.count == 2)
    }
}

@Suite("Sign-in: responses, claims and errors")
struct OAuthResponseTests {
    @Test func tokenResponseAndClientInfo() throws {
        let r = try #require(TokenResponse.parse(tokenAnswer(expiresIn: 4000)))
        #expect(r.expiresIn == 4000)
        #expect(r.refreshToken == "rt-1")
        #expect(r.homeAccount?.objectId == Fixture.userOID && r.homeAccount?.tenantId == homeTenant)
        // expires_in as a string, as some endpoints send it.
        let s = try #require(TokenResponse.parse(Data(#"{"access_token":"x","expires_in":"120"}"#.utf8)))
        #expect(s.expiresIn == 120 && s.homeAccount == nil)
        #expect(TokenResponse.parse(Data(#"{"error":"invalid_grant"}"#.utf8)) == nil)
    }

    @Test func idTokenClaims() throws {
        let claims = try #require(IDTokenClaims(token: fakeToken([
            "oid": "AAAAAAAA-0000-4000-8000-000000000001", "tid": homeTenant.uppercased(), "preferred_username": "alex@contoso.example",
            "name": "Alex Wilber", "nonce": "n1",
        ])))
        #expect(claims.objectId == "aaaaaaaa-0000-4000-8000-000000000001")
        #expect(claims.tenantId == homeTenant)
        #expect(claims.username == "alex@contoso.example" && claims.name == "Alex Wilber" && claims.nonce == "n1")
        #expect(IDTokenClaims(token: "not-a-jwt") == nil)
        // The access token's claims give the header's identity.
        let identity = try #require(JWT.identity(fromToken: fakeToken(["oid": "o", "tid": "t", "preferred_username": "u@x.example"])))
        #expect(identity.upn == "u@x.example" && identity.tenantId == "t")
    }

    @Test func clockSkewIsMeasuredButExpiryUsesExpiresIn() throws {
        let now = Fixture.now
        let ahead = TokenResponse(accessToken: fakeToken(["iat": Int(now.timeIntervalSince1970) + 600]), refreshToken: nil,
                                  idToken: nil, expiresIn: 3600, scope: nil, clientInfo: nil)
        #expect(ahead.clockSkew(now: now) == 600)
    }

    @Test func errorParsingAndReadableMessages() throws {
        let mfa = try #require(OAuthErrorInfo.parse(oauthError(
            "invalid_grant", "AADSTS50076: Due to a configuration change made by your administrator...\r\nTrace ID: x",
            codes: [50076], claims: #"{"access_token":{"capolids":{"essential":true,"values":["p1"]}}}"#)))
        #expect(mfa.needsInteraction)
        #expect(mfa.message == "Multi-factor authentication is required. Sign in again and complete MFA (AADSTS50076).")
        #expect(mfa.claims?.contains("capolids") == true)
        #expect(mfa.shortDescription == "AADSTS50076: Due to a configuration change made by your administrator...")

        // Codes are read from the description when error_codes is missing.
        let notFound = OAuthErrorInfo(error: "unauthorized_client", description: "AADSTS700016: Application with identifier 'x' was not found")
        #expect(notFound.codes == [700016])
        #expect(notFound.message.contains("client ID was not found"))
        #expect(!notFound.needsInteraction)

        #expect(OAuthErrorInfo(error: "invalid_client", codes: [7000218]).message.contains("Allow public client flows"))
        #expect(OAuthErrorInfo(error: "invalid_request", codes: [50011]).message.contains("http://localhost"))
        #expect(OAuthErrorInfo(error: "invalid_grant", codes: [700082]).message.contains("expired"))
        #expect(OAuthErrorInfo(error: "invalid_request", codes: [700024]).message.contains("clock"))
        #expect(OAuthErrorInfo(error: "temporarily_unavailable", description: "Try later\nTrace").message == "Try later")
        #expect(OAuthErrorInfo(error: "access_denied").message.contains("cancelled"))

        if case .interactionRequired(let info) = SignInError.from(status: 400, data: oauthError("interaction_required", codes: [53003])) {
            #expect(info.message.contains("Conditional Access"))
        } else { Issue.record("expected interactionRequired") }
        if case .oauth = SignInError.from(status: 400, data: oauthError("invalid_client", codes: [7000218])) {} else { Issue.record("expected oauth") }
        if case .invalidResponse(let m) = SignInError.from(status: 502, data: Data("<html>bad gateway".utf8)) {
            #expect(m.hasPrefix("HTTP 502"))
        } else { Issue.record("expected invalidResponse") }
    }

    @Test func signInErrorsSayWhatToDo() {
        #expect(SignInError.notSignedIn.needsLogin)
        #expect(SignInError.notSignedIn.localizedDescription.contains("pimento login"))
        #expect(SignInError.missingClientId.localizedDescription.contains("PIMENTO_CLIENT_ID"))
        #expect(!SignInError.missingClientId.needsLogin)
        #expect(!SignInError.network("offline").needsLogin)
        let challenge = SignInError.interactionRequired(OAuthErrorInfo(error: "interaction_required", codes: [50076], claims: "{}"))
        #expect(challenge.claims == "{}")
        #expect(challenge.localizedDescription.hasSuffix("Sign in again."))
    }
}

@Suite("Sign-in: device code")
struct DeviceCodeTests {
    let challenge = DeviceCodeChallenge(deviceCode: "DC", userCode: "ABCD-EFGH", verificationURL: URL(string: "https://microsoft.com/devicelogin")!,
                                        expiresIn: 60, interval: 5, message: nil)

    @Test func parseChallenge() throws {
        let c = try #require(DeviceCodeChallenge.parse(Data(#"""
        {"device_code":"DC","user_code":"ABCD-EFGH","verification_uri":"https://microsoft.com/devicelogin",
         "expires_in":"900","interval":5,"message":"To sign in, use a web browser"}
        """#.utf8)))
        #expect(c.userCode == "ABCD-EFGH" && c.expiresIn == 900 && c.interval == 5 && c.message?.hasPrefix("To sign in") == true)
        #expect(DeviceCodeChallenge.parse(Data(#"{"device_code":"d","user_code":"u","verification_uri":"http://evil.example"}"#.utf8)) == nil)
        let legacy = try #require(DeviceCodeChallenge.parse(Data(#"{"device_code":"d","user_code":"u","verification_url":"https://x.example"}"#.utf8)))
        #expect(legacy.interval == 5 && legacy.expiresIn == 900)
    }

    @Test func pollingStateMachine() {
        let start = Fixture.now
        var p = DeviceCodePoller(challenge: challenge, startedAt: start)
        #expect(p.firstWait == .wait(seconds: 5))
        #expect(p.next(status: 400, data: oauthError("authorization_pending"), now: start.addingTimeInterval(5)) == .wait(seconds: 5))
        #expect(p.next(status: 400, data: oauthError("slow_down"), now: start.addingTimeInterval(10)) == .wait(seconds: 10))
        // The slower interval sticks.
        #expect(p.next(status: 400, data: oauthError("authorization_pending"), now: start.addingTimeInterval(20)) == .wait(seconds: 10))
        #expect(p.next(status: 400, data: oauthError("slow_down"), now: start.addingTimeInterval(30)) == .wait(seconds: 15))
        // Past the deadline, pending means expired.
        #expect(p.next(status: 400, data: oauthError("authorization_pending"), now: start.addingTimeInterval(61)) == .failed(.deviceCodeExpired))
        guard case .done(let tokens) = p.next(status: 200, data: tokenAnswer(), now: start.addingTimeInterval(40)) else {
            Issue.record("expected tokens"); return
        }
        #expect(tokens.refreshToken == "rt-1")
    }

    @Test func pollingFailures() {
        var p = DeviceCodePoller(challenge: challenge, startedAt: Fixture.now)
        #expect(p.next(status: 400, data: oauthError("expired_token"), now: Fixture.now) == .failed(.deviceCodeExpired))
        #expect(p.next(status: 400, data: oauthError("authorization_declined"), now: Fixture.now) == .failed(.declined))
        if case .failed(.invalidResponse) = p.next(status: 400, data: oauthError("bad_verification_code"), now: Fixture.now) {} else {
            Issue.record("expected invalidResponse")
        }
        if case .failed(.interactionRequired) = p.next(status: 400, data: oauthError("invalid_grant", codes: [50076]), now: Fixture.now) {} else {
            Issue.record("expected interactionRequired")
        }
        if case .failed(.oauth) = p.next(status: 400, data: oauthError("invalid_client", codes: [7000218]), now: Fixture.now) {} else {
            Issue.record("expected oauth")
        }
        if case .failed(.invalidResponse) = p.next(status: 500, data: Data("oops".utf8), now: Fixture.now) {} else {
            Issue.record("expected invalidResponse")
        }
        if case .failed(.invalidResponse) = p.next(status: 200, data: Data("{}".utf8), now: Fixture.now) {} else {
            Issue.record("expected invalidResponse for a 200 without a token")
        }
    }
}

@Suite("Sign-in: loopback redirect")
struct LoopbackTests {
    @Test func parseRedirects() {
        #expect(LoopbackRequest.parse("GET /?code=abc.def-1&state=s1 HTTP/1.1\r\nHost: localhost\r\n\r\n", expectedState: "s1") == .code("abc.def-1"))
        #expect(LoopbackRequest.parse("GET /?code=abc&state=other HTTP/1.1\r\n\r\n", expectedState: "s1") == .stateMismatch)
        #expect(LoopbackRequest.parse("GET /?code=abc HTTP/1.1\r\n\r\n", expectedState: "s1") == .stateMismatch)
        #expect(LoopbackRequest.parse("GET /favicon.ico HTTP/1.1\r\n\r\n", expectedState: "s1") == .ignored)
        #expect(LoopbackRequest.parse("GET / HTTP/1.1\r\n\r\n", expectedState: "s1") == .ignored)
        #expect(LoopbackRequest.parse("POST /?code=abc&state=s1 HTTP/1.1\r\n\r\n", expectedState: "s1") == .ignored)
        #expect(LoopbackRequest.parse("GET /other?code=abc&state=s1 HTTP/1.1\r\n\r\n", expectedState: "s1") == .ignored)
        #expect(LoopbackRequest.parse("", expectedState: "s1") == .ignored)
        let error = LoopbackRequest.parse(
            "GET /?error=access_denied&error_description=AADSTS65004%3A+User+declined+to+consent&state=s1 HTTP/1.1\r\n\r\n",
            expectedState: "s1")
        guard case .error(let info) = error else { Issue.record("expected error"); return }
        #expect(info.error == "access_denied")
        #expect(info.description == "AADSTS65004: User declined to consent")
        #expect(info.codes == [65004])
        #expect(LoopbackRequest.parse("GET /?error=access_denied&state=nope HTTP/1.1\r\n\r\n", expectedState: "s1") == .stateMismatch)
    }

    @Test func responsePagesAreEscapedAndUncached() {
        let ok = String(decoding: LoopbackRequest.response(for: .code("x")), as: UTF8.self)
        #expect(ok.hasPrefix("HTTP/1.1 200 OK\r\n"))
        #expect(ok.contains("You can close this tab"))
        #expect(ok.contains("Cache-Control: no-store") && ok.contains("Content-Security-Policy: default-src 'none'"))
        #expect(!ok.contains("x</"))
        let bad = String(decoding: LoopbackRequest.response(for: .error(OAuthErrorInfo(error: "<script>"))), as: UTF8.self)
        #expect(bad.hasPrefix("HTTP/1.1 400"))
        #expect(bad.contains("&lt;script&gt;") && !bad.contains("<script>"))
        #expect(String(decoding: LoopbackRequest.response(for: .ignored), as: UTF8.self).hasPrefix("HTTP/1.1 404"))
    }

    @Test func listenerReturnsTheCodeAndSkipsStrangers() async throws {
        let listener = try LoopbackListener()
        #expect(listener.port > 0)
        #expect(listener.redirectURI == "http://localhost:\(listener.port)")
        async let code = listener.waitForCallback(state: "s1", timeout: 10)
        try await Task.sleep(nanoseconds: 50_000_000)
        let favicon = browse(port: listener.port, "/favicon.ico")
        #expect(favicon.hasPrefix("HTTP/1.1 404"))
        let wrong = browse(port: listener.port, "/?code=evil&state=s2")
        #expect(wrong.hasPrefix("HTTP/1.1 400"))
        let page = browse(port: listener.port, "/?code=the-code&state=s1")
        #expect(page.hasPrefix("HTTP/1.1 200") && page.contains("close this tab"))
        #expect(try await code == "the-code")
    }

    @Test func listenerReportsTheIdentityPlatformsError() async throws {
        let listener = try LoopbackListener()
        async let code = listener.waitForCallback(state: "s1", timeout: 10)
        try await Task.sleep(nanoseconds: 50_000_000)
        browse(port: listener.port, "/?error=interaction_required&error_description=AADSTS50076%3A+MFA&state=s1")
        do {
            _ = try await code
            Issue.record("expected an error")
        } catch let error as SignInError {
            guard case .interactionRequired(let info) = error else { Issue.record("got \(error)"); return }
            #expect(info.codes == [50076])
        }
    }

    /// A local client sending its request a byte at a time gets an answer and
    /// is cut off at the connection deadline, and the real redirect still
    /// gets through afterwards.
    @Test func aTricklingClientCannotHoldTheListener() async throws {
        let listener = try LoopbackListener(connectionTimeout: 0.5)
        async let code = listener.waitForCallback(state: "s1", timeout: 20)
        try await Task.sleep(nanoseconds: 50_000_000)
        let port = listener.port
        let answered: (String, TimeInterval) = await withCheckedContinuation { continuation in
            Thread {
                guard let fd = TestSocket.connect(port: port) else { return continuation.resume(returning: ("", 0)) }
                defer { _ = TestSocket.close(fd) }
                let started = Date()
                let request = Array("GET /?code=slow&state=s1 HTTP/1.1\r\nHost: localhost\r\n\r\n".utf8)
                var response = [UInt8]()
                var buffer = [UInt8](repeating: 0, count: 4096)
                // One byte every 150 ms (the whole request would take about 8 s).
                for byte in request {
                    TestSocket.sendAll(fd, [byte])
                    if TestSocket.waitReadable(fd, milliseconds: 150) { break }
                }
                while Date().timeIntervalSince(started) < 10 {
                    let n = TestSocket.receive(fd, into: &buffer)
                    guard n > 0 else { break }
                    response += buffer[0..<n]
                }
                continuation.resume(returning: (String(decoding: response, as: UTF8.self), Date().timeIntervalSince(started)))
            }.start()
        }
        #expect(answered.0.hasPrefix("HTTP/1.1 404"))
        #expect(answered.1 < 3)
        let page = browse(port: listener.port, "/?code=the-code&state=s1")
        #expect(page.hasPrefix("HTTP/1.1 200"))
        #expect(try await code == "the-code")
    }

    /// Connections that send nothing do not queue the browser's redirect
    /// behind them: it is answered at once, while they are still open, and
    /// more of them than the listener serves at once only push out the oldest.
    @Test func silentConnectionsDoNotDelayTheRedirect() async throws {
        let listener = try LoopbackListener(connectionTimeout: 4)
        async let code = listener.waitForCallback(state: "s1", timeout: 20)
        try await Task.sleep(nanoseconds: 50_000_000)
        let idle = (0..<(LoopbackListener.maxConnections + 4)).compactMap { _ in TestSocket.connect(port: listener.port) }
        defer { for fd in idle { _ = TestSocket.close(fd) } }
        #expect(idle.count == LoopbackListener.maxConnections + 4)
        try await Task.sleep(nanoseconds: 100_000_000)
        let started = Date()
        let page = browse(port: listener.port, "/?code=the-code&state=s1")
        #expect(page.hasPrefix("HTTP/1.1 200"))
        #expect(Date().timeIntervalSince(started) < 2, "the redirect waited for the idle connections")
        #expect(try await code == "the-code")
    }

    /// What a client sends after its request head is read and dropped once it
    /// is answered, so the answer is not lost to a reset; and a client that
    /// never stops sending cannot hold the listener in that drain.
    @Test func moreThanTheHeadNeitherLosesTheAnswerNorHoldsTheListener() async throws {
        let listener = try LoopbackListener(connectionTimeout: 2)
        async let code = listener.waitForCallback(state: "s1", timeout: 20)
        try await Task.sleep(nanoseconds: 50_000_000)
        let port = listener.port
        let head = Array("GET /favicon.ico HTTP/1.1\r\nHost: localhost\r\n\r\n".utf8)
        // Head and body in one go; the answer is read only after all of it was sent.
        let answer: String = await withCheckedContinuation { continuation in
            Thread {
                guard let fd = TestSocket.connect(port: port) else { return continuation.resume(returning: "") }
                defer { _ = TestSocket.close(fd) }
                TestSocket.sendAll(fd, head + [UInt8](repeating: 0x78, count: 32 * 1024))
                var response = [UInt8]()
                var buffer = [UInt8](repeating: 0, count: 4096)
                while TestSocket.waitReadable(fd, milliseconds: 3000) {
                    let n = TestSocket.receive(fd, into: &buffer)
                    guard n > 0 else { break }
                    response += buffer[0..<n]
                }
                continuation.resume(returning: String(decoding: response, as: UTF8.self))
            }.start()
        }
        #expect(answer.hasPrefix("HTTP/1.1 404"), "the answer was lost: \(answer.prefix(40))")
        // A client that sends without end until the listener lets it go.
        let flooding = Thread {
            guard let fd = TestSocket.connect(port: port) else { return }
            defer { _ = TestSocket.close(fd) }
            let chunk = head + [UInt8](repeating: 0x78, count: 64 * 1024)
            let started = Date()
            while Date().timeIntervalSince(started) < 10, LoopbackSocket.send(fd, chunk[...]) > 0 {}
        }
        flooding.start()
        try await Task.sleep(nanoseconds: 200_000_000)
        let started = Date()
        let page = browse(port: port, "/?code=the-code&state=s1")
        #expect(page.hasPrefix("HTTP/1.1 200"))
        #expect(try await code == "the-code")
        #expect(Date().timeIntervalSince(started) < 2, "the flooding client held the listener")
    }

    @Test func listenerTimesOutAndCancels() async throws {
        let listener = try LoopbackListener()
        await #expect(throws: SignInError.timedOut) { _ = try await listener.waitForCallback(state: "s", timeout: 0.3) }

        let other = try LoopbackListener()
        let task = Task { try await other.waitForCallback(state: "s", timeout: 30) }
        try await Task.sleep(nanoseconds: 100_000_000)
        task.cancel()
        await #expect(throws: SignInError.cancelled) { _ = try await task.value }
    }
}

@Suite("Sign-in: token broker")
struct TokenBrokerTests {
    /// A broker on an in-memory store with a fake token endpoint.
    func broker(clock: TestClock = TestClock(), _ answer: @escaping @Sendable (URLRequest) throws -> (Data, Int)) -> (TokenBroker, RecordingTransport, InMemoryTokenStore) {
        let store = InMemoryTokenStore()
        let transport = RecordingTransport(handler: answer)
        return (TokenBroker(store: store, transport: transport, clock: { clock.now }), transport, store)
    }

    func signedInAccount(_ store: InMemoryTokenStore, refreshToken: String = "rt-0") throws -> SignedInAccount {
        let account = SignedInAccount(objectId: Fixture.userOID, homeTenantId: homeTenant, tenantId: homeTenant, username: "test@example.com",
                                      name: "Test User", clientId: testClientId, signedInAt: Fixture.now)
        try store.save(account, refreshToken: refreshToken)
        return account
    }

    @Test func browserSignInWithLoopbackAndPKCE() async throws {
        let seen = TestBox<URL>()
        let (broker, transport, store) = broker { request in
            let f = formFields(request)
            // The nonce of the authorize URL must come back in the id token.
            let nonce = seen.value.map { query($0)["nonce"] ?? "" }
            #expect(f["grant_type"] == "authorization_code" && f["code"] == "auth-code")
            return (tokenAnswer(nonce: nonce), 200)
        }
        let account = try await broker.signInWithBrowser(clientId: testClientId, timeout: 10) { url in
            seen.value = url
            let q = query(url)
            let port = UInt16(URL(string: q["redirect_uri"]!)!.port!)
            // The "browser": Entra redirects back with the code and our state.
            DispatchQueue.global().async { browse(port: port, "/?code=auth-code&state=\(q["state"]!)") }
            return true
        }
        #expect(account.id == "\(Fixture.userOID).\(homeTenant)")
        #expect(account.username == "test@example.com" && account.name == "Test User" && account.clientId == testClientId)
        #expect(try store.refreshToken(for: account.id) == "rt-1")

        let requests = await transport.requests
        #expect(requests.count == 1)
        let f = formFields(requests[0])
        let url = try #require(seen.value)
        #expect(url.host == "login.microsoftonline.com" && url.path == "/organizations/oauth2/v2.0/authorize")
        #expect(f["redirect_uri"] == query(url)["redirect_uri"])
        #expect(PKCE.challenge(for: f["code_verifier"]!) == query(url)["code_challenge"])

        // The sign-in's access token is cached: no refresh needed right away.
        _ = try await broker.accessToken(accountId: nil, tenantId: nil)
        #expect(await transport.requests.count == 1)
    }

    /// A nonce was sent: an id token without one (or no id token) is refused.
    @Test func aSentNonceMustComeBack() async throws {
        let (broker, _, store) = broker { _ in (Data(), 500) }
        func response(_ body: Data) throws -> TokenResponse { try #require(TokenResponse.parse(body)) }
        await #expect(throws: SignInError.nonceMismatch) {
            _ = try await broker.complete(try response(tokenAnswer(nonce: nil)), clientId: testClientId, nonce: "n-1")
        }
        var withoutIdToken = try #require(try JSONSerialization.jsonObject(with: tokenAnswer(nonce: "n-1")) as? [String: Any])
        withoutIdToken["id_token"] = nil
        await #expect(throws: SignInError.nonceMismatch) {
            _ = try await broker.complete(try response(try JSONSerialization.data(withJSONObject: withoutIdToken)), clientId: testClientId, nonce: "n-1")
        }
        await #expect(throws: SignInError.nonceMismatch) {
            _ = try await broker.complete(try response(tokenAnswer(nonce: "n-2")), clientId: testClientId, nonce: "n-1")
        }
        #expect(try store.accounts().isEmpty)
        // The right nonce, or none asked for (device code): saved.
        _ = try await broker.complete(try response(tokenAnswer(nonce: "n-1")), clientId: testClientId, nonce: "n-1")
        _ = try await broker.complete(try response(tokenAnswer(nonce: nil)), clientId: testClientId, nonce: nil)
        #expect(try store.accounts().count == 1)
    }

    @Test func browserSignInRejectsAMissingNonce() async throws {
        let (broker, _, store) = broker { _ in (tokenAnswer(nonce: nil), 200) }
        await #expect(throws: SignInError.nonceMismatch) {
            _ = try await broker.signInWithBrowser(clientId: testClientId, timeout: 10) { url in
                let q = query(url)
                let port = UInt16(URL(string: q["redirect_uri"]!)!.port!)
                DispatchQueue.global().async { browse(port: port, "/?code=c&state=\(q["state"]!)") }
                return true
            }
        }
        #expect(try store.accounts().isEmpty)
    }

    @Test func browserSignInRejectsAForeignNonce() async throws {
        let (broker, _, store) = broker { _ in (tokenAnswer(nonce: "someone-else"), 200) }
        await #expect(throws: SignInError.nonceMismatch) {
            _ = try await broker.signInWithBrowser(clientId: testClientId, timeout: 10) { url in
                let q = query(url)
                let port = UInt16(URL(string: q["redirect_uri"]!)!.port!)
                DispatchQueue.global().async { browse(port: port, "/?code=c&state=\(q["state"]!)") }
                return true
            }
        }
        #expect(try store.accounts().isEmpty)
    }

    @Test func browserSignInThatCannotOpenStopsListening() async throws {
        let (broker, transport, _) = broker { _ in (tokenAnswer(), 200) }
        await #expect(throws: SignInError.self) {
            _ = try await broker.signInWithBrowser(clientId: testClientId, timeout: 10) { _ in false }
        }
        #expect(await transport.requests.isEmpty)
    }

    @Test func perTenantTokensByRefreshTokenRedemption() async throws {
        let clock = TestClock()
        let counter = TestBox<Int>(0)
        let (broker, transport, store) = broker(clock: clock) { request in
            counter.value = (counter.value ?? 0) + 1
            let tenant = request.url!.pathComponents[1]
            return (tokenAnswer(tenant: tenant, refresh: "rt-\(counter.value!)", expiresIn: 3600, access: "for-\(tenant)"), 200)
        }
        let account = try signedInAccount(store)
        let home = try await broker.accessToken(accountId: account.id, tenantId: nil)
        #expect(JWT.claims(home)?["tid"] as? String == homeTenant)
        let other = try await broker.accessToken(accountId: account.id, tenantId: otherTenant)
        #expect(JWT.claims(other)?["tid"] as? String == otherTenant)
        var requests = await transport.requests
        #expect(requests.map { $0.url!.pathComponents[1] } == [homeTenant, otherTenant])
        #expect(formFields(requests[0])["refresh_token"] == "rt-0")
        // The rotated refresh token is kept and used next.
        #expect(formFields(requests[1])["refresh_token"] == "rt-1")
        #expect(try store.refreshToken(for: account.id) == "rt-2")

        // Cached until five minutes before expiry.
        clock.advance(3600 - 301)
        _ = try await broker.accessToken(accountId: account.id, tenantId: otherTenant)
        #expect(await transport.requests.count == 2)
        clock.advance(2)
        _ = try await broker.accessToken(accountId: account.id, tenantId: otherTenant)
        requests = await transport.requests
        #expect(requests.count == 3)
    }

    @Test func concurrentCallsShareOneRefresh() async throws {
        let (broker, transport, store) = broker { _ in (tokenAnswer(), 200) }
        let account = try signedInAccount(store)
        async let a = broker.accessToken(accountId: account.id, tenantId: otherTenant)
        async let b = broker.accessToken(accountId: account.id, tenantId: otherTenant)
        async let c = broker.accessToken(accountId: account.id, tenantId: otherTenant)
        let tokens = try await [a, b, c]
        #expect(Set(tokens).count == 1)
        #expect(await transport.requests.count == 1)
    }

    @Test func signOutDuringARefreshKeepsTheAccountRemoved() async throws {
        let gate = TransportGate()
        let store = InMemoryTokenStore()
        let broker = TokenBroker(store: store, transport: GatedTransport(gate: gate, answer: (tokenAnswer(refresh: "rt-rotated"), 200)))
        let account = try signedInAccount(store)
        let refresh = Task { try await broker.accessToken(accountId: account.id, tenantId: otherTenant) }
        await gate.waitUntilEntered()
        try await broker.signOut(account.id)
        gate.release()
        // The rotated refresh token of the late answer must not bring the account back.
        await #expect(throws: SignInError.notSignedIn) { _ = try await refresh.value }
        #expect(try store.accounts().isEmpty)
        #expect(try store.refreshToken(for: account.id) == nil)
    }

    /// Two processes (two brokers) sharing one store: `pimento logout` in one
    /// while the other refreshes. The late rotated token must not bring the
    /// account back; each broker's own generation cannot see the other.
    @Test(arguments: ["memory", "file"])
    func signOutInAnotherProcessDuringARefreshKeepsTheAccountRemoved(_ kind: String) async throws {
        let url = TestTemp.url("tokens").appendingPathComponent("tokens.json")
        let store: TokenStore = kind == "file" ? FileTokenStore(url: url) : InMemoryTokenStore()
        let account = SignedInAccount(objectId: Fixture.userOID, homeTenantId: homeTenant, tenantId: homeTenant, username: "test@example.com",
                                      name: "Test User", clientId: testClientId, signedInAt: Fixture.now)
        try store.save(account, refreshToken: "rt-0")
        let gate = TransportGate()
        let app = TokenBroker(store: store, transport: GatedTransport(gate: gate, answer: (tokenAnswer(refresh: "rt-rotated"), 200)))
        let cli = TokenBroker(store: store, transport: OfflineTransport())
        let refresh = Task { try await app.accessToken(accountId: account.id, tenantId: otherTenant) }
        await gate.waitUntilEntered()
        try await cli.signOut(account.id)
        gate.release()
        await #expect(throws: SignInError.notSignedIn) { _ = try await refresh.value }
        #expect(try store.accounts().isEmpty)
        #expect(try store.refreshToken(for: account.id) == nil)
        if kind == "file" { #expect(!FileManager.default.fileExists(atPath: url.path)) }
    }

    /// … and a sign-in again in the other process keeps its new token.
    @Test(arguments: ["memory", "file"])
    func signInAgainInAnotherProcessDuringARefreshKeepsTheNewToken(_ kind: String) async throws {
        let url = TestTemp.url("tokens").appendingPathComponent("tokens.json")
        let store: TokenStore = kind == "file" ? FileTokenStore(url: url) : InMemoryTokenStore()
        let account = SignedInAccount(objectId: Fixture.userOID, homeTenantId: homeTenant, tenantId: homeTenant, username: "test@example.com",
                                      name: "Test User", clientId: testClientId, signedInAt: Fixture.now)
        try store.save(account, refreshToken: "rt-0")
        let gate = TransportGate()
        let app = TokenBroker(store: store, transport: GatedTransport(gate: gate, answer: (tokenAnswer(refresh: "rt-rotated"), 200)))
        let refresh = Task { try await app.accessToken(accountId: account.id, tenantId: otherTenant) }
        await gate.waitUntilEntered()
        try store.save(account, refreshToken: "rt-new")
        gate.release()
        _ = try await refresh.value
        #expect(try store.refreshToken(for: account.id) == "rt-new")
        // Without anything in between, the rotated token replaces the old one.
        let plain = TokenBroker(store: store, transport: RecordingTransport { _ in (tokenAnswer(refresh: "rt-next"), 200) })
        _ = try await plain.accessToken(accountId: account.id, tenantId: otherTenant)
        #expect(try store.refreshToken(for: account.id) == "rt-next")
    }

    @Test func signInAgainDuringARefreshKeepsTheNewSignIn() async throws {
        let gate = TransportGate()
        let store = InMemoryTokenStore()
        let broker = TokenBroker(store: store, transport: GatedTransport(gate: gate, answer: (tokenAnswer(refresh: "rt-old-rotated"), 200)))
        let account = try signedInAccount(store, refreshToken: "rt-old")
        let refresh = Task { try await broker.accessToken(accountId: account.id, tenantId: nil) }
        await gate.waitUntilEntered()
        // A new sign-in (here: its result) with another app registration.
        let otherClient = "1f1e1d1c-1b1a-4119-8118-171615141312"
        let fresh = try await broker.complete(
            TokenResponse.parse(tokenAnswer(refresh: "rt-new"))!, clientId: otherClient, nonce: nil)
        gate.release()
        _ = try? await refresh.value
        #expect(try store.refreshToken(for: fresh.id) == "rt-new")
        #expect(try store.accounts().map(\.clientId) == [otherClient])
    }

    @Test func providerFeedsPIMService() async throws {
        let (broker, _, store) = broker { _ in (tokenAnswer(), 200) }
        _ = try signedInAccount(store)
        let provider = broker.provider(accountId: nil, tenantId: nil)
        let token = try await provider.accessToken()
        #expect(JWT.identity(fromToken: token)?.objectId == Fixture.userOID)
    }

    @Test func refreshErrorsAreMapped() async throws {
        let (broker, _, store) = broker { _ in
            (oauthError("invalid_grant", "AADSTS50076: MFA", codes: [50076], claims: #"{"access_token":{}}"#), 400)
        }
        await #expect(throws: SignInError.notSignedIn) { _ = try await broker.accessToken(accountId: nil, tenantId: nil) }
        _ = try signedInAccount(store)
        do {
            _ = try await broker.accessToken(accountId: nil, tenantId: nil)
            Issue.record("expected an error")
        } catch let error as SignInError {
            #expect(error.needsLogin)
            #expect(error.claims == #"{"access_token":{}}"#)
        }
        // The account stays: signing in again replaces its token.
        #expect(try store.accounts().count == 1)
    }

    @Test func networkFailuresAreReadable() async throws {
        let (broker, _, store) = broker { _ in throw URLError(.notConnectedToInternet) }
        _ = try signedInAccount(store)
        do {
            _ = try await broker.accessToken(accountId: nil, tenantId: nil)
            Issue.record("expected an error")
        } catch let error as SignInError {
            guard case .network = error else { Issue.record("got \(error)"); return }
            #expect(!error.needsLogin)
        }
    }

    @Test func deviceCodeFlowPollsWithBackoff() async throws {
        let clock = TestClock()
        let polls = TestBox<Int>(0)
        let (broker, transport, store) = broker(clock: clock) { request in
            if request.url!.path.hasSuffix("/devicecode") {
                return (Data(#"{"device_code":"DC","user_code":"ABCD-EFGH","verification_uri":"https://microsoft.com/devicelogin","expires_in":900,"interval":5}"#.utf8), 200)
            }
            polls.value = (polls.value ?? 0) + 1
            switch polls.value! {
            case 1: return (oauthError("authorization_pending"), 400)
            case 2: return (oauthError("slow_down"), 400)
            default: return (tokenAnswer(), 200)
            }
        }
        let challenge = try await broker.startDeviceCode(clientId: testClientId, tenant: homeTenant)
        #expect(challenge.userCode == "ABCD-EFGH")
        let slept = TestBox<[TimeInterval]>([])
        let account = try await broker.finishDeviceCode(challenge, clientId: testClientId, tenant: homeTenant) { s in
            slept.value = (slept.value ?? []) + [s]
            clock.advance(s)
        }
        #expect(slept.value == [5, 5, 10])
        #expect(account.tenantId == homeTenant)
        #expect(try store.refreshToken(for: account.id) == "rt-1")
        let paths = await transport.requests.map { $0.url!.path }
        #expect(paths == ["/\(homeTenant)/oauth2/v2.0/devicecode"] + Array(repeating: "/\(homeTenant)/oauth2/v2.0/token", count: 3))
    }

    @Test func deviceCodeExpires() async throws {
        let clock = TestClock()
        let (broker, _, _) = broker(clock: clock) { _ in (oauthError("authorization_pending"), 400) }
        let challenge = DeviceCodeChallenge(deviceCode: "DC", userCode: "U", verificationURL: URL(string: "https://microsoft.com/devicelogin")!,
                                            expiresIn: 30, interval: 10, message: nil)
        await #expect(throws: SignInError.deviceCodeExpired) {
            _ = try await broker.finishDeviceCode(challenge, clientId: testClientId) { clock.advance($0) }
        }
    }

    @Test func signOut() async throws {
        let (broker, transport, store) = broker { _ in (tokenAnswer(), 200) }
        let account = try signedInAccount(store)
        _ = try await broker.accessToken(accountId: account.id, tenantId: nil)
        try await broker.signOut(account.id)
        #expect(try store.accounts().isEmpty)
        await #expect(throws: SignInError.notSignedIn) { _ = try await broker.accessToken(accountId: account.id, tenantId: nil) }
        #expect(await transport.requests.count == 1)
    }

    @Test func accountChoice() async throws {
        let (broker, _, store) = broker { _ in (tokenAnswer(), 200) }
        var older = SignedInAccount(objectId: "o1", homeTenantId: "t1", tenantId: "t1", username: "a", name: nil, clientId: testClientId,
                                    signedInAt: Fixture.now.addingTimeInterval(-60))
        try store.save(older, refreshToken: "x")
        let newer = SignedInAccount(objectId: "o2", homeTenantId: "t2", tenantId: "t2", username: "b", name: nil, clientId: testClientId,
                                    signedInAt: Fixture.now)
        try store.save(newer, refreshToken: "y")
        #expect(try await broker.account(nil) == newer)
        #expect(try await broker.account(older.id) == older)
        // The chosen account is gone: an error, never another account's tokens.
        await #expect(throws: SignInError.notSignedIn) { _ = try await broker.account("gone") }
        await #expect(throws: SignInError.notSignedIn) { _ = try await broker.accessToken(accountId: "gone", tenantId: nil) }
        older.name = "Older"
        #expect(older.displayName == "Older <a>")
    }

    @Test func authContextBuildsTheRightProvider() async throws {
        #expect(AuthContext.azureCLI.tokens(tenantId: "t") is AzureCLITokenProvider)
        #expect(AuthContext.azureCLI.loginCommand(tenant: "t") == "az login --tenant t")
        let (broker, _, _) = broker { _ in (tokenAnswer(), 200) }
        let pimento = AuthContext(selection: AuthSelection(source: .pimento, origin: .saved), broker: broker, accountId: nil)
        #expect(pimento.tokens(tenantId: nil) is BrokerTokenProvider)
        #expect(pimento.loginCommand(tenant: nil) == "pimento login")
        #expect(pimento.loginCommand(tenant: "t") == "pimento login --tenant t")
        let orphan = AuthContext(selection: AuthSelection(source: .pimento, origin: .saved), broker: nil, accountId: nil)
        await #expect(throws: SignInError.notSignedIn) { _ = try await orphan.tokens(tenantId: nil).accessToken() }
    }
}

/// Holds the request it gets until `release()`; `waitUntilEntered()` returns
/// once the request is being held.
final class TransportGate: @unchecked Sendable {
    private let entered = AsyncStream<Void>.makeStream()
    private let released = AsyncStream<Void>.makeStream()

    func enter() async {
        entered.continuation.yield()
        var it = released.stream.makeAsyncIterator()
        _ = await it.next()
    }

    func waitUntilEntered() async {
        var it = entered.stream.makeAsyncIterator()
        _ = await it.next()
    }

    func release() { released.continuation.yield() }
}

struct GatedTransport: HTTPTransport {
    let gate: TransportGate
    let answer: (Data, Int)

    func send(_ request: URLRequest) async throws -> (Data, Int) {
        await gate.enter()
        return answer
    }
}

final class TestBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T?
    init(_ value: T? = nil) { stored = value }
    var value: T? {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

@Suite("Sign-in: settings, stores and precedence")
struct SignInStorageTests {
    func tempDir() -> URL {
        TestTemp.url("signin")
    }


    let account = SignedInAccount(objectId: Fixture.userOID, homeTenantId: homeTenant, tenantId: otherTenant, username: "test@example.com",
                                  name: "Test User", clientId: testClientId, signedInAt: Fixture.now)

    @Test func authSourcePrecedence() throws {
        let env = [AuthSourceResolver.environmentVariable: "pimento"]
        #expect(try AuthSourceResolver.resolve(commandLine: "az", environment: env, saved: .pimento) == AuthSelection(source: .az, origin: .commandLine))
        #expect(try AuthSourceResolver.resolve(commandLine: nil, environment: env, saved: .az) == AuthSelection(source: .pimento, origin: .environment))
        #expect(try AuthSourceResolver.resolve(commandLine: " ", environment: [:], saved: .pimento) == AuthSelection(source: .pimento, origin: .saved))
        #expect(try AuthSourceResolver.resolve(commandLine: nil, environment: [:], saved: nil) == AuthSelection(source: .az, origin: .default))
        #expect(try AuthSourceResolver.resolve(commandLine: "Azure-CLI", environment: [:], saved: nil).source == .az)
        #expect(throws: AuthSourceError.invalid("msal")) { try AuthSourceResolver.resolve(commandLine: "msal", environment: [:], saved: nil) }
        #expect(throws: AuthSourceError.invalid("x")) {
            try AuthSourceResolver.resolve(commandLine: nil, environment: [AuthSourceResolver.environmentVariable: "x"], saved: nil)
        }
        #expect(AuthSelection(source: .az, origin: .environment).isOverride)
        #expect(!AuthSelection(source: .az, origin: .saved).isOverride)
    }

    @Test func clientIdPrecedence() throws {
        let a = "aaaaaaaa-0000-4000-8000-000000000001", b = "bbbbbbbb-0000-4000-8000-000000000002"
        let c = "cccccccc-0000-4000-8000-000000000003", d = "dddddddd-0000-4000-8000-000000000004"
        let env = [AuthSourceResolver.clientIdVariable: b]
        #expect(try AuthSourceResolver.clientId(commandLine: a.uppercased(), environment: env, saved: c, account: d) == a)
        #expect(try AuthSourceResolver.clientId(commandLine: nil, environment: env, saved: c, account: d) == b)
        #expect(try AuthSourceResolver.clientId(commandLine: nil, environment: [:], saved: c, account: d) == c)
        #expect(try AuthSourceResolver.clientId(commandLine: nil, environment: [:], saved: "junk", account: d) == d)
        #expect(throws: SignInError.invalidClientId("junk")) { try AuthSourceResolver.clientId(commandLine: "junk", environment: [:], saved: c) }
        #expect(throws: SignInError.missingClientId) { try AuthSourceResolver.clientId(commandLine: nil, environment: [:], saved: nil) }
    }

    @Test func inMemoryStore() throws {
        let store = InMemoryTokenStore()
        try store.save(account, refreshToken: "a")
        try store.save(account, refreshToken: "b")
        #expect(try store.accounts() == [account])
        #expect(try store.refreshToken(for: account.id) == "b")
        try store.removeAll()
        #expect(try store.accounts().isEmpty && store.refreshToken(for: account.id) == nil)
    }

    @Test func fileStoreIsPrivate() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("pimento/tokens.json")
        let store = FileTokenStore(url: url)
        #expect(try store.accounts().isEmpty)
        try store.save(account, refreshToken: "secret-rt")
        #expect(hasMode(url.path, 0o600))
        #expect(hasMode(url.deletingLastPathComponent().path, 0o700))
        #expect(try store.accounts() == [account])
        #expect(try store.refreshToken(for: account.id) == "secret-rt")
        // Rewrites keep the mode, and leave no temporary files behind (only the empty lock file).
        try store.save(account, refreshToken: "rotated")
        #expect(hasMode(url.path, 0o600))
        #expect(try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path).sorted() == ["tokens.json", "tokens.json.lock"])
        #expect(hasMode(url.path + ".lock", 0o600))
        #expect(try FileTokenStore(url: url).refreshToken(for: account.id) == "rotated")
        try store.remove(account.id)
        #expect(!FileManager.default.fileExists(atPath: url.path))

        try Data("not json".utf8).write(to: url)
        #expect(throws: SignInError.self) { try store.accounts() }
    }

    /// The app and the CLI (each its own store value) saving at the same time.
    @Test func concurrentFileStoreWritersLoseNoAccount() async throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("pimento/tokens.json")
        let writers = 8, perWriter = 10
        await withTaskGroup(of: Void.self) { group in
            for w in 0..<writers {
                group.addTask {
                    let store = FileTokenStore(url: url)
                    for i in 0..<perWriter {
                        let a = SignedInAccount(objectId: "o\(w)-\(i)", homeTenantId: "t", tenantId: "t", username: nil, name: nil,
                                                clientId: testClientId, signedInAt: Date())
                        try? store.save(a, refreshToken: "rt")
                    }
                }
            }
        }
        #expect(try FileTokenStore(url: url).accounts().count == writers * perWriter)
    }

    #if !os(Windows)
    @Test(.enabled(if: getuid() != 0, "root ignores folder permissions"))
    func fileStoreSignOutThatCannotDeleteTheFileFails() throws {
        let dir = tempDir()
        let folder = dir.appendingPathComponent("pimento")
        defer {
            _ = chmod(folder.path, 0o700)
            try? FileManager.default.removeItem(at: dir)
        }
        let store = FileTokenStore(url: folder.appendingPathComponent("tokens.json"))
        try store.save(account, refreshToken: "secret-rt")
        // A folder the file cannot be deleted from.
        #expect(chmod(folder.path, 0o500) == 0)
        #expect(throws: SignInError.self) { try store.remove(account.id) }
        #expect(try store.refreshToken(for: account.id) == "secret-rt")
    }
    #endif

    @Test func fileStoreLocation() {
        for platform in [HostPlatform.macOS, .linux] {
            #expect(FileTokenStore.location(environment: [:], home: "/home/u", platform: platform).path == filePath("/home/u/.config/pimento/tokens.json"))
            #expect(FileTokenStore.location(environment: ["XDG_CONFIG_HOME": "/x"], home: "/home/u", platform: platform).path
                == filePath("/x/pimento/tokens.json"))
        }
        #expect(FileTokenStore.location(environment: [FileTokenStore.fileVariable: "~/t.json"], home: "/home/u").path == filePath("/home/u/t.json"))
        #expect(TokenStores.standard(environment: [TokenStores.storeVariable: "file", FileTokenStore.fileVariable: "/tmp/x.json"]) is FileTokenStore)
    }

    @Test func authSettingsRoundTripAndLenientRead() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = AuthSettingsStore(url: dir.appendingPathComponent("auth.json"))
        #expect(store.load() == AuthSettings())
        try store.update { $0.source = .pimento; $0.clientId = testClientId; $0.accountId = account.id }
        #expect(store.load() == AuthSettings(source: .pimento, clientId: testClientId, accountId: account.id))
        #expect(hasMode(store.url.path, 0o600))
        try Data(#"{"source":"msal","clientId":"nope","accountId":"x"}"#.utf8).write(to: store.url)
        #expect(store.load() == AuthSettings(source: nil, clientId: nil, accountId: "x"))
        try Data("garbage".utf8).write(to: store.url)
        #expect(store.load() == AuthSettings())
    }
}

@Suite("Sign-in: opening the browser")
struct BrowserLaunchTests {
    static let authorizeURL = URL(string: "https://login.microsoftonline.com/organizations/oauth2/v2.0/authorize?client_id=00000000-0000-4000-8000-000000000001"
        + "&redirect_uri=http%3A%2F%2F127.0.0.1%3A50123&state=STATE-abc123&nonce=NONCE-def456&code_challenge=CHALLENGE-ghi789"
        + "&code_challenge_method=S256&login_hint=o'brien%40example.com")!

    /// The opener gets only a file path: no part of the authorize URL is a process argument.
    @Test func theAuthorizeURLNeverAppearsInTheOpenersArguments() throws {
        let base = TestTemp.url("browser")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let argv = TestBox<[String]>([])
        let page = try #require(BrowserLaunch.openThroughPage(Self.authorizeURL, in: base) { path in
            argv.value = (argv.value ?? []) + [path]
            return true
        })
        let args = try #require(argv.value)
        #expect(args == [page.file.path])
        for secret in ["STATE-abc123", "NONCE-def456", "CHALLENGE-ghi789", "login.microsoftonline.com", "authorize", "?", "&", "127.0.0.1"] {
            #expect(!args.joined(separator: " ").contains(secret), "\(secret)")
        }
        // The page sends the browser on: the whole URL, escaped for HTML.
        let html = try String(contentsOf: page.file, encoding: .utf8)
        #expect(html.contains("http-equiv=\"refresh\""))
        #expect(html.contains("state=STATE-abc123&amp;nonce=NONCE-def456&amp;code_challenge=CHALLENGE-ghi789"))
        #expect(html.contains("o%27brien") && !html.contains("o'brien"))
        #expect(!html.contains("&nonce"))
        // Private to the user: 0600 in a 0700 folder of its own.
        #expect(hasMode(page.file.path, 0o600))
        #expect(hasMode(page.directory.path, 0o700))
        #expect(page.directory.deletingLastPathComponent().standardizedFileURL.path == base.standardizedFileURL.path)
        #expect(page.directory.lastPathComponent.hasPrefix("pimento-signin-"))
        page.remove()
        #expect(!FileManager.default.fileExists(atPath: page.directory.path))
    }

    @Test func aFailedOpenLeavesNothingBehind() throws {
        let base = TestTemp.url("browser")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        #expect(BrowserLaunch.openThroughPage(Self.authorizeURL, in: base) { _ in false } == nil)
        #expect(try FileManager.default.contentsOfDirectory(atPath: base.path).isEmpty)
        // Two pages never share a folder.
        let a = try BrowserLaunch.writeRedirectPage(for: Self.authorizeURL, in: base)
        let b = try BrowserLaunch.writeRedirectPage(for: Self.authorizeURL, in: base)
        #expect(a.directory != b.directory)
        let pages = RedirectPages()
        pages.add(a)
        pages.add(b)
        pages.removeAll()
        #expect(try FileManager.default.contentsOfDirectory(atPath: base.path).isEmpty)
    }

    /// The CLI's opener: LaunchServices on macOS, a redirect page elsewhere;
    /// never `process.arguments = [url…]`.
    @Test func theCLIOpenerPassesNoURLAsAnArgument() throws {
        let main = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/pimento/main.swift")
        let text = try String(contentsOf: main, encoding: .utf8)
        #expect(!text.contains("url.absoluteString"))
        #expect(text.contains("LSOpenCFURLRef(url as CFURL, nil)"))
        #expect(text.contains("BrowserLaunch.openThroughPage(url"))
        #expect(text.contains("redirectPages.removeAll()"))
        // Windows: the page's path straight to ShellExecuteW, never through cmd.exe or a shell string.
        #expect(text.contains("ShellExecuteW(nil, verb, file, nil, nil, SW_SHOWNORMAL)"))
        #expect(!text.contains("cmd.exe /c") && !text.contains("\"start\""))
    }
}

@Suite("Sign-in: the loopback listener owns both sides of localhost")
struct LoopbackDualStackTests {
    /// Another program's listener on [::1] (IPv6 only), on a port of the
    /// kernel's choosing; nil when this system has no IPv6 loopback.
    static func squatter() -> (fd: TestSocket.Handle, port: UInt16)? {
        try? LoopbackSocket.startup()
        guard case .bound(let fd) = LoopbackListener.bindIPv6Loopback(port: 0) else { return nil }
        guard let port = LoopbackSocket.localPort(fd) else {
            TestSocket.close(fd)
            return nil
        }
        return (fd, port)
    }

    static var hasIPv6Loopback: Bool {
        guard let s = squatter() else { return false }
        TestSocket.close(s.fd)
        return true
    }

    @Test(.enabled(if: hasIPv6Loopback, "no IPv6 loopback here"))
    func aPortWhoseIPv6SideIsTakenIsNeverUsed() throws {
        let squat = try #require(Self.squatter())
        defer { TestSocket.close(squat.fd) }
        #expect(LoopbackListener.bindIPv6Loopback(port: squat.port) == .taken)
        // Only that port to try: sign-in fails rather than leaving ::1 to the squatter.
        #expect(throws: SignInError.self) { _ = try LoopbackListener(connectionTimeout: 5, ports: [squat.port]) }
        // With more tries it moves to a port where both sides are its own.
        let listener = try LoopbackListener(connectionTimeout: 5, ports: [squat.port, 0, 0])
        defer { listener.close() }
        #expect(listener.port != squat.port)
        #expect(LoopbackListener.bindIPv6Loopback(port: listener.port) == .taken)
        #expect(listener.redirectURI == "http://localhost:\(listener.port)")
    }

    @Test func theListenerAlwaysHoldsTheIPv6SideWhenThereIsOne() throws {
        for _ in 0..<5 {
            let listener = try LoopbackListener()
            defer { listener.close() }
            if Self.hasIPv6Loopback { #expect(LoopbackListener.bindIPv6Loopback(port: listener.port) == .taken) }
        }
        #expect(LoopbackListener.meansNoIPv6(TestSocket.noAddressFamily) && LoopbackListener.meansNoIPv6(TestSocket.addressNotAvailable))
        #expect(!LoopbackListener.meansNoIPv6(TestSocket.addressInUse) && !LoopbackListener.meansNoIPv6(TestSocket.accessDenied))
    }

    /// No other socket can bind the listener's port, not even with
    /// `SO_REUSEADDR`: on Windows that option would otherwise let another
    /// program take the port over (and the redirect with it), which the
    /// listener's `SO_EXCLUSIVEADDRUSE` prevents.
    @Test func nobodyElseCanBindTheListenersPort() throws {
        let listener = try LoopbackListener()
        defer { listener.close() }
        let v4 = try #require(LoopbackSocket.makeSocket(family: AF_INET))
        defer { TestSocket.close(v4) }
        LoopbackSocket.setOption(v4, SOL_SOCKET, SO_REUSEADDR, 1)
        #expect(!LoopbackSocket.bind(v4, to: LoopbackSocket.ipv4Loopback(port: listener.port)))
        if Self.hasIPv6Loopback, let v6 = LoopbackSocket.makeSocket(family: AF_INET6) {
            defer { TestSocket.close(v6) }
            LoopbackSocket.setIPv6Only(v6)
            LoopbackSocket.setOption(v6, SOL_SOCKET, SO_REUSEADDR, 1)
            #expect(!LoopbackSocket.bind(v6, to: LoopbackSocket.ipv6Loopback(port: listener.port)))
        }
    }
}
