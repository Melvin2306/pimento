import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import PimentoCore

/// Your `asTarget()` requests with the Contributor request `7a1b2c3d` in
/// `status`; the other fixture requests unchanged.
func scheduleRequests(with status: String) throws -> Data {
    var doc = try #require(try JSONSerialization.jsonObject(with: Fixture.data("schedule-requests")) as? [String: Any])
    var items = try #require(doc["value"] as? [[String: Any]])
    for i in items.indices where (items[i]["name"] as? String)?.hasPrefix("7a1b2c3d") == true {
        var props = try #require(items[i]["properties"] as? [String: Any])
        props["status"] = status
        items[i]["properties"] = props
    }
    doc["value"] = items
    return try JSONSerialization.data(withJSONObject: doc)
}

/// Answers the `asTarget()` listing with the statuses in turn (the last one repeats).
final class StatusSequence: @unchecked Sendable {
    private let lock = NSLock()
    private var statuses: [String]
    private(set) var reads = 0

    init(_ statuses: [String]) { self.statuses = statuses }

    func answer(_ request: URLRequest) throws -> (Data, Int)? {
        let url = request.url!.absoluteString
        if url.contains("roleAssignmentApprovals/7a1b2c3d") { return (try Fixture.data("approval-stages-denied"), 200) }
        guard url.contains("roleAssignmentScheduleRequests?"), url.contains("asTarget()") else { return nil }
        let status: String = lock.withLock {
            reads += 1
            return statuses.count > 1 ? statuses.removeFirst() : statuses[0]
        }
        return (try scheduleRequests(with: status), 200)
    }
}

@Suite("CLI: approval commands parsing")
struct CLIApprovalParserTests {
    func command(_ args: String...) throws -> CLICommand { try CLIParser.parse(args).command }

    @Test func pendingAndApprovals() throws {
        #expect(try command("pending", "--json", "-t", "contoso.example") == .pending({ var o = PendingOptions(); o.json = true; o.tenant = "contoso.example"; return o }()))
        #expect(try command("approvals") == .approvals(ApprovalsOptions()))
        #expect(throws: CLIParseError.unexpectedArgument("x", command: "approvals")) { try command("approvals", "x") }
    }

    @Test func waitTargetsAndTimeout() throws {
        guard case .wait(let o) = try command("wait", "7a1b2c3d", "5f0c", "--timeout", "2h", "--json") else { Issue.record("expected wait"); return }
        #expect(o.targets == ["7a1b2c3d", "5f0c"] && o.timeout == 7200 && o.json && !o.all)
        guard case .wait(let all) = try command("wait", "--all") else { Issue.record("expected wait"); return }
        #expect(all.all && all.timeout == 1800)
        #expect(throws: CLIParseError.noWaitSelection) { try command("wait") }
        #expect(throws: CLIParseError.invalidTimeout("soon")) { try command("wait", "--all", "--timeout", "soon") }
        #expect(throws: CLIParseError.invalidTimeout("25h")) { try command("wait", "--all", "--timeout", "25h") }
        #expect(throws: CLIParseError.conflicting("--all", "request id “7a1b”")) { try command("wait", "--all", "7a1b") }
        #expect(throws: CLIParseError.notARequestId("prod")) { try command("wait", "prod") }
    }

    @Test func timeouts() {
        #expect(WaitTimeout.parse("30m") == 1800)
        #expect(WaitTimeout.parse("1h30m") == 5400)
        #expect(WaitTimeout.parse("90s") == 90)
        #expect(WaitTimeout.parse("45") == 2700)
        #expect(WaitTimeout.parse("1d") == 86400)
        for bad in ["", "0", "m", "10x", "1h3", "-5"] { #expect(WaitTimeout.parse(bad) == nil, "\(bad)") }
        // Huge values are refused (out of range), not an overflow trap.
        #expect(WaitTimeout.parse("1000000000000000000") != nil)
        #expect(throws: CLIParseError.invalidTimeout("1000000000000000000")) { try command("wait", "--all", "--timeout", "1000000000000000000") }
        #expect(throws: CLIParseError.invalidTimeout("1000000000000000000d")) { try command("wait", "--all", "--timeout", "1000000000000000000d") }
        #expect(WaitTimeout.label(1800) == "30m")
        #expect(WaitTimeout.label(5400) == "1h 30m")
        #expect(WaitTimeout.label(7200) == "2h")
        #expect(WaitTimeout.label(30) == "30s")
    }

    @Test func approveAndDeny() throws {
        guard case .approve(let a) = try command("approve", "a1a1a1a1", "b2b2", "-j", "ok", "--yes", "--dry-run") else { Issue.record("expected approve"); return }
        #expect(a.decision == .approve && a.targets == ["a1a1a1a1", "b2b2"] && a.justification == "ok" && a.assumeYes && a.dryRun)
        guard case .deny(let d) = try command("deny", "a1a1", "-j", "no") else { Issue.record("expected deny"); return }
        #expect(d.decision == .deny)
        #expect(throws: CLIParseError.missingJustificationFor("approve")) { try command("approve", "a1a1") }
        #expect(throws: CLIParseError.noDecisionSelection("deny")) { try command("deny", "-j", "x") }
        #expect(throws: CLIParseError.notARequestId("--all")) { try command("deny", "--", "--all", "-j", "x") }
        #expect(throws: CLIParseError.unknownOption("--all", command: "approve")) { try command("approve", "--all", "-j", "x") }
        // Without a prompt only whole ids: a prefix is re-resolved when the command runs.
        #expect(throws: CLIParseError.fullRequestIdRequired("a1a1a1a1", command: "approve")) { try command("approve", "a1a1a1a1", "-j", "x", "--yes") }
        #expect(throws: CLIParseError.fullRequestIdRequired("a1a1a1a1-0000-4000-8000-00000000001", command: "deny")) {
            try command("deny", "a1a1a1a1-0000-4000-8000-00000000001", "-j", "x", "-y")
        }
        guard case .approve(let whole) = try command("approve", "a1a1a1a1-0000-4000-8000-000000000011", "-j", "x", "--yes") else {
            Issue.record("expected approve"); return
        }
        #expect(whole.targets == ["a1a1a1a1-0000-4000-8000-000000000011"] && whole.assumeYes)
    }

    @Test func helpAndCompletionsKnowTheNewCommands() throws {
        for name in ["pending", "wait", "approvals", "approve", "deny"] {
            #expect(try command(name, "--help") == .help(topic: name))
            #expect(CLIHelp.text(for: name).hasPrefix("Usage: pimento \(name)"))
            #expect(CLIHelp.text(for: nil).contains("  \(name) "))
            for shell in CompletionShell.allCases { #expect(CLIHelp.completionScript(for: shell).contains(name)) }
        }
        #expect(CLIHelp.text(for: "wait").contains("4 timed out"))
        #expect(CLIHelp.text(for: nil).contains("4 `wait` timed out"))
        for shell in CompletionShell.allCases { #expect(CLIHelp.completionScript(for: shell).contains("timeout")) }
    }
}

@Suite("CLI: requests awaiting approval")
struct CLIRequesterTests {
    @Test func activateReportsAwaitingApprovalWithExitZero() async throws {
        let h = CLIHarness(put: { _ in (Data(#"{"properties":{"status":"PendingApproval","scheduleInfo":{"startDateTime":"2026-10-29T12:00:00Z"}}}"#.utf8), 201) })
        #expect(await h.run("activate", "staging", "-j", "release", "--yes", "--json") == 0)
        let put = try #require(await h.puts.first)
        let id = put.url!.lastPathComponent
        #expect(h.err.contains("awaiting approval  Contributor · Contoso Staging (request \(id.prefix(8)))"))
        #expect(h.err.contains("1 awaiting approval."))
        #expect(h.err.contains("1 role waits for an approver"))
        #expect(h.err.contains("`pimento wait --all`"))
        let doc = try #require(try JSONSerialization.jsonObject(with: Data(h.out.utf8)) as? [String: Any])
        let result = try #require((doc["results"] as? [[String: Any]])?.first)
        #expect(result["outcome"] as? String == "submitted")
        #expect(result["requestId"] as? String == id)
        #expect((doc["summary"] as? [String: Any])?["submitted"] as? Int == 1)
    }

    @Test func pendingListsRequestsWithAgeAndExpiry() async throws {
        let h = CLIHarness()
        #expect(await h.run("pending") == 0)
        let lines = h.out.split(separator: "\n").map(String.init)
        #expect(lines.count == 2)
        #expect(lines[0].hasPrefix("ID") && lines[0].contains("ASKED") && lines[0].contains("EXPIRES"))
        #expect(lines[1].hasPrefix("7a1b2c3d") && lines[1].contains("Contributor") && lines[1].contains("4 h"))
        #expect(lines[1].contains("9m ago") && lines[1].contains("in 23h 50m") && lines[1].contains("PendingApproval"))
        #expect(await h.transport.requests.allSatisfy { $0.httpMethod == "GET" })

        let json = CLIHarness()
        #expect(await json.run("pending", "--json") == 0)
        let doc = try #require(try JSONSerialization.jsonObject(with: Data(json.out.utf8)) as? [String: Any])
        let requests = try #require(doc["requests"] as? [[String: Any]])
        #expect(requests.count == 1)
        #expect(requests[0]["expiresAt"] as? String == "2026-10-30T11:50:00.400Z")

        let none = CLIHarness()
        none.get = StatusSequence(["Provisioned"]).answer
        #expect(await none.run("pending") == 0)
        #expect(none.out == "No requests of yours wait for approval.\n")
    }

    @Test func waitUntilApproved() async throws {
        let h = CLIHarness()
        let sequence = StatusSequence(["PendingApproval", "PendingApproval", "Provisioned"])
        h.get = sequence.answer
        #expect(await h.run("wait", "7a1b") == 0)
        #expect(h.sleeps == [30, 30])
        #expect(h.out.contains("Waiting for 1 request to be decided (up to 30m, checking every 30s)"))
        #expect(h.out.contains("approved   Contributor · Contoso Staging (7a1b2c3d): active until 15:50"))
        #expect(h.out.contains("1 approved."))
        #expect(await h.transport.requests.allSatisfy { $0.httpMethod == "GET" })
    }

    @Test func waitReportsADenialWithTheApproversWords() async throws {
        let h = CLIHarness()
        h.get = StatusSequence(["PendingApproval", "Denied"]).answer
        #expect(await h.run("wait", "--all", "--json") == 1)
        #expect(h.err.contains("denied     Contributor · Contoso Staging (7a1b2c3d): “Use the staging subscription” by Nestor Wilke"))
        let doc = try #require(try JSONSerialization.jsonObject(with: Data(h.out.utf8)) as? [String: Any])
        let result = try #require((doc["results"] as? [[String: Any]])?.first)
        #expect(result["outcome"] as? String == "denied")
        #expect(result["reviewer"] as? String == "Nestor Wilke")
        #expect((doc["summary"] as? [String: Any])?["rejected"] as? Int == 1)
    }

    @Test func waitExpiredAndTimeout() async {
        let expired = CLIHarness()
        expired.get = StatusSequence(["PendingApproval", "TimedOut"]).answer
        #expect(await expired.run("wait", "7a1b2c3d") == 1)
        #expect(expired.out.contains("expired    Contributor · Contoso Staging (7a1b2c3d): no approver decided within 24 hours"))

        let slow = CLIHarness()
        slow.get = StatusSequence(["PendingApproval"]).answer
        #expect(await slow.run("wait", "7a1b2c3d", "--timeout", "2m") == 4)
        #expect(slow.sleeps == [30, 30, 30, 30])
        #expect(slow.out.contains("timeout    Contributor · Contoso Staging (7a1b2c3d): still awaiting approval after 2m"))
        #expect(slow.out.contains("1 still waiting."))
    }

    @Test func waitOnDecidedUnknownOrNothing() async {
        // Already decided: reported at once, no polling.
        let done = CLIHarness()
        #expect(await done.run("wait", "aaaa0000") == 0)
        #expect(done.sleeps.isEmpty)
        // That fixture request has no display names: the ids stand in.
        #expect(done.out.contains("approved   8e3af657-a8ff-443c-a75c-2fe8c4bcb635 · aaaaaaaa-0000-0000-0000-00000000000a (aaaa0000): active until 18:42"))

        let unknown = CLIHarness()
        #expect(await unknown.run("wait", "deadbeef") == 1)
        #expect(unknown.out.contains("not found  deadbeef: no request of yours with this id"))

        let nothing = CLIHarness()
        nothing.get = StatusSequence(["Provisioned"]).answer
        #expect(await nothing.run("wait", "--all") == 0)
        #expect(nothing.out.contains("No requests of yours wait for approval."))
    }

    @Test func waitExitCodes() {
        func s(_ a: Int, _ r: Int, _ t: Int, _ n: Int) -> CLIJSON.Waiting.Summary {
            var x = CLIJSON.Waiting.Summary(); x.approved = a; x.rejected = r; x.timedOut = t; x.notFound = n; return x
        }
        #expect(CLIRunner.waitExit(s(2, 0, 0, 0)) == .success)
        #expect(CLIRunner.waitExit(s(1, 0, 1, 0)) == .timeout)
        #expect(CLIRunner.waitExit(s(1, 1, 1, 0)) == .failure)
        #expect(CLIRunner.waitExit(s(0, 0, 0, 1)) == .failure)
        #expect(CLIExit.timeout.rawValue == 4)
    }
}

@Suite("CLI: approving and denying")
struct CLIApproverTests {
    @Test func approvalsTableAndJSON() async throws {
        let h = CLIHarness()
        #expect(await h.run("approvals") == 0)
        let lines = h.out.split(separator: "\n").map(String.init)
        #expect(lines.count == 3)
        #expect(lines[0].hasPrefix("ID") && lines[0].contains("REQUESTER") && lines[0].contains("JUSTIFICATION"))
        #expect(lines[1].hasPrefix("b2b2b2b2") && lines[1].contains("Lee Gu") && lines[1].contains("Owner (!)") && lines[1].contains("3h 00m ago")
            && lines[1].contains("in 21h 00m") && lines[1].contains("INC-77 outage"))
        #expect(lines[2].hasPrefix("a1a1a1a1") && lines[2].contains("Megan Bowen") && lines[2].contains("CHG-2002 (ServiceNow)"))
        #expect(await h.transport.requests.allSatisfy { $0.httpMethod == "GET" })

        let json = CLIHarness()
        #expect(await json.run("approvals", "--json") == 0)
        let doc = try #require(try JSONSerialization.jsonObject(with: Data(json.out.utf8)) as? [String: Any])
        #expect(doc["available"] as? Bool == true)
        let requests = try #require(doc["requests"] as? [[String: Any]])
        #expect(requests.count == 2)
        #expect((requests[1]["requester"] as? [String: Any])?["email"] as? String == "megan@contoso.example")
        #expect(requests[1]["stageId"] as? String == "5a5a5a5a-0000-4000-8000-000000000021")
        #expect(requests[0]["isOwner"] as? Bool == true)
    }

    @Test func noApproverPermissionsIsACalmEmptyList() async throws {
        let h = CLIHarness()
        h.get = { request in
            request.url!.absoluteString.contains("asApprover()")
                ? (Data(#"{"error":{"code":"AuthorizationFailed","message":"not allowed"}}"#.utf8), 403) : nil
        }
        #expect(await h.run("approvals") == 0)
        #expect(h.out == "You have no approvals to review.\n")
        #expect(h.err.isEmpty)
        let json = CLIHarness()
        json.get = h.get
        #expect(await json.run("approvals", "--json") == 0)
        let doc = try #require(try JSONSerialization.jsonObject(with: Data(json.out.utf8)) as? [String: Any])
        #expect(doc["available"] as? Bool == false)
        #expect((doc["note"] as? String)?.hasPrefix("HTTP 403") == true)
        #expect((doc["requests"] as? [Any])?.isEmpty == true)
    }

    @Test func approveSendsOnePatchPerRequest() async throws {
        let h = CLIHarness()
        #expect(await h.run("approve", "a1a1a1a1-0000-4000-8000-000000000011", "b2b2b2b2-0000-4000-8000-000000000012",
                            "-j", "matches the change", "--yes", "--json") == 0)
        let patches = await h.transport.requests.filter { $0.httpMethod == "PATCH" }
        #expect(patches.count == 2)
        let urls = Set(patches.map { $0.url!.absoluteString })
        #expect(urls.contains("https://management.azure.com/providers/Microsoft.Authorization/roleAssignmentApprovals/a1a1a1a1-0000-4000-8000-000000000011/stages/5a5a5a5a-0000-4000-8000-000000000021?api-version=2021-01-01-preview"))
        #expect(urls.contains { $0.contains("roleAssignmentApprovals/b2b2b2b2-0000-4000-8000-000000000012/stages/6b6b6b6b-0000-4000-8000-000000000022") })
        let body = try #require(try JSONSerialization.jsonObject(with: patches[0].httpBody ?? Data()) as? [String: String])
        #expect(body == ["reviewResult": "Approve", "justification": "matches the change"])
        #expect(h.err.contains("Warning: 1 Owner role (!)"))
        #expect(h.err.contains("approved   Owner · Fabrikam Production for Lee Gu"))
        let doc = try #require(try JSONSerialization.jsonObject(with: Data(h.out.utf8)) as? [String: Any])
        #expect((doc["summary"] as? [String: Any])?["decided"] as? Int == 2)
        #expect(doc["decision"] as? String == "approve")
    }

    /// One pending request in the approver's inbox, as ARM lists it.
    static func inboxItem(name: String, roleGUID: String, roleName: String, scopeName: String) -> [String: Any] {
        let scope = "/subscriptions/99999999-0000-4000-8000-000000000009"
        return [
            "id": "\(scope)/providers/Microsoft.Authorization/roleAssignmentScheduleRequests/\(name)",
            "name": name,
            "properties": [
                "scope": scope,
                "roleDefinitionId": "\(scope)/providers/Microsoft.Authorization/roleDefinitions/\(roleGUID)",
                "principalId": "44444444-0000-4000-8000-000000000004",
                "requestType": "SelfActivate",
                "status": "PendingApproval",
                "approvalId": "/providers/Microsoft.Authorization/roleAssignmentApprovals/\(name)",
                "scheduleInfo": ["startDateTime": "2026-10-29T11:00:00Z", "expiration": ["type": "AfterDuration", "duration": "PT8H"]],
                "justification": "read-only audit",
                "createdOn": "2026-10-29T11:00:00Z",
                "expandedProperties": [
                    "scope": ["displayName": scopeName, "type": "subscription"],
                    "roleDefinition": ["displayName": roleName],
                    "principal": ["displayName": "Dummy Requester", "email": "requester@example.com"],
                ],
            ] as [String: Any],
        ]
    }

    /// A requester cancels a reviewed request and submits another whose id
    /// starts the same: `--yes` decides only the exact id that was reviewed.
    @Test func yesNeverDecidesARequestSwappedInUnderTheSamePrefix() async throws {
        let decoy = "5e5e5e5e-0000-4000-8000-0000000000c1", swapped = "5e5e5e5e-9999-4000-8000-0000000000d2"
        let readerItem = Self.inboxItem(name: decoy, roleGUID: "acdd72a7-3385-48ef-bd42-f606fba81ae7", roleName: "Reader", scopeName: "Dummy Sandbox")
        let ownerItem = Self.inboxItem(name: swapped, roleGUID: EligibleRole.ownerRoleGUID, roleName: "Owner", scopeName: "Dummy Production")
        let listing = TestBox<[[String: Any]]>([readerItem])
        func harness(answers: [String] = []) -> CLIHarness {
            let h = CLIHarness(answers: answers)
            h.get = { request in
                guard request.url!.absoluteString.contains("asApprover()") else { return nil }
                return (try JSONSerialization.data(withJSONObject: ["value": listing.value ?? []]), 200)
            }
            return h
        }

        // The approver reviews the decoy: the whole id is listed.
        let review = harness()
        #expect(await review.run("approvals") == 0)
        #expect(review.out.contains(decoy) && review.out.contains("Reader"))

        // The requester swaps it for an Owner request under the same prefix.
        listing.value = [ownerItem]
        for prefix in ["5e5e5e5e", "5e5e"] {
            for verb in ["approve", "deny"] {
                let h = harness()
                #expect(await h.run(verb, prefix, "-j", "ok", "--yes") == 2)
                #expect(h.err.contains("takes only full request ids"))
                #expect(await h.transport.requests.filter { $0.httpMethod == "PATCH" }.isEmpty)
            }
        }
        // The whole reviewed id no longer matches anything: nothing is sent.
        let exact = harness()
        #expect(await exact.run("approve", decoy, "-j", "ok", "--yes") == 1)
        #expect(exact.out.contains("not found  \(decoy)"))
        #expect(await exact.transport.requests.filter { $0.httpMethod == "PATCH" }.isEmpty)

        // On a terminal a prefix still works, and the prompt shows the whole id it matched.
        let asked = harness(answers: ["n"])
        asked.stdinIsTTY = true
        #expect(await asked.run("approve", "5e5e5e5e", "-j", "ok") == 1)
        #expect(asked.out.contains(swapped) && asked.out.contains("Owner (!)"))
        #expect(asked.err.contains("Approve 1 request, including 1 Owner? [y/N]"))
        #expect(await asked.transport.requests.filter { $0.httpMethod == "PATCH" }.isEmpty)

        // Control: the swapped request's own whole id decides it.
        let control = harness()
        #expect(await control.run("approve", swapped, "-j", "ok", "--yes") == 0)
        let patches = await control.transport.requests.filter { $0.httpMethod == "PATCH" }
        #expect(patches.count == 1 && patches[0].url!.absoluteString.contains("roleAssignmentApprovals/\(swapped)/stages/"))
    }

    /// Roles that can grant access to others get the same warning as Owner.
    @Test func approvingAccessAdministratorRolesWarnsAndAsks() async throws {
        let uaa = Self.inboxItem(name: "7e7e7e7e-0000-4000-8000-0000000000a1", roleGUID: AccessGrantingRole.userAccessAdministratorGUID,
                                 roleName: "User Access Administrator", scopeName: "Dummy Production")
        let rbac = Self.inboxItem(name: "7e7e7e7e-1111-4000-8000-0000000000a2", roleGUID: AccessGrantingRole.rbacAdministratorGUID,
                                  roleName: "Role Based Access Control Administrator", scopeName: "Dummy Staging")
        let owner = Self.inboxItem(name: "7e7e7e7e-2222-4000-8000-0000000000a3", roleGUID: EligibleRole.ownerRoleGUID,
                                   roleName: "Owner", scopeName: "Dummy Sandbox")
        let reader = Self.inboxItem(name: "7e7e7e7e-3333-4000-8000-0000000000a4", roleGUID: "acdd72a7-3385-48ef-bd42-f606fba81ae7",
                                    roleName: "Reader", scopeName: "Dummy Sandbox")
        let listing = try JSONSerialization.data(withJSONObject: ["value": [uaa, rbac, owner, reader]])
        let h = CLIHarness(answers: ["n"])
        h.stdinIsTTY = true
        h.get = { request in request.url!.absoluteString.contains("asApprover()") ? (listing, 200) : nil }
        #expect(await h.run("approve", "7e7e7e7e-0", "7e7e7e7e-1", "7e7e7e7e-2", "7e7e7e7e-3", "-j", "ok") == 1)
        #expect(h.out.contains("User Access Administrator (!)"))
        #expect(h.out.contains("Role Based Access Control Administrator (!)"))
        #expect(!h.out.contains("Reader (!)"))
        #expect(h.out.contains("Warning: 1 Owner role (!)"))
        #expect(h.out.contains("Warning: 2 access administrator roles (!): can grant anyone any role on the resource, Owner included."))
        #expect(h.err.contains("Approve 4 requests, including 1 Owner and 2 access administrators? [y/N]"))
        #expect(await h.transport.requests.filter { $0.httpMethod == "PATCH" }.isEmpty)

        let one = CLIHarness(answers: ["n"])
        one.stdinIsTTY = true
        one.get = h.get
        #expect(await one.run("approve", "7e7e7e7e-0", "-j", "ok") == 1)
        #expect(one.err.contains("Approve 1 request, including 1 access administrator? [y/N]"))
        #expect(!one.out.contains("Owner role"))
    }

    @Test func dryRunAsksNothingAndSendsNothing() async {
        let h = CLIHarness()
        #expect(await h.run("deny", "a1a1a1a1", "-j", "use staging", "--dry-run") == 0)
        #expect(await h.transport.requests.allSatisfy { $0.httpMethod == "GET" })
        #expect(h.out.contains("Would deny 1 request"))
        #expect(h.out.contains("PATCH https://management.azure.com/providers/Microsoft.Authorization/roleAssignmentApprovals/a1a1a1a1-0000-4000-8000-000000000011/stages/5a5a5a5a-0000-4000-8000-000000000021?api-version=2021-01-01-preview"))
        #expect(h.out.contains("\"reviewResult\" : \"Deny\""))
        #expect(h.out.contains("The requesters do not get the roles"))
    }

    @Test func safetyRules() async {
        let script = CLIHarness()
        #expect(await script.run("approve", "a1a1", "-j", "x") == 2)
        #expect(script.err.contains("Refusing to approve without confirmation"))
        #expect(await script.transport.requests.isEmpty)

        let no = CLIHarness(answers: ["n"])
        no.stdinIsTTY = true
        #expect(await no.run("approve", "b2b2", "-j", "x") == 1)
        #expect(no.err.contains("Approve 1 request, including 1 Owner? [y/N]"))
        #expect(await no.transport.requests.allSatisfy { $0.httpMethod == "GET" })

        let yes = CLIHarness(answers: ["y"])
        yes.stdinIsTTY = true
        #expect(await yes.run("deny", "b2b2", "-j", "not during the freeze") == 0)
        #expect(yes.err.contains("Deny 1 request? [y/N]"))
        #expect(await yes.transport.requests.filter { $0.httpMethod == "PATCH" }.count == 1)
    }

    @Test func unknownDecidedAndRefused() async {
        let unknown = CLIHarness()
        #expect(await unknown.run("deny", "deadbeef-0000-4000-8000-000000000000", "-j", "x", "--yes") == 1)
        #expect(unknown.out.contains("not found  deadbeef-0000-4000-8000-000000000000"))
        #expect(unknown.err.contains("No request matches"))

        let gone = CLIHarness()
        gone.patch = { _ in (Data(#"{"Message":"Exception of type 'RecordNotFoundException' was thrown."}"#.utf8), 404) }
        #expect(await gone.run("approve", "a1a1a1a1-0000-4000-8000-000000000011", "-j", "x", "--yes") == 1)
        #expect(gone.out.contains("skipped    Contributor · Contoso Staging for Megan Bowen: Not pending any more"))

        let refused = CLIHarness()
        refused.patch = { _ in (Data(#"{"error":{"code":"ExpiredAuthenticationToken","message":"expired"}}"#.utf8), 401) }
        #expect(await refused.run("approve", "a1a1a1a1-0000-4000-8000-000000000011", "-j", "x", "--yes") == 3)
        #expect(refused.err.contains("hint: sign in with"))

        let empty = CLIHarness()
        empty.get = { request in request.url!.absoluteString.contains("asApprover()") ? (Data(#"{"value":[]}"#.utf8), 200) : nil }
        #expect(await empty.run("approve", "a1a1a1a1-0000-4000-8000-000000000011", "-j", "x", "--yes") == 1)
        #expect(empty.err.contains("You have no approvals to review."))
    }
}

@Suite("CLI: text from others is shown, not obeyed by the terminal")
struct CLITerminalSafetyTests {
    /// Raw characters that must never reach the terminal from someone else's text.
    static let raw: [Character] = ["\r", "\u{1B}", "\u{07}", "\u{9B}", "\u{202E}", "\u{2066}", "\u{200F}", "\u{7F}"]

    /// No raw character from `raw`, once Pimento's own colour codes are taken out.
    static func clean(_ text: String) -> Bool {
        var text = text
        for code in ["0", "1", "2", "31", "32", "33", "1;31"] { text = text.replacingOccurrences(of: "\u{1B}[\(code)m", with: "") }
        // CR is checked by scalar: "\r\n" is one Character.
        return !text.unicodeScalars.contains { s in raw.contains { $0.unicodeScalars.first == s } }
    }

    @Test func sanitiserEscapesControlsEscapesAndBidi() {
        #expect(TerminalText.sanitize("plain · text ✓") == "plain · text ✓")
        #expect(TerminalText.sanitize("a\rb") == "a\\rb")
        #expect(TerminalText.sanitize("a\r\nb\tc") == "a\\r\\nb\\tc")
        #expect(TerminalText.sanitize("\u{1B}]52;c;ZXZpbA==\u{07}") == "\\e]52;c;ZXZpbA==\\a")
        #expect(TerminalText.sanitize("x\u{9B}31my\u{7F}") == "x\\u{9B}31my\\u{7F}")
        #expect(TerminalText.sanitize("evil\u{202E}txt.exe\u{2066}\u{200E}") == "evil\\u{202E}txt.exe\\u{2066}\\u{200E}")
        // Output keeps line breaks, tabs and (only when colours are on) Pimento's own colour codes.
        let ours = TerminalStyle(colors: true).red("failed") + "\tline\n"
        #expect(TerminalText.output(ours, keepStyles: true) == ours)
        #expect(TerminalText.output(ours, keepStyles: false) == "\\e[31mfailed\\e[0m\tline\n")
        // Anything else that starts with ESC is escaped, colours on or not.
        #expect(TerminalText.output("\u{1B}[8mhidden\u{1B}[2K\r", keepStyles: true) == "\\e[8mhidden\\e[2K\\r")
        #expect(TerminalText.output("\u{1B}]8;;https://evil.example\u{1B}\\link", keepStyles: true) == "\\e]8;;https://evil.example\\e\\link")
        // JSON: the same values, written as escapes.
        let json = CLIJSON.encode(["name": "a\u{202E}b\u{85}c\u{1B}d"])
        #expect(Self.clean(json) && !json.contains("\u{85}"))
        #expect(json.contains(#"a\u202eb\u0085c\u001bd"#) || json.contains(#"a\u202eb\u0085c\u001Bd"#))
        let decoded = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: String]
        #expect(decoded?["name"] == "a\u{202E}b\u{85}c\u{1B}d")
    }

    /// The report's case: a justification that starts with CR and repeats a
    /// harmless row. On a terminal it would overwrite the real row (User
    /// Access Administrator on production) just before `[y/N]`.
    @Test func aCarriageReturnCannotOverwriteTheRowBeforeThePrompt() async throws {
        let name = "f6f6f6f6-0000-4000-8000-000000000016"
        var item = CLIApproverTests.inboxItem(name: name, roleGUID: "18d7d88d-d35e-4fb5-a5c3-7773c20a72d9",
                                              roleName: "User Access Administrator", scopeName: "Contoso Production")
        var props = try #require(item["properties"] as? [String: Any])
        props["justification"] = "\r\(name.prefix(8))  Dummy Requester  Reader  Contoso Sandbox  8 h  read-only audit.\u{1B}[8m"
        props["ticketInfo"] = ["ticketNumber": "T\u{1B}]52;c;ZXZpbA==\u{07}", "ticketSystem": "\u{1B}]8;;https://evil.example\u{1B}\\x"]
        item["properties"] = props
        let listing = try JSONSerialization.data(withJSONObject: ["value": [item]])
        for colours in [false, true] {
            let h = CLIHarness(answers: ["n"])
            h.stdinIsTTY = true
            h.stdoutIsTTY = colours
            h.width = 400
            h.get = { request in request.url!.absoluteString.contains("asApprover()") ? (listing, 200) : nil }
            #expect(await h.run("approve", "f6f6", "-j", "ok") == 1)
            #expect(Self.clean(h.out) && Self.clean(h.err))
            #expect(!h.out.contains("\u{1B}[8m") && !h.out.contains("\u{1B}]"))
            #expect(h.out.contains("User Access Administrator") && h.out.contains("Contoso Production"))
            #expect(h.out.contains("\\rf6f6f6f6  Dummy Requester  Reader"))
            #expect(h.err.contains("Approve 1 request, including 1 access administrator? [y/N]"))
            #expect(await h.transport.requests.filter { $0.httpMethod == "PATCH" }.isEmpty)

            let list = CLIHarness()
            list.stdoutIsTTY = colours
            list.get = h.get
            #expect(await list.run("approvals") == 0)
            #expect(Self.clean(list.out) && Self.clean(list.err))
            #expect(list.out.contains("\\e]52;c;ZXZpbA==\\a"))
        }
        // --json keeps the exact values, escaped as JSON.
        let json = CLIHarness()
        json.get = { request in request.url!.absoluteString.contains("asApprover()") ? (listing, 200) : nil }
        #expect(await json.run("approvals", "--json") == 0)
        #expect(Self.clean(json.out))
        let doc = try #require(try JSONSerialization.jsonObject(with: Data(json.out.utf8)) as? [String: Any])
        let request = try #require((doc["requests"] as? [[String: Any]])?.first)
        #expect((request["justification"] as? String)?.hasPrefix("\r") == true)
    }

    /// Names and messages interpolated into result lines and errors.
    @Test func errorMessagesAndNamesInResultLinesAreEscaped() async throws {
        let h = CLIHarness(put: { _ in
            (Data(#"{"error":{"code":"RoleAssignmentRequestPolicyValidationFailed","message":"bad\r\u001b[2Kfine \u202Etxt"}}"#.utf8), 400)
        })
        h.stdoutIsTTY = true
        #expect(await h.run("activate", "staging", "-j", "x", "--yes") == 1)
        #expect(Self.clean(h.out) && Self.clean(h.err))
        #expect((h.out + h.err).contains("bad\\r\\e[2Kfine \\u{202E}txt"))
    }
}
