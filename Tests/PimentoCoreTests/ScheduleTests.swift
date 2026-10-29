import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import PimentoCore

/// Thursday 2026-10-29, 19:11 in Berlin (CET, UTC+1).
private let berlin = TimeZone(identifier: "Europe/Berlin")!
private let thursdayEvening = AzureDate.parse("2026-10-29T18:11:00Z")!

private func at(_ text: String, now: Date = thursdayEvening) throws -> Date? {
    try ScheduleTime.parse(text, now: now, timeZone: berlin)
}

private func utc(_ s: String) -> Date { AzureDate.parse(s)! }

@Suite("Scheduled start: the --at grammar")
struct ScheduleTimeTests {
    @Test func nowMeansNoSchedule() throws {
        #expect(try at("now") == nil)
        #expect(try at("  NOW ") == nil)
        #expect(try ScheduleTime.resolve("now", now: thursdayEvening, timeZone: berlin) == nil)
    }

    @Test func relativeOffsets() throws {
        #expect(try at("+1h") == thursdayEvening.addingTimeInterval(3600))
        #expect(try at("+1h30m") == thursdayEvening.addingTimeInterval(5400))
        #expect(try at("+90min") == thursdayEvening.addingTimeInterval(5400))
        #expect(try at("+ 2d") == thursdayEvening.addingTimeInterval(2 * 86400))
        #expect(try at("+1d 2h") == thursdayEvening.addingTimeInterval(86400 + 7200))
        for bad in ["+90", "+0m", "+h", "+1x", "+-1h", "+"] {
            #expect(throws: ScheduleTimeError.unreadable(bad)) { try at(bad) }
        }
    }

    @Test func clockTimesAreTheNextOccurrence() throws {
        // 08:00 has passed today: tomorrow. 20:00 is still ahead: today.
        #expect(try at("08:00") == utc("2026-10-30T07:00:00Z"))
        #expect(try at("8") == utc("2026-10-30T07:00:00Z"))
        #expect(try at("0800") == utc("2026-10-30T07:00:00Z"))
        #expect(try at("20:00") == utc("2026-10-29T19:00:00Z"))
        #expect(throws: ScheduleTimeError.unreadable("25:00")) { try at("25:00") }
        #expect(throws: ScheduleTimeError.unreadable("8:5")) { try at("8:5") }
    }

    @Test func dayWords() throws {
        let tomorrow8 = utc("2026-10-30T07:00:00Z")
        #expect(try at("tomorrow 08:00") == tomorrow8)
        #expect(try at("tomorrow08:00") == tomorrow8)
        #expect(try at("Tomorrow 8") == tomorrow8)
        #expect(try at("today 21:30") == utc("2026-10-29T20:30:00Z"))
        // Weekdays: the next one; today when the time is still ahead.
        #expect(try at("mon 08:00") == utc("2026-11-02T07:00:00Z"))
        #expect(try at("Monday 9:15") == utc("2026-11-02T08:15:00Z"))
        #expect(try at("thu 20:00") == utc("2026-10-29T19:00:00Z"))
        #expect(try at("thu 08:00") == utc("2026-11-05T07:00:00Z"))
        // Next working day: Friday after a Thursday, Monday after a Friday or Saturday.
        #expect(try at("workday 08:00") == tomorrow8)
        #expect(try at("workday 08:00", now: utc("2026-10-30T18:00:00Z")) == utc("2026-11-02T07:00:00Z"))
        #expect(try at("workday 08:00", now: utc("2026-10-31T09:00:00Z")) == utc("2026-11-02T07:00:00Z"))
        #expect(throws: ScheduleTimeError.missingTime("tomorrow")) { try at("tomorrow") }
        #expect(throws: ScheduleTimeError.unreadable("someday 08:00")) { try at("someday 08:00") }
    }

    @Test func absoluteDatesInLocalTimeOrWithAZone() throws {
        #expect(try at("2026-11-02 08:00") == utc("2026-11-02T07:00:00Z"))
        #expect(try at("2026-11-02T08:00") == utc("2026-11-02T07:00:00Z"))
        #expect(try at("2026-11-02T08:00:30") == utc("2026-11-02T07:00:30Z"))
        #expect(try at("2026-11-02T08:00:00Z") == utc("2026-11-02T08:00:00Z"))
        #expect(try at("2026-11-02T08:00:00.000Z") == utc("2026-11-02T08:00:00Z"))
        #expect(try at("2026-11-02T08:00+02:00") == utc("2026-11-02T06:00:00Z"))
        #expect(try at("2026-11-02 08:00 -0500") == utc("2026-11-02T13:00:00Z"))
        #expect(throws: ScheduleTimeError.missingTime("2026-11-02")) { try at("2026-11-02") }
        #expect(throws: ScheduleTimeError.unreadable("2026-02-30 08:00")) { try at("2026-02-30 08:00") }
        #expect(throws: ScheduleTimeError.unreadable("2026-11-02 24:00")) { try at("2026-11-02 24:00") }
        #expect(throws: ScheduleTimeError.unreadable("banana")) { try at("banana") }
        #expect(throws: ScheduleTimeError.unreadable("")) { try at("  ") }
    }

    @Test func resolveRejectsThePastAndMoreThanAMonthAhead() throws {
        #expect(throws: ScheduleTimeError.inThePast("today 17:00")) {
            try ScheduleTime.resolve("today 17:00", now: thursdayEvening, timeZone: berlin)
        }
        #expect(throws: ScheduleTimeError.tooFarAhead("2026-12-15 08:00")) {
            try ScheduleTime.resolve("2026-12-15 08:00", now: thursdayEvening, timeZone: berlin)
        }
        #expect(try ScheduleTime.resolve("+30d", now: thursdayEvening, timeZone: berlin) != nil)
        #expect(throws: ScheduleTimeError.tooFarAhead("+31d")) { try ScheduleTime.resolve("+31d", now: thursdayEvening, timeZone: berlin) }
        #expect(ScheduleTimeError.tooFarAhead("x").errorDescription?.contains("a month") == true)
    }

    @Test func presetsOfTheAppsStartMenu() {
        #expect(ScheduleTime.Preset.inOneHour.date(now: thursdayEvening, timeZone: berlin) == utc("2026-10-29T19:11:00Z"))
        // Rounded up to the next whole minute.
        #expect(ScheduleTime.Preset.inOneHour.date(now: utc("2026-10-29T18:11:30Z"), timeZone: berlin) == utc("2026-10-29T19:12:00Z"))
        #expect(ScheduleTime.Preset.tomorrowMorning.date(now: thursdayEvening, timeZone: berlin) == utc("2026-10-30T07:00:00Z"))
        #expect(ScheduleTime.Preset.nextWorkingDayMorning.date(now: thursdayEvening, timeZone: berlin) == utc("2026-10-30T07:00:00Z"))
        #expect(ScheduleTime.Preset.nextWorkingDayMorning.date(now: utc("2026-10-30T10:00:00Z"), timeZone: berlin) == utc("2026-11-02T07:00:00Z"))
    }

    @Test func labels() {
        #expect(ScheduleTime.label(utc("2026-10-29T19:00:00Z"), now: thursdayEvening, timeZone: berlin) == "today 20:00")
        #expect(ScheduleTime.label(utc("2026-10-30T07:00:00Z"), now: thursdayEvening, timeZone: berlin) == "Fri 08:00")
        #expect(ScheduleTime.label(utc("2026-11-03T07:00:00Z"), now: thursdayEvening, timeZone: berlin) == "Tue 08:00")
        #expect(ScheduleTime.label(utc("2026-11-10T07:00:00Z"), now: thursdayEvening, timeZone: berlin) == "Tue 10 Nov 08:00")
    }
}

@Suite("Scheduled activation requests")
struct ScheduledActivationTests {
    @Test func aLaterStartGoesIntoScheduleInfo() throws {
        let role = try Fixture.role("Contoso Staging", "Contributor")
        let start = utc("2026-10-30T07:00:00Z")
        let plans = try ActivationRequestBuilder.plan(
            [role], principalId: Fixture.userOID, justification: "deploy", now: Fixture.now, start: start
        ) { _ in EffectiveDuration(minutes: 60, requested: .hours(1), policyMaxMinutes: nil) }
        #expect(plans[0].start == start)
        #expect(plans[0].plannedEnd == utc("2026-10-30T08:00:00Z"))
        #expect(plans[0].body.properties.scheduleInfo?.startDateTime == "2026-10-30T07:00:00.000Z")
        #expect(plans[0].body.properties.scheduleInfo?.expiration.duration == "PT1H")
        // Without a start, as before: now.
        let now = try ActivationRequestBuilder.plan([role], principalId: Fixture.userOID, justification: "x", hours: 1, now: Fixture.now)
        #expect(now[0].start == nil)
        #expect(now[0].body.properties.scheduleInfo?.startDateTime == "2026-10-29T12:00:00.000Z")
    }

    @Test func grantedWithAFutureStartIsScheduled() throws {
        let response = Data(#"{"properties":{"status":"Granted","scheduleInfo":{"startDateTime":"2026-10-30T07:00:00+00:00","expiration":{"type":"AfterDuration","duration":"PT1H"}}}}"#.utf8)
        let outcome = ActivationResponseMapper.outcome(
            for: .activate, statusCode: 201, data: response, requestedAt: Fixture.now, minutes: 60)
        #expect(outcome == .scheduled(status: "Granted", start: utc("2026-10-30T07:00:00Z"), until: utc("2026-10-30T08:00:00Z")))
        #expect(!outcome.isFailure)
        #expect(!outcome.leavesRoleActive)
        #expect(outcome.summary.hasPrefix("Scheduled for "))
        // No schedule in the answer: the asked start decides.
        let bare = ActivationResponseMapper.outcome(
            for: .activate, statusCode: 201, data: Data(#"{"properties":{"status":"Granted"}}"#.utf8),
            requestedAt: Fixture.now, minutes: 60, scheduledStart: utc("2026-10-30T07:00:00Z"))
        #expect(bare == .scheduled(status: "Granted", start: utc("2026-10-30T07:00:00Z"), until: utc("2026-10-30T08:00:00Z")))
        // Waiting for approval stays a submission; a start right now is an activation.
        let approval = ActivationResponseMapper.outcome(
            for: .activate, statusCode: 201, data: Data(#"{"properties":{"status":"PendingApproval"}}"#.utf8),
            requestedAt: Fixture.now, minutes: 60, scheduledStart: utc("2026-10-30T07:00:00Z"))
        #expect(approval == .activated(status: "PendingApproval", until: utc("2026-10-30T08:00:00Z")))
        let now = ActivationResponseMapper.outcome(
            for: .activate, statusCode: 201, data: try Fixture.data("success-response"), requestedAt: Fixture.now, minutes: 240)
        guard case .activated = now else { Issue.record("expected activated, got \(now)"); return }
    }

    @Test func tooFarAheadKeepsItsCode() {
        let data = Data(#"{"error":{"code":"ScheduleStartTimeTooFarAhead","message":"Schedule start time should be earlier than a month later."}}"#.utf8)
        let outcome = ActivationResponseMapper.outcome(for: .activate, statusCode: 400, data: data, requestedAt: Fixture.now, minutes: 60)
        #expect(outcome == .failed(code: ScheduleTime.tooFarAheadCode, message: "Schedule start time should be earlier than a month later."))
    }

    @Test func completionNotificationOfScheduledRoles() throws {
        let a = try Fixture.role("Contoso Staging", "Contributor")
        let b = try Fixture.role("Contoso Production", "Reader")
        let start = utc("2026-10-30T07:00:00Z")
        let outcomes: [String: ActivationOutcome] = [
            a.id: .scheduled(status: "Granted", start: start, until: start.addingTimeInterval(3600)),
            b.id: .scheduled(status: "Granted", start: start, until: start.addingTimeInterval(7200)),
        ]
        let summary = try #require(ActivationSummary(roles: [a, b], outcomes: outcomes, now: Fixture.now, timeZone: berlin))
        #expect(summary.title == "2 roles scheduled")
        #expect(summary.body.hasPrefix("starts Fri 08:00"))
        #expect(summary.body.contains("Contributor · Contoso Staging"))
        // Nothing is active yet: no expiry reminders.
        #expect(summary.reminders.isEmpty)
        #expect(!summary.isFailure)
    }
}

@Suite("Pending requests: list and cancel")
struct ScheduledRequestTests {
    func items() throws -> [AssignmentScheduleRequestItem] {
        try Fixture.decode("schedule-requests", as: ARMList<AssignmentScheduleRequestItem>.self).value
    }

    @Test func onlyPendingActivationsSoonestFirst() throws {
        let pending = ScheduledRequestParser.pending(try items(), principalId: Fixture.userOID, now: Fixture.now)
        #expect(pending.map(\.shortId) == ["7a1b2c3d", "5f0c1d2e", "9c9c9c9c"])
        #expect(pending.map(\.kind) == [.awaitingApproval, .scheduled, .scheduled])
        let owner = pending[1]
        #expect(owner.roleName == "Owner" && owner.scopeName == "rg-app-dev" && owner.isOwner)
        #expect(owner.start == utc("2026-10-30T07:00:00Z"))
        #expect(owner.end == utc("2026-10-30T09:00:00Z"))
        #expect(owner.durationMinutes == 120)
        #expect(owner.justification == "deploy window")
        #expect(owner.ticketNumber == nil)
        #expect(owner.scopeTypeLabel == "Resource group")
        #expect(pending[0].ticketNumber == "CHG-1001" && pending[0].ticketSystem == "ServiceNow")
        // AfterDateTime: the end as given.
        #expect(pending[2].end == utc("2026-11-02T16:00:00Z"))
        // Someone else's request is left out.
        #expect(ScheduledRequestParser.pending(try items(), principalId: "someone-else", now: Fixture.now).isEmpty)
    }

    @Test func kindByStatusAndStart() {
        let later = Fixture.now.addingTimeInterval(3600), earlier = Fixture.now.addingTimeInterval(-60)
        #expect(ScheduledRequest.kind(status: "Granted", start: later, now: Fixture.now) == .scheduled)
        #expect(ScheduledRequest.kind(status: "ScheduleCreated", start: later, now: Fixture.now) == .scheduled)
        #expect(ScheduledRequest.kind(status: "PendingScheduleCreation", start: later, now: Fixture.now) == .scheduled)
        #expect(ScheduledRequest.kind(status: "Granted", start: earlier, now: Fixture.now) == nil)
        #expect(ScheduledRequest.kind(status: "Provisioned", start: later, now: Fixture.now) == nil)
        #expect(ScheduledRequest.kind(status: "Canceled", start: later, now: Fixture.now) == nil)
        #expect(ScheduledRequest.kind(status: "PendingApproval", start: earlier, now: Fixture.now) == .awaitingApproval)
    }

    @Test func rowsFindTheirRequestsByScopeAndRole() throws {
        let pending = ScheduledRequestParser.pending(try items(), now: Fixture.now)
        let byRole = ScheduledRequestParser.byRole(pending)
        let row = try Fixture.role("rg-app-dev", "Owner")
        #expect(byRole[row.policyKey]?.map(\.shortId) == ["5f0c1d2e"])
    }

    @Test func cancelURLIsBuiltFromScopeAndName() throws {
        let r = try #require(ScheduledRequestParser.pending(try items(), now: Fixture.now).first { $0.shortId == "5f0c1d2e" })
        #expect(r.cancelURL?.absoluteString == "https://management.azure.com/subscriptions/cccccccc-0000-0000-0000-00000000000c/resourceGroups/rg-app-dev/providers/Microsoft.Authorization/roleAssignmentScheduleRequests/5f0c1d2e-0000-4000-8000-000000000001/cancel?api-version=2020-10-01")
        let evil = ScheduledRequest(id: "", name: "../../x", scope: "/subscriptions/a", roleDefinitionId: "r", roleName: "R",
                                    scopeName: "a", scopeType: "subscription", status: "Granted", start: Fixture.now, end: nil)
        #expect(evil.cancelURL == nil)
    }

    @Test func cancelOutcomes() {
        #expect(CancelOutcome.from(statusCode: 200, data: Data()) == .canceled)
        let gone = Data(#"{"error":{"code":"RequestCannotBeCancelled","message":"Request is not in cancellable state."}}"#.utf8)
        #expect(CancelOutcome.from(statusCode: 400, data: gone) == .notCancellable("Request is not in cancellable state."))
        #expect(CancelOutcome.from(statusCode: 400, data: gone).isFailure)
        let token = Data(#"{"error":{"code":"ExpiredAuthenticationToken","message":"expired"}}"#.utf8)
        #expect(CancelOutcome.from(statusCode: 401, data: token).isAuthFailure)
    }

    @Test func serviceListsAndCancelsOnlyThroughARM() async throws {
        let transport = RecordingTransport { request in
            if request.httpMethod == "POST" {
                return request.url!.path.contains("9c9c9c9c")
                    ? (Data(#"{"error":{"code":"RequestCannotBeCancelled","message":"no"}}"#.utf8), 400)
                    : (Data(), 200)
            }
            #expect(request.url!.absoluteString.contains("roleAssignmentScheduleRequests?api-version=2020-10-01&$filter=asTarget()"))
            return (try Fixture.data("schedule-requests"), 200)
        }
        let service = PIMService(transport: transport, tokens: StaticTokenProvider())
        let (identity, requests) = try await service.loadScheduledRequests(now: Fixture.now)
        #expect(identity.objectId == Fixture.userOID)
        #expect(requests.count == 3)
        let box = CancelBox()
        try await service.cancel(Array(requests.suffix(2))) { r, outcome in box.set(r.shortId, outcome) }
        #expect(box.values == ["5f0c1d2e": .canceled, "9c9c9c9c": .notCancellable("no")])
        let posts = await transport.requests.filter { $0.httpMethod == "POST" }
        #expect(posts.count == 2)
        #expect(posts.allSatisfy { $0.url!.host == ARM.host && $0.url!.path.hasSuffix("/cancel") })
        #expect(posts.allSatisfy { $0.value(forHTTPHeaderField: "Authorization")?.hasPrefix("Bearer ") == true })

        // A read-only service cannot cancel.
        let readOnly = PIMService(transport: ReadOnlyTransport(transport), tokens: StaticTokenProvider())
        let refused = CancelBox()
        try await readOnly.cancel([requests[1]]) { r, outcome in refused.set(r.shortId, outcome) }
        guard case .failed(let code, _)? = refused.values["5f0c1d2e"] else { Issue.record("expected a refusal"); return }
        #expect(code == "NetworkError")
    }
}

final class CancelBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String: CancelOutcome] = [:]
    func set(_ key: String, _ value: CancelOutcome) { lock.withLock { stored[key] = value } }
    var values: [String: CancelOutcome] { lock.withLock { stored } }
}

@Suite("Scheduled start notifications")
struct ScheduledStartNoticeTests {
    @Test func oneNoticePerTenantAndStartMinute() throws {
        let items = try Fixture.decode("schedule-requests", as: ARMList<AssignmentScheduleRequestItem>.self).value
        let pending = ScheduledRequestParser.pending(items, now: Fixture.now)
        let notices = ScheduledStartNotice.notices(for: pending, tenantId: "AAAA-Tenant", now: Fixture.now, timeZone: berlin)
        // The request awaiting approval gets none.
        #expect(notices.count == 2)
        #expect(notices[0].id == "scheduled-aaaa-tenant-" + String(Int(utc("2026-10-30T07:00:00Z").timeIntervalSince1970)))
        #expect(notices[0].fireAt == utc("2026-10-30T07:00:00Z"))
        #expect(notices[0].title == "Scheduled activation started")
        #expect(notices[0].body == "Owner · rg-app-dev, until 10:00")
        #expect(notices.allSatisfy { $0.id.hasPrefix(ScheduledStartNotice.idPrefix(tenantId: "aaaa-tenant")) })
        #expect(notices.allSatisfy { ScheduledStartNotice.isNotice($0.id) })
        #expect(ScheduledStartNotice.idPrefix(tenantId: nil) == "scheduled-default-")
        // Started ones are dropped.
        #expect(ScheduledStartNotice.notices(for: pending, tenantId: nil, now: utc("2026-10-31T00:00:00Z")).count == 1)
    }

    @Test func severalRolesAtOneMinuteShareANotice() {
        let start = utc("2026-10-30T07:00:20Z")
        let requests = (1...5).map { i in
            ScheduledRequest(id: "\(i)", name: "\(i)", scope: "/subscriptions/s\(i)", roleDefinitionId: "r", roleName: "Reader",
                             scopeName: "Sub \(i)", scopeType: "subscription", status: "Granted", start: start, end: nil)
        }
        let notices = ScheduledStartNotice.notices(for: requests, tenantId: nil, now: Fixture.now, timeZone: berlin)
        #expect(notices.count == 1)
        #expect(notices[0].title == "Scheduled activations started (5 roles)")
        #expect(notices[0].body.hasSuffix("and 2 more"))
        #expect(notices[0].fireAt == utc("2026-10-30T07:00:00Z"))
    }
}
