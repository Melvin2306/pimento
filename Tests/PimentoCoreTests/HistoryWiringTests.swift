import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import PimentoCore

/// Every write path records exactly one history entry per role (or request),
/// whatever the outcome; reads record nothing.
@Suite("History wiring")
struct HistoryWiringTests {
    static let tenant = "00000000-0000-4000-8000-0000000000aa"
    let store = HistoryStore(url: temporaryHistoryURL())
    var tokens: StaticTokenProvider {
        StaticTokenProvider(token: fakeToken(["oid": Fixture.userOID, "name": "Test User", "tid": Self.tenant]))
    }

    func service(_ transport: HTTPTransport, source: HistorySource = .app) -> PIMService {
        let recorder = HistoryRecorder(store: store, source: source, clock: { Fixture.now })
        recorder.setTenantLabels([Self.tenant: "Contoso"])
        return PIMService(transport: transport, tokens: tokens, sleep: { _ in }, clock: { Fixture.now }, history: recorder)
    }

    static func requestType(_ request: URLRequest) -> String {
        let body = (try? JSONSerialization.jsonObject(with: request.httpBody ?? Data())) as? [String: Any]
        return (body?["properties"] as? [String: Any])?["requestType"] as? String ?? "?"
    }

    @Test func activationsOneRecordPerRoleWhateverTheOutcome() async throws {
        let roles = try [Fixture.role("Contoso Staging", "Contributor"), Fixture.role("Contoso Production", "Reader"),
                         Fixture.role("rg-app-dev", "Owner")]
        let plans = try ActivationRequestBuilder.plan(roles, principalId: Fixture.userOID, justification: "release", hours: 2, now: Fixture.now)
        let ok = try Fixture.data("success-response")
        let transport = RecordingTransport { request in
            if request.url!.path.contains("rg-app-dev") { return (try Fixture.data("error-policy"), 400) }
            if request.url!.path.contains("bbbbbbbb") { return (try Fixture.data("error-exists"), 400) }
            return (ok, 201)
        }
        try await service(transport).execute(plans) { _, _ in }
        let records = store.load().records
        #expect(records.count == plans.count)
        #expect(Set(records.compactMap(\.requestId)) == Set(plans.map(\.requestId)))
        #expect(records.allSatisfy { $0.action == .activate && $0.source == .app && $0.tenantId == Self.tenant && $0.tenantLabel == "Contoso" })
        #expect(records.allSatisfy { $0.justification == "release" && $0.at == Fixture.now && $0.version == AppInfo.version })
        #expect(Set(records.map(\.result)) == [.failed, .skipped, .succeeded])
        // Nothing of the request or response body beyond the short message.
        let text = try String(contentsOf: store.url, encoding: .utf8)
        #expect(!text.contains("principalId") && !text.contains("linkedRoleEligibilityScheduleId") && !text.contains("Bearer"))
    }

    @Test func scheduledActivationsAreSchedules() async throws {
        let start = Fixture.now.addingTimeInterval(86400)
        let plans = try ActivationRequestBuilder.plan(
            [try Fixture.role("Contoso Staging", "Contributor")], principalId: Fixture.userOID, justification: "later", now: Fixture.now, start: start
        ) { _ in EffectiveDuration(minutes: 60, requested: .hours(1), policyMaxMinutes: nil) }
        let granted = Data(#"{"properties":{"status":"Granted","scheduleInfo":{"startDateTime":"2026-10-30T12:00:00Z","expiration":{"endDateTime":"2026-10-30T13:00:00Z"}}}}"#.utf8)
        try await service(RecordingTransport { _ in (granted, 201) }).execute(plans) { _, _ in }
        let records = store.load().records
        #expect(records.map(\.action) == [.schedule])
        #expect(records[0].start == start && records[0].result == .succeeded && records[0].status == "Granted")
    }

    @Test func deactivationsAndExtensions() async throws {
        let active = try Fixture.role("Contoso Production", "Owner")
        let off = try ActivationRequestBuilder.deactivationPlan([active], principalId: Fixture.userOID)
        let transport = RecordingTransport { _ in (Data(#"{"properties":{"status":"Revoked"}}"#.utf8), 201) }
        try await service(transport).execute(off) { _, _ in }
        let assignment = ActiveAssignment(
            id: "a", scheduleId: "/x/roleAssignmentSchedules/s1", roleDefinitionId: active.roleDefinitionId, roleName: "Owner",
            scope: active.scope, scopeName: active.scopeName, scopeType: active.scopeType, start: Fixture.now, end: Fixture.now.addingTimeInterval(86400))
        let ext = try ActivationRequestBuilder.extensionPlan([assignment], principalId: Fixture.userOID, justification: "project", days: 30)
        let pending = RecordingTransport { _ in (Data(#"{"properties":{"status":"PendingAdminDecision"}}"#.utf8), 201) }
        try await service(pending, source: .cli).execute(ext) { _, _ in }
        let records = store.load().records
        #expect(records.map(\.action) == [.deactivate, .extend])
        #expect(records.map(\.result) == [.succeeded, .pending])
        #expect(records.map(\.source) == [.app, .cli])
        #expect(records[1].requestedDuration == "P30D")
    }

    @Test func aRenewalIsOneRecordHowEverManyAttempts() async throws {
        let owner = try Fixture.role("rg-app-dev", "Owner")
        let reader = try Fixture.role("Contoso Production", "Owner")
        let plans = try ActivationRequestBuilder.renewPlan([owner, reader], principalId: Fixture.userOID, justification: "on-call", now: Fixture.now) { _ in
            EffectiveDuration(minutes: 60, requested: .hours(1), policyMaxMinutes: nil)
        }
        let attempts = AttemptCounter()
        let ok = try Fixture.data("success-response")
        let transport = RecordingTransport { request in
            if Self.requestType(request) == "SelfDeactivate" { return (Data(#"{"properties":{"status":"Revoked"}}"#.utf8), 201) }
            // The first two activations of each role are refused while PIM catches up.
            return attempts.next(request.url!.path.components(separatedBy: "/providers/")[0]) <= 2
                ? (Data(#"{"error":{"code":"RoleAssignmentExists","message":"x"}}"#.utf8), 400) : (ok, 201)
        }
        try await service(transport).renew(plans) { _, _ in }
        let records = store.load().records
        #expect(records.count == 2)
        #expect(records.allSatisfy { $0.action == .renew && $0.result == .succeeded && $0.durationMinutes == 60 })
        // The request id is the activation that finally went through; the deactivation is related.
        let puts = await transport.requests.filter { Self.requestType($0) == "SelfActivate" }
        #expect(puts.count == 6)
        let lastIds = Set(records.compactMap(\.requestId))
        for scope in [owner.scope, reader.scope] {
            let last = puts.last { $0.url!.path.hasPrefix(scope + "/providers/") }!.url!.lastPathComponent
            #expect(lastIds.contains(last))
        }
        #expect(Set(records.compactMap(\.relatedRequestId)) == Set(plans.map(\.deactivation.requestId)))
    }

    @Test func cancelsAndDecisions() async throws {
        let transport = RecordingTransport { request in
            if request.httpMethod == "POST" {
                return request.url!.path.contains("9c9c9c9c") ? (Data(#"{"error":{"code":"RequestCannotBeCancelled","message":"no"}}"#.utf8), 400) : (Data(), 200)
            }
            if request.httpMethod == "PATCH" { return (Data(), 200) }
            return (try Fixture.data("schedule-requests"), 200)
        }
        let service = service(transport)
        let (_, requests) = try await service.loadScheduledRequests(now: Fixture.now)
        #expect(store.load().records.isEmpty, "reading records nothing")
        try await service.cancel(requests) { _, _ in }
        var records = store.load().records
        #expect(records.count == requests.count)
        #expect(records.allSatisfy { $0.action == .cancel })
        #expect(records.filter { $0.result == .failed }.map(\.status) == ["RequestCannotBeCancelled"])

        let approval = ApprovalRequest(
            id: "/x/a1a1a1a1-0000-4000-8000-000000000011", name: "a1a1a1a1-0000-4000-8000-000000000011",
            approvalId: "a1a1a1a1-0000-4000-8000-000000000011",
            stage: ApprovalStage(id: "5a5a5a5a-0000-4000-8000-000000000021", status: "InProgress", assignedToMe: true),
            scope: "/subscriptions/s", roleDefinitionId: "r/b24988ac-6180-42a0-ab88-20f7382dd24c", roleName: "Contributor",
            scopeName: "Contoso Staging", scopeType: "subscription", requesterId: "u2", requesterName: "Megan Bowen",
            requesterEmail: "megan@contoso.example", justification: "hotfix")
        var other = approval
        other.stage = nil
        let plans = try PlannedDecision.plan([approval, other], decision: .deny, justification: "not now")
        try await service.decide(plans) { _, _ in }
        records = store.load().records.filter { $0.action == .deny }
        #expect(records.count == 2)
        #expect(records.map(\.result).sorted() == [.skipped, .succeeded])
        #expect(records.allSatisfy { $0.justification == "not now" && $0.requester == "Megan Bowen <megan@contoso.example>" })
    }

    @Test func noRecorderOrHistoryOffRecordsNothing() async throws {
        let plans = try ActivationRequestBuilder.plan([try Fixture.role("Contoso Staging", "Contributor")], principalId: Fixture.userOID,
                                                      justification: "x", hours: 1, now: Fixture.now)
        let ok = try Fixture.data("success-response")
        try await PIMService(transport: RecordingTransport { _ in (ok, 201) }, tokens: tokens).execute(plans) { _, _ in }
        #expect(!FileManager.default.fileExists(atPath: store.url.path))
        try store.saveSettings(HistorySettings(enabled: false))
        try await service(RecordingTransport { _ in (ok, 201) }).execute(plans) { _, _ in }
        #expect(store.load().records.isEmpty)
    }
}

final class AttemptCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var counts: [String: Int] = [:]
    func next(_ key: String) -> Int {
        lock.withLock {
            counts[key, default: 0] += 1
            return counts[key]!
        }
    }
}
