import AppKit
import Foundation
import PimentoCore

/// Settings › Account: the auth source, and Pimento's own sign-in (browser
/// or device code). The flows and the token store are in PimentoCore.
extension AppModel {
    /// The account tokens come from (the chosen one, else the most recent).
    var currentAccount: SignedInAccount? {
        signedInAccounts.first { $0.id == authSettings.accountId } ?? signedInAccounts.first
    }

    var trimmedClientIdDraft: String { clientIdDraft.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// nil when the field is empty or a valid GUID; else what is wrong.
    var clientIdProblem: String? {
        let id = trimmedClientIdDraft
        guard !id.isEmpty, !MicrosoftIdentity.isValidClientId(id) else { return nil }
        return "Not a client ID: use the Application (client) ID GUID of your app registration."
    }

    /// The client ID sign-in uses: `$PIMENTO_CLIENT_ID`, the field, the saved one, the account's.
    var effectiveClientId: String? {
        try? AuthSourceResolver.clientId(commandLine: nil, environment: ProcessInfo.processInfo.environment,
                                         saved: MicrosoftIdentity.isValidClientId(trimmedClientIdDraft) ? trimmedClientIdDraft : authSettings.clientId,
                                         account: currentAccount?.clientId)
    }

    var canSignIn: Bool { effectiveClientId != nil && !isSigningIn }

    var isSigningIn: Bool {
        switch signInState {
        case .browser, .requestingCode, .deviceCode: true
        case .idle, .failed: false
        }
    }

    /// Reads the accounts (attributes only: no secret, so no Keychain prompt).
    func reloadAccounts() async {
        signedInAccounts = (try? await broker.accounts()) ?? []
    }

    /// Saves the client ID field when it holds a GUID (or clears it when empty).
    func commitClientId() {
        let id = trimmedClientIdDraft
        if id.isEmpty {
            authSettings.clientId = nil
        } else if MicrosoftIdentity.isValidClientId(id) {
            authSettings.clientId = id.lowercased()
            clientIdDraft = id.lowercased()
        }
    }

    /// Switches between the Azure CLI and Pimento sign-in, and reloads.
    func setAuthSource(_ source: AuthSource) {
        guard !authSelection.isOverride, !isActivating else { return }
        authSettings.source = source
        guard authSelection.source != source else { return }
        authSelection = AuthSelection(source: source, origin: .saved)
        knownTenants = []
        restartSession()
        Task { await loadTenants() }
    }

    /// Opens Settings on the Account tab.
    func openAccountSettings() {
        settingsTab = .account
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// The tenant to sign in to: the one chosen in the app, else the home tenant.
    private var signInTenant: String? { tenant.tenantId }

    /// Authorization code flow: opens the system browser, waits for the
    /// loopback redirect (5 minutes at most).
    func signInWithBrowser() {
        commitClientId()
        guard let clientId = effectiveClientId, !isSigningIn else { return }
        signInState = .browser
        let claims = authSettings.claimsChallenge, hint = currentAccount?.username, tenant = signInTenant
        signInTask = Task {
            do {
                let account = try await broker.signInWithBrowser(clientId: clientId, tenant: tenant, loginHint: hint, claims: claims) { url in
                    await MainActor.run { NSWorkspace.shared.open(url) }
                }
                await finishSignIn(account, clientId: clientId)
            } catch {
                signInFailed(error)
            }
        }
    }

    /// Device code flow: shows the code in a sheet, polls until it is entered.
    func signInWithDeviceCode(inMainWindow: Bool = false) {
        commitClientId()
        guard let clientId = effectiveClientId, !isSigningIn else { return }
        signInState = .requestingCode
        deviceCodeInMainWindow = inMainWindow
        showDeviceCodeSheet = true
        let tenant = signInTenant
        signInTask = Task {
            do {
                let challenge = try await broker.startDeviceCode(clientId: clientId, tenant: tenant)
                signInState = .deviceCode(challenge)
                let account = try await broker.finishDeviceCode(challenge, clientId: clientId, tenant: tenant)
                await finishSignIn(account, clientId: clientId)
            } catch {
                signInFailed(error)
            }
        }
    }

    func cancelSignIn() {
        signInTask?.cancel()
        signInTask = nil
        signInState = .idle
        showDeviceCodeSheet = false
    }

    private func signInFailed(_ error: Error) {
        guard !Task.isCancelled, (error as? SignInError) != .cancelled else {
            if signInState != .idle { signInState = .idle }
            return
        }
        signInState = .failed(error.localizedDescription)
    }

    private func finishSignIn(_ account: SignedInAccount, clientId: String) async {
        signInTask = nil
        signInState = .idle
        showDeviceCodeSheet = false
        authSettings.clientId = clientId
        authSettings.accountId = account.id
        authSettings.claimsChallenge = nil
        clientIdDraft = clientId
        await reloadAccounts()
        // A new session replaces the service: let a running operation finish first.
        while isActivating { try? await Task.sleep(for: .milliseconds(300)) }
        if authSelection.isOverride {
            restartSession()
        } else {
            authSettings.source = .pimento
            authSelection = AuthSelection(source: .pimento, origin: .saved)
            knownTenants = []
            restartSession()
            Task { await loadTenants() }
        }
        banner = Banner(kind: .success, text: "Signed in as \(account.displayName).")
    }

    /// Makes `account` the one tokens come from.
    func useAccount(_ account: SignedInAccount) {
        // Not while an operation runs: restarting the session would swap its service.
        guard authSettings.accountId != account.id, !isActivating else { return }
        authSettings.accountId = account.id
        if authSource == .pimento { restartSession() }
    }

    /// Deletes the account's refresh token (and its cached access tokens).
    func signOut(_ account: SignedInAccount) {
        guard !isActivating else { return }
        Task {
            do { try await broker.signOut(account.id) } catch {
                banner = Banner(kind: .error, text: error.localizedDescription)
            }
            if authSettings.accountId == account.id { authSettings.accountId = nil }
            await reloadAccounts()
            if authSource == .pimento { restartSession() }
        }
    }

    func signOutAll() {
        guard !isActivating else { return }
        Task {
            do { try await broker.signOutAll() } catch {
                banner = Banner(kind: .error, text: error.localizedDescription)
            }
            authSettings.accountId = nil
            authSettings.claimsChallenge = nil
            await reloadAccounts()
            if authSource == .pimento { restartSession() }
        }
    }

    /// A failed request that carries a claims challenge (MFA, authentication
    /// context): keep it for the next sign-in and say so.
    func noteClaimsChallenge(in outcomes: [ActivationOutcome]) {
        guard authSource == .pimento, let claims = outcomes.lazy.compactMap(\.claimsChallenge).first else { return }
        authSettings.claimsChallenge = claims
        banner = Banner(kind: .error, text: "Azure asks for more verification (MFA or an authentication context). "
            + "Sign in again under Settings › Account, then activate again.")
    }
}
