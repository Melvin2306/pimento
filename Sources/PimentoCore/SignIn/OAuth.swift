import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The Microsoft identity platform (v2.0) endpoints Pimento's own sign-in uses.
/// Credentials go to `login.microsoftonline.com` (token endpoint) and access
/// tokens to `management.azure.com` (ARM), nowhere else.
public enum MicrosoftIdentity {
    public static let host = "login.microsoftonline.com"
    /// The authority for "any work or school account" (multi-tenant apps).
    public static let organizations = "organizations"
    /// Delegated ARM access plus a refresh token and the user's name.
    public static let scopes = ["\(ARM.baseURL)/user_impersonation", "offline_access", "openid", "profile"]
    public static var scope: String { scopes.joined(separator: " ") }
    /// The redirect URI registered on the app: loopback, any port (Entra ignores
    /// the port of `http://localhost`).
    public static let redirectBase = "http://localhost"

    /// `organizations`, or a tenant GUID / domain (validated: it becomes a path segment).
    public static func authority(_ tenant: String?) throws -> String {
        guard let tenant = tenant?.trimmingCharacters(in: .whitespacesAndNewlines), !tenant.isEmpty else { return organizations }
        if tenant.lowercased() == organizations { return organizations }
        guard TenantResolver.isValid(tenant) else { throw TenantError.invalid(tenant) }
        return tenant
    }

    public static func authorizeURL(authority: String) -> URL {
        URL(string: "https://\(host)/\(authority)/oauth2/v2.0/authorize")!
    }

    public static func tokenURL(authority: String) -> URL {
        URL(string: "https://\(host)/\(authority)/oauth2/v2.0/token")!
    }

    public static func deviceCodeURL(authority: String) -> URL {
        URL(string: "https://\(host)/\(authority)/oauth2/v2.0/devicecode")!
    }

    /// True for the token and device-code endpoints over HTTPS on login.microsoftonline.com.
    public static func isCredentialEndpoint(_ url: URL?) -> Bool {
        guard let url, url.scheme == "https", url.host?.lowercased() == host, url.port == nil else { return false }
        return url.path.hasSuffix("/oauth2/v2.0/token") || url.path.hasSuffix("/oauth2/v2.0/devicecode")
    }

    /// A client ID is an application (client) GUID.
    public static func isValidClientId(_ value: String) -> Bool {
        UUID(uuidString: value.trimmingCharacters(in: .whitespacesAndNewlines)) != nil
    }
}

/// Refuses every request that is not a POST to Microsoft's token or
/// device-code endpoint: refresh tokens and codes cannot go anywhere else.
public struct SignInTransport: HTTPTransport {
    public struct Refused: Error, LocalizedError, Equatable {
        public let url: String
        public var errorDescription: String? { "Refused to send sign-in data to \(url): only \(MicrosoftIdentity.host) is allowed." }
    }

    let base: HTTPTransport

    public init(_ base: HTTPTransport = URLSessionTransport()) { self.base = base }

    public func send(_ request: URLRequest) async throws -> (Data, Int) {
        guard request.httpMethod == "POST", MicrosoftIdentity.isCredentialEndpoint(request.url) else {
            throw Refused(url: request.url?.absoluteString ?? "?")
        }
        return try await base.send(request)
    }
}

/// RFC 7636 proof key: a random verifier and its S256 challenge.
public struct PKCE: Equatable, Sendable {
    public let verifier: String
    public var challenge: String { Self.challenge(for: verifier) }
    public static let method = "S256"

    public init(verifier: String) { self.verifier = verifier }

    /// 32 random bytes, base64url: 43 characters.
    public static func generate() -> PKCE { PKCE(verifier: OAuthRandom.string(bytes: 32)) }

    public static func challenge(for verifier: String) -> String {
        Base64URL.encode(SHA256.hash(Array(verifier.utf8)))
    }
}

public enum OAuthRandom {
    /// base64url of `bytes` random bytes. `SystemRandomNumberGenerator` is
    /// cryptographically secure on every platform Swift runs on.
    public static func string(bytes: Int) -> String {
        var rng = SystemRandomNumberGenerator()
        return Base64URL.encode((0..<bytes).map { _ in UInt8.random(in: .min ... .max, using: &rng) })
    }
}

/// One interactive sign-in attempt: what goes into the authorize URL and what
/// the redirect and the id token must echo back.
public struct AuthorizationRequest: Equatable, Sendable {
    public var clientId: String
    public var authority: String
    public var redirectURI: String
    public var pkce: PKCE
    public var state: String
    public var nonce: String
    public var loginHint: String?
    /// A claims challenge (JSON) from a previous error, e.g. Conditional Access.
    public var claims: String?
    /// `select_account` lets the user pick or add an account.
    public var prompt: String? = "select_account"

    public init(clientId: String, authority: String, redirectURI: String, pkce: PKCE = .generate(),
                state: String = OAuthRandom.string(bytes: 24), nonce: String = OAuthRandom.string(bytes: 24),
                loginHint: String? = nil, claims: String? = nil) {
        self.clientId = clientId
        self.authority = authority
        self.redirectURI = redirectURI
        self.pkce = pkce
        self.state = state
        self.nonce = nonce
        self.loginHint = loginHint
        self.claims = claims
    }

    public var url: URL {
        var c = URLComponents(url: MicrosoftIdentity.authorizeURL(authority: authority), resolvingAgainstBaseURL: false)!
        var items = [
            URLQueryItem(name: "client_id", value: clientId),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_mode", value: "query"),
            URLQueryItem(name: "scope", value: MicrosoftIdentity.scope),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "nonce", value: nonce),
            URLQueryItem(name: "code_challenge", value: pkce.challenge),
            URLQueryItem(name: "code_challenge_method", value: PKCE.method),
        ]
        if let prompt { items.append(URLQueryItem(name: "prompt", value: prompt)) }
        if let loginHint, !loginHint.isEmpty { items.append(URLQueryItem(name: "login_hint", value: loginHint)) }
        if let claims, !claims.isEmpty { items.append(URLQueryItem(name: "claims", value: claims)) }
        c.queryItems = items
        // URLComponents leaves `+` and `/` alone in queries; encode them strictly.
        c.percentEncodedQuery = c.percentEncodedQuery?
            .replacingOccurrences(of: "+", with: "%2B")
        return c.url!
    }
}

/// `application/x-www-form-urlencoded` bodies for the token endpoint.
public enum TokenRequest {
    public static func authorizationCode(_ code: String, request: AuthorizationRequest) -> URLRequest {
        post(MicrosoftIdentity.tokenURL(authority: request.authority), [
            ("client_id", request.clientId),
            ("grant_type", "authorization_code"),
            ("scope", MicrosoftIdentity.scope),
            ("code", code),
            ("redirect_uri", request.redirectURI),
            ("code_verifier", request.pkce.verifier),
            ("client_info", "1"),
        ])
    }

    public static func refresh(_ refreshToken: String, clientId: String, authority: String, claims: String? = nil) -> URLRequest {
        var fields = [
            ("client_id", clientId),
            ("grant_type", "refresh_token"),
            ("scope", MicrosoftIdentity.scope),
            ("refresh_token", refreshToken),
            ("client_info", "1"),
        ]
        if let claims, !claims.isEmpty { fields.append(("claims", claims)) }
        return post(MicrosoftIdentity.tokenURL(authority: authority), fields)
    }

    public static func deviceCode(clientId: String, authority: String) -> URLRequest {
        post(MicrosoftIdentity.deviceCodeURL(authority: authority), [
            ("client_id", clientId),
            ("scope", MicrosoftIdentity.scope),
        ])
    }

    public static func deviceCodeToken(_ deviceCode: String, clientId: String, authority: String) -> URLRequest {
        post(MicrosoftIdentity.tokenURL(authority: authority), [
            ("client_id", clientId),
            ("grant_type", "urn:ietf:params:oauth:grant-type:device_code"),
            ("device_code", deviceCode),
            ("client_info", "1"),
        ])
    }

    static func post(_ url: URL, _ fields: [(String, String)]) -> URLRequest {
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = Data(formEncode(fields).utf8)
        return request
    }

    /// RFC 3986 unreserved characters stay, everything else is percent-encoded.
    public static func formEncode(_ fields: [(String, String)]) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        // `alphanumerics` includes non-ASCII letters; percent-encode those too.
        func enc(_ s: String) -> String {
            s.unicodeScalars.map { u in
                u.isASCII && allowed.contains(u) ? String(u) : String(u).utf8.map { String(format: "%%%02X", $0) }.joined()
            }.joined()
        }
        return fields.map { "\(enc($0.0))=\(enc($0.1))" }.joined(separator: "&")
    }

    /// Parses a form body back into fields (tests and the loopback query).
    public static func formDecode(_ body: String) -> [String: String] {
        var result: [String: String] = [:]
        for pair in body.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let key = String(parts[0]).replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? String(parts[0])
            let value = parts.count > 1 ? (String(parts[1]).replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? "") : ""
            result[key] = value
        }
        return result
    }
}

/// A successful token endpoint response.
public struct TokenResponse: Equatable, Sendable {
    public let accessToken: String
    public let refreshToken: String?
    public let idToken: String?
    /// Seconds from receipt. The expiry is computed from this, on our clock,
    /// so a skewed Mac clock does not make a fresh token look expired.
    public let expiresIn: Int
    public let scope: String?
    /// `client_info`: base64url JSON with the home account (`uid`, `utid`).
    public let clientInfo: String?

    public init(accessToken: String, refreshToken: String?, idToken: String?, expiresIn: Int, scope: String?, clientInfo: String?) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.idToken = idToken
        self.expiresIn = expiresIn
        self.scope = scope
        self.clientInfo = clientInfo
    }

    static func parse(_ data: Data) -> TokenResponse? {
        guard let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let access = o["access_token"] as? String, !access.isEmpty else { return nil }
        let expires = (o["expires_in"] as? Int) ?? (o["expires_in"] as? String).flatMap(Int.init) ?? 3600
        return TokenResponse(accessToken: access, refreshToken: o["refresh_token"] as? String, idToken: o["id_token"] as? String,
                             expiresIn: max(0, expires), scope: o["scope"] as? String, clientInfo: o["client_info"] as? String)
    }

    /// `uid` and `utid` of `client_info`.
    public var homeAccount: (objectId: String, tenantId: String)? {
        guard let clientInfo, let data = Base64URL.decode(clientInfo),
              let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let uid = o["uid"] as? String, let utid = o["utid"] as? String, !uid.isEmpty, !utid.isEmpty else { return nil }
        return (uid.lowercased(), utid.lowercased())
    }

    /// Seconds the issuer's clock is ahead of ours (`iat` of the access token
    /// vs. `now`), when the token carries one.
    public func clockSkew(now: Date) -> TimeInterval? {
        guard let iat = JWT.claims(accessToken)?["iat"] as? Double ?? (JWT.claims(accessToken)?["iat"] as? Int).map(Double.init) else { return nil }
        return iat - now.timeIntervalSince1970
    }
}

/// Claims of the id token Pimento reads (its signature is not checked: it
/// comes straight from the token endpoint over TLS, OIDC Core 3.1.3.7).
public struct IDTokenClaims: Equatable, Sendable {
    public let objectId: String?
    public let tenantId: String?
    public let username: String?
    public let name: String?
    public let nonce: String?

    public init(objectId: String?, tenantId: String?, username: String?, name: String?, nonce: String?) {
        self.objectId = objectId
        self.tenantId = tenantId
        self.username = username
        self.name = name
        self.nonce = nonce
    }

    public init?(token: String) {
        guard let c = JWT.claims(token) else { return nil }
        objectId = (c["oid"] as? String)?.lowercased()
        tenantId = (c["tid"] as? String)?.lowercased()
        username = (c["preferred_username"] as? String) ?? (c["upn"] as? String) ?? (c["email"] as? String)
        name = c["name"] as? String
        nonce = c["nonce"] as? String
    }
}

/// An error from the authorize or token endpoint (RFC 6749 §5.2 plus Entra's fields).
public struct OAuthErrorInfo: Equatable, Sendable {
    public let error: String
    public let description: String?
    /// Entra's `error_codes`: the numbers of the AADSTS codes.
    public let codes: [Int]
    /// A claims challenge to send with the next interactive sign-in.
    public let claims: String?
    public let suberror: String?

    public init(error: String, description: String? = nil, codes: [Int] = [], claims: String? = nil, suberror: String? = nil) {
        self.error = error
        self.description = description
        self.codes = codes.isEmpty ? Self.codes(in: description ?? "") : codes
        self.claims = claims
        self.suberror = suberror
    }

    public static func parse(_ data: Data) -> OAuthErrorInfo? {
        guard let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let error = o["error"] as? String else { return nil }
        let codes = (o["error_codes"] as? [Int]) ?? []
        return OAuthErrorInfo(error: error, description: o["error_description"] as? String, codes: codes,
                              claims: o["claims"] as? String, suberror: o["suberror"] as? String)
    }

    /// `AADSTS50076` → 50076, every occurrence, in order.
    static func codes(in text: String) -> [Int] {
        var result: [Int] = []
        var rest = Substring(text)
        while let r = rest.range(of: "AADSTS") {
            let digits = rest[r.upperBound...].prefix { $0.isNumber }
            if let n = Int(digits) { result.append(n) }
            rest = rest[r.upperBound...]
        }
        return result
    }

    /// The first line of Entra's description (it appends trace and correlation IDs).
    public var shortDescription: String? {
        description?.split(whereSeparator: \.isNewline).first.map { String($0).trimmingCharacters(in: .whitespaces) }
    }

    /// Signing in again (in the browser or with a code) is the fix.
    public var needsInteraction: Bool {
        if ["invalid_grant", "interaction_required", "login_required", "consent_required"].contains(error) { return true }
        return codes.contains { AADSTS.interactive.contains($0) }
    }

    /// What the user reads: a known AADSTS code in plain words, else Entra's text.
    public var message: String {
        for code in codes {
            if let known = AADSTS.explanation(code) { return "\(known) (AADSTS\(code))." }
        }
        switch error {
        case "access_denied": return "Sign-in was cancelled or access was denied."
        case "invalid_client": return "The client ID is not a public client app registration (see README › Pimento sign-in)."
        case "unauthorized_client": return "The app registration does not allow this sign-in flow (see README › Pimento sign-in)."
        case "invalid_scope": return "Azure Service Management (user_impersonation) is not available to this app registration."
        default: return shortDescription ?? error
        }
    }
}

/// Readable explanations for the AADSTS codes users run into most.
public enum AADSTS {
    /// Codes that a new interactive sign-in can fix.
    static let interactive: Set<Int> = [50076, 50079, 50078, 50158, 50173, 70043, 700082, 70008, 50132, 50133, 65001, 50058, 53003, 54005]

    public static func explanation(_ code: Int) -> String? {
        switch code {
        case 50076, 50079: "Multi-factor authentication is required. Sign in again and complete MFA"
        case 50078: "Your MFA sign-in has expired. Sign in again"
        case 50158: "An external security challenge must be completed. Sign in again in the browser"
        case 53003: "Blocked by a Conditional Access policy"
        case 53000, 530003: "Conditional Access requires a compliant or managed device"
        case 50097: "Device authentication is required by Conditional Access"
        case 50173, 50132, 50133: "Your session was revoked (password change or admin action). Sign in again"
        case 70043, 700082, 70008: "Your sign-in has expired. Sign in again"
        case 70000, 54005: "The sign-in code was already used or has expired. Sign in again"
        case 50148, 501481: "The PKCE verifier did not match. Sign in again"
        case 65001: "The app registration has no consent for Azure Service Management. Grant consent (see README › Pimento sign-in)"
        case 65004: "Consent was declined"
        case 700016: "The client ID was not found in this tenant. Check it, or make the app registration multi-tenant"
        case 50011, 500113, 50196: "The redirect URI does not match. Add the platform \"Mobile and desktop applications\" with http://localhost"
        case 7000218: "The app registration does not allow public client flows. Turn on \"Allow public client flows\""
        case 70011: "The requested scope is not valid for this app registration"
        case 50020: "Your account is not a member or guest of this tenant"
        case 50034: "This account does not exist in the tenant"
        case 50053: "The account is locked"
        case 50057: "The account is disabled"
        case 50055: "The password has expired"
        case 50126: "Wrong user name or password"
        case 90002: "The tenant was not found"
        case 50058: "No signed-in session. Sign in again"
        case 700024, 700025: "The request was outside its valid time range. Check the Mac's clock"
        default: nil
        }
    }
}

/// A claims challenge (Conditional Access, MFA, authentication context) that
/// must go with the next interactive sign-in.
public enum ClaimsChallenge {
    /// Finds one in an ARM error message (PIM's authentication-context errors
    /// append `&claims=<URL-encoded JSON>`) or a `WWW-Authenticate` value
    /// (`claims="<base64 JSON>"`). Returns the JSON, or nil.
    public static func find(in text: String) -> String? {
        var rest = Substring(text)
        while let r = rest.range(of: "claims=") {
            let tail = rest[r.upperBound...]
            if tail.hasPrefix("\"") {
                let value = tail.dropFirst().prefix { $0 != "\"" }
                if let data = Data(base64Encoded: String(value)) ?? Base64URL.decode(String(value)),
                   let json = String(data: data, encoding: .utf8), isJSONObject(json) { return json }
                if isJSONObject(String(value)) { return String(value) }
            } else {
                let value = tail.prefix { !$0.isWhitespace && !"&\"'),".contains($0) }
                if let decoded = String(value).removingPercentEncoding, isJSONObject(decoded) { return decoded }
            }
            rest = tail
        }
        return nil
    }

    static func isJSONObject(_ s: String) -> Bool {
        s.hasPrefix("{") && (try? JSONSerialization.jsonObject(with: Data(s.utf8))) is [String: Any]
    }
}

public extension ActivationOutcome {
    /// The claims challenge in a failed request's message, if Azure sent one.
    var claimsChallenge: String? {
        switch self {
        case .policyViolation(_, let message), .failed(_, let message): ClaimsChallenge.find(in: message)
        default: nil
        }
    }
}
