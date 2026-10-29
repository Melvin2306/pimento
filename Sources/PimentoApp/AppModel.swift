import AppKit
import Foundation
import Observation
import PimentoCore
import SwiftUI

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
    var startPickerDraft = Date()
    /// Your pending requests in Azure (scheduled, or awaiting approval).
    var scheduledRequests: [ScheduledRequest] = []
    var scheduledLoadState: LoadState = .idle
    var showScheduled = false
    /// Requests being cancelled, and how cancelling went.
    var cancelling: Set<String> = []
    var cancelResults: [String: CancelOutcome] = [:]
    var showCancelAllConfirmation = false

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
    let presetStore = PresetStore()
    var presetLibrary = PresetLibrary()
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

    // Settings (⌘,), saved to UserDefaults on every change.
    var prefs: Preferences {
        didSet { preferencesChanged(from: oldValue) }
    }
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
    var knownTenants: [TenantInfo] = []
    private(set) var isLoadingTenants = false
    /// Tenants the user hid from the picker (lower-case IDs).
    private(set) var hiddenTenantIds: Set<String> = []
    var showTenantPicker = false
    var tenantQuery = ""
    var showHiddenTenants = false
    var hoveredTenantId: String?
    var showTenantSheet = false
    var tenantDraft = ""

    struct Banner: Equatable {
        enum Kind { case info, success, error }
        let kind: Kind
        let text: String
    }

    private enum Keys {
        /// The tenant last picked in the app.
        static let tenant = "tenantId"
        static let hiddenTenants = "hiddenTenantIds"
        static let recentJustifications = "recentJustifications"
        static let recentTickets = "recentTickets"
        static let lastTicketSystem = "lastTicketSystem"
        static let tableColumns = "tableColumns"
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

    private var service: PIMService
    private var tenantGeneration = 0

    init(commandLineTenant: String?) {
        // 0.1.0 persisted a dry-run mode; activation is now always real (the
        // preview is a separate action), so the stale setting is dropped.
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: "dryRun")
        self.commandLineTenant = commandLineTenant
        let prefs = Preferences.load(from: defaults)
        self.prefs = prefs
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
            selection = try TenantResolver.resolve(commandLine: commandLineTenant, saved: saved)
        } catch {
            selection = TenantSelection(tenantId: nil, source: .azDefault)
            tenantError = error.localizedDescription
        }
        tenant = selection
        service = PIMService(tokens: AzureCLITokenProvider(tenantId: selection.tenantId))
        restartAutoRefresh()
        reloadPresets()
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
        if let system = ticket.ticketSystem { UserDefaults.standard.set(system, forKey: Keys.lastTicketSystem) }
        guard prefs.rememberJustifications else { return }
        recentTickets = TicketInfo.recording(ticket, in: recentTickets, limit: Preferences.recentJustificationLimit)
        if let data = try? JSONEncoder().encode(recentTickets) { UserDefaults.standard.set(data, forKey: Keys.recentTickets) }
    }

    func clearRecentTickets() {
        recentTickets = []
        UserDefaults.standard.removeObject(forKey: Keys.recentTickets)
    }

    // MARK: Scheduling

    /// `Fri 08:00`, for the start menu and the results.
    func startLabel(_ date: Date) -> String { ScheduleTime.label(date, now: Date()) }

    func setStart(_ date: Date?) {
        scheduleStart = date
        if let date {
            do { try ScheduleTime.validate(date, now: Date()) } catch {
                banner = Banner(kind: .error, text: error.localizedDescription)
            }
        }
    }

    func openStartPicker() {
        startPickerDraft = scheduleStart ?? ScheduleTime.Preset.tomorrowMorning.date(now: Date())
        showStartPicker = true
    }

    /// The latest start PIM accepts, for the date picker.
    var latestStart: Date { Date().addingTimeInterval(TimeInterval(ScheduleTime.maxDaysAhead) * 86400) }

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
        let service = service
        do {
            let (identity, requests) = try await service.loadScheduledRequests()
            guard generation == tenantGeneration else { return }
            scheduledRequests = requests
            scheduledLoadState = .loaded
            Notifier.syncScheduledStarts(requests, tenantId: identity.tenantId ?? effectiveTenantId, prefs: prefs)
        } catch {
            guard generation == tenantGeneration else { return }
            scheduledLoadState = .failed(message: error.localizedDescription, needsLogin: (error as? AzureCLIError)?.needsLogin ?? false)
        }
    }

    func openScheduled() {
        cancelResults = [:]
        showScheduled = true
        Task { await loadScheduled() }
    }

    /// Cancels `requests` (POST …/cancel), then reads the list again.
    func cancelScheduled(_ requests: [ScheduledRequest]) async {
        let targets = requests.filter { !cancelling.contains($0.name) }
        guard !targets.isEmpty else { return }
        for r in targets {
            cancelling.insert(r.name)
            cancelResults[r.name] = nil
        }
        do {
            try await service.cancel(targets) { r, outcome in
                await MainActor.run {
                    self.cancelling.remove(r.name)
                    self.cancelResults[r.name] = outcome
                }
            }
        } catch {
            for r in targets { cancelResults[r.name] = .failed(code: "Auth", message: error.localizedDescription) }
        }
        for r in targets { cancelling.remove(r.name) }
        let done = targets.filter { cancelResults[$0.name] == .canceled }.count
        let failed = targets.count - done
        banner = Banner(kind: failed > 0 ? .error : .success,
                        text: "\(done) scheduled activation\(done == 1 ? "" : "s") cancelled" + (failed > 0 ? ", \(failed) failed." : "."))
        await loadScheduled()
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
        let service = service
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
        let service = service
        do {
            let snapshot = try await service.loadRoles()
            // A tenant switch while loading makes this result stale.
            guard generation == tenantGeneration else { return }
            identity = snapshot.identity
            roles = applyPending(to: snapshot.roles)
            // Drop selections that changed state or disappeared.
            checked.formIntersection(Set(roles.filter { !$0.isActive }.map(\.id)))
            checkedActive.formIntersection(Set(roles.filter(\.isActive).map(\.id)))
            lastRefreshed = Date()
            loadState = .loaded
            reloadPresets()
            loadPolicies(retryFailures: true)
            Task { await loadScheduled() }
        } catch let error as AzureCLIError {
            guard generation == tenantGeneration else { return }
            loadState = .failed(message: error.localizedDescription, needsLogin: error.needsLogin)
        } catch {
            guard generation == tenantGeneration else { return }
            loadState = .failed(message: error.localizedDescription, needsLogin: false)
        }
    }

    /// Shows rows this app just changed the way they will be until Azure
    /// lists them so, and forgets those Azure agrees with (or that are stale).
    private func applyPending(to fresh: [EligibleRole]) -> [EligibleRole] {
        let now = Date()
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
        if let tenants = try? await TenantDirectory.load(preferredTenant: tenant.tenantId), !tenants.isEmpty {
            knownTenants = tenants
        }
    }

    func setHidden(_ tenant: TenantInfo, _ hidden: Bool) {
        if hidden { hiddenTenantIds.insert(tenant.id) } else { hiddenTenantIds.remove(tenant.id) }
        UserDefaults.standard.set(hiddenTenantIds.sorted(), forKey: Keys.hiddenTenants)
    }

    func unhideAllTenants() {
        hiddenTenantIds = []
        showHiddenTenants = false
        UserDefaults.standard.removeObject(forKey: Keys.hiddenTenants)
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
            UserDefaults.standard.set(id, forKey: Keys.tenant)
            tenant = TenantSelection(tenantId: id, source: .saved)
        } else {
            UserDefaults.standard.removeObject(forKey: Keys.tenant)
            tenant = TenantSelection(tenantId: nil, source: .azDefault)
        }
        service = PIMService(tokens: AzureCLITokenProvider(tenantId: tenant.tenantId))
        tenantGeneration += 1
        roles = []
        identity = nil
        checked = []
        checkedActive = []
        policies = [:]
        policyTask = nil
        scheduledRequests = []
        scheduledLoadState = .idle
        cancelResults = [:]
        progress = [:]
        pending = [:]
        banner = nil
        lastRefreshed = nil
        loadState = .idle
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
        let roles = checkedRoles
        let now = Date()
        if let start = scheduleStart { try ScheduleTime.validate(start, now: now) }
        await ensurePolicies(for: roles)
        let needTicket = TicketRequirement.missing(roles, ticket: currentTicket) { self.policies[$0.policyKey] }
        if !needTicket.isEmpty {
            showTicketFields = true
            throw TicketMissing(roles: needTicket)
        }
        return try ActivationRequestBuilder.plan(
            roles, principalId: identity.objectId, justification: justification, now: now,
            start: scheduleStart, ticket: currentTicket
        ) {
            self.effectiveDuration(for: $0)
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
        let planned: [PlannedRequest]
        do { planned = try await plans() } catch {
            banner = Banner(kind: .error, text: error.localizedDescription)
            return
        }
        isActivating = true
        banner = nil
        rememberJustification(trimmedJustification)
        rememberTicket(currentTicket)
        let scheduling = scheduleStart != nil
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
        let ok = outcomes.filter { if case .activated = $0 { return true }; return false }.count
        let scheduledStarts = outcomes.compactMap { o -> Date? in if case .scheduled(_, let start, _) = o { return start }; return nil }
        let skipped = outcomes.filter { $0 == .alreadyActive }.count
        let failed = outcomes.filter(\.isFailure).count
        if scheduledStarts.isEmpty {
            banner = Banner(kind: failed > 0 ? .error : .success, text: "\(ok) activated, \(skipped) skipped, \(failed) failed.")
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
        // Back to "now" once everything was scheduled, so the next batch is not scheduled by accident.
        if scheduling, failed == 0 { scheduleStart = nil }
        isActivating = false
        Notifier.operationFinished(
            roles: planned.map(\.role), outcomes: finishedOutcomes, operation: .activate,
            context: reminderContext(justification: trimmedJustification), prefs: prefs)
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
    private func reminderContext(justification: String) -> Notifier.ReminderContext {
        Notifier.ReminderContext(
            tenantId: effectiveTenantId,
            // Kept only when the user keeps recent justifications.
            justification: prefs.rememberJustifications && !justification.isEmpty ? justification : nil,
            duration: duration)
    }

    /// Refreshes now and again shortly: ARM lists a change only after a few
    /// seconds, and the status should come from Azure, not from the overlay.
    private func refreshAfterChange() async {
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
        RoleLifecycle.select(lifecycleTargets, now: Date(), forRenewal: forRenewal) {
            self.policies[$0.policyKey]?.policy?.requiresApproval == true
        }
    }

    /// Ends the activations of `roles` (SelfDeactivate).
    func deactivate(_ targets: [EligibleRole]) async {
        guard !isActivating, let identity else { return }
        let selection = RoleLifecycle.select(targets, now: Date())
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
        let now = Date()
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
        await ensurePolicies(for: targets)
        let requested = asked ?? duration
        let selection = RoleLifecycle.select(targets, now: Date(), forRenewal: true) {
            self.policies[$0.policyKey]?.policy?.requiresApproval == true
        }
        let plans: [RenewPlan]
        do {
            plans = try ActivationRequestBuilder.renewPlan(selection.ready, principalId: identity.objectId, justification: justification) {
                EffectiveDuration.resolve(requested, policyMaxMinutes: self.policies[$0.policyKey]?.maxMinutes,
                                          fallbackHours: self.prefs.defaultHours)
            }
        } catch {
            banner = Banner(kind: .error, text: error.localizedDescription)
            return
        }
        isActivating = true
        banner = nil
        rememberJustification(justification)
        for role in selection.tooSoon {
            progress[role.id] = .done(.tooSoon(possibleAt: RoleLifecycle.earliestDeactivation(of: role)))
        }
        for role in selection.needsApproval {
            progress[role.id] = .done(.failed(code: "ApprovalRequired",
                                              message: "Its policy requires approval: after ending it you would wait for an approver. Not renewed."))
        }
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
        let now = Date()
        for plan in plans {
            guard case .done(let outcome) = progress[plan.id] else { continue }
            switch outcome {
            case .renewed(let until):
                renewed.append(plan.role)
                for row in self.roles(sharing: plan.role) { pending[row.id] = .active(until: until, since: now) }
            case .failed(let code, _) where code == "ReactivationFailed":
                lost.append(plan.role)
                checkedActive.remove(plan.id)
                for row in self.roles(sharing: plan.role) { pending[row.id] = .inactive(since: now) }
            default:
                break
            }
        }
        let outcomes = finishedOutcomes
        let all = selection.tooSoon + selection.needsApproval + plans.map(\.role)
        let failed = all.filter { outcomes[$0.id]?.isFailure == true }
        var text = lifecycleBanner(done: renewed.count, verb: "renewed", failed: failed, outcomes: outcomes)
        if !lost.isEmpty { text += " \(lost.count) ended but not active again: activate \(lost.count == 1 ? "it" : "them") again." }
        banner = Banner(kind: failed.isEmpty ? .success : .error, text: text)
        isActivating = false
        roles = applyPending(to: roles)
        // The old reminders are for the old expiry; renewed roles get new ones.
        Notifier.rolesEnded(Set((renewed + lost).map { ReminderRole.key($0.policyKey) }))
        Notifier.operationFinished(roles: all, outcomes: outcomes, operation: .renew,
                                   context: reminderContext(justification: justification), prefs: prefs)
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
        guard payload.isTenant(effectiveTenantId) else {
            NSApp.activate(ignoringOtherApps: true)
            banner = Banner(kind: .error, text: "That reminder is for tenant \(payload.tenantId ?? "?"). Switch to it, then renew or end the roles here.")
            return
        }
        while isActivating { try? await Task.sleep(for: .milliseconds(300)) }
        await refresh()
        let targets = payload.matchingActive(in: roles)
        guard !targets.isEmpty else {
            if action == .renew { NSApp.activate(ignoringOtherApps: true) }
            banner = Banner(kind: .info, text: "The roles in that reminder are no longer active.")
            Notifier.rolesEnded(Set(payload.roles.map(\.key)))
            return
        }
        switch action {
        case .end:
            await deactivate(targets)
        case .renew:
            checkedActive = Set(targets.map(\.id))
            if let d = payload.duration { duration = d }
            if let text = payload.justification { justification = text }
            let owners = targets.contains(where: \.isOwner) && prefs.confirmOwnerRoles
            if trimmedJustification.isEmpty || owners {
                // Needs the user: a justification, or the Owner confirmation.
                NSApp.activate(ignoringOtherApps: true)
                requestRenewal(targets)
            } else {
                await renew(targets, justification: trimmedJustification, duration: payload.duration)
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

    // MARK: Settings

    private func preferencesChanged(from old: Preferences) {
        let valid = prefs.validated()
        guard valid == prefs else {
            prefs = valid  // re-enters with a valid value
            return
        }
        guard prefs != old else { return }
        prefs.save(to: UserDefaults.standard)
        if prefs.effectiveAppearance != old.effectiveAppearance { AppAppearance.apply(prefs) }
        if prefs.defaultHours != old.defaultHours, !isActivating { duration = .hours(prefs.defaultHours) }
        if prefs.autoRefreshMinutes != old.autoRefreshMinutes { restartAutoRefresh() }
        if !prefs.rememberJustifications, old.rememberJustifications {
            clearRecentJustifications()
            clearRecentTickets()
        }
        if prefs.notifyScheduledStart != old.notifyScheduledStart {
            Notifier.syncScheduledStarts(scheduledRequests, tenantId: identity?.tenantId ?? effectiveTenantId, prefs: prefs)
        }
        if !prefs.expiryReminders, old.expiryReminders {
            Notifier.cancelReminders()
        } else if prefs.expiryReminders, prefs.reminderLeadMinutes != old.reminderLeadMinutes {
            Notifier.rescheduleReminders(lead: prefs.reminderLead)
        }
    }

    /// Back to the defaults. Hidden tenants and the remembered tenant stay.
    func resetPreferences() {
        prefs = Preferences()
        columnCustomization = TableColumnCustomization()
        // After the assignments, whose didSet saves: no stored value pins
        // today's defaults, so future defaults apply.
        Preferences.reset(in: UserDefaults.standard)
        UserDefaults.standard.removeObject(forKey: Keys.tableColumns)
    }

    private func rememberJustification(_ text: String) {
        guard prefs.rememberJustifications else { return }
        recentJustifications = Preferences.recording(text, in: recentJustifications)
        UserDefaults.standard.set(recentJustifications, forKey: Keys.recentJustifications)
    }

    func clearRecentJustifications() {
        recentJustifications = []
        UserDefaults.standard.removeObject(forKey: Keys.recentJustifications)
    }

    func isColumnVisible(_ column: Column) -> Bool {
        columnCustomization[visibility: column.rawValue] != .hidden
    }

    func setColumn(_ column: Column, visible: Bool) {
        columnCustomization[visibility: column.rawValue] = visible ? .visible : .hidden
    }

    private func saveColumnCustomization() {
        if let data = try? JSONEncoder().encode(columnCustomization) {
            UserDefaults.standard.set(data, forKey: Keys.tableColumns)
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
