import AppKit
import PimentoCore
import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            if let banner = model.banner {
                BannerView(banner: banner) { model.banner = nil }
            }
            content
            Divider()
            ActivationBar()
        }
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
                            .disabled(model.tenant.isOverride)
                    }
                } else if model.visibleRoles.isEmpty {
                    ContentUnavailableView.search(text: model.search)
                } else {
                    RoleTable()
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
            + "(\(total) role\(total == 1 ? "" : "s") in total) for \(model.hours) h:\n\n\(names)\(more)"
            + "\n\nJustification: \(model.trimmedJustification)"
    }
}

// MARK: - Table

struct RoleTable: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Table(model.visibleRoles, sortOrder: $model.sortOrder, columnCustomization: $model.columnCustomization) {
            TableColumn("") { (role: EligibleRole) in
                Toggle("", isOn: Binding(
                    get: { model.isChecked(role) },
                    set: { model.setChecked(role, $0) }
                ))
                .labelsHidden()
                .disabled(role.isActive || model.isActivating)
                .help(role.isActive ? "Already active" : "Select for activation")
                .accessibilityLabel("Select \(role.roleName) on \(role.scopeName)")
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
            }
            .width(min: 160, ideal: 260)
            .customizationID("resource")
            .disabledCustomizationBehavior(.visibility)

            TableColumn("Type", value: \.scopeTypeLabel) { role in
                Text(role.scopeTypeLabel).lineLimit(1)
            }
            .width(min: 80, ideal: 110)
            .customizationID(AppModel.Column.type.rawValue)

            TableColumn("Membership", value: \.membership.label) { role in
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
            .width(min: 80, ideal: 150)
            .customizationID(AppModel.Column.membership.rawValue)

            TableColumn("Cond.") { role in
                if role.hasCondition {
                    Image(systemName: "lock.shield")
                        .foregroundStyle(.secondary)
                        .help("ABAC condition (copied verbatim on activation):\n\(role.condition ?? "")")
                        .accessibilityLabel("Has an ABAC condition")
                }
            }
            .width(44)
            .customizationID(AppModel.Column.condition.rawValue)

            TableColumn("Status", value: \.statusSortKey) { role in
                StatusCell(role: role)
            }
            .width(min: 110, ideal: 150)
            .customizationID("status")
            .disabledCustomizationBehavior(.visibility)

            TableColumn("Result") { role in
                ResultCell(progress: model.progress[role.id])
            }
            .width(min: 120, ideal: 260)
            .customizationID("result")
            .disabledCustomizationBehavior(.visibility)
        }
        .tableStyle(.inset(alternatesRowBackgrounds: true))
    }
}

struct StatusCell: View {
    let role: EligibleRole

    var body: some View {
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

struct ResultCell: View {
    let progress: RowProgress?

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
        case .done(let outcome):
            let (symbol, color): (String, Color) = switch outcome {
            case .activated: ("checkmark.circle.fill", .green)
            case .alreadyActive: ("arrow.uturn.forward.circle", .secondary)
            case .policyViolation, .failed: ("xmark.octagon.fill", .red)
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

            Picker("Duration", selection: $model.hours) {
                ForEach(1...ActivationRequestBuilder.maxHours, id: \.self) { h in
                    Text("\(h) h").tag(h)
                }
            }
            .fixedSize()
            .help("How long the roles stay active. Each role's PIM policy sets its own maximum (8 h unless changed).")

            Button {
                model.buildDryRun()
            } label: {
                Label("Preview", systemImage: "eye")
            }
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
            .buttonStyle(.borderedProminent)
            .tint(model.checkedOwnerRoles.isEmpty ? .accentColor : .orange)
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(!model.canActivate)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.bar)
    }

    private var hint: String {
        let n = model.checkedRoles.count
        let owners = model.checkedOwnerRoles.count
        if n == 0 { return "Select roles in the table to activate them." }
        var parts = ["\(n) selected"]
        if owners > 0 { parts.append("\(owners) Owner") }
        if model.trimmedJustification.isEmpty { parts.append("justification required") }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Supporting views

struct BannerView: View {
    let banner: AppModel.Banner
    let dismiss: () -> Void

    private var style: (symbol: String, color: Color) {
        switch banner.kind {
        case .info: ("info.circle.fill", .accentColor)
        case .success: ("checkmark.circle.fill", .green)
        case .error: ("exclamationmark.triangle.fill", .orange)
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: style.symbol).foregroundStyle(style.color)
            Text(banner.text).textSelection(.enabled)
            Spacer()
            Button(action: dismiss) { Image(systemName: "xmark") }
                .buttonStyle(.borderless)
                .accessibilityLabel("Dismiss")
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(style.color.opacity(0.12))
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
                    .accessibilityLabel("Copy login command")
                }
            }
            HStack {
                Button("Choose Tenant…") { model.openTenantPicker() }
                    .disabled(model.tenant.isOverride)
                Button("Retry") { Task { await model.refresh() } }
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
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(16)
            Divider()
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
        .frame(minWidth: 720, idealWidth: 820, minHeight: 480, idealHeight: 640)
    }
}
