import AppKit
import PimentoCore
import SwiftUI

/// Toolbar button showing the current tenant; opens the searchable picker.
struct TenantToolbarButton: View {
    @Environment(AppModel.self) private var model
    @Environment(\.appTheme) private var theme
    @Environment(\.ultraDark) private var ultra

    var body: some View {
        @Bindable var model = model
        Button {
            if model.showTenantPicker { model.showTenantPicker = false } else { model.openTenantPicker() }
        } label: {
            // Primary colour on purpose: a secondary label reads as disabled.
            HStack(spacing: 6) {
                Image(systemName: model.tenant.isOverride ? "lock.fill" : "building.2.fill")
                    // White on the blue XP title bar, where the accent would vanish.
                    .foregroundStyle(theme == .windowsXP ? Color.white : Color.accentColor)
                Text(model.tenantLabel)
                    .fontWeight(.medium)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .frame(maxWidth: 260, alignment: .leading)
                    .fixedSize(horizontal: true, vertical: false)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 2)
        }
        .disabled(model.isActivating)
        .help(help)
        .accessibilityLabel("Tenant: \(model.tenantLabel)")
        .popover(isPresented: $model.showTenantPicker, arrowEdge: .bottom) {
            TenantPicker()
                .environment(model)
                .appTheme(theme, ultra: ultra)
                .appAppearanceInPopover()
        }
    }

    private var help: String {
        let id = model.effectiveTenantId.map { "\n\($0)" } ?? ""
        return switch model.tenant.source {
        case .commandLine: "Tenant set with --tenant\(id)"
        case .environment: "Tenant set with \(TenantResolver.environmentVariable)\(id)"
        case .saved: "Tenant chosen in the app (⇧⌘T to change)\(id)"
        case .azDefault: "Using az's current tenant (⇧⌘T to change)\(id)"
        }
    }
}

/// Popover listing the reachable tenants: search, name + domain, a short ID,
/// a checkmark on the one in use, and hiding tenants you never use.
struct TenantPicker: View {
    @Environment(AppModel.self) private var model
    @FocusState private var searchFocused: Bool

    private var locked: Bool { model.tenant.isOverride }

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 0) {
            if locked {
                lockedNote.padding(12)
                Divider()
            }
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search tenants", text: $model.tenantQuery)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
                    .onSubmit(pickFirstMatch)
                if !model.tenantQuery.isEmpty {
                    Button { model.tenantQuery = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Clear search")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    if model.tenantQuery.isEmpty { azDefaultRow }
                    let tenants = model.pickerTenants
                    ForEach(tenants) { tenant in TenantRow(tenant: tenant, locked: locked) }
                    if tenants.isEmpty { emptyNote }
                }
                .padding(6)
            }
            .frame(minHeight: 120, maxHeight: 380)
            .fixedSize(horizontal: false, vertical: true)

            Divider()
            footer.padding(.horizontal, 10).padding(.vertical, 8)
        }
        .frame(width: 400)
        .themedPageBackground()
        .onAppear {
            searchFocused = true
            if model.knownTenants.isEmpty { Task { await model.loadTenants() } }
        }
    }

    private var lockedNote: some View {
        Label {
            Text("Set by \(model.tenant.source == .commandLine ? "--tenant" : TenantResolver.environmentVariable) for this launch. "
                + "Relaunch without it to switch tenants here.")
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "lock.fill").foregroundStyle(.secondary)
        }
    }

    private var azDefaultRow: some View {
        let current = model.tenant.source == .azDefault
        let resolved = current && model.effectiveTenantId != nil ? model.tenantLabel : nil
        return PickerRowButton(id: "az-default", disabled: locked, action: { choose(nil) }) {
            Image(systemName: "terminal").frame(width: 18).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text("Use az default")
                Text(resolved.map { "az account show: \($0)" } ?? "The tenant of az's current account")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            if current { Image(systemName: "checkmark").foregroundStyle(Color.accentColor) }
        }
        .help("Follow az's current account (az account show)")
    }

    private var emptyNote: some View {
        Group {
            if model.isLoadingTenants && model.knownTenants.isEmpty {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Loading tenants…")
                }
            } else if model.knownTenants.isEmpty {
                Text("No tenants found. Sign in with `az login`, or enter a tenant ID or domain.")
            } else {
                Text(model.tenantQuery.isEmpty ? "All tenants are hidden." : "No tenant matches “\(model.tenantQuery)”.")
            }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(16)
    }

    private var footer: some View {
        @Bindable var model = model
        return HStack(spacing: 12) {
            Button("Enter ID or Domain…") {
                model.showTenantPicker = false
                model.showTenantSheet = true
            }
            .disabled(locked)
            Spacer()
            if model.hiddenTenantCount > 0 {
                Toggle("Show hidden (\(model.hiddenTenantCount))", isOn: $model.showHiddenTenants)
                    .toggleStyle(.checkbox)
                    .controlSize(.small)
            }
            Button {
                Task { await model.loadTenants() }
            } label: {
                if model.isLoadingTenants {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "arrow.clockwise")
                }
            }
            .buttonStyle(.borderless)
            .disabled(model.isLoadingTenants)
            .help("Reload the tenant list")
            .accessibilityLabel("Reload tenant list")
        }
        .buttonStyle(.link)
    }

    private func pickFirstMatch() {
        guard !locked, !model.tenantQuery.isEmpty, let first = model.pickerTenants.first else { return }
        choose(first.id)
    }

    private func choose(_ id: String?) {
        model.showTenantPicker = false
        guard !locked else { return }
        if let id, model.effectiveTenantId?.caseInsensitiveCompare(id) == .orderedSame, model.tenant.source == .saved { return }
        if id == nil, model.tenant.source == .azDefault { return }
        model.selectTenant(id)
    }
}

/// One tenant in the picker: name, domain and short ID, hide on hover.
private struct TenantRow: View {
    @Environment(AppModel.self) private var model
    let tenant: TenantInfo
    let locked: Bool

    var body: some View {
        let hidden = model.isHidden(tenant)
        let current = model.isEffectiveTenant(tenant)
        PickerRowButton(id: tenant.id, disabled: locked, action: choose) {
            Image(systemName: tenant.isManaged ? "person.2.badge.gearshape" : "building.2")
                .frame(width: 18)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(tenant.label)
                    .fontWeight(current ? .semibold : .regular)
                    .foregroundStyle(tenant.isNamed ? .primary : .secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(secondary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .opacity(hidden ? 0.55 : 1)
            Spacer(minLength: 8)
            if model.hoveredTenantId == tenant.id && !current {
                Button {
                    model.setHidden(tenant, !hidden)
                } label: {
                    Image(systemName: hidden ? "eye" : "eye.slash")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help(hidden ? "Show this tenant in the list again" : "Hide this tenant from the list")
                .accessibilityLabel(hidden ? "Unhide \(tenant.label)" : "Hide \(tenant.label)")
            }
            if current { Image(systemName: "checkmark").foregroundStyle(Color.accentColor) }
        }
        .help("\(tenant.label)\n\(tenant.id)")
        .contextMenu {
            Button("Copy Tenant ID") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(tenant.id, forType: .string)
            }
            if !current {
                Button(hidden ? "Show in List" : "Hide from List") { model.setHidden(tenant, !hidden) }
            }
        }
        .accessibilityLabel("\(tenant.label)\(current ? ", current tenant" : "")")
    }

    /// Domain (when the name is a display name) and the short ID; the full ID
    /// for unnamed tenants, which have nothing else to go by.
    private var secondary: String {
        guard tenant.isNamed else { return tenant.id }
        return ([tenant.detail, tenant.isManaged ? "Lighthouse" : nil, tenant.shortId].compactMap { $0 }).joined(separator: " · ")
    }

    private func choose() {
        model.showTenantPicker = false
        guard !locked, !(model.isEffectiveTenant(tenant) && model.tenant.source == .saved) else { return }
        model.selectTenant(tenant.id)
    }
}

/// A full-width plain row with a hover highlight (kept in the model: the
/// `@State` macro needs full Xcode).
private struct PickerRowButton<Content: View>: View {
    @Environment(AppModel.self) private var model
    @Environment(\.appTheme) private var theme
    @Environment(\.colorScheme) private var scheme
    @Environment(\.ultraDark) private var ultra
    let id: String
    let disabled: Bool
    let action: () -> Void
    @ViewBuilder let content: () -> Content

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) { content() }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: theme == .native ? 6 : ThemePalette(theme, scheme, ultra: ultra).cornerRadius)
                        .fill(model.hoveredTenantId == id && !disabled ? hoverFill : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .onHover { inside in
            if inside { model.hoveredTenantId = id } else if model.hoveredTenantId == id { model.hoveredTenantId = nil }
        }
    }

    private var hoverFill: Color {
        theme == .native ? Color.accentColor.opacity(0.14) : ThemePalette(theme, scheme, ultra: ultra).rowHover
    }
}

/// Sheet to type in a tenant ID or domain that az doesn't list.
struct TenantSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    private var draft: String { model.tenantDraft.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var draftIsValid: Bool { TenantResolver.isValid(draft) }

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 14) {
            Text("Enter Tenant").font(.headline)
            Text("Pimento lists the PIM roles of one Microsoft Entra tenant at a time. "
                + "Enter a tenant ID or a verified domain. az needs a session for it (az login --tenant …).")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            TextField("Tenant ID or domain, e.g. contoso.onmicrosoft.com", text: $model.tenantDraft)
                .themedTextField()
                .textFieldStyle(.roundedBorder)
                .font(.body.monospaced())
                .onSubmit(save)
            if !draft.isEmpty && !draftIsValid {
                Text("Enter a tenant GUID or a domain name.").font(.caption).foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .themedButton(.secondary)
                    .keyboardShortcut(.cancelAction)
                Button("Use Tenant", action: save)
                    .themedButton(.primary())
                    .keyboardShortcut(.defaultAction)
                    .disabled(!draftIsValid)
            }
        }
        .padding(20)
        .frame(width: 480)
        .themedPageBackground()
        .onAppear { model.tenantDraft = model.tenant.tenantId ?? "" }
    }

    private func save() {
        guard draftIsValid else { return }
        model.selectTenant(draft)
        dismiss()
    }
}
