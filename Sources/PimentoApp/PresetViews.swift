import AppKit
import PimentoCore
import SwiftUI

// Presets: named sets of roles with an optional justification and duration,
// saved per tenant in the presets file the `pimento` CLI reads too.

/// The menu items, shared by the toolbar menu and the Presets menu in the
/// menu bar (which adds ⌘1–⌘9).
struct PresetMenuItems: View {
    @Environment(AppModel.self) private var model
    var shortcuts = false

    var body: some View {
        let presets = model.visiblePresets
        let noRoles = model.roles.isEmpty || model.isActivating
        if presets.isEmpty {
            Text(model.presetFileError == nil ? "No Presets for This Tenant" : "Presets File Unreadable")
        } else {
            Section("Select Roles") {
                ForEach(Array(presets.enumerated()), id: \.element.id) { index, preset in
                    let button = Button(preset.name) { model.applyPreset(preset) }.disabled(noRoles)
                    if shortcuts && index < 9 {
                        button.keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
                    } else {
                        button
                    }
                }
            }
            Menu("Activate Preset") {
                ForEach(presets) { preset in
                    Button(preset.name) { model.activatePreset(preset) }
                }
            }
            .disabled(noRoles)
        }
        Divider()
        Button("Save Selection as Preset…") { model.beginSavePreset() }
            .keyboardShortcut(shortcuts ? KeyboardShortcut("s", modifiers: [.command, .shift]) : nil)
            .disabled(model.checkedRoles.isEmpty || model.isActivating)
        Button("Manage Presets…") { model.openManagePresets() }
            .disabled(model.isActivating)
    }
}

/// Toolbar menu: select or activate a preset in one click.
struct PresetsMenu: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Menu {
            PresetMenuItems()
        } label: {
            Label("Presets", systemImage: "star.square.on.square")
        }
        .help("Presets: select or activate a saved set of roles (⌘1–⌘9 in the Presets menu)")
        .accessibilityLabel("Presets")
    }
}

// MARK: - Save selection

struct SavePresetSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    private var name: String { model.savePresetName.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        @Bindable var model = model
        let roles = model.checkedRoles
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Save Selection as Preset").font(.headline)
                Text("Select or activate these \(roles.count) role\(roles.count == 1 ? "" : "s") again in one click, "
                    + "from the Presets menu or with pimento activate --preset.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            TextField("Name, e.g. On-call", text: $model.savePresetName)
                .themedTextField()
                .textFieldStyle(.roundedBorder)
                .onSubmit(save)
                .accessibilityLabel("Preset name")

            VStack(alignment: .leading, spacing: 8) {
                Toggle("Save the justification", isOn: $model.savePresetIncludesJustification)
                TextField("Justification", text: $model.savePresetJustification)
                    .themedTextField()
                    .textFieldStyle(.roundedBorder)
                    .disabled(!model.savePresetIncludesJustification)
                    .padding(.leading, 20)
                Toggle("Save the duration: \(model.duration.label)", isOn: $model.savePresetIncludesDuration)
            }
            .toggleStyle(.checkbox)

            PresetRoleList(roles: roles.map(PresetRole.init), maxHeight: 150)

            if let error = model.savePresetError {
                Text(error).font(.caption).foregroundStyle(.red)
            } else if model.savePresetReplaces {
                Text("A preset named “\(name)” exists for this tenant and will be replaced.")
                    .font(.caption).foregroundStyle(.orange)
            }

            HStack {
                Text("Tenant: \(model.tenantLabel)").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .themedButton(.secondary)
                    .keyboardShortcut(.cancelAction)
                Button(model.savePresetReplaces ? "Replace" : "Save", action: save)
                    .themedButton(.primary())
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.isEmpty || roles.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 480)
        .themedPageBackground()
    }

    private func save() {
        guard !name.isEmpty else { return }
        if model.saveSelectionAsPreset() { dismiss() }
    }
}

/// A read-only list of preset roles: role (crown for Owner) and resource.
struct PresetRoleList: View {
    let roles: [PresetRole]
    var maxHeight: CGFloat = 200

    var body: some View {
        PresetBox {
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(roles, id: \.key) { role in
                        HStack(spacing: 6) {
                            RoleName(name: role.roleName ?? "Role", isOwner: Self.isOwner(role))
                            Text("·").foregroundStyle(.secondary)
                            Text(role.scopeName ?? role.scope).lineLimit(1).truncationMode(.middle)
                                .foregroundStyle(.secondary)
                        }
                        .help(role.scope)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
            }
            .frame(maxHeight: maxHeight)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    static func isOwner(_ role: PresetRole) -> Bool {
        role.key.role == EligibleRole.ownerRoleGUID || role.roleName?.caseInsensitiveCompare("Owner") == .orderedSame
    }
}

private struct RoleName: View {
    let name: String
    let isOwner: Bool

    var body: some View {
        HStack(spacing: 3) {
            Text(name).fontWeight(isOwner ? .semibold : .regular).lineLimit(1)
            if isOwner {
                Image(systemName: "crown.fill").foregroundStyle(.orange).imageScale(.small)
                    .accessibilityLabel("Owner role")
            }
        }
    }
}

/// A bordered box: the theme's surface and border colours, or the system's.
struct PresetBox<Content: View>: View {
    @Environment(\.appTheme) private var theme
    @Environment(\.colorScheme) private var scheme
    @Environment(\.ultraDark) private var ultra
    @ViewBuilder let content: () -> Content

    var body: some View {
        let palette = ThemePalette(theme, scheme, ultra: ultra)
        let radius: CGFloat = theme == .native ? 6 : theme == .azure ? palette.cornerRadius : 0
        content()
            .background(theme == .native ? AnyShapeStyle(.background) : AnyShapeStyle(palette.surface),
                        in: RoundedRectangle(cornerRadius: radius))
            .overlay(RoundedRectangle(cornerRadius: radius)
                .strokeBorder(theme == .native ? AnyShapeStyle(.separator) : AnyShapeStyle(palette.border)))
    }
}

// MARK: - Manage

struct ManagePresetsSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appTheme) private var theme
    @Environment(\.colorScheme) private var scheme
    @Environment(\.ultraDark) private var ultra

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Presets").font(.headline)
                    Text("For \(model.tenantLabel). Shared with the pimento command-line tool.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { dismiss() }
                    .themedButton(.secondary)
                    .keyboardShortcut(.cancelAction)
            }
            .padding(16)
            ThemedDivider()
            HStack(spacing: 0) {
                sidebar.frame(width: 220)
                Rectangle().fill(sidebarDividerColor).frame(width: 1)
                editor.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if let error = model.presetFileError {
                ThemedDivider()
                Text(error).font(.caption).foregroundStyle(.red).padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(width: 860, height: 580)
        .themedPageBackground()
    }

    private var sidebarDividerColor: Color {
        theme == .native ? Color(nsColor: .separatorColor) : ThemePalette(theme, scheme, ultra: ultra).border
    }

    private var sidebar: some View {
        let presets = model.visiblePresets
        return VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    if presets.isEmpty && model.presetDraft == nil {
                        Text("No presets yet. Check roles in the table and press +, or use Save Selection as Preset.")
                            .font(.callout).foregroundStyle(.secondary)
                            .padding(8)
                    }
                    if let draft = model.presetDraft, model.managedPresetId == nil {
                        SidebarRow(title: draft.name, subtitle: "New, not saved", selected: true) {}
                    }
                    ForEach(presets) { preset in
                        SidebarRow(title: preset.name, subtitle: subtitle(preset), selected: model.managedPresetId == preset.id) {
                            model.selectManagedPreset(preset.id)
                        }
                    }
                }
                .padding(6)
            }
            ThemedDivider()
            HStack(spacing: 4) {
                Button { model.newPreset() } label: { Image(systemName: "plus") }
                    .help("New preset (with the checked roles, if any)")
                    .accessibilityLabel("New preset")
                Button { model.deleteManagedPreset() } label: { Image(systemName: "minus") }
                    .help("Delete the selected preset")
                    .accessibilityLabel("Delete preset")
                    .disabled(model.managedPresetId == nil)
                Spacer()
            }
            .buttonStyle(.borderless)
            .padding(6)
        }
    }

    private func subtitle(_ p: Preset) -> String {
        ([p.summary, p.duration?.label].compactMap { $0 }).joined(separator: " · ")
    }

    @ViewBuilder private var editor: some View {
        if model.presetDraft != nil {
            PresetEditor()
        } else {
            ContentUnavailableView {
                Label("No Preset Selected", systemImage: "star.square.on.square")
            } description: {
                Text("Pick a preset on the left, or press + to create one from the checked roles.")
            }
        }
    }
}

private struct SidebarRow: View {
    @Environment(\.appTheme) private var theme
    @Environment(\.colorScheme) private var scheme
    @Environment(\.ultraDark) private var ultra
    let title: String
    let subtitle: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        let palette = ThemePalette(theme, scheme, ultra: ultra)
        let fill: Color = theme == .native ? Color.accentColor.opacity(0.18) : palette.selection
        let text: Color = theme == .native ? .primary : selected ? palette.selectionText : palette.text
        Button(action: action) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).fontWeight(.medium).lineLimit(1).foregroundStyle(text)
                Text(subtitle).font(.caption).lineLimit(1)
                    .foregroundStyle(theme == .native ? Color.secondary : selected ? palette.selectionText.opacity(0.85) : palette.secondaryText)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: theme == .native ? 6 : palette.cornerRadius).fill(selected ? fill : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Edits `model.presetDraft`: name, justification, duration, roles, rules.
private struct PresetEditor: View {
    @Environment(AppModel.self) private var model

    private func binding<T>(_ path: WritableKeyPath<Preset, T>, _ fallback: T) -> Binding<T> {
        Binding(
            get: { model.presetDraft?[keyPath: path] ?? fallback },
            set: { if model.presetDraft != nil { model.presetDraft![keyPath: path] = $0 } })
    }

    private var justification: Binding<String> {
        Binding(
            get: { model.presetDraft?.justification ?? "" },
            set: { model.presetDraft?.justification = $0.isEmpty ? nil : $0 })
    }

    private var ticketSystem: Binding<String> {
        Binding(
            get: { model.presetDraft?.ticketSystem ?? "" },
            set: { model.presetDraft?.ticketSystem = $0.isEmpty ? nil : $0 })
    }

    var body: some View {
        let draft = model.presetDraft!
        VStack(alignment: .leading, spacing: 12) {
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                GridRow {
                    Text("Name").gridColumnAlignment(.trailing)
                    TextField("Name", text: binding(\.name, ""))
                        .themedTextField()
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel("Preset name")
                }
                GridRow {
                    Text("Justification")
                    TextField("Optional: filled in when you pick the preset", text: justification)
                        .themedTextField()
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel("Default justification")
                }
                GridRow {
                    Text("Ticket system")
                    TextField("Optional, e.g. ServiceNow: filled in when you pick the preset", text: ticketSystem)
                        .themedTextField()
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel("Default ticket system")
                }
                GridRow {
                    Text("Keep alive")
                    Toggle("Renew its roles before they expire, during working hours", isOn: binding(\.keepAlive, false))
                        .help("While a role of this preset is active, Pimento continues it shortly before it ends "
                            + "(Settings › Activation › Keep alive). Roles whose policy requires approval are left alone.")
                }
                GridRow {
                    Text("Duration")
                    Picker("Duration", selection: binding(\.duration, nil)) {
                        Text("Not set").tag(RequestedDuration?.none)
                        Text("Maximum allowed").tag(RequestedDuration?.some(.maximum))
                        Divider()
                        ForEach(1...ActivationRequestBuilder.maxHours, id: \.self) { h in
                            Text("\(h) h").tag(RequestedDuration?.some(.hours(h)))
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
            }

            HStack {
                Text("Roles").font(.subheadline.weight(.semibold))
                Text(draft.summary).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Use Checked Roles (\(model.checkedRoles.count))") { model.setDraftRolesToSelection() }
                    .themedButton(.secondary)
                    .disabled(model.checkedRoles.isEmpty)
                    .help("Replace the preset's roles with the roles checked in the table")
            }

            PresetBox {
                ScrollView {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(model.draftMissingRoles, id: \.key) { item in
                            HStack(spacing: 6) {
                                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                                    .imageScale(.small)
                                Text(item.label).lineLimit(1).truncationMode(.middle)
                                Text("no longer eligible").font(.caption).foregroundStyle(.secondary)
                                Spacer()
                                removeButton { model.removeFromDraft(item) }
                            }
                            .help(item.scope)
                        }
                        ForEach(draft.match, id: \.self) { rule in
                            let count = model.roles.filter(rule.criteria.matches).count
                            HStack(spacing: 6) {
                                Image(systemName: "line.3.horizontal.decrease.circle").foregroundStyle(.secondary)
                                Text("Rule: \(rule.label)").lineLimit(1)
                                Text("matches \(count) now").font(.caption).foregroundStyle(.secondary)
                                Spacer()
                                removeButton { model.removeFromDraft(rule) }
                            }
                            .help("Saved with pimento presets save; resolved when you pick the preset.")
                        }
                        if !model.draftMissingRoles.isEmpty || !draft.match.isEmpty { Divider() }
                        ForEach(model.roles) { role in
                            Toggle(isOn: Binding(get: { model.draftContains(role) }, set: { model.setDraft(role, included: $0) })) {
                                HStack(spacing: 6) {
                                    RoleName(name: role.roleName, isOwner: role.isOwner)
                                    Text("·").foregroundStyle(.secondary)
                                    Text(role.scopeName).lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                                    if role.isActive {
                                        Text("active").font(.caption).foregroundStyle(.green)
                                    }
                                }
                            }
                            .toggleStyle(.checkbox)
                            .help("\(role.scopeTypeLabel) · \(role.membership.label)\n\(role.scope)")
                        }
                        if model.roles.isEmpty {
                            Text("Load your roles (⌘R) to add or remove roles.").font(.callout).foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                }
            }
            .frame(maxHeight: .infinity)

            HStack {
                Button("Delete", role: .destructive) { model.deleteManagedPreset() }
                    .themedButton(.secondary)
                    .disabled(model.managedPresetId == nil)
                if let error = model.presetDraftError {
                    Text(error).font(.caption).foregroundStyle(.red).lineLimit(2)
                }
                Spacer()
                Button("Revert") { model.revertDraft() }
                    .themedButton(.secondary)
                    .disabled(!model.presetDraftIsDirty || model.managedPresetId == nil)
                Button("Save") { model.saveDraft() }
                    .themedButton(.primary())
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut("s", modifiers: .command)
                    .disabled(!model.presetDraftIsDirty)
            }
        }
        .padding(16)
    }

    private func removeButton(_ action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: "xmark.circle.fill") }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help("Remove from the preset")
            .accessibilityLabel("Remove from the preset")
    }
}
