import Foundation
import Observation
import PimentoCore
import SwiftUI

enum RowProgress: Equatable {
    case queued
    case running
    case done(ActivationOutcome)
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
    /// Rows activated from this app that Azure does not list as active yet:
    /// ARM takes a few seconds to show a new activation, so a refresh right
    /// after activating would still say "Eligible". Value: the expiry Azure
    /// returned, if any.
    private var pendingActive: [EligibleRole.ID: Date?] = [:]
    var isActivating = false
    var dryRunPlans: [PlannedRequest] = []
    var showDryRunSheet = false
    var showOwnerConfirmation = false
    var banner: Banner?

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
        return n == 0 ? "Activate" : "Activate \(n) \(noun)"
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
            roles = applyPendingActivations(to: snapshot.roles)
            // Drop selections that became active or disappeared.
            let selectable = Set(roles.filter { !$0.isActive }.map(\.id))
            checked.formIntersection(selectable)
            lastRefreshed = Date()
            loadState = .loaded
            reloadPresets()
            loadPolicies(retryFailures: true)
        } catch let error as AzureCLIError {
            guard generation == tenantGeneration else { return }
            loadState = .failed(message: error.localizedDescription, needsLogin: error.needsLogin)
        } catch {
            guard generation == tenantGeneration else { return }
            loadState = .failed(message: error.localizedDescription, needsLogin: false)
        }
    }

    /// Shows rows this app just activated as active until Azure lists them,
    /// and forgets those Azure now reports (or whose expiry has passed).
    private func applyPendingActivations(to fresh: [EligibleRole]) -> [EligibleRole] {
        let now = Date()
        return fresh.map { role in
            guard let until = pendingActive[role.id] else { return role }
            if role.isActive || (until.map { $0 <= now } ?? false) {
                pendingActive[role.id] = nil
                return role
            }
            var shown = role
            shown.isActive = true
            shown.activeUntil = until
            return shown
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
        policies = [:]
        policyTask = nil
        progress = [:]
        pendingActive = [:]
        banner = nil
        lastRefreshed = nil
        loadState = .idle
        Task { await refresh() }
    }

    func isSelectedTenant(_ id: String?) -> Bool {
        guard let id else { return tenant.tenantId == nil }
        return tenant.tenantId?.caseInsensitiveCompare(id) == .orderedSame
    }

    func isChecked(_ role: EligibleRole) -> Bool { checked.contains(role.id) }

    func setChecked(_ role: EligibleRole, _ on: Bool) {
        guard !role.isActive else { return }
        if on { checked.insert(role.id) } else { checked.remove(role.id) }
    }

    /// Checks every not-yet-active row that matches the current search.
    func selectAllEligible() {
        for role in visibleRoles where !role.isActive { checked.insert(role.id) }
    }

    func clearSelection() { checked.removeAll() }

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

    /// One request per checked role, each capped at its policy maximum.
    private func plans() async throws -> [PlannedRequest] {
        guard let identity else { throw ActivationRequestError.missingPrincipal }
        let roles = checkedRoles
        await ensurePolicies(for: roles)
        return try ActivationRequestBuilder.plan(roles, principalId: identity.objectId, justification: justification) {
            self.effectiveDuration(for: $0)
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
        for plan in planned { progress[plan.id] = .queued }
        do {
            try await service.execute(
                planned,
                maxConcurrent: prefs.maxParallelRequests,
                onStart: { plan in await MainActor.run { self.progress[plan.id] = .running } },
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
        let skipped = outcomes.filter { $0 == .alreadyActive }.count
        let failed = outcomes.filter(\.isFailure).count
        banner = Banner(kind: failed > 0 ? .error : .success, text: "\(ok) activated, \(skipped) skipped, \(failed) failed.")
        // Activated and already-active rows are done: show them as active
        // right away and take them out of the selection.
        for plan in planned {
            guard case .done(let outcome) = progress[plan.id] else { continue }
            switch outcome {
            case .activated(_, let until):
                pendingActive[plan.id] = until
                checked.remove(plan.id)
            case .alreadyActive:
                checked.remove(plan.id)
            default:
                break
            }
        }
        isActivating = false
        Notifier.activationsFinished(planned: planned, outcomes: progress.compactMapValues { p -> ActivationOutcome? in
            if case .done(let o) = p { return o }
            return nil
        }, prefs: prefs)
        await refresh()
        // ARM lists a new activation only after a few seconds; check again so
        // the status comes from Azure rather than from the pending overlay.
        if !pendingActive.isEmpty {
            let generation = tenantGeneration
            Task {
                try? await Task.sleep(for: .seconds(20))
                guard generation == self.tenantGeneration else { return }
                await self.refresh()
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
        if !prefs.rememberJustifications, old.rememberJustifications { clearRecentJustifications() }
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
