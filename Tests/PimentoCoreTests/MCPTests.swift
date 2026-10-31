import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import PimentoCore

// MARK: - Harness

/// Counts what reaches the simulator, by method: a refused or declined write
/// must not send a single PUT.
final class MethodLog: @unchecked Sendable {
    private let lock = NSLock()
    private var methods: [String] = []
    func add(_ m: String) { lock.withLock { methods.append(m) } }
    var writes: Int { lock.withLock { methods.filter { $0 != "GET" }.count } }
}

struct CountingTransport: HTTPTransport {
    let base: HTTPTransport
    let log: MethodLog
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        log.add(request.httpMethod ?? "GET")
        return try await base.send(request)
    }
}

/// Lines the server wrote, readable as they arrive.
final class LineCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    func add(_ line: String) { lock.withLock { lines.append(line) } }
    var all: [String] { lock.withLock { lines } }
}

/// The MCP server on the demo simulator, with in-memory streams: what a
/// client would see on the server's stdout, and what it writes to its stdin.
final class MCPHarness: @unchecked Sendable {
    static let now = AzureDate.parse("2026-10-30T10:30:00Z")!
    let workspace = DemoWorkspace(directory: TestTemp.url("mcp"))
    let clock = DemoClock.manual(at: MCPHarness.now)
    let session: DemoSession
    let methods = MethodLog()
    let output = LineCollector()
    let server: MCPServer
    private let continuation: AsyncStream<String>.Continuation
    private var runTask: Task<Void, Never>?
    private var consumed = 0

    init(_ config: MCPConfiguration = MCPConfiguration(), presets: PresetStore? = nil) throws {
        let utc = TimeZone(identifier: "UTC")!
        try workspace.reset(now: MCPHarness.now, timeZone: utc)
        let clock = clock
        session = DemoSession(options: DemoOptions(frozenAt: 630), clock: clock, workspace: workspace, timeZone: utc) { clock.advance(by: $0) }
        let session = session, methods = methods, workspace = workspace
        let recorder = HistoryRecorder(store: workspace.historyStore, source: .mcp, clock: { clock.now() })
        let backend = MCPBackend(
            service: { tenant, readOnly in
                let base: HTTPTransport = readOnly ? ReadOnlyTransport(session.azure) : session.azure
                return PIMService(transport: CountingTransport(base: base, log: methods), tokens: session.azureCLITokens(tenantId: tenant),
                                  sleep: session.sleep, clock: { clock.now() }, history: readOnly ? nil : recorder)
            },
            tenants: { _ in try await session.loadTenants() },
            resolveTenant: { $0 },
            presets: presets ?? workspace.presetStore, history: workspace.historyStore, now: { clock.now() }, timeZone: utc)
        let output = output
        server = MCPServer(config: config, tools: MCPToolbox(backend: backend), clock: { clock.now() }, send: { output.add($0) })
        var c: AsyncStream<String>.Continuation!
        let stream = AsyncStream<String> { c = $0 }
        continuation = c
        let server = server
        runTask = Task { await server.run(lines: stream) }
    }

    deinit { workspace.remove() }

    func send(_ message: JSONValue) { continuation.yield(message.serialized) }
    func sendRaw(_ line: String) { continuation.yield(line) }

    /// The next message the server sends (at most 5 s away).
    func next() async throws -> JSONValue {
        for _ in 0..<1000 {
            let lines = output.all
            if lines.count > consumed {
                consumed += 1
                return try JSONValue.parse(lines[consumed - 1])
            }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        Issue.record("no message from the server")
        throw CancellationError()
    }

    /// Nothing more within a short while.
    func expectSilence() async throws {
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(output.all.count == consumed, "unexpected: \(output.all.dropFirst(consumed))")
    }

    func request(_ id: Int, _ method: String, _ params: JSONValue = [:]) async throws -> JSONValue {
        send(["jsonrpc": "2.0", "id": .int(id), "method": .string(method), "params": params])
        return try await next()
    }

    /// `initialize` + `notifications/initialized`, with or without form elicitation.
    func initialize(version: String = "2025-11-25", elicitation: Bool = true) async throws -> JSONValue {
        let caps: JSONValue = elicitation ? ["elicitation": ["form": [:]]] : [:]
        let r = try await request(0, "initialize", ["protocolVersion": .string(version), "capabilities": caps,
                                                    "clientInfo": ["name": "test", "version": "1"]])
        send(["jsonrpc": "2.0", "method": "notifications/initialized"])
        return r
    }

    /// A legacy `tools/call`.
    func call(_ id: Int, _ tool: String, _ args: JSONValue) {
        send(["jsonrpc": "2.0", "id": .int(id), "method": "tools/call", "params": ["name": .string(tool), "arguments": args]])
    }

    static func modernMeta(elicitation: Bool = true) -> JSONValue {
        ["io.modelcontextprotocol/protocolVersion": "2026-07-28",
         "io.modelcontextprotocol/clientCapabilities": elicitation ? ["elicitation": [:]] : [:],
         "io.modelcontextprotocol/clientInfo": ["name": "test", "version": "1"]]
    }

    func finish() async {
        continuation.finish()
        await runTask?.value
    }

    var mcpHistory: [HistoryRecord] { workspace.historyStore.records(now: clock.now()).filter { $0.source == .mcp } }

    func activeRoles() async throws -> [EligibleRole] {
        try await session.makeService(tokens: session.azureCLITokens(tenantId: nil), readOnly: true).loadRoles().roles.filter(\.isActive)
    }
}

extension JSONValue {
    subscript(index: Int) -> JSONValue? {
        guard case .array(let a) = self, a.indices.contains(index) else { return nil }
        return a[index]
    }
    var result: JSONValue? { self["result"] }
    var toolText: String { self["result"]?["content"]?.arrayValue?.first?["text"]?.stringValue ?? "" }
    var isToolError: Bool { self["result"]?["isError"]?.boolValue == true }
    var errorCode: Int? { if case .int(let c)? = self["error"]?["code"] { c } else { nil } }
}

let reader: JSONValue = ["roles": [["role": "Reader", "scope": "Contoso Production"]], "justification": "INC-1234 read the logs", "hours": 24]

// MARK: - Framing

@Suite("MCP: JSON and framing")
struct MCPJSONTests {
    @Test func parsesAndWritesOneLineExactly() throws {
        let text = #"{"a":[1,-2,3.5,1e3,true,false,null],"b":"x\"y\\z\n\u00e9\ud83d\ude00","id":9007199254740993}"#
        let v = try JSONValue.parse(text)
        #expect(v["id"] == .int(9_007_199_254_740_993))
        #expect(v["a"]?.arrayValue?[2] == .double(3.5))
        #expect(v["b"]?.stringValue == "x\"y\\z\né😀")
        let out = v.serialized
        #expect(!out.contains("\n"))
        #expect(try JSONValue.parse(out) == v)
    }

    @Test func refusesWhatIsNotStrictJSON() {
        for bad in ["{", "[1,]", "{\"a\":1,}", "{'a':1}", "01", "NaN", "{\"a\":1}x", "\"\u{01}\"", "{\"a\":1,\"a\":2}", "\"\\ud800\"", "1e999"] {
            #expect(throws: JSONParseError.self, "\(bad)") { try JSONValue.parse(bad) }
        }
        let deep = String(repeating: "[", count: 100) + String(repeating: "]", count: 100)
        #expect(throws: JSONParseError.self) { try JSONValue.parse(deep) }
    }

    @Test func escapesSeparatorsAndBidiCharacters() {
        let v: JSONValue = .string("a\u{2028}b\u{202E}c\u{7F}d")
        #expect(v.serialized == #""a\u2028b\u202ec\u007fd""#)
    }

    @Test func redactsPathsAndTokens() {
        let s = MCPText.redact("open /home/alex/.config/pimento/presets.json failed; /private/var/folders/alex/T/x; ~/x/y; C:\\Users\\alex\\AppData\\x.json; eyJhbGciOiJub25lIn0.eyJvaWQiOiJ4In0.sig; Bearer abcdefghijklmnop; scope /subscriptions/0000/resourceGroups/rg")
        #expect(!s.contains("alex"))
        #expect(!s.contains("eyJ"))
        #expect(!s.contains("abcdefghijklmnop"))
        #expect(s.contains("/subscriptions/0000/resourceGroups/rg"))
    }

    @Test func redactsPathsWithSpacesButKeepsTheWordsAfterThem() {
        let s = MCPText.redact("open /home/Alex Smith/Library/Application Support/Pimento/presets.json failed: "
            + "C:\\Users\\Jane Wilber\\AppData\\Roaming\\Pimento\\presets.json missing; /tmp/a b")
        #expect(s == "open <path> failed: <path> missing; <path> b", "\(s)")
    }
}

// MARK: - Lifecycle

@Suite("MCP: lifecycle and protocol")
struct MCPLifecycleTests {
    @Test func initializeNegotiatesALegacyVersion() async throws {
        let h = try MCPHarness()
        let r = try await h.initialize(version: "2025-06-18")
        #expect(r["result"]?["protocolVersion"] == "2025-06-18")
        #expect(r["result"]?["serverInfo"]?["name"] == "pimento")
        #expect(r["result"]?["capabilities"]?["tools"] != nil)
        #expect(r["result"]?["instructions"]?.stringValue?.contains("read-only") == true)
        // An unknown version: the newest the server speaks.
        let other = try MCPHarness()
        #expect(try await other.initialize(version: "1999-01-01")["result"]?["protocolVersion"] == .string(MCP.legacyVersions[0]))
        // The notification got no answer; tools/list works.
        let list = try await h.request(1, "tools/list")
        #expect(list["result"]?["tools"]?.arrayValue?.isEmpty == false)
        #expect(list["result"]?["resultType"] == nil)
        #expect(try await h.request(2, "ping")["result"] == .object([:]))
        await h.finish()
        await other.finish()
    }

    @Test func requestsWithoutAnEraAreRefused() async throws {
        let h = try MCPHarness()
        let r = try await h.request(1, "tools/list")
        #expect(r.errorCode == -32602)
        #expect(r["id"] == 1)
        await h.finish()
    }

    @Test func modernRequestsCarryTheirOwnVersionAndCapabilities() async throws {
        let h = try MCPHarness()
        let list = try await h.request(1, "tools/list", ["_meta": MCPHarness.modernMeta()])
        #expect(list["result"]?["resultType"] == "complete")
        #expect(list["result"]?["_meta"]?["io.modelcontextprotocol/serverInfo"]?["name"] == "pimento")
        let discover = try await h.request(2, "server/discover", ["_meta": MCPHarness.modernMeta()])
        #expect(discover["result"]?["supportedVersions"]?.arrayValue?.first == "2026-07-28")
        #expect(discover["result"]?["supportedVersions"]?.arrayValue?.contains("2025-11-25") == true)

        var meta = MCPHarness.modernMeta().objectValue!
        meta["io.modelcontextprotocol/protocolVersion"] = "2099-01-01"
        let unsupported = try await h.request(3, "tools/list", ["_meta": .object(meta)])
        #expect(unsupported.errorCode == -32022)
        #expect(unsupported["error"]?["data"]?["requested"] == "2099-01-01")
        #expect(unsupported["error"]?["data"]?["supported"]?.arrayValue?.contains("2026-07-28") == true)

        meta = MCPHarness.modernMeta().objectValue!
        meta["io.modelcontextprotocol/clientCapabilities"] = nil
        #expect(try await h.request(4, "tools/list", ["_meta": .object(meta)]).errorCode == -32602)
        #expect(try await h.request(5, "resources/list", ["_meta": MCPHarness.modernMeta()]).errorCode == -32601)
        await h.finish()
    }

    @Test func malformedMessagesGetJSONRPCErrors() async throws {
        let h = try MCPHarness()
        h.sendRaw("{not json")
        #expect(try await h.next().errorCode == -32700)
        h.sendRaw(#"[{"jsonrpc":"2.0","id":1,"method":"ping"}]"#)
        #expect(try await h.next().errorCode == -32600)
        h.sendRaw(#"{"jsonrpc":"2.0","id":null,"method":"ping"}"#)
        #expect(try await h.next().errorCode == -32600)
        h.sendRaw(#"{"jsonrpc":"2.0","id":{"a":1},"method":"ping"}"#)
        #expect(try await h.next().errorCode == -32600)
        // Notifications are never answered, known or not.
        h.sendRaw(#"{"jsonrpc":"2.0","method":"notifications/whatever"}"#)
        h.sendRaw("")
        try await h.expectSilence()
        await h.finish()
    }

    @Test func toolListDependsOnlyOnHowTheServerWasStarted() async throws {
        let readOnly = try MCPHarness()
        let ro = try await readOnly.request(1, "tools/list", ["_meta": MCPHarness.modernMeta()])
        let roNames = Set(ro["result"]?["tools"]?.arrayValue?.compactMap { $0["name"]?.stringValue } ?? [])
        #expect(roNames == ["list_tenants", "list_eligible_roles", "list_active_roles", "list_presets", "list_pending_approvals", "get_history"])
        for tool in ro["result"]?["tools"]?.arrayValue ?? [] {
            #expect(tool["annotations"]?["readOnlyHint"] == true)
            #expect(tool["inputSchema"]?["additionalProperties"] == false)
        }
        let call = try await readOnly.request(2, "tools/call", ["_meta": MCPHarness.modernMeta(), "name": "activate_roles", "arguments": reader])
        #expect(call.errorCode == -32602)
        #expect(call["error"]?["message"]?.stringValue?.contains("--allow-activate") == true)
        #expect(readOnly.methods.writes == 0)
        await readOnly.finish()

        let rw = try MCPHarness(MCPConfiguration(allowActivate: true))
        let tools = try await rw.request(1, "tools/list", ["_meta": MCPHarness.modernMeta()])["result"]?["tools"]?.arrayValue ?? []
        let byName = Dictionary(uniqueKeysWithValues: tools.compactMap { t in t["name"]?.stringValue.map { ($0, t) } })
        #expect(Set(byName.keys).isSuperset(of: ["activate_roles", "deactivate_roles", "renew_roles"]))
        #expect(byName["activate_roles"]?["annotations"]?["readOnlyHint"] == false)
        #expect(byName["activate_roles"]?["annotations"]?["destructiveHint"] == false)
        #expect(byName["deactivate_roles"]?["annotations"]?["destructiveHint"] == true)
        #expect(byName["activate_roles"]?["inputSchema"]?["required"] == ["justification"])
        await rw.finish()
    }

    @Test func readToolsAnswerFromTheSimulator() async throws {
        let h = try MCPHarness()
        _ = try await h.initialize()
        h.call(1, "list_active_roles", [:])
        let active = try await h.next()
        #expect(!active.isToolError)
        #expect(active["result"]?["structuredContent"]?["count"] == 3)
        h.call(2, "list_eligible_roles", ["role": "Owner"])
        let owners = try await h.next()["result"]?["structuredContent"]?["roles"]?.arrayValue ?? []
        #expect(owners.count == 2)
        #expect(owners.allSatisfy { $0["highPrivilege"] == true })
        #expect(owners.contains { $0["policy"]?["requiresApproval"] == true && $0["policy"]?["maxDuration"] == "PT1H" })
        h.call(3, "list_presets", [:])
        let presets = try await h.next()
        #expect(presets.toolText.contains("On-call"))
        #expect(!presets.toolText.contains(h.workspace.directory.path))
        h.call(4, "list_pending_approvals", [:])
        #expect(try await h.next()["result"]?["structuredContent"]?["count"] != nil)
        h.call(5, "get_history", ["limit": 2])
        #expect(try await h.next()["result"]?["structuredContent"]?["records"]?.arrayValue?.count == 2)
        h.call(6, "list_tenants", [:])
        #expect(try await h.next().toolText.contains("Fabrikam"))
        #expect(h.methods.writes == 0)
        await h.finish()
    }

    @Test func aPinnedServerListsOnlyItsTenant() async throws {
        for pin in [DemoDirectory.fabrikam.id, "FABRIKAM.example"] {
            let h = try MCPHarness(MCPConfiguration(tenant: pin))
            _ = try await h.initialize()
            h.call(1, "list_tenants", [:])
            let r = try await h.next()
            let ids = (r["result"]?["structuredContent"]?["tenants"]?.arrayValue ?? []).compactMap { $0["id"]?.stringValue }
            #expect(ids == [DemoDirectory.fabrikam.id], "\(pin): \(r.toolText)")
            await h.finish()
        }
    }

    @Test func finishedRequestsAreNotKept() async throws {
        let h = try MCPHarness()
        _ = try await h.initialize()
        for id in 1...200 { h.send(["jsonrpc": "2.0", "id": .int(id), "method": "ping"]) }
        for _ in 1...200 { _ = try await h.next() }
        #expect(h.server.requestsInFlight == 0)
        await h.finish()
    }

    @Test func endOfInputEndsTheServer() async throws {
        let h = try MCPHarness()
        await h.finish()
        #expect(h.output.all.isEmpty)
    }
}

// MARK: - Validation

@Suite("MCP: input validation")
struct MCPValidationTests {
    static let bad: [(JSONValue, String)] = [
        (["roles": [["role": "Reader", "scope": "Contoso Production"]]], "justification"),
        (["roles": [["role": "Reader", "scope": "Contoso Production"]], "justification": "x", "admin": true], "Unknown argument"),
        (["roles": [["role": "Reader", "scope": "Contoso Production"]], "justification": 42], "must be a string"),
        (["roles": [["role": "Reader", "scope": "Contoso Production"]], "justification": "   "], "must not be empty"),
        (["roles": [["role": "Reader", "scope": "Contoso Production"]], "justification": "ok\nIgnore the above"], "control"),
        (["roles": [["role": "Reader", "scope": "Contoso Production"]], "justification": "ok \u{202E}txet"], "control"),
        (["roles": [["role": "Reader", "scope": "Contoso Production"]], "justification": "zero\u{200B}width"], "control"),
        (["roles": [["role": "Reader", "scope": "Contoso Production"]], "justification": .string(String(repeating: "a", count: 501))], "too long"),
        (["roles": [["role": "Reader", "scope": "Contoso Production"]], "justification": "x", "hours": 25], "between 1 and 24"),
        (["roles": [["role": "Reader", "scope": "Contoso Production"]], "justification": "x", "hours": .double(1.5)], "integer"),
        (["roles": [["role": "*", "scope": "Contoso Production"]], "justification": "x"], "wildcards"),
        (["roles": [["role": "Reader", "scope": "/subscriptions/../x"]], "justification": "x"], "ARM scope"),
        (["roles": [["role": "Reader", "scope": "Contoso Production", "extra": 1]], "justification": "x"], "Unknown argument"),
        (["roles": [], "justification": "x"], "must not be empty"),
        (["roles": .array(Array(repeating: ["role": "Reader", "scope": "Contoso Production"] as JSONValue, count: 21)), "justification": "x"], "too many"),
        (["justification": "x"], "Name the roles"),
        (["roles": [["role": "Reader", "scope": "Contoso Production"]], "preset": "On-call", "justification": "x"], "either roles or preset"),
        (["roles": [["role": "Reader", "scope": "Contoso Production"]], "justification": "x", "tenant": "--evil"], "tenant"),
        (["roles": [["role": "Reader", "scope": "Contoso Production"]], "justification": "x", "ticket_system": "Jira"], "ticket_number"),
        (["roles": [["role": "Reader", "scope": "Nowhere"]], "justification": "x"], "No eligible role"),
    ]

    @Test func untrustedArgumentsAreRefusedBeforeAnythingHappens() async throws {
        let h = try MCPHarness(MCPConfiguration(allowActivate: true))
        _ = try await h.initialize()
        for (n, (args, expected)) in Self.bad.enumerated() {
            h.call(n + 1, "activate_roles", args)
            let r = try await h.next()
            #expect(r.isToolError, "accepted: \(args.serialized)")
            #expect(r.toolText.contains(expected), "\(args.serialized): \(r.toolText)")
        }
        // Arguments that are not an object, or no tool name: protocol errors.
        h.send(["jsonrpc": "2.0", "id": 100, "method": "tools/call", "params": ["name": "activate_roles", "arguments": "x"]])
        #expect(try await h.next().errorCode == -32602)
        h.send(["jsonrpc": "2.0", "id": 101, "method": "tools/call", "params": ["arguments": [:]]])
        #expect(try await h.next().errorCode == -32602)
        #expect(h.methods.writes == 0)
        #expect(h.mcpHistory.isEmpty)
        await h.finish()
    }

    @Test func aPinnedTenantCannotBeLeft() async throws {
        let h = try MCPHarness(MCPConfiguration(allowActivate: true, tenant: DemoDirectory.fabrikam.id))
        _ = try await h.initialize()
        var args = reader.objectValue!
        args["tenant"] = .string(DemoDirectory.contoso.id)
        h.call(1, "activate_roles", .object(args))
        let r = try await h.next()
        #expect(r.isToolError)
        #expect(r.toolText.contains("limited to tenant"))
        h.call(2, "list_active_roles", ["tenant": .string(DemoDirectory.contoso.id)])
        #expect(try await h.next().isToolError)
        #expect(h.methods.writes == 0)
        await h.finish()
    }

    @Test func historyKeepsToThePinnedTenant() async throws {
        func tenants(_ config: MCPConfiguration) async throws -> [String] {
            let h = try MCPHarness(config)
            let at = MCPHarness.now.addingTimeInterval(-3600)
            // Keep-alive's records are filtered like the others.
            try h.workspace.historyStore.append(([DemoDirectory.contoso.id, DemoDirectory.fabrikam.id, nil] as [String?]).flatMap { id in
                [HistorySource.cli, .keepAlive].map {
                    HistoryRecord(at: at, action: .activate, result: .succeeded, tenantId: id, scope: "/subscriptions/x",
                                  justification: "pin-check", source: $0)
                }
            })
            _ = try await h.initialize()
            h.call(1, "get_history", ["text": "pin-check"])
            let r = try await h.next()
            #expect(!r.isToolError, "\(r.toolText)")
            await h.finish()
            return (r["result"]?["structuredContent"]?["records"]?.arrayValue ?? []).map { $0["tenantId"]?.stringValue ?? "none" }
        }
        #expect(try await tenants(MCPConfiguration()).count == 6)
        #expect(try await tenants(MCPConfiguration(tenant: DemoDirectory.fabrikam.id)) == [DemoDirectory.fabrikam.id, DemoDirectory.fabrikam.id])
        // A domain pin is resolved to the tenant's GUID through its token.
        #expect(try await tenants(MCPConfiguration(tenant: "CONTOSO.example")) == [DemoDirectory.contoso.id, DemoDirectory.contoso.id])
        // A pin that cannot be resolved shows nothing rather than everything.
        #expect(try await tenants(MCPConfiguration(tenant: "unknown.example")) == [])
    }

    @Test func callsAreRateLimited() async throws {
        var config = MCPConfiguration()
        config.readsPerMinute = 2
        let h = try MCPHarness(config)
        _ = try await h.initialize()
        for id in 1...3 { h.call(id, "list_presets", [:]) }
        var errors = 0
        for _ in 1...3 {
            if try await h.next().isToolError { errors += 1 }
        }
        #expect(errors == 1)
        await h.finish()
    }
}

// MARK: - Confirmation

@Suite("MCP: confirmation and gating")
struct MCPConfirmationTests {
    /// Activates Reader on Contoso Production (8 h policy) through a legacy
    /// elicitation answered with `answer`; returns the elicitation and the result.
    func legacyActivation(answer: JSONValue?, config: MCPConfiguration = MCPConfiguration(allowActivate: true),
                          args: JSONValue = reader) async throws -> (MCPHarness, JSONValue, JSONValue) {
        let h = try MCPHarness(config)
        _ = try await h.initialize()
        h.call(1, "activate_roles", args)
        let ask = try await h.next()
        #expect(ask["method"] == "elicitation/create")
        #expect(h.methods.writes == 0, "sent before the user answered")
        if let answer {
            h.send(["jsonrpc": "2.0", "id": ask["id"]!, "result": answer])
        } else {
            h.send(["jsonrpc": "2.0", "id": ask["id"]!, "error": ["code": -1, "message": "no"]])
        }
        return (h, ask, try await h.next())
    }

    @Test func acceptedElicitationActivatesCappedAndRecorded() async throws {
        let (h, ask, result) = try await legacyActivation(answer: ["action": "accept", "content": ["confirm": true]])
        let message = ask["params"]?["message"]?.stringValue ?? ""
        #expect(message.contains("ACTIVATE"))
        #expect(message.contains("Reader on \"Contoso Production\""))
        #expect(message.contains("8 h (asked 24 h; capped at the policy maximum)"))
        #expect(message.contains("\"INC-1234 read the logs\""))
        #expect(ask["params"]?["requestedSchema"]?["required"] == ["confirm"])
        #expect(ask["params"]?["mode"] == "form")
        #expect(!result.isToolError)
        let first = result["result"]?["structuredContent"]?["results"]?.arrayValue?.first
        #expect(first?["outcome"] == "activated")
        #expect(first?["duration"] == "PT8H")
        #expect(first?["capped"] == true)
        #expect(first?["request"] == nil)
        #expect(h.methods.writes == 1)
        let recorded = h.mcpHistory
        #expect(recorded.count == 1)
        #expect(recorded.first?.action == .activate)
        #expect(recorded.first?.justification == "INC-1234 read the logs")
        #expect(recorded.first?.durationMinutes == 480)
        #expect(try await h.activeRoles().contains { $0.roleName == "Reader" && $0.scopeName == "Contoso Production" })
        await h.finish()
    }

    @Test func declinedDismissedUncheckedOrFailedSendNothing() async throws {
        let answers: [JSONValue?] = [
            ["action": "decline"], ["action": "cancel"], ["action": "accept", "content": ["confirm": false]],
            ["action": "accept", "content": [:]], ["action": "accept", "content": ["confirm": "true"]], nil,
        ]
        for answer in answers {
            let (h, _, result) = try await legacyActivation(answer: answer)
            #expect(result.isToolError, "\(answer?.serialized ?? "error")")
            #expect(result.toolText.contains("Nothing was sent"))
            #expect(h.methods.writes == 0)
            #expect(h.mcpHistory.isEmpty)
            await h.finish()
        }
    }

    @Test func theElicitationFitsTheNegotiatedRevision() async throws {
        let h = try MCPHarness(MCPConfiguration(allowActivate: true))
        _ = try await h.initialize(version: "2025-06-18")
        h.call(1, "activate_roles", reader)
        let ask = try await h.next()
        #expect(ask["method"] == "elicitation/create")
        #expect(ask["params"]?["mode"] == nil)
        #expect(ask["params"]?["requestedSchema"] != nil)
        await h.finish()
    }

    @Test func anUnansweredConfirmationTimesOut() async throws {
        var config = MCPConfiguration(allowActivate: true)
        config.confirmationTimeout = 0.2
        let h = try MCPHarness(config)
        _ = try await h.initialize()
        h.call(1, "activate_roles", reader)
        #expect(try await h.next()["method"] == "elicitation/create")
        let result = try await h.next()
        #expect(result.isToolError)
        #expect(h.methods.writes == 0)
        await h.finish()
    }

    @Test func aCancelledCallGetsNoAnswerAndSendsNothing() async throws {
        let h = try MCPHarness(MCPConfiguration(allowActivate: true))
        _ = try await h.initialize()
        h.call(1, "activate_roles", reader)
        let ask = try await h.next()
        h.send(["jsonrpc": "2.0", "method": "notifications/cancelled", "params": ["requestId": 1]])
        try await h.expectSilence()
        // A late answer changes nothing.
        h.send(["jsonrpc": "2.0", "id": ask["id"]!, "result": ["action": "accept", "content": ["confirm": true]]])
        try await h.expectSilence()
        #expect(h.methods.writes == 0)
        await h.finish()
    }

    @Test func endOfInputWhileAskingSendsNothing() async throws {
        let h = try MCPHarness(MCPConfiguration(allowActivate: true))
        _ = try await h.initialize()
        h.call(1, "activate_roles", reader)
        #expect(try await h.next()["method"] == "elicitation/create")
        await h.finish()
        #expect(h.methods.writes == 0)
    }

    @Test func withoutElicitationWritesAreRefusedUnlessNoConfirm() async throws {
        // Legacy client without the capability: a tool error.
        let legacy = try MCPHarness(MCPConfiguration(allowActivate: true))
        _ = try await legacy.initialize(elicitation: false)
        legacy.call(1, "activate_roles", reader)
        let refused = try await legacy.next()
        #expect(refused.isToolError)
        #expect(refused.toolText.contains("--no-confirm"))
        // 2025-03-26 has no elicitation, whatever the client claims.
        let old = try MCPHarness(MCPConfiguration(allowActivate: true))
        _ = try await old.initialize(version: "2025-03-26", elicitation: true)
        old.call(1, "activate_roles", reader)
        #expect(try await old.next().isToolError)
        // Stateless client without it: MissingRequiredClientCapability.
        let modern = try MCPHarness(MCPConfiguration(allowActivate: true))
        let r = try await modern.request(1, "tools/call", ["_meta": MCPHarness.modernMeta(elicitation: false), "name": "activate_roles", "arguments": reader])
        #expect(r.errorCode == -32021)
        #expect(r["error"]?["data"]?["requiredCapabilities"]?["elicitation"] != nil)
        for h in [legacy, old, modern] {
            #expect(h.methods.writes == 0)
            await h.finish()
        }

        // --no-confirm: the client's own approval is the gate.
        let trusting = try MCPHarness(MCPConfiguration(allowActivate: true, noConfirm: true))
        _ = try await trusting.initialize(elicitation: false)
        trusting.call(1, "activate_roles", reader)
        let done = try await trusting.next()
        #expect(done["method"] == nil, "asked although the client cannot answer")
        #expect(!done.isToolError)
        #expect(trusting.methods.writes == 1)
        #expect(trusting.mcpHistory.count == 1)
        await trusting.finish()

        // --no-confirm never skips asking a client that can.
        let (asking, ask, _) = try await legacyActivation(answer: ["action": "decline"], config: MCPConfiguration(allowActivate: true, noConfirm: true))
        #expect(ask["method"] == "elicitation/create")
        #expect(asking.methods.writes == 0)
        await asking.finish()
    }

    @Test func statelessElicitationRoundTrip() async throws {
        let h = try MCPHarness(MCPConfiguration(allowActivate: true))
        let meta = MCPHarness.modernMeta()
        let first = try await h.request(1, "tools/call", ["_meta": meta, "name": "activate_roles", "arguments": reader])
        #expect(first["result"]?["resultType"] == "input_required")
        let input = first["result"]?["inputRequests"]?["pimento_confirm"]
        #expect(input?["method"] == "elicitation/create")
        #expect(input?["params"]?["message"]?.stringValue?.contains("Reader") == true)
        let state = first["result"]?["requestState"]
        #expect(state?.stringValue?.count == 64)
        #expect(h.methods.writes == 0)
        let yes: JSONValue = ["pimento_confirm": ["action": "accept", "content": ["confirm": true]]]

        // A forged state, or the right one for other arguments: asked again, nothing sent.
        let forged = try await h.request(2, "tools/call", ["_meta": meta, "name": "activate_roles", "arguments": reader,
                                                            "requestState": "00", "inputResponses": yes])
        #expect(forged["result"]?["resultType"] == "input_required")
        var other = reader.objectValue!
        other["hours"] = 1
        let mismatched = try await h.request(3, "tools/call", ["_meta": meta, "name": "activate_roles", "arguments": .object(other),
                                                                "requestState": state!, "inputResponses": yes])
        #expect(mismatched["result"]?["resultType"] == "input_required")
        // The state was used up by that attempt: it cannot be replayed.
        let replay = try await h.request(4, "tools/call", ["_meta": meta, "name": "activate_roles", "arguments": reader,
                                                            "requestState": state!, "inputResponses": yes])
        #expect(replay["result"]?["resultType"] == "input_required")
        #expect(h.methods.writes == 0)

        // A fresh state, declined.
        let fresh = replay["result"]?["requestState"]
        let declined = try await h.request(5, "tools/call", ["_meta": meta, "name": "activate_roles", "arguments": reader,
                                                              "requestState": fresh!, "inputResponses": ["pimento_confirm": ["action": "decline"]]])
        #expect(declined.isToolError)
        #expect(h.methods.writes == 0)

        // And accepted.
        let again = try await h.request(6, "tools/call", ["_meta": meta, "name": "activate_roles", "arguments": reader])
        let done = try await h.request(7, "tools/call", ["_meta": meta, "name": "activate_roles", "arguments": reader,
                                                          "requestState": again["result"]!["requestState"]!, "inputResponses": yes])
        #expect(done["result"]?["resultType"] == "complete")
        #expect(!done.isToolError)
        #expect(h.methods.writes == 1)
        #expect(h.mcpHistory.count == 1)
        await h.finish()
    }

    @Test func aConfirmationExpires() async throws {
        let h = try MCPHarness(MCPConfiguration(allowActivate: true))
        let meta = MCPHarness.modernMeta()
        let first = try await h.request(1, "tools/call", ["_meta": meta, "name": "activate_roles", "arguments": reader])
        h.clock.advance(by: 11 * 60)
        let late = try await h.request(2, "tools/call", ["_meta": meta, "name": "activate_roles", "arguments": reader,
                                                          "requestState": first["result"]!["requestState"]!,
                                                          "inputResponses": ["pimento_confirm": ["action": "accept", "content": ["confirm": true]]]])
        #expect(late["result"]?["resultType"] == "input_required")
        #expect(h.methods.writes == 0)
        await h.finish()
    }

    static let owner: JSONValue = ["roles": [["role": "Owner", "scope": "Contoso Staging"]], "justification": "Rotate the TLS certificate"]

    @Test func highPrivilegeRolesNeedTheirOwnOptIn() async throws {
        // Refused before the user is even asked.
        let h = try MCPHarness(MCPConfiguration(allowActivate: true))
        _ = try await h.initialize()
        h.call(1, "activate_roles", Self.owner)
        let refused = try await h.next()
        #expect(refused.isToolError)
        #expect(refused.toolText.contains("--allow-privileged"))
        // Also inside a mixed request, and for User Access Administrator.
        h.call(2, "activate_roles", ["roles": [["role": "Reader", "scope": "Contoso Production"],
                                               ["role": "User Access Administrator", "scope": "Contoso Production"]],
                                     "justification": "x", "ticket_number": "CHG-1", "ticket_system": "ServiceNow"])
        #expect(try await h.next().toolText.contains("User Access Administrator"))
        #expect(h.methods.writes == 0)
        await h.finish()

        // Allowed: the user must also tick the high-privilege box.
        let config = MCPConfiguration(allowActivate: true, allowPrivileged: true)
        let (half, ask, result) = try await legacyActivation(answer: ["action": "accept", "content": ["confirm": true]], config: config, args: Self.owner)
        #expect(ask["params"]?["requestedSchema"]?["required"] == ["confirm", "confirm_high_privilege"])
        #expect(ask["params"]?["message"]?.stringValue?.contains("[HIGH PRIVILEGE]") == true)
        #expect(result.isToolError)
        #expect(half.methods.writes == 0)
        await half.finish()

        let (full, _, ok) = try await legacyActivation(
            answer: ["action": "accept", "content": ["confirm": true, "confirm_high_privilege": true]], config: config, args: Self.owner)
        #expect(!ok.isToolError)
        #expect(ok["result"]?["structuredContent"]?["results"]?[0]?["role"]?["highPrivilege"] == true)
        #expect(full.methods.writes == 1)
        await full.finish()
    }

    @Test func ticketsAreRequiredWhereThePolicySaysSo() async throws {
        let h = try MCPHarness(MCPConfiguration(allowActivate: true))
        _ = try await h.initialize()
        let base: [String: JSONValue] = ["roles": [["role": "Contributor", "scope": "rg-contoso-data-prod"]], "justification": "Fix the pipeline"]
        h.call(1, "activate_roles", .object(base))
        let refused = try await h.next()
        #expect(refused.isToolError)
        #expect(refused.toolText.contains("requires a ticket"))
        var withTicket = base
        withTicket["ticket_number"] = "CHG-1001"
        withTicket["ticket_system"] = "ServiceNow"
        h.call(2, "activate_roles", .object(withTicket))
        let ask = try await h.next()
        #expect(ask["params"]?["message"]?.stringValue?.contains("CHG-1001 (ServiceNow)") == true)
        h.send(["jsonrpc": "2.0", "id": ask["id"]!, "result": ["action": "accept", "content": ["confirm": true]]])
        let accepted = try await h.next()
        #expect(!accepted.isToolError)
        #expect(h.mcpHistory.first?.ticketNumber == "CHG-1001")
        await h.finish()
    }

    @Test func ambiguousNamesAndAlreadyActiveRoles() async throws {
        let h = try MCPHarness(MCPConfiguration(allowActivate: true, noConfirm: true))
        _ = try await h.initialize(elicitation: false)
        // Contributor on Contoso Development is active: skipped, nothing sent.
        h.call(1, "activate_roles", ["roles": [["role": "Contributor", "scope": "Contoso Development"]], "justification": "x"])
        let skipped = try await h.next()
        #expect(!skipped.isToolError)
        #expect(skipped["result"]?["structuredContent"]?["summary"]?["skipped"] == 1)
        #expect(h.methods.writes == 0)
        // By ARM scope works as well as by name.
        let roles = try await h.session.makeService(tokens: h.session.azureCLITokens(tenantId: nil), readOnly: true).loadRoles().roles
        let scope = roles.first { $0.roleName == "Reader" && $0.scopeName == "Contoso Production" }!.scope
        h.call(2, "activate_roles", ["roles": [["role": "reader", "scope": .string(scope.uppercased() + "/")]], "justification": "x", "hours": 1])
        let byScope = try await h.next()
        #expect(byScope["result"]?["structuredContent"]?["results"]?[0]?["duration"] == "PT1H")
        #expect(h.methods.writes == 1)
        await h.finish()
    }

    @Test func deactivateAndRenewAreConfirmedToo() async throws {
        let h = try MCPHarness(MCPConfiguration(allowActivate: true))
        _ = try await h.initialize()
        let dev: JSONValue = ["roles": [["role": "Contributor", "scope": "Contoso Development"]], "justification": "Load test done"]
        h.call(1, "renew_roles", dev)
        let askRenew = try await h.next()
        #expect(askRenew["params"]?["message"]?.stringValue?.contains("RENEW") == true)
        h.send(["jsonrpc": "2.0", "id": askRenew["id"]!, "result": ["action": "accept", "content": ["confirm": true]]])
        let renewed = try await h.next()
        #expect(renewed["result"]?["structuredContent"]?["summary"]?["renewed"] == 1, "\(renewed.toolText)")

        h.clock.advance(by: 10 * 60)
        h.call(2, "deactivate_roles", ["roles": [["role": "Contributor", "scope": "Contoso Development"]]])
        let askEnd = try await h.next()
        #expect(askEnd["params"]?["message"]?.stringValue?.contains("DEACTIVATE") == true)
        h.send(["jsonrpc": "2.0", "id": askEnd["id"]!, "result": ["action": "accept", "content": ["confirm": true]]])
        let ended = try await h.next()
        #expect(ended["result"]?["structuredContent"]?["summary"]?["deactivated"] == 1, "\(ended.toolText)")
        #expect(Set(h.mcpHistory.map(\.action)) == [.renew, .deactivate])
        await h.finish()
    }

    @Test func presetsCanBeActivated() async throws {
        let h = try MCPHarness(MCPConfiguration(allowActivate: true, allowPrivileged: true, noConfirm: true))
        _ = try await h.initialize(elicitation: false)
        h.call(1, "activate_roles", ["preset": "Release day", "justification": "Release 2026.11"])
        let r = try await h.next()
        #expect(r["result"]?["structuredContent"]?["preset"] == "Release day", "\(r.toolText)")
        await h.finish()
    }

    @Test func errorsNeverShowFilePaths() async throws {
        let broken = TestTemp.url("broken-presets").appendingPathComponent("presets.json")
        try FileManager.default.createDirectory(at: broken.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{ not json".utf8).write(to: broken)
        let h = try MCPHarness(MCPConfiguration(allowActivate: true), presets: PresetStore(url: broken))
        _ = try await h.initialize()
        h.call(1, "list_presets", [:])
        let r = try await h.next()
        #expect(r.isToolError)
        #expect(!r.toolText.contains(broken.deletingLastPathComponent().path))
        h.call(2, "activate_roles", ["preset": "On-call", "justification": "x"])
        let w = try await h.next()
        #expect(w.isToolError)
        #expect(!w.toolText.contains(TestTemp.root.path))
        await h.finish()
    }

    // MARK: Review: TOCTOU, display, cancellation

    static let twoReaders: JSONValue = ["roles": [["role": "Reader", "scope": "Contoso Production"], ["role": "Reader", "scope": "Contoso Root"]],
                                        "justification": "INC-1234 read the logs"]

    @Test func aPlanThatChangesWhileTheUserDecidesIsNotSent() async throws {
        let h = try MCPHarness(MCPConfiguration(allowActivate: true))
        _ = try await h.initialize()
        h.call(1, "activate_roles", Self.twoReaders)
        let ask = try await h.next()
        #expect(ask["method"] == "elicitation/create")
        // Meanwhile one role is activated elsewhere (the app, the CLI): the plan the user saw is stale.
        try await h.activateElsewhere(role: "Reader", scopeName: "Contoso Root")
        h.send(["jsonrpc": "2.0", "id": ask["id"]!, "result": ["action": "accept", "content": ["confirm": true]]])
        let result = try await h.next()
        #expect(result.isToolError)
        #expect(result.toolText.contains("changed while the user was deciding"), "\(result.toolText)")
        #expect(h.methods.writes == 0)
        #expect(h.mcpHistory.isEmpty)
        await h.finish()
    }

    @Test func aStatelessConfirmationOfAStalePlanIsNotSent() async throws {
        let h = try MCPHarness(MCPConfiguration(allowActivate: true))
        let meta = MCPHarness.modernMeta()
        let first = try await h.request(1, "tools/call", ["_meta": meta, "name": "activate_roles", "arguments": Self.twoReaders])
        let state = try #require(first["result"]?["requestState"])
        try await h.activateElsewhere(role: "Reader", scopeName: "Contoso Root")
        let late = try await h.request(2, "tools/call", ["_meta": meta, "name": "activate_roles", "arguments": Self.twoReaders, "requestState": state,
                                                          "inputResponses": ["pimento_confirm": ["action": "accept", "content": ["confirm": true]]]])
        #expect(late.isToolError)
        #expect(late.toolText.contains("changed after the user confirmed"), "\(late.toolText)")
        #expect(h.methods.writes == 0)
        await h.finish()
    }

    @Test func theConfirmationNamesTheExactScope() async throws {
        // Display names are not unique (rg-app in a dev and a prod subscription):
        // the user must see which scope the agent picked.
        let (h, ask, _) = try await legacyActivation(answer: ["action": "decline"])
        let scope = try await h.session.makeService(tokens: h.session.azureCLITokens(tenantId: nil), readOnly: true).loadRoles().roles
            .first { $0.roleName == "Reader" && $0.scopeName == "Contoso Production" }!.scope
        #expect(ask["params"]?["message"]?.stringValue?.contains(scope) == true, "\(ask["params"]?["message"]?.stringValue ?? "")")
        await h.finish()
    }

    @Test func invisibleFillerCharactersAreRefused() async throws {
        let h = try MCPHarness(MCPConfiguration(allowActivate: true))
        _ = try await h.initialize()
        for (n, filler) in ["\u{3164}\u{3164}", "\u{115F}", "\u{1160}", "\u{FFA0}", "\u{2800}\u{2800}"].enumerated() {
            h.call(n + 1, "activate_roles", ["roles": [["role": "Reader", "scope": "Contoso Production"]], "justification": .string(filler)])
            let r = try await h.next()
            #expect(r.isToolError)
            #expect(r.toolText.contains("not allowed"), "\(r.toolText)")
        }
        #expect(h.methods.writes == 0)
        await h.finish()
    }

    /// `visible` followed by `bytes`, each as an invisible variation selector
    /// (U+FE00-U+FE0F, U+E0100-U+E01EF): one scalar per byte that adds no
    /// character and renders as nothing.
    static func hidden(_ visible: String, bytes: [UInt8]) -> String {
        var s = String.UnicodeScalarView(visible.unicodeScalars)
        for b in bytes { s.append(Unicode.Scalar(b < 16 ? 0xFE00 + UInt32(b) : 0xE0100 + UInt32(b) - 16)!) }
        return String(s)
    }

    @Test func aPayloadHiddenInVariationSelectorsIsRefused() async throws {
        let payload = Self.hidden("INC-1234 read the logs", bytes: Array("V1-DUMMY-SECRET-42 fabrikam.example".utf8) + Array(repeating: 0x41, count: 3000))
        #expect(payload.count == 22)
        #expect(payload.unicodeScalars.count == 3057)
        let h = try MCPHarness(MCPConfiguration(allowActivate: true))
        _ = try await h.initialize()
        h.call(1, "activate_roles", ["roles": [["role": "Reader", "scope": "Contoso Production"]], "justification": .string(payload)])
        let r = try await h.next()
        #expect(r.isToolError)
        #expect(r.toolText.contains("too long"), "\(r.toolText)")
        // Shorter, it is refused for what it hides.
        h.call(2, "activate_roles", ["roles": [["role": "Reader", "scope": "Contoso Production"]],
                                     "justification": .string(Self.hidden("INC-1234 read the logs", bytes: Array("V1-DUMMY-SECRET-42".utf8)))])
        let short = try await h.next()
        #expect(short.isToolError)
        #expect(short.toolText.contains("invisible character, which is not allowed"), "\(short.toolText)")
        h.call(3, "activate_roles", ["roles": [["role": "Reader", "scope": "Contoso Production"]], "justification": "x",
                                     "ticket_number": .string(Self.hidden("INC-1", bytes: [1, 2, 3]))])
        #expect(try await h.next().isToolError)
        #expect(h.methods.writes == 0)
        #expect(h.mcpHistory.isEmpty)
        await h.finish()
    }

    @Test func everyAgentStringRefusesInvisibleCharactersButKeepsEmojiAndScripts() throws {
        let fields = MCPToolbox.writeTools.first { $0.name == "activate_roles" }!.fields
        func refused(_ key: String, _ value: String) -> Bool {
            var args: [String: JSONValue] = ["roles": [["role": "Reader", "scope": "Contoso Production"]], "justification": "x"]
            if key == "preset" { args["roles"] = nil }
            if key == "role" || key == "scope" {
                args["roles"] = [["role": key == "role" ? .string(value) : "Reader", "scope": key == "scope" ? .string(value) : "Contoso Production"]]
            } else {
                args[key] = .string(value)
            }
            return (try? MCPSchema.validate(.object(args), fields)) == nil
        }
        // 500 characters of Hindi: more scalars than characters.
        let hindi = String(String(repeating: "आज रात सर्वर की जाँच करनी है ", count: 30).prefix(500))
        #expect(hindi.count == 500)
        #expect(hindi.unicodeScalars.count > 600)
        #expect(!refused("justification", hindi))
        let fine = ["⚠️ disk full", "✔️ approved", "1️⃣ first", "#️⃣7", "❤️", "☺︎", "🇩🇪 Frankfurt", "👍🏽", "Tiếng Việt", "தமிழ்", "ภาษาไทย", "العربية"]
        for key in ["justification", "ticket_number", "ticket_system", "preset", "role", "scope"] {
            for text in fine { #expect(!refused(key, text), "\(key): \(text)") }
            let hiddenTexts = [
                "a\u{FE0F}", "\u{FE0F}", "⚠\u{FE0F}\u{FE0F}", "1\u{FE0F}", "1\u{FE0F}x", "ok\u{FE00}", "ok\u{E0100}", "ok\u{E01EF}",
                "ok\u{180B}", "ok\u{180F}", "ok\u{2065}", "ok\u{FFF0}", "ok\u{E0000}", "ok\u{E0FFF}", Self.hidden("INC-1", bytes: [7]),
            ]
            for text in hiddenTexts { #expect(refused(key, text), "\(key): \(text.unicodeScalars.map { String($0.value, radix: 16) })") }
        }
        // Stacked combining marks count against the length too.
        #expect(refused("ticket_number", "a" + String(repeating: "\u{0301}", count: 400)))
        #expect(!refused("ticket_number", "a" + String(repeating: "\u{0301}", count: 398)))
    }

    @Test func theConfirmationShowsInvisibleCharactersAsEscapes() {
        #expect(MCPText.clip("ok\u{FE00}x", 40) == "ok\\u{FE00}x")
        #expect(MCPText.clip("a\u{FE0F}", 40) == "a\\u{FE0F}")
        #expect(MCPText.clip("⚠️ 1️⃣", 40) == "⚠️ 1️⃣")
        #expect(MCPText.clip("नमस्ते", 40) == "नमस्ते")
    }

    @Test func aConfirmationIsBoundToTheAccount() {
        func plan(_ objectId: String) -> MCPWritePlan {
            MCPWritePlan(kind: .activate, tenantArgument: nil, tenantId: "t", user: Identity(objectId: objectId, name: nil, upn: nil, tenantId: "t"),
                         justification: "x", ticket: nil, requested: .hours(1), preset: nil)
        }
        #expect(plan("a").fingerprint == plan("A").fingerprint)
        #expect(plan("a").fingerprint != plan("b").fingerprint)
    }

    @Test func theConfirmationSaysWhichRolesAKeepAlivePresetRenews() throws {
        let reader = try Fixture.role("Contoso Production", "Reader")
        let staging = try Fixture.role("Contoso Staging", "Contributor")
        var kept = Preset(name: "On-call", tenantId: nil, roles: [PresetRole(reader)])
        kept.keepAlive = true
        let notKept = Preset(name: "Other", tenantId: nil, roles: [PresetRole(staging)])
        let notes = MCPToolbox.keepAliveNotes([reader, staging], presets: [kept, notKept])
        #expect(notes.count == 1)
        #expect(notes.first?.contains("Reader on Contoso Production is kept alive by the preset “On-call”") == true, "\(notes)")
        #expect(MCPToolbox.keepAliveNotes([staging], presets: [kept, notKept]).isEmpty)
    }

    @Test func aWriteCancelledWhileQueuedIsNotSent() async throws {
        // A legacy client holds the write gate with a confirmation on screen;
        // a second write (a stateless request the server may send unconfirmed,
        // --no-confirm) waits behind it and is cancelled meanwhile.
        let h = try MCPHarness(MCPConfiguration(allowActivate: true, noConfirm: true))
        _ = try await h.initialize()
        h.call(1, "activate_roles", reader)
        let ask = try await h.next()
        #expect(ask["method"] == "elicitation/create")
        h.send(["jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": [
            "_meta": MCPHarness.modernMeta(elicitation: false), "name": "activate_roles",
            "arguments": ["roles": [["role": "Reader", "scope": "Contoso Root"]], "justification": "x"]]])
        try await Task.sleep(nanoseconds: 50_000_000)
        h.send(["jsonrpc": "2.0", "method": "notifications/cancelled", "params": ["requestId": 2]])
        try await Task.sleep(nanoseconds: 50_000_000)
        h.send(["jsonrpc": "2.0", "id": ask["id"]!, "result": ["action": "decline"]])
        #expect(try await h.next().isToolError)
        try await h.expectSilence()
        #expect(h.methods.writes == 0)
        #expect(h.mcpHistory.isEmpty)
        await h.finish()
    }
}

extension MCPHarness {
    /// Activates a role directly on the simulator, not through the server.
    func activateElsewhere(role: String, scopeName: String) async throws {
        let service = session.makeService(tokens: session.azureCLITokens(tenantId: nil))
        let snapshot = try await service.loadRoles()
        let row = try #require(snapshot.roles.first { $0.roleName == role && $0.scopeName == scopeName })
        let plans = try ActivationPlanning.activationPlans(
            [row], policies: [:], principalId: snapshot.identity.objectId, justification: "elsewhere", requested: .hours(1), ticket: nil, now: clock.now())
        try await service.execute(plans) { _, _ in }
    }
}

// MARK: - CLI and end to end

/// stdin for an in-process `pimento mcp`: lines handed over one by one.
final class LineQueue: @unchecked Sendable {
    private let condition = NSCondition()
    private var lines: [String] = []
    private var closed = false

    func push(_ line: String) {
        condition.lock()
        lines.append(line)
        condition.signal()
        condition.unlock()
    }

    func close() {
        condition.lock()
        closed = true
        condition.broadcast()
        condition.unlock()
    }

    func pop() -> String? {
        condition.lock()
        defer { condition.unlock() }
        while lines.isEmpty && !closed { condition.wait() }
        return lines.isEmpty ? nil : lines.removeFirst()
    }
}

@Suite("MCP: pimento mcp")
struct MCPCommandTests {
    @Test func parsesItsOptions() throws {
        #expect(try CLIParser.parse(["mcp"]).command == .mcp(MCPOptions()))
        guard case .mcp(let o) = try CLIParser.parse(["mcp", "--allow-activate", "--allow-privileged", "--no-confirm", "--tenant", "contoso.onmicrosoft.com"]).command else {
            Issue.record("expected mcp")
            return
        }
        #expect(o.allowActivate && o.allowPrivileged && o.noConfirm)
        #expect(o.tenant == "contoso.onmicrosoft.com")
        #expect(throws: CLIParseError.requiresAllowActivate("--allow-privileged")) { try CLIParser.parse(["mcp", "--allow-privileged"]) }
        #expect(throws: CLIParseError.requiresAllowActivate("--no-confirm")) { try CLIParser.parse(["mcp", "--no-confirm"]) }
        #expect(throws: TenantError.invalid("-x")) { try CLIParser.parse(["mcp", "--tenant=-x"]) }
        #expect(throws: CLIParseError.self) { try CLIParser.parse(["mcp", "--yes"]) }
        #expect(throws: CLIParseError.self) { try CLIParser.parse(["mcp", "extra"]) }
        #expect(CLIHelp.text(for: "mcp").contains("--allow-activate"))
        for shell in CompletionShell.allCases { #expect(CLIHelp.completionScript(for: shell).contains("allow-activate")) }
    }

    /// `pimento mcp --demo --allow-activate` through the CLI runner, stdin and
    /// stdout in memory: a whole session, isolated from the real environment.
    @Test func aWholeDemoSessionThroughTheCLI() async throws {
        let cli = DemoCLIRun()
        let input = LineQueue()
        let out = cli.out
        var env = cli.environment
        env.readLine = { input.pop() }
        let monitor = cli.monitor
        let run = Task { await NetworkGuard.$monitor.withValue(monitor) { await CLIRunner(environment: env).run(["mcp", "--demo", "--allow-activate"]) } }

        func send(_ v: JSONValue) { input.push(v.serialized) }
        var seen = 0
        func next() async throws -> JSONValue {
            for _ in 0..<1000 {
                let lines = (out.value ?? "").split(separator: "\n", omittingEmptySubsequences: true)
                if lines.count > seen {
                    seen += 1
                    return try JSONValue.parse(String(lines[seen - 1]))
                }
                try await Task.sleep(nanoseconds: 5_000_000)
            }
            throw CancellationError()
        }

        send(["jsonrpc": "2.0", "id": 1, "method": "initialize",
              "params": ["protocolVersion": "2025-11-25", "capabilities": ["elicitation": [:]], "clientInfo": ["name": "t", "version": "1"]]])
        #expect(try await next()["result"]?["instructions"]?.stringValue?.contains("Demo mode") == true)
        send(["jsonrpc": "2.0", "method": "notifications/initialized"])
        send(["jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": ["name": "activate_roles", "arguments": reader]])
        let ask = try await next()
        #expect(ask["method"] == "elicitation/create")
        send(["jsonrpc": "2.0", "id": ask["id"]!, "result": ["action": "accept", "content": ["confirm": true]]])
        let done = try await next()
        #expect(done["result"]?["structuredContent"]?["summary"]?["activated"] == 1, "\(done.toolText)")
        send(["jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": ["name": "get_history", "arguments": ["limit": 1]]])
        #expect(try await next()["result"]?["structuredContent"]?["records"]?[0]?["source"] == "mcp")
        input.close()
        #expect(await run.value == 0)
        // Only MCP messages on stdout; the note went to stderr.
        for line in (out.value ?? "").split(separator: "\n") { #expect((try? JSONValue.parse(String(line))) != nil) }
        #expect(cli.stderr.contains("pimento mcp"))
        cli.expectIsolated()
    }

    /// The built `pimento` binary, over real pipes.
    @Test func theBuiltBinaryServesOverPipes() throws {
        #if os(Windows)
        let name = "pimento.exe"
        #else
        let name = "pimento"
        #endif
        // The products folder: next to the resource bundle, or a few levels
        // up from it (inside the .xctest bundle on macOS).
        var folder = Bundle.module.bundleURL.deletingLastPathComponent()
        var found: URL?
        for _ in 0..<5 {
            let candidate = folder.appendingPathComponent(name)
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDirectory), !isDirectory.boolValue,
               FileManager.default.isExecutableFile(atPath: candidate.path) {
                found = candidate
                break
            }
            folder = folder.deletingLastPathComponent()
        }
        guard let binary = found else {
            // `swift test` builds it; a test runner that does not is told so.
            Issue.record("no \(name) binary near \(Bundle.module.bundleURL.path)")
            return
        }
        let process = Process()
        process.executableURL = binary
        process.arguments = ["mcp", "--demo"]
        var environment = ProcessInfo.processInfo.environment
        environment[DemoMode.clockVariable] = "10:30"
        environment[DemoMode.environmentVariable] = nil
        process.environment = environment
        let stdin = Pipe(), stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        try process.run()
        let meta = MCPHarness.modernMeta()
        let messages: [JSONValue] = [
            ["jsonrpc": "2.0", "id": 1, "method": "server/discover", "params": ["_meta": meta]],
            ["jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": ["_meta": meta, "name": "list_active_roles", "arguments": [:]]],
            ["jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": ["_meta": meta, "name": "activate_roles", "arguments": reader]],
        ]
        // Also: a CRLF line, and a line over the 1 MB limit, refused without ending the session.
        var input = messages.map { $0.serialized + "\n" }.joined()
        input += String(repeating: " ", count: 2_000_000) + "\n"
        input += (["jsonrpc": "2.0", "id": 4, "method": "ping"] as JSONValue).serialized + "\r\n"
        stdin.fileHandleForWriting.write(Data(input.utf8))
        try stdin.fileHandleForWriting.close()
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        let replies = String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline).compactMap { try? JSONValue.parse(String($0)) }
        let byId = Dictionary(replies.compactMap { r in r["id"].map { ($0, r) } }, uniquingKeysWith: { a, _ in a })
        #expect(byId[1]?["result"]?["supportedVersions"]?.arrayValue?.first == "2026-07-28")
        #expect(byId[2]?["result"]?["structuredContent"]?["count"] == 3)
        // Read-only: the write tool does not exist.
        #expect(byId[3]?.errorCode == -32602)
        #expect(byId[.null]?["error"]?["message"] == "Message too large")
        #expect(byId[4]?["result"] == [:])
    }
}

@Suite("MCP: bounded stdin")
struct MCPLineReaderTests {
    /// A read(2) over `data`, `chunk` bytes at a time.
    static func reader(_ data: [UInt8], limit: Int = 1000, chunk: Int) -> MCPLineReader {
        let box = ByteSource(data)
        return MCPLineReader(limit: limit, chunkSize: 4096) { buffer, count in box.read(into: buffer, max: min(count, chunk)) }
    }

    static func all(_ r: MCPLineReader) -> [MCPInputLine] {
        var out: [MCPInputLine] = []
        while let line = r.next() { out.append(line) }
        return out
    }

    @Test func linesAreWhatReadLineReturns() {
        let cases: [(String, [String])] = [
            ("", []), ("\n", [""]), ("a", ["a"]), ("a\n", ["a"]), ("a\r\n", ["a"]), ("a\r", ["a\r"]), ("a\r\r\n", ["a\r"]),
            ("a\n\nb", ["a", "", "b"]), ("\r\n\r\n", ["", ""]), ("é😀\n{\"x\":1}\r\n", ["é😀", "{\"x\":1}"]),
        ]
        for (input, expected) in cases {
            for chunk in [1, 2, 3, 7, 4096] {
                #expect(Self.all(Self.reader(Array(input.utf8), chunk: chunk)) == expected.map(MCPInputLine.line), "\(input.debugDescription) by \(chunk)")
            }
        }
        // Invalid UTF-8 is repaired, as readLine does.
        #expect(Self.all(Self.reader([0x61, 0xFF, 0x0A], chunk: 1)) == [.line("a\u{FFFD}")])
    }

    @Test func overlongLinesAreRefusedAndTheNextLineIsRead() {
        for chunk in [1, 3, 4096] {
            let input = Array("abcd\nabcde\nabcd\r\nlonger than four\nok\nabcd\r".utf8)
            #expect(Self.all(Self.reader(input, limit: 4, chunk: chunk)) == [.line("abcd"), .tooLong, .line("abcd"), .tooLong, .line("ok"), .tooLong])
        }
    }

    @Test func anOverlongLineIsNeverHeldInFull() {
        // 20 MB without a newline, then a message: at most the limit (and a "\r") is held.
        let source = ByteSource(Array(repeating: UInt8(ascii: " "), count: 20_000_000) + Array("\n{}\n".utf8))
        let reader = MCPLineReader(limit: 1000) { buffer, count in source.read(into: buffer, max: count) }
        #expect(Self.all(reader) == [.tooLong, .line("{}")])
        #expect(reader.peakLineBytes <= 1001)
    }

    @Test func theServerRefusesWhatTheReaderRefused() async throws {
        let output = LineCollector()
        let server = MCPServer(config: MCPConfiguration(), tools: MCPToolbox(backend: MCPBackend(
            service: { _, _ in fatalError() }, tenants: { _ in [] }, resolveTenant: { $0 }, presets: PresetStore(url: TestTemp.url("none.json")),
            history: nil, now: { Date() }, timeZone: .current)), send: { output.add($0) })
        await server.run(input: AsyncStream { c in
            c.yield(.tooLong)
            c.yield(.line(#"{"jsonrpc":"2.0","id":1,"method":"ping"}"#))
            c.finish()
        })
        let replies = try output.all.map(JSONValue.parse)
        #expect(replies.count == 2)
        #expect(replies.first?["error"]?["message"] == "Message too large")
        #expect(replies.last?["id"] == 1)
    }
}

/// Bytes handed out like read(2) would.
final class ByteSource: @unchecked Sendable {
    private let bytes: [UInt8]
    private var offset = 0
    init(_ bytes: [UInt8]) { self.bytes = bytes }
    func read(into buffer: UnsafeMutableRawPointer, max: Int) -> Int {
        let n = Swift.min(max, bytes.count - offset)
        guard n > 0 else { return 0 }
        bytes.withUnsafeBytes { buffer.copyMemory(from: $0.baseAddress! + offset, byteCount: n) }
        offset += n
        return n
    }
}
