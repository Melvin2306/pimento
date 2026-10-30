import AppKit
import PimentoCore
import SwiftUI

/// The Settings window (⌘,): a toolbar tab per pane, each pane two columns
/// of grouped options. Every change is saved and applied right away.
struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        TabView(selection: $model.settingsTab) {
            ForEach(SettingsPane.allCases, id: \.self) { pane in
                SettingsPaneView(tab: pane)
                    .tabItem { Label(pane.title, systemImage: pane.symbolName) }
                    .tag(pane)
            }
        }
        .themedSettingsToolbar()
    }
}

/// One pane of the Settings window.
struct SettingsPaneView: View {
    let tab: SettingsPane

    var body: some View {
        switch tab {
        case .general: GeneralSettings()
        case .appearance: AppearanceSettings()
        case .account: AccountSettings()
        case .activation: ActivationSettings()
        case .notifications: NotificationSettings()
        case .history: HistorySettingsView()
        }
    }
}

// MARK: - General

private struct GeneralSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        SettingsPaneContainer {
            SettingsColumns(leadingLabelWidth: 108) {
                SettingsGroup("Tenant") {
                    SettingsRow("Open with") {
                        Picker("Open with", selection: launchTenant) {
                            Text("Last used tenant").tag("lastUsed")
                            Text("az's current tenant").tag("azDefault")
                            if !tenantChoices.isEmpty {
                                Divider()
                                ForEach(tenantChoices, id: \.id) { choice in
                                    Text(choice.label).tag(choice.id)
                                }
                            }
                        }
                        .labelsHidden()
                        .frame(maxWidth: 220)
                        if model.tenant.isOverride {
                            SettingsNote("This launch uses \(model.tenant.source == .commandLine ? "--tenant" : TenantResolver.environmentVariable), which takes precedence.")
                        }
                    }
                    SettingsRow("Hidden tenants") {
                        HStack(spacing: 8) {
                            Text(model.hiddenTenantIds.isEmpty ? "None" : "\(model.hiddenTenantIds.count)")
                                .foregroundStyle(.secondary)
                            Button("Show All") { model.unhideAllTenants() }
                                .disabled(model.hiddenTenantIds.isEmpty)
                            InfoButton("Hide tenants you never use from the tenant picker (⇧⌘T) by hovering over them.",
                                       label: "About hidden tenants")
                        }
                    }
                }
                SettingsGroup("Refresh") {
                    SettingsRow {
                        Toggle("Load roles on launch", isOn: $model.prefs.refreshOnLaunch)
                    }
                    SettingsRow("Automatically") {
                        Picker("Refresh automatically", selection: $model.prefs.autoRefreshMinutes) {
                            ForEach(Preferences.autoRefreshOptions, id: \.self) { minutes in
                                Text(SettingsText.autoRefresh(minutes: minutes)).tag(minutes)
                            }
                        }
                        .labelsHidden()
                        .fixedSize()
                    }
                }
            } trailing: {
                SettingsGroup("Menu bar") {
                    Toggle("Show in menu bar", isOn: $model.prefs.showInMenuBar)
                        .help("A menu bar icon with your active roles, their countdown, Renew, End Now and presets")
                    Group {
                        Toggle("Show remaining time in menu bar", isOn: $model.prefs.menuBarShowsRemainingTime)
                            .help("The soonest end next to the icon, like 2 · 1:24, not only the number of active roles")
                        Toggle("Hide Dock icon (menu bar only)", isOn: $model.prefs.hideDockIcon)
                            .help("No Dock icon and no app menu; open windows from the menu bar icon")
                    }
                    .disabled(!model.prefs.showInMenuBar)
                    .settingsIndent()
                    Toggle("Launch at login", isOn: Binding(
                        get: { model.loginItemState.isOn },
                        set: { model.setLaunchAtLogin($0) }))
                        .help("Open Pimento when you log in (System Settings › General › Login Items)")
                    if let error = model.loginItemError {
                        SettingsNote(error, kind: .error).settingsIndent()
                    } else if let caption = model.loginItemState.caption {
                        SettingsNote(caption).settingsIndent()
                    }
                    SettingsNote(SettingsText.menuBarStatus(showInMenuBar: model.prefs.showInMenuBar,
                                                            hideDockIcon: model.prefs.hideDockIcon))
                }
            }

            HStack {
                SettingsNote("Changes apply right away.")
                Spacer()
                Button("Reset All Settings to Defaults…") { model.showResetConfirmation = true }
            }
            .padding(.top, 2)
        }
        .onAppear { model.updateLoginItemState() }
        .confirmationDialog("Reset all settings?", isPresented: $model.showResetConfirmation) {
            Button("Reset", role: .destructive) { model.resetPreferences() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Notifications, activation defaults, refresh, menu bar, appearance and columns go back to their defaults. "
                + "Hidden tenants and recent justifications are kept.")
        }
    }

    /// Known tenants plus a saved one az no longer lists.
    private var tenantChoices: [(id: String, label: String)] {
        var choices = model.knownTenants.map { (id: $0.id, label: $0.label) }
        if case .specific(let id) = model.prefs.launchTenant,
           !choices.contains(where: { $0.id.caseInsensitiveCompare(id) == .orderedSame }) {
            choices.append((id: id, label: id))
        }
        return choices
    }

    private var launchTenant: Binding<String> {
        Binding(
            get: {
                switch model.prefs.launchTenant {
                case .lastUsed: "lastUsed"
                case .azDefault: "azDefault"
                case .specific(let id): model.knownTenant(id)?.id ?? id
                }
            },
            set: { value in
                model.prefs.launchTenant = switch value {
                case "lastUsed": .lastUsed
                case "azDefault": .azDefault
                default: .specific(value)
                }
            })
    }
}

// MARK: - Activation

private struct ActivationSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        SettingsPaneContainer {
            SettingsColumns(leadingLabelWidth: 112) {
                SettingsGroup("Defaults") {
                    SettingsRow("Default duration") {
                        Picker("Default duration", selection: $model.prefs.defaultHours) {
                            ForEach(Preferences.hoursRange, id: \.self) { h in Text("\(h) h").tag(h) }
                        }
                        .labelsHidden()
                        .fixedSize()
                    }
                    SettingsRow("Parallel requests") {
                        HStack(spacing: 6) {
                            Stepper(value: $model.prefs.maxParallelRequests, in: Preferences.maxParallelRange) {
                                Text("\(model.prefs.maxParallelRequests)").monospacedDigit()
                            }
                            .accessibilityLabel("Parallel requests")
                            .accessibilityValue("\(model.prefs.maxParallelRequests)")
                            InfoButton("How many activation requests Pimento sends to Azure at once "
                                + "(\(Preferences.maxParallelRange.lowerBound) to \(Preferences.maxParallelRange.upperBound)).",
                                label: "About parallel requests")
                        }
                    }
                }
                SettingsGroup("Owner roles") {
                    Toggle("Confirm before activating Owner roles", isOn: $model.prefs.confirmOwnerRoles)
                    SettingsNote(SettingsText.ownerConfirmation(isOn: model.prefs.confirmOwnerRoles),
                                 kind: model.prefs.confirmOwnerRoles ? .info : .warning)
                        .settingsIndent()
                }
            } trailing: {
                SettingsGroup("Justification") {
                    Toggle("Remember recent justifications and tickets", isOn: $model.prefs.rememberJustifications)
                    Toggle("Start with the last justification filled in", isOn: $model.prefs.prefillLastJustification)
                        .disabled(!model.prefs.rememberJustifications)
                        .settingsIndent()
                    SettingsRow {
                        HStack(spacing: 8) {
                            Text("Remembered:")
                            Text(SettingsText.remembered(justifications: model.recentJustifications.count,
                                                         tickets: model.recentTickets.count))
                                .foregroundStyle(.secondary)
                            Button("Clear") {
                                model.clearRecentJustifications()
                                model.clearRecentTickets()
                            }
                            .disabled(model.recentJustifications.isEmpty && model.recentTickets.isEmpty)
                        }
                    }
                    SettingsRow {
                        HStack(spacing: 4) {
                            SettingsNote("Up to \(Preferences.recentJustificationLimit), stored on this Mac only.")
                                .fixedSize()
                            InfoButton("Pick one from the clock button next to the justification or ticket field.",
                                       label: "About recent justifications")
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Notifications

private func resultIsFailure(_ result: NotificationTestResult) -> Bool {
    if case .failed = result { true } else { false }
}

private struct NotificationSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        SettingsPaneContainer {
            SettingsColumns(leadingLabelWidth: 76) {
                SettingsGroup("Delivery") {
                    SettingsRow("Permission") {
                        HStack(spacing: 8) {
                            Text(model.notificationPermission.label)
                                .foregroundStyle(model.notificationPermission.needsSystemSettings ? Color.orange : .secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            if model.notificationPermission.needsSystemSettings {
                                Button("Open System Settings…") { Notifier.openSystemSettings() }
                            } else if model.notificationPermission == .notDetermined {
                                Button("Allow…") {
                                    Task {
                                        await Notifier.requestPermission()
                                        await model.updateNotificationPermission()
                                    }
                                }
                            }
                        }
                    }
                    SettingsRow("Test") {
                        HStack(spacing: 6) {
                            Button("Send Test Notification") {
                                Task { await model.sendTestNotification() }
                            }
                            .disabled(model.notificationPermission == .unavailable)
                            InfoButton("A Focus or Do Not Disturb mode can hide banners even when they are allowed; "
                                + "they still land in Notification Center. The banner style is under System Settings › "
                                + "Notifications › Pimento.", label: "About notification banners")
                        }
                        if let result = model.notificationTestResult {
                            Text(result.label())
                                .font(.caption)
                                .foregroundStyle(resultIsFailure(result) ? Color.orange : .secondary)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    SettingsRow("Sound") {
                        Toggle("Play sound", isOn: $model.prefs.playSound)
                    }
                }
                SettingsGroup("When activations finish") {
                    Toggle("Show a notification", isOn: $model.prefs.notifyOnCompletion)
                    Toggle("Only when something fails", isOn: $model.prefs.notifyOnlyOnFailure)
                        .disabled(!model.prefs.notifyOnCompletion)
                        .settingsIndent()
                }
            } trailing: {
                SettingsGroup("Reminders") {
                    Toggle("Remind me before roles expire", isOn: $model.prefs.expiryReminders)
                    HStack(spacing: 6) {
                        Picker("Remind me", selection: $model.prefs.reminderLeadMinutes) {
                            ForEach(Preferences.reminderLeadOptions, id: \.self) { m in
                                Text(SettingsText.reminderLead(minutes: m)).tag(m)
                            }
                        }
                        .labelsHidden()
                        .fixedSize()
                        .disabled(!model.prefs.expiryReminders)
                        InfoButton("Turning reminders off cancels the ones already scheduled; a new lead time moves them.",
                                   label: "About expiry reminders")
                    }
                    .settingsIndent()
                    HStack(spacing: 6) {
                        Toggle("Notify when a scheduled activation starts", isOn: $model.prefs.notifyScheduledStart)
                        InfoButton("At the start time, from this Mac, for the activations listed under Scheduled. Best-effort: "
                            + "it does not check that PIM activated the role. Turning it off removes the pending ones.",
                            label: "About scheduled activation notifications")
                    }
                }
                SettingsGroup("Approvals") {
                    HStack(spacing: 6) {
                        Toggle("Approval decisions", isOn: $model.prefs.notifyApprovalDecisions)
                        InfoButton("When a request of yours that needed approval is approved (with its expiry), denied, "
                            + "expires or is cancelled. Pimento checks every minute while one waits.",
                            label: "About approval decisions")
                    }
                    HStack(spacing: 6) {
                        Toggle("New approval requests", isOn: $model.prefs.notifyNewApprovals)
                        InfoButton("When someone asks you to approve; noticed whenever Pimento refreshes "
                            + "(turn on auto-refresh under General).", label: "About new approval requests")
                    }
                }
            }
        }
        .task { await model.updateNotificationPermission() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await model.updateNotificationPermission() }
        }
    }
}
