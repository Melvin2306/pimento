import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import PimentoCore

/// The demo simulator, through the same `PIMService` calls the app and the
/// CLI make. Every test runs on a manual clock with the network blocked, and
/// checks that nothing tried to reach it.
struct DemoFixture {
    static let start = AzureDate.parse("2026-10-30T09:30:00Z")!
    static let utc = TimeZone(identifier: "UTC")!

    let clock: DemoClock
    let azure: DemoAzure
    let monitor = NetworkGuard.Monitor()

    init(behavior: DemoAzure.Behavior = .init(), start: Date = DemoFixture.start) {
        clock = DemoClock.manual(at: start)
        azure = DemoAzure(clock: clock, behavior: behavior, timeZone: Self.utc)
    }

    /// A service on the simulator, as the demo builds it (az's tokens, simulated).
    func service(tenant: String? = nil) -> PIMService {
        let clock = clock
        return PIMService(transport: azure, tokens: azure.cliTokens(tenantId: tenant),
                          sleep: { clock.advance(by: $0) }, clock: { clock.now() })
    }

    func roles(tenant: String? = nil) async throws -> [EligibleRole] {
        try await service(tenant: tenant).loadRoles(now: clock.now()).roles
    }

    func role(_ scopeName: String, _ roleName: String, tenant: String? = nil) async throws -> EligibleRole {
        try #require(try await roles(tenant: tenant).first { $0.scopeName == scopeName && $0.roleName == roleName })
    }

    /// Activates `role` for `minutes` (no policy cap), from `start` (nil: now).
    func activate(_ role: EligibleRole, minutes: Int, justification: String = "Demo test", start: Date? = nil,
                  ticket: TicketInfo? = nil) async throws -> ActivationOutcome {
        let plans = try ActivationRequestBuilder.plan(
            [role], principalId: DemoDirectory.user.id, justification: justification, now: clock.now(), start: start, ticket: ticket
        ) { _ in EffectiveDuration(minutes: minutes, requested: .hours(max(1, minutes / 60)), policyMaxMinutes: nil) }
        let box = TestBox<ActivationOutcome>()
        try await service().execute(plans) { _, outcome in box.value = outcome }
        return try #require(box.value)
    }

    func deactivate(_ role: EligibleRole) async throws -> ActivationOutcome {
        let plans = try ActivationRequestBuilder.deactivationPlan([role], principalId: DemoDirectory.user.id, now: clock.now())
        let box = TestBox<ActivationOutcome>()
        try await service().execute(plans) { _, outcome in box.value = outcome }
        return try #require(box.value)
    }

    /// Runs `body` with the network blocked for the task; fails the test if anything tried it.
    func offline<T>(_ body: () async throws -> T) async throws -> T {
        let result = try await NetworkGuard.$monitor.withValue(monitor) { try await body() }
        #expect(monitor.blocked.isEmpty, "demo code tried the network: \(monitor.blocked)")
        return result
    }
}

@Suite("Demo: ARM simulator")
struct DemoAzureTests {
    @Test func listsTheDemoUsersRolesWithGroupsConditionsAndActivations() async throws {
        let f = DemoFixture()
        try await f.offline { () async throws in
            let snapshot = try await f.service().loadRoles(now: f.clock.now())
            #expect(snapshot.identity.displayName == "Alex Wilber")
            #expect(snapshot.identity.upn == "alex.wilber@contoso.example")
            #expect(snapshot.identity.tenantId == DemoDirectory.contoso.id)
            #expect(snapshot.roles.count == 16)
            #expect(snapshot.roles.contains { $0.membership == .group("sg-platform-oncall") })
            #expect(snapshot.roles.contains { $0.membership == .direct })
            #expect(snapshot.roles.filter(\.hasCondition).count == 3)
            let active = snapshot.roles.filter(\.isActive)
            #expect(Set(active.map(\.roleName)) == ["Contributor", "Key Vault Secrets User"])
            #expect(active.count == 2 + 1) // Contributor on Production (group) and Development, Key Vault
            let kv = try #require(active.first { $0.roleName == "Key Vault Secrets User" })
            #expect(kv.activeUntil == f.clock.now().addingTimeInterval(8 * 60))
            #expect(snapshot.timeBoundAssignments.count == 1)
            // 16 eligibilities, 10 per page: the listing follows nextLink once.
            #expect(f.azure.requestLog.filter { $0.hasSuffix("roleEligibilityScheduleInstances") }.count == 2)
        }
    }

    @Test func otherTenantsHaveTheirOwnRoles() async throws {
        let f = DemoFixture()
        try await f.offline { () async throws in
            #expect(try await f.roles(tenant: DemoDirectory.fabrikam.id).count == 3)
            #expect(try await f.roles(tenant: "northwindtraders.example").count == 2)
            #expect(try await f.roles(tenant: DemoDirectory.adventureWorks.id).count == 1)
            #expect(try await f.roles(tenant: DemoDirectory.unnamed.id).isEmpty)
        }
    }

    @Test func policiesCarryMaximaTicketsMfaAndApproval() async throws {
        let f = DemoFixture()
        try await f.offline { () async throws in
            let roles = try await f.roles()
            let policies = try await f.service().loadPolicies(for: roles)
            func policy(_ scope: String, _ role: String) -> RolePolicy? {
                roles.first { $0.scopeName == scope && $0.roleName == role }.flatMap { policies[$0.policyKey]?.policy }
            }
            #expect(policies.count == 15) // two rows share rg-contoso-web-prod · Contributor
            #expect(policy("Contoso Production", "Owner") == RolePolicy(
                maximumDuration: 3600, requiresJustification: true, requiresMFA: true, requiresApproval: true,
                policyId: policy("Contoso Production", "Owner")?.policyId))
            #expect(policy("Contoso Production", "Contributor")?.maxMinutes == 240)
            #expect(policy("Contoso Production", "Contributor")?.requiresTicket == true)
            #expect(policy("kv-contoso-prod", "Key Vault Secrets User")?.requiresTicket == true)
            #expect(policy("Contoso Root", "Reader")?.maxMinutes == 480)
        }
    }

    @Test func activationBecomesActiveAndASecondOneIsRoleAssignmentExists() async throws {
        let f = DemoFixture()
        try await f.offline { () async throws in
            let owner = try await f.role("Contoso Staging", "Owner")
            let outcome = try await f.activate(owner, minutes: 240)
            #expect(outcome == .activated(status: "Provisioned", until: f.clock.now().addingTimeInterval(4 * 3600)))
            let active = try await f.role("Contoso Staging", "Owner")
            #expect(active.isActive)
            #expect(active.activeUntil == f.clock.now().addingTimeInterval(4 * 3600))
            #expect(try await f.activate(active, minutes: 60) == .alreadyActive)
        }
    }

    /// Pimento percent-encodes the scope of a request URL (`ARMScope.path`):
    /// the simulator matches the decoded scope, as ARM does.
    @Test func aPercentEncodedScopeIsTheSameScope() async throws {
        let f = DemoFixture()
        try await f.offline { () async throws in
            let web = try await f.role("rg-contoso-web-prod", "Website Contributor")
            let planned = try #require(try ActivationRequestBuilder.plan(
                [web], principalId: DemoDirectory.user.id, justification: "Encoded", now: f.clock.now()
            ) { _ in EffectiveDuration(minutes: 60, requested: .hours(1), policyMaxMinutes: nil) }.first)
            // `-` encoded as ARMScope would encode a character outside its allowlist.
            let raw = planned.url.absoluteString.replacingOccurrences(of: "/rg-contoso-web-prod/", with: "/rg%2Dcontoso%2Dweb%2Dprod/")
            #expect(raw != planned.url.absoluteString)
            let encoded = PlannedRequest(role: web, url: try #require(URL(string: raw)), body: planned.body,
                                         requestedAt: planned.requestedAt, duration: planned.duration)
            let box = TestBox<ActivationOutcome>()
            try await f.service().execute([encoded]) { _, outcome in box.value = outcome }
            #expect(box.value?.leavesRoleActive == true)
            #expect(try await f.role("rg-contoso-web-prod", "Website Contributor").isActive)
        }
    }

    @Test func policyRulesAreEnforcedWithTheRealErrorCodes() async throws {
        let f = DemoFixture()
        try await f.offline { () async throws in
            let owner = try await f.role("Contoso Staging", "Owner")
            #expect(try await f.activate(owner, minutes: 480) == .policyViolation(
                rules: ["ExpirationRule"], message: "The following policy rules failed: [\"ExpirationRule\"]"))
            let kv = try await f.role("rg-contoso-data-prod", "Contributor")
            guard case .policyViolation(let rules, _) = try await f.activate(kv, minutes: 60) else {
                Issue.record("expected a policy violation")
                return
            }
            #expect(rules == ["TicketingRule"])
            #expect(try await f.activate(kv, minutes: 60, ticket: TicketInfo(number: "DATA-1", system: "Jira")).leavesRoleActive)
        }
    }

    @Test func approvalTimelineFromPendingToApprovedByTheSimulatedApprover() async throws {
        let f = DemoFixture()
        try await f.offline { () async throws in
            let owner = try await f.role("Contoso Production", "Owner")
            let outcome = try await f.activate(owner, minutes: 60, justification: "Rotate the TLS certificate")
            #expect(outcome.isAwaitingApproval)
            // A second request while one waits: PIM refuses it.
            guard case .failed(let code, _) = try await f.activate(owner, minutes: 60) else {
                Issue.record("expected a failure")
                return
            }
            #expect(code == "PendingRoleAssignmentRequest")
            var tracker = ApprovalTracker()
            let pending = try await f.service().loadRequestHistory(now: f.clock.now())
            #expect(pending.pending.contains { $0.kind == .awaitingApproval && $0.roleName == "Owner" })
            _ = tracker.update(items: pending.items, principalId: DemoDirectory.user.id, now: f.clock.now())
            #expect(tracker.count == 1)

            f.clock.advance(by: 30)
            #expect(try await f.role("Contoso Production", "Owner").isActive == false)
            f.clock.advance(by: 20) // past the 45-second approval delay
            let history = try await f.service().loadRequestHistory(now: f.clock.now())
            let decided = tracker.update(items: history.items, principalId: DemoDirectory.user.id, now: f.clock.now())
            #expect(decided.count == 1)
            #expect(decided.first?.resolution.isApproved == true)
            #expect(decided.first?.status == "Provisioned")
            let review = await f.service().review(approvalId: decided.first?.request.approvalId)
            #expect(review == ReviewInfo(reviewer: "Megan Bowen", justification: "Approved for the change window"))
            let active = try await f.role("Contoso Production", "Owner")
            #expect(active.isActive)
            #expect(active.activeUntil == f.clock.now().addingTimeInterval(3600 - 5))
        }
    }

    @Test func aJustificationSayingDenyIsDenied() async throws {
        let f = DemoFixture()
        try await f.offline { () async throws in
            let owner = try await f.role("Contoso Production", "Owner")
            _ = try await f.activate(owner, minutes: 60, justification: "Please deny this one")
            f.clock.advance(by: 60)
            let items = try await f.service().loadRequestHistory(now: f.clock.now()).items
            let mine = try #require(items.first { $0.properties?.justification == "Please deny this one" })
            #expect(ApprovalTracker.resolution(of: mine) == .denied)
            #expect(try await f.role("Contoso Production", "Owner").isActive == false)
        }
    }

    @Test func requestsWaitingADayTimeOut() async throws {
        let f = DemoFixture()
        try await f.offline { () async throws in
            f.clock.advance(by: 24 * 3600)
            let inbox = try await f.service().loadApprovalInbox().inbox
            // Megan's and Diego's requests expired; Isaiah's (arrived later) still waits.
            #expect(inbox.requests.map(\.requesterName) == ["Isaiah Langer"])
        }
    }

    @Test func deactivationInTheFirstFiveMinutesIsTooSoonThenWorksThenNotActive() async throws {
        let f = DemoFixture()
        try await f.offline { () async throws in
            let owner = try await f.role("Contoso Staging", "Owner")
            _ = try await f.activate(owner, minutes: 60)
            f.clock.advance(by: 60)
            let active = try await f.role("Contoso Staging", "Owner")
            #expect(try await f.deactivate(active) == .tooSoon(possibleAt: active.activeSince!.addingTimeInterval(300)))
            f.clock.advance(by: 300)
            #expect(try await f.deactivate(active) == .deactivated(status: "Revoked"))
            #expect(try await f.role("Contoso Staging", "Owner").isActive == false)
            #expect(try await f.deactivate(active) == .notActive)
        }
    }

    @Test func activeDurationTooShortIsMappedTheSameWay() async throws {
        var behavior = DemoAzure.Behavior()
        behavior.tooSoonCode = "ActiveDurationTooShort"
        let f = DemoFixture(behavior: behavior)
        try await f.offline { () async throws in
            let owner = try await f.role("Contoso Staging", "Owner")
            _ = try await f.activate(owner, minutes: 60)
            let active = try await f.role("Contoso Staging", "Owner")
            #expect(try await f.deactivate(active) == .tooSoon(possibleAt: active.activeSince!.addingTimeInterval(300)))
        }
    }

    @Test func renewRetriesThroughRoleAssignmentExists() async throws {
        let f = DemoFixture()
        try await f.offline { () async throws in
            let contributor = try await f.role("Contoso Development", "Contributor")
            let plans = try ActivationRequestBuilder.renewPlan(
                [contributor], principalId: DemoDirectory.user.id, justification: "Fresh hours", now: f.clock.now()
            ) { _ in EffectiveDuration(minutes: 480, requested: .hours(8), policyMaxMinutes: 480) }
            let phases = Collector<RenewPhase>()
            let result = TestBox<ActivationOutcome>()
            try await f.service().renew(plans, onPhase: { _, phase in phases.append(phase) }) { _, outcome in result.value = outcome }
            #expect(result.value == .renewed(until: f.clock.now().addingTimeInterval(8 * 3600)))
            // PIM held the old activation for a few seconds: the first attempts were refused.
            #expect(phases.items.contains(.reactivating(attempt: 2)))
        }
    }

    @Test func scheduledActivationStartsOnTime() async throws {
        let f = DemoFixture()
        try await f.offline { () async throws in
            let reader = try await f.role("Contoso Root", "Reader")
            let start = f.clock.now().addingTimeInterval(2 * 3600)
            guard case .scheduled(let status, let at, _) = try await f.activate(reader, minutes: 120, start: start) else {
                Issue.record("expected a scheduled activation")
                return
            }
            #expect(status == "Granted")
            #expect(at == start)
            let scheduled = try await f.service().loadScheduledRequests(now: f.clock.now()).requests
            #expect(scheduled.filter { $0.kind == .scheduled }.map(\.roleName).sorted() == ["Contributor", "Reader"])
            f.clock.advance(by: 2 * 3600 + 1)
            let active = try await f.role("Contoso Root", "Reader")
            #expect(active.isActive)
            #expect(active.activeUntil == start.addingTimeInterval(2 * 3600))
        }
    }

    @Test func cancelWorksOnceThenRequestCannotBeCancelled() async throws {
        let f = DemoFixture()
        try await f.offline { () async throws in
            let scheduled = try #require(try await f.service().loadScheduledRequests(now: f.clock.now()).requests.first)
            #expect(scheduled.roleName == "Contributor")
            #expect(scheduled.scopeName == "Contoso Staging")
            let outcomes = Collector<CancelOutcome>()
            try await f.service().cancel([scheduled, scheduled], maxConcurrent: 1) { _, o in outcomes.append(o) }
            #expect(outcomes.items.first == .canceled)
            guard case .notCancellable = outcomes.items.last else {
                Issue.record("expected RequestCannotBeCancelled, got \(outcomes.items)")
                return
            }
            #expect(try await f.service().loadScheduledRequests(now: f.clock.now()).requests.isEmpty)
        }
    }

    @Test func approverInboxStagesDecisionsAndArrivals() async throws {
        let f = DemoFixture()
        try await f.offline { () async throws in
            let service = f.service()
            let inbox = try await service.loadApprovalInbox().inbox
            #expect(inbox.unavailable == nil)
            #expect(inbox.requests.map(\.requesterName) == ["Diego Siciliani", "Megan Bowen"])
            #expect(inbox.requests.allSatisfy { $0.stage?.assignedToMe == true && $0.stage?.isOpen == true })
            let megan = try #require(inbox.requests.last)
            #expect(megan.ticket == TicketInfo(number: "CHG-2291", system: "ServiceNow"))
            #expect(megan.durationMinutes == 60)

            let plans = try PlannedDecision.plan([megan], decision: .approve, justification: "Planned rotation")
            let results = Collector<DecisionOutcome>()
            try await service.decide(plans + plans, maxConcurrent: 1) { _, o in results.append(o) }
            #expect(results.items == [.decided(.approve), .notPending(DecisionOutcome.noOpenStageMessage)])
            #expect(try await service.loadApprovalInbox().inbox.requests.map(\.requesterName) == ["Diego Siciliani"])

            // A colleague's request arrives after two and a half minutes.
            f.clock.advance(by: 151)
            let later = try await service.loadApprovalInbox().inbox.requests
            #expect(ApprovalParser.arrivals(previous: ["x"], current: later).map(\.requesterName) == ["Diego Siciliani", "Isaiah Langer"])
            #expect(later.map(\.requesterName) == ["Diego Siciliani", "Isaiah Langer"])
        }
    }

    @Test func approvalsListingAcceptsOnlyAsApprover() async throws {
        let f = DemoFixture()
        try f.offlineSync { () throws in
            var request = URLRequest(url: URL(string: "\(ARM.baseURL)/providers/Microsoft.Authorization/roleAssignmentApprovals?api-version=\(ARM.approvalsApiVersion)&$filter=asTarget()")!)
            request.setValue("Bearer \(try f.azure.cliAccessToken(tenantId: nil))", forHTTPHeaderField: "Authorization")
            let (data, status) = try f.azure.handle(request)
            #expect(status == 400)
            #expect(ARMErrorEnvelope.describe(data)?.contains("asApprover") == true)
        }
    }

    @Test func activationsExpireOnTheClock() async throws {
        let f = DemoFixture()
        try await f.offline { () async throws in
            #expect(try await f.role("kv-contoso-prod", "Key Vault Secrets User").isActive)
            f.clock.advance(by: 8 * 60 + 1)
            #expect(try await f.role("kv-contoso-prod", "Key Vault Secrets User").isActive == false)
            f.clock.advance(by: 6 * 3600)
            #expect(try await f.roles().filter(\.isActive).isEmpty)
        }
    }

    @Test func extensionIsPendingAdminDecisionOnce() async throws {
        let f = DemoFixture()
        try await f.offline { () async throws in
            let assignment = try #require(try await f.service().loadRoles(now: f.clock.now()).timeBoundAssignments.first)
            #expect(assignment.roleName == "Reader")
            let plans = try ActivationRequestBuilder.extensionPlan([assignment, assignment], principalId: DemoDirectory.user.id,
                                                                   justification: "Audit", days: 30, now: f.clock.now())
            let outcomes = Collector<ActivationOutcome>()
            try await f.service().execute(plans, maxConcurrent: 1) { _, o in outcomes.append(o) }
            #expect(outcomes.items.first == .activated(status: "PendingAdminDecision", until: nil))
            #expect(outcomes.items.last == .failed(
                code: "PendingRoleAssignmentRequest",
                message: "A request for this role is already pending; cancel it in the Azure portal (PIM › My requests) or wait. (There is already an existing pending Role assignment request.)"))
        }
    }

    @Test func tenantsArePagedAndOneIsUnnamed() async throws {
        let f = DemoFixture()
        try await f.offline { () async throws in
            let tenants = TenantDirectory.sorted(try await TenantDirectory.fetchARM(tokens: f.azure.cliTokens(tenantId: nil), transport: f.azure))
            #expect(tenants.map(\.label) == ["Adventure Works", "Contoso", "Fabrikam", "Northwind Traders", "Unnamed tenant \(DemoDirectory.unnamed.id.prefix(8))"])
            #expect(f.azure.requestLog.filter { $0 == "GET /tenants" }.count == 2)
        }
    }

    @Test func tokensAreCheckedLikeARMDoes() async throws {
        let f = DemoFixture()
        try await f.offline { () async throws in
            #expect(throws: AzureCLIError.self) { try f.azure.cliAccessToken(tenantId: "11111111-1111-1111-1111-111111111111") }
            let forged = PIMService(transport: f.azure, tokens: StaticTokenProvider(token: fakeToken(["oid": DemoDirectory.user.id, "tid": DemoDirectory.contoso.id])))
            do {
                _ = try await forged.loadRoles()
                Issue.record("a token the demo did not mint was accepted")
            } catch PIMServiceError.http(let status, let message) {
                #expect(status == 401)
                #expect(message.hasPrefix("InvalidAuthenticationToken"))
            }
        }
    }

    @Test func historyImportReadsThePastRequests() async throws {
        let f = DemoFixture()
        try await f.offline { () async throws in
            let records = try await f.service().loadHistoryFromAzure(now: f.clock.now())
            #expect(records.count >= 10)
            #expect(Set(records.map(\.result)).isSuperset(of: [.succeeded, .denied, .canceled, .expired]))
            #expect(records.allSatisfy { $0.source == .azure })
        }
    }

    @Test func pimentoSignInRunsOnTheSimulatedTokenEndpoint() async throws {
        let f = DemoFixture()
        try await f.offline { () async throws in
            let session = DemoSession(options: DemoOptions(), clock: f.clock, workspace: DemoWorkspace.temporary(), timeZone: DemoFixture.utc)
            let broker = session.makeBroker()
            let token = try await broker.accessToken(accountId: nil, tenantId: DemoDirectory.fabrikam.id)
            #expect(JWT.identity(fromToken: token)?.tenantId == DemoDirectory.fabrikam.id)
            // Device code: one "authorization_pending", then signed in.
            let challenge = try await broker.startDeviceCode(clientId: DemoDirectory.clientId)
            #expect(challenge.userCode == "DEMO-4821")
            let account = try await broker.finishDeviceCode(challenge, clientId: DemoDirectory.clientId) { _ in }
            #expect(account.displayName == "Alex Wilber <alex.wilber@contoso.example>")
            #expect(account.tenantId == DemoDirectory.contoso.id)
            await #expect(throws: SignInError.self) { try await broker.accessToken(accountId: nil, tenantId: "11111111-1111-1111-1111-111111111111") }
        }
    }

    @Test func otherHostsAreUnknown() throws {
        let f = DemoFixture()
        #expect(throws: DemoAzure.UnknownHost.self) { try f.azure.handle(URLRequest(url: URL(string: "https://graph.microsoft.com/v1.0/me")!)) }
        #expect(throws: DemoAzure.UnknownHost.self) { try f.azure.handle(URLRequest(url: URL(string: "http://management.azure.com/tenants")!)) }
    }

    @Test func idsAreStable() {
        #expect(DemoID.uuid("tenant-contoso") == DemoID.uuid("tenant-contoso"))
        #expect(UUID(uuidString: DemoID.uuid("x")) != nil)
        #expect(DemoID.uuid("a") != DemoID.uuid("b"))
    }
}

extension DemoFixture {
    func offlineSync<T>(_ body: () throws -> T) throws -> T {
        let result = try NetworkGuard.$monitor.withValue(monitor) { try body() }
        #expect(monitor.blocked.isEmpty)
        return result
    }
}

@Suite("Demo: clock")
struct DemoClockTests {
    @Test func runsShiftedSpedUpFrozenAndManually() {
        let real = TestBox(Date(timeIntervalSince1970: 1_000_000))
        let clock = DemoClock(start: Date(timeIntervalSince1970: 0), rate: 60, realNow: { real.value! })
        #expect(clock.now() == Date(timeIntervalSince1970: 0))
        real.value = real.value!.addingTimeInterval(10)
        #expect(clock.now() == Date(timeIntervalSince1970: 600))
        #expect(clock.realInterval(until: Date(timeIntervalSince1970: 1200)) == 10)
        clock.rate = 0
        real.value = real.value!.addingTimeInterval(100)
        #expect(clock.now() == Date(timeIntervalSince1970: 600))
        #expect(clock.isFrozen)
        #expect(clock.realInterval(until: Date(timeIntervalSince1970: 1200)) == nil)
        clock.advance(by: 30)
        #expect(clock.now() == Date(timeIntervalSince1970: 630))
    }

    @Test func tidyClockIsTenThirtyToday() {
        let utc = TimeZone(identifier: "UTC")!
        let options = DemoOptions(frozenAt: DemoMode.tidyMinutes)
        let clock = options.makeClock(realNow: { AzureDate.parse("2026-10-30T17:45:12Z")! }, timeZone: utc)
        #expect(clock.now() == AzureDate.parse("2026-10-30T10:30:00Z"))
        #expect(clock.isFrozen)
    }
}

/// Collects values from concurrent callbacks.
final class Collector<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [T] = []
    func append(_ value: T) { lock.withLock { stored.append(value) } }
    var items: [T] { lock.withLock { stored } }
}
