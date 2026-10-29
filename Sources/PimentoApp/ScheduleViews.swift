import AppKit
import PimentoCore
import SwiftUI

// Scheduled activations (a later start, the Scheduled sheet) and ticket
// information (number and system) in the bottom bar.

// MARK: - Start menu

/// "Start: Now" / "Start: Fri 08:00" in the bottom bar, with quick choices
/// and a date picker. Local time zone; PIM accepts up to a month ahead.
struct StartMenu: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        HStack(spacing: 2) {
            Menu {
                Button("Now") { model.setStart(nil) }
                Divider()
                ForEach(ScheduleTime.Preset.allCases, id: \.self) { preset in
                    Button(preset.title) { model.setStart(preset.date(now: Date())) }
                }
                Divider()
                Button("Pick Date and Time…") { model.openStartPicker() }
            } label: {
                Label(model.scheduleStart.map { "Start: \(model.startLabel($0))" } ?? "Start: Now",
                      systemImage: model.scheduleStart == nil ? "play.circle" : "calendar.badge.clock")
            }
            .fixedSize()
            .help(model.scheduleStart.map {
                "Scheduled: PIM activates the roles at \($0.formatted(date: .complete, time: .shortened)). "
                    + "Choose Now to activate right away."
            } ?? "Activate now, or schedule the activation for later (up to \(ScheduleTime.maxDaysAhead) days ahead)")
            .accessibilityLabel(model.scheduleStart.map { "Start \(model.startLabel($0))" } ?? "Start now")
            if model.scheduleStart != nil {
                Button {
                    model.setStart(nil)
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help("Start now instead")
                .accessibilityLabel("Start now instead")
            }
        }
        .disabled(model.isActivating)
        .popover(isPresented: $model.showStartPicker, arrowEdge: .top) {
            StartPicker()
                .environment(model)
                .appAppearanceInPopover()
        }
    }
}

private struct StartPicker: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 10) {
            Text("Start the activation at").font(.headline)
            // The calendar for the day, a field for the time: the analog
            // clock of the graphical style is hard to set to the minute.
            DatePicker("Day", selection: $model.startPickerDraft, in: Date()...model.latestStart,
                       displayedComponents: [.date])
                .datePickerStyle(.graphical)
                .labelsHidden()
            DatePicker("Time", selection: $model.startPickerDraft, displayedComponents: [.hourAndMinute])
                .datePickerStyle(.field)
                .fixedSize()
            Text("\(model.startLabel(model.startPickerDraft)) · \(TimeZone.current.localizedName(for: .shortStandard, locale: .current) ?? TimeZone.current.identifier)")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { model.showStartPicker = false }
                    .themedButton(.secondary)
                    .keyboardShortcut(.cancelAction)
                Button("Schedule") {
                    model.setStart(model.startPickerDraft)
                    model.showStartPicker = false
                }
                .themedButton(.primary())
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(14)
        .frame(width: 260)
    }
}

// MARK: - Ticket fields

/// Ticket number and system, with recent tickets, under the justification.
struct TicketFields: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        let needed = !model.checkedRolesNeedingTicket.isEmpty
        HStack(spacing: 4) {
            Image(systemName: "ticket")
                .foregroundStyle(needed ? Color.orange : .secondary)
                .help(needed ? "\(model.checkedRolesNeedingTicket.count) checked role(s) need a ticket" : "Optional ticket information")
                .accessibilityHidden(true)
            TextField(needed ? "Ticket number (required)" : "Ticket number (optional)", text: $model.ticketNumber)
                .themedTextField()
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 120)
                .accessibilityLabel("Ticket number")
            TextField("Ticket system, e.g. ServiceNow", text: $model.ticketSystem)
                .themedTextField()
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 120)
                .accessibilityLabel("Ticket system")
            if !model.recentTickets.isEmpty {
                Menu {
                    ForEach(model.recentTickets, id: \.self) { ticket in
                        Button(ticket.label) { model.useRecentTicket(ticket) }
                    }
                    Divider()
                    Button("Clear Recent") { model.clearRecentTickets() }
                } label: {
                    Image(systemName: "clock.arrow.circlepath")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .disabled(model.isActivating)
                .help("Recent tickets")
                .accessibilityLabel("Recent tickets")
            }
            if !needed {
                Button {
                    model.ticketNumber = ""
                    model.showTicketFields = false
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help("No ticket")
                .accessibilityLabel("Remove ticket")
            }
        }
    }
}

// MARK: - Scheduled sheet

/// Your activations that have not started yet, from Azure, with Cancel.
struct ScheduledSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appTheme) private var theme
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Scheduled Activations").font(.headline)
                    Text("From Azure: activations that start later, and requests waiting for approval "
                        + "(Pimento checks those every minute and notifies you of the decision). "
                        + "Cancelling one does not touch a role that is active now.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button {
                    Task { await model.loadScheduled() }
                } label: {
                    if model.scheduledLoadState == .loading {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                }
                .themedButton(.secondary)
                .disabled(model.scheduledLoadState == .loading)
                Button("Done") { dismiss() }
                    .themedButton(.primary())
                    .keyboardShortcut(.defaultAction)
            }
            .padding(16)
            ThemedDivider()
            content
            if model.scheduledRequests.count > 1 {
                ThemedDivider()
                HStack {
                    Text("\(model.scheduledRequests.count) requests").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Cancel All…", role: .destructive) { model.showCancelAllConfirmation = true }
                        .themedButton(.secondary)
                        .disabled(!model.cancelling.isEmpty)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            }
        }
        .themedPageBackground()
        .frame(minWidth: 760, idealWidth: 860, minHeight: 360, idealHeight: 460)
        .alert("Cancel all \(model.scheduledRequests.count) scheduled activations?", isPresented: $model.showCancelAllConfirmation) {
            Button("Cancel All", role: .destructive) {
                let all = model.scheduledRequests
                Task { await model.cancelScheduled(all) }
            }
            Button("Keep", role: .cancel) {}
        } message: {
            Text("The roles will not be activated at their start times. You can schedule them again.")
        }
    }

    @ViewBuilder private var content: some View {
        switch model.scheduledLoadState {
        case .failed(let message, _) where model.scheduledRequests.isEmpty:
            ContentUnavailableView {
                Label("Could not read your requests", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .loading where model.scheduledRequests.isEmpty, .idle:
            ProgressView("Reading your requests…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        default:
            if model.scheduledRequests.isEmpty {
                ContentUnavailableView {
                    Label("Nothing scheduled", systemImage: "calendar")
                } description: {
                    Text("Choose a start under Start in the bottom bar, then press Schedule.")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(model.scheduledRequests) { request in
                            ScheduledRow(request: request)
                            ThemedDivider()
                        }
                    }
                }
            }
        }
    }
}

private struct ScheduledRow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.appTheme) private var theme
    @Environment(\.colorScheme) private var scheme
    @Environment(\.ultraDark) private var ultra
    let request: ScheduledRequest

    private var whenText: String {
        guard request.kind == .scheduled else {
            var parts = ["Awaiting approval"]
            if let asked = request.createdOn { parts.append("asked \(ScheduledRowAge.ago(asked))") }
            if let expires = request.expiresAt {
                parts.append(expires > Date() ? "expires in \(DurationText.short(minutes: max(1, Int(expires.timeIntervalSinceNow / 60))))" : "expired")
            }
            return parts.joined(separator: " · ")
        }
        let left = DurationText.short(minutes: max(1, Int(request.start.timeIntervalSinceNow / 60)))
        return "Starts \(model.startLabel(request.start)) · in \(left)"
    }

    private var detail: String {
        var parts: [String] = []
        if let minutes = request.durationMinutes { parts.append("for \(DurationText.short(minutes: minutes))") }
        if let j = request.justification { parts.append("“\(j)”") }
        if let n = request.ticketNumber { parts.append("ticket \(TicketInfo(number: n, system: request.ticketSystem).label)") }
        parts.append(request.status)
        return parts.joined(separator: " · ")
    }

    var body: some View {
        let palette = ThemePalette(theme, scheme, ultra: ultra)
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: request.kind == .scheduled ? "calendar.badge.clock" : "hourglass")
                .font(.title3)
                .foregroundStyle(theme == .native ? Color.accentColor : palette.accent)
                .frame(width: 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(request.roleName).fontWeight(request.isOwner ? .semibold : .regular).lineLimit(1)
                    if request.isOwner {
                        Image(systemName: "crown.fill").foregroundStyle(.orange).imageScale(.small).accessibilityLabel("Owner role")
                    }
                    Text("· \(request.scopeName)").foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
                    .help(detail + "\nRequest \(request.name)\n\(request.scope)")
            }
            Spacer(minLength: 8)
            Group {
                if theme == .azure {
                    ThemeBadge(text: whenText, symbol: nil, foreground: palette.accent, fill: palette.infoFill, font: palette.font(12))
                } else {
                    Text(whenText).foregroundStyle(.secondary)
                }
            }
            .help(request.kind == .scheduled
                ? request.start.formatted(date: .complete, time: .shortened)
                : "Waiting for an approver, who has 24 hours to decide. Pimento checks every minute and notifies you of the decision.")
            trailing.frame(width: 150, alignment: .trailing)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .textSelection(.enabled)
    }

    @ViewBuilder private var trailing: some View {
        if model.cancelling.contains(request.name) {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Cancelling…").foregroundStyle(.secondary)
            }
        } else if let outcome = model.cancelResults[request.name], outcome != .canceled {
            Label("Not cancelled", systemImage: "xmark.octagon.fill")
                .foregroundStyle(.red)
                .help(outcome.summary)
        } else {
            Button("Cancel") { Task { await model.cancelScheduled([request]) } }
                .themedButton(.secondary)
                .help(request.kind == .scheduled
                ? "Cancel this request: the role will not be activated at \(model.startLabel(request.start))"
                : "Withdraw this request: approvers no longer see it")
        }
    }
}
