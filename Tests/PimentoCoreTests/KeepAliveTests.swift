import Foundation
import Testing
@testable import PimentoCore

private let utc = TimeZone(identifier: "UTC")!
private let calendar: Calendar = {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = utc
    return c
}()

/// `2026-11-02T14:00` (a Monday) in UTC.
private func at(_ text: String) -> Date { AzureDate.parse(text.count == 16 ? text + ":00Z" : text)! }
private let monday = "2026-11-02"
private func mon(_ time: String) -> Date { at("\(monday)T\(time)") }

private let sub = "/subscriptions/bbbbbbbb-0000-0000-0000-00000000000b"
private let contributorGUID = "b24988ac-6180-42a0-ab88-20f7382dd24c"

/// A synthetic Contributor role on Contoso Staging, active until `until` (nil: eligible only).
private func role(until: Date? = nil, since: Date? = nil, membership: Membership = .direct, id: String = "row-1",
                  schedule: String = "aaaaaaaa-0000-4000-8000-000000000001") -> EligibleRole {
    EligibleRole(
        id: id, eligibilityScheduleId: "\(sub)/providers/Microsoft.Authorization/roleEligibilitySchedules/e1",
        roleDefinitionId: "\(sub)/providers/Microsoft.Authorization/roleDefinitions/\(contributorGUID)",
        roleName: "Contributor", scope: sub, scopeName: "Contoso Staging", scopeType: "subscription", membership: membership,
        isActive: until != nil, activeUntil: until, activeSince: since ?? until.map { $0.addingTimeInterval(-3600) },
        activeScheduleId: until == nil ? nil : "\(sub)/providers/Microsoft.Authorization/roleAssignmentSchedules/\(schedule)")
}

private func policy(maxHours: Int = 8, approval: Bool = false, ticket: Bool = false) -> PolicyLookup {
    .loaded(RolePolicy(maximumDuration: TimeInterval(maxHours * 3600), requiresJustification: true, requiresTicket: ticket,
                       requiresApproval: approval))
}

private func track(justification: String? = "Deploy release 2.4", ticket: TicketInfo? = nil, lastEnd: Date? = nil) -> KeepAliveTrack {
    var t = KeepAliveTrack()
    t.justification = justification
    t.ticket = ticket
    t.lastEnd = lastEnd
    return t
}

private func decide(
    _ r: EligibleRole, now: Date, rule: KeepAliveRule = KeepAliveRule(), policy p: PolicyLookup? = policy(),
    pending: [ScheduledRequest] = [], track t: KeepAliveTrack = track(), hours: WorkingHours = WorkingHours(), paused: Bool = false
) -> KeepAliveStatus {
    KeepAlive.decide(role: r, rule: rule, policy: p, pending: pending, track: t, hours: hours, paused: paused, now: now, calendar: calendar)
}

private func scheduled(start: Date, minutes: Int = 60, name: String = "cccccccc-0000-4000-8000-000000000001") -> ScheduledRequest {
    ScheduledRequest(id: "", name: name, scope: sub, roleDefinitionId: "\(sub)/providers/Microsoft.Authorization/roleDefinitions/\(contributorGUID)",
                     roleName: "Contributor", scopeName: "Contoso Staging", scopeType: "subscription", status: "Granted", start: start,
                     end: start.addingTimeInterval(TimeInterval(minutes * 60)))
}

@Suite("Keep-alive: working hours")
struct WorkingHoursTests {
    @Test func theDefaultIsWeekdaysEightToSix() {
        let h = WorkingHours()
        #expect(h.label == "Mon–Fri 08:00–18:00")
        #expect(h.window(containing: mon("08:00"), calendar: calendar) == DateInterval(start: mon("08:00"), end: mon("18:00")))
        #expect(h.window(containing: mon("17:59"), calendar: calendar) != nil)
        #expect(h.window(containing: mon("07:59"), calendar: calendar) == nil)
        #expect(h.window(containing: mon("18:00"), calendar: calendar) == nil, "the end is not inside")
        #expect(h.window(containing: at("2026-11-07T12:00"), calendar: calendar) == nil, "Saturday")
    }

    @Test func aWindowEndingAtOrBeforeItsStartRunsOvernight() {
        let night = WorkingHours(days: [6], start: ClockTime(hour: 22, minute: 0), end: ClockTime(hour: 6, minute: 0))
        let friday = at("2026-11-06T22:00")
        #expect(night.window(containing: at("2026-11-07T03:00"), calendar: calendar) == DateInterval(start: friday, end: at("2026-11-07T06:00")))
        #expect(night.window(containing: at("2026-11-06T21:59"), calendar: calendar) == nil)
        #expect(night.window(containing: at("2026-11-08T03:00"), calendar: calendar) == nil, "Saturday night is not a working night")
        #expect(night.lengthMinutes == 480)
        let allDay = WorkingHours(days: Set(1...7), start: ClockTime(hour: 0, minute: 0), end: ClockTime(hour: 0, minute: 0))
        #expect(allDay.lengthMinutes == 1440)
        #expect(allDay.window(containing: mon("23:59"), calendar: calendar)?.duration == 86400)
    }

    @Test func theNextWindowSkipsTheWeekend() {
        let h = WorkingHours()
        #expect(h.nextWindow(after: at("2026-11-06T18:30"), calendar: calendar)?.start == at("2026-11-09T08:00"))
        #expect(h.nextWindow(after: mon("07:00"), calendar: calendar)?.start == mon("08:00"))
        #expect(h.nextWindow(after: mon("09:00"), calendar: calendar)?.start == at("2026-11-03T08:00"))
        #expect(WorkingHours(days: []).nextWindow(after: mon("09:00"), calendar: calendar) == nil)
    }

    @Test func daysAndWindowsParseFromTheCommandLine() {
        #expect(WorkingHours.parseDays("mon-fri") == [2, 3, 4, 5, 6])
        #expect(WorkingHours.parseDays("Fri-Mon") == [6, 7, 1, 2])
        #expect(WorkingHours.parseDays("mon,wed, fri") == [2, 4, 6])
        #expect(WorkingHours.parseDays("weekend") == [1, 7])
        #expect(WorkingHours.parseDays("all") == Set(1...7))
        #expect(WorkingHours.parseDays("mon-") == nil)
        #expect(WorkingHours.parseDays("someday") == nil)
        #expect(WorkingHours.parseDays("") == nil)
        #expect(WorkingHours.parseWindow("08:00-18:00").map { [$0.start.text, $0.end.text] } == ["08:00", "18:00"])
        #expect(WorkingHours.parseWindow("7-19").map { [$0.start.text, $0.end.text] } == ["07:00", "19:00"])
        #expect(WorkingHours.parseWindow("22:00-06:00") != nil)
        #expect(WorkingHours.parseWindow("08:00") == nil)
        #expect(WorkingHours.parseWindow("25:00-18:00") == nil)
    }

    @Test func labelsReadAsAWeek() {
        #expect(WorkingHours(days: [2, 4, 6]).daysLabel == "Mon, Wed, Fri")
        #expect(WorkingHours(days: [7, 1]).daysLabel == "Sat, Sun")
        #expect(WorkingHours(days: Set(1...7)).daysLabel == "Every day")
        #expect(WorkingHours(days: [2, 3, 4, 6]).daysLabel == "Mon–Wed, Fri")
        #expect(WorkingHours(days: []).daysLabel == "No days")
    }

    @Test func itIsStoredLeniently() {
        let h = WorkingHours(days: [2, 3], start: ClockTime(hour: 7, minute: 30), end: ClockTime(hour: 16, minute: 0))
        #expect(WorkingHours(storedValue: h.storedValue) == h)
        #expect(WorkingHours(storedValue: "nonsense") == WorkingHours())
        #expect(WorkingHours(storedValue: ["start": "9:00", "days": [9, 2], "end": "late"]) == WorkingHours(days: [2], start: ClockTime(hour: 9, minute: 0)))
        var p = Preferences()
        p.keepAliveHours = h
        p.keepAlivePaused = true
        let store = MemoryStore()
        p.save(to: store)
        #expect(Preferences.load(from: store).keepAliveHours == h)
        #expect(Preferences.load(from: store).keepAlivePaused)
    }
}

@Suite("Keep-alive: durations at the end of working hours")
struct KeepAliveClipTests {
    @Test func theLastRenewalIsShortenedToWholeHours() {
        #expect(KeepAlive.clippedMinutes(cap: 480, room: 10 * 3600) == 480)
        #expect(KeepAlive.clippedMinutes(cap: 480, room: 8 * 3600) == 480)
        #expect(KeepAlive.clippedMinutes(cap: 480, room: 2.5 * 3600) == 120)
        #expect(KeepAlive.clippedMinutes(cap: 480, room: 59 * 60) == nil, "not even an hour")
        // A policy maximum below whole hours is requested as is, when it fits.
        #expect(KeepAlive.clippedMinutes(cap: 90, room: 100 * 60) == 90)
        #expect(KeepAlive.clippedMinutes(cap: 90, room: 80 * 60) == 60)
        #expect(KeepAlive.clippedMinutes(cap: 30, room: 40 * 60) == 30)
        #expect(KeepAlive.clippedMinutes(cap: 30, room: 20 * 60) == nil)
    }
}

@Suite("Keep-alive: when and what to renew")
struct KeepAliveDecisionTests {
    @Test func itWaitsUntilShortlyBeforeTheEnd() {
        let r = role(until: mon("14:00"))
        #expect(decide(r, now: mon("12:00")) == .waiting(until: mon("13:45")))
        #expect(KeepAliveStatus.waiting(until: mon("13:45")).nextCheck(now: mon("12:00")) == mon("13:45"))
    }

    @Test func theContinuationStartsExactlyAtTheEnd() {
        let r = role(until: mon("14:00"))
        #expect(decide(r, now: mon("13:46"), policy: policy(maxHours: 4))
            == .act(.handOver(start: mon("14:00"), minutes: 240, clipped: false, justification: "Deploy release 2.4", ticket: nil)))
    }

    @Test func thePresetDurationIsCappedAtThePolicy() {
        let r = role(until: mon("10:00"))
        let rule = KeepAliveRule(requested: .hours(2))
        #expect(decide(r, now: mon("09:50"), rule: rule).action
            == .handOver(start: mon("10:00"), minutes: 120, clipped: false, justification: "Deploy release 2.4", ticket: nil))
        #expect(decide(r, now: mon("09:50"), rule: KeepAliveRule(requested: .hours(12)), policy: policy(maxHours: 4)).action?.minutes == 240)
    }

    @Test func theLastRenewalEndsWithWorkingHours() {
        let r = role(until: mon("15:20"))
        #expect(decide(r, now: mon("15:10"))
            == .act(.handOver(start: mon("15:20"), minutes: 120, clipped: true, justification: "Deploy release 2.4", ticket: nil)))
        // 40 minutes left: PIM's shortest here is an hour, so it stops.
        #expect(decide(role(until: mon("17:20")), now: mon("17:10")) == .lastOfDay(end: mon("17:20"), windowEnd: mon("18:00")))
        // It lasts past the end anyway.
        #expect(decide(role(until: mon("18:30")), now: mon("17:30")) == .endsAfterHours(windowEnd: mon("18:00")))
    }

    @Test func nothingHappensOutsideWorkingHours() {
        #expect(decide(role(until: mon("07:55")), now: mon("07:45")) == .outsideHours(next: mon("08:00")))
        #expect(decide(role(until: at("2026-11-07T11:00")), now: at("2026-11-07T10:50")) == .outsideHours(next: at("2026-11-09T08:00")))
        // Ending just after the start of working hours: renewed once they start.
        #expect(decide(role(until: mon("08:10")), now: mon("08:00")).action != nil)
    }

    @Test func approvalRequiredAndUnreadablePoliciesAreExcluded() {
        let r = role(until: mon("14:00"))
        #expect(decide(r, now: mon("13:50"), policy: policy(approval: true)) == .excluded(.needsApproval))
        #expect(decide(r, now: mon("13:50"), policy: .failed("HTTP 403")) == .excluded(.policyUnknown))
        #expect(decide(r, now: mon("13:50"), policy: .notFound) == .excluded(.policyUnknown))
        #expect(decide(r, now: mon("13:50"), policy: nil) == .excluded(.policyLoading))
        #expect(KeepAliveStatus.excluded(.needsApproval).isExcluded)
        #expect(!KeepAliveStatus.excluded(.policyLoading).isExcluded)
        #expect(KeepAliveStatus.excluded(.needsApproval).summary(now: mon("13:50"), timeZone: utc).contains("requires approval"))
    }

    @Test func theJustificationAndTicketOfTheActivationAreReused() {
        let r = role(until: mon("14:00"))
        let ticket = TicketInfo(number: "CHG-1001", system: "ServiceNow")
        #expect(decide(r, now: mon("13:50"), policy: policy(ticket: true), track: track(ticket: ticket)).action
            == .handOver(start: mon("14:00"), minutes: 240, clipped: true, justification: "Deploy release 2.4", ticket: ticket))
        // A ticket the policy needs but nobody knows: skipped.
        #expect(decide(r, now: mon("13:50"), policy: policy(ticket: true)) == .blocked(.needsTicket))
        #expect(decide(r, now: mon("13:50"), policy: policy(ticket: true), track: track(ticket: TicketInfo(number: "CHG-1", system: nil)))
            == .blocked(.needsTicket))
        // No justification known: the preset's, else skipped.
        #expect(decide(r, now: mon("13:50"), track: track(justification: nil)) == .blocked(.needsJustification))
        #expect(decide(r, now: mon("13:50"), rule: KeepAliveRule(justification: "On call"), track: track(justification: nil)).action
            == .handOver(start: mon("14:00"), minutes: 240, clipped: true, justification: "On call", ticket: nil))
    }

    @Test func aContinuationAlreadyScheduledIsLeftAlone() {
        let r = role(until: mon("14:00"))
        #expect(decide(r, now: mon("13:50"), pending: [scheduled(start: mon("14:00"))]) == .continued(start: mon("14:00"), until: mon("15:00")))
        // One for tomorrow is no continuation.
        #expect(decide(r, now: mon("13:50"), pending: [scheduled(start: at("2026-11-03T08:00"))]).action != nil)
        var t = track()
        t.handOver = .init(start: mon("14:00"), until: mon("18:00"), requestName: "x", scope: sub, roleDefinitionId: contributorGUID)
        #expect(decide(r, now: mon("13:50"), track: t) == .continued(start: mon("14:00"), until: mon("18:00")))
    }

    @Test func tooCloseToTheEndItWaitsForTheEnd() {
        // A start less than two minutes ahead would count as "now" and overlap.
        #expect(decide(role(until: mon("14:00")), now: mon("13:59")) == .waiting(until: mon("14:00").addingTimeInterval(30)))
    }

    @Test func failuresBackOffAndStop() {
        let r = role(until: mon("14:00"))
        var t = track()
        t.failures = 2
        t.retryAt = mon("13:55")
        #expect(decide(r, now: mon("13:50"), track: t) == .retryLater(at: mon("13:55"), failures: 2))
        #expect(decide(r, now: mon("13:55"), track: t).action != nil)
        t.failures = KeepAlive.maxFailures
        t.retryAt = nil
        #expect(decide(r, now: mon("13:55"), track: t) == .gaveUp(failures: KeepAlive.maxFailures))
    }

    @Test func pausedDoesNothing() {
        #expect(decide(role(until: mon("14:00")), now: mon("13:50"), paused: true) == .paused)
    }

    @Test func activeWithoutAnEndNeedsNothing() {
        #expect(decide(role(until: nil).withActive(), now: mon("13:50")) == .noEnd)
    }
}

@Suite("Keep-alive: lapsed roles, sleep and wake")
struct KeepAliveLapseTests {
    @Test func aRoleThatWasNeverSeenActiveIsNotStarted() {
        #expect(decide(role(), now: mon("09:00"), track: track(lastEnd: nil)) == .notActive)
    }

    @Test func aRoleThatLapsedWhileAsleepIsActivatedAgainInsideWorkingHours() {
        // Seen active until 14:00; the Mac slept from 13:30 to 15:30.
        #expect(decide(role(), now: mon("15:30"), track: track(lastEnd: mon("14:00")))
            == .act(.activateNow(minutes: 120, clipped: true, justification: "Deploy release 2.4", ticket: nil)))
        #expect(decide(role(), now: mon("09:00"), policy: policy(maxHours: 4), track: track(lastEnd: mon("08:30")))
            == .act(.activateNow(minutes: 240, clipped: false, justification: "Deploy release 2.4", ticket: nil)))
    }

    @Test func notAfterWorkingHoursNorForWhatLapsedBeforeThem() {
        #expect(decide(role(), now: mon("18:30"), track: track(lastEnd: mon("14:00"))) == .notActive)
        // Lapsed at 07:30, before working hours: keep-alive does not start the day.
        #expect(decide(role(), now: mon("08:30"), track: track(lastEnd: mon("07:30"))) == .notActive)
        // Lapsed yesterday.
        #expect(decide(role(), now: at("2026-11-03T09:00"), track: track(lastEnd: mon("17:00"))) == .notActive)
        // Less than an hour left today.
        #expect(decide(role(), now: mon("17:30"), track: track(lastEnd: mon("17:00"))) == .lastOfDay(end: mon("17:00"), windowEnd: mon("18:00")))
    }

    @Test func aRoleEndedEarlyIsNotBroughtBack() {
        #expect(decide(role(), now: mon("12:00"), track: track(lastEnd: mon("14:00"))) == .endedEarly)
        // ...and a continuation Pimento scheduled for it is withdrawn.
        var t = track(lastEnd: mon("14:00"))
        let h = KeepAliveTrack.HandOver(start: mon("14:00"), until: mon("18:00"), requestName: "n1", scope: sub, roleDefinitionId: contributorGUID)
        t.handOver = h
        #expect(decide(role(), now: mon("13:50"), track: t) == .act(.cancel(h)))
    }

    @Test func aContinuationGetsAMomentToStartBeforeItCountsAsMissing() {
        var t = track(lastEnd: mon("14:00"))
        t.handOver = .init(start: mon("14:00"), until: mon("18:00"), requestName: "n1", scope: sub, roleDefinitionId: contributorGUID)
        #expect(decide(role(), now: mon("14:01"), track: t) == .continued(start: mon("14:00"), until: mon("18:00")))
        #expect(KeepAliveStatus.continued(start: mon("14:00"), until: nil).nextCheck(now: mon("14:01")) == mon("14:04"))
        // It did not start: activated now (with a gap).
        #expect(decide(role(), now: mon("14:04"), track: t).action
            == .activateNow(minutes: 180, clipped: true, justification: "Deploy release 2.4", ticket: nil))
    }

    @Test func aScheduledActivationAboutToStartCounts() {
        #expect(decide(role(), now: mon("14:00"), pending: [scheduled(start: mon("14:05"))], track: track(lastEnd: mon("13:59")))
            == .continued(start: mon("14:05"), until: mon("15:05")))
    }
}

@Suite("Keep-alive: passes, records and notices")
struct KeepAlivePlannerTests {
    @Test func onePerScopeAndRoleTheActiveDirectRowFirst() {
        let viaGroup = role(until: mon("14:00"), membership: .group("sg-ops"), id: "row-2")
        let direct = role(until: mon("14:00"), id: "row-1")
        let key = ReminderRole.key(direct.policyKey)
        var book = KeepAliveBook()
        let items = KeepAlivePlanner.plan(
            roles: [viaGroup, direct], rules: [key: KeepAliveRule()], policies: [direct.policyKey: policy()], infos: [:], pending: [],
            book: &book, hours: WorkingHours(), paused: false, now: mon("12:00"), calendar: calendar)
        #expect(items.map(\.role.id) == ["row-1"])
        #expect(book[key].lastEnd == mon("14:00"))
        #expect(items.first?.status == .blocked(.needsJustification) || items.first?.status == .waiting(until: mon("13:45")))
    }

    @Test func theListingTeachesTheJustificationAndTicket() {
        let r = role(until: mon("14:00"), schedule: "aaaaaaaa-0000-4000-8000-0000000000aa")
        let key = ReminderRole.key(r.policyKey)
        let ticket = TicketInfo(number: "INC-1", system: "Jira")
        var book = KeepAliveBook()
        let items = KeepAlivePlanner.plan(
            roles: [r], rules: [key: KeepAliveRule()], policies: [r.policyKey: policy(ticket: true)],
            infos: ["aaaaaaaa-0000-4000-8000-0000000000aa": ActivationRequestInfo(justification: "Incident", ticket: ticket)],
            pending: [], book: &book, hours: WorkingHours(), paused: false, now: mon("13:50"), calendar: calendar)
        #expect(items.first?.status == .act(.handOver(start: mon("14:00"), minutes: 240, clipped: true, justification: "Incident", ticket: ticket)))
        // Unrelated roles are not kept.
        #expect(KeepAlivePlanner.plan(roles: [r], rules: [:], policies: [:], infos: [:], pending: [], book: &book, hours: WorkingHours(),
                                      paused: false, now: mon("13:50"), calendar: calendar).isEmpty)
    }

    @Test func anEarlyEndIsForgottenAndCountersStartOverEachWindow() {
        let r = role()
        let key = ReminderRole.key(r.policyKey)
        var book = KeepAliveBook()
        book[key] = track(lastEnd: mon("14:00"))
        book.tracks[key]?.failures = 4
        book.tracks[key]?.window = at("2026-10-30T08:00")
        let items = KeepAlivePlanner.plan(
            roles: [r], rules: [key: KeepAliveRule()], policies: [r.policyKey: policy()], infos: [:], pending: [], book: &book,
            hours: WorkingHours(), paused: false, now: mon("12:00"), calendar: calendar)
        #expect(items.first?.status == .endedEarly)
        #expect(book[key].lastEnd == nil)
        #expect(book[key].failures == 0)
        #expect(book[key].window == mon("08:00"))
    }

    @Test func outcomesAreRecordedWithBackoffAndACap() {
        let r = role(until: mon("14:00"))
        let key = "k"
        var book = KeepAliveBook()
        let action = KeepAliveAction.handOver(start: mon("14:00"), minutes: 240, clipped: false, justification: "j", ticket: nil)
        let refused = book.record(action, outcome: .request(.alreadyActive, requestId: "r1"), role: r, key: key, now: mon("13:45"))
        #expect(refused == .failed(role: r, message: "PIM refused a continuation that would overlap the current activation (RoleAssignmentExists)",
                                   retryAt: mon("13:46"), failures: 1))
        _ = book.record(action, outcome: .request(.failed(code: "NetworkError", message: "offline"), requestId: "r2"), role: r, key: key, now: mon("13:46"))
        #expect(book[key].retryAt == mon("13:51"))
        _ = book.record(action, outcome: .request(.failed(code: "NetworkError", message: "offline"), requestId: "r3"), role: r, key: key, now: mon("13:51"))
        #expect(book[key].retryAt == mon("14:06"))
        let last = book.record(action, outcome: .request(.failed(code: "NetworkError", message: "offline"), requestId: "r4"), role: r, key: key, now: mon("14:06"))
        guard case .failed(_, _, nil, 4) = last else { Issue.record("expected the give-up after 4 failures, got \(last)"); return }
        #expect(decide(role(until: mon("15:00")), now: mon("14:50"), track: book[key]) == .gaveUp(failures: 4))

        var ok = KeepAliveBook()
        let renewed = ok.record(action, outcome: .request(.scheduled(status: "Granted", start: mon("14:00"), until: mon("18:00")), requestId: "r5"),
                                role: r, key: key, now: mon("13:45"))
        #expect(renewed == .renewed(role: r, start: mon("14:00"), until: mon("18:00"), clipped: false, lapsedAt: nil))
        #expect(ok[key].handOver?.requestName == "r5")
        #expect(renewed.notice(now: mon("13:45"), timeZone: utc).title == "Renewed Contributor until 18:00")
        // Awaiting approval is no renewal.
        var pending = KeepAliveBook()
        #expect(pending.record(action, outcome: .request(.activated(status: "PendingApproval", until: nil), requestId: "r6"),
                               role: r, key: key, now: mon("13:45")).isFailure)
    }

    @Test func aLateActivationRemembersItsEndAndTheLapse() {
        let r = role()
        var book = KeepAliveBook()
        book["k"] = track(lastEnd: mon("14:00"))
        let event = book.record(.activateNow(minutes: 120, clipped: true, justification: "j", ticket: nil),
                                outcome: .request(.activated(status: "Provisioned", until: mon("18:00")), requestId: "r1"),
                                role: r, key: "k", now: mon("16:00"))
        #expect(event == .renewed(role: r, start: mon("16:00"), until: mon("18:00"), clipped: true, lapsedAt: mon("14:00")))
        #expect(book["k"].lastEnd == mon("18:00"))
        // Until the listing shows it: a continuation, not an early end.
        #expect(decide(role(), now: mon("16:01"), track: book["k"]) == .continued(start: mon("16:00"), until: mon("18:00")))
        let body = event.notice(now: mon("16:00"), timeZone: utc).body
        #expect(body.contains("ended at 14:00"))
        #expect(body.contains("Shortened to end with your working hours"))
    }

    @Test func withdrawingClearsTheTrack() {
        let r = role()
        var book = KeepAliveBook()
        var t = track(lastEnd: mon("14:00"))
        let h = KeepAliveTrack.HandOver(start: mon("14:00"), until: mon("18:00"), requestName: "n1", scope: sub, roleDefinitionId: contributorGUID)
        t.handOver = h
        book["k"] = t
        #expect(book.record(.cancel(h), outcome: .cancel(.canceled), role: r, key: "k", now: mon("13:00")) == .withdrawn(role: r))
        #expect(book["k"].handOver == nil)
        #expect(book["k"].lastEnd == nil)
    }

    @Test func pausingAndRemovingReturnTheContinuationsToWithdraw() {
        var book = KeepAliveBook()
        var t = track(lastEnd: mon("14:00"))
        let h = KeepAliveTrack.HandOver(start: mon("14:00"), until: mon("18:00"), requestName: "n1", scope: sub, roleDefinitionId: contributorGUID)
        t.handOver = h
        book["a"] = t
        book["b"] = track(lastEnd: mon("15:00"))
        #expect(book.pause(now: mon("13:50")) == ["a": h])
        #expect(book["b"].lastEnd == nil, "what lapses while paused is not brought back")
        #expect(book["a"].handOver == nil, "withdrawn on pause: after a resume the role is continued again")
        #expect(book.pause(now: mon("13:51")).isEmpty, "withdrawn once")
        book["a"] = t
        #expect(book.remove("a", now: mon("13:50")) == h)
        #expect(book.remove("a", now: mon("13:50")) == nil)
        book["c"] = t
        #expect(book.remove("c", now: mon("14:30")) == nil, "already started")
    }

    @Test func blockedAndLastOfDayAreNoticedOncePerWindow() {
        let r = role(until: mon("14:00"))
        var book = KeepAliveBook()
        let items = [KeepAlivePlanner.Item(key: "k", role: r, rule: KeepAliveRule(), status: .blocked(.needsTicket))]
        #expect(KeepAlivePlanner.onceEvents(items, book: &book) == [.blocked(role: r, .needsTicket)])
        #expect(KeepAlivePlanner.onceEvents(items, book: &book).isEmpty)
        book.tracks["k"]?.enter(window: at("2026-11-03T08:00"))
        #expect(KeepAlivePlanner.onceEvents(items, book: &book).count == 1)
    }

    @Test func rulesComeFromRolesAndPresets() throws {
        let r = role(until: mon("14:00"))
        let key = ReminderRole.key(r.policyKey)
        #expect(KeepAliveRule.resolve(perRole: [key], presets: [], roles: [r]) == [key: KeepAliveRule()])
        let preset = Preset(name: "Release", tenantId: nil, roles: [PresetRole(r)], justification: "Release day", duration: .hours(4), keepAlive: true)
        #expect(KeepAliveRule.resolve(perRole: [key], presets: [preset], roles: [r])
            == [key: KeepAliveRule(requested: .hours(4), justification: "Release day", preset: "Release")])
        var off = preset
        off.keepAlive = false
        #expect(KeepAliveRule.resolve(perRole: [], presets: [off], roles: [r]).isEmpty)
        // Stored in the presets file only when on.
        let data = PresetLibrary(presets: [preset, off]).encoded()
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.components(separatedBy: "\"keepAlive\"").count == 2)
        #expect(try PresetLibrary.decode(data).presets.map(\.keepAlive) == [true, false])
    }

    @Test func summariesReadWell() {
        let now = mon("12:00")
        #expect(KeepAliveStatus.waiting(until: mon("13:45")).summary(now: now, timeZone: utc) == "renews at 13:45")
        #expect(KeepAliveStatus.continued(start: mon("14:00"), until: mon("18:00")).summary(now: now, timeZone: utc) == "continues at 14:00 until 18:00")
        #expect(KeepAliveStatus.outsideHours(next: at("2026-11-03T08:00")).summary(now: now, timeZone: utc) == "outside working hours (from Tue 08:00)")
        #expect(KeepAliveStatus.retryLater(at: mon("12:05"), failures: 1).summary(now: now, timeZone: utc) == "failed once, trying again at 12:05")
    }
}

private extension EligibleRole {
    /// Active without an end.
    func withActive() -> EligibleRole {
        var r = self
        r.isActive = true
        return r
    }
}

@Suite("Keep-alive: against the demo simulator")
struct KeepAliveDemoTests {
    static let start = AzureDate.parse("2026-10-30T09:30:00Z")!

    func session(at start: Date = Self.start) -> (DemoFixture, PIMService) {
        let fixture = DemoFixture(start: start)
        return (fixture, fixture.service())
    }

    @Test func aRoleIsContinuedWithoutAGap() async throws {
        let (demo, service) = session()
        let keepAlive = KeepAliveSession()
        let kv = try await demo.role("kv-contoso-prod", "Key Vault Secrets User")
        let key = ReminderRole.key(kv.policyKey)
        let clock = demo.clock
        let result = try await demo.offline {
            try await keepAlive.pass(reader: service.readOnly, writer: service, perRole: [key], presets: [], hours: WorkingHours(), paused: false,
                                     calendar: calendar, clock: { clock.now() })
        }
        // It ends at 09:38: continued from then for its policy's hour, with its ticket.
        #expect(result.events == [.renewed(role: result.items[0].role, start: at("2026-10-30T09:38"), until: at("2026-10-30T10:38"),
                                           clipped: false, lapsedAt: nil)])
        #expect(result.items.first?.status == .continued(start: at("2026-10-30T09:38"), until: at("2026-10-30T10:38")))
        // The continuation starts at the end: active the whole time.
        demo.clock.advance(by: 8 * 60 + 30)
        let after = try await demo.role("kv-contoso-prod", "Key Vault Secrets User")
        #expect(after.isActive)
        #expect(after.activeUntil == at("2026-10-30T10:38"))
        let next = try await demo.offline {
            try await keepAlive.pass(reader: service.readOnly, writer: service, perRole: [key], presets: [], hours: WorkingHours(), paused: false,
                                     calendar: calendar, clock: { clock.now() })
        }
        #expect(next.items.first?.status == .waiting(until: at("2026-10-30T10:23")))
        #expect(next.events.isEmpty)
    }

    @Test func aRoleThatLapsedWhileAsleepIsActivatedOnWake() async throws {
        let (demo, service) = session()
        let keepAlive = KeepAliveSession()
        let dev = try await demo.role("Contoso Development", "Contributor")
        let key = ReminderRole.key(dev.policyKey)
        let clock = demo.clock
        func pass() async throws -> KeepAlivePassResult {
            try await demo.offline {
                try await keepAlive.pass(reader: service.readOnly, writer: service, perRole: [key], presets: [], hours: WorkingHours(), paused: false,
                                         calendar: calendar, clock: { clock.now() })
            }
        }
        #expect(try await pass().items.first?.status == .waiting(until: at("2026-10-30T14:25")))
        // Asleep from 09:30 to 16:00: it ended at 14:40.
        demo.clock.advance(by: 6.5 * 3600)
        let woke = try await pass()
        #expect(woke.events.count == 1)
        guard case .renewed(_, let start, let until, let clipped, let lapsed)? = woke.events.first else {
            Issue.record("expected a renewal, got \(woke.events)")
            return
        }
        #expect(start == at("2026-10-30T16:00"))
        #expect(until == at("2026-10-30T18:00"), "shortened to the end of working hours")
        #expect(clipped)
        #expect(lapsed == at("2026-10-30T14:40"))
        #expect(try await demo.role("Contoso Development", "Contributor").isActive)
        // At 17:45: it lasts to the end of working hours, nothing more to do.
        demo.clock.advance(by: 105 * 60)
        let evening = try await pass()
        #expect(evening.items.first?.status == .endsAfterHours(windowEnd: at("2026-10-30T18:00")))
        #expect(evening.events.isEmpty)
        #expect(evening.nextCheck == nil)
    }

    @Test func approvalRolesAreNeverSent() async throws {
        let (demo, service) = session()
        let keepAlive = KeepAliveSession()
        let owner = try await demo.role("Contoso Production", "Owner")
        let key = ReminderRole.key(owner.policyKey)
        let clock = demo.clock
        let result = try await demo.offline {
            try await keepAlive.pass(reader: service.readOnly, writer: service, perRole: [key], presets: [], hours: WorkingHours(), paused: false,
                                     calendar: calendar, clock: { clock.now() })
        }
        #expect(result.items.first?.status == .excluded(.needsApproval))
        #expect(result.actions.isEmpty)
    }

    @Test func aDryRunSendsNothing() async throws {
        let (demo, service) = session()
        let keepAlive = KeepAliveSession()
        let kv = try await demo.role("kv-contoso-prod", "Key Vault Secrets User")
        let clock = demo.clock
        let result = try await demo.offline {
            try await keepAlive.pass(reader: service.readOnly, writer: service.readOnly, perRole: [ReminderRole.key(kv.policyKey)], presets: [],
                                     hours: WorkingHours(), paused: false, calendar: calendar, clock: { clock.now() }, dryRun: true)
        }
        #expect(result.actions.count == 1)
        #expect(result.events.isEmpty)
        let scheduled = try await service.loadScheduledRequests(now: clock.now()).requests
        #expect(!scheduled.contains { $0.policyKey == kv.policyKey && $0.start == at("2026-10-30T09:38") })
    }
}

@Suite("Keep-alive: roles that grant access, and the history")
struct KeepAliveConsentTests {
    func roleNamed(_ name: String, guid: String, id: String = "row-x") -> EligibleRole {
        EligibleRole(id: id, eligibilityScheduleId: "e", roleDefinitionId: "\(sub)/providers/Microsoft.Authorization/roleDefinitions/\(guid)",
                     roleName: name, scope: sub, scopeName: "Contoso Staging", scopeType: "subscription", membership: .direct,
                     isActive: true, activeUntil: mon("14:00"), activeSince: mon("10:00"))
    }

    var owner: EligibleRole { roleNamed("Owner", guid: EligibleRole.ownerRoleGUID) }
    var uaa: EligibleRole { roleNamed("User Access Administrator", guid: AccessGrantingRole.userAccessAdministratorGUID) }
    var rbac: EligibleRole { roleNamed("Role Based Access Control Administrator", guid: AccessGrantingRole.rbacAdministratorGUID) }

    @Test func accessGrantingRolesNeedConfirmationOnce() {
        let contributor = role(until: mon("14:00"))
        #expect(owner.grantsAccess && uaa.grantsAccess && rbac.grantsAccess)
        #expect(!contributor.grantsAccess)
        let needing = KeepAliveConsent.needingConfirmation([contributor, owner, uaa, owner], confirmed: [], enabled: true)
        #expect(needing.map(\.roleName) == ["Owner", "User Access Administrator"])
        let confirmed = KeepAliveConsent.accessKeys([owner, contributor])
        #expect(confirmed == [ReminderRole.key(owner.policyKey)])
        #expect(KeepAliveConsent.needingConfirmation([owner, uaa], confirmed: confirmed, enabled: true).map(\.roleName) == ["User Access Administrator"])
        #expect(KeepAliveConsent.needingConfirmation([owner, rbac], confirmed: [], enabled: false).isEmpty, "the confirmation is off")
        let message = KeepAliveConsent.message([owner])
        #expect(message.contains("grant access"))
        #expect(message.contains("• Owner · Contoso Staging"))
    }

    @Test func anUnconfirmedAccessRoleIsNeverSent() {
        let key = ReminderRole.key(owner.policyKey)
        func status(_ confirmed: Set<String>?) -> KeepAliveStatus? {
            var book = KeepAliveBook()
            book[key] = track()
            return KeepAlivePlanner.plan(
                roles: [owner], rules: [key: KeepAliveRule()], policies: [owner.policyKey: policy()], infos: [:], pending: [],
                book: &book, hours: WorkingHours(), paused: false, now: mon("13:50"), calendar: calendar, confirmedAccess: confirmed
            ).first?.status
        }
        #expect(status([]) == .excluded(.notConfirmed))
        #expect(status([]).map(\.isExcluded) == true)
        #expect(status([key])?.action != nil)
        #expect(status(nil)?.action != nil, "no confirmation needed")
        #expect(KeepAliveStatus.excluded(.notConfirmed).summary(now: mon("13:50"), timeZone: utc).contains("not confirmed"))
    }

    @Test func keepAliveHasItsOwnHistorySource() throws {
        #expect(HistorySource.keepAlive.rawValue == "keepAlive")
        #expect(HistorySource.keepAlive.title == "Keep alive")
        let data = try JSONEncoder().encode(HistorySource.keepAlive)
        #expect(String(decoding: data, as: UTF8.self) == "\"keepAlive\"")
        #expect(try JSONDecoder().decode(HistorySource.self, from: data) == .keepAlive)
        let store = HistoryStore(url: TestTemp.url("keepalive-history").appendingPathComponent("history.jsonl"))
        let app = HistoryRecorder(store: store, source: .app)
        app.setTenantLabels(["11111111-2222-4333-8444-555555555555": "Contoso"])
        let keep = app.with(source: .keepAlive)
        #expect(keep.source == .keepAlive)
        #expect(keep.context(tenantId: "11111111-2222-4333-8444-555555555555").tenantLabel == "Contoso")
        #expect(app.source == .app)
    }

    @Test func whatAPassSendsIsRecordedAsKeepAlive() async throws {
        let demo = DemoFixture(start: KeepAliveDemoTests.start)
        let store = HistoryStore(url: TestTemp.url("keepalive-pass").appendingPathComponent("history.jsonl"))
        let service = demo.service().recording(to: HistoryRecorder(store: store, source: .app, clock: { [clock = demo.clock] in clock.now() }))
        let kv = try await demo.role("kv-contoso-prod", "Key Vault Secrets User")
        let clock = demo.clock
        let result = try await demo.offline {
            try await KeepAliveSession().pass(reader: service.readOnly, writer: service, perRole: [ReminderRole.key(kv.policyKey)], presets: [],
                                              hours: WorkingHours(), paused: false, calendar: calendar, clock: { clock.now() })
        }
        #expect(result.events.count == 1)
        let records = store.records(now: clock.now())
        #expect(records.count == 1)
        #expect(records.first?.source == .keepAlive)
        #expect(HistoryCSV.encode(records).contains("\"keepAlive\""))
    }
}
