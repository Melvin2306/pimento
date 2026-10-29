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
        center.setNotificationCategories([reminderCategory])
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

    /// Expiry reminders offer Renew and End Now (`ReminderAction`).
    private nonisolated static var reminderCategory: UNNotificationCategory {
        let actions = ReminderAction.allCases.map { action in
            var options: UNNotificationActionOptions = []
            if action.opensApp { options.insert(.foreground) }
            if action.isDestructive { options.insert(.destructive) }
            return UNNotificationAction(identifier: action.rawValue, title: action.title, options: options)
        }
        return UNNotificationCategory(identifier: ReminderAction.categoryIdentifier, actions: actions, intentIdentifiers: [])
    }

    /// What an expiry reminder needs for its actions.
    struct ReminderContext {
        var tenantId: String?
        var justification: String?
        var duration: RequestedDuration?
    }

    /// The completion notification of an activation, deactivation or renewal,
    /// and expiry reminders for what is active now.
    static func operationFinished(
        roles: [EligibleRole], outcomes: [String: ActivationOutcome], operation: ActivationSummary.Operation,
        context: ReminderContext, prefs: Preferences
    ) {
        guard isAvailable,
              let summary = ActivationSummary(roles: roles, outcomes: outcomes, operation: operation, reminderLead: prefs.reminderLead)
        else { return }
        if summary.postsCompletion(enabled: prefs.notifyOnCompletion, onlyFailures: prefs.notifyOnlyOnFailure) {
            let content = content(summary.title, summary.body, thread: "activations", sound: prefs.playSound)
            schedule(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }

        guard prefs.expiryReminders else { return }
        for reminder in summary.reminders {
            let payload = ReminderPayload(roles: reminder.roles, tenantId: context.tenantId,
                                          justification: context.justification, duration: context.duration)
            scheduleReminder(reminder, payload: payload, prefs: prefs)
        }
    }

    private nonisolated static func scheduleReminder(_ reminder: ActivationSummary.Reminder, payload: ReminderPayload, sound: Bool) {
        let content = UNMutableNotificationContent()
        content.title = reminder.title
        content.body = reminder.body
        content.sound = sound ? .default : nil
        content.threadIdentifier = "expiry"
        content.interruptionLevel = .active
        content.categoryIdentifier = ReminderAction.categoryIdentifier
        content.userInfo = payload.userInfo
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(1, reminder.fireAt.timeIntervalSinceNow), repeats: false)
        // Same identifier per expiry minute: replaces a pending one.
        schedule(UNNotificationRequest(identifier: reminder.id, content: content, trigger: trigger))
    }

    private static func scheduleReminder(_ reminder: ActivationSummary.Reminder, payload: ReminderPayload, prefs: Preferences) {
        scheduleReminder(reminder, payload: payload, sound: prefs.playSound)
    }

    /// Takes roles that were ended or renewed out of pending reminders (a
    /// reminder left with no role is removed) and clears delivered reminders
    /// that are only about them.
    static func rolesEnded(_ keys: Set<String>) {
        guard isAvailable, !keys.isEmpty else { return }
        let center = UNUserNotificationCenter.current()
        center.getPendingNotificationRequests { requests in
            let pending = requests.compactMap { request -> (id: String, fireAt: Date, payload: ReminderPayload)? in
                guard ActivationSummary.isReminder(request.identifier),
                      let payload = ReminderPayload(userInfo: request.content.userInfo),
                      let trigger = request.trigger as? UNTimeIntervalNotificationTrigger,
                      let fireAt = trigger.nextTriggerDate()
                else { return nil }
                return (request.identifier, fireAt, payload)
            }
            let sound = requests.first { ActivationSummary.isReminder($0.identifier) }?.content.sound != nil
            for update in ReminderUpdate.updates(pending: pending, ended: keys) {
                switch update {
                case .remove(let id):
                    center.removePendingNotificationRequests(withIdentifiers: [id])
                case .replace(let reminder, let payload):
                    scheduleReminder(reminder, payload: payload, sound: sound)
                }
            }
        }
        center.getDeliveredNotifications { delivered in
            let stale = delivered.filter { note in
                guard ActivationSummary.isReminder(note.request.identifier),
                      let payload = ReminderPayload(userInfo: note.request.content.userInfo) else { return false }
                return payload.removing(keys) == nil
            }
            center.removeDeliveredNotifications(withIdentifiers: stale.map(\.request.identifier))
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

    /// Replaces the pending "scheduled activation started" notifications of
    /// `tenantId` with one per start minute of `requests` (none when they are
    /// turned off). Run whenever the pending requests were read, so requests
    /// cancelled anywhere (app, CLI, portal) lose theirs.
    static func syncScheduledStarts(_ requests: [ScheduledRequest], tenantId: String?, prefs: Preferences) {
        guard isAvailable else { return }
        let prefix = ScheduledStartNotice.idPrefix(tenantId: tenantId)
        let notices = prefs.notifyScheduledStart ? ScheduledStartNotice.notices(for: requests, tenantId: tenantId, now: Date()) : []
        let sound = prefs.playSound
        UNUserNotificationCenter.current().getPendingNotificationRequests { pending in
            let stale = pending.map(\.identifier).filter { $0.hasPrefix(prefix) && !notices.map(\.id).contains($0) }
            UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: stale)
            for notice in notices {
                let content = UNMutableNotificationContent()
                content.title = notice.title
                content.body = notice.body
                content.sound = sound ? .default : nil
                content.threadIdentifier = "scheduled"
                content.interruptionLevel = .active
                let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(1, notice.fireAt.timeIntervalSinceNow), repeats: false)
                // Same identifier per start minute: replaces a pending one.
                schedule(UNNotificationRequest(identifier: notice.id, content: content, trigger: trigger))
            }
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
/// which is exactly when an activation finishes. Also receives the Renew /
/// End Now actions of expiry reminders.
private final class ForegroundPresenter: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list, .sound])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let action = ReminderAction(rawValue: response.actionIdentifier)
        let payload = ReminderPayload(userInfo: response.notification.request.content.userInfo)
        Task { @MainActor in
            if let action, let payload {
                await AppModel.shared.handleReminderAction(action, payload: payload)
            } else if response.actionIdentifier == UNNotificationDefaultActionIdentifier {
                NSApp.activate(ignoringOtherApps: true)
            }
        }
        completionHandler()
    }
}
