import Foundation

/// The panes of the app's Settings window, in toolbar order.
public enum SettingsPane: String, CaseIterable, Hashable, Sendable {
    case general
    case appearance
    case account
    case activation
    case notifications
    case history

    public var title: String {
        switch self {
        case .general: "General"
        case .appearance: "Appearance"
        case .account: "Account"
        case .activation: "Activation"
        case .notifications: "Notifications"
        case .history: "History"
        }
    }

    /// The SF Symbol of the pane's toolbar tab.
    public var symbolName: String {
        switch self {
        case .general: "gearshape"
        case .appearance: "paintpalette"
        case .account: "person.crop.circle"
        case .activation: "bolt.shield"
        case .notifications: "bell.badge"
        case .history: "clock.arrow.circlepath"
        }
    }
}

/// Short texts of the Settings window that depend only on preferences.
public enum SettingsText {
    /// "Off", "Every minute", "Every 5 minutes".
    public static func autoRefresh(minutes: Int) -> String {
        switch minutes {
        case ...0: "Off"
        case 1: "Every minute"
        default: "Every \(minutes) minutes"
        }
    }

    /// "10 minutes before".
    public static func reminderLead(minutes: Int) -> String {
        minutes == 1 ? "1 minute before" : "\(minutes) minutes before"
    }

    /// What closing the window does, for the menu bar options.
    public static func menuBarStatus(showInMenuBar: Bool, hideDockIcon: Bool, appName: String = AppInfo.name) -> String {
        guard showInMenuBar else { return "Without the menu bar icon, closing the window quits \(appName)." }
        return hideDockIcon
            ? "\(appName) runs in the menu bar only. Quit it from the menu bar icon."
            : "Closing the window keeps \(appName) running in the menu bar. ⌘-drag the icon out of the menu bar to hide it."
    }

    /// Why the mode control is disabled while a light-only theme is selected,
    /// and what applies again with another theme; nil for a theme with dark mode.
    public static func lightOnlyNote(theme: AppTheme, mode: AppearanceMode) -> String? {
        guard !theme.supportsDarkMode else { return nil }
        let base = "\(theme.title) is light-only."
        switch mode {
        case .light, .system: return base
        case .timeOfDay: return base + " The schedule applies again with another theme."
        case .dark, .ultraDark: return base + " \(mode.title) applies again with another theme."
        }
    }

    /// The Owner confirmation's note: the recommendation, or the warning when it is off.
    public static func ownerConfirmation(isOn: Bool) -> String {
        isOn
            ? "Lists the Owner roles in the selection and asks before sending anything. Recommended."
            : "Owner roles are activated without asking. The Activate button still turns orange."
    }

    /// "3 justifications, 1 ticket".
    public static func remembered(justifications: Int, tickets: Int) -> String {
        "\(count(justifications, "justification")), \(count(tickets, "ticket"))"
    }

    static func count(_ n: Int, _ noun: String) -> String { "\(n) \(noun)\(n == 1 ? "" : "s")" }
}

public extension AppTheme {
    /// One line under the theme's card in Settings › Appearance.
    var summary: String {
        switch self {
        case .native: "The standard macOS look"
        case .azure: "Flat, portal-style top bar"
        case .windowsXP: "Beige, glossy blue title bar"
        }
    }

    /// The card's tooltip: the summary plus fonts and modes.
    var details: String {
        switch self {
        case .native: "The standard macOS look. Light, dark and ultra dark."
        case .azure: "Flat, with a dark portal-style top bar. Light, dark and ultra dark. Uses Segoe UI if this Mac has it."
        case .windowsXP: "Beige with a glossy blue title bar. Light only. Uses Tahoma if this Mac has it."
        }
    }
}
