import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import PimentoCore

private func properties(_ body: ActivationRequestBody) throws -> [String: Any] {
    let object = try JSONSerialization.jsonObject(with: ActivationRequestBuilder.encode(body)) as? [String: Any]
    return try #require(object?["properties"] as? [String: Any])
}

private func requestProperties(_ request: URLRequest) throws -> [String: Any] {
    let object = try JSONSerialization.jsonObject(with: try #require(request.httpBody)) as? [String: Any]
    return try #require(object?["properties"] as? [String: Any])
}

private func armError(_ code: String, _ message: String = "message") -> Data {
    Data(#"{"error":{"code":"\#(code)","message":"\#(message)"}}"#.utf8)
}

private func requestStatus(_ status: String, requestType: String) -> Data {
    Data(#"{"properties":{"status":"\#(status)","requestType":"\#(requestType)"}}"#.utf8)
}

/// A time-bound, admin-assigned assignment (Fabrikam, synthetic).
private func timeBound(end: String = "2026-11-05T12:00:00Z", condition: String? = nil) -> ActiveAssignment {
    ActiveAssignment(
        id: "/subscriptions/dddddddd-0000-0000-0000-00000000000d/providers/Microsoft.Authorization/roleAssignmentScheduleInstances/tb1",
        scheduleId: "/subscriptions/dddddddd-0000-0000-0000-00000000000d/providers/Microsoft.Authorization/roleAssignmentSchedules/tb1",
        roleDefinitionId: "/subscriptions/dddddddd-0000-0000-0000-00000000000d/providers/Microsoft.Authorization/roleDefinitions/acdd72a7-3385-48ef-bd42-f606fba81ae7",
        roleName: "Reader", scope: "/subscriptions/dddddddd-0000-0000-0000-00000000000d", scopeName: "Fabrikam Sandbox",
        scopeType: "subscription", start: AzureDate.parse("2026-10-01T08:00:00Z"), end: AzureDate.parse(end)!,
        condition: condition, conditionVersion: condition == nil ? nil : "2.0")
}

@Suite("Deactivate, renew and extend: request bodies")
struct LifecycleRequestTests {
    @Test func deactivationBodyHasNoScheduleAndCopiesTheCondition() throws {
        let owner = try Fixture.role("Contoso Production", "Owner")
        #expect(owner.isActive)
        let p = try properties(ActivationRequestBuilder.deactivationBody(for: owner, principalId: Fixture.userOID))
        #expect(p["requestType"] as? String == "SelfDeactivate")
        #expect(p["principalId"] as? String == Fixture.userOID)
        #expect(p["roleDefinitionId"] as? String == owner.roleDefinitionId)
        #expect(p["linkedRoleEligibilityScheduleId"] as? String == owner.eligibilityScheduleId)
        #expect(p["justification"] as? String == ActivationRequestBuilder.defaultDeactivationJustification)
        #expect(p["condition"] as? String == owner.condition)
        #expect(p["conditionVersion"] as? String == "2.0")
        #expect(p["scheduleInfo"] == nil)
        #expect(p["targetRoleAssignmentScheduleId"] == nil)
    }

    @Test func deactivationWithoutConditionSendsOnlyTheCoreFields() throws {
        let owner = try Fixture.role("rg-app-dev", "Owner")
        let p = try properties(ActivationRequestBuilder.deactivationBody(for: owner, principalId: "me", justification: "  done  "))
        #expect(Set(p.keys) == ["principalId", "roleDefinitionId", "requestType", "linkedRoleEligibilityScheduleId", "justification"])
        #expect(p["justification"] as? String == "done")
    }

    @Test func deactivationNeedsAnActiveRoleAndAPrincipal() throws {
        let reader = try Fixture.role("Contoso Production", "Reader")
        #expect(throws: ActivationRequestError.notActive) {
            try ActivationRequestBuilder.deactivationBody(for: reader, principalId: "me")
        }
        let owner = try Fixture.role("rg-app-dev", "Owner")
        #expect(throws: ActivationRequestError.missingPrincipal) {
            try ActivationRequestBuilder.deactivationBody(for: owner, principalId: "")
        }
    }

    @Test func deactivationPlanSendsOneRequestPerActivation() throws {
        let owner = try Fixture.role("rg-app-dev", "Owner")
        let viaGroup = EligibleRole(
            id: "group-row", eligibilityScheduleId: "other", roleDefinitionId: owner.roleDefinitionId, roleName: owner.roleName,
            scope: owner.scope + "/", scopeName: owner.scopeName, scopeType: owner.scopeType, membership: .group("Ops"),
            isActive: true, activeUntil: owner.activeUntil)
        let plans = try ActivationRequestBuilder.deactivationPlan([owner, viaGroup], principalId: "me", now: Fixture.now)
        #expect(plans.count == 1)
        #expect(plans[0].action == .deactivate)
        #expect(plans[0].url.absoluteString.contains("/resourceGroups/rg-app-dev/providers/Microsoft.Authorization/roleAssignmentScheduleRequests/"))
    }

    @Test func extensionBodyTargetsTheScheduleAndAsksForALaterEnd() throws {
        let a = timeBound(condition: "@Resource[x] StringEquals 'y'")
        let p = try properties(ActivationRequestBuilder.extensionBody(for: a, principalId: "me", justification: "project runs longer", days: 30))
        #expect(p["requestType"] as? String == "SelfExtend")
        #expect(p["targetRoleAssignmentScheduleId"] as? String == a.scheduleId)
        #expect(p["linkedRoleEligibilityScheduleId"] == nil)
        #expect(p["condition"] as? String == "@Resource[x] StringEquals 'y'")
        #expect(p["conditionVersion"] as? String == "2.0")
        let schedule = try #require(p["scheduleInfo"] as? [String: Any])
        #expect(schedule["startDateTime"] as? String == "2026-10-01T08:00:00.000Z")
        let expiration = try #require(schedule["expiration"] as? [String: Any])
        #expect(expiration["type"] as? String == "AfterDateTime")
        #expect(expiration["endDateTime"] as? String == "2026-12-05T12:00:00.000Z")
        #expect(expiration["duration"] == nil)
    }

    @Test func extensionValidatesItsInput() {
        let a = timeBound()
        #expect(throws: ActivationRequestError.missingJustification) {
            try ActivationRequestBuilder.extensionBody(for: a, principalId: "me", justification: " ", days: 30)
        }
        #expect(throws: ActivationRequestError.invalidDays(0)) {
            try ActivationRequestBuilder.extensionBody(for: a, principalId: "me", justification: "x", days: 0)
        }
    }

    @Test func renewPlanEndsThenActivatesForTheCappedDuration() throws {
        let owner = try Fixture.role("Contoso Production", "Owner")
        let plans = try ActivationRequestBuilder.renewPlan([owner], principalId: "me", justification: "still on it", now: Fixture.now) { _ in
            EffectiveDuration.resolve(.hours(8), policyMaxMinutes: 120, fallbackHours: 8)
        }
        let plan = try #require(plans.first)
        #expect(plan.deactivation.body.properties.requestType == "SelfDeactivate")
        #expect(plan.deactivation.body.properties.justification == "still on it")
        let on = try properties(plan.plannedActivation.body)
        #expect(on["requestType"] as? String == "SelfActivate")
        #expect(on["linkedRoleEligibilityScheduleId"] as? String == owner.eligibilityScheduleId)
        #expect(on["condition"] as? String == owner.condition)
        #expect(plan.plannedActivation.body.duration == "PT2H")
        #expect(plan.plannedActivation.url != plan.deactivation.url)
        // Each attempt gets its own request id and start time.
        let later = Fixture.now.addingTimeInterval(30)
        let again = try plan.activation(now: later)
        #expect(again.url != plan.plannedActivation.url)
        #expect(again.body.properties.scheduleInfo?.startDateTime == "2026-10-29T12:00:30.000Z")
        #expect(throws: ActivationRequestError.missingJustification) {
            try ActivationRequestBuilder.renewPlan([owner], principalId: "me", justification: "", duration: { _ in plan.duration })
        }
    }
}

@Suite("Deactivate, renew and extend: responses and rules")
struct LifecycleOutcomeTests {
    let since = AzureDate.parse("2026-10-29T11:58:00Z")!

    @Test func deactivationResponses() {
        let ok = ActivationResponseMapper.outcome(
            for: .deactivate, statusCode: 201, data: requestStatus("Revoked", requestType: "SelfDeactivate"), requestedAt: Fixture.now, minutes: 0)
        #expect(ok == .deactivated(status: "Revoked"))
        #expect(ok.summary == "Deactivated")
        #expect(!ok.isFailure)

        let early = ActivationResponseMapper.outcome(
            for: .deactivate, statusCode: 400, data: armError("ActiveDurationTooShort"), requestedAt: Fixture.now, minutes: 0, activeSince: since)
        #expect(early == .tooSoon(possibleAt: since.addingTimeInterval(300)))
        #expect(early.isFailure)
        #expect(early.leavesRoleActive)

        let gone = ActivationResponseMapper.outcome(
            for: .deactivate, statusCode: 400, data: armError("RoleAssignmentDoesNotExist"), requestedAt: Fixture.now, minutes: 0)
        #expect(gone == .notActive)
        #expect(!gone.isFailure)
        // What PIM really answers in the first five minutes (seen live).
        let fresh = ActivationResponseMapper.outcome(
            for: .deactivate, statusCode: 400, data: armError("RoleAssignmentDoesNotExist"), requestedAt: Fixture.now, minutes: 0,
            activeSince: Fixture.now.addingTimeInterval(-90))
        #expect(fresh == .tooSoon(possibleAt: Fixture.now.addingTimeInterval(210)))
        let old = ActivationResponseMapper.outcome(
            for: .deactivate, statusCode: 400, data: armError("RoleAssignmentDoesNotExist"), requestedAt: Fixture.now, minutes: 0,
            activeSince: Fixture.now.addingTimeInterval(-600))
        #expect(old == .notActive)

        let pending = ActivationResponseMapper.outcome(
            for: .deactivate, statusCode: 400, data: armError("RoleAssignmentRequestExistsWithSameAssignmentId"), requestedAt: Fixture.now, minutes: 0)
        guard case .failed(let code, let message) = pending else { Issue.record("expected failure"); return }
        #expect(code == "RoleAssignmentRequestExistsWithSameAssignmentId")
        #expect(message.contains("already pending"))

        let token = ActivationResponseMapper.outcome(
            for: .deactivate, statusCode: 401, data: armError("ExpiredAuthenticationToken"), requestedAt: Fixture.now, minutes: 0)
        #expect(token.isAuthFailure)
    }

    @Test func extensionIsOnlyARequest() {
        // What PIM answers to SelfExtend: a request waiting for an administrator.
        let outcome = ActivationResponseMapper.outcome(
            for: .extend, statusCode: 201, data: requestStatus("PendingAdminDecision", requestType: "SelfExtend"), requestedAt: Fixture.now, minutes: 0)
        #expect(outcome == .activated(status: "PendingAdminDecision", until: nil))
        #expect(outcome.summary == "Submitted (PendingAdminDecision)")
        #expect(!outcome.isFailure)
    }

    @Test func activationMappingIsUnchanged() throws {
        let outcome = ActivationResponseMapper.outcome(
            for: .activate, statusCode: 400, data: try Fixture.data("error-exists"), requestedAt: Fixture.now, minutes: 60)
        #expect(outcome == .alreadyActive)
    }

    @Test func selectionSplitsWhatCanBeEndedNow() throws {
        let owner = try Fixture.role("Contoso Production", "Owner")
        let reader = try Fixture.role("Contoso Production", "Reader")
        var fresh = try Fixture.role("rg-app-dev", "Owner")
        fresh.activeSince = Fixture.now.addingTimeInterval(-120)
        let selection = RoleLifecycle.select([owner, reader, fresh], now: Fixture.now)
        #expect(selection.ready.map(\.id) == [owner.id])
        #expect(selection.inactive.map(\.id) == [reader.id])
        #expect(selection.tooSoon.map(\.id) == [fresh.id])
        #expect(RoleLifecycle.earliestDeactivation(of: fresh) == Fixture.now.addingTimeInterval(180))

        let renewal = RoleLifecycle.select([owner, fresh], now: Fixture.now, forRenewal: true, requiresApproval: { $0.id == owner.id })
        #expect(renewal.needsApproval.map(\.id) == [owner.id])
        #expect(renewal.ready.isEmpty)

        // An unreadable policy is not "no approval needed": the role is left alone.
        let unknown = RoleLifecycle.select([owner], now: Fixture.now, forRenewal: true, requiresApproval: { _ in false },
                                           policyKnown: { _ in false })
        #expect(unknown.policyUnknown.map(\.id) == [owner.id] && unknown.ready.isEmpty && !unknown.isEmpty)
        // Deactivation does not depend on the policy.
        #expect(RoleLifecycle.select([owner], now: Fixture.now, policyKnown: { _ in false }).ready.map(\.id) == [owner.id])
    }

    @Test func selectionPrefersTheDirectRowOfAnActivation() throws {
        let owner = try Fixture.role("rg-app-dev", "Owner")
        let viaGroup = EligibleRole(
            id: "group-row", eligibilityScheduleId: "other", roleDefinitionId: owner.roleDefinitionId, roleName: owner.roleName,
            scope: owner.scope, scopeName: owner.scopeName, scopeType: owner.scopeType, membership: .group("Ops"),
            isActive: true, activeUntil: owner.activeUntil)
        #expect(RoleLifecycle.select([viaGroup, owner], now: Fixture.now).ready.map(\.id) == [owner.id])
    }

    @Test func rowsKnowWhenAndHowTheyWereActivated() throws {
        let owner = try Fixture.role("Contoso Production", "Owner")
        #expect(owner.activeSince == AzureDate.parse("2026-10-29T09:42:19.66Z"))
        #expect(owner.activeScheduleId?.hasSuffix("/roleAssignmentSchedules/a1") == true)
        // Of two activations of one role, the one that ends last.
        let dev = try Fixture.role("rg-app-dev", "Owner")
        #expect(dev.activeUntil == AzureDate.parse("2026-10-29T20:00:00.5Z"))
        #expect(try Fixture.role("Contoso Production", "Reader").activeSince == nil)
    }

    @Test func timeBoundAssignmentsAreTheAssignedOnesWithAnEnd() throws {
        // The fixtures hold one (Fabrikam Sandbox, Reader); these do not count.
        var list = try Fixture.assignments()
        let json = #"""
        {"value":[
          {"id":"x2","properties":{"roleAssignmentScheduleId":"s2","assignmentType":"Assigned","memberType":"Group","scope":"/subscriptions/e",
           "roleDefinitionId":"/x/roleDefinitions/r","endDateTime":"2026-11-05T12:00:00Z"}},
          {"id":"x3","properties":{"roleAssignmentScheduleId":"s3","assignmentType":"Assigned","memberType":"Direct","scope":"/subscriptions/e",
           "roleDefinitionId":"/x/roleDefinitions/r","endDateTime":"2026-10-29T11:00:00Z"}}
        ]}
        """#
        list += try JSONDecoder().decode(ARMList<AssignmentScheduleInstance>.self, from: Data(json.utf8)).value
        let found = RoleMatcher.timeBoundAssignments(list, now: Fixture.now)
        #expect(found.count == 1)
        #expect(found[0].scopeName == "Fabrikam Sandbox")
        #expect(found[0].roleName == "Reader")
        #expect(found[0].asRole.isActive)
        #expect(RoleCriteria(filters: ["fabrikam"], state: .active).matches(found[0]))
        #expect(!RoleCriteria(roles: ["owner"]).matches(found[0]))
    }
}

/// A transport that answers each PUT by its request type, in order (a
/// negative status: the answer is lost, `URLError(.timedOut)`). GETs are
/// answered from the script's `"GET"` entry and recorded as `GET`.
actor ScriptedPUTs: HTTPTransport {
    private var script: [String: [(Data, Int)]]
    private(set) var sent: [String] = []
    /// The request ids (last path component) of the PUTs, in order.
    private(set) var requestIds: [String] = []

    init(_ script: [String: [(Data, Int)]]) { self.script = script }

    /// Answers GETs from the PUT request ids sent so far (overrides `"GET"`).
    private var getHandler: (@Sendable ([String]) -> Data)?

    func answerGET(_ handler: @escaping @Sendable ([String]) -> Data) { getHandler = handler }

    private func answerGET() -> (Data, Int)? {
        guard let getHandler else { return nil }
        sent.append("GET")
        return (getHandler(requestIds), 200)
    }

    private func note(_ request: URLRequest) {
        if request.httpMethod == "PUT", let id = request.url?.lastPathComponent { requestIds.append(id) }
    }

    private func next(_ type: String) -> (Data, Int) {
        sent.append(type)
        var queue = script[type] ?? []
        guard !queue.isEmpty else { return (Data(), 500) }
        let answer = queue.count > 1 ? queue.removeFirst() : queue[0]
        script[type] = queue
        return answer
    }

    nonisolated func send(_ request: URLRequest) async throws -> (Data, Int) {
        await note(request)
        let type: String
        if request.httpMethod == "GET" {
            if let answer = await answerGET() { return answer }
            type = "GET"
        } else {
            let body = try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any]
            type = (body?["properties"] as? [String: Any])?["requestType"] as? String ?? "?"
        }
        let (data, status) = await next(type)
        if status < 0 { throw URLError(.timedOut) }
        return (data, status)
    }
}

final class Sleeps: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [TimeInterval] = []
    func add(_ t: TimeInterval) { lock.withLock { values.append(t) } }
    var all: [TimeInterval] { lock.withLock { values } }
}

@Suite("Renew against a fake ARM")
struct RenewServiceTests {
    func plan(_ role: EligibleRole) throws -> RenewPlan {
        try #require(try ActivationRequestBuilder.renewPlan([role], principalId: Fixture.userOID, justification: "on-call", now: Fixture.now) { _ in
            EffectiveDuration(minutes: 60, requested: .hours(1), policyMaxMinutes: nil)
        }.first)
    }

    func run(_ transport: ScriptedPUTs, _ plan: RenewPlan, sleeps: Sleeps = Sleeps()) async throws -> ActivationOutcome {
        let service = PIMService(transport: transport, tokens: StaticTokenProvider(), sleep: { sleeps.add($0) }, clock: { Fixture.now })
        let box = OutcomeBox()
        try await service.renew([plan]) { p, outcome in box.set(p.id, outcome) }
        return try #require(box.all[plan.id])
    }

    @Test func endsThenActivatesAgainRetryingWhilePIMCatchesUp() async throws {
        let owner = try Fixture.role("rg-app-dev", "Owner")
        let transport = ScriptedPUTs([
            "SelfDeactivate": [(requestStatus("Revoked", requestType: "SelfDeactivate"), 201)],
            "SelfActivate": [(armError("RoleAssignmentExists"), 400), (try Fixture.data("success-response"), 201)],
        ])
        let sleeps = Sleeps()
        let outcome = try await run(transport, try plan(owner), sleeps: sleeps)
        guard case .renewed(let until) = outcome else { Issue.record("expected renewed, got \(outcome)"); return }
        #expect(until == AzureDate.parse("2026-10-29T13:00:00.123Z"))
        #expect(await transport.sent == ["SelfDeactivate", "SelfActivate", "SelfActivate"])
        #expect(sleeps.all == [PIMService.reactivationDelays[1]])
    }

    @Test func aRoleThatCannotBeEndedIsLeftAlone() async throws {
        var fresh = try Fixture.role("rg-app-dev", "Owner")
        fresh.activeSince = Fixture.now.addingTimeInterval(-60)
        let transport = ScriptedPUTs(["SelfDeactivate": [(armError("ActiveDurationTooShort"), 400)]])
        let outcome = try await run(transport, try plan(fresh))
        #expect(outcome == .tooSoon(possibleAt: Fixture.now.addingTimeInterval(240)))
        #expect(await transport.sent == ["SelfDeactivate"])
    }

    @Test func aFailedReactivationSaysTheRoleIsOff() async throws {
        let owner = try Fixture.role("rg-app-dev", "Owner")
        let transport = ScriptedPUTs([
            "SelfDeactivate": [(requestStatus("Revoked", requestType: "SelfDeactivate"), 201)],
            "SelfActivate": [(armError("RoleAssignmentRequestPolicyValidationFailed", #"The following policy rules failed: [\"MfaRule\"]"#), 400)],
        ])
        let outcome = try await run(transport, try plan(owner))
        guard case .failed(let code, let message) = outcome else { Issue.record("expected failure"); return }
        #expect(code == "ReactivationFailed")
        #expect(message.contains("Deactivated"))
        #expect(message.contains("MFA"))
        #expect(await transport.sent == ["SelfDeactivate", "SelfActivate"])
    }

    @Test func givesUpAfterAboutFiveMinutes() async throws {
        let owner = try Fixture.role("rg-app-dev", "Owner")
        let transport = ScriptedPUTs([
            "SelfDeactivate": [(Data(), 201)],
            "SelfActivate": [(armError("RoleAssignmentExists"), 400)],
        ])
        let sleeps = Sleeps()
        let outcome = try await run(transport, try plan(owner), sleeps: sleeps)
        guard case .failed(let code, _) = outcome else { Issue.record("expected failure"); return }
        #expect(code == "ReactivationFailed")
        #expect(await transport.sent.filter { $0 == "SelfActivate" }.count == PIMService.reactivationDelays.count)
        #expect(sleeps.all.reduce(0, +) == PIMService.reactivationDelays.reduce(0, +))
        // PIM took about three minutes to accept the new activation in tests.
        #expect((240...330).contains(PIMService.reactivationDelays.reduce(0, +)))
    }

    /// An `Activated` instance of rg-app-dev / Owner (the fixture role).
    func activeInstance(schedule: String, start: String = "2026-10-29T12:00:00Z", end: String = "2026-10-29T13:00:00Z") -> Data {
        let scope = "/subscriptions/cccccccc-0000-0000-0000-00000000000c/resourceGroups/rg-app-dev"
        return Data(#"""
        {"value":[{"id":"\#(scope)/providers/Microsoft.Authorization/roleAssignmentScheduleInstances/i1","properties":{
          "roleAssignmentScheduleId":"\#(scope)/providers/Microsoft.Authorization/roleAssignmentSchedules/\#(schedule)",
          "assignmentType":"Activated","memberType":"Direct","scope":"\#(scope)",
          "roleDefinitionId":"/subscriptions/cccccccc-0000-0000-0000-00000000000c/providers/Microsoft.Authorization/roleDefinitions/8e3af657-a8ff-443c-a75c-2fe8c4bcb635",
          "startDateTime":"\#(start)","endDateTime":"\#(end)"}}]}
        """#.utf8)
    }

    @Test func aLostAnswerFollowedByExistsIsCheckedAndReportedAsRenewed() async throws {
        let owner = try Fixture.role("rg-app-dev", "Owner")
        // The first activation reached PIM but its answer was lost; the next
        // ones are refused because that activation exists. The GET lists the
        // schedule PIM created for the first one (named after its request).
        let transport = ScriptedPUTs([
            "SelfDeactivate": [(requestStatus("Revoked", requestType: "SelfDeactivate"), 201)],
            "SelfActivate": [(Data(), -1), (armError("RoleAssignmentExists"), 400)],
        ])
        await transport.answerGET { ids in
            ids.count > 1 ? self.activeInstance(schedule: ids[1], start: "2026-10-29T11:00:00Z") : Data(#"{"value":[]}"#.utf8)
        }
        let outcome = try await run(transport, try plan(owner))
        #expect(outcome == .renewed(until: AzureDate.parse("2026-10-29T13:00:00Z")))
        let sent = await transport.sent
        #expect(sent.first == "SelfDeactivate")
        #expect(sent.last == "GET")
        #expect(sent.filter { $0 == "SelfActivate" }.count == PIMService.reactivationDelays.count)
    }

    @Test func aLostAnswerIsMatchedByStartTimeWhenTheScheduleIdDiffers() async throws {
        let owner = try Fixture.role("rg-app-dev", "Owner")
        let transport = ScriptedPUTs([
            "SelfDeactivate": [(requestStatus("Revoked", requestType: "SelfDeactivate"), 201)],
            "SelfActivate": [(Data(), -1), (armError("RoleAssignmentExists"), 400)],
            "GET": [(activeInstance(schedule: "other"), 200)],
        ])
        let outcome = try await run(transport, try plan(owner))
        #expect(outcome == .renewed(until: AzureDate.parse("2026-10-29T13:00:00Z")))
    }

    @Test func aLostAnswerWithoutANewActivationStaysAFailure() async throws {
        let owner = try Fixture.role("rg-app-dev", "Owner")
        // Only the old activation (started before the renewal) is listed.
        let old = try #require(owner.activeSince)
        let transport = ScriptedPUTs([
            "SelfDeactivate": [(requestStatus("Revoked", requestType: "SelfDeactivate"), 201)],
            "SelfActivate": [(Data(), -1), (armError("RoleAssignmentExists"), 400)],
            "GET": [(activeInstance(schedule: "old", start: AzureDate.format(old)), 200)],
        ])
        let outcome = try await run(transport, try plan(owner))
        guard case .failed(let code, _) = outcome else { Issue.record("expected failure, got \(outcome)"); return }
        #expect(code == "ReactivationFailed")
        #expect(await transport.sent.filter { $0 == "GET" }.count == 1)
    }

    @Test func noLostAnswerMeansNoExtraRead() async throws {
        let owner = try Fixture.role("rg-app-dev", "Owner")
        let transport = ScriptedPUTs([
            "SelfDeactivate": [(requestStatus("Revoked", requestType: "SelfDeactivate"), 201)],
            "SelfActivate": [(armError("RoleAssignmentExists"), 400)],
            "GET": [(activeInstance(schedule: "other"), 200)],
        ])
        guard case .failed = try await run(transport, try plan(owner)) else { Issue.record("expected failure"); return }
        #expect(!(await transport.sent.contains("GET")))
    }

    @Test func anActivationThatHadAlreadyEndedIsActivatedAgain() async throws {
        let owner = try Fixture.role("rg-app-dev", "Owner")
        let transport = ScriptedPUTs([
            "SelfDeactivate": [(armError("RoleAssignmentDoesNotExist"), 404)],
            "SelfActivate": [(try Fixture.data("success-response"), 201)],
        ])
        guard case .renewed = try await run(transport, try plan(owner)) else { Issue.record("expected renewed"); return }
    }
}

@Suite("Deactivation eligibility link")
struct DeactivationLinkTests {
    static let scope = "/subscriptions/cccccccc-0000-0000-0000-00000000000c/resourceGroups/rg-app-dev"
    static let ownerId = "/subscriptions/cccccccc-0000-0000-0000-00000000000c/providers/Microsoft.Authorization/roleDefinitions/8e3af657-a8ff-443c-a75c-2fe8c4bcb635"
    static let directSchedule = "\(scope)/providers/Microsoft.Authorization/roleEligibilitySchedules/direct"
    static let groupSchedule = "\(scope)/providers/Microsoft.Authorization/roleEligibilitySchedules/group"

    /// Owner on rg-app-dev, eligible directly and through a group, activated
    /// through the group's eligibility.
    static func listings(linked: String? = groupSchedule) throws -> ([EligibilityScheduleInstance], [AssignmentScheduleInstance]) {
        func eligibility(_ id: String, _ schedule: String, _ member: String) -> String {
            #"{"id":"\#(id)","properties":{"roleEligibilityScheduleId":"\#(schedule)","scope":"\#(scope)","roleDefinitionId":"\#(ownerId)","memberType":"\#(member)"}}"#
        }
        let e = #"{"value":[\#(eligibility("e-direct", directSchedule, "Direct")),\#(eligibility("e-group", groupSchedule, "Group"))]}"#
        let link = linked.map { #""linkedRoleEligibilityScheduleId":"\#($0)","# } ?? ""
        let a = #"""
        {"value":[{"id":"i1","properties":{"roleAssignmentScheduleId":"\#(scope)/providers/Microsoft.Authorization/roleAssignmentSchedules/s1",
          "assignmentType":"Activated","memberType":"Group",\#(link)"scope":"\#(scope)","roleDefinitionId":"\#(ownerId)",
          "startDateTime":"2026-10-29T10:00:00Z","endDateTime":"2026-10-29T14:00:00Z"}}]}
        """#
        return (try JSONDecoder().decode(ARMList<EligibilityScheduleInstance>.self, from: Data(e.utf8)).value,
                try JSONDecoder().decode(ARMList<AssignmentScheduleInstance>.self, from: Data(a.utf8)).value)
    }

    static func linkedId(_ body: Data?) -> String? {
        let json = body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        return (json?["properties"] as? [String: Any])?["linkedRoleEligibilityScheduleId"] as? String
    }

    @Test func rowsKnowTheEligibilityTheirActivationWasMadeWith() throws {
        let (e, a) = try Self.listings()
        let rows = RoleMatcher.rows(eligibilities: e, assignments: a, now: Fixture.now)
        #expect(rows.count == 2)
        #expect(rows.allSatisfy { $0.activeEligibilityScheduleId == Self.groupSchedule })
        #expect(RenewPlan.asEligible(rows[0]).activeEligibilityScheduleId == nil)
    }

    @Test func theDeactivationSendsTheActivationsEligibilityNotTheRows() throws {
        let (e, a) = try Self.listings()
        let rows = RoleMatcher.rows(eligibilities: e, assignments: a, now: Fixture.now)
        let plans = try ActivationRequestBuilder.deactivationPlan(rows, principalId: Fixture.userOID)
        #expect(plans.count == 1)
        // Whichever row is kept, the activation was made with the group's eligibility.
        #expect(plans[0].body.properties.linkedRoleEligibilityScheduleId == Self.groupSchedule)
        #expect(Self.linkedId(plans[0].bodyJSON) == Self.groupSchedule)
    }

    @Test func anUnknownLinkIsReadFromTheActivationBeforeSending() async throws {
        let (e, unlinked) = try Self.listings(linked: nil)
        let rows = RoleMatcher.rows(eligibilities: e, assignments: unlinked, now: Fixture.now)
        #expect(rows.allSatisfy { $0.isActive && $0.activeEligibilityScheduleId == nil })
        let plans = try ActivationRequestBuilder.deactivationPlan(rows.filter { $0.membership == .direct }, principalId: Fixture.userOID)
        #expect(plans[0].body.properties.linkedRoleEligibilityScheduleId == Self.directSchedule)
        let (_, linked) = try Self.listings()
        let listing = try JSONSerialization.data(withJSONObject: ["value": [[
            "id": "i1", "properties": [
                "roleAssignmentScheduleId": "\(Self.scope)/providers/Microsoft.Authorization/roleAssignmentSchedules/s1",
                "assignmentType": "Activated", "scope": Self.scope, "roleDefinitionId": Self.ownerId,
                "linkedRoleEligibilityScheduleId": linked[0].properties.linkedRoleEligibilityScheduleId!,
                "startDateTime": "2026-10-29T10:00:00Z", "endDateTime": "2026-10-29T14:00:00Z"]]]])
        let transport = RecordingTransport { request in
            request.httpMethod == "GET" ? (listing, 200) : (Data(#"{"properties":{"status":"Revoked"}}"#.utf8), 201)
        }
        let service = PIMService(transport: transport, tokens: StaticTokenProvider(), clock: { Fixture.now })
        let box = OutcomeBox()
        try await service.execute(plans) { plan, outcome in box.set(plan.id, outcome) }
        let sent = await transport.requests
        #expect(sent.map { $0.httpMethod ?? "" } == ["GET", "PUT"])
        #expect(Self.linkedId(sent[1].httpBody) == Self.groupSchedule)
    }

    @Test func aKnownLinkNeedsNoRead() async throws {
        let (e, a) = try Self.listings()
        let rows = RoleMatcher.rows(eligibilities: e, assignments: a, now: Fixture.now)
        let plans = try ActivationRequestBuilder.deactivationPlan(rows, principalId: Fixture.userOID)
        let transport = RecordingTransport { _ in (Data(#"{"properties":{"status":"Revoked"}}"#.utf8), 201) }
        let service = PIMService(transport: transport, tokens: StaticTokenProvider(), clock: { Fixture.now })
        try await service.execute(plans) { _, _ in }
        #expect(await transport.requests.map { $0.httpMethod ?? "" } == ["PUT"])
    }

    @Test func aFailedReadSendsTheRowsEligibility() async throws {
        let (e, unlinked) = try Self.listings(linked: nil)
        let rows = RoleMatcher.rows(eligibilities: e, assignments: unlinked, now: Fixture.now)
        let plans = try ActivationRequestBuilder.deactivationPlan(rows.filter { $0.membership == .direct }, principalId: Fixture.userOID)
        let transport = RecordingTransport { request in
            request.httpMethod == "GET" ? (Data(), 500) : (Data(#"{"properties":{"status":"Revoked"}}"#.utf8), 201)
        }
        let service = PIMService(transport: transport, tokens: StaticTokenProvider(), clock: { Fixture.now })
        try await service.execute(plans) { _, _ in }
        let sent = await transport.requests
        #expect(sent.map { $0.httpMethod ?? "" } == ["GET", "PUT"])
        #expect(Self.linkedId(sent[1].httpBody) == Self.directSchedule)
    }
}
