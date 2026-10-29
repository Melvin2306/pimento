import Foundation

/// The menu bar extra's rules: which active roles it lists and in what order,
/// how it writes remaining time, what the menu bar shows next to the icon,
/// and when its one timer fires next. The SwiftUI wiring stays in the app.
public enum MenuBarStatus {
    /// One activation in the menu: a scope + role that is active right now.
    public struct Entry: Equatable, Identifiable, Sendable {
        public let role: EligibleRole
        /// When the activation ends; nil: no end (or Azure did not say).
        public let until: Date?

        public var id: String { role.id }

        public func remaining(at now: Date) -> TimeInterval? { until.map { $0.timeIntervalSince(now) } }
    }

    /// Active roles, one per scope + role (a role active directly and through
    /// a group is one activation), without those already over at `now`.
    /// Soonest end first; open-ended ones last; then by role and scope name.
    public static func entries(_ roles: [EligibleRole], now: Date) -> [Entry] {
        var seen = Set<RoleMatcher.Key>()
        let active = roles
            .filter { $0.isActive && ($0.activeUntil.map { $0 > now } ?? true) }
            // Direct rows before group rows, so the kept row is the direct one.
            .sorted { lhs, rhs in
                if (lhs.membership == .direct) != (rhs.membership == .direct) { return lhs.membership == .direct }
                return lhs.id < rhs.id
            }
            .filter { seen.insert($0.policyKey).inserted }
        return active.map { Entry(role: $0, until: $0.activeUntil) }.sorted { a, b in
            switch (a.until, b.until) {
            case let (x?, y?) where x != y: return x < y
            case (.some, nil): return true
            case (nil, .some): return false
            default:
                let byRole = a.role.roleName.localizedStandardCompare(b.role.roleName)
                if byRole != .orderedSame { return byRole == .orderedAscending }
                return a.role.scopeName.localizedStandardCompare(b.role.scopeName) == .orderedAscending
            }
        }
    }

    /// Ends within the reminder lead time (or is over): shown in the warning colour.
    public static func isWarning(remaining: TimeInterval?, lead: TimeInterval) -> Bool {
        guard let remaining else { return false }
        return remaining <= lead
    }

    // MARK: Formatting

    /// The menu bar's `1:24` (hours and minutes). Minutes round up, so it
    /// never reads `0:00` while the role is still active; a day or more
    /// reads `2d`, `2d 3h`.
    public static func shortText(remaining: TimeInterval) -> String {
        let minutes = max(0, Int((remaining / 60).rounded(.up)))
        if minutes >= 24 * 60 { return dayText(minutes: minutes) }
        return "\(minutes / 60):" + twoDigits(minutes % 60)
    }

    /// The popover's live countdown: `1:24:05` while it ticks every second,
    /// the same as `shortText` otherwise. Seconds round up as well.
    public static func countdownText(remaining: TimeInterval, seconds: Bool) -> String {
        guard seconds else { return shortText(remaining: remaining) }
        let total = max(0, Int(remaining.rounded(.up)))
        if total >= 24 * 3600 { return dayText(minutes: Int((Double(total) / 60).rounded(.up))) }
        return "\(total / 3600):" + twoDigits(total / 60 % 60) + ":" + twoDigits(total % 60)
    }

    /// `1 h 24 min`, for accessibility and help text.
    public static func spokenText(remaining: TimeInterval) -> String {
        DurationText.short(minutes: max(1, Int((remaining / 60).rounded(.up))))
    }

    private static func dayText(minutes: Int) -> String {
        let days = minutes / 1440, hours = minutes % 1440 / 60
        return hours == 0 ? "\(days)d" : "\(days)d \(hours)h"
    }

    private static func twoDigits(_ n: Int) -> String { n < 10 ? "0\(n)" : "\(n)" }

    // MARK: Menu bar text

    /// What follows the icon in the menu bar: nothing while no role is
    /// active; the number of active roles; with the remaining time on, the
    /// soonest end too: `1:24` for one role, `2 · 1:24` for more. An
    /// open-ended soonest role shows the number only.
    public static func badgeText(_ entries: [Entry], now: Date, showsRemainingTime: Bool) -> String? {
        guard !entries.isEmpty else { return nil }
        let count = "\(entries.count)"
        guard showsRemainingTime, let remaining = entries.first?.remaining(at: now) else { return count }
        let time = shortText(remaining: remaining)
        return entries.count == 1 ? time : "\(count) · \(time)"
    }

    /// VoiceOver's reading of the menu bar item.
    public static func accessibilityText(_ entries: [Entry], now: Date) -> String {
        guard let first = entries.first else { return "\(AppInfo.name), no active roles" }
        let roles = entries.count == 1 ? "1 active role" : "\(entries.count) active roles"
        guard let remaining = first.remaining(at: now) else { return "\(AppInfo.name), \(roles)" }
        return "\(AppInfo.name), \(roles), \(entries.count == 1 ? "ends" : "the next ends") in \(spokenText(remaining: remaining))"
    }

    // MARK: Timer

    /// When the menu bar extra's single timer fires next. With the popover
    /// open: on the next whole second (its countdown shows seconds).
    /// Otherwise only when the menu bar would change: when an activation
    /// ends (the count drops) and, with the remaining time shown, when the
    /// soonest one's minute changes, so at most about once a minute. Nil:
    /// nothing changes on its own (no timer at all).
    public static func nextTick(after now: Date, ends: [Date], showsRemainingTime: Bool, popoverOpen: Bool) -> Date? {
        if popoverOpen { return Date(timeIntervalSinceReferenceDate: now.timeIntervalSinceReferenceDate.rounded(.down) + 1) }
        let upcoming = ends.filter { $0 > now }
        guard let soonest = upcoming.min() else { return nil }
        var candidates = upcoming
        if showsRemainingTime {
            // `shortText` rounds minutes up, so it changes when exactly k whole
            // minutes are left: the next such moment after `now`.
            let left = soonest.timeIntervalSince(now)
            let k = (left / 60).rounded(.up) - 1
            candidates.append(soonest.addingTimeInterval(-60 * max(0, k)))
        }
        return candidates.min()
    }
}

/// Whether the app keeps a Dock icon, and whether closing its last window
/// quits it. Without the menu bar extra both stay as they were: hiding the
/// Dock icon then would leave the app unreachable.
public enum AppPresence {
    public enum ActivationPolicy: Equatable, Sendable {
        /// Dock icon and app menu.
        case regular
        /// Menu bar only: no Dock icon, no app menu.
        case accessory
    }

    public static func activationPolicy(_ prefs: Preferences) -> ActivationPolicy {
        prefs.showInMenuBar && prefs.hideDockIcon ? .accessory : .regular
    }

    /// Closing the last window quits only when there is no menu bar extra to
    /// keep running in.
    public static func terminatesAfterLastWindowClosed(_ prefs: Preferences) -> Bool {
        !prefs.showInMenuBar
    }
}

/// Settings › General › Launch at login: what the system says about the
/// login item (`SMAppService.mainApp`), in words.
public enum LoginItemState: Equatable, Sendable {
    case enabled
    case disabled
    /// Registered, but switched off in System Settings › General › Login Items.
    case requiresApproval
    /// The system does not know this copy of the app (not a bundled .app).
    case notFound

    /// From `SMAppService.Status.rawValue`.
    public init(statusRawValue: Int) {
        switch statusRawValue {
        case 1: self = .enabled
        case 2: self = .requiresApproval
        case 3: self = .notFound
        default: self = .disabled
        }
    }

    /// What the toggle shows: on when registered, even while it waits for approval.
    public var isOn: Bool { self == .enabled || self == .requiresApproval }

    public var caption: String? {
        switch self {
        case .enabled: nil
        case .disabled: nil
        case .requiresApproval: "Allow \(AppInfo.name) in System Settings › General › Login Items, or it does not open at login."
        case .notFound: "Only Pimento.app can open at login (scripts/bundle.sh --install builds it)."
        }
    }

    /// Why registering or unregistering failed: the system's reason, and what
    /// it usually means for a locally built, ad-hoc signed app.
    public static func failureMessage(code: Int?, description: String, isAppBundle: Bool) -> String {
        let action = "Could not change Launch at login: \(description.trimmingCharacters(in: .whitespacesAndNewlines))"
        let ending = action.hasSuffix(".") ? "" : "."
        guard isAppBundle else { return action + ending + " Only Pimento.app can open at login (scripts/bundle.sh --install builds it)." }
        let hint: String? = switch code {
        case 3?: "The app's code signature is not accepted (locally built apps are signed ad hoc). Add Pimento in System Settings › General › Login Items instead."
        case 11?: "Login items are blocked for Pimento: allow it in System Settings › General › Login Items."
        case 1?, 2?, 4?, 7?: "macOS refused the request (as it may for ad-hoc signed apps). Add Pimento in System Settings › General › Login Items instead."
        default: nil
        }
        return action + ending + (hint.map { " " + $0 } ?? "")
    }
}
