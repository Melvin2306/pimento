import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Pimento's own sign-in: runs the interactive flows, keeps refresh tokens in
/// the token store and ARM access tokens in memory (per account and tenant,
/// renewed five minutes before they expire), and redeems the refresh token
/// against whichever tenant is asked for.
public actor TokenBroker {
    public nonisolated let store: TokenStore
    let transport: HTTPTransport
    let clock: @Sendable () -> Date
    private var cache: [String: (token: String, expires: Date)] = [:]
    private var inflight: [String: Task<String, Error>] = [:]
    /// Bumped whenever an account is signed out or signed in again: a refresh
    /// that started before must not write its rotated refresh token back.
    private var generation: [String: Int] = [:]

    /// Access tokens are renewed this long before their expiry.
    public static let refreshMargin: TimeInterval = 5 * 60

    /// `transport` is wrapped in `SignInTransport`: nothing leaves for another host.
    public init(store: TokenStore, transport: HTTPTransport = URLSessionTransport(), clock: @escaping @Sendable () -> Date = { Date() }) {
        self.store = store
        self.transport = SignInTransport(transport)
        self.clock = clock
    }

    /// A token provider for `PIMService` and the tenant listing. `accountId`
    /// nil: the most recently signed-in account; `tenantId` nil: its sign-in tenant.
    public nonisolated func provider(accountId: String?, tenantId: String?) -> TokenProvider {
        BrokerTokenProvider(broker: self, accountId: accountId, tenantId: tenantId)
    }

    // MARK: Accounts

    public func accounts() throws -> [SignedInAccount] { try store.accounts() }

    /// The account `id`, or the most recent one when `id` is nil. An `id`
    /// that is gone (signed out, perhaps by another process) is an error:
    /// tokens never silently come from another account.
    public func account(_ id: String?) throws -> SignedInAccount {
        let all = try store.accounts()
        if let id {
            guard let match = all.first(where: { $0.id == id }) else { throw SignInError.notSignedIn }
            return match
        }
        guard let latest = all.first else { throw SignInError.notSignedIn }
        return latest
    }

    public func signOut(_ accountId: String) throws {
        try store.remove(accountId)
        forget(accountId)
    }

    public func signOutAll() throws {
        let ids = (try? store.accounts().map(\.id)) ?? []
        try store.removeAll()
        for id in ids { generation[id, default: 0] += 1 }
        cache = [:]
        inflight = [:]
    }

    private func forget(_ accountId: String) {
        generation[accountId, default: 0] += 1
        for key in cache.keys where key.hasPrefix(accountId + "|") { cache[key] = nil }
        for key in inflight.keys where key.hasPrefix(accountId + "|") { inflight[key] = nil }
    }

    // MARK: Access tokens

    /// An ARM access token for `tenantId` (nil: the account's sign-in tenant).
    public func accessToken(accountId: String?, tenantId: String?) async throws -> String {
        let account = try account(accountId)
        let tenant = (tenantId?.isEmpty == false ? tenantId! : account.tenantId).lowercased()
        let key = "\(account.id)|\(tenant)"
        if let cached = cache[key], cached.expires.timeIntervalSince(clock()) > Self.refreshMargin { return cached.token }
        if let running = inflight[key] { return try await running.value }
        let task = Task { try await self.redeem(account: account, tenant: tenant, key: key) }
        inflight[key] = task
        defer { inflight[key] = nil }
        return try await task.value
    }

    private func redeem(account: SignedInAccount, tenant: String, key: String) async throws -> String {
        guard let refreshToken = try store.refreshToken(for: account.id) else { throw SignInError.notSignedIn }
        let authority = try MicrosoftIdentity.authority(tenant)
        let started = generation[account.id, default: 0]
        let response = try await post(TokenRequest.refresh(refreshToken, clientId: account.clientId, authority: authority))
        // Signed out (or in again) meanwhile: keep nothing of this answer, or
        // the rotated refresh token would bring the removed account back.
        guard generation[account.id, default: 0] == started else { throw SignInError.notSignedIn }
        // Entra rotates refresh tokens; keep the newest, but only in place of
        // the one redeemed: another process may have signed the account out
        // (or in again) meanwhile, which this broker's generation cannot see.
        // Not replaced and gone: signed out elsewhere, so keep nothing.
        // Not replaced but present: another process rotated it first; keep that one.
        if let rotated = response.refreshToken, rotated != refreshToken,
           try !store.replaceRefreshToken(account.id, expected: refreshToken, with: rotated),
           try store.refreshToken(for: account.id) == nil {
            throw SignInError.notSignedIn
        }
        remember(response, key: key)
        return response.accessToken
    }

    private func remember(_ response: TokenResponse, key: String) {
        cache[key] = (response.accessToken, clock().addingTimeInterval(TimeInterval(response.expiresIn)))
    }

    /// POSTs to the token endpoint and maps the answer.
    func post(_ request: URLRequest) async throws -> TokenResponse {
        let (data, status) = try await send(request)
        guard status == 200 else { throw SignInError.from(status: status, data: data) }
        guard let response = TokenResponse.parse(data) else { throw SignInError.invalidResponse("no access token") }
        return response
    }

    func send(_ request: URLRequest) async throws -> (Data, Int) {
        do { return try await transport.send(request) } catch let error as SignInTransport.Refused {
            throw error
        } catch {
            throw SignInError.network(error.localizedDescription)
        }
    }

    // MARK: Signing in

    /// Saves the account of a fresh sign-in and caches its access token.
    /// When a `nonce` was sent, the id token must carry exactly that nonce:
    /// one without an id token or without a nonce is refused too.
    func complete(_ response: TokenResponse, clientId: String, nonce: String?) throws -> SignedInAccount {
        let id = response.idToken.flatMap(IDTokenClaims.init(token:))
        if let nonce {
            guard let echoed = id?.nonce, LoopbackRequest.constantTimeEqual(echoed, nonce) else { throw SignInError.nonceMismatch }
        }
        let access = JWT.identity(fromToken: response.accessToken)
        guard let objectId = response.homeAccount?.objectId ?? id?.objectId ?? access?.objectId.lowercased(),
              let signInTenant = id?.tenantId ?? access?.tenantId?.lowercased() else {
            throw SignInError.invalidResponse("the answer names no account")
        }
        guard let refreshToken = response.refreshToken, !refreshToken.isEmpty else {
            throw SignInError.invalidResponse("no refresh token (is offline_access allowed?)")
        }
        let account = SignedInAccount(
            objectId: objectId, homeTenantId: response.homeAccount?.tenantId ?? signInTenant, tenantId: signInTenant,
            username: id?.username ?? access?.upn, name: id?.name ?? access?.name, clientId: clientId, signedInAt: clock())
        try store.save(account, refreshToken: refreshToken)
        forget(account.id)
        remember(response, key: "\(account.id)|\(signInTenant)")
        return account
    }

    /// Authorization code flow with PKCE and a loopback redirect. `open`
    /// shows the URL to the user (the system browser in the app; tests act as
    /// the browser) and returns false if it could not.
    public func signInWithBrowser(
        clientId: String, tenant: String? = nil, loginHint: String? = nil, claims: String? = nil,
        timeout: TimeInterval = 300, open: @escaping @Sendable (URL) async -> Bool
    ) async throws -> SignedInAccount {
        let authority = try MicrosoftIdentity.authority(tenant)
        let listener = try LoopbackListener()
        defer { listener.close() }
        let request = AuthorizationRequest(clientId: clientId, authority: authority, redirectURI: listener.redirectURI,
                                           loginHint: loginHint, claims: claims)
        async let code = listener.waitForCallback(state: request.state, timeout: timeout)
        guard await open(request.url) else {
            listener.close()
            _ = try? await code
            throw SignInError.loopback("could not open the browser")
        }
        let response = try await post(TokenRequest.authorizationCode(try await code, request: request))
        return try complete(response, clientId: clientId, nonce: request.nonce)
    }

    /// Step 1 of the device code flow: the code to show the user.
    public func startDeviceCode(clientId: String, tenant: String? = nil) async throws -> DeviceCodeChallenge {
        let authority = try MicrosoftIdentity.authority(tenant)
        let (data, status) = try await send(TokenRequest.deviceCode(clientId: clientId, authority: authority))
        guard status == 200 else { throw SignInError.from(status: status, data: data) }
        guard let challenge = DeviceCodeChallenge.parse(data) else { throw SignInError.invalidResponse("no device code") }
        return challenge
    }

    /// Step 2: polls until the user finished (or the code expired, or the task
    /// was cancelled), then saves the account.
    public func finishDeviceCode(
        _ challenge: DeviceCodeChallenge, clientId: String, tenant: String? = nil,
        sleep: @escaping @Sendable (TimeInterval) async -> Void = { try? await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) }
    ) async throws -> SignedInAccount {
        let authority = try MicrosoftIdentity.authority(tenant)
        var poller = DeviceCodePoller(challenge: challenge, startedAt: clock())
        var step = poller.firstWait
        while true {
            switch step {
            case .done(let response): return try complete(response, clientId: clientId, nonce: nil)
            case .failed(let error): throw error
            case .wait(let seconds):
                await sleep(TimeInterval(seconds))
                if Task.isCancelled { throw SignInError.cancelled }
                let (data, status) = try await send(TokenRequest.deviceCodeToken(challenge.deviceCode, clientId: clientId, authority: authority))
                step = poller.next(status: status, data: data, now: clock())
            }
        }
    }
}

struct BrokerTokenProvider: TokenProvider {
    let broker: TokenBroker
    let accountId: String?
    let tenantId: String?

    func accessToken() async throws -> String {
        try await broker.accessToken(accountId: accountId, tenantId: tenantId)
    }
}

/// Builds the token provider for the chosen auth source.
public struct AuthContext: Sendable {
    public let selection: AuthSelection
    /// Pimento sign-in only.
    public let broker: TokenBroker?
    public let accountId: String?
    /// The Azure CLI's tokens for a tenant (the demo simulates them).
    public let azureCLI: @Sendable (String?) -> TokenProvider

    public init(selection: AuthSelection, broker: TokenBroker?, accountId: String?,
                azureCLI: @escaping @Sendable (String?) -> TokenProvider = { AzureCLITokenProvider(tenantId: $0) }) {
        self.selection = selection
        self.broker = broker
        self.accountId = accountId
        self.azureCLI = azureCLI
    }

    public static let azureCLI = AuthContext(selection: AuthSelection(source: .az, origin: .default), broker: nil, accountId: nil)

    public var source: AuthSource { selection.source }

    /// az for `.az`; the broker's account for `.pimento`.
    public func tokens(tenantId: String?) -> TokenProvider {
        switch source {
        case .az: return azureCLI(tenantId)
        case .pimento:
            guard let broker else { return FailingTokenProvider(error: SignInError.notSignedIn) }
            return broker.provider(accountId: accountId, tenantId: tenantId)
        }
    }

    /// The command that fixes a sign-in error.
    public func loginCommand(tenant: String?) -> String {
        switch source {
        case .az: return AzureCLIError.loginCommand(tenant: tenant)
        case .pimento:
            guard let tenant, !tenant.isEmpty else { return "pimento login" }
            return "pimento login --tenant \(tenant)"
        }
    }
}

struct FailingTokenProvider: TokenProvider {
    let error: Error
    func accessToken() async throws -> String { throw error }
}
