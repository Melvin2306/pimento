import Foundation
import Testing
@testable import PimentoCore

@Suite("Expiry reminder actions")
struct ReminderActionTests {
    let utc = TimeZone(identifier: "UTC")!

    func roles() throws -> [EligibleRole] {
        [try Fixture.role("Contoso Production", "Owner"), try Fixture.role("rg-app-dev", "Owner")]
    }

    @Test func categoryAndActionsAreStableIdentifiers() {
        #expect(ReminderAction.categoryIdentifier == "pimento.expiry-reminder")
        #expect(ReminderAction.allCases.map(\.rawValue) == ["pimento.reminder.renew", "pimento.reminder.end"])
        #expect(ReminderAction(rawValue: "pimento.reminder.end") == .end)
        #expect(ReminderAction(rawValue: "com.apple.UNNotificationDefaultActionIdentifier") == nil)
        #expect(ReminderAction.end.isDestructive && !ReminderAction.renew.isDestructive)
        #expect(ReminderAction.renew.opensApp && !ReminderAction.end.opensApp)
        #expect(ReminderAction.renew.title == "Renew")
        #expect(ReminderAction.end.title == "End Now")
    }

    @Test func remindersNameTheirRoles() throws {
        let roles = try roles()
        let until = AzureDate.parse("2026-10-29T14:00:00Z")!
        let outcomes = Dictionary(uniqueKeysWithValues: roles.map { ($0.id, ActivationOutcome.activated(status: "Provisioned", until: until)) })
        let summary = try #require(ActivationSummary(roles: roles, outcomes: outcomes, now: Fixture.now, timeZone: utc))
        let reminder = try #require(summary.reminders.first)
        #expect(reminder.roles.map(\.line) == ["Owner · Contoso Production", "Owner · rg-app-dev"])
        #expect(reminder.roles.allSatisfy { $0.isOwner })
        #expect(reminder.roles[0].key == "/subscriptions/aaaaaaaa-0000-0000-0000-00000000000a|8e3af657-a8ff-443c-a75c-2fe8c4bcb635")
    }

    @Test func payloadRoundTripsThroughUserInfo() throws {
        let payload = ReminderPayload(
            roles: try roles().map(ReminderRole.init), tenantId: "contoso.onmicrosoft.com",
            justification: "INC-1 on-call", duration: .hours(2))
        // userInfo goes through a property list in UserNotifications.
        let data = try PropertyListSerialization.data(fromPropertyList: payload.userInfo, format: .binary, options: 0)
        let back = try #require(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        #expect(ReminderPayload(userInfo: back) == payload)
        #expect(ReminderPayload(userInfo: ["roleKeys": [String]()]) == nil)
        #expect(ReminderPayload(userInfo: [:]) == nil)

        let bare = ReminderPayload(roles: payload.roles)
        #expect(bare.userInfo["justification"] == nil)
        #expect(ReminderPayload(userInfo: bare.userInfo)?.justification == nil)
    }

    @Test func payloadFindsItsActiveRolesAndTenant() throws {
        let all = try Fixture.rows()
        let payload = ReminderPayload(roles: try roles().map(ReminderRole.init) + [ReminderRole(try Fixture.role("Contoso Staging", "Contributor"))])
        // Contoso Staging's activation has ended: not a target any more.
        #expect(payload.matchingActive(in: all).map(\.scopeName).sorted() == ["Contoso Production", "rg-app-dev"])
        #expect(ReminderPayload(roles: [], tenantId: "A").isTenant("a"))
        #expect(!ReminderPayload(roles: [], tenantId: "A").isTenant("b"))
        #expect(!ReminderPayload(roles: [], tenantId: "A").isTenant(nil))
        #expect(ReminderPayload(roles: [], tenantId: nil).isTenant("b"))
    }

    @Test func endingARoleUpdatesOrRemovesItsReminders() throws {
        let roles = try roles().map(ReminderRole.init)
        let minute = AzureDate.parse("2026-10-29T14:00:00Z")!
        let shared = ActivationSummary.reminder(expiringAt: minute, roles: roles, fireAt: minute.addingTimeInterval(-600), timeZone: utc)
        #expect(shared.title == "2 PIM roles expire at \(shortTime("2026-10-29T14:00:00Z", utc))")
        let other = ActivationSummary.reminder(expiringAt: minute.addingTimeInterval(3600), roles: [roles[1]], fireAt: minute, timeZone: utc)
        let pending: [(id: String, fireAt: Date, payload: ReminderPayload)] = [
            (shared.id, shared.fireAt, ReminderPayload(roles: roles, tenantId: "t", justification: "j")),
            (other.id, other.fireAt, ReminderPayload(roles: [roles[1]])),
            ("expiry-1", minute, ReminderPayload(roles: [ReminderRole(key: "unrelated", line: "x")])),
        ]
        let updates = ReminderUpdate.updates(pending: pending, ended: [roles[1].key], timeZone: utc)
        #expect(updates.count == 2)
        guard case .replace(let reminder, let payload) = updates[0] else { Issue.record("expected replace"); return }
        #expect(reminder.id == shared.id)
        #expect(reminder.fireAt == shared.fireAt)
        #expect(reminder.body == "Owner · Contoso Production")
        #expect(reminder.title.hasPrefix("1 PIM role expires at"))
        #expect(payload.roles == [roles[0]])
        #expect(payload.tenantId == "t" && payload.justification == "j")
        #expect(updates[1] == .remove(id: other.id))
        #expect(ActivationSummary.expiry(ofReminder: shared.id) == minute)
    }

    @Test func batchesExpiringInTheSameMinuteKeepTheirOwnReminders() throws {
        let roles = try roles().map(ReminderRole.init)
        let minute = AzureDate.parse("2026-10-29T17:00:00Z")!
        let fire = minute.addingTimeInterval(-600)
        let a = ActivationSummary.reminder(expiringAt: minute, roles: [roles[0]], fireAt: fire, timeZone: utc)
        let b = ActivationSummary.reminder(expiringAt: minute, roles: [roles[1]], fireAt: fire, timeZone: utc)
        // Two batches ending in the same minute: neither replaces the other.
        #expect(a.id != b.id)
        // The same roles again replace their reminder; order does not matter.
        #expect(ActivationSummary.reminder(expiringAt: minute, roles: roles, fireAt: fire, timeZone: utc).id
            == ActivationSummary.reminder(expiringAt: minute, roles: roles.reversed(), fireAt: fire, timeZone: utc).id)
        for id in [a.id, b.id, "expiry-\(Int(minute.timeIntervalSince1970))"] {
            #expect(ActivationSummary.expiry(ofReminder: id) == minute)
            #expect(ActivationSummary.rescheduledFireDate(for: id, reminderLead: 600, now: Fixture.now) == fire)
        }
    }

    @Test func deactivationAndRenewalSummaries() throws {
        let roles = try roles()
        let ended = Dictionary(uniqueKeysWithValues: roles.map { ($0.id, ActivationOutcome.deactivated(status: "Revoked")) })
        let off = try #require(ActivationSummary(roles: roles, outcomes: ended, operation: .deactivate, now: Fixture.now, timeZone: utc))
        #expect(off.title == "2 roles deactivated")
        #expect(off.reminders.isEmpty)
        #expect(!off.isFailure)

        let mixed = [roles[0].id: ActivationOutcome.deactivated(status: ""), roles[1].id: .tooSoon(possibleAt: nil)]
        let partly = try #require(ActivationSummary(roles: roles, outcomes: mixed, operation: .deactivate, now: Fixture.now, timeZone: utc))
        #expect(partly.title == "1 deactivated, 1 failed")
        #expect(partly.isFailure)

        let until = AzureDate.parse("2026-10-29T16:00:00Z")!
        let renewed = [roles[0].id: ActivationOutcome.renewed(until: until)]
        let fresh = try #require(ActivationSummary(roles: roles, outcomes: renewed, operation: .renew, now: Fixture.now, timeZone: utc))
        #expect(fresh.title == "1 role renewed")
        #expect(fresh.reminders.count == 1)
        #expect(fresh.reminders[0].fireAt == until.addingTimeInterval(-ActivationSummary.defaultReminderLead))

        let requested = [roles[0].id: ActivationOutcome.activated(status: "PendingAdminDecision", until: nil)]
        let ext = try #require(ActivationSummary(roles: roles, outcomes: requested, operation: .extend, now: Fixture.now, timeZone: utc))
        #expect(ext.title == "Extension requested for 1 role")
        #expect(ext.body.contains("administrator"))
        #expect(ext.reminders.isEmpty)
    }
}
