import Foundation

/// `pimento --demo` (or `PIMENTO_DEMO=1`): every command runs against the
/// demo simulator, in a temporary folder of its own, on a virtual clock that
/// waits by moving forward (`wait` and Renew's retries take no real time).
/// Each command starts from the same demo data; nothing is sent anywhere and
/// none of the user's files, settings or tokens are read or written.
extension CLIEnvironment {
    /// Variables a demo command must not take from the real environment:
    /// the user's tenant, auth source, client ID and token store.
    static let demoIgnoredVariables = [
        TenantResolver.environmentVariable, AuthSourceResolver.environmentVariable, AuthSourceResolver.clientIdVariable,
        TokenStores.storeVariable, FileTokenStore.fileVariable,
    ]

    /// `base` (terminal, time zone) with everything Azure- and file-facing
    /// taken from `session`.
    public static func demo(from base: CLIEnvironment, session: DemoSession) -> CLIEnvironment {
        var env = base
        var variables = base.variables
        for key in demoIgnoredVariables { variables[key] = nil }
        variables[PresetStore.environmentVariable] = session.workspace.presetStore.url.path
        variables[HistoryStore.environmentVariable] = session.workspace.historyStore.url.path
        env.variables = variables
        let clock = session.clock
        env.now = { clock.now() }
        env.makeService = { tokens, readOnly in session.makeService(tokens: tokens, readOnly: readOnly) }
        env.loadTenants = { _, tokens in try await session.loadTenants(tokens: tokens) }
        env.sleep = session.sleep
        env.history = session.workspace.historyStore
        env.signIn = CLISignIn(settings: session.workspace.authSettingsStore, store: session.tokenStore, transport: session.azure,
                               openURL: { _ in false }, browserSignIn: false)
        env.azureCLITokens = { session.azureCLITokens(tenantId: $0) }
        env.demo = session
        return env
    }
}

extension CLIRunner {
    /// `PIMENTO_DEMO_BADGE=off` hides the "Demo mode" line (terminal screenshots).
    static let demoBadgeVariable = "PIMENTO_DEMO_BADGE"

    /// Runs `invocation` in a fresh demo session, with the network blocked.
    func runDemo(_ invocation: CLIInvocation) async -> Int32 {
        let options = DemoOptions().applying(environment: env.variables)
        let start = options.frozenAt.map { DemoClock.today(atMinutes: $0, now: env.now(), timeZone: env.timeZone) } ?? env.now()
        let clock = DemoClock.manual(at: start)
        let workspace = DemoWorkspace.temporary()
        defer { workspace.remove() }
        do { try workspace.reset(now: start, timeZone: env.timeZone) } catch {
            err(errStyle.red("error:") + " could not set up the demo data: \(error.localizedDescription)")
            return CLIExit.failure.rawValue
        }
        let session = DemoSession(options: options, clock: clock, workspace: workspace, timeZone: env.timeZone) { seconds in
            clock.advance(by: seconds)
            await Task.yield()
        }
        let badge = env.variables[Self.demoBadgeVariable]?.lowercased()
        if env.stderrIsTTY, badge != "off", badge != "0" {
            err(errStyle.dim("Demo mode: simulated Azure and synthetic data, nothing is sent."))
        }
        let runner = CLIRunner(environment: .demo(from: env, session: session))
        return await NetworkGuard.$monitor.withValue(NetworkGuard.monitor ?? NetworkGuard.Monitor()) {
            await runner.run(invocation)
        }
    }
}
