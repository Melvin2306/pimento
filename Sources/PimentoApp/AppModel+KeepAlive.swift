import AppKit
import Foundation
import PimentoCore

// Keep alive in the app: which roles are kept alive (per role, or by a preset
// with keep-alive on), the passes of `KeepAliveSession` (its rules are in
// `KeepAlive`), their timer, and what the views show. A pass reads your roles
// and requests, sends what is due and refreshes; it runs at the moment the
// last one named, after a refresh that changed a kept role, on wake and
// after a clock change.

extension AppModel {
    /// The longest wait between passes while roles are kept alive.
    static let keepAliveMaxIdle: TimeInterval = 30 * 60

    // MARK: State

    /// The key in `keepAliveRolesByTenant` and `keepAliveConfirmedByTenant`:
    /// the tenant and the signed-in account (`tenant/objectId`), so that
    /// another account in the same tenant inherits neither the marks nor the
    /// confirmations.
    var keepAliveTenantKey: String {
        let tenantKey = (identity?.tenantId ?? tenant.tenantId ?? "default").lowercased()
        guard let user = identity?.objectId.lowercased(), !user.isEmpty else { return tenantKey }
        return "\(tenantKey)/\(user)"
    }

    /// Roles kept alive one by one in this tenant (role keys).
    var keptRoleKeys: Set<String> { keepAliveRolesByTenant[keepAliveTenantKey] ?? [] }

    /// How `role` is kept alive, if it is.
    func keepAliveRule(for role: EligibleRole) -> KeepAliveRule? { keepAliveRules[ReminderRole.key(role.policyKey)] }

    /// Where `role` stands, once a pass has looked at it.
    func keepAliveStatus(for role: EligibleRole) -> KeepAliveStatus? { keepAliveItems[ReminderRole.key(role.policyKey)]?.status }

    /// Roles kept alive in this tenant, one row per scope + role (direct first).
    var keptRoles: [EligibleRole] {
        var seen = Set<String>()
        return roles.sorted { ($0.membership == .direct ? 0 : 1) < ($1.membership == .direct ? 0 : 1) }
            .filter { keepAliveRules[ReminderRole.key($0.policyKey)] != nil && seen.insert(ReminderRole.key($0.policyKey)).inserted }
            .sorted { ($0.roleName, $0.scopeName) < ($1.roleName, $1.scopeName) }
    }

    /// One line for tooltips, the toolbar menu and the menu bar.
    func keepAliveText(for role: EligibleRole) -> String {
        guard let rule = keepAliveRule(for: role) else { return "Not kept alive" }
        let by = rule.preset.map { " (preset \($0))" } ?? ""
        if prefs.keepAlivePaused { return "Kept alive\(by): paused" }
        guard let status = keepAliveStatus(for: role) else { return "Kept alive\(by)" }
        return "Kept alive\(by): \(status.summary(now: AppClock.now()))"
    }

    /// Whether the role cannot be kept alive (approval, unreadable policy),
    /// from the policy read for the table.
    func keepAliveImpossible(_ role: EligibleRole) -> String? {
        switch policies[role.policyKey] {
        case .loaded(let p)? where p.requiresApproval: "its policy requires approval"
        case .failed?, .notFound?: "its policy could not be read"
        default: nil
        }
    }

    static func loadKeepAliveRoles(from defaults: UserDefaults, key: String) -> [String: Set<String>] {
        guard let stored = defaults.dictionary(forKey: key) as? [String: [String]] else { return [:] }
        return stored.mapValues(Set.init)
    }

    private func saveKeepAliveRoles() {
        AppRuntime.defaults.set(keepAliveRolesByTenant.mapValues { $0.sorted() }, forKey: Keys.keepAliveRoles)
        AppRuntime.defaults.set(keepAliveConfirmedByTenant.mapValues { $0.sorted() }, forKey: Keys.keepAliveConfirmed)
    }

    // MARK: Confirmation (access-granting roles)

    /// Access-granting roles confirmed in this tenant; nil when the Owner
    /// confirmation is off (then none is needed).
    var keepAliveConfirmedAccess: Set<String>? {
        prefs.confirmOwnerRoles ? keepAliveConfirmedByTenant[keepAliveTenantKey] ?? [] : nil
    }

    /// Access-granting roles among `roles` whose keep-alive needs your confirmation first.
    func keepAliveNeedingConsent(_ roles: [EligibleRole]) -> [EligibleRole] {
        KeepAliveConsent.needingConfirmation(roles, confirmed: keepAliveConfirmedByTenant[keepAliveTenantKey] ?? [],
                                             enabled: prefs.confirmOwnerRoles)
    }

    /// The confirmation was accepted: remember the roles, then mark or save.
    func confirmKeepAliveConsent() {
        guard let request = keepAliveConsent else { return }
        keepAliveConsent = nil
        var confirmed = keepAliveConfirmedByTenant[keepAliveTenantKey] ?? []
        confirmed.formUnion(KeepAliveConsent.accessKeys(request.roles))
        keepAliveConfirmedByTenant[keepAliveTenantKey] = confirmed
        saveKeepAliveRoles()
        if request.preset != nil {
            saveDraftNow()
        } else {
            setKeepAlive(request.targets, on: true)
        }
    }

    /// Rules from the per-role marks and the presets with keep-alive on.
    func updateKeepAliveRules() {
        let rules = KeepAliveRule.resolve(perRole: keptRoleKeys, presets: visiblePresets, roles: roles)
        if rules != keepAliveRules { keepAliveRules = rules }
        keepAliveItems = keepAliveItems.filter { rules[$0.key] != nil }
    }

    /// A scheduled request that continues a kept role (its start is the role's end).
    func isKeepAliveContinuation(_ request: ScheduledRequest) -> Bool {
        let key = ReminderRole.key(request.policyKey)
        guard keepAliveRules[key] != nil else { return false }
        return roles.contains { r in
            r.policyKey == request.policyKey && (r.activeUntil.map { abs($0.timeIntervalSince(request.start)) <= KeepAlive.continuationSlack } ?? false)
        }
    }

    // MARK: Changes

    /// Turns keep-alive on or off for `targets` (per role). Off withdraws a
    /// continuation Pimento scheduled for them that has not started.
    func setKeepAlive(_ targets: [EligibleRole], on: Bool) {
        if on {
            let needing = keepAliveNeedingConsent(targets)
            if !needing.isEmpty {
                keepAliveConsent = KeepAliveConsentRequest(roles: needing, targets: targets, preset: nil)
                return
            }
        }
        let keys = Set(targets.map { ReminderRole.key($0.policyKey) })
        var set = keptRoleKeys
        if on { set.formUnion(keys) } else { set.subtract(keys) }
        keepAliveRolesByTenant[keepAliveTenantKey] = set.isEmpty ? nil : set
        saveKeepAliveRoles()
        updateKeepAliveRules()
        if !on {
            let byPreset = targets.filter { keepAliveRule(for: $0)?.preset != nil }
            if let p = byPreset.first.flatMap({ keepAliveRule(for: $0)?.preset }) {
                banner = Banner(kind: .info, text: "\(byPreset.count == 1 ? "That role is" : "Some of those roles are") still kept alive by the preset “\(p)”: "
                    + "turn it off under Manage Presets.")
            }
            let removed = keys.filter { keepAliveRules[$0] == nil }
            Task { await self.withdrawContinuations(of: removed) }
        } else {
            let excluded = targets.compactMap { role in keepAliveImpossible(role).map { "\(role.roleName) · \(role.scopeName): \($0)" } }
            if !excluded.isEmpty {
                banner = Banner(kind: .info, text: "Kept alive, but not renewed: " + excluded.joined(separator: "; ")
                    + ". A renewal would \(excluded.count == 1 ? "leave it" : "leave them") waiting for an approver.")
            }
        }
        scheduleKeepAlivePass(after: 1)
    }

    /// Pauses or resumes every keep-alive (Settings, menu bar, toolbar).
    func setKeepAlivePaused(_ paused: Bool) {
        prefs.keepAlivePaused = paused
    }

    func keepAliveSettingsChanged(from old: Preferences) {
        if prefs.keepAlivePaused, !old.keepAlivePaused {
            keepAliveTimer?.invalidate()
            keepAliveTimer = nil
            Task {
                let withdraw = await keepAliveSession.pause(now: AppClock.now())
                _ = await KeepAliveSession.withdraw(Array(withdraw.values), writer: service)
                await runKeepAlivePass()
            }
        } else {
            scheduleKeepAlivePass(after: 1)
        }
    }

    func keepAlivePresetsChanged() {
        let before = keepAliveRules
        updateKeepAliveRules()
        guard keepAliveRules != before else { return }
        let removed = Set(before.keys).subtracting(keepAliveRules.keys)
        if !removed.isEmpty { Task { await self.withdrawContinuations(of: removed) } }
        scheduleKeepAlivePass(after: 1)
    }

    private func withdrawContinuations(of keys: Set<String>) async {
        let now = AppClock.now()
        var withdraw: [KeepAliveTrack.HandOver] = []
        for key in keys {
            if let h = await keepAliveSession.remove(key, now: now) { withdraw.append(h) }
        }
        guard !withdraw.isEmpty else { return }
        let outcomes = await KeepAliveSession.withdraw(withdraw, writer: service)
        let failed = outcomes.filter { outcome in
            if case .notCancellable = outcome { return false }  // already started
            return outcome.isFailure
        }.count
        banner = Banner(kind: failed > 0 ? .error : .info, text: failed > 0
            ? "Could not withdraw \(failed) scheduled continuation\(failed == 1 ? "" : "s"): see Scheduled to cancel."
            : "Withdrew \(withdraw.count) scheduled continuation\(withdraw.count == 1 ? "" : "s").")
        Task { await loadScheduled() }
    }

    /// After a refresh: re-resolve the rules, and run a pass when a kept
    /// role started, ended or changed its end since the last pass.
    func keepAliveAfterRefresh() {
        updateKeepAliveRules()
        guard !keepAliveRules.isEmpty else { return }
        let seen = keptRoles.reduce(into: [String: Date]()) { $0[ReminderRole.key($1.policyKey)] = $1.isActive ? ($1.activeUntil ?? .distantFuture) : .distantPast }
        if seen != keepAliveSeen || keepAliveItems.isEmpty { scheduleKeepAlivePass(after: 2) }
    }

    /// Wake, a clock or time-zone change: look again (a role may have lapsed).
    func keepAliveClockChanged() {
        guard !keepAliveRules.isEmpty else { return }
        // Give the network a moment after wake.
        scheduleKeepAlivePass(after: 10)
    }

    /// Another tenant or account: keep-alive starts over.
    func keepAliveReset() {
        keepAliveTimer?.invalidate()
        keepAliveTimer = nil
        keepAliveItems = [:]
        keepAliveRules = [:]
        keepAliveSeen = [:]
        keepAliveError = nil
        // A confirmation asked in the previous session is not answered in this one.
        keepAliveConsent = nil
        Task { await keepAliveSession.reset() }
    }

    // MARK: Passes

    /// Runs a pass after `seconds` (real time), replacing a later one.
    func scheduleKeepAlivePass(after seconds: TimeInterval) {
        scheduleKeepAlivePass(atReal: Date().addingTimeInterval(seconds))
    }

    private func scheduleKeepAlivePass(atReal fire: Date) {
        if let timer = keepAliveTimer, timer.isValid, timer.fireDate <= fire { return }
        keepAliveTimer?.invalidate()
        let timer = Timer(fire: fire, interval: 0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.keepAliveTimer = nil
                Task { await self.runKeepAlivePass() }
            }
        }
        timer.tolerance = 2
        RunLoop.main.add(timer, forMode: .common)
        keepAliveTimer = timer
    }

    /// One pass: read, send what is due, tell the user, plan the next one.
    func runKeepAlivePass() async {
        // One at a time; one asked for meanwhile (a change, a pause) runs after it.
        guard !keepAliveRunning else {
            scheduleKeepAlivePass(after: 5)
            return
        }
        updateKeepAliveRules()
        guard tenantError == nil, identity != nil, !keepAliveRules.isEmpty else {
            keepAliveItems = [:]
            return
        }
        // Not in the middle of the user's own activation or renewal.
        guard !isActivating else {
            scheduleKeepAlivePass(after: 30)
            return
        }
        keepAliveRunning = true
        defer { keepAliveRunning = false }
        let generation = tenantGeneration
        let session = keepAliveSession, service = service
        let perRole = keptRoleKeys, presets = visiblePresets, hours = prefs.keepAliveHours, paused = prefs.keepAlivePaused
        let confirmed = keepAliveConfirmedAccess
        do {
            let result = try await session.pass(
                reader: service.readOnly, writer: service, perRole: perRole, presets: presets, hours: hours, paused: paused,
                calendar: .autoupdatingCurrent, clock: { AppClock.now() }, maxConcurrent: min(4, prefs.maxParallelRequests),
                confirmedAccess: confirmed)
            guard generation == tenantGeneration else { return }
            keepAliveError = nil
            keepAliveItems = Dictionary(result.items.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
            keepAliveSeen = result.items.reduce(into: [String: Date]()) {
                $0[$1.key] = $1.role.isActive ? ($1.role.activeUntil ?? .distantFuture) : .distantPast
            }
            announce(result.events)
            let next = result.nextCheck.map { min($0, AppClock.now().addingTimeInterval(Self.keepAliveMaxIdle)) }
                ?? AppClock.now().addingTimeInterval(Self.keepAliveMaxIdle)
            if !paused, let fire = AppClock.realDate(for: next) { scheduleKeepAlivePass(atReal: max(fire, Date().addingTimeInterval(5))) }
            if !result.actions.isEmpty { await refreshAfterChange() }
        } catch is KeepAliveSessionReset {
            // Overtaken by a reset (another tenant or account): start over soon.
            guard generation == tenantGeneration else { return }
            scheduleKeepAlivePass(after: 5)
        } catch {
            guard generation == tenantGeneration else { return }
            keepAliveError = error.localizedDescription
            scheduleKeepAlivePass(after: 5 * 60)
        }
    }

    /// Notifications (as the settings say) and the reminders of renewed roles.
    private func announce(_ events: [KeepAliveEvent]) {
        guard !events.isEmpty else { return }
        Notifier.keepAlive(events, prefs: prefs)
        let renewed = events.compactMap { e -> (EligibleRole, Date, Bool)? in
            if case .renewed(let role, _, let until, let clipped, _) = e { return (role, until, clipped) }
            return nil
        }
        guard !renewed.isEmpty else { return }
        // The old end no longer applies; the last renewal of the day gets a reminder for its end.
        Notifier.rolesEnded(Set(renewed.map { ReminderRole.key($0.0.policyKey) }))
        let last = renewed.filter(\.2)
        if !last.isEmpty {
            Notifier.scheduleReminders(
                roles: last.map(\.0), outcomes: Dictionary(last.map { ($0.0.id, ActivationOutcome.renewed(until: $0.1)) }, uniquingKeysWith: { a, _ in a }),
                context: Notifier.ReminderContext(tenantId: identity?.tenantId ?? tenant.tenantId, principalId: identity?.objectId), prefs: prefs)
        }
        let failed = events.filter(\.isFailure)
        if let f = failed.first {
            banner = Banner(kind: .error, text: "Keep alive: " + f.notice(now: AppClock.now()).body)
        }
    }
}

/// Keeping access-granting roles alive asks first (with *Confirm before
/// activating Owner roles* on): `roles` need it; `targets` are marked once
/// confirmed, or the preset draft is saved.
struct KeepAliveConsentRequest: Equatable {
    let roles: [EligibleRole]
    let targets: [EligibleRole]
    /// The preset whose keep-alive toggle asks (nil: roles marked in the table).
    let preset: String?

    var title: String {
        preset.map { "Keep the roles of “\($0)” alive, including roles that can grant access?" }
            ?? (roles.count == 1 ? "Keep \(roles[0].roleName) alive?" : "Keep \(roles.count) roles that can grant access alive?")
    }

    var message: String { KeepAliveConsent.message(roles) }
}
