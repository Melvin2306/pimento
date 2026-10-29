import AppKit
import PimentoCore
@preconcurrency import UserNotifications

/// What macOS currently allows Pimento to do with notifications.
enum NotificationPermission: Equatable {
    case unknown
    /// Running outside Pimento.app (`swift run`): no bundle ID, no notifications.
    case unavailable
    case notDetermined
    case denied
    case allowed

    var label: String {
        switch self {
        case .unknown: "Checking…"
        case .unavailable: "Unavailable outside Pimento.app"
        case .notDetermined: "Not asked yet"
        case .denied: "Turned off in System Settings"
        case .allowed: "Allowed"
        }
    }
}

/// macOS notifications: one when a batch of activations finishes, and a
/// reminder shortly before activated roles expire, as the user's settings say.
/// Only inside the .app bundle: UserNotifications needs a bundle identifier, so
/// `swift run` skips them.
@MainActor
enum Notifier {
    private static let foreground = ForegroundPresenter()

    static var isAvailable: Bool {
        Bundle.main.bundleIdentifier != nil && Bundle.main.bundleURL.pathExtension == "app"
    }

    /// Called at launch: shows banners while the app is frontmost too, and
    /// asks for permission once (macOS remembers the answer).
    static func setUp() {
        guard isAvailable else { return }
        let center = UNUserNotificationCenter.current()
        center.delegate = foreground
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func activationsFinished(planned: [PlannedRequest], outcomes: [String: ActivationOutcome], prefs: Preferences) {
        guard isAvailable,
              let summary = ActivationSummary(planned: planned, outcomes: outcomes, reminderLead: prefs.reminderLead)
        else { return }
        let center = UNUserNotificationCenter.current()

        if summary.postsCompletion(enabled: prefs.notifyOnCompletion, onlyFailures: prefs.notifyOnlyOnFailure) {
            let content = content(summary.title, summary.body, thread: "activations", sound: prefs.playSound)
            center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }

        guard prefs.expiryReminders else { return }
        for reminder in summary.reminders {
            let content = content(reminder.title, reminder.body, thread: "expiry", sound: prefs.playSound)
            let trigger = UNTimeIntervalNotificationTrigger(
                timeInterval: max(1, reminder.fireAt.timeIntervalSinceNow), repeats: false)
            center.add(UNNotificationRequest(identifier: reminder.id, content: content, trigger: trigger))
        }
    }

    /// A sample notification, from the Settings window.
    static func sendTest(prefs: Preferences) {
        guard isAvailable else { return }
        let content = content(
            "Test notification",
            "This is how Pimento tells you that activations finished or roles are about to expire.",
            thread: "test", sound: prefs.playSound)
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "test", content: content, trigger: nil))
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
                center.add(UNNotificationRequest(identifier: request.identifier, content: request.content, trigger: trigger))
            }
        }
    }

    static func permission() async -> NotificationPermission {
        guard isAvailable else { return .unavailable }
        let status = await withCheckedContinuation { continuation in
            UNUserNotificationCenter.current().getNotificationSettings { settings in
                continuation.resume(returning: settings.authorizationStatus)
            }
        }
        switch status {
        case .notDetermined: return .notDetermined
        case .denied: return .denied
        case .authorized, .provisional: return .allowed
        @unknown default: return .allowed
        }
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
        return content
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
