import Foundation
import Testing
@testable import PimentoCore

@Suite("ARM response → outcome mapping")
struct OutcomeMappingTests {
    func outcome(_ status: Int, _ fixture: String?) throws -> ActivationOutcome {
        let data = try fixture.map(Fixture.data) ?? Data()
        return ActivationResponseMapper.outcome(statusCode: status, data: data, requestedAt: Fixture.now, hours: 4)
    }

    @Test func roleAssignmentExistsIsSkipped() throws {
        let o = try outcome(400, "error-exists")
        #expect(o == .alreadyActive)
        #expect(!o.isFailure)
        #expect(o.summary == "Skipped (already active)")
    }

    @Test func policyFailureListsTheFailedRules() throws {
        let o = try outcome(400, "error-policy")
        guard case .policyViolation(let rules, let message) = o else {
            Issue.record("expected policyViolation, got \(o)")
            return
        }
        #expect(rules == ["ExpirationRule", "JustificationRule"])
        #expect(message.contains("ExpirationRule"))
        #expect(o.isFailure)
        #expect(o.summary.contains("maximum activation time"))
        #expect(o.summary.contains("justification required"))
    }

    @Test func tokenErrorsCarryALoginHint() throws {
        let o = try outcome(401, "error-token")
        guard case .failed(let code, let message) = o else {
            Issue.record("expected failed, got \(o)")
            return
        }
        #expect(code == "InvalidAuthenticationToken")
        #expect(message.contains("az login"))
    }

    @Test func unknownAndNonJSONErrorsAreFailures() throws {
        #expect(try outcome(403, nil) == .failed(code: "HTTP 403", message: "forbidden"))
        let o = ActivationResponseMapper.outcome(statusCode: 502, data: Data("<html>bad gateway</html>".utf8), requestedAt: Fixture.now, hours: 1)
        #expect(o == .failed(code: "HTTP 502", message: "<html>bad gateway</html>"))
        let authz = Data(#"{"error":{"code":"AuthorizationFailed","message":"nope"}}"#.utf8)
        #expect(ActivationResponseMapper.outcome(statusCode: 403, data: authz, requestedAt: Fixture.now, hours: 1)
            == .failed(code: "AuthorizationFailed", message: "nope"))
    }

    @Test func successComputesExpiryFromResponseStart() throws {
        let o = try outcome(201, "success-response")
        #expect(o == .activated(status: "Provisioned", until: AzureDate.parse("2026-10-29T16:00:00.123Z")))
        #expect(!o.isFailure)
        #expect(o.summary.hasPrefix("Activated until"))
    }

    @Test func pendingApprovalIsReportedAsAwaitingApproval() {
        let o = ActivationOutcome.activated(status: "PendingApproval", until: nil)
        #expect(o.summary == "Awaiting approval")
        #expect(o.isAwaitingApproval)
    }

    @Test func ruleExtractionIgnoresProse() {
        #expect(ActivationResponseMapper.failedRules(in: "The following policy rules failed: [\"MfaRule\"]. Rule text") == ["MfaRule"])
        #expect(ActivationResponseMapper.failedRules(in: "no rules here") == [])
    }
}

@Suite("Auth helpers")
struct AuthTests {
    @Test func identityComesFromTheTokenClaims() throws {
        let token = fakeToken(["oid": "abc-oid", "name": "Ada Lovelace", "upn": "ada@example.com", "tid": "t1"])
        let id = try #require(JWT.identity(fromToken: token))
        #expect(id == Identity(objectId: "abc-oid", name: "Ada Lovelace", upn: "ada@example.com", tenantId: "t1"))
        #expect(JWT.identity(fromToken: fakeToken(["name": "no oid"])) == nil)
        #expect(JWT.identity(fromToken: "garbage") == nil)
    }

    @Test func locatesAzPreferringHomebrew() {
        let present: Set<String> = ["/opt/homebrew/bin/az", "/custom/bin/az"]
        #expect(AzureCLI.locate(environment: ["PATH": "/custom/bin"], isExecutable: present.contains) == "/opt/homebrew/bin/az")
        #expect(AzureCLI.locate(environment: ["PATH": "/x:/custom/bin"], isExecutable: ["/custom/bin/az"].contains) == "/custom/bin/az")
        #expect(AzureCLI.locate(environment: [:], isExecutable: { _ in false }) == nil)
    }

    @Test func tokenCommandPinsTenantAndResource() {
        let args = AzureCLITokenProvider(tenantId: "tenant-x", azPath: "/bin/false").arguments()
        #expect(args.starts(with: ["account", "get-access-token"]))
        #expect(args.contains("tenant-x"))
        #expect(zip(args, args.dropFirst()).contains { $0 == "--resource" && $1 == "https://management.azure.com/" })
    }

    @Test func noTenantMeansAzDefault() {
        let args = AzureCLITokenProvider(tenantId: nil).arguments()
        #expect(!args.contains("--tenant"))
        #expect(args.contains("--resource"))
        #expect(AzureCLIError.loginCommand(tenant: nil) == "az login")
        #expect(AzureCLIError.loginCommand(tenant: "contoso.onmicrosoft.com") == "az login --tenant contoso.onmicrosoft.com")
    }
}

@Suite("PIMService with a fake transport")
struct PIMServiceTests {
    @Test func loadRolesFollowsNextLinkAndOnlyGETs() async throws {
        let page1 = try Fixture.data("eligibilities-page1")
        let page2 = try Fixture.data("eligibilities-page2")
        let assignments = try Fixture.data("assignments")
        let transport = RecordingTransport { request in
            let url = request.url!.absoluteString
            if url.contains("roleAssignmentScheduleInstances") { return (assignments, 200) }
            return (url.contains("skiptoken=page2") ? page2 : page1, 200)
        }
        let service = PIMService(transport: transport, tokens: StaticTokenProvider())
        let snapshot = try await service.loadRoles(now: Fixture.now)

        #expect(snapshot.identity.objectId == Fixture.userOID)
        #expect(snapshot.roles.count == 4)
        #expect(snapshot.roles.filter(\.isActive).count == 2)
        let requests = await transport.requests
        #expect(requests.count == 3)
        #expect(requests.allSatisfy { $0.httpMethod == "GET" })
        #expect(requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization")?.hasPrefix("Bearer ") == true })
        #expect(requests.allSatisfy { $0.url!.absoluteString.contains("asTarget()") })
    }

    @Test func foreignNextLinkIsNotFollowed() async throws {
        let page = Data(#"{"value":[],"nextLink":"https://evil.example.com/steal"}"#.utf8)
        let transport = RecordingTransport { _ in (page, 200) }
        let service = PIMService(transport: transport, tokens: StaticTokenProvider())
        _ = try await service.loadRoles()
        let hosts = await transport.requests.compactMap { $0.url?.host }
        #expect(hosts == ["management.azure.com", "management.azure.com"])
    }

    @Test func listingErrorSurfacesARMMessage() async throws {
        let transport = RecordingTransport { _ in
            (Data(#"{"error":{"code":"AuthorizationFailed","message":"no access"}}"#.utf8), 403)
        }
        let service = PIMService(transport: transport, tokens: StaticTokenProvider())
        await #expect(throws: PIMServiceError.self) { try await service.loadRoles() }
    }

    @Test func executeIsBoundedAndReportsEveryOutcome() async throws {
        let base = try Fixture.role("Contoso Production", "Reader")
        let roles = (0..<20).map { i in
            EligibleRole(id: "row-\(i)", eligibilityScheduleId: base.eligibilityScheduleId, roleDefinitionId: base.roleDefinitionId,
                         roleName: base.roleName, scope: "/subscriptions/sub-\(i)", scopeName: "Sub \(i)",
                         scopeType: base.scopeType, membership: .direct)
        }
        let plans = try ActivationRequestBuilder.plan(roles, principalId: Fixture.userOID, justification: "x", hours: 8, now: Fixture.now)
        let exists = try Fixture.data("error-exists")
        let ok = try Fixture.data("success-response")
        let transport = RecordingTransport(delayNanos: 20_000_000) { request in
            // sub-0, sub-3, sub-6, … are already active.
            let sub = request.url!.pathComponents[2]
            let index = Int(sub.dropFirst("sub-".count))!
            return index % 3 == 0 ? (exists, 400) : (ok, 201)
        }
        let service = PIMService(transport: transport, tokens: StaticTokenProvider())
        let collected = Collected()
        try await service.execute(plans, maxConcurrent: 8) { plan, outcome in
            await collected.add(plan.id, outcome)
        }

        let results = await collected.items
        #expect(results.count == 20)
        #expect(Set(results.keys) == Set(roles.map(\.id)))
        #expect(results.values.filter { $0 == .alreadyActive }.count == 7)
        #expect(results.values.filter { if case .activated = $0 { true } else { false } }.count == 13)
        let peak = await transport.peakInFlight
        #expect(peak <= 8)
        #expect(peak > 1)
        let requests = await transport.requests
        #expect(requests.allSatisfy { $0.httpMethod == "PUT" })
        #expect(requests.allSatisfy { $0.value(forHTTPHeaderField: "Content-Type") == "application/json" })
        let sentBodies = Set(requests.compactMap(\.httpBody))
        #expect(sentBodies == Set(plans.map(\.bodyJSON)))
    }

    @Test func networkErrorsBecomeFailedOutcomes() async throws {
        struct Boom: Error {}
        let plans = try ActivationRequestBuilder.plan([Fixture.role("Contoso Production", "Reader")],
                                                      principalId: "me", justification: "x", hours: 1, now: Fixture.now)
        let service = PIMService(transport: RecordingTransport { _ in throw Boom() }, tokens: StaticTokenProvider())
        let collected = Collected()
        try await service.execute(plans) { plan, outcome in await collected.add(plan.id, outcome) }
        let outcome = try #require(await collected.items.values.first)
        guard case .failed(let code, _) = outcome else {
            Issue.record("expected failed, got \(outcome)")
            return
        }
        #expect(code == "NetworkError")
    }

    @Test func readOnlyTransportRefusesWrites() async throws {
        let inner = RecordingTransport { _ in (Data("{}".utf8), 200) }
        let readOnly = ReadOnlyTransport(inner)
        var put = URLRequest(url: URL(string: "https://management.azure.com/x")!)
        put.httpMethod = "PUT"
        await #expect(throws: ReadOnlyTransport.WriteRefused.self) { try await readOnly.send(put) }
        var get = URLRequest(url: URL(string: "https://management.azure.com/x")!)
        get.httpMethod = "GET"
        _ = try await readOnly.send(get)
        #expect(await inner.requests.map(\.httpMethod) == ["GET"])
    }

    @Test func executeWithReadOnlyTransportSendsNothing() async throws {
        let inner = RecordingTransport { _ in (Data("{}".utf8), 201) }
        let service = PIMService(transport: ReadOnlyTransport(inner), tokens: StaticTokenProvider())
        let plans = try ActivationRequestBuilder.plan(Fixture.rows(), principalId: "me", justification: "x", hours: 1, now: Fixture.now)
        let collected = Collected()
        try await service.execute(plans) { plan, outcome in await collected.add(plan.id, outcome) }
        #expect(await inner.requests.isEmpty)
        #expect(await collected.items.values.allSatisfy(\.isFailure))
    }
}

actor Collected {
    private(set) var items: [String: ActivationOutcome] = [:]
    func add(_ id: String, _ outcome: ActivationOutcome) { items[id] = outcome }
}
