import Foundation
import Testing
@testable import PimentoCore

@Suite("Notification permission")
struct NotificationPermissionTests {
    private func settings(
        _ authorization: NotificationSettingsSnapshot.Authorization,
        style: NotificationSettingsSnapshot.AlertStyle = .banner,
        alerts: Bool? = true,
        center: Bool? = true
    ) -> NotificationPermission {
        NotificationPermission(NotificationSettingsSnapshot(
            authorization: authorization, alertStyle: style, alerts: alerts, notificationCenter: center))
    }

    @Test func authorizationStates() {
        #expect(settings(.notDetermined) == .notDetermined)
        #expect(settings(.denied) == .denied)
        #expect(settings(.authorized) == .allowed(alerts: false))
        #expect(settings(.authorized, style: .alert) == .allowed(alerts: true))
        #expect(settings(.ephemeral) == .allowed(alerts: false))
    }

    @Test func allowedButQuietIsNotReportedAsAllowed() {
        #expect(settings(.authorized, style: .none) == .bannersOff)
        #expect(settings(.authorized, alerts: false) == .bannersOff)
        #expect(settings(.authorized, style: .none, center: false) == .bannersOff)
        #expect(settings(.authorized, center: false) == .allowed(alerts: false), "banners still show without Notification Center")
        #expect(settings(.provisional) == .bannersOff, "provisional delivers quietly")
        #expect(settings(.authorized, alerts: nil) == .allowed(alerts: false), "an unsupported setting is not 'off'")
    }

    @Test func labelsAndSystemSettingsHint() {
        #expect(NotificationPermission.allowed(alerts: false).label == "Allowed (banners)")
        #expect(NotificationPermission.bannersOff.label == "Allowed, but banners are off")
        #expect(NotificationPermission.denied.needsSystemSettings)
        #expect(NotificationPermission.bannersOff.needsSystemSettings)
        #expect(!NotificationPermission.allowed(alerts: true).needsSystemSettings)
        #expect(!NotificationPermission.notDetermined.needsSystemSettings)
    }

    @Test func testResultLabel() {
        let utc = TimeZone(identifier: "UTC")!
        let date = Date(timeIntervalSince1970: 1_700_000_000)  // 22:13:20 UTC
        #expect(NotificationTestResult.sent(date).label(timeZone: utc) == "Sent ✓ at 22:13")
        #expect(NotificationTestResult.failed("Notifications are not allowed for this application").label(timeZone: utc)
            == "Not sent: Notifications are not allowed for this application")
    }
}
