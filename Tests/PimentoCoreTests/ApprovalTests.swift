import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import PimentoCore

/// A `roleAssignmentScheduleRequests` item of yours, synthetic.
func requestItem(
    _ name: String, status: String, start: String = "2026-10-29T11:50:00Z", duration: String = "PT4H",
    principal: String = Fixture.userOID, approvalId: String? = nil, role: String = "Contributor", scopeName: String = "Contoso Staging",
    createdOn: String = "2026-10-29T11:50:00Z", requestType: String = "SelfActivate", ticket: (String, String)? = nil
) -> AssignmentScheduleRequestItem {
    var props: [String: Any] = [
        "scope": "/subscriptions/bbbbbbbb-0000-0000-0000-00000000000b",
        "roleDefinitionId": "/subscriptions/bbbbbbbb-0000-0000-0000-00000000000b/providers/Microsoft.Authorization/roleDefinitions/b24988ac-6180-42a0-ab88-20f7382dd24c",
        "principalId": principal, "requestType": requestType, "status": status, "createdOn": createdOn,
        "scheduleInfo": ["startDateTime": start, "expiration": ["type": "AfterDuration", "duration": duration]],
        "expandedProperties": ["scope": ["displayName": scopeName, "type": "subscription"], "roleDefinition": ["displayName": role]],
    ]
    if let approvalId { props["approvalId"] = approvalId }
    if let ticket { props["ticketInfo"] = ["ticketNumber": ticket.0, "ticketSystem": ticket.1] }
    let doc: [String: Any] = ["id": "/subscriptions/bbbbbbbb-0000-0000-0000-00000000000b/providers/Microsoft.Authorization/roleAssignmentScheduleRequests/\(name)",
                              "name": name, "properties": props]
    return try! JSONDecoder().decode(AssignmentScheduleRequestItem.self, from: JSONSerialization.data(withJSONObject: doc))
}

/// Answers the approver listings from the fixtures; PATCH with 200.
@Sendable func approverARM(_ request: URLRequest) throws -> (Data, Int) {
    let url = request.url!.absoluteString
    if request.httpMethod == "PATCH" { return (Data(), 200) }
    if url.contains("roleAssignmentApprovals/") && url.contains("/stages") { return (try Fixture.data("approval-stages"), 200) }
    if url.contains("roleAssignmentApprovals?") { return (try Fixture.data("approvals"), 200) }
    if url.contains("asApprover()") { return (try Fixture.data("approver-requests"), 200) }
    return (Data(), 404)
}

@Suite("Approvals: parsing")
struct ApprovalParsingTests {
    func inbox() throws -> [ApprovalRequest] {
        let requests = try Fixture.decode("approver-requests", as: ARMList<AssignmentScheduleRequestItem>.self).value
        let approvals = try Fixture.decode("approvals", as: ARMList<RoleAssignmentApprovalItem>.self).value
        return ApprovalParser.inbox(requests: requests, approvals: approvals, me: Fixture.userOID)
    }

    @Test func onlyRequestsWaitingForYouOldestFirst() throws {
        let list = try inbox()
        // Provisioned, your own request and a SelfExtend (PendingAdminDecision) are left out.
        #expect(list.map(\.shortId) == ["b2b2b2b2", "a1a1a1a1"])
        let owner = list[0]
        #expect(owner.isOwner && owner.roleName == "Owner" && owner.scopeName == "Fabrikam Production")
        #expect(owner.requesterLabel == "Lee Gu <lee@fabrikam.example>")
        #expect(owner.requesterId == "33333333-0000-4000-8000-000000000002")
        #expect(owner.approvalId == "b2b2b2b2-0000-4000-8000-000000000012")
        #expect(owner.stage == nil)  // not in the approvals listing: read when deciding
        #expect(owner.expiresAt == AzureDate.parse("2026-10-30T09:00:00Z"))
    }

    @Test func requestDetailsAndTheStageToDecide() throws {
        let r = try #require(try inbox().last)
        #expect(r.roleName == "Contributor" && r.scopeName == "Contoso Staging" && r.scopeTypeLabel == "Subscription")
        #expect(r.requesterName == "Megan Bowen" && r.requesterEmail == "megan@contoso.example")
        #expect(r.justification == "release 2.4 hotfix")
        #expect(r.ticket == TicketInfo(number: "CHG-2002", system: "ServiceNow"))
        #expect(r.durationMinutes == 240)
        #expect(r.start == AzureDate.parse("2026-10-29T11:20:00Z"))
        #expect(r.createdOn == AzureDate.parse("2026-10-29T11:20:00.5Z"))
        // The approval id is the last segment of `approvalId`; the stage id
        // the last segment of the stage's `id` (its `name` differs).
        #expect(r.approvalId == "a1a1a1a1-0000-4000-8000-000000000011")
        let stage = try #require(r.stage)
        #expect(stage.id == "5a5a5a5a-0000-4000-8000-000000000021")
        #expect(stage.isOpen && stage.assignedToMe == true && !stage.isReviewed)
    }

    @Test func decidableStage() {
        let done = ApprovalStage(id: "1", status: "Completed", assignedToMe: true, reviewResult: "Approve")
        let other = ApprovalStage(id: "2", status: "InProgress", assignedToMe: false, reviewResult: "NotReviewed")
        let unknown = ApprovalStage(id: "3", status: "InProgress")
        let mine = ApprovalStage(id: "4", status: "Escalated", assignedToMe: true, reviewResult: "NotReviewed")
        #expect(ApprovalStage.decidable([done, other]) == nil)
        #expect(ApprovalStage.decidable([done, unknown]) == unknown)
        #expect(ApprovalStage.decidable([unknown, mine]) == mine)
        #expect(ApprovalStage.decidable([ApprovalStage(id: "5", status: "NotStarted", assignedToMe: true)]) == nil)
    }

    @Test func reviewInfoFromDecidedStages() throws {
        let items = try Fixture.decode("approval-stages-denied", as: ARMList<ApprovalStageItem>.self).value
        let stages = ApprovalStage.parse(items)
        #expect(stages.first?.reviewedAt == AzureDate.parse("2026-10-29T12:05:00Z"))
        #expect(ReviewInfo(stages: stages) == ReviewInfo(reviewer: "Nestor Wilke", justification: "Use the staging subscription"))
        #expect(ReviewInfo(stages: [ApprovalStage(id: "x", status: "InProgress", reviewResult: "NotReviewed")]) == nil)
    }

    @Test func arrivalsOnlyAfterTheFirstListing() throws {
        let list = try inbox()
        #expect(ApprovalParser.arrivals(previous: nil, current: list).isEmpty)
        let seen = ApprovalParser.names([list[0]])
        #expect(ApprovalParser.arrivals(previous: seen, current: list).map(\.shortId) == ["a1a1a1a1"])
        #expect(ApprovalParser.arrivals(previous: ApprovalParser.names(list), current: list).isEmpty)
    }

    @Test func armErrorsWithATopLevelMessage() {
        let data = Data(#"{"Message":"Currently, ?$filter=asApprover() needs to be passed to this endpoint"}"#.utf8)
        #expect(ARMErrorEnvelope.describe(data) == "Currently, ?$filter=asApprover() needs to be passed to this endpoint")
        let (code, message) = ActivationResponseMapper.error(statusCode: 400, data: data)
        #expect(code == "HTTP 400" && message.hasPrefix("Currently"))
        #expect(ARMErrorEnvelope.describe(Data(#"{"error":{"code":"AuthorizationFailed","message":"no"}}"#.utf8)) == "AuthorizationFailed: no")
        #expect(ARMErrorEnvelope.describe(Data("<html>".utf8)) == nil)
    }
}

@Suite("Approvals: decisions")
struct ApprovalDecisionTests {
    func request(stage: ApprovalStage? = ApprovalStage(id: "5a5a5a5a-0000-4000-8000-000000000021", status: "InProgress", assignedToMe: true)) -> ApprovalRequest {
        ApprovalRequest(id: "/x/a1a1a1a1-0000-4000-8000-000000000011", name: "a1a1a1a1-0000-4000-8000-000000000011",
                        approvalId: "a1a1a1a1-0000-4000-8000-000000000011", stage: stage, scope: "/subscriptions/s",
                        roleDefinitionId: "r/b24988ac-6180-42a0-ab88-20f7382dd24c", roleName: "Contributor", scopeName: "Contoso Staging",
                        scopeType: "subscription", requesterId: "22222222-0000-4000-8000-000000000001", requesterName: "Megan Bowen")
    }

    @Test func bodyAndURL() throws {
        let plans = try PlannedDecision.plan([request()], decision: .approve, justification: "  looks right ")
        let plan = try #require(plans.first)
        #expect(plan.url?.absoluteString == "https://management.azure.com/providers/Microsoft.Authorization/roleAssignmentApprovals/a1a1a1a1-0000-4000-8000-000000000011/stages/5a5a5a5a-0000-4000-8000-000000000021?api-version=2021-01-01-preview")
        let body = try #require(try JSONSerialization.jsonObject(with: plan.bodyJSON) as? [String: String])
        #expect(body == ["reviewResult": "Approve", "justification": "looks right"])
        let deny = try PlannedDecision.plan([request()], decision: .deny, justification: "no")
        #expect(deny[0].body.reviewResult == "Deny")
        #expect(throws: ApprovalDecisionError.missingJustification) { try PlannedDecision.plan([request()], decision: .deny, justification: "  ") }
        // No stage: nothing to send to.
        #expect(try PlannedDecision.plan([request(stage: nil)], decision: .approve, justification: "x")[0].url == nil)
    }

    @Test func idsThatAreNotIdsMakeNoURL() {
        #expect(ARM.approvalStageURL(approvalId: "../tenants", stageId: "x") == nil)
        #expect(ARM.approvalStageURL(approvalId: "a", stageId: "b?c") == nil)
        #expect(ARM.approvalStagesURL(approvalId: "") == nil)
    }

    @Test func outcomes() {
        #expect(DecisionOutcome.from(statusCode: 200, data: Data(), decision: .approve) == .decided(.approve))
        #expect(DecisionOutcome.from(statusCode: 204, data: Data(), decision: .deny) == .decided(.deny))
        #expect(DecisionOutcome.from(statusCode: 404, data: Data(#"{"Message":"RecordNotFound"}"#.utf8), decision: .approve)
            == .notPending(DecisionOutcome.noOpenStageMessage))
        let token = DecisionOutcome.from(statusCode: 401, data: Data(#"{"error":{"code":"ExpiredAuthenticationToken","message":"x"}}"#.utf8), decision: .approve)
        #expect(token.isAuthFailure && token.isFailure)
        guard case .failed(_, let message) = DecisionOutcome.from(statusCode: 403, data: Data(#"{"error":{"code":"AuthorizationFailed","message":"no"}}"#.utf8), decision: .deny)
        else { Issue.record("expected failure"); return }
        #expect(message.hasPrefix("You may not decide this request"))
        #expect(DecisionOutcome.decided(.deny).summary == "Denied")
        #expect(!DecisionOutcome.decided(.approve).isFailure)
    }

    @Test func serviceListsResolvesAndPatches() async throws {
        let transport = RecordingTransport(handler: approverARM)
        let service = PIMService(transport: transport, tokens: StaticTokenProvider())
        let (identity, inbox) = try await service.loadApprovalInbox()
        #expect(identity.objectId == Fixture.userOID)
        #expect(inbox.unavailable == nil && inbox.requests.count == 2)
        let resolved = await service.resolvingStages(inbox.requests)
        #expect(resolved[0].stage?.id == "6b6b6b6b-0000-4000-8000-000000000022")
        let plans = try PlannedDecision.plan(resolved, decision: .deny, justification: "not now")
        let box = DecisionBox()
        try await service.decide(plans) { p, o in box.set(p.request.name, o) }
        #expect(box.all.values.allSatisfy { $0 == .decided(.deny) })
        let patches = await transport.requests.filter { $0.httpMethod == "PATCH" }
        #expect(patches.count == 2)
        #expect(Set(patches.map { $0.url!.path }) == [
            "/providers/Microsoft.Authorization/roleAssignmentApprovals/b2b2b2b2-0000-4000-8000-000000000012/stages/6b6b6b6b-0000-4000-8000-000000000022",
            "/providers/Microsoft.Authorization/roleAssignmentApprovals/a1a1a1a1-0000-4000-8000-000000000011/stages/5a5a5a5a-0000-4000-8000-000000000021",
        ])
        #expect(patches.allSatisfy { $0.url!.host == "management.azure.com" && $0.value(forHTTPHeaderField: "Authorization")?.hasPrefix("Bearer ") == true })
        // Only GETs before the decisions; the approvals listing uses the preview api-version.
        let gets = await transport.requests.filter { $0.httpMethod == "GET" }.map { $0.url!.absoluteString }
        #expect(gets.contains { $0.contains("roleAssignmentApprovals?api-version=2021-01-01-preview&$filter=asApprover()") })
        #expect(gets.contains { $0.contains("roleAssignmentScheduleRequests?api-version=2020-10-01&$filter=asApprover()") })
    }

    @Test func aRequestWithoutAnOpenStageIsNotSent() async throws {
        let transport = RecordingTransport { _ in (Data(#"{"value":[]}"#.utf8), 200) }
        let service = PIMService(transport: transport, tokens: StaticTokenProvider())
        let plans = try PlannedDecision.plan(await service.resolvingStages([request(stage: nil)]), decision: .approve, justification: "x")
        let box = DecisionBox()
        try await service.decide(plans) { p, o in box.set(p.request.name, o) }
        #expect(box.all.values.first == .notPending(DecisionOutcome.noOpenStageMessage))
        #expect(await transport.requests.allSatisfy { $0.httpMethod == "GET" })
    }

    @Test func aStageLookupErrorIsAFailureNotNotPending() async throws {
        let transport = RecordingTransport { _ in
            (Data(#"{"error":{"code":"ExpiredAuthenticationToken","message":"expired"}}"#.utf8), 401)
        }
        let service = PIMService(transport: transport, tokens: StaticTokenProvider())
        let plans = try PlannedDecision.plan(await service.resolvingStages([request(stage: nil)]), decision: .approve, justification: "x")
        let box = DecisionBox()
        try await service.decide(plans) { p, o in box.set(p.request.name, o) }
        guard case .failed(let code, let message)? = box.all.values.first else {
            Issue.record("expected a failure, got \(String(describing: box.all.values.first))")
            return
        }
        #expect(code == "StageLookupFailed" && message.contains("401"))
        #expect(await transport.requests.allSatisfy { $0.httpMethod == "GET" })
    }

    @Test func noApproverPermissionsIsAnEmptyInbox() async throws {
        for (status, body) in [(403, #"{"error":{"code":"AuthorizationFailed","message":"no access"}}"#),
                               (400, #"{"Message":"Currently, ?$filter=asApprover() needs to be passed to this endpoint"}"#),
                               (404, "")] {
            let service = PIMService(transport: RecordingTransport { _ in (Data(body.utf8), status) }, tokens: StaticTokenProvider())
            let (_, inbox) = try await service.loadApprovalInbox()
            #expect(inbox.isEmpty)
            #expect(inbox.unavailable?.hasPrefix("HTTP \(status)") == true)
        }
        // Nothing waiting: the approvals endpoint is not even asked.
        let none = RecordingTransport { _ in (Data(#"{"value":[]}"#.utf8), 200) }
        let (_, empty) = try await PIMService(transport: none, tokens: StaticTokenProvider()).loadApprovalInbox()
        #expect(empty == ApprovalInbox())
        #expect(await none.requests.count == 1)
        // A rejected token is still an error (sign in again).
        let expired = PIMService(transport: RecordingTransport { _ in (Data(#"{"error":{"code":"ExpiredAuthenticationToken","message":"x"}}"#.utf8), 401) },
                                 tokens: StaticTokenProvider())
        await #expect(throws: PIMServiceError.self) { try await expired.loadApprovalInbox() }
    }

    @Test func stagesThatCannotBeListedStillLeaveTheRequests() async throws {
        let transport = RecordingTransport { request in
            let url = request.url!.absoluteString
            if url.contains("roleAssignmentApprovals") { return (Data(#"{"Message":"boom"}"#.utf8), 500) }
            return (try Fixture.data("approver-requests"), 200)
        }
        let (_, inbox) = try await PIMService(transport: transport, tokens: StaticTokenProvider()).loadApprovalInbox()
        #expect(inbox.requests.count == 2 && inbox.requests.allSatisfy { $0.stage == nil })
    }
}

final class DecisionBox: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: DecisionOutcome] = [:]
    func set(_ id: String, _ o: DecisionOutcome) { lock.withLock { values[id] = o } }
    var all: [String: DecisionOutcome] { lock.withLock { values } }
}

@Suite("Approvals: following your requests")
struct ApprovalTrackerTests {
    let name = "7a1b2c3d-0000-4000-8000-000000000002"

    @Test func resolutionsByStatus() {
        let until = Fixture.now
        #expect(RequestResolution(status: "Provisioned", until: until) == .approved(until: until))
        #expect(RequestResolution(status: "Granted") == .approved(until: nil))
        #expect(RequestResolution(status: "Denied") == .denied)
        #expect(RequestResolution(status: "AdminDenied") == .denied)
        #expect(RequestResolution(status: "TimedOut") == .expired)
        #expect(RequestResolution(status: "Canceled") == .canceled)
        #expect(RequestResolution(status: "Failed") == .failed(status: "Failed"))
        for waiting in ["PendingApproval", "PendingApprovalProvisioning", "PendingEvaluation", "Something"] {
            #expect(RequestResolution(status: waiting) == nil)
        }
    }

    @Test func pendingThenApproved() {
        var tracker = ApprovalTracker()
        // First listing: the request waits; nothing to report, now followed.
        #expect(tracker.update(items: [requestItem(name, status: "PendingApproval")], principalId: Fixture.userOID, now: Fixture.now).isEmpty)
        #expect(tracker.count == 1)
        #expect(ApprovalPolling.shouldPoll(pendingCount: tracker.count, autoRefreshMinutes: 0))
        // Still waiting.
        #expect(tracker.update(items: [requestItem(name, status: "PendingApproval")], principalId: Fixture.userOID, now: Fixture.now).isEmpty)
        // Approved.
        let t = tracker.update(items: [requestItem(name, status: "Provisioned")], principalId: Fixture.userOID, now: Fixture.now)
        #expect(t.count == 1)
        #expect(t[0].resolution == .approved(until: AzureDate.parse("2026-10-29T15:50:00Z")))
        #expect(t[0].status == "Provisioned" && t[0].request.roleName == "Contributor")
        #expect(tracker.isEmpty)
        #expect(!ApprovalPolling.shouldPoll(pendingCount: tracker.count, autoRefreshMinutes: 0))
        // Reported once.
        #expect(tracker.update(items: [requestItem(name, status: "Provisioned")], principalId: Fixture.userOID, now: Fixture.now).isEmpty)
    }

    @Test func pendingThenDeniedExpiredOrCancelled() {
        for (status, resolution) in [("Denied", RequestResolution.denied), ("TimedOut", .expired), ("Canceled", .canceled)] {
            var tracker = ApprovalTracker()
            _ = tracker.update(items: [requestItem(name, status: "PendingApproval")], principalId: Fixture.userOID, now: Fixture.now)
            let t = tracker.update(items: [requestItem(name, status: status)], principalId: Fixture.userOID, now: Fixture.now)
            #expect(t.map(\.resolution) == [resolution])
            #expect(tracker.isEmpty)
        }
    }

    @Test func decisionsMadeBeforeTrackingAreNotReported() {
        var tracker = ApprovalTracker()
        #expect(tracker.update(items: [requestItem(name, status: "Denied")], principalId: Fixture.userOID, now: Fixture.now).isEmpty)
        #expect(tracker.isEmpty)
    }

    @Test func otherPeoplesRequestsAndVanishedOnes() {
        var tracker = ApprovalTracker()
        _ = tracker.update(items: [requestItem(name, status: "PendingApproval", principal: "someone-else")], principalId: Fixture.userOID, now: Fixture.now)
        #expect(tracker.isEmpty)
        _ = tracker.update(items: [requestItem(name, status: "PendingApproval")], principalId: Fixture.userOID, now: Fixture.now)
        // Missing from a listing: kept for a while, then dropped without a report.
        for _ in 1..<ApprovalTracker.maxMisses {
            #expect(tracker.update(items: [], principalId: Fixture.userOID, now: Fixture.now).isEmpty)
            #expect(tracker.count == 1)
        }
        #expect(tracker.update(items: [], principalId: Fixture.userOID, now: Fixture.now).isEmpty)
        #expect(tracker.isEmpty)
    }

    @Test func waitTracksOnlyWhatItWasGiven() {
        var tracker = ApprovalTracker()
        let other = "8b8b8b8b-0000-4000-8000-000000000009"
        let pending = ScheduledRequestParser.pending([requestItem(name, status: "PendingApproval")], principalId: Fixture.userOID, now: Fixture.now)
        tracker.track(pending)
        let items = [requestItem(name, status: "PendingApproval"), requestItem(other, status: "PendingApproval")]
        #expect(tracker.update(items: items, principalId: Fixture.userOID, now: Fixture.now, trackNew: false).isEmpty)
        #expect(tracker.count == 1)
        #expect(ApprovalTracker.resolution(of: requestItem(other, status: "Provisioned", start: "2026-10-29T12:00:00Z", duration: "PT1H"))
            == .approved(until: AzureDate.parse("2026-10-29T13:00:00Z")))
        #expect(ApprovalTracker.resolution(of: requestItem(other, status: "PendingApproval")) == nil)
    }

    @Test func pollingRespectsAMinuteAutoRefresh() {
        #expect(!ApprovalPolling.shouldPoll(pendingCount: 2, autoRefreshMinutes: 1))
        #expect(ApprovalPolling.shouldPoll(pendingCount: 2, autoRefreshMinutes: 5))
        #expect(!ApprovalPolling.shouldPoll(pendingCount: 0, autoRefreshMinutes: 5))
        #expect(ApprovalPolling.interval == 60)
    }

    @Test func expiryOfAWaitingRequest() throws {
        let pending = ScheduledRequestParser.pending(try Fixture.decode("schedule-requests", as: ARMList<AssignmentScheduleRequestItem>.self).value,
                                                     principalId: Fixture.userOID, now: Fixture.now)
        let waiting = try #require(pending.first { $0.kind == .awaitingApproval })
        #expect(waiting.expiresAt == AzureDate.parse("2026-10-30T11:50:00.4Z"))
        #expect(waiting.approvalId == "/providers/Microsoft.Authorization/roleAssignmentApprovals/7a1b2c3d-0000-4000-8000-000000000002")
        #expect(pending.first { $0.kind == .scheduled }?.expiresAt == nil)
    }
}

@Suite("Approvals: notifications")
struct ApprovalNoticeTests {
    let utc = TimeZone(identifier: "UTC")!

    func transition(_ resolution: RequestResolution, start: String = "2026-10-29T11:50:00Z") -> ApprovalTransition {
        let r = ScheduledRequestParser.pending([requestItem("7a1b2c3d-0000-4000-8000-000000000002", status: "PendingApproval", start: start)],
                                               principalId: Fixture.userOID, now: Fixture.now)[0]
        return ApprovalTransition(request: r, resolution: resolution, status: "x")
    }

    @Test func approved() {
        let n = ApprovalNotice.decision(transition(.approved(until: AzureDate.parse("2026-10-29T15:50:00Z"))), now: Fixture.now, timeZone: utc)
        #expect(n.title == "Approved and active: Contributor")
        #expect(n.body == "Contoso Staging. Active until \(shortTime("2026-10-29T15:50:00Z", utc)).")
        #expect(n.id == "approval-7a1b2c3d-0000-4000-8000-000000000002")
        // The listed end wins over the request's estimate.
        let listed = ApprovalNotice.decision(transition(.approved(until: nil)), until: AzureDate.parse("2026-10-29T16:00:00Z"), now: Fixture.now, timeZone: utc)
        #expect(listed.body == "Contoso Staging. Active until \(shortTime("2026-10-29T16:00:00Z", utc)).")
        // Approved for a later start.
        let later = ApprovalNotice.decision(transition(.approved(until: AzureDate.parse("2026-10-30T12:00:00Z")), start: "2026-10-30T08:00:00Z"),
                                            now: Fixture.now, timeZone: utc)
        #expect(later.title == "Approved: Contributor")
        #expect(later.body == "Contoso Staging. Starts Fri 08:00, until \(shortTime("2026-10-30T12:00:00Z", utc)).")
    }

    @Test func deniedWithTheApproversWords() {
        let review = ReviewInfo(reviewer: "Nestor Wilke", justification: "Use the staging subscription")
        let n = ApprovalNotice.decision(transition(.denied), review: review, now: Fixture.now, timeZone: utc)
        #expect(n.title == "Denied: Contributor")
        #expect(n.body == "Contoso Staging.\n“Use the staging subscription” (Nestor Wilke)")
        let anonymous = ApprovalNotice.decision(transition(.denied), review: ReviewInfo(reviewer: "Nestor Wilke"), now: Fixture.now, timeZone: utc)
        #expect(anonymous.body == "Contoso Staging.\nBy Nestor Wilke.")
        #expect(ApprovalNotice.decision(transition(.denied), now: Fixture.now, timeZone: utc).body == "Contoso Staging.")
    }

    @Test func expiredCancelledFailed() {
        #expect(ApprovalNotice.decision(transition(.expired), now: Fixture.now, timeZone: utc).body
            == "Contoso Staging. No approver decided within 24 hours; request it again.")
        #expect(ApprovalNotice.decision(transition(.canceled), now: Fixture.now, timeZone: utc).title == "Request cancelled: Contributor")
        #expect(ApprovalNotice.decision(transition(.failed(status: "Failed")), now: Fixture.now, timeZone: utc).body == "Contoso Staging. Status: Failed.")
    }

    @Test func newRequestsToDecide() throws {
        let requests = try ApprovalParsingTests().inbox()
        #expect(ApprovalNotice.arrivals([]) == nil)
        let one = try #require(ApprovalNotice.arrivals([requests[1]]))
        #expect(one.title == "Approval requested")
        #expect(one.body == "Megan Bowen: Contributor · Contoso Staging")
        let two = try #require(ApprovalNotice.arrivals(requests))
        #expect(two.title == "2 approvals requested")
        #expect(two.body == "Lee Gu: Owner · Fabrikam Production\nMegan Bowen: Contributor · Contoso Staging")
    }

    @Test func completionNotificationOfAwaitingRoles() throws {
        let role = try Fixture.role("Contoso Staging", "Contributor")
        let summary = try #require(ActivationSummary(roles: [role], outcomes: [role.id: .activated(status: "PendingApproval", until: Fixture.now)],
                                                     now: Fixture.now, timeZone: utc))
        #expect(summary.title == "1 role awaiting approval")
        #expect(summary.body.contains("Awaiting approval (an approver has 24 hours to decide)\nContributor · Contoso Staging"))
        #expect(summary.reminders.isEmpty)  // not active: no expiry reminder
        #expect(!summary.isFailure)
    }
}

@Suite("Requests: history and tickets")
struct RequestHistoryTests {
    @Test func ticketOfTheRequestBehindAnActiveRole() throws {
        let identity = Identity(objectId: Fixture.userOID, name: nil, upn: nil, tenantId: nil)
        let history = RequestHistory(identity: identity, items: [
            requestItem("a4000000-0000-4000-8000-000000000001", status: "Provisioned", ticket: ("CHG-9", "ServiceNow")),
            requestItem("a5000000-0000-4000-8000-000000000002", status: "Provisioned"),
            requestItem("a6000000-0000-4000-8000-000000000003", status: "Provisioned", principal: "someone-else", ticket: ("X-1", "Jira")),
        ], now: Fixture.now)
        #expect(history.items.count == 2)
        var role = try Fixture.role("Contoso Staging", "Contributor")
        role.isActive = true
        role.activeScheduleId = "/subscriptions/bbbbbbbb-0000-0000-0000-00000000000b/providers/Microsoft.Authorization/roleAssignmentSchedules/A4000000-0000-4000-8000-000000000001"
        #expect(RequestHistory.ticket(for: role, in: history.activationTickets) == TicketInfo(number: "CHG-9", system: "ServiceNow"))
        role.activeScheduleId = "/x/roleAssignmentSchedules/a5000000-0000-4000-8000-000000000002"
        #expect(RequestHistory.ticket(for: role, in: history.activationTickets) == nil)
        role.isActive = false
        #expect(RequestHistory.ticket(for: role, in: history.activationTickets) == nil)
        #expect(history.items(matching: "A4000").count == 1)
    }
}
