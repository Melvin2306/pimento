import AppKit
import PimentoCore
import SwiftUI

/// The Settings window (⌘,). Every change is saved and applied right away.
struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings()
                .tabItem { Label("General", systemImage: "gearshape") }
            ActivationSettings()
                .tabItem { Label("Activation", systemImage: "bolt.shield") }
            NotificationSettings()
                .tabItem { Label("Notifications", systemImage: "bell.badge") }
            HistorySettingsView()
                .tabItem { Label("History", systemImage: "clock.arrow.circlepath") }
        }
        .frame(width: 500)
    }
}

private struct GeneralSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
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
                if model.tenant.isOverride {
                    Text("This launch uses the tenant from \(model.tenant.source == .commandLine ? "--tenant" : TenantResolver.environmentVariable), which takes precedence.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                LabeledContent("Hidden tenants") {
                    HStack {
                        Text(model.hiddenTenantIds.isEmpty ? "None" : "\(model.hiddenTenantIds.count)")
                            .foregroundStyle(.secondary)
                        Button("Show All") { model.unhideAllTenants() }
                            .disabled(model.hiddenTenantIds.isEmpty)
                    }
                }
            } header: {
                Text("Tenant")
            } footer: {
                Text("Hide tenants you never use from the tenant picker (⇧⌘T) by hovering over them.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Refresh") {
                Toggle("Load roles on launch", isOn: $model.prefs.refreshOnLaunch)
                Picker("Refresh automatically", selection: $model.prefs.autoRefreshMinutes) {
                    ForEach(Preferences.autoRefreshOptions, id: \.self) { minutes in
                        Text(minutes == 0 ? "Off" : minutes == 1 ? "Every minute" : "Every \(minutes) minutes").tag(minutes)
                    }
                }
            }

            Section {
                Picker("Theme", selection: $model.prefs.theme) {
                    ForEach(AppTheme.allCases, id: \.self) { theme in
                        Text(theme.title).tag(theme)
                    }
                }
                Picker("Mode", selection: appearanceMode) {
                    ForEach(AppearanceMode.allCases, id: \.self) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .disabled(!model.prefs.theme.supportsDarkMode)
                .help("Light, dark, or follow the system's appearance")
                if !model.prefs.theme.supportsDarkMode {
                    Text("Windows XP-style is light-only.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } header: {
                Text("Appearance")
            } footer: {
                Text(themeFooter).font(.caption).foregroundStyle(.secondary)
            }

            Section {
                ForEach(AppModel.Column.allCases, id: \.self) { column in
                    Toggle(column.title, isOn: Binding(
                        get: { model.isColumnVisible(column) },
                        set: { model.setColumn(column, visible: $0) }))
                }
            } header: {
                Text("Table columns")
            } footer: {
                Text("You can also right-click a column header.").font(.caption).foregroundStyle(.secondary)
            }

            Section {
                HStack {
                    Spacer()
                    Button("Reset All Settings to Defaults…") { model.showResetConfirmation = true }
                }
            }
        }
        .formStyle(.grouped)
        .themedForm()
        .fixedSize(horizontal: false, vertical: true)
        .confirmationDialog("Reset all settings?", isPresented: $model.showResetConfirmation) {
            Button("Reset", role: .destructive) { model.resetPreferences() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Notifications, activation defaults, refresh, appearance and columns go back to their defaults. "
                + "Hidden tenants and recent justifications are kept.")
        }
    }

    /// Shows Light while a light-only theme is selected; the stored choice
    /// applies again after switching back.
    private var appearanceMode: Binding<AppearanceMode> {
        Binding(
            get: { model.prefs.effectiveAppearance },
            set: { model.prefs.appearanceMode = $0 })
    }

    private var themeFooter: String {
        let base = switch model.prefs.theme {
        case .native: "The standard macOS look."
        case .azure: "Flat, with a dark portal-style top bar."
        case .windowsXP: "Beige with a glossy blue title bar. Uses Tahoma if this Mac has it."
        }
        return base + " Azure-style and Windows XP-style are inspired by those designs; Pimento is not affiliated with Microsoft."
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

private struct ActivationSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Form {
            Section("Defaults") {
                Picker("Default duration", selection: $model.prefs.defaultHours) {
                    ForEach(Preferences.hoursRange, id: \.self) { h in Text("\(h) h").tag(h) }
                }
                LabeledContent("Parallel requests") {
                    Stepper(value: $model.prefs.maxParallelRequests, in: Preferences.maxParallelRange) {
                        Text("\(model.prefs.maxParallelRequests)").monospacedDigit()
                    }
                }
            }

            Section {
                Toggle("Confirm before activating Owner roles", isOn: $model.prefs.confirmOwnerRoles)
            } footer: {
                Text(model.prefs.confirmOwnerRoles
                    ? "Lists the Owner roles in the selection and asks before sending anything. Recommended."
                    : "Owner roles are activated without asking. The Activate button still turns orange.")
                    .font(.caption).foregroundStyle(model.prefs.confirmOwnerRoles ? .secondary : Color.orange)
            }

            Section {
                Toggle("Remember recent justifications and tickets", isOn: $model.prefs.rememberJustifications)
                Toggle("Start with the last justification filled in", isOn: $model.prefs.prefillLastJustification)
                    .disabled(!model.prefs.rememberJustifications)
                LabeledContent("Remembered") {
                    HStack {
                        Text("\(model.recentJustifications.count) justifications, \(model.recentTickets.count) tickets")
                            .foregroundStyle(.secondary)
                        Button("Clear") {
                            model.clearRecentJustifications()
                            model.clearRecentTickets()
                        }
                        .disabled(model.recentJustifications.isEmpty && model.recentTickets.isEmpty)
                    }
                }
            } header: {
                Text("Justification")
            } footer: {
                Text("Up to \(Preferences.recentJustificationLimit), stored on this Mac only. "
                    + "Pick one from the clock button next to the justification or ticket field.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .themedForm()
        .fixedSize(horizontal: false, vertical: true)
    }
}

private func resultIsFailure(_ result: NotificationTestResult) -> Bool {
    if case .failed = result { true } else { false }
}

private struct NotificationSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                LabeledContent("Permission") {
                    HStack {
                        Text(model.notificationPermission.label)
                            .foregroundStyle(model.notificationPermission.needsSystemSettings ? Color.orange : .secondary)
                            .multilineTextAlignment(.trailing)
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
                LabeledContent {
                    if let result = model.notificationTestResult {
                        Text(result.label())
                            .foregroundStyle(resultIsFailure(result) ? Color.orange : .secondary)
                            .textSelection(.enabled)
                    }
                } label: {
                    Button("Send Test Notification") {
                        Task { await model.sendTestNotification() }
                    }
                    .disabled(model.notificationPermission == .unavailable)
                }
            } footer: {
                Text("A Focus or Do Not Disturb mode can hide banners even when they are allowed; "
                    + "they still land in Notification Center. The banner style is under System Settings › "
                    + "Notifications › Pimento.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("When activations finish") {
                Toggle("Show a notification", isOn: $model.prefs.notifyOnCompletion)
                Toggle("Only when something fails", isOn: $model.prefs.notifyOnlyOnFailure)
                    .disabled(!model.prefs.notifyOnCompletion)
            }

            Section {
                Toggle("Remind me before roles expire", isOn: $model.prefs.expiryReminders)
                Picker("Remind me", selection: $model.prefs.reminderLeadMinutes) {
                    ForEach(Preferences.reminderLeadOptions, id: \.self) { m in Text("\(m) minutes before").tag(m) }
                }
                .disabled(!model.prefs.expiryReminders)
            } header: {
                Text("Expiry")
            } footer: {
                Text("Turning reminders off cancels the ones already scheduled; a new lead time moves them.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Toggle("Notify when a scheduled activation starts", isOn: $model.prefs.notifyScheduledStart)
            } header: {
                Text("Scheduled activations")
            } footer: {
                Text("At the start time, from this Mac, for the activations listed under Scheduled. Best-effort: "
                    + "it does not check that PIM activated the role. Turning it off removes the pending ones.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Toggle("Approval decisions", isOn: $model.prefs.notifyApprovalDecisions)
                Toggle("New approval requests", isOn: $model.prefs.notifyNewApprovals)
            } header: {
                Text("Approvals")
            } footer: {
                Text("Decisions: when a request of yours that needed approval is approved (with its expiry), denied, "
                    + "expires or is cancelled; Pimento checks every minute while one waits. New requests: when someone "
                    + "asks you to approve; noticed whenever Pimento refreshes (turn on auto-refresh under General).")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Toggle("Play sound", isOn: $model.prefs.playSound)
            }
        }
        .formStyle(.grouped)
        .themedForm()
        .fixedSize(horizontal: false, vertical: true)
        .task { await model.updateNotificationPermission() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await model.updateNotificationPermission() }
        }
    }
}
