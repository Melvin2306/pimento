import AppKit
import Foundation
import Observation
import PimentoCore
import SwiftUI
import UniformTypeIdentifiers

enum RowProgress: Equatable {
    case queued
    /// In flight: `Activating…`, `Ending…`, `Activating again…`.
    case running(String)
    case done(ActivationOutcome)
}

/// What the app shows for a row until Azure's listing agrees: ARM lists a new
/// activation, or drops an ended one, only after a few seconds.
enum PendingState: Equatable {
    /// Activated (or renewed) from this app; `until`: the expiry Azure returned.
    case active(until: Date?, since: Date)
    /// Ended from this app at `since`.
    case inactive(since: Date)
}

@MainActor
@Observable
final class AppModel {
    enum LoadState: Equatable {
        case idle
        case loading
        case loaded
        case failed(message: String, needsLogin: Bool)
    }

    var roles: [EligibleRole] = []
    var checked: Set<EligibleRole.ID> = []
    var search = ""
    var justification = ""
    /// Hours, or the maximum each role's policy allows. Each role gets at
    /// most its policy maximum either way (`effectiveDuration(for:)`).
    var duration: RequestedDuration = .hours(ActivationRequestBuilder.defaultHours)
    var sortOrder: [KeyPathComparator<EligibleRole>] = [KeyPathComparator(\.scopeName)]
    var loadState: LoadState = .idle
    var identity: Identity?
    var lastRefreshed: Date?
    var progress: [EligibleRole.ID: RowProgress] = [:]
    /// Rows activated, renewed or ended from this app that Azure does not
    /// list that way yet, so a refresh right after does not flip them back.
    private var pending: [EligibleRole.ID: PendingState] = [:]
    /// Active rows checked for Deactivate / Renew (kept apart from `checked`,
    /// the eligible rows to activate).
    var checkedActive: Set<EligibleRole.ID> = []
    /// An activation, deactivation or renewal is running.
    var isActivating = false
    var showDeactivateConfirmation = false
    var showRenewConfirmation = false
    /// The rows the open Deactivate / Renew confirmation is about.
    var lifecycleTargets: [EligibleRole] = []
    /// Bumped to move keyboard focus to the justification field.
    var justificationFocusRequest = 0
    var dryRunPlans: [PlannedRequest] = []
    var showDryRunSheet = false
    var showOwnerConfirmation = false
    var banner: Banner?

    // Scheduling: nil starts the activations now; a date schedules them.
    var scheduleStart: Date?
    var showStartPicker = false
    var startPickerDraft = AppClock.now()
    /// Your pending requests in Azure (scheduled, or awaiting approval).
    var scheduledRequests: [ScheduledRequest] = []
    /// Tickets of your requests by request name: what Renew sends again.
    private(set) var activationTickets: [String: TicketInfo] = [:]

    // Your requests waiting for approval, followed until they are decided.
    private var approvalTracker = ApprovalTracker()
    private var approvalPollTask: Task<Void, Never>?

    // Requests you can approve or deny (Approvals sheet).
    var approvalInbox = ApprovalInbox()
    var approvalsLoadState: LoadState = .idle
    var showApprovals = false
    /// Checked requests, by request name.
    var approvalSelection: Set<String> = []
    var approvalJustification = ""
    /// Requests being decided, and how deciding went.
    var deciding: Set<String> = []
    var decisionResults: [String: DecisionOutcome] = [:]
    var approvalMessage: Banner?
    var showDecisionConfirmation = false
    var pendingDecision: ApprovalDecision = .approve
    /// Names of the last listing, to notice new requests (nil: not listed yet).
    private var seenApprovals: Set<String>?
    var scheduledLoadState: LoadState = .idle
    var showScheduled = false
    /// Requests being cancelled, and how cancelling went.
    var cancelling: Set<String> = []
    var cancelResults: [String: CancelOutcome] = [:]
    /// The Cancel confirmation (a row's Cancel, or Cancel All) and the
    /// requests it showed, picked when the button was pressed.
    var showCancelConfirmation = false
    private(set) var cancelTargets: [ScheduledRequest] = []

    // Ticket information: shown when a checked role's policy needs it, or on request.
    var ticketNumber = ""
    var ticketSystem = ""
    var showTicketFields = false
    /// Most recent first; kept only while `prefs.rememberJustifications` is on.
    private(set) var recentTickets: [TicketInfo] = []

    // PIM policies, per scope + role, for this session (cleared on a tenant
    // switch; failed lookups are retried on refresh).
    var policies: [RoleMatcher.Key: PolicyLookup] = [:]
    private var policyTask: Task<Void, Never>?

    // Presets, shared with the CLI through the presets file.
    let presetStore = AppRuntime.demo?.workspace.presetStore ?? PresetStore()
    var presetLibrary = PresetLibrary() {
        didSet { if presetLibrary != oldValue { keepAlivePresetsChanged() } }
    }
    /// The presets file could not be read (or written).
    var presetFileError: String?
    var showSavePresetSheet = false
    var showManagePresets = false
    var savePresetName = ""
    var savePresetJustification = ""
    var savePresetIncludesJustification = true
    var savePresetIncludesDuration = false
    var savePresetError: String?
    /// The preset selected in Manage Presets, and its unsaved edits.
    var managedPresetId: UUID?
    var presetDraft: Preset?
    var presetDraftError: String?
    /// "Load roles on launch" is off and nothing has been loaded yet.
    private(set) var awaitingManualRefresh = false

    // History: every write this app (and the CLI) sent, from the shared file.
    let historyStore = AppRuntime.demo?.workspace.historyStore ?? HistoryStore()
    let historyRecorder: HistoryRecorder
    /// Whether history is kept, and for how long (shared with the CLI).
    var historySettings: HistorySettings {
        didSet { historySettingsChanged(from: oldValue) }
    }
    var historyRecords: [HistoryRecord] = []
    var showHistory = false
    var historySearch = ""
    var historyPeriod: HistoryPeriod = .all
    var historyFrom = AppClock.now().addingTimeInterval(-7 * 86400)
    var historyTo = AppClock.now()
    var historyAction: HistoryAction?
    var historyResult: HistoryResult?
    /// A tenant GUID (lower-case), or nil for all.
    var historyTenant: String?
    var historySortOrder: [KeyPathComparator<HistoryRecord>] = [KeyPathComparator(\.at, order: .reverse)]
    var historySelection: Set<HistoryRecord.ID> = []
    var historyImportState: LoadState = .idle
    var historyMessage: Banner?
    var showClearHistoryConfirmation = false

    // Settings (⌘,), saved to UserDefaults on every change.
    var prefs: Preferences {
        didSet { preferencesChanged(from: oldValue) }
    }
    /// The appearance that applies now (`prefs.resolvedAppearance`), for
    /// `AppAppearance` and the themed views. Updated with `prefs` and, in
    /// the time-of-day mode, at each boundary of the schedule.
    private(set) var appearance: ResolvedAppearance = .system
    /// Fires at the schedule's next boundary (time-of-day mode only).
    @ObservationIgnored private var appearanceTimer: Timer?
    @ObservationIgnored private var clockObservers: [(NotificationCenter, NSObjectProtocol)] = []
    /// Most recent first; kept only while `prefs.rememberJustifications` is on.
    private(set) var recentJustifications: [String] = []
    var columnCustomization = TableColumnCustomization<EligibleRole>() {
        didSet { saveColumnCustomization() }
    }
    var notificationPermission: NotificationPermission = .unknown
    var notificationTestResult: NotificationTestResult?
    var showResetConfirmation = false
    private var autoRefreshTask: Task<Void, Never>?

    // Tenant
    /// `--tenant` from the launch arguments, if any.
    let commandLineTenant: String?
    private(set) var tenant: TenantSelection
    /// An invalid `--tenant` / `PIMENTO_TENANT` value; shown instead of the table.
    private(set) var tenantError: String?
    var knownTenants: [TenantInfo] = [] {
        didSet { historyRecorder.setTenantLabels(Dictionary(knownTenants.compactMap { t in t.name.map { (t.id, $0) } }, uniquingKeysWith: { a, _ in a })) }
    }
    private(set) var isLoadingTenants = false
    /// Tenants the user hid from the picker (lower-case IDs).
    private(set) var hiddenTenantIds: Set<String> = []
    var showTenantPicker = false
    var tenantQuery = ""
    var showHiddenTenants = false
    var hoveredTenantId: String?
    var showTenantSheet = false
    var tenantDraft = ""

    // Account (Settings › Account): where tokens come from, and Pimento's own sign-in.
    /// `auth.json`, shared with the CLI.
    let authSettingsStore: AuthSettingsStore
    /// Pimento sign-in: refresh tokens in the store (Keychain), access tokens in memory.
    let broker: TokenBroker
    /// Saved on every change.
    var authSettings: AuthSettings {
        didSet {
            guard authSettings != oldValue else { return }
            // The CLI and the next launch read it: say when it did not stick.
            do { try authSettingsStore.save(authSettings) } catch {
                banner = Banner(kind: .error, text: "Could not save the sign-in settings (\(authSettingsStore.url.path)): \(error.localizedDescription)")
            }
        }
    }
    /// The auth source in use (`$PIMENTO_AUTH` overrides the setting).
    var authSelection: AuthSelection
    /// Accounts of Pimento sign-in (no secrets read).
    var signedInAccounts: [SignedInAccount] = []
    /// The client ID field in Settings › Account.
    var clientIdDraft = ""
    var signInState: SignInState = .idle
    /// The device-code sheet, in the Settings window or the main window.
    var showDeviceCodeSheet = false
    var deviceCodeInMainWindow = false
    @ObservationIgnored var signInTask: Task<Void, Never>?
    /// The Settings window's pane (so the main window can open Account).
    var settingsTab: SettingsPane = .general

    enum SignInState: Equatable {
        case idle
        /// Waiting for the browser (authorization code with PKCE).
        case browser
        /// Asking Microsoft for a device code.
        case requestingCode
        /// Waiting for the user to enter the code.
        case deviceCode(DeviceCodeChallenge)
        case failed(String)
    }

    // Menu bar extra
    /// The inline confirmation or question the menu bar popover shows (its
    /// panel cannot host the main window's alerts).
    var menuBarPrompt: MenuBarPrompt?
    /// Launch at login (`SMAppService.mainApp`): the system's state, read
    /// when Settings opens; `loginItemError`: why the last change failed.
    var loginItemState: LoginItemState = .disabled
    var loginItemError: String?

    // Keep alive (`AppModel+KeepAlive.swift`).
    /// Roles kept alive one by one, by tenant (lower-case, or "default"), as role keys.
    var keepAliveRolesByTenant: [String: Set<String>] = [:]
    /// Access-granting roles whose keep-alive you confirmed, by tenant, as role keys.
    var keepAliveConfirmedByTenant: [String: Set<String>] = [:]
    /// The open confirmation for keeping access-granting roles alive.
    var keepAliveConsent: KeepAliveConsentRequest?
    /// How each kept role is kept alive (per role or by a preset), by role key.
    var keepAliveRules: [String: KeepAliveRule] = [:]
    /// Where each kept role stands after the last pass, by role key.
    var keepAliveItems: [String: KeepAlivePlanner.Item] = [:]
    /// The last pass failed to read (shown in the menu bar and the toolbar menu).
    var keepAliveError: String?
    @ObservationIgnored let keepAliveSession = KeepAliveSession()
    @ObservationIgnored var keepAliveTimer: Timer?
    @ObservationIgnored var keepAliveRunning = false
    /// What the last pass saw of the kept roles (key: end), to notice changes after a refresh.
    @ObservationIgnored var keepAliveSeen: [String: Date] = [:]

    struct Banner: Equatable {
        enum Kind { case info, success, error }
        let kind: Kind
        let text: String
    }

    enum Keys {
        /// The tenant last picked in the app.
        static let tenant = "tenantId"
        static let hiddenTenants = "hiddenTenantIds"
        static let recentJustifications = "recentJustifications"
        static let recentTickets = "recentTickets"
        static let lastTicketSystem = "lastTicketSystem"
        static let tableColumns = "tableColumns"
        /// Roles kept alive one by one: `{tenant: [role key]}`.
        static let keepAliveRoles = "keepAlive.roles"
        /// Access-granting roles whose keep-alive was confirmed: `{tenant: [role key]}`.
        static let keepAliveConfirmed = "keepAlive.confirmed"
    }

    /// Table columns the Settings window can show or hide.
    enum Column: String, CaseIterable {
        case type, membership, condition, duration
        var title: String {
            switch self {
            case .type: "Type"
            case .membership: "Membership"
            case .condition: "Condition"
            case .duration: "Duration"
            }
        }
    }

    static let shared = AppModel(commandLineTenant: LaunchArguments.tenant(in: Array(CommandLine.arguments.dropFirst())))

    /// Tokens for `tenantId` from the current auth source.
    func tokens(tenantId: String?) -> TokenProvider { authContext.tokens(tenantId: tenantId) }

    var authContext: AuthContext {
        AuthContext(selection: authSelection, broker: broker, accountId: authSettings.accountId, azureCLI: Self.azureCLITokens)
    }

    /// The Azure CLI's tokens, or the demo's stand-in for them.
    static var azureCLITokens: @Sendable (String?) -> TokenProvider {
        if let demo = AppRuntime.demo { return { demo.azureCLITokens(tenantId: $0) } }
        return { AzureCLITokenProvider(tenantId: $0) }
    }

    /// The environment the app reads `PIMENTO_TENANT` / `PIMENTO_AUTH` /
    /// `PIMENTO_CLIENT_ID` from: none of the user's in demo mode.
    static var settingsEnvironment: [String: String] { AppRuntime.isDemo ? [:] : ProcessInfo.processInfo.environment }

    /// A service for `tokens`: on the demo simulator in demo mode.
    static func makeService(tokens: TokenProvider, history: HistoryRecorder) -> PIMService {
        if let demo = AppRuntime.demo { return demo.makeService(tokens: tokens, history: history) }
        return PIMService(tokens: tokens, history: history)
    }

    var authSource: AuthSource { authSelection.source }

    private(set) var service: PIMService
    private(set) var tenantGeneration = 0

    /// `tokenStore` / `authSettingsStore` / `signInTransport`: the Keychain,
    /// `auth.json` and the network unless given.
    init(commandLineTenant: String?, tokenStore: TokenStore? = nil, authSettingsStore: AuthSettingsStore? = nil,
         signInTransport: HTTPTransport? = nil) {
        // 0.1.0 persisted a dry-run mode; activation is now always real (the
        // preview is a separate action), so the stale setting is dropped.
        let defaults = AppRuntime.defaults
        defaults.removeObject(forKey: "dryRun")
        self.commandLineTenant = commandLineTenant
        let prefs = Preferences.load(from: defaults)
        self.prefs = prefs
        appearance = prefs.resolvedAppearance()
        duration = .hours(prefs.defaultHours)
        awaitingManualRefresh = !prefs.refreshOnLaunch
        hiddenTenantIds = Set(defaults.stringArray(forKey: Keys.hiddenTenants) ?? [])
        let recent = prefs.rememberJustifications ? defaults.stringArray(forKey: Keys.recentJustifications) ?? [] : []
        recentJustifications = recent
        if prefs.prefillLastJustification { justification = recent.first ?? "" }
        if prefs.rememberJustifications, let data = defaults.data(forKey: Keys.recentTickets),
           let tickets = try? JSONDecoder().decode([TicketInfo].self, from: data) {
            recentTickets = tickets
        }
        ticketSystem = defaults.string(forKey: Keys.lastTicketSystem) ?? ""
        if let data = defaults.data(forKey: Keys.tableColumns),
           let saved = try? JSONDecoder().decode(TableColumnCustomization<EligibleRole>.self, from: data) {
            columnCustomization = saved
        }
        let saved = prefs.startupTenant(lastUsed: defaults.string(forKey: Keys.tenant))
        let selection: TenantSelection
        do {
            selection = try TenantResolver.resolve(commandLine: commandLineTenant, environment: Self.settingsEnvironment, saved: saved)
        } catch {
            selection = TenantSelection(tenantId: nil, source: .azDefault)
            tenantError = error.localizedDescription
        }
        tenant = selection
        let authStore = authSettingsStore ?? AppRuntime.demo?.workspace.authSettingsStore ?? AuthSettingsStore()
        self.authSettingsStore = authStore
        let auth = authStore.load()
        authSettings = auth
        clientIdDraft = auth.clientId ?? ""
        let selectedAuth = (try? AuthSourceResolver.resolve(commandLine: nil, environment: Self.settingsEnvironment, saved: auth.source))
            ?? AuthSelection(source: auth.source ?? .az, origin: auth.source == nil ? .default : .saved)
        authSelection = selectedAuth
        // Demo mode: the demo account in memory, sign-in on the simulator (never the Keychain).
        let broker = if tokenStore == nil, let demo = AppRuntime.demo {
            demo.makeBroker()
        } else {
            TokenBroker(store: tokenStore ?? TokenStores.standard(), transport: signInTransport ?? URLSessionTransport())
        }
        self.broker = broker
        let recorder = HistoryRecorder(store: historyStore, source: .app, clock: { AppClock.now() })
        historyRecorder = recorder
        historySettings = historyStore.loadSettings()
        service = Self.makeService(
            tokens: AuthContext(selection: selectedAuth, broker: broker, accountId: auth.accountId, azureCLI: Self.azureCLITokens)
                .tokens(tenantId: selection.tenantId),
            history: recorder)
        keepAliveRolesByTenant = Self.loadKeepAliveRoles(from: defaults, key: Keys.keepAliveRoles)
        keepAliveConfirmedByTenant = Self.loadKeepAliveRoles(from: defaults, key: Keys.keepAliveConfirmed)
        restartAutoRefresh()
        observeClockChanges()
        scheduleAppearanceChange(after: AppClock.now())
        reloadPresets()
        Task { await reloadAccounts() }
        // Old records go once per launch (the CLI and later writes prune too).
        let store = historyStore, retention = historySettings.retention
        Task.detached(priority: .utility) { _ = try? store.prune(retention: retention) }
    }

    // MARK: Derived state

    var visibleRoles: [EligibleRole] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        let filtered = q.isEmpty ? roles : roles.filter { role in
            [role.roleName, role.scopeName, role.scopeTypeLabel, role.membership.label, role.scope]
                .contains { $0.lowercased().contains(q) }
        }
        return filtered.sorted(using: sortOrder)
    }

    var checkedRoles: [EligibleRole] { roles.filter { checked.contains($0.id) && !$0.isActive } }
    var checkedActiveRoles: [EligibleRole] { roles.filter { checkedActive.contains($0.id) && $0.isActive } }
    var checkedOwnerRoles: [EligibleRole] { checkedRoles.filter(\.isOwner) }
    var activeCount: Int { roles.filter(\.isActive).count }
    var trimmedJustification: String { justification.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// The tenant actually in use: the chosen one, or the one az's token is for.
    var effectiveTenantId: String? { tenant.tenantId ?? identity?.tenantId }

    var tenantLabel: String {
        guard let id = effectiveTenantId else { return "Default tenant" }
        if let known = knownTenant(id) { return known.label }
        // Not listed (yet): a GUID reads better shortened; a domain as typed.
        return UUID(uuidString: id) != nil ? "Tenant \(id.prefix(8))" : id
    }

    func knownTenant(_ id: String) -> TenantInfo? {
        knownTenants.first { $0.id.caseInsensitiveCompare(id) == .orderedSame }
    }

    /// The picker's rows for the current search and hidden setting.
    var pickerTenants: [TenantInfo] {
        TenantDirectory.visible(
            knownTenants, query: tenantQuery, hidden: hiddenTenantIds,
            showHidden: showHiddenTenants, current: effectiveTenantId)
    }

    /// Hidden tenants az still knows about (stale IDs don't count).
    var hiddenTenantCount: Int { knownTenants.filter { hiddenTenantIds.contains($0.id) }.count }

    func isHidden(_ tenant: TenantInfo) -> Bool { hiddenTenantIds.contains(tenant.id) }

    func isEffectiveTenant(_ tenant: TenantInfo) -> Bool {
        effectiveTenantId?.caseInsensitiveCompare(tenant.id) == .orderedSame
    }

    var loginCommand: String { AzureCLIError.loginCommand(tenant: effectiveTenantId) }

    /// What the menu bar says when signed out.
    var signedOutHint: String {
        authSource == .az ? "Signed out: run \(loginCommand)" : "Signed out: sign in under Settings › Account"
    }

    /// True when signing in (az, or Pimento's sign-in) would fix `error`.
    static func needsLogin(_ error: Error) -> Bool {
        switch error {
        case let e as AzureCLIError: e.needsLogin || e == .notFound
        case let e as SignInError: e.needsLogin
        case let e as PIMServiceError: CLIExit.code(for: e) == .auth
        default: false
        }
    }

    var canActivate: Bool {
        !isActivating && !checkedRoles.isEmpty && !trimmedJustification.isEmpty && identity != nil
            && missingTicketRoles.isEmpty
    }

    // MARK: Tickets

    /// The ticket to send: nil without a number (a system alone is not sent).
    var currentTicket: TicketInfo? {
        let number = ticketNumber.trimmingCharacters(in: .whitespacesAndNewlines)
        return number.isEmpty ? nil : TicketInfo(number: number, system: ticketSystem)
    }

    func requiresTicket(_ role: EligibleRole) -> Bool { policies[role.policyKey]?.policy?.requiresTicket == true }

    /// Checked roles whose policy requires a ticket.
    var checkedRolesNeedingTicket: [EligibleRole] {
        TicketRequirement.rolesNeedingTicket(checkedRoles) { self.policies[$0.policyKey] }
    }

    /// Checked roles that need a ticket the fields do not complete yet.
    var missingTicketRoles: [EligibleRole] {
        TicketRequirement.missing(checkedRoles, ticket: currentTicket) { self.policies[$0.policyKey] }
    }

    var ticketFieldsVisible: Bool {
        showTicketFields || !checkedRolesNeedingTicket.isEmpty || !ticketNumber.trimmingCharacters(in: .whitespaces).isEmpty
    }

    func useRecentTicket(_ ticket: TicketInfo) {
        ticketNumber = ticket.ticketNumber ?? ""
        if let system = ticket.ticketSystem { ticketSystem = system }
        showTicketFields = true
    }

    private func rememberTicket(_ ticket: TicketInfo?) {
        guard let ticket else { return }
        if let system = ticket.ticketSystem { AppRuntime.defaults.set(system, forKey: Keys.lastTicketSystem) }
        guard prefs.rememberJustifications else { return }
        recentTickets = TicketInfo.recording(ticket, in: recentTickets, limit: Preferences.recentJustificationLimit)
        if let data = try? JSONEncoder().encode(recentTickets) { AppRuntime.defaults.set(data, forKey: Keys.recentTickets) }
    }

    func clearRecentTickets() {
        recentTickets = []
        AppRuntime.defaults.removeObject(forKey: Keys.recentTickets)
    }

    // MARK: Scheduling

    /// `Fri 08:00`, for the start menu and the results.
    func startLabel(_ date: Date) -> String { ScheduleTime.label(date, now: AppClock.now()) }

    func setStart(_ date: Date?) {
        scheduleStart = date
        if let date {
            do { try ScheduleTime.validate(date, now: AppClock.now()) } catch {
                banner = Banner(kind: .error, text: error.localizedDescription)
            }
        }
    }

    func openStartPicker() {
        startPickerDraft = scheduleStart ?? ScheduleTime.Preset.tomorrowMorning.date(now: AppClock.now())
        showStartPicker = true
    }

    /// The latest start PIM accepts, for the date picker.
    var latestStart: Date { AppClock.now().addingTimeInterval(TimeInterval(ScheduleTime.maxDaysAhead) * 86400) }

    /// Pending requests of the eligibility in `role` (scope + role).
    func scheduledRequests(for role: EligibleRole) -> [ScheduledRequest] {
        scheduledRequests.filter { $0.policyKey == role.policyKey }
    }

    var scheduledCount: Int { scheduledRequests.count }

    /// Reads your pending requests from Azure (read-only) and rebuilds the
    /// "scheduled activation started" notifications from them.
    func loadScheduled() async {
        guard tenantError == nil, scheduledLoadState != .loading else { return }
        scheduledLoadState = .loading
        let generation = tenantGeneration
        let service = service.readOnly
        do {
            let history = try await service.loadRequestHistory()
            guard generation == tenantGeneration else { return }
            let requests = history.pending
            scheduledRequests = requests
            activationTickets = history.activationTickets
            scheduledLoadState = .loaded
            // Keep-alive's continuations get their own notification ("Renewed …").
            Notifier.syncScheduledStarts(requests.filter { !isKeepAliveContinuation($0) },
                                         tenantId: history.identity.tenantId ?? effectiveTenantId, prefs: prefs)
            let decided = approvalTracker.update(items: history.items, principalId: history.identity.objectId,
                                                 tenantId: history.identity.tenantId, now: AppClock.now())
            updateApprovalPolling()
            if !decided.isEmpty { Task { await self.announce(decided) } }
        } catch {
            guard generation == tenantGeneration else { return }
            scheduledLoadState = .failed(message: error.localizedDescription, needsLogin: Self.needsLogin(error))
        }
    }

    /// Requests of yours waiting for approval that Pimento follows.
    var awaitingApprovalCount: Int { approvalTracker.count }

    /// Polls your requests every minute while some wait for approval (not
    /// while an activation runs, and not when auto-refresh already reads them
    /// every minute); stops once none is left.
    private func updateApprovalPolling() {
        guard ApprovalPolling.shouldPoll(pendingCount: approvalTracker.count, autoRefreshMinutes: prefs.autoRefreshMinutes) else {
            approvalPollTask?.cancel()
            approvalPollTask = nil
            return
        }
        guard approvalPollTask == nil else { return }
        approvalPollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(ApprovalPolling.interval))
                guard !Task.isCancelled, let self else { return }
                if !self.isActivating, self.tenantError == nil { await self.loadScheduled() }
                guard ApprovalPolling.shouldPoll(pendingCount: self.approvalTracker.count, autoRefreshMinutes: self.prefs.autoRefreshMinutes) else {
                    self.approvalPollTask = nil
                    return
                }
            }
        }
    }

    /// Tells the user how requests that waited for approval were decided:
    /// a notification each (Settings), a banner, and fresh rows for approved ones.
    private func announce(_ transitions: [ApprovalTransition]) async {
        let generation = tenantGeneration
        let service = service.readOnly
        if transitions.contains(where: \.resolution.isApproved) { await refreshAfterRunningLoad() }
        guard generation == tenantGeneration else { return }
        var approvedRoles: [EligibleRole] = []
        var outcomes: [String: ActivationOutcome] = [:]
        var lines: [String] = []
        for t in transitions {
            let review = t.resolution.isApproved ? nil : await service.review(approvalId: t.request.approvalId)
            guard generation == tenantGeneration else { return }
            let role = roles.first { $0.policyKey == t.request.policyKey && $0.isActive }
            let notice = ApprovalNotice.decision(t, review: review, until: role?.activeUntil, now: AppClock.now())
            Notifier.approvalDecided(notice, prefs: prefs)
            lines.append(notice.title)
            if t.resolution.isApproved, let role {
                approvedRoles.append(role)
                outcomes[role.id] = .activated(status: t.status, until: role.activeUntil)
            }
        }
        let rejected = transitions.contains { !$0.resolution.isApproved }
        banner = Banner(kind: rejected ? .error : .success, text: lines.joined(separator: " · ") + ".")
        // Approved roles get their expiry reminders like any activation.
        Notifier.scheduleReminders(roles: approvedRoles, outcomes: outcomes, context: reminderContext(justification: ""), prefs: prefs)
    }

    func openScheduled() {
        cancelResults = [:]
        showScheduled = true
        Task { await loadScheduled() }
    }

    /// Asks before cancelling `requests` (a row, or every listed one): the
    /// confirmation shows them, and only they are sent when it is accepted.
    func requestCancel(_ requests: [ScheduledRequest]) {
        let targets = requests.filter { !cancelling.contains($0.name) }
        guard !targets.isEmpty else { return }
        cancelTargets = targets
        showCancelConfirmation = true
    }

    /// The confirmation was accepted: cancels what it showed that is still
    /// listed (a refresh may have dropped some; a new session drops all).
    func confirmCancel() {
        let listed = Set(scheduledRequests.map(\.name))
        let targets = cancelTargets.filter { listed.contains($0.name) }
        cancelTargets = []
        guard !targets.isEmpty else { return }
        Task { await cancelScheduled(targets) }
    }

    /// Cancels `requests` (POST …/cancel), then reads the list again.
    func cancelScheduled(_ requests: [ScheduledRequest]) async {
        let targets = requests.filter { !cancelling.contains($0.name) }
        guard !targets.isEmpty else { return }
        for r in targets {
            cancelling.insert(r.name)
            cancelResults[r.name] = nil
        }
        let generation = tenantGeneration
        do {
            try await service.cancel(targets) { r, outcome in
                await MainActor.run {
                    guard generation == self.tenantGeneration else { return }
                    self.cancelling.remove(r.name)
                    self.cancelResults[r.name] = outcome
                }
            }
        } catch {
            guard generation == tenantGeneration else { return }
            for r in targets { cancelResults[r.name] = .failed(code: "Auth", message: error.localizedDescription) }
        }
        guard generation == tenantGeneration else { return }
        for r in targets { cancelling.remove(r.name) }
        let done = targets.filter { cancelResults[$0.name] == .canceled }
        let failed = targets.count - done.count
        banner = Banner(kind: failed > 0 ? .error : .success,
                        text: "\(ScheduledRequest.countLabel(done)) cancelled" + (failed > 0 ? ", \(failed) failed." : "."))
        await loadScheduled()
    }

    // MARK: Approvals (approver side)

    var approvalCount: Int { approvalInbox.requests.count }

    var selectedApprovals: [ApprovalRequest] { approvalInbox.requests.filter { approvalSelection.contains($0.name) } }

    var trimmedApprovalJustification: String { approvalJustification.trimmingCharacters(in: .whitespacesAndNewlines) }

    var canDecide: Bool { !selectedApprovals.isEmpty && !trimmedApprovalJustification.isEmpty && deciding.isEmpty }

    /// Reads the requests you can decide (read-only). Azure refusing the
    /// listing leaves a calm, empty inbox. New requests since the last
    /// listing get a notification (Settings).
    func loadApprovals() async {
        guard tenantError == nil, approvalsLoadState != .loading else { return }
        approvalsLoadState = .loading
        let generation = tenantGeneration
        let service = service.readOnly
        do {
            let (_, inbox) = try await service.loadApprovalInbox()
            guard generation == tenantGeneration else { return }
            let arrivals = ApprovalParser.arrivals(previous: seenApprovals, current: inbox.requests)
            let names = ApprovalParser.names(inbox.requests)
            seenApprovals = names
            approvalInbox = inbox
            approvalSelection = approvalSelection.filter { names.contains($0.lowercased()) }
            approvalsLoadState = .loaded
            if let notice = ApprovalNotice.arrivals(arrivals) { Notifier.approvalsArrived(notice, prefs: prefs) }
        } catch {
            guard generation == tenantGeneration else { return }
            approvalsLoadState = .failed(message: error.localizedDescription, needsLogin: Self.needsLogin(error))
        }
    }

    func openApprovals() {
        decisionResults = [:]
        approvalMessage = nil
        showApprovals = true
        NSApp.activate(ignoringOtherApps: true)
        Task { await loadApprovals() }
    }

    func setApproval(_ request: ApprovalRequest, selected: Bool) {
        if selected { approvalSelection.insert(request.name) } else { approvalSelection.remove(request.name) }
    }

    func selectAllApprovals(_ on: Bool) {
        approvalSelection = on ? Set(approvalInbox.requests.map(\.name)) : []
    }

    /// Deny always asks; Approve asks when roles that grant access (Owner,
    /// User Access Administrator, RBAC Administrator) are among the
    /// selection (with the Owner confirmation on).
    func requestDecision(_ decision: ApprovalDecision) {
        guard canDecide else { return }
        pendingDecision = decision
        if decision == .deny || (prefs.confirmOwnerRoles && selectedApprovals.contains(where: \.grantsAccess)) {
            showDecisionConfirmation = true
        } else {
            Task { await decide(decision) }
        }
    }

    /// Approves or denies the selected requests (PATCH on each approval's
    /// open stage), then reads the inbox again.
    func decide(_ decision: ApprovalDecision) async {
        let targets = selectedApprovals.filter { !deciding.contains($0.name) }
        guard !targets.isEmpty else { return }
        approvalMessage = nil
        for r in targets {
            deciding.insert(r.name)
            decisionResults[r.name] = nil
        }
        let service = service
        let generation = tenantGeneration
        do {
            let plans = try PlannedDecision.plan(await service.resolvingStages(targets), decision: decision,
                                                 justification: trimmedApprovalJustification)
            // Switched account or tenant while the stages loaded: send nothing.
            guard generation == tenantGeneration else { return }
            for p in plans where p.url == nil { decisionResults[p.request.name] = .notPending(DecisionOutcome.noOpenStageMessage) }
            try await service.decide(plans.filter { $0.url != nil }) { p, outcome in
                await MainActor.run {
                    guard generation == self.tenantGeneration else { return }
                    self.deciding.remove(p.request.name)
                    self.decisionResults[p.request.name] = outcome
                }
            }
        } catch {
            guard generation == tenantGeneration else { return }
            for r in targets where decisionResults[r.name] == nil {
                decisionResults[r.name] = .failed(code: "Error", message: error.localizedDescription)
            }
        }
        guard generation == tenantGeneration else { return }
        for r in targets { deciding.remove(r.name) }
        let done = targets.filter { decisionResults[$0.name] == .decided(decision) }
        let failed = targets.count - done.count
        approvalSelection.subtract(done.map(\.name))
        approvalMessage = Banner(kind: failed > 0 ? .error : .success,
                                 text: "\(done.count) \(decision.pastTense)" + (failed > 0 ? ", \(failed) not: see the rows." : "."))
        if failed == 0 { approvalJustification = "" }
        await loadApprovals()
    }

    // MARK: Durations and policies

    func policyLookup(for role: EligibleRole) -> PolicyLookup? { policies[role.policyKey] }

    /// What `role` is requested for: the chosen duration, capped at its
    /// policy maximum when that is known.
    func effectiveDuration(for role: EligibleRole) -> EffectiveDuration {
        EffectiveDuration.resolve(duration, policyMaxMinutes: policies[role.policyKey]?.maxMinutes,
                                  fallbackHours: prefs.defaultHours)
    }

    /// Checked roles whose duration is capped at their policy maximum.
    var cappedCheckedRoles: [EligibleRole] { checkedRoles.filter { effectiveDuration(for: $0).isClamped } }

    /// `8 h`, or `up to 8 h` when the checked roles get different durations.
    var durationSummary: String {
        let minutes = Set(checkedRoles.map { effectiveDuration(for: $0).minutes })
        guard let longest = minutes.max() else { return duration.label }
        let text = DurationText.short(minutes: longest)
        return minutes.count == 1 ? text : "up to \(text)"
    }

    /// Reads the PIM policy of every role not looked up yet (and retries
    /// failed lookups), a few at a time, in the background.
    func loadPolicies(for roles: [EligibleRole]? = nil, retryFailures: Bool = false) {
        let candidates = roles ?? self.roles
        let missing = candidates.filter { role in
            switch policies[role.policyKey] {
            case nil: true
            case .failed?: retryFailures
            default: false
            }
        }
        guard !missing.isEmpty else { return }
        let generation = tenantGeneration
        let service = service.readOnly
        let previous = policyTask
        policyTask = Task { [weak self] in
            await previous?.value
            _ = try? await service.loadPolicies(for: missing) { key, lookup in
                await MainActor.run {
                    guard let self, generation == self.tenantGeneration else { return }
                    self.policies[key] = lookup
                }
            }
        }
    }

    /// Waits for the policies of `roles`; used before building requests.
    private func ensurePolicies(for roles: [EligibleRole]) async {
        loadPolicies(for: roles)
        await policyTask?.value
    }

    var activateTitle: String {
        let n = checkedRoles.count
        let noun = n == 1 ? "role" : "roles"
        let verb = scheduleStart == nil ? "Activate" : "Schedule"
        return n == 0 ? verb : "\(verb) \(n) \(noun)"
    }

    // MARK: Actions

    func refresh() async {
        guard loadState != .loading, tenantError == nil else { return }
        awaitingManualRefresh = false
        loadState = .loading
        let generation = tenantGeneration
        let service = service.readOnly
        do {
            let snapshot = try await service.loadRoles()
            // A tenant switch while loading makes this result stale.
            guard generation == tenantGeneration else { return }
            identity = snapshot.identity
            roles = applyPending(to: snapshot.roles)
            // Drop selections that changed state or disappeared.
            checked.formIntersection(Set(roles.filter { !$0.isActive }.map(\.id)))
            checkedActive.formIntersection(Set(roles.filter(\.isActive).map(\.id)))
            lastRefreshed = AppClock.now()
            loadState = .loaded
            reloadPresets()
            keepAliveAfterRefresh()
            loadPolicies(retryFailures: true)
            Task { await loadScheduled() }
            Task { await loadApprovals() }
        } catch {
            guard generation == tenantGeneration else { return }
            if let claims = (error as? SignInError)?.claims { authSettings.claimsChallenge = claims }
            loadState = .failed(message: error.localizedDescription, needsLogin: Self.needsLogin(error))
        }
    }

    /// Refreshes, first letting a load that is already running finish
    /// (`refresh()` alone returns at once then, leaving the old rows), so
    /// that the caller looks at current roles. Gives up waiting after a minute.
    private func refreshAfterRunningLoad() async {
        for _ in 0..<300 where loadState == .loading {
            try? await Task.sleep(for: .milliseconds(200))
        }
        await refresh()
    }

    /// Shows rows this app just changed the way they will be until Azure
    /// lists them so, and forgets those Azure agrees with (or that are stale).
    private func applyPending(to fresh: [EligibleRole]) -> [EligibleRole] {
        let now = AppClock.now()
        return fresh.map { role in
            guard let state = pending[role.id] else { return role }
            switch state {
            case .active(let until, let since):
                // Azure lists it with (about) the new expiry: done. A renewal
                // may still show the old activation for a moment.
                let caughtUp = role.isActive && (until == nil || (role.activeUntil ?? .distantFuture) >= until!.addingTimeInterval(-90))
                if caughtUp || (until.map { $0 <= now } ?? false) {
                    pending[role.id] = nil
                    return role
                }
                var shown = role
                shown.isActive = true
                shown.activeUntil = until
                shown.activeSince = since
                return shown
            case .inactive(let since):
                if !role.isActive || now.timeIntervalSince(since) > 180 {
                    pending[role.id] = nil
                    return role
                }
                return RenewPlan.asEligible(role)
            }
        }
    }

    /// Fills the tenant picker from ARM's `/tenants` listing and az's account
    /// cache. Failures keep the previous list: the picker still offers the
    /// default tenant and manual entry.
    func loadTenants() async {
        guard !isLoadingTenants else { return }
        isLoadingTenants = true
        defer { isLoadingTenants = false }
        let loaded: [TenantInfo]?
        switch authSource {
        case _ where AppRuntime.demo != nil:
            // The demo account's tenants, from the simulated `/tenants`.
            loaded = try? await AppRuntime.demo?.loadTenants(tokens: tokens(tenantId: tenant.tenantId))
        case .az: loaded = try? await TenantDirectory.load(preferredTenant: tenant.tenantId)
        case .pimento:
            // ARM's /tenants lists every tenant of the signed-in account.
            loaded = (try? await TenantDirectory.fetchARM(tokens: tokens(tenantId: tenant.tenantId))).map(TenantDirectory.sorted)
        }
        if let tenants = loaded, !tenants.isEmpty { knownTenants = tenants }
    }

    func setHidden(_ tenant: TenantInfo, _ hidden: Bool) {
        if hidden { hiddenTenantIds.insert(tenant.id) } else { hiddenTenantIds.remove(tenant.id) }
        AppRuntime.defaults.set(hiddenTenantIds.sorted(), forKey: Keys.hiddenTenants)
    }

    func unhideAllTenants() {
        hiddenTenantIds = []
        showHiddenTenants = false
        AppRuntime.defaults.removeObject(forKey: Keys.hiddenTenants)
    }

    func openTenantPicker() {
        guard !isActivating else { return }
        tenantQuery = ""
        hoveredTenantId = nil
        showTenantPicker = true
    }

    /// Switches tenant (nil = az default), remembers it, and reloads.
    func selectTenant(_ id: String?) {
        guard !tenant.isOverride, !isActivating else { return }
        let id = id?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let id, !id.isEmpty {
            guard TenantResolver.isValid(id) else {
                banner = Banner(kind: .error, text: TenantError.invalid(id).localizedDescription)
                return
            }
            AppRuntime.defaults.set(id, forKey: Keys.tenant)
            tenant = TenantSelection(tenantId: id, source: .saved)
        } else {
            AppRuntime.defaults.removeObject(forKey: Keys.tenant)
            tenant = TenantSelection(tenantId: nil, source: .azDefault)
        }
        restartSession()
    }

    /// A new service for the current tenant and auth source; forgets everything
    /// loaded with the previous one and reloads.
    func restartSession() {
        service = Self.makeService(tokens: tokens(tenantId: tenant.tenantId), history: historyRecorder)
        tenantGeneration += 1
        roles = []
        identity = nil
        checked = []
        checkedActive = []
        policies = [:]
        policyTask = nil
        scheduledRequests = []
        scheduledLoadState = .idle
        activationTickets = [:]
        cancelResults = [:]
        cancelling = []
        // Nothing asked in the previous session may be sent in this one.
        cancelTargets = []
        showCancelConfirmation = false
        showOwnerConfirmation = false
        showDeactivateConfirmation = false
        showRenewConfirmation = false
        lifecycleTargets = []
        showDecisionConfirmation = false
        deciding = []
        dryRunPlans = []
        showDryRunSheet = false
        approvalTracker = ApprovalTracker()
        updateApprovalPolling()
        approvalInbox = ApprovalInbox()
        approvalsLoadState = .idle
        approvalSelection = []
        decisionResults = [:]
        approvalMessage = nil
        seenApprovals = nil
        progress = [:]
        pending = [:]
        banner = nil
        lastRefreshed = nil
        loadState = .idle
        keepAliveReset()
        Task { await refresh() }
    }

    func isSelectedTenant(_ id: String?) -> Bool {
        guard let id else { return tenant.tenantId == nil }
        return tenant.tenantId?.caseInsensitiveCompare(id) == .orderedSame
    }

    func isChecked(_ role: EligibleRole) -> Bool {
        role.isActive ? checkedActive.contains(role.id) : checked.contains(role.id)
    }

    /// Eligible rows are checked for activation, active ones for Deactivate / Renew.
    func setChecked(_ role: EligibleRole, _ on: Bool) {
        if role.isActive {
            if on { checkedActive.insert(role.id) } else { checkedActive.remove(role.id) }
        } else {
            if on { checked.insert(role.id) } else { checked.remove(role.id) }
        }
    }

    /// Checks every not-yet-active row that matches the current search.
    func selectAllEligible() {
        for role in visibleRoles where !role.isActive { checked.insert(role.id) }
    }

    func clearSelection() {
        checked.removeAll()
        checkedActive.removeAll()
    }

    /// Entry point of the main button: Owner confirmation, or run. The
    /// preview (dry run) is its own, secondary action: buildDryRun().
    func requestActivation() {
        guard canActivate else { return }
        if prefs.confirmOwnerRoles && !checkedOwnerRoles.isEmpty {
            showOwnerConfirmation = true
        } else {
            Task { await activate() }
        }
    }

    /// One request per checked role, each capped at its policy maximum, from
    /// the chosen start (now, or scheduled) and with the ticket, if any.
    private func plans() async throws -> [PlannedRequest] {
        guard let identity else { throw ActivationRequestError.missingPrincipal }
        // What the user chose when pressing the button: the policy lookup
        // below can take seconds, and edits made meanwhile must not be sent.
        let roles = checkedRoles
        let justification = justification
        let ticket = currentTicket
        let start = scheduleStart
        let requested = duration
        let now = AppClock.now()
        if let start { try ScheduleTime.validate(start, now: now) }
        await ensurePolicies(for: roles)
        let needTicket = TicketRequirement.missing(roles, ticket: ticket) { self.policies[$0.policyKey] }
        if !needTicket.isEmpty {
            showTicketFields = true
            throw TicketMissing(roles: needTicket)
        }
        return try ActivationRequestBuilder.plan(
            roles, principalId: identity.objectId, justification: justification, now: now,
            start: start, ticket: ticket
        ) {
            EffectiveDuration.resolve(requested, policyMaxMinutes: self.policies[$0.policyKey]?.maxMinutes,
                                      fallbackHours: self.prefs.defaultHours)
        }
    }

    struct TicketMissing: LocalizedError {
        let roles: [EligibleRole]
        var errorDescription: String? {
            "A ticket number and ticket system are required for "
                + roles.prefix(3).map { "\($0.roleName) · \($0.scopeName)" }.joined(separator: ", ")
                + (roles.count > 3 ? " and \(roles.count - 3) more" : "") + "."
        }
    }

    func buildDryRun() {
        Task {
            do {
                dryRunPlans = try await plans()
                showDryRunSheet = true
            } catch {
                banner = Banner(kind: .error, text: error.localizedDescription)
            }
        }
    }

    func activate() async {
        guard !isActivating else { return }
        // Busy before the first await: loading the policies can take seconds,
        // and a second click (or ⌘↩, a preset, a reminder) must not send the
        // batch again meanwhile.
        isActivating = true
        let justification = trimmedJustification
        let ticket = currentTicket
        let requested = duration
        let scheduling = scheduleStart != nil
        let planned: [PlannedRequest]
        do { planned = try await plans() } catch {
            isActivating = false
            banner = Banner(kind: .error, text: error.localizedDescription)
            return
        }
        banner = nil
        rememberJustification(justification)
        rememberTicket(ticket)
        for plan in planned { progress[plan.id] = .queued }
        do {
            try await service.execute(
                planned,
                maxConcurrent: prefs.maxParallelRequests,
                onStart: { plan in await MainActor.run { self.progress[plan.id] = .running(scheduling ? "Scheduling…" : "Activating…") } },
                onResult: { plan, outcome in await MainActor.run { self.progress[plan.id] = .done(outcome) } }
            )
        } catch {
            for plan in planned where progress[plan.id] == .queued {
                progress[plan.id] = .done(.failed(code: "Auth", message: error.localizedDescription))
            }
            banner = Banner(kind: .error, text: error.localizedDescription)
        }
        let outcomes = planned.compactMap { plan -> ActivationOutcome? in
            if case .done(let o) = progress[plan.id] { return o }
            return nil
        }
        let awaiting = outcomes.filter(\.isAwaitingApproval).count
        let ok = outcomes.filter { if case .activated = $0 { return !$0.isAwaitingApproval }; return false }.count
        let scheduledStarts = outcomes.compactMap { o -> Date? in if case .scheduled(_, let start, _) = o { return start }; return nil }
        let skipped = outcomes.filter { $0 == .alreadyActive }.count
        let failed = outcomes.filter(\.isFailure).count
        if scheduledStarts.isEmpty {
            let waits = awaiting > 0 ? ", \(awaiting) awaiting approval (you get a notification when decided)" : ""
            banner = Banner(kind: failed > 0 ? .error : .success, text: "\(ok) activated\(waits), \(skipped) skipped, \(failed) failed.")
        } else {
            let when = Set(scheduledStarts.map(startLabel)).sorted().joined(separator: ", ")
            var text = "\(scheduledStarts.count) scheduled for \(when)"
            if ok > 0 { text += ", \(ok) activated" }
            if skipped > 0 { text += ", \(skipped) skipped" }
            if failed > 0 { text += ", \(failed) failed" }
            banner = Banner(kind: failed > 0 ? .error : .success, text: text + ". See Scheduled to cancel.")
        }
        // Activated and already-active rows are done: show them as active
        // right away and take them out of the selection.
        for plan in planned {
            guard case .done(let outcome) = progress[plan.id] else { continue }
            switch outcome {
            case .activated(let status, let until):
                if ActivationOutcome.isGranted(status: status) { pending[plan.id] = .active(until: until, since: plan.requestedAt) }
                checked.remove(plan.id)
            case .alreadyActive, .scheduled:
                checked.remove(plan.id)
            default:
                break
            }
        }
        noteClaimsChallenge(in: outcomes)
        // Back to "now" once everything was scheduled, so the next batch is not scheduled by accident.
        if scheduling, failed == 0 { scheduleStart = nil }
        isActivating = false
        Notifier.operationFinished(
            roles: planned.map(\.role), outcomes: finishedOutcomes, operation: .activate,
            context: reminderContext(justification: justification, duration: requested), prefs: prefs)
        await refreshAfterChange()
    }

    /// Outcomes of every row that finished.
    private var finishedOutcomes: [String: ActivationOutcome] {
        progress.compactMapValues { p -> ActivationOutcome? in
            if case .done(let o) = p { return o }
            return nil
        }
    }

    /// What expiry reminders carry for their Renew / End Now actions.
    private func reminderContext(justification: String, duration: RequestedDuration? = nil) -> Notifier.ReminderContext {
        Notifier.ReminderContext(
            // The GUID when known: the selection may be a domain.
            tenantId: identity?.tenantId ?? tenant.tenantId,
            // Whose roles: the actions refuse to run as anyone else.
            principalId: identity?.objectId,
            // Kept only when the user keeps recent justifications.
            justification: prefs.rememberJustifications && !justification.isEmpty ? justification : nil,
            duration: duration ?? self.duration)
    }

    /// Refreshes now and again shortly: ARM lists a change only after a few
    /// seconds, and the status should come from Azure, not from the overlay.
    func refreshAfterChange() async {
        await refresh()
        guard !pending.isEmpty else { return }
        let generation = tenantGeneration
        Task {
            for delay in [20, 40] {
                try? await Task.sleep(for: .seconds(delay))
                guard generation == self.tenantGeneration else { return }
                if self.pending.isEmpty { return }
                await self.refresh()
            }
        }
    }

    // MARK: Deactivate and renew

    var deactivateTitle: String {
        let n = checkedActiveRoles.count
        return n == 0 ? "Deactivate" : "Deactivate \(n)"
    }

    var renewTitle: String {
        let n = checkedActiveRoles.count
        return n == 0 ? "Renew" : "Renew \(n)"
    }

    var canChangeActive: Bool { !isActivating && !checkedActiveRoles.isEmpty && identity != nil }

    /// Asks before ending `roles` (default: the checked active rows).
    func requestDeactivation(_ roles: [EligibleRole]? = nil) {
        let targets = (roles ?? checkedActiveRoles).filter(\.isActive)
        guard !isActivating, !targets.isEmpty, identity != nil else { return }
        lifecycleTargets = targets
        showDeactivateConfirmation = true
    }

    /// Asks before renewing `roles`: always, because of the gap.
    func requestRenewal(_ roles: [EligibleRole]? = nil) {
        let targets = (roles ?? checkedActiveRoles).filter(\.isActive)
        guard !isActivating, !targets.isEmpty, identity != nil else { return }
        guard !trimmedJustification.isEmpty else {
            checkedActive = Set(targets.map(\.id))
            banner = Banner(kind: .error, text: "Renewing activates the roles again: enter a justification, then press Renew.")
            justificationFocusRequest += 1
            return
        }
        lifecycleTargets = targets
        loadPolicies(for: targets)
        showRenewConfirmation = true
    }

    /// The confirmation's targets split by what PIM allows now.
    func lifecycleSelection(forRenewal: Bool) -> RoleLifecycle.Selection {
        // Policies still loading count as known here; renew() decides once they are in.
        renewalSelection(lifecycleTargets, forRenewal: forRenewal, loadingIsKnown: true)
    }

    /// The ticket a renewal of `role` sends: the ticket fields when filled in,
    /// else the ticket its current activation was requested with.
    func renewalTicket(for role: EligibleRole) -> TicketInfo? {
        RenewTicket.choose(given: currentTicket, original: RequestHistory.ticket(for: role, in: activationTickets))
    }

    /// A role whose policy could not be read is not renewed: whether it
    /// would need approval to come back is unknown.
    private func renewalSelection(_ targets: [EligibleRole], forRenewal: Bool = true, loadingIsKnown: Bool = false) -> RoleLifecycle.Selection {
        RoleLifecycle.select(
            targets, now: AppClock.now(), forRenewal: forRenewal,
            needsTicket: { RenewTicket.isMissing($0, ticket: self.renewalTicket(for: $0), policy: self.policies[$0.policyKey]) },
            requiresApproval: { self.policies[$0.policyKey]?.policy?.requiresApproval == true },
            policyKnown: { role in
                guard let lookup = self.policies[role.policyKey] else { return loadingIsKnown }
                return lookup.policy != nil
            })
    }

    /// Ends the activations of `roles` (SelfDeactivate).
    func deactivate(_ targets: [EligibleRole]) async {
        guard !isActivating, let identity else { return }
        let selection = RoleLifecycle.select(targets, now: AppClock.now())
        let planned: [PlannedRequest]
        do {
            planned = try ActivationRequestBuilder.deactivationPlan(selection.ready, principalId: identity.objectId)
        } catch {
            banner = Banner(kind: .error, text: error.localizedDescription)
            return
        }
        isActivating = true
        banner = nil
        for role in selection.tooSoon {
            progress[role.id] = .done(.tooSoon(possibleAt: RoleLifecycle.earliestDeactivation(of: role)))
        }
        for plan in planned { progress[plan.id] = .queued }
        do {
            try await service.execute(
                planned,
                maxConcurrent: prefs.maxParallelRequests,
                onStart: { plan in await MainActor.run { self.progress[plan.id] = .running("Ending…") } },
                onResult: { plan, outcome in await MainActor.run { self.progress[plan.id] = .done(outcome) } }
            )
        } catch {
            for plan in planned where progress[plan.id] == .queued {
                progress[plan.id] = .done(.failed(code: "Auth", message: error.localizedDescription))
            }
            banner = Banner(kind: .error, text: error.localizedDescription)
        }
        var ended: [EligibleRole] = []
        let now = AppClock.now()
        for plan in planned {
            guard case .done(let outcome) = progress[plan.id] else { continue }
            switch outcome {
            case .deactivated, .notActive:
                ended.append(plan.role)
                checkedActive.remove(plan.id)
                // Every row of that scope + role (direct and through a group).
                for row in self.roles(sharing: plan.role) { pending[row.id] = .inactive(since: now) }
            default:
                break
            }
        }
        let outcomes = finishedOutcomes
        let all = selection.tooSoon + planned.map(\.role)
        let failed = all.filter { outcomes[$0.id]?.isFailure == true }
        banner = Banner(kind: failed.isEmpty ? .success : .error, text: lifecycleBanner(
            done: ended.count, verb: "deactivated", failed: failed, outcomes: outcomes))
        noteClaimsChallenge(in: planned.compactMap { outcomes[$0.id] })
        isActivating = false
        roles = applyPending(to: roles)
        Notifier.rolesEnded(Set(ended.map { ReminderRole.key($0.policyKey) }))
        Notifier.operationFinished(roles: all, outcomes: outcomes, operation: .deactivate,
                                   context: reminderContext(justification: ""), prefs: prefs)
        await refreshAfterChange()
    }

    /// Ends and re-activates `roles` for the chosen duration (capped at each
    /// policy maximum). Roles whose policy requires approval are left alone.
    func renew(_ targets: [EligibleRole], justification text: String? = nil, duration asked: RequestedDuration? = nil) async {
        guard !isActivating, let identity else { return }
        let justification = (text ?? trimmedJustification).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !justification.isEmpty else {
            banner = Banner(kind: .error, text: ActivationRequestError.missingJustification.localizedDescription)
            return
        }
        // Busy before the first await (see activate()): no second renewal of the same roles.
        isActivating = true
        let requested = asked ?? duration
        await ensurePolicies(for: targets)
        // The tickets the activations were requested with, read fresh: Renew sends them again.
        var historyError: String?
        do { activationTickets = try await service.readOnly.loadRequestHistory().activationTickets } catch {
            historyError = error.localizedDescription
        }
        let selection = renewalSelection(targets)
        let plans: [RenewPlan]
        do {
            plans = try ActivationRequestBuilder.renewPlan(
                selection.ready, principalId: identity.objectId, justification: justification,
                ticket: { self.renewalTicket(for: $0) }
            ) {
                EffectiveDuration.resolve(requested, policyMaxMinutes: self.policies[$0.policyKey]?.maxMinutes,
                                          fallbackHours: self.prefs.defaultHours)
            }
        } catch {
            isActivating = false
            banner = Banner(kind: .error, text: error.localizedDescription)
            return
        }
        banner = nil
        rememberJustification(justification)
        for role in selection.tooSoon {
            progress[role.id] = .done(.tooSoon(possibleAt: RoleLifecycle.earliestDeactivation(of: role)))
        }
        for role in selection.needsApproval {
            progress[role.id] = .done(.failed(code: "ApprovalRequired",
                                              message: "Its policy requires approval: after ending it you would wait for an approver. Not renewed."))
        }
        for role in selection.policyUnknown {
            progress[role.id] = .done(.failed(code: "PolicyUnknown",
                                              message: "Its policy could not be read, so it might need approval to come back. Not renewed."))
        }
        for role in selection.needsTicket {
            let why = historyError.map { " (reading your requests failed: \($0))" } ?? ""
            progress[role.id] = .done(.failed(code: "TicketRequired",
                                              message: "Its policy requires a ticket and the current activation's ticket is unknown\(why): fill in ticket number and system, then Renew. Not renewed."))
        }
        if !selection.needsTicket.isEmpty { showTicketFields = true }
        for plan in plans { progress[plan.id] = .queued }
        do {
            try await service.renew(
                plans,
                maxConcurrent: min(4, prefs.maxParallelRequests),
                onPhase: { plan, phase in
                    await MainActor.run {
                        switch phase {
                        case .deactivating: self.progress[plan.id] = .running("Ending…")
                        case .reactivating(let attempt):
                            self.progress[plan.id] = .running(attempt > 1 ? "Activating again (try \(attempt))…" : "Activating again…")
                        }
                    }
                },
                onResult: { plan, outcome in await MainActor.run { self.progress[plan.id] = .done(outcome) } }
            )
        } catch {
            for plan in plans where progress[plan.id] == .queued {
                progress[plan.id] = .done(.failed(code: "Auth", message: error.localizedDescription))
            }
            banner = Banner(kind: .error, text: error.localizedDescription)
        }
        var renewed: [EligibleRole] = []
        var lost: [EligibleRole] = []
        var awaiting: [EligibleRole] = []
        let now = AppClock.now()
        for plan in plans {
            guard case .done(let outcome) = progress[plan.id] else { continue }
            switch outcome {
            case .renewed(let until):
                renewed.append(plan.role)
                for row in self.roles(sharing: plan.role) { pending[row.id] = .active(until: until, since: now) }
            case .activated:
                // Ended, and the new activation was only submitted (waits for
                // an approver): not active now.
                awaiting.append(plan.role)
                checkedActive.remove(plan.id)
                for row in self.roles(sharing: plan.role) { pending[row.id] = .inactive(since: now) }
            case .failed(let code, _) where code == "ReactivationFailed":
                lost.append(plan.role)
                checkedActive.remove(plan.id)
                for row in self.roles(sharing: plan.role) { pending[row.id] = .inactive(since: now) }
            default:
                break
            }
        }
        let outcomes = finishedOutcomes
        let all = selection.tooSoon + selection.needsApproval + selection.policyUnknown + selection.needsTicket + plans.map(\.role)
        let failed = all.filter { outcomes[$0.id]?.isFailure == true }
        var text = lifecycleBanner(done: renewed.count, verb: "renewed", failed: failed, outcomes: outcomes)
        if !awaiting.isEmpty {
            text += " \(awaiting.count) ended and awaiting approval (you get a notification when decided)."
        }
        if !lost.isEmpty { text += " \(lost.count) ended but not active again: activate \(lost.count == 1 ? "it" : "them") again." }
        banner = Banner(kind: !failed.isEmpty ? .error : awaiting.isEmpty ? .success : .info, text: text)
        // A reactivation refused for MFA or an authentication context carries
        // the claims challenge in its message, as an activation does.
        noteClaimsChallenge(in: plans.compactMap { outcomes[$0.id] })
        isActivating = false
        roles = applyPending(to: roles)
        // The old reminders are for the old expiry; renewed roles get new ones.
        Notifier.rolesEnded(Set((renewed + lost + awaiting).map { ReminderRole.key($0.policyKey) }))
        Notifier.operationFinished(roles: all, outcomes: outcomes, operation: .renew,
                                   context: reminderContext(justification: justification, duration: requested), prefs: prefs)
        await refreshAfterChange()
    }

    /// Rows for the same scope + role as `role` (one activation).
    private func roles(sharing role: EligibleRole) -> [EligibleRole] {
        roles.filter { $0.policyKey == role.policyKey }
    }

    private func lifecycleBanner(done: Int, verb: String, failed: [EligibleRole], outcomes: [String: ActivationOutcome]) -> String {
        var parts = ["\(done) \(verb)"]
        let tooSoon = failed.compactMap { role -> Date? in
            if case .tooSoon(let at)? = outcomes[role.id] { return at ?? .distantPast }
            return nil
        }
        if !tooSoon.isEmpty {
            let latest = tooSoon.max().flatMap { $0 == .distantPast ? nil : $0 }
            parts.append("\(tooSoon.count) too soon (PIM ends an activation only after 5 minutes\(latest.map { "; try again from \($0.formatted(date: .omitted, time: .shortened))" } ?? ""))")
        }
        let other = failed.count - tooSoon.count
        if other > 0 { parts.append("\(other) failed") }
        return parts.joined(separator: ", ") + "."
    }

    // MARK: Reminder actions

    /// A tap on "Renew" or "End Now" in an expiry reminder.
    func handleReminderAction(_ action: ReminderAction, payload: ReminderPayload) async {
        while isActivating { try? await Task.sleep(for: .milliseconds(300)) }
        // Current roles and identity first: right after launch (a tap on the
        // reminder can start the app) neither is loaded yet, and an empty
        // list would read as "no longer active".
        await refreshAfterRunningLoad()
        guard loadState == .loaded else {
            NSApp.activate(ignoringOtherApps: true)
            banner = Banner(kind: .error, text: "Could not load the roles to act on that reminder. Refresh, then renew or end them here.")
            return
        }
        // Only for the account that activated the roles: after switching
        // accounts the same scope and role would be someone else's.
        guard payload.isPrincipal(identity?.objectId) else {
            NSApp.activate(ignoringOtherApps: true)
            banner = Banner(kind: .error, text: "That reminder is for another account than the one signed in now. "
                + "Switch back to it, then renew or end the roles here.")
            return
        }
        // The reminder names the tenant by GUID (older ones as selected).
        guard payload.isTenant(identity?.tenantId) || payload.isTenant(tenant.tenantId) else {
            NSApp.activate(ignoringOtherApps: true)
            banner = Banner(kind: .error, text: "That reminder is for tenant \(payload.tenantId ?? "?"). Switch to it, then renew or end the roles here.")
            return
        }
        let targets = payload.matchingActive(in: roles)
        guard !targets.isEmpty else {
            if action == .renew { NSApp.activate(ignoringOtherApps: true) }
            banner = Banner(kind: .info, text: "The roles in that reminder are no longer active.")
            Notifier.rolesEnded(Set(payload.roles.map(\.key)))
            return
        }
        switch action {
        case .end:
            if targets.contains(where: \.isOwner) && prefs.confirmOwnerRoles {
                // As in the app: Owner roles are ended after the confirmation there.
                NSApp.activate(ignoringOtherApps: true)
                requestDeactivation(targets)
            } else {
                await deactivate(targets)
            }
        case .renew:
            let owners = targets.contains(where: \.isOwner) && prefs.confirmOwnerRoles
            let text = payload.justification?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if text.isEmpty || owners {
                // Needs the user: a justification, or the Owner confirmation.
                // Whatever is in the justification field was not chosen for
                // these roles, so it is only sent once the user confirms.
                checkedActive = Set(targets.map(\.id))
                if let d = payload.duration { duration = d }
                if !text.isEmpty { justification = text }
                NSApp.activate(ignoringOtherApps: true)
                requestRenewal(targets)
            } else {
                await renew(targets, justification: text, duration: payload.duration)
            }
        }
    }

    func clearResults() { progress.removeAll() }

    // MARK: Presets

    /// The tenant presets are saved for: the token's tenant (a GUID), else the chosen one.
    var presetTenantId: String? { identity?.tenantId ?? tenant.tenantId }

    /// Presets for the tenant in use (and presets for any tenant).
    var visiblePresets: [Preset] { presetLibrary.presets(forTenant: presetTenantId) }

    func reloadPresets() {
        do {
            presetLibrary = try presetStore.load()
            presetFileError = nil
        } catch {
            presetFileError = error.localizedDescription
        }
    }

    /// Read-modify-write, so presets saved by the CLI meanwhile are kept.
    @discardableResult
    private func updatePresets<T>(_ change: (inout PresetLibrary) throws -> T) throws -> T {
        let (library, result) = try presetStore.update(change)
        presetLibrary = library
        presetFileError = nil
        return result
    }

    /// Checks the preset's roles (only those), and takes over its
    /// justification and duration. Says what is active or missing.
    @discardableResult
    func applyPreset(_ preset: Preset) -> PresetResolution {
        let resolution = preset.resolve(in: roles)
        search = ""
        checked = Set(resolution.eligible.map(\.id))
        if let text = preset.trimmedJustification { justification = text }
        if let d = preset.duration { duration = d }
        if let system = preset.trimmedTicketSystem { ticketSystem = system }
        loadPolicies(for: resolution.eligible)
        var parts = ["\(preset.name): \(resolution.eligible.count) role\(resolution.eligible.count == 1 ? "" : "s") selected"]
        if !resolution.active.isEmpty { parts.append("\(resolution.active.count) already active") }
        if !resolution.missing.isEmpty {
            let names = resolution.missing.prefix(3).map(\.label).joined(separator: ", ")
            parts.append("\(resolution.missing.count) no longer eligible (\(names)\(resolution.missing.count > 3 ? ", …" : ""))")
        }
        banner = Banner(kind: resolution.missing.isEmpty ? .info : .error, text: parts.joined(separator: " · ") + ".")
        return resolution
    }

    /// Selects the preset's roles and activates them (with the Owner
    /// confirmation when that is on).
    func activatePreset(_ preset: Preset) {
        guard !isActivating, !roles.isEmpty else { return }
        let resolution = applyPreset(preset)
        if resolution.eligible.isEmpty {
            let why = resolution.roles.isEmpty ? "none of its roles are eligible" : "all of its roles are already active"
            banner = Banner(kind: resolution.missing.isEmpty ? .info : .error, text: "\(preset.name): nothing to activate, \(why).")
            return
        }
        guard !trimmedJustification.isEmpty else {
            banner = Banner(kind: .error, text: "\(preset.name) has no justification: enter one, then press Activate.")
            return
        }
        requestActivation()
    }

    func beginSavePreset() {
        guard !checkedRoles.isEmpty else { return }
        savePresetName = ""
        savePresetJustification = trimmedJustification
        savePresetIncludesJustification = !trimmedJustification.isEmpty
        savePresetIncludesDuration = duration != .hours(prefs.defaultHours)
        savePresetError = nil
        showSavePresetSheet = true
    }

    /// A preset of that name exists for this tenant: saving replaces it.
    var savePresetReplaces: Bool {
        visiblePresets.contains { PresetLibrary.sameName($0.name, savePresetName) && PresetLibrary.sameTenant($0.tenantId, presetTenantId) }
    }

    /// Saves the checked roles as a preset. True when it worked.
    func saveSelectionAsPreset() -> Bool {
        var seen = Set<RoleMatcher.Key>()
        let roles = checkedRoles.filter { seen.insert($0.policyKey).inserted }.map(PresetRole.init)
        let text = savePresetJustification.trimmingCharacters(in: .whitespacesAndNewlines)
        let preset = Preset(
            name: savePresetName, tenantId: presetTenantId, roles: roles,
            justification: savePresetIncludesJustification && !text.isEmpty ? text : nil,
            duration: savePresetIncludesDuration ? duration : nil)
        do {
            let saved = try updatePresets { try $0.save(preset, replacing: true) }
            banner = Banner(kind: .success, text: "Saved preset “\(saved.name)” with \(saved.summary).")
            return true
        } catch {
            savePresetError = error.localizedDescription
            return false
        }
    }

    func openManagePresets() {
        reloadPresets()
        presetDraftError = nil
        selectManagedPreset(managedPresetId.flatMap { id in visiblePresets.first { $0.id == id } }?.id ?? visiblePresets.first?.id)
        showManagePresets = true
    }

    func selectManagedPreset(_ id: UUID?) {
        managedPresetId = id
        presetDraft = id.flatMap { id in presetLibrary.presets.first { $0.id == id } }
        presetDraftError = nil
    }

    /// The draft differs from what is saved.
    var presetDraftIsDirty: Bool {
        guard let draft = presetDraft else { return false }
        return presetLibrary.presets.first { $0.id == draft.id } != draft
    }

    func draftContains(_ role: EligibleRole) -> Bool {
        presetDraft?.roles.contains { $0.key == role.policyKey } ?? false
    }

    func setDraft(_ role: EligibleRole, included: Bool) {
        guard presetDraft != nil else { return }
        presetDraft!.roles.removeAll { $0.key == role.policyKey }
        if included { presetDraft!.roles.append(PresetRole(role)) }
    }

    /// Exact roles of the draft that are not among the current eligibilities.
    var draftMissingRoles: [PresetRole] {
        guard let draft = presetDraft, !roles.isEmpty else { return [] }
        return draft.resolve(in: roles).missing
    }

    func removeFromDraft(_ item: PresetRole) { presetDraft?.roles.removeAll { $0.key == item.key } }
    func removeFromDraft(_ rule: PresetRule) { presetDraft?.match.removeAll { $0 == rule } }

    /// Replaces the draft's roles with the checked ones.
    func setDraftRolesToSelection() {
        var seen = Set<RoleMatcher.Key>()
        presetDraft?.roles = checkedRoles.filter { seen.insert($0.policyKey).inserted }.map(PresetRole.init)
    }

    func newPreset() {
        var n = 1
        var name = "New Preset"
        while visiblePresets.contains(where: { PresetLibrary.sameName($0.name, name) }) {
            n += 1
            name = "New Preset \(n)"
        }
        var seen = Set<RoleMatcher.Key>()
        let roles = checkedRoles.filter { seen.insert($0.policyKey).inserted }.map(PresetRole.init)
        managedPresetId = nil
        presetDraft = Preset(name: name, tenantId: presetTenantId, roles: roles,
                             justification: trimmedJustification.isEmpty ? nil : trimmedJustification)
        presetDraftError = nil
    }

    func saveDraft() {
        guard let draft = presetDraft else { return }
        // Keep-alive on for access-granting roles: confirmed once, now.
        if draft.keepAlive {
            let needing = keepAliveNeedingConsent(draft.resolve(in: roles).roles)
            if !needing.isEmpty {
                keepAliveConsent = KeepAliveConsentRequest(roles: needing, targets: [], preset: draft.name)
                return
            }
        }
        saveDraftNow()
    }

    /// Saves the draft (after the keep-alive confirmation, if one was needed).
    func saveDraftNow() {
        guard let draft = presetDraft else { return }
        do {
            let saved = try updatePresets { try $0.save(draft) }
            presetDraft = saved
            managedPresetId = saved.id
            presetDraftError = nil
        } catch {
            presetDraftError = error.localizedDescription
        }
    }

    func revertDraft() { selectManagedPreset(managedPresetId) }

    func deleteManagedPreset() {
        guard let id = presetDraft?.id else { return }
        do {
            try updatePresets { $0.delete(id) }
            selectManagedPreset(visiblePresets.first?.id)
        } catch {
            presetDraftError = error.localizedDescription
        }
    }

    // MARK: History

    /// Reads the history file again (it is shared with the CLI).
    func reloadHistory() {
        historyRecords = historyStore.records(settings: historySettings, knownTenants: knownTenantLabels)
    }

    private var knownTenantLabels: [String: String] {
        Dictionary(knownTenants.compactMap { t in t.name.map { (t.id, $0) } }, uniquingKeysWith: { a, _ in a })
    }

    func openHistory() {
        historyMessage = nil
        reloadHistory()
        showHistory = true
        NSApp.activate(ignoringOtherApps: true)
    }

    /// The filter of the History window's controls.
    var historyFilter: HistoryFilter {
        var filter = HistoryFilter(text: historySearch)
        if historyPeriod == .custom {
            (filter.since, filter.until) = HistoryPeriod.customRange(from: historyFrom, to: historyTo)
        } else {
            filter.since = historyPeriod.since(now: AppClock.now())
        }
        if let historyAction { filter.actions = [historyAction] }
        if let historyResult { filter.results = [historyResult] }
        filter.tenant = historyTenant
        return filter
    }

    /// The rows of the History window: filtered, in the table's sort order.
    var visibleHistory: [HistoryRecord] {
        historyFilter.apply(historyRecords).sorted(using: historySortOrder)
    }

    var historyTenants: [(id: String, label: String)] { HistoryLog.tenants(in: historyRecords) }

    var historyFiltersActive: Bool {
        !historySearch.trimmingCharacters(in: .whitespaces).isEmpty || historyAction != nil || historyResult != nil
            || historyTenant != nil || historyPeriod != .all
    }

    func resetHistoryFilters() {
        historySearch = ""
        historyAction = nil
        historyResult = nil
        historyTenant = nil
        historyPeriod = .all
    }

    /// Reads your past requests from Azure (read-only) and adds the ones the
    /// history does not have yet.
    func importHistoryFromAzure() async {
        guard historyImportState != .loading, tenantError == nil else { return }
        historyImportState = .loading
        historyMessage = nil
        let service = service.readOnly
        let store = historyStore
        let label = effectiveTenantId.flatMap(knownTenant)?.name
        let cutoff = historySettings.retention.cutoff(now: AppClock.now())
        do {
            let records = try await service.loadHistoryFromAzure(tenantLabel: label)
            let kept = records.filter { cutoff == nil || $0.at >= cutoff! }
            let result = try await Task.detached { try store.importRecords(kept) }.value
            historyImportState = .loaded
            var text = "Read \(records.count) request\(records.count == 1 ? "" : "s") from Azure: \(result.added) added, \(result.known) already here"
            if records.count > kept.count { text += ", \(records.count - kept.count) older than \(historySettings.retention.title.lowercased())" }
            historyMessage = Banner(kind: .success, text: text + ".")
            reloadHistory()
        } catch {
            historyImportState = .failed(message: error.localizedDescription, needsLogin: Self.needsLogin(error))
            historyMessage = Banner(kind: .error, text: "Import from Azure failed: \(error.localizedDescription)")
        }
    }

    /// Asks where to save, then writes the rows shown (filtered and sorted) as CSV.
    func exportHistoryCSV() {
        let records = visibleHistory
        let panel = NSSavePanel()
        panel.title = "Export History"
        panel.nameFieldStringValue = "pimento-history-\(AppClock.now().formatted(.iso8601.year().month().day())).csv"
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try HistoryCSV.write(records, to: url)
            historyMessage = Banner(kind: .success, text: "Exported \(records.count) record\(records.count == 1 ? "" : "s") to \(url.lastPathComponent).")
        } catch {
            historyMessage = Banner(kind: .error, text: error.localizedDescription)
        }
    }

    func showHistoryInFinder() {
        let fm = FileManager.default
        if fm.fileExists(atPath: historyStore.url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([historyStore.url])
        } else {
            let dir = historyStore.url.deletingLastPathComponent()
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            NSWorkspace.shared.open(dir)
        }
    }

    func clearHistory() {
        do {
            try historyStore.clear()
            historyMessage = Banner(kind: .success, text: "History cleared.")
        } catch {
            historyMessage = Banner(kind: .error, text: error.localizedDescription)
        }
        reloadHistory()
    }

    /// Checks the role of `record` and fills in its justification, ticket and
    /// duration, ready to activate again.
    func activateAgain(_ record: HistoryRecord) {
        switch HistoryReplay.verdict(for: record, roles: roles, tenantId: identity?.tenantId ?? effectiveTenantId) {
        case .ready(let role):
            showHistory = false
            search = ""
            checked = [role.id]
            checkedActive = []
            scheduleStart = nil
            // Exactly what that request carried: a justification or ticket
            // left in the fields from something else is not sent with it.
            justification = record.justification ?? ""
            if let d = HistoryReplay.duration(of: record) { duration = d }
            if let ticket = record.ticket {
                ticketNumber = ticket.ticketNumber ?? ""
                if let system = ticket.ticketSystem { ticketSystem = system }
                showTicketFields = true
            } else {
                ticketNumber = ""
            }
            loadPolicies(for: [role])
            let carried = [record.justification == nil ? nil : "justification", record.ticket == nil ? nil : "ticket"].compactMap { $0 }
            let when = record.at.formatted(date: .abbreviated, time: .shortened)
            banner = Banner(kind: .info, text: "\(role.roleName) · \(role.scopeName) selected"
                + (carried.isEmpty ? " (that request of \(when) kept no justification: enter one)" : " with the \(carried.joined(separator: " and ")) of \(when)")
                + ". Press Activate.")
            justificationFocusRequest += 1
        case .alreadyActive(let role):
            historyMessage = Banner(kind: .info, text: "\(role.roleName) · \(role.scopeName) is active now.")
        case .notEligible:
            historyMessage = Banner(kind: .error, text: "\(record.roleDisplay) · \(record.scopeDisplay) is not among your eligible roles here.")
        case .otherTenant(let id):
            historyMessage = Banner(kind: .error, text: "That was in tenant \(record.tenantLabel ?? id). Switch to it (⇧⌘T), then try again.")
        case .notAnActivation:
            break
        }
    }

    /// Whether "Activate Again" applies to `record` right now.
    func canActivateAgain(_ record: HistoryRecord) -> Bool {
        guard !isActivating else { return false }
        if case .ready = HistoryReplay.verdict(for: record, roles: roles, tenantId: identity?.tenantId ?? effectiveTenantId) { return true }
        return false
    }

    private func historySettingsChanged(from old: HistorySettings) {
        guard historySettings != old else { return }
        do { try historyStore.saveSettings(historySettings) } catch {
            historyMessage = Banner(kind: .error, text: error.localizedDescription)
        }
        if historySettings.retention != old.retention {
            let store = historyStore, retention = historySettings.retention
            Task {
                _ = try? await Task.detached { try store.prune(retention: retention) }.value
                self.reloadHistory()
            }
        }
    }

    // MARK: Settings

    private func preferencesChanged(from old: Preferences) {
        let valid = prefs.validated()
        guard valid == prefs else {
            prefs = valid  // re-enters with a valid value
            return
        }
        guard prefs != old else { return }
        prefs.save(to: AppRuntime.defaults)
        updateAppearance()
        if AppPresence.activationPolicy(prefs) != AppPresence.activationPolicy(old) { DockIcon.apply(prefs, reactivate: true) }
        if prefs.defaultHours != old.defaultHours, !isActivating { duration = .hours(prefs.defaultHours) }
        if prefs.autoRefreshMinutes != old.autoRefreshMinutes {
            restartAutoRefresh()
            updateApprovalPolling()
        }
        if !prefs.rememberJustifications, old.rememberJustifications {
            clearRecentJustifications()
            clearRecentTickets()
        }
        if prefs.notifyScheduledStart != old.notifyScheduledStart {
            Notifier.syncScheduledStarts(scheduledRequests, tenantId: identity?.tenantId ?? effectiveTenantId, prefs: prefs)
        }
        if prefs.keepAliveHours != old.keepAliveHours || prefs.keepAlivePaused != old.keepAlivePaused {
            keepAliveSettingsChanged(from: old)
        }
        if !prefs.expiryReminders, old.expiryReminders {
            Notifier.cancelReminders()
        } else if prefs.expiryReminders, prefs.reminderLeadMinutes != old.reminderLeadMinutes {
            Notifier.rescheduleReminders(lead: prefs.reminderLead)
        }
    }

    /// Applies `prefs.resolvedAppearance()` if it changed, and arms the
    /// timer for the next change of the time-of-day schedule.
    func updateAppearance() {
        let date = AppClock.now()
        let resolved = prefs.resolvedAppearance(at: date)
        if resolved != appearance {
            appearance = resolved
            AppAppearance.apply(resolved)
        }
        scheduleAppearanceChange(after: date)
    }

    /// One timer for the next boundary, none outside the time-of-day mode.
    /// Timers do not count time asleep and ignore clock changes, hence
    /// `observeClockChanges`. A timer firing a little early re-arms for the
    /// same boundary.
    private func scheduleAppearanceChange(after date: Date) {
        appearanceTimer?.invalidate()
        appearanceTimer = nil
        guard let next = prefs.nextAppearanceChange(after: date) else { return }
        let timer = Timer(fire: next, interval: 0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateAppearance() }
        }
        timer.tolerance = 1
        RunLoop.main.add(timer, forMode: .common)
        appearanceTimer = timer
    }

    /// Re-checks the appearance after sleep, a clock change and a time-zone
    /// change: the schedule is in local wall-clock time.
    private func observeClockChanges() {
        let workspace = NSWorkspace.shared.notificationCenter, center = NotificationCenter.default
        let names: [(NotificationCenter, Notification.Name)] = [
            (workspace, NSWorkspace.didWakeNotification),
            (center, .NSSystemClockDidChange),
            (center, .NSSystemTimeZoneDidChange),
        ]
        clockObservers = names.map { center, name in
            (center, center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.updateAppearance()
                    // Timers do not count time asleep: look at the kept roles now.
                    self?.keepAliveClockChanged()
                }
            })
        }
    }

    /// Back to the defaults. Hidden tenants and the remembered tenant stay.
    func resetPreferences() {
        prefs = Preferences()
        columnCustomization = TableColumnCustomization()
        // After the assignments, whose didSet saves: no stored value pins
        // today's defaults, so future defaults apply.
        Preferences.reset(in: AppRuntime.defaults)
        AppRuntime.defaults.removeObject(forKey: Keys.tableColumns)
    }

    private func rememberJustification(_ text: String) {
        guard prefs.rememberJustifications else { return }
        recentJustifications = Preferences.recording(text, in: recentJustifications)
        AppRuntime.defaults.set(recentJustifications, forKey: Keys.recentJustifications)
    }

    func clearRecentJustifications() {
        recentJustifications = []
        AppRuntime.defaults.removeObject(forKey: Keys.recentJustifications)
    }

    func isColumnVisible(_ column: Column) -> Bool {
        columnCustomization[visibility: column.rawValue] != .hidden
    }

    func setColumn(_ column: Column, visible: Bool) {
        columnCustomization[visibility: column.rawValue] = visible ? .visible : .hidden
    }

    private func saveColumnCustomization() {
        if let data = try? JSONEncoder().encode(columnCustomization) {
            AppRuntime.defaults.set(data, forKey: Keys.tableColumns)
        }
    }

    /// Refreshes every `autoRefreshMinutes` while idle (not during an activation).
    private func restartAutoRefresh() {
        autoRefreshTask?.cancel()
        autoRefreshTask = nil
        let minutes = prefs.autoRefreshMinutes
        guard minutes > 0 else { return }
        autoRefreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(minutes * 60))
                guard !Task.isCancelled, let self else { return }
                if !self.isActivating, self.loadState != .loading, self.tenantError == nil {
                    await self.refresh()
                }
            }
        }
    }

    func updateNotificationPermission() async {
        notificationPermission = await Notifier.permission()
    }

    func sendTestNotification() async {
        notificationTestResult = await Notifier.sendTest(prefs: prefs)
        await updateNotificationPermission()
    }
}
