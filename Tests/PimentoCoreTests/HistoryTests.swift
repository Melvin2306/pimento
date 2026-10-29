import Foundation
import Testing
@testable import PimentoCore

/// A fresh history file path in the temporary directory.
func temporaryHistoryURL() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("pimento-tests-\(UUID().uuidString)", isDirectory: true)
        .appendingPathComponent("history.jsonl")
}

extension HistoryRecord {
    static func sample(
        _ n: Int = 0, at: Date = Fixture.now, action: HistoryAction = .activate, result: HistoryResult = .succeeded,
        tenantId: String? = "00000000-0000-4000-8000-0000000000aa", tenantLabel: String? = nil, role: String = "Owner",
        scopeName: String = "Contoso Production", justification: String? = "deploy", requestId: String? = nil,
        source: HistorySource = .cli
    ) -> HistoryRecord {
        HistoryRecord(
            id: "rec-\(n)", at: at, action: action, result: result, status: result == .succeeded ? "Provisioned" : "Failed",
            tenantId: tenantId, tenantLabel: tenantLabel, scope: "/subscriptions/aaaaaaaa-0000-0000-0000-00000000000a",
            scopeName: scopeName, scopeType: "subscription", roleName: role,
            roleDefinitionId: "/providers/Microsoft.Authorization/roleDefinitions/8e3af657-a8ff-443c-a75c-2fe8c4bcb635",
            requestedDuration: "PT8H", durationMinutes: 480, start: at, end: at.addingTimeInterval(8 * 3600),
            justification: justification, requestId: requestId ?? String(format: "%08x-0000-4000-8000-000000000000", n),
            source: source, version: "0.1.0")
    }
}

@Suite("History records")
struct HistoryRecordTests {
    @Test func roundTripsAsOneJSONLine() throws {
        var r = HistoryRecord.sample(1)
        r.justification = "line one\nline two \"quoted\""
        r.ticketNumber = "CHG-1001"
        r.ticketSystem = "ServiceNow"
        let line = try r.jsonLine()
        #expect(!line.contains(0x0A))
        let text = String(decoding: line, as: UTF8.self)
        #expect(text.contains(#""at":"2026-10-29T12:00:00.000Z""#))
        #expect(text.contains(#""v":1"#))
        #expect(text.contains(#""source":"cli""#))
        #expect(!text.contains("message"), "nil fields are left out")
        let back = try JSONDecoder().decode(HistoryRecord.self, from: line)
        #expect(back == r)
    }

    @Test func decodingIsLenient() throws {
        let line = #"""
        {"v":7,"at":"2026-10-29T12:00:00Z","action":"teleport","result":"warp","scope":"/subscriptions/x","durationMinutes":"lots",
         "futureField":{"nested":true},"start":"not a date","id":"abc","source":"robot"}
        """#
        let r = try JSONDecoder().decode(HistoryRecord.self, from: Data(line.utf8))
        #expect(r.action.rawValue == "teleport" && r.action.title == "Teleport")
        #expect(r.result.rawValue == "warp")
        #expect(r.durationMinutes == nil && r.start == nil)
        #expect(r.source.rawValue == "robot")
        #expect(r.id == "abc")

        // Missing the essentials: not a record.
        #expect(throws: (any Error).self) { try JSONDecoder().decode(HistoryRecord.self, from: Data(#"{"action":"activate"}"#.utf8)) }
        #expect(throws: (any Error).self) { try JSONDecoder().decode(HistoryRecord.self, from: Data(#"{"at":"2026-10-29T12:00:00Z"}"#.utf8)) }
    }

    @Test func fromAnActivationPlan() throws {
        let role = try Fixture.role("Contoso Staging", "Contributor")
        let plans = try ActivationRequestBuilder.plan(
            [role], principalId: Fixture.userOID, justification: "release", now: Fixture.now,
            ticket: TicketInfo(number: "CHG-1", system: "Jira")
        ) { _ in EffectiveDuration(minutes: 240, requested: .hours(8), policyMaxMinutes: 240) }
        let context = HistoryContext(tenantId: "t-1", tenantLabel: "Contoso", source: .app, at: Fixture.now)
        let until = Fixture.now.addingTimeInterval(4 * 3600)
        let r = HistoryRecord(plan: plans[0], outcome: .activated(status: "Provisioned", until: until), context: context)
        #expect(r.action == .activate && r.result == .succeeded && r.status == "Provisioned")
        #expect(r.requestedDuration == "PT8H" && r.durationMinutes == 240)
        #expect(r.start == Fixture.now && r.end == until)
        #expect(r.justification == "release" && r.ticketNumber == "CHG-1" && r.ticketSystem == "Jira")
        #expect(r.requestId == plans[0].requestId)
        #expect(r.tenantLabel == "Contoso" && r.source == .app && r.version == AppInfo.version)
        #expect(r.roleName == "Contributor" && r.scopeName == "Contoso Staging")

        let pending = HistoryRecord(plan: plans[0], outcome: .activated(status: "PendingApproval", until: nil), context: context)
        #expect(pending.result == .pending && pending.status == "PendingApproval")
        let failed = HistoryRecord(plan: plans[0], outcome: .failed(code: "AuthorizationFailed", message: "no\naccess"), context: context)
        #expect(failed.result == .failed && failed.status == "AuthorizationFailed" && failed.message == "no access")
        let policy = HistoryRecord(plan: plans[0], outcome: .policyViolation(rules: ["ExpirationRule"], message: "x"), context: context)
        #expect(policy.message == "duration exceeds the role's maximum activation time")
        let exists = HistoryRecord(plan: plans[0], outcome: .alreadyActive, context: context)
        #expect(exists.result == .skipped)
    }

    @Test func messagesAreShortAndNeverABody() {
        #expect(HistoryRecord.shortMessage(#"{"error":{"code":"x"}}"#) == nil)
        #expect(HistoryRecord.shortMessage("<html><body>Bad gateway</body></html>") == nil)
        let long = String(repeating: "a", count: 1000)
        #expect(HistoryRecord.shortMessage(long)?.count == HistoryRecord.maxMessageLength)
        #expect(HistoryRecord.shortMessage("  \n ") == nil)
    }

    @Test func scheduledDeactivationAndExtension() throws {
        let context = HistoryContext(tenantId: nil, source: .cli, at: Fixture.now)
        let start = Fixture.now.addingTimeInterval(86400)
        let role = try Fixture.role("Contoso Staging", "Contributor")
        let scheduled = try ActivationRequestBuilder.plan([role], principalId: Fixture.userOID, justification: "later", now: Fixture.now, start: start) { _ in
            EffectiveDuration(minutes: 60, requested: .hours(1), policyMaxMinutes: nil)
        }
        let s = HistoryRecord(plan: scheduled[0], outcome: .scheduled(status: "Granted", start: start, until: start.addingTimeInterval(3600)), context: context)
        #expect(s.action == .schedule && s.result == .succeeded && s.start == start)

        let active = try Fixture.role("Contoso Production", "Owner")
        let off = try ActivationRequestBuilder.deactivationPlan([active], principalId: Fixture.userOID)
        let d = HistoryRecord(plan: off[0], outcome: .deactivated(status: "Revoked"), context: context)
        #expect(d.action == .deactivate && d.result == .succeeded && d.durationMinutes == nil && d.requestedDuration == nil)
        #expect(HistoryRecord(plan: off[0], outcome: .notActive, context: context).result == .skipped)
        #expect(HistoryRecord(plan: off[0], outcome: .tooSoon(possibleAt: nil), context: context).result == .failed)

        let assignment = ActiveAssignment(
            id: "a", scheduleId: "/x/roleAssignmentSchedules/s1", roleDefinitionId: active.roleDefinitionId, roleName: "Owner",
            scope: active.scope, scopeName: active.scopeName, scopeType: active.scopeType, start: Fixture.now, end: Fixture.now.addingTimeInterval(86400))
        let ext = try ActivationRequestBuilder.extensionPlan([assignment], principalId: Fixture.userOID, justification: "project", days: 30)
        let e = HistoryRecord(plan: ext[0], outcome: .activated(status: "PendingAdminDecision", until: nil), context: context)
        #expect(e.action == .extend && e.result == .pending && e.requestedDuration == "P30D" && e.durationText == "30 days")
    }
}

@Suite("History file")
struct HistoryStoreTests {
    @Test func locationAndEnvironmentOverride() {
        let home = "/Users/someone"
        #expect(HistoryStore.location(environment: [:], home: home, platform: .macOS).path
            == filePath("/Users/someone/Library/Application Support/Pimento/history.jsonl"))
        #expect(HistoryStore.location(environment: [:], home: home, platform: .linux).path == filePath("/Users/someone/.config/pimento/history.jsonl"))
        #expect(HistoryStore.location(environment: ["PIMENTO_HISTORY": "~/h.jsonl"], home: home).path == filePath("/Users/someone/h.jsonl"))
        let store = HistoryStore(url: URL(fileURLWithPath: "/tmp/x/history.jsonl"))
        #expect(store.rotatedURL.path == filePath("/tmp/x/history.1.jsonl"))
        #expect(store.settingsURL.path == filePath("/tmp/x/history-settings.json"))
    }

    @Test func appendsLinesWithMode600() throws {
        let store = HistoryStore(url: temporaryHistoryURL())
        #expect(store.load().records.isEmpty)
        try store.append([.sample(1), .sample(2)])
        try store.append([.sample(3)])
        let loaded = store.load()
        #expect(loaded.records.map(\.id) == ["rec-1", "rec-2", "rec-3"])
        let text = try String(contentsOf: store.url, encoding: .utf8)
        #expect(text.split(separator: "\n").count == 3 && text.hasSuffix("\n"))
        #expect(hasMode(store.url.path, 0o600))
    }

    @Test func skipsBrokenLines() throws {
        let store = HistoryStore(url: temporaryHistoryURL())
        try store.append([.sample(1)])
        let handle = try FileHandle(forWritingTo: store.url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("not json\n\n{\"v\":1,\"at\":\"2026-10-29T12:00:00Z\",\"act".utf8))
        try handle.close()
        try store.append([.sample(2)])
        let loaded = store.load()
        // The line cut off at the end does not swallow the next record.
        #expect(loaded.records.map(\.id) == ["rec-1", "rec-2"])
        #expect(loaded.unreadableLines == 2)
    }

    @Test func concurrentWritersDoNotInterleave() async throws {
        let url = temporaryHistoryURL()
        let writers = 8, perWriter = 40
        await withTaskGroup(of: Void.self) { group in
            for w in 0..<writers {
                group.addTask {
                    // Each writer its own store value (as the app and the CLI have).
                    let store = HistoryStore(url: url)
                    for i in 0..<perWriter {
                        var r = HistoryRecord.sample(w * 1000 + i)
                        r.justification = String(repeating: "x", count: 2000 + i)
                        try? store.append([r])
                    }
                }
            }
        }
        let loaded = HistoryStore(url: url).load()
        #expect(loaded.unreadableLines == 0)
        #expect(loaded.records.count == writers * perWriter)
        #expect(Set(loaded.records.map(\.id)).count == writers * perWriter)
    }

    @Test func rotatesPastTheSizeLimit() throws {
        let store = HistoryStore(url: temporaryHistoryURL(), maxBytes: 2000)
        for i in 0..<10 { try store.append([.sample(i)]) }
        #expect(FileManager.default.fileExists(atPath: store.rotatedURL.path))
        let current = try Data(contentsOf: store.url).count
        #expect(current <= 2000 + 1000)
        // Both files are read; at most two generations are kept.
        let ids = store.load().records.map(\.id)
        #expect(ids.last == "rec-9")
        #expect(ids.count < 10 && ids.count >= 3)
        #expect(ids == ids.sorted { Int($0.dropFirst(4))! < Int($1.dropFirst(4))! })
    }

    @Test func retentionPrunesOldRecords() throws {
        let store = HistoryStore(url: temporaryHistoryURL())
        let day: TimeInterval = 86400
        try store.append([
            .sample(1, at: Fixture.now.addingTimeInterval(-400 * day)),
            .sample(2, at: Fixture.now.addingTimeInterval(-100 * day)),
            .sample(3, at: Fixture.now.addingTimeInterval(-10 * day)),
        ])
        #expect(try store.prune(retention: .forever, now: Fixture.now) == 0)
        #expect(try store.prune(retention: .days365, now: Fixture.now) == 1)
        #expect(store.load().records.map(\.id) == ["rec-2", "rec-3"])
        // Shown records honour the retention even before a prune.
        #expect(store.records(settings: HistorySettings(retention: .days30), now: Fixture.now).map(\.id) == ["rec-3"])
        #expect(try store.prune(retention: .days30, now: Fixture.now) == 1)
        #expect(store.load().records.map(\.id) == ["rec-3"])
        #expect(hasMode(store.url.path, 0o600))
    }

    @Test func clearRemovesEverythingButSettings() throws {
        let store = HistoryStore(url: temporaryHistoryURL(), maxBytes: 1500)
        try store.saveSettings(HistorySettings(enabled: false, retention: .days90))
        for i in 0..<6 { try store.append([.sample(i)]) }
        try store.clear()
        #expect(store.load().records.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: store.rotatedURL.path))
        #expect(store.loadSettings() == HistorySettings(enabled: false, retention: .days90))
        try store.append([.sample(7)])
        #expect(store.load().records.count == 1)
    }

    @Test func settingsAreLenient() throws {
        let store = HistoryStore(url: temporaryHistoryURL())
        #expect(store.loadSettings() == HistorySettings())
        try FileManager.default.createDirectory(at: store.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"retentionDays": 100, "extra": 1}"#.utf8).write(to: store.settingsURL)
        #expect(store.loadSettings() == HistorySettings(enabled: true, retention: .days90))
        try Data(#"{"enabled": false, "retentionDays": 0}"#.utf8).write(to: store.settingsURL)
        #expect(store.loadSettings() == HistorySettings(enabled: false, retention: .forever))
        try Data("garbage".utf8).write(to: store.settingsURL)
        #expect(store.loadSettings() == HistorySettings())
    }

    @Test func recorderHonoursTheSettingAndNeverThrows() throws {
        let store = HistoryStore(url: temporaryHistoryURL())
        let recorder = HistoryRecorder(store: store, source: .cli, clock: { Fixture.now })
        recorder.record([.sample(1)])
        #expect(store.load().records.count == 1)
        try store.saveSettings(HistorySettings(enabled: false))
        recorder.record([.sample(2)])
        #expect(store.load().records.count == 1)

        // A path that cannot be a file (its folder is a file): no throw, the error is kept.
        let notAFolder = temporaryHistoryURL().deletingLastPathComponent().appendingPathComponent("not-a-folder")
        try FileManager.default.createDirectory(at: notAFolder.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: notAFolder)
        defer { try? FileManager.default.removeItem(at: notAFolder) }
        let blocked = HistoryRecorder(store: HistoryStore(url: notAFolder.appendingPathComponent("history.jsonl")), source: .cli)
        blocked.record([.sample(3)])
        #expect(blocked.lastError != nil)

        recorder.setTenantLabels(["ABC": "Contoso"])
        #expect(recorder.context(tenantId: "abc").tenantLabel == "Contoso")
        #expect(recorder.context(tenantId: "abc").at == Fixture.now)
    }
}

@Suite("History filters and dates")
struct HistoryFilterTests {
    let records: [HistoryRecord] = [
        .sample(1, at: Fixture.now.addingTimeInterval(-3600), action: .activate, tenantLabel: "Contoso"),
        .sample(2, at: Fixture.now.addingTimeInterval(-86400 * 3), action: .deactivate, result: .failed, role: "Reader"),
        .sample(3, at: Fixture.now.addingTimeInterval(-86400 * 10), action: .approve, tenantId: "00000000-0000-4000-8000-0000000000bb",
                tenantLabel: "Fabrikam", justification: "matches CHG-2002"),
        .sample(4, at: Fixture.now.addingTimeInterval(-60), action: .schedule, source: .azure),
    ]

    @Test func filtersCombine() {
        #expect(HistoryFilter().apply(records).map(\.id) == ["rec-4", "rec-1", "rec-2", "rec-3"])
        #expect(HistoryFilter(since: Fixture.now.addingTimeInterval(-86400 * 7)).apply(records).count == 3)
        #expect(HistoryFilter(until: Fixture.now.addingTimeInterval(-86400)).apply(records).map(\.id) == ["rec-2", "rec-3"])
        #expect(HistoryFilter(actions: [.activate, .schedule]).apply(records).map(\.id) == ["rec-4", "rec-1"])
        #expect(HistoryFilter(results: [.failed]).apply(records).map(\.id) == ["rec-2"])
        #expect(HistoryFilter(sources: [.azure]).apply(records).map(\.id) == ["rec-4"])
        #expect(HistoryFilter(tenant: "fabri").apply(records).map(\.id) == ["rec-3"])
        #expect(HistoryFilter(tenant: "00000000-0000-4000-8000-0000000000AA").apply(records).count == 3)
        #expect(HistoryFilter(text: "chg-2002 approve").apply(records).map(\.id) == ["rec-3"])
        #expect(HistoryFilter(text: "reader").apply(records).map(\.id) == ["rec-2"])
        #expect(HistoryFilter().apply(records, limit: 2).map(\.id) == ["rec-4", "rec-1"])
    }

    @Test func tenantNamesComeFromOtherRecords() {
        let filled = HistoryLog.fillingTenantLabels(records)
        #expect(filled.first { $0.id == "rec-2" }?.tenantLabel == "Contoso")
        #expect(filled.first { $0.id == "rec-3" }?.tenantLabel == "Fabrikam")
        let tenants = HistoryLog.tenants(in: filled)
        #expect(tenants.map(\.label) == ["Contoso", "Fabrikam"])
        let known = HistoryLog.fillingTenantLabels([.sample(9)], known: ["00000000-0000-4000-8000-0000000000AA": "Contoso Ltd"])
        #expect(known[0].tenantLabel == "Contoso Ltd")
    }

    @Test func parsesSinceAndUntil() throws {
        let utc = TimeZone(identifier: "UTC")!
        let now = Fixture.now
        #expect(HistoryDate.parse("7d", now: now, timeZone: utc) == now.addingTimeInterval(-7 * 86400))
        #expect(HistoryDate.parse("24h", now: now, timeZone: utc) == now.addingTimeInterval(-86400))
        #expect(HistoryDate.parse("30m", now: now, timeZone: utc) == now.addingTimeInterval(-1800))
        #expect(HistoryDate.parse("2w", now: now, timeZone: utc) == now.addingTimeInterval(-14 * 86400))
        #expect(HistoryDate.parse("today", now: now, timeZone: utc) == AzureDate.parse("2026-10-29T00:00:00Z"))
        #expect(HistoryDate.parse("yesterday", now: now, timeZone: utc) == AzureDate.parse("2026-10-28T00:00:00Z"))
        #expect(HistoryDate.parse("2026-10-01", now: now, timeZone: utc) == AzureDate.parse("2026-10-01T00:00:00Z"))
        #expect(HistoryDate.parse("2026-10-01 08:30", now: now, timeZone: utc) == AzureDate.parse("2026-10-01T08:30:00Z"))
        // As an upper bound, a whole day includes that day.
        let endOfOct1 = AzureDate.parse("2026-10-02T00:00:00Z")!.addingTimeInterval(-0.001)
        #expect(HistoryDate.parse("2026-10-01", now: now, timeZone: utc, endOfDay: true) == endOfOct1)
        #expect(HistoryDate.parse("today", now: now, timeZone: utc, endOfDay: true) == AzureDate.parse("2026-10-30T00:00:00Z")!.addingTimeInterval(-0.001))
        #expect(HistoryDate.parse("2026-10-01 08:30", now: now, timeZone: utc, endOfDay: true) == AzureDate.parse("2026-10-01T08:30:00Z"))
        #expect(HistoryDate.parse("7d", now: now, timeZone: utc, endOfDay: true) == now.addingTimeInterval(-7 * 86400))
        #expect(HistoryDate.parse("2026-10-01T08:30:00+02:00", now: now, timeZone: utc) == AzureDate.parse("2026-10-01T06:30:00Z"))
        for bad in ["", "soon", "7x", "-3d", "0d", "2026-13-45"] {
            #expect(HistoryDate.parse(bad, now: now, timeZone: utc) == nil, "\(bad)")
        }
        #expect(HistoryAction(argument: "Approve") == .approve)
        #expect(HistoryAction(argument: "teleport") == nil)
        #expect(HistoryResult(argument: "ok") == .succeeded && HistoryResult(argument: "cancelled") == .canceled)
    }
}

@Suite("History CSV")
struct HistoryCSVTests {
    @Test func escapesPerRFC4180() {
        #expect(HistoryCSV.field("plain") == "plain")
        #expect(HistoryCSV.field("a,b") == "\"a,b\"")
        #expect(HistoryCSV.field("say \"hi\"") == "\"say \"\"hi\"\"\"")
        #expect(HistoryCSV.field("two\nlines") == "\"two\nlines\"")
        #expect(HistoryCSV.field("cr\r\nlf") == "\"cr\r\nlf\"")
        #expect(HistoryCSV.field("") == "")
        #expect(HistoryCSV.field("Grüße, 東京") == "\"Grüße, 東京\"")
    }

    @Test func guardsAgainstFormulaInjection() {
        #expect(HistoryCSV.field("=1+2") == "'=1+2")
        #expect(HistoryCSV.field("+SUM(A1)") == "'+SUM(A1)")
        #expect(HistoryCSV.field("-2+3") == "'-2+3")
        #expect(HistoryCSV.field("@cmd") == "'@cmd")
        #expect(HistoryCSV.field("\tx") == "'\tx")
        #expect(HistoryCSV.field("\rx") == "\"'\rx\"")
        #expect(HistoryCSV.field("\r\nx") == "\"'\r\nx\"")
        #expect(HistoryCSV.field("=HYPERLINK(\"http://example.invalid\",\"x\")") == "\"'=HYPERLINK(\"\"http://example.invalid\"\",\"\"x\"\")\"")
        // Only the first character counts.
        #expect(HistoryCSV.field("a=b") == "a=b")
        #expect(HistoryCSV.field(" =b") == " =b")
    }

    @Test func documentHasHeaderCRLFAndBothTimes() throws {
        var r = HistoryRecord.sample(1, tenantLabel: "Contoso", justification: "deploy, release \"2.4\"")
        r.message = "=cmd|' /C calc'!A0"
        let csv = HistoryCSV.encode([r], timeZone: TimeZone(identifier: "Europe/Berlin")!)
        #expect(csv.hasSuffix("\r\n"))
        let lines = csv.components(separatedBy: "\r\n")
        #expect(lines.count == 3 && lines[2].isEmpty)
        #expect(lines[0] == HistoryCSV.columns.joined(separator: ","))
        #expect(lines[1].hasPrefix("2026-10-29T12:00:00.000Z,2026-10-29 13:00:00 +01:00,activate,succeeded,Provisioned,'=cmd|' /C calc'!A0,"))
        #expect(lines[1].contains(",\"deploy, release \"\"2.4\"\"\","))
        #expect(lines[1].contains(",Contoso,Owner,Contoso Production,"))
        #expect(lines[1].hasSuffix(",cli,0.1.0"))
        // No bare LF outside quoted fields.
        #expect(!csv.replacingOccurrences(of: "\r\n", with: "").contains("\n"))
        #expect(HistoryCSV.columns.count == lines[1].split(separator: ",", omittingEmptySubsequences: false).count - 1,
                "one extra comma inside the quoted justification")
    }

    @Test func writesTheFileReadableOnlyByYou() throws {
        let url = temporaryHistoryURL().deletingLastPathComponent().appendingPathComponent("export.csv")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try HistoryCSV.write([.sample(1)], to: url, timeZone: TimeZone(identifier: "UTC")!)
        #expect(try String(contentsOf: url, encoding: .utf8).hasPrefix("timestamp_utc,local_time,"))
        #expect(hasMode(url.path, 0o600))
    }
}

@Suite("History import from Azure")
struct HistoryImportTests {
    func items() throws -> [AssignmentScheduleRequestItem] {
        try Fixture.decode("history-requests", as: ARMList<AssignmentScheduleRequestItem>.self).value
    }

    @Test func mapsYourSelfServiceRequests() throws {
        let records = HistoryImport.records(from: try items(), principalId: Fixture.userOID, tenantId: "t-1", tenantLabel: "Contoso")
        // Admin assignments and other people's requests are left out.
        #expect(records.map(\.requestId).allSatisfy { $0 != "5e5e5e5e-0000-4000-8000-000000000005" && $0 != "6f6f6f6f-0000-4000-8000-000000000006" })
        #expect(records.count == 5)
        #expect(records.map(\.action) == [.activate, .activate, .activate, .deactivate, .schedule])
        #expect(records.map(\.result) == [.expired, .denied, .succeeded, .succeeded, .canceled])
        let activation = try #require(records.first { $0.requestId == "1a1a1a1a-0000-4000-8000-000000000001" })
        #expect(activation.source == .azure && activation.version == nil)
        #expect(activation.tenantId == "t-1" && activation.tenantLabel == "Contoso")
        #expect(activation.roleName == "Owner" && activation.scopeName == "Contoso Production" && activation.scopeType == "subscription")
        #expect(activation.durationMinutes == 480 && activation.requestedDuration == "PT8H")
        #expect(activation.end == AzureDate.parse("2026-10-28T17:00:00.12Z"))
        #expect(activation.ticketNumber == "CHG-1001" && activation.justification == "deploy, release 2.4")
        #expect(activation.id == "azure-1a1a1a1a-0000-4000-8000-000000000001")
        let scheduled = try #require(records.first { $0.action == .schedule })
        #expect(scheduled.durationMinutes == 480 && scheduled.start == AzureDate.parse("2026-11-02T08:00:00Z"))
        let ended = try #require(records.first { $0.action == .deactivate })
        #expect(ended.durationMinutes == nil && ended.status == "Revoked")

        let recent = HistoryImport.records(from: try items(), principalId: Fixture.userOID, tenantId: "t-1",
                                           since: AzureDate.parse("2026-10-28T00:00:00Z"))
        #expect(recent.count == 3)
    }

    @Test func mergesWithoutDuplicates() throws {
        let store = HistoryStore(url: temporaryHistoryURL())
        // Pimento made one of them itself; a renewal holds the deactivation's id as related.
        var own = HistoryRecord.sample(1, requestId: "1A1A1A1A-0000-4000-8000-000000000001", source: .app)
        own.action = .activate
        var renewal = HistoryRecord.sample(2, action: .renew, requestId: "ffffffff-0000-4000-8000-00000000000f")
        renewal.relatedRequestId = "2b2b2b2b-0000-4000-8000-000000000002"
        try store.append([own, renewal])
        let imported = HistoryImport.records(from: try items(), principalId: Fixture.userOID, tenantId: "t-1")
        let first = try store.importRecords(imported)
        #expect(first.added == 3 && first.known == 2)
        let again = try store.importRecords(imported)
        #expect(again.added == 0 && again.known == 5)
        let all = store.load().records
        #expect(all.count == 5)
        #expect(all.filter { $0.source == .azure }.count == 3)
    }

    @Test func statusesMapToResults() {
        #expect(HistoryImport.result(status: "Provisioned") == .succeeded)
        #expect(HistoryImport.result(status: "pendingApproval") == .pending)
        #expect(HistoryImport.result(status: "PendingAdminDecision") == .pending)
        #expect(HistoryImport.result(status: "AdminDenied") == .denied)
        #expect(HistoryImport.result(status: "TimedOut") == .expired)
        #expect(HistoryImport.result(status: "FailedAsResourceIsLocked") == .failed)
        #expect(HistoryImport.result(status: "Something new") == .unknown)
        #expect(HistoryImport.action(requestType: "AdminAssign", start: nil, createdOn: nil) == nil)
        #expect(HistoryImport.action(requestType: "SelfRenew", start: nil, createdOn: nil) == .renew)
    }
}

@Suite("History window logic")
struct HistoryWindowTests {
    @Test func periods() {
        #expect(HistoryPeriod.week.since(now: Fixture.now) == Fixture.now.addingTimeInterval(-7 * 86400))
        #expect(HistoryPeriod.all.since(now: Fixture.now) == nil)
        #expect(HistoryPeriod.custom.since(now: Fixture.now) == nil)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let (from, to) = HistoryPeriod.customRange(
            from: AzureDate.parse("2026-10-20T15:00:00Z")!, to: AzureDate.parse("2026-10-18T09:00:00Z")!, calendar: calendar)
        #expect(from == AzureDate.parse("2026-10-18T00:00:00Z"))
        #expect(abs(to.timeIntervalSince(AzureDate.parse("2026-10-21T00:00:00Z")!)) < 0.01 && to < AzureDate.parse("2026-10-21T00:00:00Z")!)
    }

    @Test func activateAgainFindsTheEligibleRow() throws {
        let rows = try Fixture.rows()
        let staging = try Fixture.role("Contoso Staging", "Contributor")
        var record = HistoryRecord.sample(1, tenantId: "t-1", role: "Contributor", scopeName: "Contoso Staging")
        record.scope = staging.scope
        record.roleDefinitionId = staging.roleDefinitionId
        #expect(HistoryReplay.verdict(for: record, roles: rows, tenantId: "T-1") == .ready(staging))
        #expect(HistoryReplay.verdict(for: record, roles: rows, tenantId: "t-2") == .otherTenant("t-1"))
        #expect(HistoryReplay.verdict(for: record, roles: [], tenantId: "t-1") == .notEligible)
        var active = staging
        active.isActive = true
        #expect(HistoryReplay.verdict(for: record, roles: [active], tenantId: nil) == .alreadyActive(active))
        record.action = .approve
        #expect(HistoryReplay.verdict(for: record, roles: rows, tenantId: "t-1") == .notAnActivation)

        record.requestedDuration = "max"
        #expect(HistoryReplay.duration(of: record) == .maximum)
        record.requestedDuration = "PT4H"
        #expect(HistoryReplay.duration(of: record) == .hours(4))
        record.requestedDuration = nil
        record.durationMinutes = 120
        #expect(HistoryReplay.duration(of: record) == .hours(2))
        record.durationMinutes = 90
        #expect(HistoryReplay.duration(of: record) == nil)
    }
}
