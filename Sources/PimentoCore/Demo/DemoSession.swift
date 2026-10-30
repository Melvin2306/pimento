import Foundation

/// The demo's own folder: presets, history and sign-in settings, the same
/// files as Pimento's real ones but elsewhere (`…/Pimento/Demo` for the
/// app, a temporary folder for each CLI command).
public struct DemoWorkspace: Sendable {
    public let directory: URL

    public init(directory: URL) { self.directory = directory }

    public var presetStore: PresetStore { PresetStore(url: directory.appendingPathComponent("presets.json")) }
    public var historyStore: HistoryStore { HistoryStore(url: directory.appendingPathComponent("history.jsonl")) }
    public var authSettingsStore: AuthSettingsStore { AuthSettingsStore(url: directory.appendingPathComponent("auth.json")) }

    /// The files the demo writes; `reset` removes these and nothing else.
    var files: [URL] {
        let history = historyStore
        let names = ["presets.json", "presets.json.lock", "auth.json", "history.jsonl.lock"]
        return names.map { directory.appendingPathComponent($0) } + [history.url, history.rotatedURL, history.settingsURL]
    }

    /// Whether the demo was set up here before (and its changes can be kept).
    public var isSeeded: Bool { FileManager.default.fileExists(atPath: directory.appendingPathComponent("auth.json").path) }

    /// Starts from the demo data: the demo's files are replaced. Only the
    /// demo's own file names in `directory` are touched.
    public func reset(now: Date, timeZone: TimeZone = .current) throws {
        for file in files where FileManager.default.fileExists(atPath: file.path) {
            try FileManager.default.removeItem(at: file)
        }
        try PrivateFile.createDirectory(directory)
        try presetStore.save(DemoSeed.presets(now: now))
        try historyStore.append(DemoSeed.history(now: now, timeZone: timeZone).sorted { $0.at < $1.at })
        try authSettingsStore.save(DemoSeed.authSettings())
    }

    /// `reset`, unless `keepChanges` and the folder holds an earlier demo.
    public func prepare(keepChanges: Bool, now: Date, timeZone: TimeZone = .current) throws {
        if keepChanges, isSeeded { return }
        try reset(now: now, timeZone: timeZone)
    }

    /// A fresh folder in the temporary directory (the CLI's, one per command).
    public static func temporary() -> DemoWorkspace {
        DemoWorkspace(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("pimento-demo-\(UUID().uuidString.lowercased())", isDirectory: true))
    }

    /// Removes the folder (temporary workspaces).
    public func remove() { try? FileManager.default.removeItem(at: directory) }
}

/// One demo run: the clock, the simulator, the token store and the folder.
/// The app and the CLI build everything Azure-facing from it.
public final class DemoSession: @unchecked Sendable {
    public let options: DemoOptions
    public let clock: DemoClock
    public let azure: DemoAzure
    public let workspace: DemoWorkspace
    /// Pimento sign-in's token store: in memory, with the demo account.
    public let tokenStore: InMemoryTokenStore
    /// Waits of the services (Renew's retries) and of `pimento wait`.
    public let sleep: @Sendable (TimeInterval) async -> Void

    /// `sleep` nil: real waits; the CLI passes one that moves its clock instead.
    public init(options: DemoOptions, clock: DemoClock? = nil, workspace: DemoWorkspace, behavior: DemoAzure.Behavior = .init(),
                timeZone: TimeZone = .current, sleep: (@Sendable (TimeInterval) async -> Void)? = nil) {
        self.options = options
        let clock = clock ?? options.makeClock(timeZone: timeZone)
        self.clock = clock
        azure = DemoAzure(clock: clock, behavior: behavior, timeZone: timeZone)
        self.workspace = workspace
        tokenStore = InMemoryTokenStore()
        try? tokenStore.save(DemoSeed.account(signedInAt: clock.now().addingTimeInterval(-3 * 86400)), refreshToken: DemoDirectory.refreshToken)
        self.sleep = sleep ?? { try? await Task.sleep(nanoseconds: UInt64(max(0, $0) * 1_000_000_000)) }
    }

    /// The Azure CLI's tokens, simulated.
    public func azureCLITokens(tenantId: String?) -> TokenProvider { azure.cliTokens(tenantId: tenantId) }

    /// Pimento sign-in on the demo token store; the token endpoint is the simulator's.
    public func makeBroker() -> TokenBroker { TokenBroker(store: tokenStore, transport: azure, clock: { [clock] in clock.now() }) }

    /// A service on the simulator (read-only: GETs only), on the demo clock.
    public func makeService(tokens: TokenProvider, readOnly: Bool = false, history: HistoryRecorder? = nil) -> PIMService {
        PIMService(transport: readOnly ? ReadOnlyTransport(azure) : azure, tokens: tokens, sleep: sleep, clock: { [clock] in clock.now() }, history: history)
    }

    /// The demo account's tenants (ARM's `/tenants`, simulated).
    public func loadTenants(tokens: TokenProvider? = nil) async throws -> [TenantInfo] {
        TenantDirectory.sorted(try await TenantDirectory.fetchARM(tokens: tokens ?? azureCLITokens(tenantId: nil), transport: ReadOnlyTransport(azure)))
    }
}
