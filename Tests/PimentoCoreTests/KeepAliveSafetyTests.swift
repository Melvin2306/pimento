import Foundation
import Testing
@testable import PimentoCore

// Keep-alive must never bring back a role you ended, renew while paused, or
// pile up requests: the cases a pass could miss with only its own memory.

private let utc = TimeZone(identifier: "UTC")!
private let calendar: Calendar = {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = utc
    return c
}()

private func at(_ text: String) -> Date { AzureDate.parse(text.count == 16 ? text + ":00Z" : text)! }
/// Monday 2026-11-02, UTC.
private func mon(_ time: String) -> Date { at("2026-11-02T\(time)") }

private let sub = "/subscriptions/bbbbbbbb-0000-0000-0000-00000000000b"
private let contributor = "\(sub)/providers/Microsoft.Authorization/roleDefinitions/b24988ac-6180-42a0-ab88-20f7382dd24c"

private func role(until: Date? = nil, since: Date? = nil) -> EligibleRole {
    EligibleRole(
        id: "row-1", eligibilityScheduleId: "\(sub)/providers/Microsoft.Authorization/roleEligibilitySchedules/e1",
        roleDefinitionId: contributor, roleName: "Contributor", scope: sub, scopeName: "Contoso Staging", scopeType: "subscription",
        membership: .direct, isActive: until != nil, activeUntil: until, activeSince: since ?? until.map { $0.addingTimeInterval(-3600) },
        activeScheduleId: until == nil ? nil : "\(sub)/providers/Microsoft.Authorization/roleAssignmentSchedules/aaaaaaaa-0000-4000-8000-000000000001")
}

private let loaded = PolicyLookup.loaded(RolePolicy(maximumDuration: 8 * 3600, requiresJustification: true, requiresTicket: false,
                                                    requiresApproval: false))

private func track(lastEnd: Date? = nil, lastStart: Date? = nil, handOver: KeepAliveTrack.HandOver? = nil) -> KeepAliveTrack {
    var t = KeepAliveTrack()
    t.justification = "Deploy release 2.4"
    t.lastEnd = lastEnd
    t.lastStart = lastStart
    t.handOver = handOver
    return t
}

private func handOver(_ start: Date, created: Date? = nil) -> KeepAliveTrack.HandOver {
    .init(start: start, until: start.addingTimeInterval(4 * 3600), requestName: "n1", scope: sub, roleDefinitionId: contributor,
          created: created)
}

private func request(start: Date, created: Date, kind: ScheduledRequest.Kind = .scheduled,
                     name: String = "cccccccc-0000-4000-8000-000000000001") -> ScheduledRequest {
    ScheduledRequest(id: "", name: name, scope: sub, roleDefinitionId: contributor, roleName: "Contributor", scopeName: "Contoso Staging",
                     scopeType: "subscription", status: kind == .scheduled ? "Granted" : "PendingApproval", start: start,
                     end: start.addingTimeInterval(3600), createdOn: created, kind: kind)
}

private func decide(_ r: EligibleRole, now: Date, pending: [ScheduledRequest] = [], track t: KeepAliveTrack = track(),
                    paused: Bool = false, deactivatedAt: Date? = nil) -> KeepAliveStatus {
    KeepAlive.decide(role: r, rule: KeepAliveRule(), policy: loaded, pending: pending, track: t, hours: WorkingHours(), paused: paused,
                     now: now, calendar: calendar, deactivatedAt: deactivatedAt)
}

@Suite("Keep-alive: never over-grant")
struct KeepAliveSafetyTests {
    @Test func aRoleEndedWhileNoPassRanIsNotBroughtBack() {
        // Active 09:00–14:00; ended (portal) at 12:00 while the Mac slept; looked at again at 15:00.
        let t = track(lastEnd: mon("14:00"), lastStart: mon("09:00"))
        #expect(decide(role(), now: mon("15:00"), track: t, deactivatedAt: mon("12:00")) == .endedEarly)
        // A deactivation of an earlier activation does not count: it lapsed, and is activated again.
        #expect(decide(role(), now: mon("15:00"), track: t, deactivatedAt: mon("08:00")).action != nil)
    }

    @Test func aContinuationIsWithdrawnWhenTheRoleWasEndedAfterItWasScheduled() {
        let tracked = handOver(mon("14:00"), created: mon("13:45"))
        // Ended at 13:50: the tracked continuation is withdrawn, even when the pass only runs at 13:59.
        #expect(decide(role(), now: mon("13:59"), track: track(lastEnd: mon("14:00"), lastStart: mon("10:00"), handOver: tracked),
                       deactivatedAt: mon("13:50")) == .act(.cancel(tracked)))
        // Not tracked (Pimento restarted, or another Pimento sent it), nothing remembered: still withdrawn.
        let pending = request(start: mon("14:00"), created: mon("13:45"))
        #expect(decide(role(), now: mon("13:52"), pending: [pending], deactivatedAt: mon("13:50")) == .act(.cancel(.init(pending))))
        // Remembered end, not tracked: ended early, withdrawn.
        #expect(decide(role(), now: mon("13:52"), pending: [pending], track: track(lastEnd: mon("14:00"))) == .act(.cancel(.init(pending))))
        // A request you scheduled yourself well ahead is yours: left alone.
        let yours = request(start: mon("14:00"), created: mon("09:00"))
        #expect(decide(role(), now: mon("13:52"), pending: [yours], deactivatedAt: mon("13:50")) == .continued(start: mon("14:00"), until: mon("15:00")))
    }

    @Test func aTrackedContinuationOfAReplacedActivationIsWithdrawn() {
        // Ended and activated again (until 17:00) before Pimento looked: the continuation at 14:00 would start in the middle.
        let h = handOver(mon("14:00"), created: mon("13:45"))
        #expect(decide(role(until: mon("17:00"), since: mon("13:48")), now: mon("13:50"), track: track(lastEnd: mon("14:00"), handOver: h))
            == .act(.cancel(h)))
        // The continuation of the current activation stays.
        #expect(decide(role(until: mon("14:00")), now: mon("13:50"), track: track(lastEnd: mon("14:00"), handOver: h))
            == .continued(start: mon("14:00"), until: mon("18:00")))
    }

    @Test func pausedWithdrawsContinuationsAndForgetsWhatLapses() {
        let h = handOver(mon("14:00"), created: mon("13:45"))
        #expect(decide(role(until: mon("14:00")), now: mon("13:50"), track: track(handOver: h), paused: true) == .act(.cancel(h)))
        // One Pimento did not track (sent before a restart) that continues the activation: withdrawn too.
        let pending = request(start: mon("14:00"), created: mon("13:45"))
        #expect(decide(role(until: mon("14:00")), now: mon("13:50"), pending: [pending], paused: true) == .act(.cancel(.init(pending))))
        // Yours (scheduled long before): left alone.
        #expect(decide(role(until: mon("14:00")), now: mon("13:50"), pending: [request(start: mon("14:00"), created: mon("08:00"))],
                       paused: true) == .paused)

        // A pass while paused (a refresh) sees the role active; it lapses; on resume it is not brought back.
        let r = role(until: mon("14:00"))
        let key = ReminderRole.key(r.policyKey)
        var book = KeepAliveBook()
        func plan(_ role: EligibleRole, now: Date, paused: Bool) -> KeepAliveStatus? {
            KeepAlivePlanner.plan(roles: [role], rules: [key: KeepAliveRule()], policies: [r.policyKey: loaded], infos: [:], pending: [],
                                  book: &book, hours: WorkingHours(), paused: paused, now: now, calendar: calendar).first?.status
        }
        #expect(plan(r, now: mon("12:00"), paused: true) == .paused)
        #expect(plan(role(), now: mon("15:00"), paused: false) == .notActive)
    }

    @Test func afterPauseAndResumeTheRoleIsContinuedAgain() {
        var book = KeepAliveBook()
        book["k"] = track(lastEnd: mon("14:00"), handOver: handOver(mon("14:00"), created: mon("13:45")))
        #expect(book.pause(now: mon("13:47")).count == 1)
        // Resumed at 13:48: the withdrawn continuation is not taken for a scheduled one.
        #expect(decide(role(until: mon("14:00")), now: mon("13:48"), track: book["k"]).action != nil)
    }

    @Test func withdrawalsBackOff() {
        var t = track(lastEnd: mon("14:00"), handOver: handOver(mon("14:00"), created: mon("13:45")))
        t.failed("throttled", now: mon("13:50"))
        #expect(decide(role(), now: mon("13:50"), track: t) == .retryLater(at: mon("13:51"), failures: 1))
        #expect(decide(role(), now: mon("13:51"), track: t).isWithdrawal == true)
        // A long backoff (after a failed renewal) still leaves one try shortly before the start.
        t.failed("throttled", now: mon("13:51"))
        t.failed("throttled", now: mon("13:52"))
        #expect(decide(role(), now: mon("13:53"), track: t) == .retryLater(at: mon("13:58"), failures: 3))
    }

    @Test func aRequestWaitingForApprovalStopsFurtherOnes() {
        // The policy was read without approval; an administrator turned it on since: the first renewal now waits.
        let waiting = request(start: mon("13:46"), created: mon("13:46"), kind: .awaitingApproval)
        #expect(decide(role(until: mon("14:00")), now: mon("13:50"), pending: [waiting]) == .excluded(.needsApproval))
    }

    @Test func itLooksAgainShortlyBeforeAContinuationStarts() {
        #expect(KeepAliveStatus.continued(start: mon("14:00"), until: nil).nextCheck(now: mon("13:46")) == mon("13:58"))
        #expect(KeepAliveStatus.continued(start: mon("14:00"), until: nil).nextCheck(now: mon("13:58")) == mon("14:03"))
    }

    @Test func overnightWindowsFollowDaylightSavingTime() {
        var berlin = Calendar(identifier: .gregorian)
        berlin.timeZone = TimeZone(identifier: "Europe/Berlin")!
        // Saturday 22:00 CEST to Sunday 06:00 CET, across the change back: 9 hours.
        let night = WorkingHours(days: [7], start: ClockTime(hour: 22, minute: 0), end: ClockTime(hour: 6, minute: 0))
        let window = night.window(containing: at("2026-10-25T01:30"), calendar: berlin)
        #expect(window == DateInterval(start: at("2026-10-24T20:00"), end: at("2026-10-25T05:00")))
        // Ending 03:30 CET (02:30Z) with 8 hours allowed: shortened to the 2 whole hours left.
        let r = role(until: at("2026-10-25T02:30"))
        #expect(KeepAlive.decide(role: r, rule: KeepAliveRule(), policy: loaded, pending: [], track: track(), hours: night, paused: false,
                                 now: at("2026-10-25T02:20"), calendar: berlin).action
            == .handOver(start: at("2026-10-25T02:30"), minutes: 120, clipped: true, justification: "Deploy release 2.4", ticket: nil))
    }

    @Test func deactivationsAreReadFromYourRequests() throws {
        let json = """
        {"value": [
          {"name": "d1", "properties": {"requestType": "SelfDeactivate", "status": "Revoked", "scope": "\(sub)/",
           "roleDefinitionId": "\(contributor.uppercased())", "createdOn": "2026-11-02T12:00:00Z", "principalId": "me"}},
          {"name": "d0", "properties": {"requestType": "SelfDeactivate", "status": "Revoked", "scope": "\(sub)",
           "roleDefinitionId": "\(contributor)", "createdOn": "2026-11-01T12:00:00Z", "principalId": "me"}},
          {"name": "a1", "properties": {"requestType": "SelfActivate", "status": "Provisioned", "scope": "\(sub)",
           "roleDefinitionId": "\(contributor)", "createdOn": "2026-11-02T13:00:00Z", "principalId": "me"}}
        ]}
        """
        struct Page: Decodable { let value: [AssignmentScheduleRequestItem] }
        let items = try JSONDecoder().decode(Page.self, from: Data(json.utf8)).value
        let history = RequestHistory(identity: Identity(objectId: "me", name: nil, upn: nil, tenantId: nil), items: items, now: mon("14:00"))
        #expect(history.deactivations == [ReminderRole.key(role().policyKey): mon("12:00")])
    }
}

@Suite("Keep-alive: never over-grant, against the demo simulator")
struct KeepAliveSafetyDemoTests {
    static let start = AzureDate.parse("2026-10-30T09:30:00Z")!

    func pass(_ session: KeepAliveSession, _ demo: DemoFixture, perRole: Set<String>, paused: Bool = false,
              dryRun: Bool = false) async throws -> KeepAlivePassResult {
        let service = demo.service()
        let clock = demo.clock
        return try await demo.offline {
            try await session.pass(reader: service.readOnly, writer: dryRun ? service.readOnly : service, perRole: perRole, presets: [],
                                   hours: WorkingHours(), paused: paused, calendar: calendar, clock: { clock.now() }, dryRun: dryRun)
        }
    }

    func kv(_ demo: DemoFixture) async throws -> EligibleRole { try await demo.role("kv-contoso-prod", "Key Vault Secrets User") }

    func continuation(_ demo: DemoFixture, of role: EligibleRole) async throws -> ScheduledRequest? {
        try await demo.service().loadScheduledRequests(now: demo.clock.now()).requests
            .first { $0.policyKey == role.policyKey && $0.kind == .scheduled }
    }

    @Test func aContinuationSentBeforeARestartIsWithdrawnWhenTheRoleIsEnded() async throws {
        let demo = DemoFixture(start: Self.start)
        let role = try await kv(demo)
        let key = ReminderRole.key(role.policyKey)
        _ = try await pass(KeepAliveSession(), demo, perRole: [key])
        #expect(try await continuation(demo, of: role) != nil, "scheduled for 09:38")
        // Pimento restarts and looks once; then the role is ended in the portal.
        let restarted = KeepAliveSession()
        demo.clock.advance(by: 60)
        #expect(try await pass(restarted, demo, perRole: [key]).items.first?.status == .continued(start: at("2026-10-30T09:38"),
                                                                                                 until: at("2026-10-30T10:38")))
        demo.clock.advance(by: 60)
        _ = try await demo.deactivate(try await kv(demo))
        let after = try await pass(restarted, demo, perRole: [key])
        #expect(after.events.count == 1)
        #expect(after.events.first.map { if case .withdrawn = $0 { true } else { false } } == true)
        #expect(try await continuation(demo, of: role) == nil)
        demo.clock.advance(by: 10 * 60)
        #expect(try await kv(demo).isActive == false, "not brought back at 09:38")
    }

    @Test func aContinuationIsWithdrawnByAPimentoThatNeverSawTheRoleActive() async throws {
        let demo = DemoFixture(start: Self.start)
        let role = try await kv(demo)
        let key = ReminderRole.key(role.policyKey)
        _ = try await pass(KeepAliveSession(), demo, perRole: [key])
        demo.clock.advance(by: 60)
        _ = try await demo.deactivate(try await kv(demo))
        // Started after the role was ended (or another Pimento, or the CLI): it knows nothing, the requests tell.
        _ = try await pass(KeepAliveSession(), demo, perRole: [key])
        #expect(try await continuation(demo, of: role) == nil)
        demo.clock.advance(by: 10 * 60)
        #expect(try await kv(demo).isActive == false)
    }

    @Test func aRoleEndedWhileTheMacSleptIsNotActivatedOnWake() async throws {
        let demo = DemoFixture(start: Self.start)
        let session = KeepAliveSession()
        let dev = try await demo.role("Contoso Development", "Contributor")
        let key = ReminderRole.key(dev.policyKey)
        #expect(try await pass(session, demo, perRole: [key]).items.first?.status == .waiting(until: at("2026-10-30T14:25")))
        // Ended in the portal at 10:00; the Mac slept from then until 16:00 (it would have ended at 14:40).
        demo.clock.advance(by: 30 * 60)
        _ = try await demo.deactivate(dev)
        demo.clock.advance(by: 6 * 3600)
        let woke = try await pass(session, demo, perRole: [key])
        #expect(woke.events.isEmpty)
        #expect(woke.items.first?.status == .endedEarly)
        #expect(try await demo.role("Contoso Development", "Contributor").isActive == false)
    }

    @Test func pausingAfterARestartWithdrawsTheContinuation() async throws {
        let demo = DemoFixture(start: Self.start)
        let role = try await kv(demo)
        let key = ReminderRole.key(role.policyKey)
        _ = try await pass(KeepAliveSession(), demo, perRole: [key])
        let restarted = KeepAliveSession()
        demo.clock.advance(by: 60)
        _ = try await pass(restarted, demo, perRole: [key], paused: true)
        #expect(try await continuation(demo, of: role) == nil)
        demo.clock.advance(by: 10 * 60)
        #expect(try await kv(demo).isActive == false, "paused: it ends at 09:38")
    }

    @Test func aRoleNoLongerKeptAliveHasItsContinuationWithdrawn() async throws {
        // Turned off while a pass was sending its continuation: the next pass withdraws it.
        let demo = DemoFixture(start: Self.start)
        let session = KeepAliveSession()
        let role = try await kv(demo)
        _ = try await pass(session, demo, perRole: [ReminderRole.key(role.policyKey)])
        #expect(try await continuation(demo, of: role) != nil)
        demo.clock.advance(by: 30)
        _ = try await pass(session, demo, perRole: [])
        #expect(try await continuation(demo, of: role) == nil)
        #expect(await session.book.tracks.isEmpty)
    }

    /// A transport that resets `session` once, on the first request whose
    /// method is `method`, while the pass waits for it (the actor is free then).
    struct ResettingTransport: HTTPTransport {
        let base: HTTPTransport
        let session: KeepAliveSession
        let method: String
        let done = Flag()
        final class Flag: @unchecked Sendable {
            private let lock = NSLock()
            private var set = false
            func once() -> Bool { lock.withLock { defer { set = true }; return !set } }
        }
        func send(_ request: URLRequest) async throws -> (Data, Int) {
            if request.httpMethod ?? "GET" == method, done.once() { await session.reset() }
            return try await base.send(request)
        }
    }

    /// Another tenant or account while a pass waits for Azure: the pass stops
    /// and leaves the new session's memory empty, even after sending.
    @Test func aResetDuringAPassIsNotUndoneByIt() async throws {
        for method in ["GET", "PUT"] {
            let demo = DemoFixture(start: Self.start)
            let session = KeepAliveSession()
            let key = ReminderRole.key(try await kv(demo).policyKey)
            let clock = demo.clock
            let service = PIMService(transport: ResettingTransport(base: demo.azure, session: session, method: method),
                                     tokens: demo.azure.cliTokens(tenantId: nil), sleep: { clock.advance(by: $0) }, clock: { clock.now() })
            await #expect(throws: KeepAliveSessionReset.self, "\(method)") {
                try await demo.offline {
                    try await session.pass(reader: service.readOnly, writer: service, perRole: [key], presets: [], hours: WorkingHours(),
                                           paused: false, calendar: calendar, clock: { clock.now() })
                }
            }
            #expect(await session.book.tracks.isEmpty, "\(method)")
            let sent = demo.azure.requestLog.filter { $0.hasPrefix("PUT") }.count
            // Reset while reading: nothing sent. While sending: that one request only.
            #expect(sent == (method == "GET" ? 0 : 1), "\(method): \(demo.azure.requestLog)")
        }
    }

    @Test func policiesAreReadAgainAfterAnHour() async throws {
        let demo = DemoFixture(start: Self.start)
        let session = KeepAliveSession()
        let role = try await kv(demo)
        let key = ReminderRole.key(role.policyKey)
        func policyReads() -> Int { demo.azure.requestLog.filter { $0.lowercased().contains("rolemanagementpolicyassignments") }.count }
        _ = try await pass(session, demo, perRole: [key], dryRun: true)
        let first = policyReads()
        #expect(first > 0)
        demo.clock.advance(by: 20 * 60)
        _ = try await pass(session, demo, perRole: [key], dryRun: true)
        #expect(policyReads() == first, "read once an hour")
        demo.clock.advance(by: 45 * 60)
        _ = try await pass(session, demo, perRole: [key], dryRun: true)
        #expect(policyReads() > first)
    }
}
