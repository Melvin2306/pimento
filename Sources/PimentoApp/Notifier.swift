import AppKit
import OSLog
import PimentoCore
@preconcurrency import UserNotifications

/// macOS notifications: one when a batch of activations finishes, and a
/// reminder shortly before activated roles expire, as the user's settings say.
/// Only inside the .app bundle: UserNotifications needs a bundle identifier, so
/// `swift run` skips them.
@MainActor
enum Notifier {
    private nonisolated static let foreground = ForegroundPresenter()
    private nonisolated static let log = Logger(subsystem: "io.github.melvin2306.pimento", category: "notifications")

    static var isAvailable: Bool {
        Bundle.main.bundleIdentifier != nil && Bundle.main.bundleURL.pathExtension == "app"
    }

    /// Called at launch: shows banners while the app is frontmost too, and
    /// asks for permission once (macOS remembers the answer).
    static func setUp() {
        guard isAvailable else { return }
        let center = installDelegate()
        center.requestAuthorization(options: [.alert, .sound]) { _, error in
            if let error { log.error("requestAuthorization failed: \(error.localizedDescription, privacy: .public)") }
        }
    }

    /// The delegate that shows banners while Pimento is frontmost. Set at
    /// launch; set again here in case a notification goes out before that.
    @discardableResult
    private nonisolated static func installDelegate() -> UNUserNotificationCenter {
        let center = UNUserNotificationCenter.current()
        if center.delegate !== foreground { center.delegate = foreground }
        return center
    }

    /// Hands a request to macOS and logs a refusal (permission missing, …).
    private nonisolated static func schedule(_ request: UNNotificationRequest) {
        installDelegate().add(request) { error in
            if let error {
                log.error("Notification \(request.identifier, privacy: .public) not scheduled: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    static func activationsFinished(planned: [PlannedRequest], outcomes: [String: ActivationOutcome], prefs: Preferences) {
        guard isAvailable,
              let summary = ActivationSummary(planned: planned, outcomes: outcomes, reminderLead: prefs.reminderLead)
        else { return }
        if summary.postsCompletion(enabled: prefs.notifyOnCompletion, onlyFailures: prefs.notifyOnlyOnFailure) {
            let content = content(summary.title, summary.body, thread: "activations", sound: prefs.playSound)
            schedule(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }

        guard prefs.expiryReminders else { return }
        for reminder in summary.reminders {
            let content = content(reminder.title, reminder.body, thread: "expiry", sound: prefs.playSound)
            let trigger = UNTimeIntervalNotificationTrigger(
                timeInterval: max(1, reminder.fireAt.timeIntervalSinceNow), repeats: false)
            schedule(UNNotificationRequest(identifier: reminder.id, content: content, trigger: trigger))
        }
    }

    /// A sample notification, from the Settings window. Each test gets its own
    /// identifier, so repeated tests are not merged into the first one.
    static func sendTest(prefs: Preferences) async -> NotificationTestResult {
        guard isAvailable else { return .failed(NotificationPermission.unavailable.label) }
        let content = content(
            "Test notification",
            "This is how Pimento tells you that activations finished or roles are about to expire.",
            thread: "test", sound: prefs.playSound)
        let request = UNNotificationRequest(identifier: "test-\(UUID().uuidString)", content: content, trigger: nil)
        do {
            try await installDelegate().add(request)
            return .sent(Date())
        } catch {
            log.error("Test notification not scheduled: \(error.localizedDescription, privacy: .public)")
            return .failed(error.localizedDescription)
        }
    }

    /// Drops every pending expiry reminder (reminders were turned off).
    static func cancelReminders() {
        guard isAvailable else { return }
        UNUserNotificationCenter.current().getPendingNotificationRequests { requests in
            let center = UNUserNotificationCenter.current()
            let ids = requests.map(\.identifier).filter(ActivationSummary.isReminder)
            center.removePendingNotificationRequests(withIdentifiers: ids)
        }
    }

    /// Moves pending expiry reminders to the new lead time. A reminder whose
    /// new time has already passed is dropped.
    static func rescheduleReminders(lead: TimeInterval) {
        guard isAvailable else { return }
        UNUserNotificationCenter.current().getPendingNotificationRequests { requests in
            let center = UNUserNotificationCenter.current()
            for request in requests where ActivationSummary.isReminder(request.identifier) {
                guard let fireAt = ActivationSummary.rescheduledFireDate(for: request.identifier, reminderLead: lead) else {
                    center.removePendingNotificationRequests(withIdentifiers: [request.identifier])
                    continue
                }
                let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(1, fireAt.timeIntervalSinceNow), repeats: false)
                // Same identifier: replaces the pending one.
                schedule(UNNotificationRequest(identifier: request.identifier, content: request.content, trigger: trigger))
            }
        }
    }

    static func permission() async -> NotificationPermission {
        guard isAvailable else { return .unavailable }
        let snapshot = await withCheckedContinuation { continuation in
            UNUserNotificationCenter.current().getNotificationSettings { settings in
                continuation.resume(returning: NotificationSettingsSnapshot(settings))
            }
        }
        return NotificationPermission(snapshot)
    }

    static func requestPermission() async {
        guard isAvailable else { return }
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
    }

    /// System Settings › Notifications, on Pimento's entry where macOS supports it.
    static func openSystemSettings() {
        let base = "x-apple.systempreferences:com.apple.Notifications-Settings.extension"
        let id = Bundle.main.bundleIdentifier.map { "?id=\($0)" } ?? ""
        if let url = URL(string: base + id) ?? URL(string: base) { NSWorkspace.shared.open(url) }
    }

    private static func content(_ title: String, _ body: String, thread: String, sound: Bool) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = sound ? .default : nil
        content.threadIdentifier = thread
        // The default, set explicitly: a banner that Focus may hold back, not a passive one.
        content.interruptionLevel = .active
        return content
    }
}

extension NotificationSettingsSnapshot {
    init(_ settings: UNNotificationSettings) {
        let authorization: Authorization = switch settings.authorizationStatus {
        case .notDetermined: .notDetermined
        case .denied: .denied
        case .provisional: .provisional
        case .ephemeral: .ephemeral
        default: .authorized
        }
        let style: AlertStyle = switch settings.alertStyle {
        case .none: .none
        case .alert: .alert
        default: .banner
        }
        func flag(_ setting: UNNotificationSetting) -> Bool? {
            switch setting {
            case .enabled: true
            case .disabled: false
            default: nil
            }
        }
        self.init(authorization: authorization, alertStyle: style,
                  alerts: flag(settings.alertSetting), notificationCenter: flag(settings.notificationCenterSetting))
    }
}

/// Without a delegate macOS drops notifications while the app is frontmost,
/// which is exactly when an activation finishes.
private final class ForegroundPresenter: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list, .sound])
    }
}
