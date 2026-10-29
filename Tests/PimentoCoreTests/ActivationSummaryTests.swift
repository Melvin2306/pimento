import Foundation
import Testing
@testable import PimentoCore

@Suite("Notification summary")
struct ActivationSummaryTests {
    let utc = TimeZone(identifier: "UTC")!
    let now = AzureDate.parse("2026-10-29T12:00:00Z")!

    func roles(_ n: Int) -> [EligibleRole] {
        (0..<n).map { i in
            EligibleRole(
                id: "id-\(i)", eligibilityScheduleId: "e-\(i)", roleDefinitionId: "r",
                roleName: i == 0 ? "Owner" : "Reader",
                scope: "/subscriptions/\(i)", scopeName: "Contoso \(i)", scopeType: "subscription",
                membership: .direct)
        }
    }

    func plans(_ roles: [EligibleRole]) throws -> [PlannedRequest] {
        try ActivationRequestBuilder.plan(roles, principalId: "p", justification: "j", hours: 8, now: now)
    }

    @Test func allActivatedNamesRolesAndExpiry() throws {
        let r = roles(2)
        let until = AzureDate.parse("2026-10-29T20:00:00Z")!
        let s = try #require(ActivationSummary(
            planned: plans(r),
            outcomes: ["id-0": .activated(status: "Provisioned", until: until), "id-1": .activated(status: "Provisioned", until: until)],
            now: now, timeZone: utc))
        #expect(s.title == "2 roles activated")
        #expect(!s.isFailure)
        #expect(s.body.contains("Active until 20:00") || s.body.contains("Active until 8:00"))
        #expect(s.body.contains("Owner · Contoso 0"))
        // Both expire the same minute: one reminder, ten minutes before.
        #expect(s.reminders.count == 1)
        #expect(s.reminders[0].fireAt == until.addingTimeInterval(-600))
        #expect(s.reminders[0].title.hasPrefix("2 PIM roles expire at"))
    }

    @Test func failuresAreTitledAndListed() throws {
        let r = roles(2)
        let s = try #require(ActivationSummary(
            planned: plans(r),
            outcomes: ["id-0": .activated(status: "Provisioned", until: nil), "id-1": .failed(code: "X", message: "no")],
            now: now, timeZone: utc))
        #expect(s.title == "1 activated, 1 failed")
        #expect(s.isFailure)
        #expect(s.body.contains("Failed:\nReader · Contoso 1"))
        #expect(s.reminders.isEmpty)
    }

    @Test func longListsAreCut() throws {
        let r = roles(5)
        var outcomes: [String: ActivationOutcome] = [:]
        for role in r { outcomes[role.id] = .activated(status: "Provisioned", until: nil) }
        let s = try #require(ActivationSummary(planned: plans(r), outcomes: outcomes, now: now, timeZone: utc))
        #expect(s.body.contains("and 2 more"))
    }

    @Test func onlySkippedSaysAlreadyActive() throws {
        let s = try #require(ActivationSummary(planned: plans(roles(1)), outcomes: ["id-0": .alreadyActive], now: now, timeZone: utc))
        #expect(s.title == "1 role already active")
    }

    @Test func noReminderForAnExpiryWithinTheLeadTime() throws {
        let until = now.addingTimeInterval(5 * 60)
        let s = try #require(ActivationSummary(
            planned: plans(roles(1)), outcomes: ["id-0": .activated(status: "Provisioned", until: until)], now: now, timeZone: utc))
        #expect(s.reminders.isEmpty)
    }

    @Test func nothingDoneIsNil() throws {
        let p = try plans(roles(1))
        #expect(ActivationSummary(planned: p, outcomes: [:], now: now) == nil)
    }

    @Test func reminderLeadIsAParameter() throws {
        let until = AzureDate.parse("2026-10-29T20:00:00Z")!
        let s = try #require(ActivationSummary(
            planned: plans(roles(1)), outcomes: ["id-0": .activated(status: "Provisioned", until: until)],
            reminderLead: 30 * 60, now: now, timeZone: utc))
        #expect(s.reminders.map(\.fireAt) == [until.addingTimeInterval(-1800)])
        #expect(ActivationSummary.isReminder(s.reminders[0].id))
        // Changing the lead later reschedules from the reminder's identifier alone.
        #expect(ActivationSummary.rescheduledFireDate(for: s.reminders[0].id, reminderLead: 5 * 60, now: now)
            == until.addingTimeInterval(-300))
        #expect(ActivationSummary.rescheduledFireDate(for: s.reminders[0].id, reminderLead: 9 * 3600, now: now) == nil)
        #expect(ActivationSummary.rescheduledFireDate(for: "some-other-id", reminderLead: 300, now: now) == nil)
    }

    @Test func onlyFailuresFilter() throws {
        let r = roles(2)
        let ok = try #require(ActivationSummary(
            planned: plans(r), outcomes: ["id-0": .activated(status: "Provisioned", until: nil)], now: now, timeZone: utc))
        let bad = try #require(ActivationSummary(
            planned: plans(r), outcomes: ["id-1": .failed(code: "X", message: "no")], now: now, timeZone: utc))
        #expect(ok.postsCompletion(enabled: true, onlyFailures: false))
        #expect(!ok.postsCompletion(enabled: true, onlyFailures: true))
        #expect(bad.postsCompletion(enabled: true, onlyFailures: true))
        #expect(!bad.postsCompletion(enabled: false, onlyFailures: false))
    }
}
