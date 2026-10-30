import AppKit
import Foundation
import PimentoCore
import ServiceManagement

/// What the menu bar popover asks before it acts: the same confirmations as
/// the main window (texts in `ConfirmationText.swift`), shown inline.
enum MenuBarPrompt: Equatable {
    /// End `lifecycleTargets` now.
    case end
    /// End and activate again `lifecycleTargets`.
    case renew
    /// The preset has no justification and none is typed in: ask for one.
    case presetJustification(Preset)
    /// The preset's roles include Owner roles (with the Owner confirmation on).
    case owner(Preset)
}

// MARK: - Menu bar actions

extension AppModel {
    /// Active roles for the menu bar, soonest end first.
    func menuBarEntries(now: Date) -> [MenuBarStatus.Entry] { MenuBarStatus.entries(roles, now: now) }

    /// The popover opened: the first load if nothing was loaded yet (refresh
    /// policy otherwise as in the window), and the presets file again (the
    /// CLI may have changed it).
    func menuBarOpened() {
        reloadPresets()
        if loadState == .idle, !awaitingManualRefresh, tenantError == nil { Task { await refresh() } }
    }

    /// Renew or End Now on a row of the popover: asks first, like the window.
    func menuBarAsk(_ prompt: MenuBarPrompt, for role: EligibleRole) {
        guard !isActivating, identity != nil, role.isActive else { return }
        lifecycleTargets = [role]
        if prompt == .renew { loadPolicies(for: [role]) }
        menuBarPrompt = prompt
    }

    /// "Activate" on a preset in the popover: selects its roles (as the
    /// Presets menu does) and activates them now, after asking for a missing
    /// justification and, for Owner roles, the Owner confirmation.
    func menuBarActivatePreset(_ preset: Preset) {
        guard !isActivating, !roles.isEmpty else { return }
        menuBarPrompt = nil
        // The popover activates now; a start picked in the window is not
        // carried over silently.
        scheduleStart = nil
        let resolution = applyPreset(preset)
        if resolution.eligible.isEmpty {
            let why = resolution.roles.isEmpty ? "none of its roles are eligible" : "all of its roles are already active"
            banner = Banner(kind: resolution.missing.isEmpty ? .info : .error, text: "\(preset.name): nothing to activate, \(why).")
            return
        }
        guard !trimmedJustification.isEmpty else {
            menuBarPrompt = .presetJustification(preset)
            return
        }
        menuBarContinue(preset)
    }

    /// After the justification: the Owner confirmation, or activate.
    func menuBarContinue(_ preset: Preset) {
        guard !trimmedJustification.isEmpty, !checkedRoles.isEmpty else { return }
        if prefs.confirmOwnerRoles, !checkedOwnerRoles.isEmpty {
            menuBarPrompt = .owner(preset)
        } else {
            menuBarPrompt = nil
            Task { await activate() }
        }
    }

    /// The popover's confirm button.
    func menuBarConfirm() {
        guard let prompt = menuBarPrompt else { return }
        switch prompt {
        case .end:
            menuBarPrompt = nil
            let targets = lifecycleTargets
            Task { await deactivate(targets) }
        case .renew:
            guard !trimmedJustification.isEmpty else { return }
            menuBarPrompt = nil
            let targets = lifecycleTargets
            Task { await renew(targets) }
        case .presetJustification(let preset):
            menuBarContinue(preset)
        case .owner:
            menuBarPrompt = nil
            Task { await activate() }
        }
    }

    /// Whether the confirm button can be pressed.
    var menuBarCanConfirm: Bool {
        guard let prompt = menuBarPrompt, !isActivating else { return false }
        switch prompt {
        case .end: return !lifecycleSelection(forRenewal: false).ready.isEmpty
        case .renew: return !lifecycleSelection(forRenewal: true).ready.isEmpty && !trimmedJustification.isEmpty
        case .presetJustification: return !trimmedJustification.isEmpty
        case .owner: return !checkedRoles.isEmpty
        }
    }

    // MARK: Launch at login

    /// Reads the login item's state from the system (read-only).
    func updateLoginItemState() {
        loginItemState = LoginItemState(statusRawValue: SMAppService.mainApp.status.rawValue)
    }

    /// Registers or unregisters Pimento as a login item. Ad-hoc signed or
    /// unbundled copies may be refused: the reason is shown.
    func setLaunchAtLogin(_ on: Bool) {
        loginItemError = nil
        // The demo changes nothing on the system.
        guard !AppRuntime.isDemo else {
            loginItemError = "Not in demo mode: launch at login is a setting of your own Pimento."
            return
        }
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            let ns = error as NSError
            loginItemError = LoginItemState.failureMessage(
                code: ns.code, description: ns.localizedDescription, isAppBundle: Bundle.main.bundleURL.pathExtension == "app")
        }
        updateLoginItemState()
    }
}

// MARK: - Dock icon

/// Applies `AppPresence.activationPolicy`: a Dock icon and app menu, or the
/// menu bar only.
@MainActor
enum DockIcon {
    static func apply(_ prefs: Preferences, reactivate: Bool, atLaunch: Bool = false) {
        // Render harnesses run with `.prohibited`: never give them a Dock icon.
        // (A bare executable starts with it too, hence `atLaunch`.)
        guard atLaunch || NSApp.activationPolicy() != .prohibited else { return }
        let policy: NSApplication.ActivationPolicy = AppPresence.activationPolicy(prefs) == .accessory ? .accessory : .regular
        guard NSApp.activationPolicy() != policy else { return }
        NSApp.setActivationPolicy(policy)
        // Switching while Settings is open deactivates the app: bring it back.
        if reactivate { DispatchQueue.main.async { NSApp.activate(ignoringOtherApps: true) } }
    }
}
