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
        #expect(await approve.run("approve", "a1a1", "b2b2", "-j", "matches the change", "--yes") == 0)
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
