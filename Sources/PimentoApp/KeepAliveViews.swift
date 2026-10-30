import AppKit
import PimentoCore
import SwiftUI

// Keep alive: the toolbar menu (which roles are kept alive and how each
// stands, Pause), the Settings group (working hours) and the menu bar line.

/// Toolbar menu: the kept roles with their status, Pause / Resume, Check Now.
struct KeepAliveMenu: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        let kept = model.keptRoles
        let paused = model.prefs.keepAlivePaused
        Menu {
            Section("Working hours: \(model.prefs.keepAliveHours.label)") {
                if kept.isEmpty {
                    Text("No roles kept alive. Right-click a role › Keep Alive, or turn it on for a preset.")
                } else {
                    ForEach(kept) { role in
                        Text("\(role.roleName) · \(role.scopeName): \(model.keepAliveText(for: role).replacingOccurrences(of: "Kept alive", with: "kept alive"))")
                    }
                }
                if let error = model.keepAliveError {
                    Text("The last check failed: \(error)")
                }
            }
            Divider()
            Toggle("Pause Keep Alive", isOn: Binding(get: { model.prefs.keepAlivePaused }, set: { model.setKeepAlivePaused($0) }))
            Button("Check Now") { Task { await model.runKeepAlivePass() } }
                .disabled(kept.isEmpty || paused || model.identity == nil)
            Button("Keep Alive Settings…") {
                model.settingsTab = .activation
                openSettings()
            }
        } label: {
            Label(kept.isEmpty ? "Keep Alive" : paused ? "Keep Alive (paused)" : "Keep Alive (\(kept.count))",
                  systemImage: paused ? "pause.circle" : "arrow.triangle.2.circlepath")
                .labelStyle(.titleAndIcon)
        }
        .help(kept.isEmpty
            ? "Keep alive: renew roles automatically before they expire, during working hours"
            : paused ? "Keep alive is paused" : "\(kept.count) role\(kept.count == 1 ? "" : "s") kept alive, \(model.prefs.keepAliveHours.label)")
        .accessibilityLabel(paused ? "Keep alive, paused" : "Keep alive, \(kept.count) roles")
    }
}

/// Settings › Activation › Keep alive: working days and hours, Pause.
struct KeepAliveSettingsGroup: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        SettingsGroup("Keep alive") {
            HStack(spacing: 6) {
                Toggle("Pause keep-alive", isOn: $model.prefs.keepAlivePaused)
                InfoButton("Right-click an active role › Keep Alive, or turn it on for a preset (Manage Presets). Shortly before a "
                    + "kept role ends, Pimento schedules a new activation that starts exactly then, with the same justification and "
                    + "ticket, so there is no gap. Only during working hours, never past their end, and never for roles whose policy "
                    + "requires approval. A role that lapsed while the Mac slept is activated again (with a gap). Needs Pimento running. "
                    + "Pausing withdraws continuations not started yet.", label: "About keep alive")
            }
            SettingsRow("Days") {
                HStack(spacing: 6) {
                    ForEach(WorkingHours.weekOrder, id: \.self) { day in
                        Toggle(WorkingHours.dayName(day), isOn: Binding(
                            get: { model.prefs.keepAliveHours.days.contains(day) },
                            set: { on in
                                if on { model.prefs.keepAliveHours.days.insert(day) } else { model.prefs.keepAliveHours.days.remove(day) }
                            }))
                    }
                }
                .fixedSize()
            }
            SettingsRow("Hours") {
                HStack(spacing: 6) {
                    DatePicker("From", selection: time(\.start), displayedComponents: .hourAndMinute).labelsHidden()
                    Text("to")
                    DatePicker("Until", selection: time(\.end), displayedComponents: .hourAndMinute).labelsHidden()
                }
                .fixedSize()
            }
            SettingsNote(note)
        }
    }

    private var note: String {
        let h = model.prefs.keepAliveHours
        if h.days.isEmpty { return "No working days: nothing is renewed." }
        let overnight = h.end.minutes <= h.start.minutes ? " (ends the next day)" : ""
        return "\(h.label)\(overnight), local time. The last renewal of the day is shortened to end by \(h.end.text)."
    }

    /// A clock time as today's date at that time, for `DatePicker`.
    private func time(_ keyPath: WritableKeyPath<WorkingHours, ClockTime>) -> Binding<Date> {
        Binding(
            get: {
                let t = model.prefs.keepAliveHours[keyPath: keyPath]
                return Calendar.current.date(bySettingHour: t.hour, minute: t.minute, second: 0, of: Date()) ?? Date()
            },
            set: { date in
                let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
                model.prefs.keepAliveHours[keyPath: keyPath] = ClockTime(hour: parts.hour ?? 0, minute: parts.minute ?? 0)
            })
    }
}

/// The menu bar popover's keep-alive line: how many roles, the hours, Pause.
struct MenuBarKeepAliveRow: View {
    let model: AppModel
    let colors: MenuBarColors

    var body: some View {
        let count = model.keptRoles.count
        let paused = model.prefs.keepAlivePaused
        HStack(spacing: 8) {
            Image(systemName: paused ? "pause.circle" : "arrow.triangle.2.circlepath")
                .foregroundStyle(model.keepAliveError == nil ? colors.secondary : colors.warning)
            Text(paused ? "Keep alive paused" : count == 0 ? "No roles kept alive" : "\(count) kept alive · \(model.prefs.keepAliveHours.label)")
                .font(.caption)
                .foregroundStyle(colors.secondary)
                .lineLimit(1)
                .help(model.keepAliveError.map { "The last check failed: \($0)" } ?? "Right-click a role in the window › Keep Alive")
            Spacer(minLength: 4)
            if count > 0 || paused {
                Button(paused ? "Resume" : "Pause") { model.setKeepAlivePaused(!paused) }
                    .buttonStyle(.borderless)
                    .font(.caption)
                    .help(paused ? "Renew kept roles again" : "Renew nothing until resumed; withdraws continuations not started yet")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}
