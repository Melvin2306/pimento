import AppKit
import PimentoCore
import SwiftUI

// The History sheet (⇧⌘H): what this app and the CLI sent, from the shared
// history file, with filters, Export CSV, Import from Azure and "Activate Again".

struct HistorySheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            ThemedDivider()
            HistoryFilterBar()
            ThemedDivider()
            if let message = model.historyMessage {
                BannerView(banner: message) { model.historyMessage = nil }
            }
            content
            ThemedDivider()
            footer
        }
        .themedPageBackground()
        .frame(minWidth: 1000, idealWidth: 1240, minHeight: 440, idealHeight: 580)
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text("History").font(.headline)
                Text("Every request Pimento sent from this Mac, from the app and the command line, and how Azure answered. "
                    + "Import from Azure adds your requests from the portal and other tools.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button {
                Task { await model.importHistoryFromAzure() }
            } label: {
                if model.historyImportState == .loading {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Importing…")
                    }
                } else {
                    Label("Import from Azure", systemImage: "icloud.and.arrow.down")
                }
            }
            .themedButton(.secondary)
            .disabled(model.historyImportState == .loading || model.tenantError != nil)
            .help("Read your past requests in \(model.tenantLabel) from Azure (read-only) and add the ones missing here")
            Button {
                model.exportHistoryCSV()
            } label: {
                Label("Export CSV…", systemImage: "square.and.arrow.up")
            }
            .themedButton(.secondary)
            .disabled(model.visibleHistory.isEmpty)
            .help("Save the rows shown, as filtered and sorted, as a CSV file")
            Button("Done") { dismiss() }
                .themedButton(.primary())
                .keyboardShortcut(.defaultAction)
        }
        .padding(16)
    }

    // Plain stacks rather than ContentUnavailableView: next to the filter bar,
    // that one sends SwiftUI's layout into attribute-graph cycles.
    @ViewBuilder private var content: some View {
        if model.historyRecords.isEmpty {
            if !model.historySettings.enabled {
                HistoryEmptyState(
                    title: "History is off", symbol: "clock.badge.xmark",
                    text: "Pimento does not record what it sends. Turn it on to keep a log on this Mac, shared with the command line."
                ) {
                    Button("Turn On") { model.historySettings.enabled = true }
                        .themedButton(.primary())
                }
            } else {
                HistoryEmptyState(
                    title: "No history yet", symbol: "clock.arrow.circlepath",
                    text: "Activations, schedules, renewals, cancellations and approvals made with Pimento show up here. "
                        + "Import from Azure adds what you requested elsewhere.") { EmptyView() }
            }
        } else if model.visibleHistory.isEmpty {
            HistoryEmptyState(title: "Nothing matches", symbol: "line.3.horizontal.decrease.circle",
                              text: "No history entry matches the filters.") {
                Button("Show All") { model.resetHistoryFilters() }
                    .themedButton(.secondary)
            }
        } else {
            HistoryTable()
                .themedListArea()
        }
    }

    private var footer: some View {
        let shown = model.visibleHistory.count
        let total = model.historyRecords.count
        return HStack(spacing: 10) {
            Text(shown == total ? "\(total) record\(total == 1 ? "" : "s")" : "\(shown) of \(total) records")
                .foregroundStyle(.secondary)
            if !model.historySettings.enabled {
                Label("Recording is off", systemImage: "pause.circle")
                    .foregroundStyle(.orange)
                    .help("Turn it on in Settings › History")
            }
            Spacer()
            Text(model.historyStore.url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                .font(.caption).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.middle)
                .textSelection(.enabled)
            Button("Show in Finder") { model.showHistoryInFinder() }
                .themedButton(.secondary)
        }
        .font(.callout)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .themedBar()
    }
}

/// A symbol, a title, a line of text and optional actions, centred.
private struct HistoryEmptyState<Actions: View>: View {
    let title: String
    let symbol: String
    let text: String
    @ViewBuilder let actions: () -> Actions

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 36))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(title).font(.title3.weight(.semibold))
            Text(text)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)
            actions()
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Search, period, action, outcome and tenant.
private struct HistoryFilterBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                TextField("Search role, resource, justification, ticket, request id", text: $model.historySearch)
                    .themedTextField()
                    .textFieldStyle(.roundedBorder)
                    .frame(minWidth: 220)
                    .accessibilityLabel("Search the history")
                Picker("Period", selection: $model.historyPeriod) {
                    ForEach(HistoryPeriod.allCases.filter { $0 != .custom }, id: \.self) { period in
                        Text(period.title).tag(period)
                    }
                    Divider()
                    Text(HistoryPeriod.custom.title).tag(HistoryPeriod.custom)
                }
                .fixedSize()
                Picker("Action", selection: $model.historyAction) {
                    Text("All").tag(HistoryAction?.none)
                    Divider()
                    ForEach(HistoryAction.known, id: \.self) { action in
                        Text(action.title).tag(Optional(action))
                    }
                }
                .fixedSize()
                Picker("Outcome", selection: $model.historyResult) {
                    Text("All").tag(HistoryResult?.none)
                    Divider()
                    ForEach(HistoryResult.known.filter { $0 != .unknown }, id: \.self) { result in
                        Text(result.title).tag(Optional(result))
                    }
                }
                .fixedSize()
                let tenants = model.historyTenants
                if tenants.count > 1 || model.historyTenant != nil {
                    Picker("Tenant", selection: $model.historyTenant) {
                        Text("All").tag(String?.none)
                        Divider()
                        ForEach(tenants, id: \.id) { tenant in
                            Text(tenant.label).tag(Optional(tenant.id))
                        }
                    }
                    .fixedSize()
                }
                Spacer(minLength: 0)
                if model.historyFiltersActive {
                    Button("Show All") { model.resetHistoryFilters() }
                        .themedButton(.secondary)
                        .help("Clear the search and filters")
                }
            }
            if model.historyPeriod == .custom {
                HStack(spacing: 10) {
                    DatePicker("From", selection: $model.historyFrom, displayedComponents: [.date])
                        .datePickerStyle(.field)
                        .fixedSize()
                    DatePicker("To", selection: $model.historyTo, displayedComponents: [.date])
                        .datePickerStyle(.field)
                        .fixedSize()
                    Text("Whole days, local time").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

extension HistoryRecord {
    /// Sort keys for the table (KeyPathComparator needs non-optional values).
    var sourceSortKey: String { source.rawValue }
    var durationSortKey: Int { durationMinutes ?? (requestedDuration == "max" ? Int.max : -1) }
    var justificationSortKey: String { justification ?? "" }
    var requestSortKey: String { requestId ?? "" }
}

private struct HistoryTable: View {
    @Environment(AppModel.self) private var model
    @Environment(\.appTheme) private var theme

    var body: some View {
        switch theme {
        case .windowsXP: table.tableStyle(.bordered(alternatesRowBackgrounds: false))
        case .azure: table.tableStyle(.inset(alternatesRowBackgrounds: false))
        case .native: table.tableStyle(.inset(alternatesRowBackgrounds: true))
        }
    }

    private var table: some View {
        @Bindable var model = model
        let rows = model.visibleHistory
        return Table(rows, selection: $model.historySelection, sortOrder: $model.historySortOrder) {
            TableColumn("When", value: \.at) { (r: HistoryRecord) in
                WhenCell(date: r.at)
            }
            .width(min: 140, ideal: 168)

            TableColumn("Action", value: \.action) { r in
                Text(r.action.title).lineLimit(1)
                    .help(r.status.map { "\(r.action.title) · Azure status: \($0)" } ?? r.action.title)
            }
            .width(min: 64, ideal: 74)

            TableColumn("Outcome", value: \.result) { r in
                HistoryResultCell(record: r)
            }
            .width(min: 86, ideal: 100)

            TableColumn("Role", value: \.roleDisplay) { r in
                HStack(spacing: 4) {
                    Text(r.roleDisplay).fontWeight(r.isOwner ? .semibold : .regular).lineLimit(1)
                    if r.isOwner {
                        Image(systemName: "crown.fill").foregroundStyle(.orange).imageScale(.small).accessibilityLabel("Owner role")
                    }
                }
                .help(r.requester.map { "\(r.roleDisplay), requested by \($0)" } ?? r.roleDisplay)
            }
            .width(min: 80, ideal: 112)

            TableColumn("Resource", value: \.scopeDisplay) { r in
                Text(r.scopeDisplay).lineLimit(1).truncationMode(.middle)
                    .help("\(r.scopeDisplay)\n\(r.scope)")
            }
            .width(min: 100, ideal: 150)

            TableColumn("Tenant", value: \.tenantDisplay) { r in
                Text(r.tenantDisplay).lineLimit(1).foregroundStyle(.secondary)
                    .help(r.tenantId ?? "")
            }
            .width(min: 60, ideal: 76)

            TableColumn("Duration", value: \.durationSortKey) { r in
                Text(r.durationText ?? "").foregroundStyle(.secondary).lineLimit(1)
                    .help(r.start.map { start in
                        "From \(start.formatted(date: .abbreviated, time: .shortened))"
                            + (r.end.map { " to \($0.formatted(date: .abbreviated, time: .shortened))" } ?? "")
                    } ?? "")
            }
            .width(min: 50, ideal: 60)

            TableColumn("Justification", value: \.justificationSortKey) { r in
                Text(justification(r)).lineLimit(1).truncationMode(.tail)
                    .help(justification(r))
            }
            .width(min: 100, ideal: 160)

            TableColumn("Source", value: \.sourceSortKey) { r in
                Text(r.source.title).foregroundStyle(.secondary).lineLimit(1)
                    .help(r.version.map { "\(r.source.title), Pimento \($0)" } ?? "Read from Azure")
            }
            .width(min: 40, ideal: 46)

            TableColumn("Request", value: \.requestSortKey) { r in
                Text(r.shortRequestId ?? "").font(.system(.body, design: .monospaced)).foregroundStyle(.secondary)
                    .help(r.requestId ?? "")
            }
            .width(min: 70, ideal: 78)
        }
        .contextMenu(forSelectionType: HistoryRecord.ID.self) { ids in
            menu(ids)
        }
    }

    private func justification(_ r: HistoryRecord) -> String {
        [r.justification, r.ticket.map { "ticket \($0.label)" }].compactMap { $0 }.joined(separator: " · ")
    }

    @ViewBuilder private func menu(_ ids: Set<HistoryRecord.ID>) -> some View {
        if let id = ids.first, ids.count == 1, let record = model.historyRecords.first(where: { $0.id == id }) {
            if record.action.isActivation {
                Button("Activate Again") { model.activateAgain(record) }
                    .disabled(!model.canActivateAgain(record))
                Divider()
            }
            if let requestId = record.requestId {
                Button("Copy Request ID") { copy(requestId) }
            }
            if let justification = record.justification {
                Button("Copy Justification") { copy(justification) }
            }
            if !record.scope.isEmpty {
                Button("Copy Scope") { copy(record.scope) }
            }
        } else if ids.count > 1 {
            let ids = model.historyRecords.filter { ids.contains($0.id) }.compactMap(\.requestId)
            Button("Copy \(ids.count) Request IDs") { copy(ids.joined(separator: "\n")) }
                .disabled(ids.isEmpty)
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

/// `Oct 28, 09:00` with "2 days ago" beside it.
private struct WhenCell: View {
    let date: Date

    var body: some View {
        HStack(spacing: 6) {
            Text(date.formatted(.dateTime.month(.abbreviated).day()) + " " + date.formatted(date: .omitted, time: .shortened)).lineLimit(1)
            Text(Self.relative(date))
                .foregroundStyle(.secondary).lineLimit(1)
        }
        .help(date.formatted(date: .complete, time: .standard))
    }

    /// "2 days ago", against the app's clock (the demo's may differ).
    static func relative(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.dateTimeStyle = .named
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: AppClock.now())
    }
}

/// The outcome as a coloured label (an Azure-style badge in that theme).
private struct HistoryResultCell: View {
    let record: HistoryRecord
    @Environment(\.appTheme) private var theme
    @Environment(\.colorScheme) private var scheme
    @Environment(\.ultraDark) private var ultra

    private var symbol: String {
        switch record.result {
        case .succeeded: "checkmark.circle.fill"
        case .pending: "hourglass"
        case .skipped: "arrow.uturn.forward.circle"
        case .failed: "xmark.octagon.fill"
        case .denied: "hand.raised.fill"
        case .canceled: "minus.circle"
        case .expired: "clock.badge.xmark"
        default: "questionmark.circle"
        }
    }

    private var detail: String {
        [record.status, record.message].compactMap { $0 }.joined(separator: ": ")
    }

    var body: some View {
        let palette = ThemePalette(theme, scheme, ultra: ultra)
        Group {
            if theme == .azure {
                let (foreground, fill): (Color, Color) = switch record.result {
                case .succeeded: (palette.success, palette.successFill)
                case .pending: (palette.warning, palette.warningFill)
                case .failed, .denied, .expired: (palette.danger, palette.dangerFill)
                default: (palette.secondaryText, palette.neutralFill)
                }
                ThemeBadge(text: record.result.title, symbol: symbol, foreground: foreground, fill: fill, font: palette.font(12))
            } else {
                let xp = theme == .windowsXP
                let color: Color = switch record.result {
                case .succeeded: xp ? palette.success : .green
                case .pending: xp ? palette.warning : .orange
                case .failed, .denied, .expired: xp ? palette.danger : .red
                default: .secondary
                }
                Label {
                    Text(record.result.title).lineLimit(1)
                } icon: {
                    Image(systemName: symbol).foregroundStyle(color)
                }
            }
        }
        .help(detail.isEmpty ? record.result.title : detail)
    }
}

// MARK: - Settings

/// Settings › History.
struct HistorySettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        SettingsPaneContainer {
            SettingsColumns(trailingLabelWidth: 64) {
                SettingsGroup("Recording") {
                    SettingsRow {
                        HStack(spacing: 6) {
                            Toggle("Keep a history of what Pimento sends", isOn: $model.historySettings.enabled)
                            InfoButton("Activations, schedules, renewals, extensions, cancellations, approvals and denials, from the app and the "
                                + "pimento command, with their outcome, justification and ticket. Never tokens or request bodies.",
                                label: "About the history")
                        }
                    }
                    HStack(spacing: 8) {
                        Text("Keep records for:")
                        Picker("Keep records for", selection: $model.historySettings.retention) {
                            ForEach(HistoryRetention.allCases, id: \.self) { r in Text(r.title).tag(r) }
                        }
                        .labelsHidden()
                        .fixedSize()
                    }
                    .disabled(!model.historySettings.enabled)
                    .settingsIndent()
                    SettingsRow {
                        SettingsNote("Older records are removed; past 5 MB the file starts over, keeping one previous file.")
                    }
                }
            } trailing: {
                SettingsGroup("File") {
                    SettingsRow("Location") {
                        Text(model.historyStore.url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                            .lineLimit(1).truncationMode(.middle)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .help(model.historyStore.url.path)
                    }
                    SettingsRow("Records") {
                        Text("\(model.historyRecords.count)").foregroundStyle(.secondary).monospacedDigit()
                    }
                    SettingsRow {
                        HStack {
                            Button("Show in Finder") { model.showHistoryInFinder() }
                            Button("Clear History…") { model.showClearHistoryConfirmation = true }
                                .disabled(model.historyRecords.isEmpty)
                        }
                    }
                    SettingsRow {
                        HStack(spacing: 4) {
                            SettingsNote("Only you can read it; shared with pimento history.")
                                .fixedSize()
                            InfoButton("Readable only by you (mode 600) and shared with the command line (pimento history); "
                                + "$\(HistoryStore.environmentVariable) points both elsewhere.", label: "About the history file")
                        }
                    }
                }
            }
        }
        .onAppear { model.reloadHistory() }
        .confirmationDialog("Clear the history?", isPresented: $model.showClearHistoryConfirmation) {
            Button("Clear History", role: .destructive) { model.clearHistory() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("All \(model.historyRecords.count) records are deleted from this Mac, for the app and the command line. "
                + "Nothing changes in Azure; Import from Azure can bring your requests back.")
        }
    }
}
