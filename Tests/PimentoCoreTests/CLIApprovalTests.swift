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
        #expect(await h.run("approve", "a1a1", "b2b2", "-j", "matches the change", "--yes", "--json") == 0)
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
        #expect(await unknown.run("deny", "deadbeef", "-j", "x", "--yes") == 1)
        #expect(unknown.out.contains("not found  deadbeef"))
        #expect(unknown.err.contains("No request matches"))

        let gone = CLIHarness()
        gone.patch = { _ in (Data(#"{"Message":"Exception of type 'RecordNotFoundException' was thrown."}"#.utf8), 404) }
        #expect(await gone.run("approve", "a1a1", "-j", "x", "--yes") == 1)
        #expect(gone.out.contains("skipped    Contributor · Contoso Staging for Megan Bowen: Not pending any more"))

        let refused = CLIHarness()
        refused.patch = { _ in (Data(#"{"error":{"code":"ExpiredAuthenticationToken","message":"expired"}}"#.utf8), 401) }
        #expect(await refused.run("approve", "a1a1", "-j", "x", "--yes") == 3)
        #expect(refused.err.contains("hint: sign in with"))

        let empty = CLIHarness()
        empty.get = { request in request.url!.absoluteString.contains("asApprover()") ? (Data(#"{"value":[]}"#.utf8), 200) : nil }
        #expect(await empty.run("approve", "a1a1", "-j", "x", "--yes") == 1)
        #expect(empty.err.contains("You have no approvals to review."))
    }
}
