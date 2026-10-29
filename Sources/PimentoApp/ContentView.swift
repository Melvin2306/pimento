import AppKit
import PimentoCore
import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            ThemeHeader()
            if let banner = model.banner {
                BannerView(banner: banner) { model.banner = nil }
            }
            content
            ThemedDivider()
            ActivationBar()
        }
        .themedPageBackground()
        .themedToolbar()
        .searchable(text: $model.search, placement: .toolbar, prompt: "Filter roles, resources, groups")
        .toolbar { toolbar }
        .navigationTitle(AppInfo.name)
        .navigationSubtitle(subtitle)
        .task {
            if model.knownTenants.isEmpty { Task { await model.loadTenants() } }
            if model.loadState == .idle && !model.awaitingManualRefresh { await model.refresh() }
        }
        .sheet(isPresented: $model.showDryRunSheet) { DryRunSheet(plans: model.dryRunPlans) }
        .sheet(isPresented: $model.showTenantSheet) { TenantSheet() }
        .sheet(isPresented: $model.showSavePresetSheet) { SavePresetSheet() }
        .sheet(isPresented: $model.showManagePresets) { ManagePresetsSheet() }
        .alert(ownerAlertTitle, isPresented: $model.showOwnerConfirmation) {
            Button(model.activateTitle, role: .destructive) {
                Task { await model.activate() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(ownerAlertMessage)
        }
    }

    @ViewBuilder private var content: some View {
        if let tenantError = model.tenantError {
            ContentUnavailableView {
                Label("Invalid tenant", systemImage: "building.2.crop.circle")
            } description: {
                Text(tenantError + "\n\nFix the --tenant argument or the \(TenantResolver.environmentVariable) variable and relaunch.")
            }
        } else {
            switch model.loadState {
            case .failed(let message, let needsLogin) where model.roles.isEmpty:
                LoadErrorView(message: message, needsLogin: needsLogin)
            case .idle where model.awaitingManualRefresh:
                ContentUnavailableView {
                    Label("Roles not loaded", systemImage: "arrow.clockwise.circle")
                } description: {
                    Text("Loading on launch is off in Settings. Refresh to list your eligible roles in \(model.tenantLabel).")
                } actions: {
                    Button("Refresh") { Task { await model.refresh() } }
                        .themedButton(.primary())
                        .buttonStyle(.borderedProminent)
                }
            case .loading where model.roles.isEmpty, .idle:
                ProgressView("Loading eligible roles…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            default:
                if model.roles.isEmpty {
                    ContentUnavailableView {
                        Label("No eligible roles", systemImage: "person.badge.key")
                    } description: {
                        Text("You have no Azure-resource PIM eligibilities in \(model.tenantLabel). "
                            + "If you expected some, check that the right tenant is selected.")
                    } actions: {
                        Button("Choose Tenant…") { model.openTenantPicker() }
                            .themedButton(.secondary)
                            .disabled(model.tenant.isOverride)
                    }
                } else if model.visibleRoles.isEmpty {
                    ContentUnavailableView.search(text: model.search)
                } else {
                    RoleTable()
                        .themedListArea()
                }
            }
        }
    }

    private var subtitle: String {
        guard let identity = model.identity else { return "" }
        return "\(identity.displayName) · \(model.roles.count) eligible · \(model.activeCount) active"
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            TenantToolbarButton()
        }
        ToolbarItemGroup(placement: .navigation) {
            Button {
                Task { await model.refresh() }
            } label: {
                if model.loadState == .loading {
                    ProgressView().controlSize(.small)
                } else {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
            }
            .help("Reload eligible and active roles (⌘R)")
            .accessibilityLabel("Refresh")
            .disabled(model.loadState == .loading || model.isActivating)

            // Next to Refresh rather than at the trailing edge, where the
            // search field pushes it into the overflow menu on narrow windows.
            SettingsLink {
                Label("Settings", systemImage: "gearshape")
            }
            .help("Settings: notifications, activation defaults, tenants (⌘,)")
            .accessibilityLabel("Settings")
        }
        ToolbarItemGroup(placement: .primaryAction) {
            PresetsMenu()
            Button("Select All Eligible") { model.selectAllEligible() }
                .help("Check every role that is not active yet, within the current filter (⇧⌘A)")
                .disabled(model.isActivating || model.roles.isEmpty)
            Button("Clear") { model.clearSelection() }
                .help("Uncheck all roles (⇧⌘D)")
                .disabled(model.checked.isEmpty || model.isActivating)
        }
    }

    private var ownerAlertTitle: String {
        let n = model.checkedOwnerRoles.count
        return "Activate \(n) Owner role\(n == 1 ? "" : "s")?"
    }

    private var ownerAlertMessage: String {
        let owners = model.checkedOwnerRoles
        let names = owners.prefix(12).map { "• \($0.scopeName)" }.joined(separator: "\n")
        let more = owners.count > 12 ? "\n… and \(owners.count - 12) more" : ""
        let total = model.checkedRoles.count
        return "You are about to activate \(owners.count) Owner role\(owners.count == 1 ? "" : "s") "
            + "(\(total) role\(total == 1 ? "" : "s") in total) for \(model.durationSummary):\n\n\(names)\(more)"
            + "\n\nJustification: \(model.trimmedJustification)"
    }
}

// MARK: - Table

struct RoleTable: View {
    @Environment(AppModel.self) private var model
    @Environment(\.appTheme) private var theme

    var body: some View {
        switch theme {
        // Bordered for XP: the grid and the boxed header read as a Luna list view.
        case .windowsXP: table.tableStyle(.bordered(alternatesRowBackgrounds: false))
        case .azure: table.tableStyle(.inset(alternatesRowBackgrounds: false))
        case .native: table.tableStyle(.inset(alternatesRowBackgrounds: true))
        }
    }

    private var table: some View {
        @Bindable var model = model
        return Table(model.visibleRoles, sortOrder: $model.sortOrder, columnCustomization: $model.columnCustomization) {
            TableColumn("") { (role: EligibleRole) in
                Toggle("", isOn: Binding(
                    get: { model.isChecked(role) },
                    set: { model.setChecked(role, $0) }
                ))
                .labelsHidden()
                .disabled(role.isActive || model.isActivating)
                .help(role.isActive ? "Already active" : "Select for activation")
                .accessibilityLabel("Select \(role.roleName) on \(role.scopeName)")
                .themedCell(checked: model.isChecked(role))
            }
            .width(24)
            .disabledCustomizationBehavior(.all)

            TableColumn("Role", value: \.roleName) { role in
                HStack(spacing: 4) {
                    Text(role.roleName)
                        .fontWeight(role.isOwner ? .semibold : .regular)
                        .lineLimit(1)
                        .help(role.roleName)
                    if role.isOwner {
                        Image(systemName: "crown.fill").foregroundStyle(.orange).imageScale(.small)
                            .help("Owner")
                            .accessibilityLabel("Owner role")
                    }
                }
                .themedCell(checked: model.isChecked(role))
            }
            .width(min: 90, ideal: 120)
            .customizationID("role")
            .disabledCustomizationBehavior(.visibility)

            TableColumn("Resource", value: \.scopeName) { role in
                // Long resource names keep both ends readable; the tooltip has the full path.
                Text(role.scopeName)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help("\(role.scopeName)\n\(role.scope)")
                    .themedCell(checked: model.isChecked(role))
            }
            .width(min: 160, ideal: 260)
            .customizationID("resource")
            .disabledCustomizationBehavior(.visibility)

            TableColumn("Type", value: \.scopeTypeLabel) { role in
                Text(role.scopeTypeLabel).lineLimit(1)
                    .themedCell(checked: model.isChecked(role))
            }
            .width(min: 80, ideal: 110)
            .customizationID(AppModel.Column.type.rawValue)

            TableColumn("Membership", value: \.membership.label) { role in
                Group {
                    switch role.membership {
                    case .direct:
                        Text("Direct")
                    case .group(let name):
                        Label(name, systemImage: "person.3")
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .help("Inherited through group \(name)")
                    }
                }
                .themedCell(checked: model.isChecked(role))
            }
            .width(min: 80, ideal: 150)
            .customizationID(AppModel.Column.membership.rawValue)

            TableColumn("Cond.") { role in
                Group {
                    if role.hasCondition {
                        Image(systemName: "lock.shield")
                            .foregroundStyle(.secondary)
                            .help("ABAC condition (copied verbatim on activation):\n\(role.condition ?? "")")
                            .accessibilityLabel("Has an ABAC condition")
                    }
                }
                .themedCell(checked: model.isChecked(role))
            }
            .width(44)
            .customizationID(AppModel.Column.condition.rawValue)

            TableColumn("Duration") { role in
                DurationCell(role: role, checked: model.isChecked(role))
                    .themedCell(checked: model.isChecked(role))
            }
            .width(min: 100, ideal: 130)
            .customizationID(AppModel.Column.duration.rawValue)

            TableColumn("Status", value: \.statusSortKey) { role in
                StatusCell(role: role, checked: model.isChecked(role))
                    .themedCell(checked: model.isChecked(role))
            }
            .width(min: 110, ideal: 150)
            .customizationID("status")
            .disabledCustomizationBehavior(.visibility)

            TableColumn("Result") { role in
                ResultCell(progress: model.progress[role.id], checked: model.isChecked(role))
                    .themedCell(checked: model.isChecked(role))
            }
            .width(min: 120, ideal: 260)
            .customizationID("result")
            .disabledCustomizationBehavior(.visibility)
        }
    }
}

struct StatusCell: View {
    let role: EligibleRole
    var checked = false
    @Environment(\.appTheme) private var theme
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        if theme == .native {
            native
        } else {
            themed(ThemePalette(theme, scheme))
        }
    }

    private var activeText: String {
        role.activeUntil.map { "Active until \(Self.format($0))" } ?? "Active"
    }

    /// A portal badge for Azure; a green check / plain text for XP.
    @ViewBuilder private func themed(_ palette: ThemePalette) -> some View {
        if role.isActive {
            Group {
                if theme == .azure {
                    ThemeBadge(text: activeText, symbol: "checkmark.circle.fill",
                               foreground: palette.success, fill: palette.successFill, font: palette.font(12))
                } else {
                    Label {
                        Text(activeText)
                    } icon: {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(palette.success)
                    }
                }
            }
            .help(role.activeUntil.map { $0.formatted(date: .complete, time: .standard) } ?? "Active")
        } else if theme == .azure {
            ThemeBadge(text: "Eligible", symbol: nil,
                       foreground: palette.secondaryText, fill: checked ? palette.surface.opacity(0.6) : palette.neutralFill,
                       font: palette.font(12))
        } else {
            Text("Eligible").foregroundStyle(checked ? palette.selectionText : palette.secondaryText)
        }
    }

    @ViewBuilder private var native: some View {
        if role.isActive {
            Label {
                Text(role.activeUntil.map { "Active until \(Self.format($0))" } ?? "Active")
            } icon: {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            }
            .help(role.activeUntil.map { $0.formatted(date: .complete, time: .standard) } ?? "Active")
        } else {
            Text("Eligible").foregroundStyle(.secondary)
        }
    }

    static func format(_ date: Date) -> String {
        Calendar.current.isDateInToday(date)
            ? date.formatted(date: .omitted, time: .shortened)
            : date.formatted(.dateTime.weekday(.abbreviated).hour().minute())
    }
}

/// The policy maximum of a role, and for checked rows the duration it will
/// be requested for: `8 h (max 8 h)`, orange when capped.
struct DurationCell: View {
    @Environment(AppModel.self) private var model
    @Environment(\.appTheme) private var theme
    @Environment(\.colorScheme) private var scheme
    let role: EligibleRole
    var checked = false

    var body: some View {
        let lookup = model.policyLookup(for: role)
        let palette = ThemePalette(theme, scheme)
        let secondary: Color = theme == .native ? .secondary : checked ? palette.selectionText : palette.secondaryText
        Group {
            if checked && !role.isActive {
                let d = model.effectiveDuration(for: role)
                if d.isClamped || d.isFallback {
                    Label {
                        // Short: the tooltip says what was asked and why.
                        Text(d.isFallback ? "\(d.text) (max ?)" : "\(d.text) (max)").lineLimit(1)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill").imageScale(.small)
                    }
                    .foregroundStyle(warning(palette))
                } else {
                    Text(d.label).lineLimit(1)
                }
            } else {
                switch lookup {
                case nil:
                    Text("…").foregroundStyle(secondary)
                case .loaded(let p)?:
                    Text(p.maxMinutes.map { "max \(DurationText.short(minutes: $0))" } ?? "no max").foregroundStyle(secondary)
                case .notFound?:
                    Text("–").foregroundStyle(secondary)
                case .failed?:
                    Text("max ?").foregroundStyle(secondary)
                }
            }
        }
        .monospacedDigit()
        .help(help(lookup))
    }

    private func warning(_ palette: ThemePalette) -> Color {
        switch theme {
        case .native: .orange
        case .azure: palette.warning
        case .windowsXP: checked ? palette.selectionText : palette.warning
        }
    }

    private func help(_ lookup: PolicyLookup?) -> String {
        var lines: [String] = []
        if checked && !role.isActive, let note = model.effectiveDuration(for: role).note { lines.append(note.prefix(1).uppercased() + note.dropFirst() + ".") }
        switch lookup {
        case nil: lines.append("Reading the role's PIM policy…")
        case .notFound?: lines.append("No PIM policy found for this role.")
        case .failed(let message)?: lines.append("Could not read the role's PIM policy: \(message)")
        case .loaded(let p)?:
            var rules = [p.maxMinutes.map { "Longest activation: \(DurationText.short(minutes: $0))" } ?? "No maximum duration"]
            if p.requiresJustification { rules.append("justification required") }
            if p.requiresTicket { rules.append("ticket required") }
            if p.requiresMFA { rules.append("MFA required") }
            if p.authenticationContext != nil { rules.append("authentication context required") }
            if p.requiresApproval { rules.append("approval required") }
            lines.append(rules.joined(separator: " · "))
        }
        return lines.joined(separator: "\n")
    }
}

struct ResultCell: View {
    let progress: RowProgress?
    var checked = false
    @Environment(\.appTheme) private var theme
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        switch progress {
        case nil:
            EmptyView()
        case .queued:
            Text("Queued").foregroundStyle(.secondary)
        case .running:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Activating…").foregroundStyle(.secondary)
            }
        case .done(let outcome) where theme == .azure:
            let palette = ThemePalette(theme, scheme)
            let (symbol, foreground, fill): (String, Color, Color) = switch outcome {
            case .activated: ("checkmark.circle.fill", palette.success, palette.successFill)
            case .alreadyActive: ("arrow.uturn.forward.circle", palette.secondaryText, palette.neutralFill)
            case .policyViolation, .failed: ("xmark.octagon.fill", palette.danger, palette.dangerFill)
            }
            ThemeBadge(text: outcome.summary, symbol: symbol, foreground: foreground, fill: fill, font: palette.font(12))
                .help(detail(outcome))
                .textSelection(.enabled)
        case .done(let outcome):
            let (symbol, color): (String, Color) = switch outcome {
            case .activated: ("checkmark.circle.fill", theme == .windowsXP ? ThemePalette(theme, scheme).success : .green)
            case .alreadyActive: ("arrow.uturn.forward.circle", .secondary)
            case .policyViolation, .failed: ("xmark.octagon.fill", theme == .windowsXP && !checked ? ThemePalette(theme, scheme).danger : .red)
            }
            Label {
                Text(outcome.summary).lineLimit(1).truncationMode(.tail)
            } icon: {
                Image(systemName: symbol).foregroundStyle(color)
            }
            .help(detail(outcome))
            .textSelection(.enabled)
        }
    }

    private func detail(_ outcome: ActivationOutcome) -> String {
        switch outcome {
        case .policyViolation(_, let message), .failed(_, let message): message
        default: outcome.summary
        }
    }
}

// MARK: - Bottom bar

struct ActivationBar: View {
    @Environment(AppModel.self) private var model
    @FocusState private var justificationFocused: Bool

    var body: some View {
        @Bindable var model = model
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    TextField("Justification (required), e.g. INC-1234 investigate database latency", text: $model.justification)
                        .themedTextField(focused: justificationFocused)
                        .textFieldStyle(.roundedBorder)
                        .focused($justificationFocused)
                        .accessibilityLabel("Justification")
                    if !model.recentJustifications.isEmpty {
                        Menu {
                            ForEach(model.recentJustifications, id: \.self) { text in
                                Button(text) { model.justification = text }
                            }
                            Divider()
                            Button("Clear Recent") { model.clearRecentJustifications() }
                        } label: {
                            Image(systemName: "clock.arrow.circlepath")
                        }
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                        .fixedSize()
                        .disabled(model.isActivating)
                        .help("Recent justifications")
                        .accessibilityLabel("Recent justifications")
                    }
                }
                Text(hint)
                    .font(.caption)
                    .foregroundStyle(model.trimmedJustification.isEmpty && !model.checkedRoles.isEmpty ? .red : .secondary)
            }
            .frame(minWidth: 280)

            Picker("Duration", selection: $model.duration) {
                Text("Maximum allowed").tag(RequestedDuration.maximum)
                Divider()
                ForEach(1...ActivationRequestBuilder.maxHours, id: \.self) { h in
                    Text("\(h) h").tag(RequestedDuration.hours(h))
                }
            }
            .fixedSize()
            .help("How long the roles stay active. Each role gets at most what its PIM policy allows: "
                + "see the Duration column. Maximum allowed asks for exactly that.")

            Button {
                model.buildDryRun()
            } label: {
                Label("Preview", systemImage: "eye")
            }
            .themedButton(.secondary)
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .disabled(!model.canActivate)
            .help("Dry run: show the exact requests without sending them (⌥⌘↩)")
            .accessibilityLabel("Preview requests without sending (dry run)")

            Button {
                model.requestActivation()
            } label: {
                if model.isActivating {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Activating…")
                    }
                } else {
                    Text(model.activateTitle)
                }
            }
            .themedButton(.primary(warning: !model.checkedOwnerRoles.isEmpty))
            .buttonStyle(.borderedProminent)
            .tint(model.checkedOwnerRoles.isEmpty ? .accentColor : .orange)
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(!model.canActivate)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .themedBar()
        .background(.bar)
    }

    private var hint: String {
        let n = model.checkedRoles.count
        let owners = model.checkedOwnerRoles.count
        if n == 0 { return "Select roles in the table to activate them." }
        var parts = ["\(n) selected"]
        if owners > 0 { parts.append("\(owners) Owner") }
        let capped = model.cappedCheckedRoles.count
        if capped > 0 { parts.append("\(capped) capped at the policy maximum") }
        if model.trimmedJustification.isEmpty { parts.append("justification required") }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Supporting views

struct BannerView: View {
    let banner: AppModel.Banner
    let dismiss: () -> Void
    @Environment(\.appTheme) private var theme
    @Environment(\.colorScheme) private var scheme

    private var style: (symbol: String, color: Color) {
        switch banner.kind {
        case .info: ("info.circle.fill", .accentColor)
        case .success: ("checkmark.circle.fill", .green)
        case .error: ("exclamationmark.triangle.fill", .orange)
        }
    }

    /// Portal message-bar / XP info-bar colours: (icon, fill).
    private var themedStyle: (icon: Color, fill: Color) {
        let palette = ThemePalette(theme, scheme)
        return switch banner.kind {
        case .info: (palette.accent, palette.infoFill)
        case .success: (palette.success, palette.successFill)
        case .error: (palette.danger, palette.dangerFill)
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: style.symbol).foregroundStyle(theme == .native ? style.color : themedStyle.icon)
            Text(banner.text).textSelection(.enabled)
            Spacer()
            Button(action: dismiss) { Image(systemName: "xmark") }
                .buttonStyle(.borderless)
                .accessibilityLabel("Dismiss")
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(theme == .native ? style.color.opacity(0.12) : themedStyle.fill)
    }
}

struct LoadErrorView: View {
    @Environment(AppModel.self) private var model
    let message: String
    let needsLogin: Bool

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: needsLogin ? "person.crop.circle.badge.exclamationmark" : "exclamationmark.triangle")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(needsLogin ? "Not signed in to \(model.tenantLabel)" : "Could not load roles")
                .font(.title2.weight(.semibold))
            Text(message)
                .font(.callout.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .lineLimit(8)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 620)
            if needsLogin {
                Text("Run this in a terminal, then press Retry:")
                HStack {
                    Text(model.loginCommand)
                        .font(.body.monospaced())
                        .textSelection(.enabled)
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(model.loginCommand, forType: .string)
                    }
                    .themedButton(.secondary)
                    .accessibilityLabel("Copy login command")
                }
            }
            HStack {
                Button("Choose Tenant…") { model.openTenantPicker() }
                    .themedButton(.secondary)
                    .disabled(model.tenant.isOverride)
                Button("Retry") { Task { await model.refresh() } }
                    .themedButton(.primary())
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct DryRunSheet: View {
    let plans: [PlannedRequest]
    @Environment(\.dismiss) private var dismiss

    private var fullText: String {
        plans.map { plan in
            "# \(plan.role.scopeName) / \(plan.role.roleName)\nPUT \(plan.url.absoluteString)\n\(plan.prettyBody)"
        }.joined(separator: "\n\n")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Dry run: \(plans.count) request\(plans.count == 1 ? "" : "s")").font(.headline)
                    Text("Nothing was sent to Azure. Close this and press Activate to send them.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Copy All") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(fullText, forType: .string)
                }
                .themedButton(.secondary)
                Button("Done") { dismiss() }
                    .themedButton(.primary())
                    .keyboardShortcut(.defaultAction)
            }
            .padding(16)
            ThemedDivider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    ForEach(plans) { plan in
                        VStack(alignment: .leading, spacing: 6) {
                            Text("\(plan.role.scopeName) / \(plan.role.roleName)").font(.subheadline.weight(.semibold))
                            Text("PUT \(plan.url.absoluteString)")
                                .font(.caption.monospaced()).foregroundStyle(.secondary)
                            Text(plan.prettyBody)
                                .font(.system(.caption, design: .monospaced))
                                .padding(10)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
                        }
                        .textSelection(.enabled)
                    }
                }
                .padding(16)
            }
        }
        .themedPageBackground()
        .frame(minWidth: 720, idealWidth: 820, minHeight: 480, idealHeight: 640)
    }
}
