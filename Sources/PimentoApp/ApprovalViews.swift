import AppKit
import PimentoCore
import SwiftUI

// The Approvals sheet: requests you can approve or deny as a PIM approver,
// with multi-select, a required justification and confirmations.

struct ApprovalsSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 0) {
            header
            ThemedDivider()
            if let message = model.approvalMessage {
                BannerView(banner: message) { model.approvalMessage = nil }
            }
            content
            if !model.approvalInbox.isEmpty {
                ThemedDivider()
                DecisionBar()
            }
        }
        .themedPageBackground()
        .frame(minWidth: 820, idealWidth: 940, minHeight: 380, idealHeight: 500)
        .alert(confirmationTitle, isPresented: $model.showDecisionConfirmation) {
            Button(model.pendingDecision == .approve ? "Approve" : "Deny", role: .destructive) {
                let decision = model.pendingDecision
                Task { await model.decide(decision) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(confirmationMessage)
        }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Approvals").font(.headline)
                Text("Activation requests you can approve or deny as a PIM approver, from Azure. "
                    + "The first approver's decision counts; requests expire after 24 hours.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button {
                Task { await model.loadApprovals() }
            } label: {
                if model.approvalsLoadState == .loading {
                    ProgressView().controlSize(.small)
                } else {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
            }
            .themedButton(.secondary)
            .disabled(model.approvalsLoadState == .loading || !model.deciding.isEmpty)
            // Secondary: Approve is the sheet's main action.
            Button("Done") { dismiss() }
                .themedButton(.secondary)
                .keyboardShortcut(.cancelAction)
        }
        .padding(16)
    }

    @ViewBuilder private var content: some View {
        switch model.approvalsLoadState {
        case .failed(let message, _) where model.approvalInbox.isEmpty:
            ContentUnavailableView {
                Label("Could not read approvals", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .loading where model.approvalInbox.isEmpty, .idle:
            ProgressView("Reading requests for you to decide…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        default:
            if model.approvalInbox.isEmpty {
                ContentUnavailableView {
                    Label("You have no approvals to review", systemImage: "checkmark.seal")
                } description: {
                    Text(model.approvalInbox.unavailable == nil
                        ? "When someone asks you to approve a role activation, it shows up here."
                        : "Azure lists no approvals for you in \(model.tenantLabel). If you approve PIM requests, check the tenant.")
                }
                .help(model.approvalInbox.unavailable ?? "")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(model.approvalInbox.requests) { request in
                            ApprovalRow(request: request)
                            ThemedDivider()
                        }
                    }
                }
            }
        }
    }

    private var confirmationTitle: String {
        let selected = model.selectedApprovals
        let n = selected.count
        let owners = selected.filter(\.isOwner).count
        let noun = "request\(n == 1 ? "" : "s")"
        switch model.pendingDecision {
        case .approve: return owners > 0 ? "Approve \(n) \(noun), including \(owners) Owner?" : "Approve \(n) \(noun)?"
        case .deny: return "Deny \(n) \(noun)?"
        }
    }

    private var confirmationMessage: String {
        let selected = model.selectedApprovals
        let lines = selected.prefix(10).map { "• \($0.requesterName ?? $0.requesterLabel): \($0.roleName) · \($0.scopeName)" }
        let more = selected.count > 10 ? "\n… and \(selected.count - 10) more" : ""
        let what = model.pendingDecision == .approve
            ? "They get the roles as requested. Owner grants full control of the resource, including access."
            : "They do not get the roles and see your justification."
        return "\(what)\n\n\(lines.joined(separator: "\n"))\(more)\n\nJustification: \(model.trimmedApprovalJustification)"
    }
}

/// One request: checkbox, requester, role, scope, justification, ticket,
/// duration and start, age and expiry, and how deciding it went.
private struct ApprovalRow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.appTheme) private var theme
    @Environment(\.colorScheme) private var scheme
    let request: ApprovalRequest

    private var selected: Bool { model.approvalSelection.contains(request.name) }

    private var detail: String {
        var parts: [String] = []
        if let minutes = request.durationMinutes { parts.append("for \(DurationText.short(minutes: minutes))") }
        if let start = request.start, start > Date().addingTimeInterval(ScheduleTime.immediateSlack) {
            parts.append("from \(model.startLabel(start))")
        }
        if let n = request.ticket { parts.append("ticket \(n.label)") }
        if let j = request.justification { parts.append("“\(j)”") }
        return parts.joined(separator: " · ")
    }

    private var when: String {
        var parts: [String] = []
        if let asked = request.createdOn { parts.append("asked \(ScheduledRowAge.ago(asked))") }
        if let expires = request.expiresAt {
            parts.append(expires > Date() ? "expires in \(DurationText.short(minutes: max(1, Int(expires.timeIntervalSinceNow / 60))))" : "expired")
        }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        let palette = ThemePalette(theme, scheme)
        HStack(alignment: .center, spacing: 12) {
            Toggle(isOn: Binding(get: { selected }, set: { model.setApproval(request, selected: $0) })) { EmptyView() }
                .toggleStyle(.checkbox)
                .labelsHidden()
                .disabled(!model.deciding.isEmpty)
                .accessibilityLabel("Select request of \(request.requesterLabel) for \(request.roleName) on \(request.scopeName)")
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(request.requesterName ?? request.requesterLabel).fontWeight(.semibold)
                    Text("asks for").foregroundStyle(.secondary)
                    Text(request.roleName).fontWeight(request.isOwner ? .semibold : .regular)
                    if request.isOwner {
                        Image(systemName: "crown.fill").foregroundStyle(.orange).imageScale(.small).accessibilityLabel("Owner role")
                    }
                    Text("· \(request.scopeName)").foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
                    .help([detail, request.requesterLabel, "Request \(request.name)", request.scope].joined(separator: "\n"))
            }
            Spacer(minLength: 8)
            Group {
                if theme == .azure {
                    ThemeBadge(text: when, symbol: "hourglass", foreground: palette.accent, fill: palette.infoFill, font: palette.font(12))
                } else {
                    Text(when).foregroundStyle(.secondary).font(.callout)
                }
            }
            .help(request.expiresAt.map { "PIM lets the request expire at \($0.formatted(date: .abbreviated, time: .shortened))" } ?? "")
            trailing.frame(width: 130, alignment: .trailing)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .background(selected ? (theme == .native ? Color.accentColor.opacity(0.12) : palette.selection.opacity(theme == .windowsXP ? 0.2 : 1)) : .clear)
        .contentShape(Rectangle())
        .textSelection(.enabled)
    }

    @ViewBuilder private var trailing: some View {
        if model.deciding.contains(request.name) {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Sending…").foregroundStyle(.secondary)
            }
        } else if let outcome = model.decisionResults[request.name] {
            switch outcome {
            case .decided(let d):
                Label(d == .approve ? "Approved" : "Denied", systemImage: d == .approve ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundStyle(d == .approve ? Color.green : Color.secondary)
            case .notPending, .failed:
                Label(outcome.isAuthFailure ? "Sign in again" : "Not decided", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .help(outcome.summary)
            }
        } else if request.isOwner {
            Text("Owner").font(.caption).foregroundStyle(.orange)
        }
    }
}

/// Justification, Select All, Deny and Approve.
private struct DecisionBar: View {
    @Environment(AppModel.self) private var model
    @Environment(\.appTheme) private var theme

    var body: some View {
        @Bindable var model = model
        let all = model.approvalInbox.requests.count
        let n = model.selectedApprovals.count
        let owners = model.selectedApprovals.filter(\.isOwner).count
        HStack(spacing: 12) {
            Toggle("All", isOn: Binding(get: { n == all && all > 0 }, set: { model.selectAllApprovals($0) }))
                .toggleStyle(.checkbox)
                .disabled(!model.deciding.isEmpty)
                .help("Select every request")
            TextField("Justification (required; the requester sees it)", text: $model.approvalJustification)
                .themedTextField()
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Justification for the decision")
            Text(n == 0 ? "None selected" : "\(n) selected")
                .foregroundStyle(.secondary)
                .fixedSize()
            Button("Deny\(n > 1 ? " \(n)" : "")…") { model.requestDecision(.deny) }
                .themedButton(.secondary)
                .disabled(!model.canDecide)
                .help("Deny the selected requests (asks first)")
            Button(model.prefs.confirmOwnerRoles && owners > 0 ? "Approve\(n > 1 ? " \(n)" : "")…" : "Approve\(n > 1 ? " \(n)" : "")") {
                model.requestDecision(.approve)
            }
            .themedButton(.primary(warning: owners > 0))
            .buttonStyle(.borderedProminent)
            .tint(theme == .native && owners > 0 ? .orange : nil)
            .disabled(!model.canDecide)
            .keyboardShortcut(.defaultAction)
            .help(owners > 0 ? "Approve the selected requests, including \(owners) Owner role\(owners == 1 ? "" : "s") (asks first)" : "Approve the selected requests")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .themedBar()
    }
}

/// "12 min ago".
enum ScheduledRowAge {
    static func ago(_ date: Date) -> String {
        let minutes = Int(Date().timeIntervalSince(date) / 60)
        return minutes < 1 ? "just now" : "\(DurationText.short(minutes: minutes)) ago"
    }
}
