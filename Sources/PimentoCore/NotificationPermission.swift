import Foundation

/// The parts of macOS's notification settings for Pimento that decide whether
/// a banner shows up. Plain values, so the mapping below is testable without
/// UserNotifications.
public struct NotificationSettingsSnapshot: Equatable, Sendable {
    public enum Authorization: Equatable, Sendable { case notDetermined, denied, authorized, provisional, ephemeral }
    public enum AlertStyle: Equatable, Sendable { case none, banner, alert }
    /// `UNNotificationSetting`: nil when not supported.
    public typealias Setting = Bool?

    public var authorization: Authorization
    public var alertStyle: AlertStyle
    public var alerts: Setting
    public var notificationCenter: Setting

    public init(authorization: Authorization, alertStyle: AlertStyle, alerts: Setting, notificationCenter: Setting) {
        self.authorization = authorization
        self.alertStyle = alertStyle
        self.alerts = alerts
        self.notificationCenter = notificationCenter
    }
}

/// What macOS currently allows Pimento to do with notifications.
public enum NotificationPermission: Equatable, Sendable {
    case unknown
    /// Running outside Pimento.app (`swift run`): no bundle ID, no notifications.
    case unavailable
    case notDetermined
    case denied
    /// Allowed, and macOS shows banners or alerts.
    case allowed(alerts: Bool)
    /// Allowed, but nothing pops up: the banner style is None, alerts are
    /// turned off, or the permission is provisional (Notification Center only).
    case bannersOff

    public init(_ settings: NotificationSettingsSnapshot) {
        switch settings.authorization {
        case .notDetermined:
            self = .notDetermined
        case .denied:
            self = .denied
        case .authorized, .provisional, .ephemeral:
            let quiet = settings.authorization == .provisional
                || settings.alertStyle == .none
                || settings.alerts == false
            self = quiet ? .bannersOff : .allowed(alerts: settings.alertStyle == .alert)
        }
    }

    public var label: String {
        switch self {
        case .unknown: "Checking…"
        case .unavailable: "Unavailable outside Pimento.app"
        case .notDetermined: "Not asked yet"
        case .denied: "Turned off in System Settings"
        case .allowed(let alerts): alerts ? "Allowed (alerts)" : "Allowed (banners)"
        case .bannersOff: "Allowed, but banners are off"
        }
    }

    /// Whether the user has to change something in System Settings to see banners.
    public var needsSystemSettings: Bool {
        switch self {
        case .denied, .bannersOff: true
        default: false
        }
    }
}

/// What happened to the last test notification (Settings › Notifications).
public enum NotificationTestResult: Equatable, Sendable {
    case sent(Date)
    case failed(String)

    public func label(timeZone: TimeZone = .current) -> String {
        switch self {
        case .sent(let date):
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = timeZone
            formatter.dateFormat = "HH:mm"
            return "Sent ✓ at \(formatter.string(from: date))"
        case .failed(let message):
            return "Not sent: \(message)"
        }
    }
}
