import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import PimentoCore

/// A dictionary standing in for UserDefaults.
final class DictionaryPreferences: PreferenceStore {
    var values: [String: Any] = [:]
    func object(forKey defaultName: String) -> Any? { values[defaultName] }
    func set(_ value: Any?, forKey defaultName: String) { values[defaultName] = value }
    func removeObject(forKey defaultName: String) { values[defaultName] = nil }
}

@Suite("Demo: isolation and setup")
struct DemoIsolationTests {
    @Test func demoModeIsRequestedByFlagOrVariable() {
        #expect(DemoMode.isRequested(arguments: ["--demo"], environment: [:]))
        #expect(DemoMode.isRequested(arguments: ["-NSDocumentRevisionsDebugMode", "YES", "--demo"], environment: [:]))
        #expect(DemoMode.isRequested(arguments: [], environment: ["PIMENTO_DEMO": "1"]))
        #expect(DemoMode.isRequested(arguments: [], environment: ["PIMENTO_DEMO": "true"]))
        #expect(!DemoMode.isRequested(arguments: [], environment: ["PIMENTO_DEMO": "0"]))
        #expect(!DemoMode.isRequested(arguments: [], environment: ["PIMENTO_DEMO": ""]))
        #expect(!DemoMode.isRequested(arguments: ["--tenant", "contoso.example"], environment: [:]))
    }

    @Test func theAppsDemoFolderIsInsideButApartFromTheRealData() {
        let real = PimentoPaths.dataDirectory(environment: [:], home: "/Users/alex", platform: .macOS)
        let demo = DemoMode.dataDirectory(environment: [:], home: "/Users/alex", platform: .macOS)
        #expect(demo.path == "/Users/alex/Library/Application Support/Pimento/Demo")
        #expect(demo.path != real.path)
        let workspace = DemoWorkspace(directory: demo)
        for url in [workspace.presetStore.url, workspace.historyStore.url, workspace.authSettingsStore.url, workspace.historyStore.settingsURL] {
            #expect(url.deletingLastPathComponent().path == demo.path)
        }
        #expect(DemoMode.defaultsSuite != Bundle.main.bundleIdentifier)
        #expect(DemoMode.defaultsSuite.hasSuffix(".demo"))
    }

    @Test func resetSeedsTheDemoFilesAndTouchesNothingElse() throws {
        let folder = TestTemp.url("demo-workspace")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let unrelated = folder.appendingPathComponent("notes.txt")
        try Data("keep me".utf8).write(to: unrelated)
        let workspace = DemoWorkspace(directory: folder)
        let now = AzureDate.parse("2026-10-30T10:30:00Z")!
        try workspace.reset(now: now, timeZone: TimeZone(identifier: "UTC")!)
        let presets = try workspace.presetStore.load().presets
        #expect(presets.map(\.name).sorted() == ["Data team", "On-call", "Release day"])
        let history = workspace.historyStore.records(now: now)
        #expect(history.count == 44)
        #expect(Set(history.map(\.action)).isSuperset(of: [.activate, .schedule, .cancel, .deactivate, .renew, .extend, .approve, .deny]))
        #expect(Set(history.map(\.result)).isSuperset(of: [.succeeded, .pending, .skipped, .failed]))
        #expect(Set(history.compactMap(\.tenantLabel)) == ["Contoso", "Fabrikam", "Northwind Traders", "Adventure Works"])
        #expect(history.allSatisfy { $0.at <= now })
        let auth = workspace.authSettingsStore.load()
        #expect(auth.source == .pimento)
        #expect(auth.clientId == DemoDirectory.clientId)
        #expect(workspace.isSeeded)
        #expect(try String(contentsOf: unrelated, encoding: .utf8) == "keep me")
        #expect(hasMode(workspace.presetStore.url.path, 0o600))
    }

    @Test func keepChangesKeepsAnEarlierDemoAndResetStartsOver() throws {
        let workspace = DemoWorkspace(directory: TestTemp.url("demo-keep"))
        let now = Date()
        try workspace.prepare(keepChanges: true, now: now)
        try workspace.presetStore.update { library in library.delete(library.presets[0].id) }
        try workspace.prepare(keepChanges: true, now: now)
        #expect(try workspace.presetStore.load().presets.count == 2)
        try workspace.prepare(keepChanges: false, now: now)
        #expect(try workspace.presetStore.load().presets.count == 3)
    }

    @Test func optionsRoundTripAndTakeTheEnvironment() {
        let store = DictionaryPreferences()
        #expect(DemoOptions.load(from: store) == DemoOptions())
        let options = DemoOptions(hideBadge: true, keepChanges: true, frozenAt: DemoMode.tidyMinutes, speed: 60)
        options.save(to: store)
        #expect(DemoOptions.load(from: store) == options)
        #expect(Set(store.values.keys).allSatisfy { $0.hasPrefix("demo.") })
        var live = options
        live.frozenAt = nil
        live.save(to: store)
        #expect(DemoOptions.load(from: store).frozenAt == nil)
        let env = DemoOptions().applying(environment: ["PIMENTO_DEMO_CLOCK": "09:05", "PIMENTO_DEMO_SPEED": "10"])
        #expect(env.frozenAt == 9 * 60 + 5)
        #expect(env.speed == 10)
        #expect(options.applying(environment: ["PIMENTO_DEMO_CLOCK": "live"]).frozenAt == nil)
        #expect(DemoMode.parseClock("25:00") == nil)
        #expect(DemoMode.parseClock("10:3") == nil)
    }

    @Test func theDemoTokenStoreIsInMemoryWithTheDemoAccount() throws {
        let session = DemoSession(options: DemoOptions(), clock: .manual(at: Date()), workspace: .temporary())
        #expect(session.tokenStore.label == "memory")
        let accounts = try session.tokenStore.accounts()
        #expect(accounts.map(\.displayName) == ["Alex Wilber <alex.wilber@contoso.example>"])
        #expect(try session.tokenStore.refreshToken(for: accounts[0].id) == DemoDirectory.refreshToken)
    }

    @Test func syntheticDataUsesOnlyFictitiousNamesAndExampleDomains() {
        let domains = DemoDirectory.tenants.compactMap(\.defaultDomain)
        #expect(domains.allSatisfy { $0.hasSuffix(".example") })
        let people = [DemoDirectory.user, DemoDirectory.megan, DemoDirectory.diego, DemoDirectory.isaiah, DemoDirectory.lynne]
        #expect(people.compactMap(\.email).allSatisfy { $0.hasSuffix("@contoso.example") })
    }
}

@Suite("Demo: no network")
struct NetworkGuardTests {
    @Test func urlSessionRequestsAreRefusedAndRecorded() async {
        let monitor = NetworkGuard.Monitor()
        await NetworkGuard.$monitor.withValue(monitor) {
            await #expect(throws: NetworkGuard.Blocked.self) {
                _ = try await URLSessionTransport().send(URLRequest(url: URL(string: "https://management.azure.com/tenants")!))
            }
        }
        #expect(monitor.blocked == ["an HTTPS request to management.azure.com"])
    }

    @Test func theAzureCLIIsNeverStarted() async {
        let monitor = NetworkGuard.Monitor()
        await NetworkGuard.$monitor.withValue(monitor) {
            await #expect(throws: NetworkGuard.Blocked.self) {
                _ = try await AzureCLITokenProvider(tenantId: nil, azPath: "/nonexistent/az").accessToken()
            }
        }
        #expect(monitor.blocked == ["the Azure CLI (az account get-access-token)"])
    }

    #if !os(Windows)
    @Test func noSignInListenerIsOpened() {
        let monitor = NetworkGuard.Monitor()
        NetworkGuard.$monitor.withValue(monitor) {
            #expect(throws: NetworkGuard.Blocked.self) { _ = try LoopbackListener() }
        }
        #expect(monitor.blocked.count == 1)
    }
    #endif

    @Test func withoutAMonitorNothingChanges() throws {
        try NetworkGuard.check("anything")
    }
}
