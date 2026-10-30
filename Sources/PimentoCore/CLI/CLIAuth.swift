import Foundation

/// `pimento login`, `pimento logout` and `pimento whoami`: Pimento's own
/// sign-in, an alternative to the Azure CLI (`--auth pimento`).
extension CLIRunner {
    /// How long `login` waits for the browser.
    static let browserTimeout: TimeInterval = 300

    func login(_ o: LoginOptions) async throws -> CLIExit {
        let settings = env.signIn.settings?.load() ?? AuthSettings()
        let tenant = try resolveTenant(o.tenant).tenantId
        let previous = try? await broker.account(settings.accountId)
        let clientId = try AuthSourceResolver.clientId(
            commandLine: o.clientId, environment: env.variables, saved: settings.clientId, account: previous?.clientId)
        let account: SignedInAccount
        if o.deviceCode || !env.signIn.browserSignIn {
            if !o.deviceCode {
                err(errStyle.dim("Browser sign-in is not available on this platform; signing in with a device code."))
            }
            let challenge = try await broker.startDeviceCode(clientId: clientId, tenant: tenant)
            err("To sign in, open \(errStyle.bold(challenge.verificationURL.absoluteString)) and enter the code \(errStyle.bold(challenge.userCode)).")
            err(errStyle.dim("Waiting for you to finish (the code expires in \(WaitTimeout.label(TimeInterval(challenge.expiresIn))); Ctrl-C stops)…"))
            account = try await broker.finishDeviceCode(challenge, clientId: clientId, tenant: tenant, sleep: env.sleep)
        } else {
            let open = env.signIn.openURL, runner = self
            defer { env.signIn.endBrowserSignIn() }
            account = try await broker.signInWithBrowser(
                clientId: clientId, tenant: tenant, loginHint: previous?.username, claims: settings.claimsChallenge,
                timeout: Self.browserTimeout
            ) { url in
                // The sign-in URL (state, nonce, PKCE challenge) is shown only
                // when no browser could be opened: not in scrollback or logs otherwise.
                if await open(url) {
                    runner.err("Opened your browser to sign in.")
                } else {
                    runner.err("Could not open a browser. To sign in, visit:")
                    runner.err("  \(url.absoluteString)")
                }
                runner.err(runner.errStyle.dim("Waiting up to \(WaitTimeout.label(Self.browserTimeout)) (no browser here? use --device-code)…"))
                // Without a browser here, the URL can still be opened by hand.
                return true
            }
        }
        let wasSource = settings.source
        var saved = true
        do {
            try env.signIn.settings?.update {
                $0.source = .pimento
                $0.clientId = clientId
                $0.accountId = account.id
                $0.claimsChallenge = nil
            }
        } catch {
            saved = false
            warnSettingsNotSaved(error)
        }
        if o.json {
            out(CLIJSON.encode(CLIJSON.Login(account: .init(account, isDefault: true), source: AuthSource.pimento.rawValue,
                                             store: env.signIn.store.label)))
            return .success
        }
        out("Signed in as \(account.displayName) · tenant \(account.tenantId)")
        if saved, auth.selection.isOverride == false, wasSource != .pimento {
            err(errStyle.dim("Pimento sign-in is now the auth source of the app and the CLI. `--auth az` or Settings › Account switches back."))
        }
        return .success
    }

    func logout(_ o: LogoutOptions) async throws -> CLIExit {
        var settings = env.signIn.settings?.load() ?? AuthSettings()
        let accounts = try await broker.accounts()
        let removed: [SignedInAccount]
        if o.all {
            removed = accounts
            try await broker.signOutAll()
        } else if let current = accounts.first(where: { $0.id == settings.accountId }) ?? accounts.first {
            removed = [current]
            try await broker.signOut(current.id)
        } else {
            removed = []
        }
        let remaining = accounts.filter { a in !removed.contains { $0.id == a.id } }
        if removed.contains(where: { $0.id == settings.accountId }) { settings.accountId = remaining.first?.id }
        let backToAz = remaining.isEmpty && settings.source == .pimento
        if backToAz { settings.source = nil }
        settings.claimsChallenge = remaining.isEmpty ? nil : settings.claimsChallenge
        do { try env.signIn.settings?.save(settings) } catch { warnSettingsNotSaved(error) }
        if o.json {
            out(CLIJSON.encode(CLIJSON.Logout(removed: removed.map(\.id), remaining: remaining.count)))
            return .success
        }
        guard !removed.isEmpty else {
            out("Not signed in with Pimento. (For the Azure CLI, run `az logout`.)")
            return .success
        }
        for account in removed { out("Signed out \(account.displayName).") }
        if backToAz { err(errStyle.dim("No Pimento sign-in left: the Azure CLI is the auth source again.")) }
        return .success
    }

    /// The sign-in itself worked, but the auth source, client ID or account
    /// in auth.json may now be stale: say so instead of pretending.
    private func warnSettingsNotSaved(_ error: Error) {
        let location = env.signIn.settings.map { $0.url.path } ?? "auth.json"
        err(errStyle.yellow("Warning:") + " could not save the sign-in settings to \(location): \(error.localizedDescription)")
    }

    func whoami(_ o: WhoamiOptions) async throws -> CLIExit {
        let tenant = try resolveTenant(o.tenant)
        let settings = env.signIn.settings?.load() ?? AuthSettings()
        let accounts = (try? await broker.accounts()) ?? []
        let current = accounts.first { $0.id == settings.accountId } ?? accounts.first
        var identity: Identity?
        var failure: Error?
        do {
            // Through the service factory, like every other command (tests fake it).
            let token = try await makeService(tenant.tenantId, true).tokens.accessToken()
            identity = JWT.identity(fromToken: token)
            if identity == nil { failure = PIMServiceError.noIdentity }
        } catch {
            failure = error
        }
        if o.json {
            out(CLIJSON.encode(CLIJSON.WhoAmI(
                source: auth.source.rawValue, origin: auth.selection.origin.rawValue, user: identity.map(CLIJSON.User.init),
                tenantId: identity?.tenantId ?? tenant.tenantId, error: failure?.localizedDescription,
                accounts: accounts.map { CLIJSON.Account($0, isDefault: $0.id == current?.id) },
                clientId: settings.clientId, tokenStore: env.signIn.store.label)))
            return failure.map { CLIExit.code(for: $0) } ?? .success
        }
        let origin = switch auth.selection.origin {
        case .commandLine: "--auth"
        case .environment: "$\(AuthSourceResolver.environmentVariable)"
        case .saved: "saved setting"
        case .default: "default"
        }
        out("Auth source: \(auth.source.title) (\(origin))")
        if let identity {
            let who = [identity.name, identity.upn.map { "<\($0)>" }].compactMap { $0 }.joined(separator: " ")
            out("Signed in as \(who.isEmpty ? identity.objectId : who)")
            out(outStyle.dim("Object ID \(identity.objectId) · tenant \(identity.tenantId ?? tenant.tenantId ?? defaultTenantLabel)"))
        }
        if !accounts.isEmpty || auth.source == .pimento {
            out("")
            out("Pimento sign-in (\(env.signIn.store.label))\(settings.clientId.map { ", client ID \($0)" } ?? ""):")
            if accounts.isEmpty { out(outStyle.dim("  no accounts; run `pimento login`")) }
            for account in accounts {
                let mark = account.id == current?.id ? "*" : " "
                out("  \(mark) \(account.displayName)" + outStyle.dim(" · tenant \(account.tenantId)"))
            }
        }
        guard let failure else { return .success }
        return report(failure, tenant: tenant.tenantId)
    }
}

extension CLIJSON {
    public struct Account: Encodable, Equatable, Sendable {
        public let id: String
        public let objectId: String
        public let username: String?
        public let name: String?
        public let tenantId: String
        public let homeTenantId: String
        public let clientId: String
        public let signedInAt: String
        public let isDefault: Bool

        public init(_ a: SignedInAccount, isDefault: Bool) {
            id = a.id
            objectId = a.objectId
            username = a.username
            name = a.name
            tenantId = a.tenantId
            homeTenantId = a.homeTenantId
            clientId = a.clientId
            signedInAt = AzureDate.format(a.signedInAt)
            self.isDefault = isDefault
        }
    }

    public struct Login: Encodable, Sendable {
        public let account: Account
        public let source: String
        public let store: String
    }

    public struct Logout: Encodable, Sendable {
        public let removed: [String]
        public let remaining: Int
    }

    public struct WhoAmI: Encodable, Sendable {
        public let source: String
        public let origin: String
        public let user: User?
        public let tenantId: String?
        public let error: String?
        public let accounts: [Account]
        public let clientId: String?
        public let tokenStore: String
    }
}
