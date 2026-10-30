import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import PimentoCore

@Suite("CLI: writes are recorded")
struct CLIHistoryRecordingTests {
    @Test func activateRecordsOnePerRoleAndDryRunsNothing() async {
        let dry = CLIHarness()
        #expect(await dry.run("activate", "--all", "-j", "INC-42", "--hours", "2", "--dry-run") == 0)
        #expect(dry.historyStore.load().records.isEmpty)

        let h = CLIHarness()
        #expect(await h.run("activate", "--role", "Reader", "-j", "INC-42", "--hours", "4", "--yes") == 0)
        let records = h.historyStore.load().records
        #expect(records.count == 1)
        let r = records[0]
        #expect(r.action == .activate && r.result == .succeeded && r.source == .cli && r.version == AppInfo.version)
        #expect(r.roleName == "Reader" && r.scopeName == "Contoso Production" && r.justification == "INC-42")
        #expect(r.requestedDuration == "PT4H" && r.durationMinutes == 240)
        #expect(r.requestId == (await h.puts)[0].url!.lastPathComponent)
        #expect(r.at == Fixture.now)
    }

    @Test func everyWriteCommandRecordsItsRequests() async throws {
        let off = CLIHarness(put: lifecyclePUT)
        #expect(await off.run("deactivate", "rg-app-dev", "--yes") == 0)
        #expect(off.historyStore.load().records.map(\.action) == [.deactivate])

        let renew = CLIHarness(put: lifecyclePUT)
        renew.policy = noApprovalPolicy
        #expect(await renew.run("renew", "rg-app-dev", "-j", "still deploying", "--hours", "3", "--yes") == 0)
        let renewed = renew.historyStore.load().records
        #expect(renewed.map(\.action) == [.renew])
        #expect(renewed[0].durationMinutes == 120 && renewed[0].requestedDuration == "PT3H")

        let ext = CLIHarness(put: lifecyclePUT)
        #expect(await ext.run("extend", "fabrikam", "-j", "project runs longer", "--days", "7", "--yes") == 0)
        #expect(ext.historyStore.load().records.map(\.action) == [.extend])

        let cancel = CLIHarness()
        #expect(await cancel.run("cancel", "5f0c1d2e", "--yes") == 0)
        #expect(cancel.historyStore.load().records.map(\.action) == [.cancel])
        #expect(cancel.historyStore.load().records[0].requestId == "5f0c1d2e-0000-4000-8000-000000000001")

        let approve = CLIHarness()
        #expect(await approve.run("approve", "a1a1a1a1-0000-4000-8000-000000000011", "b2b2b2b2-0000-4000-8000-000000000012",
                                  "-j", "matches the change", "--yes") == 0)
        let decided = approve.historyStore.load().records
        #expect(decided.map(\.action) == [.approve, .approve])
        #expect(decided.allSatisfy { $0.justification == "matches the change" && $0.requester != nil })

        let dryDeny = CLIHarness()
        #expect(await dryDeny.run("deny", "a1a1a1a1", "-j", "use staging", "--dry-run") == 0)
        #expect(dryDeny.historyStore.load().records.isEmpty)
    }

    @Test func historyOffRecordsNothing() async throws {
        let h = CLIHarness()
        try h.historyStore.saveSettings(HistorySettings(enabled: false))
        #expect(await h.run("activate", "--role", "Reader", "-j", "INC-42", "--yes") == 0)
        #expect(h.historyStore.load().records.isEmpty)
    }
}

@Suite("CLI: history parsing")
struct CLIHistoryParserTests {
    func command(_ args: String...) throws -> CLICommand { try CLIParser.parse(args).command }

    @Test func listCollectsFilters() throws {
        guard case .history(.list(let o)) = try command(
            "history", "contoso", "deploy", "--since", "7d", "--until", "today", "--action", "activate,renew", "--action", "approve",
            "--outcome", "failed", "-t", "Contoso", "-n", "20", "--json")
        else { Issue.record("expected history list"); return }
        #expect(o.text == ["contoso", "deploy"])
        #expect(o.since == "7d" && o.until == "today")
        #expect(o.actions == [.activate, .renew, .approve])
        #expect(o.results == [.failed])
        #expect(o.tenant == "Contoso" && o.limit == 20 && o.json && !o.csv)
        guard case .history(.list(let plain)) = try command("history") else { Issue.record("expected history list"); return }
        #expect(plain == HistoryListOptions())
    }

    @Test func subcommands() throws {
        guard case .history(.export(let file, let o)) = try command("history", "export", "out.csv", "--since", "30d")
        else { Issue.record("expected export"); return }
        #expect(file == "out.csv" && o.since == "30d")
        guard case .history(.export(let dash, _)) = try command("history", "export", "-") else { Issue.record("expected export"); return }
        #expect(dash == "-")
        guard case .history(.importAzure(let i)) = try command("history", "import-azure", "--since", "30d", "--tenant", "contoso.onmicrosoft.com", "--json")
        else { Issue.record("expected import"); return }
        #expect(i.since == "30d" && i.tenant == "contoso.onmicrosoft.com" && i.json)
        #expect(try command("history", "clear") == .history(.clear(assumeYes: false)))
        #expect(try command("history", "clear", "-y") == .history(.clear(assumeYes: true)))
        #expect(try command("history", "--help") == .help(topic: "history"))
        #expect(try command("history", "export", "--help") == .help(topic: "history"))
    }

    @Test func usageErrors() {
        #expect(throws: CLIParseError.unknownAction("teleport")) { try command("history", "--action", "teleport") }
        #expect(throws: CLIParseError.unknownOutcome("great")) { try command("history", "--outcome", "great") }
        #expect(throws: CLIParseError.conflicting("--json", "--csv")) { try command("history", "--json", "--csv") }
        #expect(throws: CLIParseError.missingExportFile) { try command("history", "export") }
        #expect(throws: CLIParseError.conflicting("export", "--csv")) { try command("history", "export", "x.csv", "--csv") }
        #expect(throws: CLIParseError.unexpectedArgument("b.csv", command: "history export")) { try command("history", "export", "a.csv", "b.csv") }
        #expect(throws: CLIParseError.outOfRange(flag: "--limit", value: 0, range: 1...1_000_000)) { try command("history", "--limit", "0") }
        #expect(throws: CLIParseError.unknownOption("--dry-run", command: "history clear")) { try command("history", "clear", "--dry-run") }
        #expect(throws: CLIParseError.unexpectedArgument("x", command: "history import-azure")) { try command("history", "import-azure", "x") }
    }

    @Test func helpAndCompletionsKnowTheCommand() {
        #expect(CLIHelp.text(for: nil).contains("history"))
        let help = CLIHelp.text(for: "history")
        for word in ["import-azure", "export", "clear", "--since", "--outcome", "PIMENTO_HISTORY", "RFC 4180"] {
            #expect(help.contains(word), "\(word)")
        }
        for shell in CompletionShell.allCases {
            let script = CLIHelp.completionScript(for: shell)
            // Each word on its own: `a && b || c` passed as soon as "outcome" appeared.
            for word in ["history", "import-azure", "export", "outcome"] {
                #expect(script.contains(word), "\(shell) completion: \(word)")
            }
        }
    }
}

@Suite("CLI: history commands")
struct CLIHistoryCommandTests {
    static let tenantA = "00000000-0000-4000-8000-0000000000aa"

    func seeded() throws -> CLIHarness {
        let h = CLIHarness()
        let day: TimeInterval = 86400
        try h.historyStore.append([
            .sample(1, at: Fixture.now.addingTimeInterval(-3600), action: .activate, tenantLabel: "Contoso", justification: "deploy, release 2.4"),
            .sample(2, at: Fixture.now.addingTimeInterval(-2 * day), action: .deactivate, result: .failed, role: "Reader"),
            .sample(3, at: Fixture.now.addingTimeInterval(-20 * day), action: .approve, tenantId: "00000000-0000-4000-8000-0000000000bb",
                    tenantLabel: "Fabrikam", justification: "=cmd"),
            .sample(4, at: Fixture.now.addingTimeInterval(-500 * day), action: .renew),
        ])
        return h
    }

    @Test func listsNewestFirstWithinTheRetention() async throws {
        let h = try seeded()
        #expect(await h.run("history") == 0)
        let lines = h.out.split(separator: "\n").map(String.init)
        #expect(lines.count == 4, "header + 3; the 500-day-old record is beyond the default retention")
        #expect(lines[0].hasPrefix("WHEN") && lines[0].contains("TENANT") && lines[0].contains("REQUEST"))
        #expect(lines[1].contains("11:00 (1h ago)") && lines[1].contains("activate") && lines[1].contains("succeeded"))
        #expect(lines[2].contains("deactivate") && lines[2].contains("failed") && lines[2].contains("Contoso"), "tenant name filled in")
        #expect(lines[3].contains("approve") && lines[3].contains("Fabrikam") && lines[3].contains("(2w ago)"))
        #expect(!h.out.contains("\u{1B}["))
    }

    @Test func filtersLimitAndEmpty() async throws {
        let h = try seeded()
        #expect(await h.run("history", "--since", "7d", "--action", "deactivate") == 0)
        #expect(h.out.split(separator: "\n").count == 2 && h.out.contains("Reader"))

        let t = try seeded()
        #expect(await t.run("history", "--tenant", "fabrikam") == 0)
        #expect(t.out.split(separator: "\n").count == 2 && t.out.contains("approve"))

        let w = try seeded()
        #expect(await w.run("history", "release", "2.4") == 0)
        #expect(w.out.split(separator: "\n").count == 2)

        let l = try seeded()
        #expect(await l.run("history", "-n", "1") == 0)
        #expect(l.out.split(separator: "\n").count == 2)
        #expect(l.err.contains("Showing the newest 1 of 3"))

        let none = try seeded()
        #expect(await none.run("history", "--outcome", "denied") == 0)
        #expect(none.out.isEmpty && none.err.contains("No history entries match"))

        let empty = CLIHarness()
        #expect(await empty.run("history") == 0)
        #expect(empty.err.contains("No history yet"))

        // A day as --until includes that day (record 1 is from today, 11:00 UTC).
        let today = try seeded()
        #expect(await today.run("history", "--since", "2026-10-29", "--until", "2026-10-29") == 0)
        #expect(today.out.split(separator: "\n").count == 2 && today.out.contains("activate"))
        let untilToday = try seeded()
        #expect(await untilToday.run("history", "--until", "today") == 0)
        #expect(untilToday.out.split(separator: "\n").count == 4)

        let bad = try seeded()
        #expect(await bad.run("history", "--since", "last tuesday") == 2)
        #expect(bad.err.contains("--since takes 7d"))
    }

    @Test func jsonAndCSV() async throws {
        let j = try seeded()
        #expect(await j.run("history", "--json", "--since", "7d") == 0)
        let doc = try #require(try JSONSerialization.jsonObject(with: Data(j.out.utf8)) as? [String: Any])
        #expect(doc["total"] as? Int == 2)
        #expect(doc["file"] as? String == j.historyStore.url.path)
        let records = try #require(doc["records"] as? [[String: Any]])
        #expect(records.map { $0["id"] as? String } == ["rec-1", "rec-2"])
        #expect(records[0]["at"] as? String == "2026-10-29T11:00:00.000Z")
        #expect(records[1]["tenantLabel"] as? String == "Contoso")

        let c = try seeded()
        #expect(await c.run("history", "--csv") == 0)
        #expect(c.out.hasPrefix("\"timestamp_utc\",\"local_time\",\"action\","))
        #expect(c.out.hasSuffix("\r\n"))
        #expect(c.out.components(separatedBy: "\r\n").count == 5)
        #expect(c.out.contains(",\"'=cmd\","))
        #expect(c.out.contains("\"deploy, release 2.4\""))
    }

    @Test func exportWritesAFile() async throws {
        let h = try seeded()
        let file = h.historyStore.url.deletingLastPathComponent().appendingPathComponent("export.csv")
        #expect(await h.run("history", "export", file.path, "--action", "approve") == 0)
        #expect(h.err.contains("Exported 1 record to \(file.path)"))
        let text = try String(contentsOf: file, encoding: .utf8)
        #expect(text.components(separatedBy: "\r\n").count == 3)
        #expect(text.contains(",\"approve\",") && text.contains(",\"'=cmd\","))
        #expect(hasMode(file.path, 0o600))

        let stdout = try seeded()
        #expect(await stdout.run("history", "export", "-") == 0)
        #expect(stdout.out.hasPrefix("\"timestamp_utc\","))

        // Under a regular file: unwritable on every platform (`/dev/null/…`
        // is an ordinary, creatable path on Windows).
        let nowhere = try seeded()
        #expect(await nowhere.run("history", "export", file.appendingPathComponent("x.csv").path) == 1)
        #expect(nowhere.err.contains("Could not write"))
    }

    @Test func importFromAzureMergesOnlyNewRequests() async throws {
        let h = CLIHarness()
        h.get = { request in
            request.url!.absoluteString.contains("roleAssignmentScheduleRequests?") && request.url!.absoluteString.contains("asTarget()")
                ? (try Fixture.data("history-requests"), 200) : nil
        }
        try h.historyStore.append([.sample(1, requestId: "1a1a1a1a-0000-4000-8000-000000000001")])
        try h.historyStore.saveSettings(HistorySettings(retention: .days30))
        #expect(await h.run("history", "import-azure") == 0)
        // 5 of yours; one Pimento already has; one older than the retention.
        #expect(h.err.contains("Read 5 requests from Azure: 3 added, 1 already in the history, 1 older than the retention (30 days)."))
        #expect(await h.transport.requests.allSatisfy { $0.httpMethod == "GET" })
        let azure = h.historyStore.load().records.filter { $0.source == .azure }
        #expect(azure.count == 3)

        let again = CLIHarness()
        again.get = h.get
        try again.historyStore.append(h.historyStore.load().records)
        #expect(await again.run("history", "import-azure", "--since", "2026-10-28", "--json") == 0)
        let doc = try #require(try JSONSerialization.jsonObject(with: Data(again.out.utf8)) as? [String: Any])
        #expect(doc["read"] as? Int == 3 && doc["added"] as? Int == 0 && doc["known"] as? Int == 3)

        let denied = CLIHarness()
        denied.tokens = FailingTokens()
        #expect(await denied.run("history", "import-azure") == 3)
    }

    @Test func clearAsksOrNeedsYes() async throws {
        let script = try seeded()
        #expect(await script.run("history", "clear") == 2)
        #expect(script.err.contains("Add --yes"))
        #expect(script.historyStore.load().records.count == 4)

        let noAnswer = CLIHarness(answers: ["n"])
        noAnswer.stdinIsTTY = true
        try noAnswer.historyStore.append(try seeded().historyStore.load().records)
        #expect(await noAnswer.run("history", "clear") == 1)
        #expect(noAnswer.err.contains("Delete all 4 history records"))
        #expect(noAnswer.historyStore.load().records.count == 4)

        let yes = try seeded()
        #expect(await yes.run("history", "clear", "--yes") == 0)
        #expect(yes.err.contains("Deleted 4 history records."))
        #expect(yes.historyStore.load().records.isEmpty)
    }
}
