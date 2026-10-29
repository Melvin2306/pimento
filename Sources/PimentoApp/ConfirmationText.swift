import Foundation
import PimentoCore

// The texts of the Owner, End Now and Renew confirmations: the main window's
// alerts and the menu bar popover's inline confirmations show the same.

extension AppModel {
    private func roleList(_ roles: [EligibleRole]) -> String {
        let lines = roles.prefix(12).map { "• \($0.roleName) · \($0.scopeName)" }
        return (lines + (roles.count > 12 ? ["… and \(roles.count - 12) more"] : [])).joined(separator: "\n")
    }

    private func notNowText(_ selection: RoleLifecycle.Selection, renewal: Bool) -> String {
        var parts: [String] = []
        if !selection.tooSoon.isEmpty {
            let at = selection.tooSoon.compactMap(RoleLifecycle.earliestDeactivation(of:)).max()
            parts.append("\(selection.tooSoon.count) activated less than 5 minutes ago cannot be ended yet"
                + (at.map { " (from \($0.formatted(date: .omitted, time: .shortened)))" } ?? "") + ".")
        }
        if renewal, !selection.needsApproval.isEmpty {
            parts.append("\(selection.needsApproval.count) need\(selection.needsApproval.count == 1 ? "s" : "") approval to activate, so \(selection.needsApproval.count == 1 ? "it is" : "they are") not renewed.")
        }
        if renewal, !selection.needsTicket.isEmpty {
            let n = selection.needsTicket.count
            parts.append("\(n) need\(n == 1 ? "s" : "") a ticket and the current activation's is unknown, so \(n == 1 ? "it is" : "they are") not renewed: fill in ticket number and system first.")
        }
        return parts.isEmpty ? "" : "\n\n" + parts.joined(separator: "\n")
    }

    /// The tickets the renewed activations carry (fields, or the original ones).
    private func renewTicketText(_ selection: RoleLifecycle.Selection) -> String {
        let labels = Set(selection.ready.compactMap { renewalTicket(for: $0)?.label }).sorted()
        return labels.isEmpty ? "" : "\nTicket: " + labels.joined(separator: ", ")
    }

    var deactivateConfirmationTitle: String {
        let n = lifecycleSelection(forRenewal: false).ready.count
        return n == 0 ? "Nothing to end yet" : "End \(n) active role\(n == 1 ? "" : "s") now?"
    }

    var deactivateConfirmationMessage: String {
        let selection = lifecycleSelection(forRenewal: false)
        return "Your access through \(selection.ready.count == 1 ? "this role" : "these roles") ends now:\n\n"
            + roleList(selection.ready) + notNowText(selection, renewal: false)
    }

    var renewConfirmationTitle: String {
        let selection = lifecycleSelection(forRenewal: true)
        let owners = selection.ready.filter(\.isOwner).count
        let n = selection.ready.count
        if n == 0 { return "Nothing to renew now" }
        return owners > 0 ? "Renew \(n) role\(n == 1 ? "" : "s"), including \(owners) Owner?" : "Renew \(n) role\(n == 1 ? "" : "s")?"
    }

    var renewConfirmationMessage: String {
        let selection = lifecycleSelection(forRenewal: true)
        let durations = Set(selection.ready.map { effectiveDuration(for: $0).minutes })
        let longest = durations.max().map { DurationText.short(minutes: $0) } ?? duration.label
        return "Each role is ended and activated again for \(durations.count > 1 ? "up to " : "")\(longest). "
            + "In between it is NOT active: PIM accepts the new activation only once it has removed the old one, "
            + "typically after 1–3 minutes (Pimento keeps trying for 5). Operations that need the role fail meanwhile. "
            + "If activating again fails, the role stays off.\n\n"
            + roleList(selection.ready)
            + "\n\nJustification: \(trimmedJustification)"
            + renewTicketText(selection)
            + notNowText(selection, renewal: true)
    }

    var ownerConfirmationTitle: String {
        let n = checkedOwnerRoles.count
        return "\(scheduleStart == nil ? "Activate" : "Schedule") \(n) Owner role\(n == 1 ? "" : "s")?"
    }

    var ownerConfirmationMessage: String {
        let owners = checkedOwnerRoles
        let names = owners.prefix(12).map { "• \($0.scopeName)" }.joined(separator: "\n")
        let more = owners.count > 12 ? "\n… and \(owners.count - 12) more" : ""
        let total = checkedRoles.count
        let when = scheduleStart.map { ", starting \(startLabel($0))" } ?? ""
        return "You are about to \(scheduleStart == nil ? "activate" : "schedule") \(owners.count) Owner role\(owners.count == 1 ? "" : "s") "
            + "(\(total) role\(total == 1 ? "" : "s") in total) for \(durationSummary)\(when):\n\n\(names)\(more)"
            + "\n\nJustification: \(trimmedJustification)"
    }
}
