import Foundation

/// How `pimento mcp` was started. Everything that widens what an agent can do
/// is off unless the human who configured the server turned it on.
public struct MCPConfiguration: Equatable, Sendable {
    /// `--allow-activate`: list and accept the write tools (activate,
    /// deactivate, renew). Off: read-only, by construction (every service
    /// the read tools use refuses anything but GET).
    public var allowActivate = false
    /// `--allow-privileged`: also activate or renew roles that can grant
    /// access to anyone (Owner, User Access Administrator, Role Based Access
    /// Control Administrator).
    public var allowPrivileged = false
    /// `--no-confirm`: when the client cannot ask its user (no form
    /// elicitation), write anyway, relying on the client's own tool approval.
    /// When the client can ask, the server always asks.
    public var noConfirm = false
    /// `--tenant`: the only tenant tool calls may use.
    public var tenant: String?
    /// Demo mode (`--demo`): said in the server's instructions.
    public var demo = false
    /// How long the server waits for the human's answer to a confirmation.
    public var confirmationTimeout: TimeInterval = 10 * 60
    /// How long a confirmation handed out on the stateless revision stays valid.
    public var confirmationTTL: TimeInterval = 10 * 60
    /// Tool calls allowed per minute: reads (they reach Azure) and writes.
    public var readsPerMinute = 120
    public var writesPerMinute = 12

    public init(allowActivate: Bool = false, allowPrivileged: Bool = false, noConfirm: Bool = false, tenant: String? = nil, demo: Bool = false) {
        self.allowActivate = allowActivate
        self.allowPrivileged = allowPrivileged
        self.noConfirm = noConfirm
        self.tenant = tenant
        self.demo = demo
    }
}

/// The MCP server: JSON-RPC over newline-delimited messages (the stdio
/// transport). `run(lines:)` reads until the input ends; every message the
/// server sends goes through `send`, one line each.
public final class MCPServer: @unchecked Sendable {
    let config: MCPConfiguration
    let tools: MCPToolbox
    let sendLine: @Sendable (String) -> Void
    let log: @Sendable (String) -> Void
    let clock: @Sendable () -> Date

    private let lock = NSLock()
    /// The handshake-based session, after `initialize`.
    private var legacy: (version: String, capabilities: JSONValue)?
    /// Requests the server sent (elicitation) and who waits for the answer.
    private var outgoing: [String: CheckedContinuation<JSONValue?, Never>] = [:]
    private var nextOutgoing = 1
    /// In-flight client requests, by id, so `notifications/cancelled` can stop them.
    private var inFlight: [JSONValue: Task<Void, Never>] = [:]
    private var cancelled: Set<JSONValue> = []
    private var finished = false
    private let writeLock = NSLock()

    let confirmations: MCPConfirmationStore
    let writeGate = MCPAsyncGate()
    let readLimiter: MCPRateLimiter
    let writeLimiter: MCPRateLimiter

    public init(config: MCPConfiguration, tools: MCPToolbox, clock: @escaping @Sendable () -> Date = { Date() },
                send: @escaping @Sendable (String) -> Void, log: @escaping @Sendable (String) -> Void = { _ in }) {
        self.config = config
        self.tools = tools
        self.clock = clock
        sendLine = send
        self.log = log
        confirmations = MCPConfirmationStore(ttl: config.confirmationTTL, clock: clock)
        readLimiter = MCPRateLimiter(perMinute: config.readsPerMinute, clock: clock)
        writeLimiter = MCPRateLimiter(perMinute: config.writesPerMinute, clock: clock)
    }

    /// Serves until `lines` ends, then lets the requests in flight finish
    /// (a write that was sent is recorded in the history) and returns.
    public func run(lines: AsyncStream<String>) async {
        await run(input: AsyncStream { continuation in
            Task {
                for await line in lines { continuation.yield(.line(line)) }
                continuation.finish()
            }
        })
    }

    /// `run(lines:)` for a reader that refuses overlong lines itself
    /// (`MCPLineReader`), so that they are never held in full.
    public func run(input: AsyncStream<MCPInputLine>) async {
        await withTaskGroup(of: Void.self) { group in
            for await item in input {
                guard case .line(let line) = item else {
                    send(["jsonrpc": "2.0", "id": .null, "error": RPCError(code: MCP.Code.invalidRequest, message: "Message too large").json])
                    continue
                }
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty { continue }
                guard trimmed.utf8.count <= MCP.maxMessageBytes else {
                    send(["jsonrpc": "2.0", "id": .null, "error": RPCError(code: MCP.Code.invalidRequest, message: "Message too large").json])
                    continue
                }
                if let task = receive(trimmed) { group.addTask { await task.value } }
            }
            // End of input: nobody can answer a confirmation any more.
            lock.withLock { finished = true }
            for (_, continuation) in takeAllOutgoing() { continuation.resume(returning: nil) }
            await group.waitForAll()
        }
    }

    // MARK: Messages

    func send(_ message: JSONValue) {
        let line = message.serialized
        writeLock.withLock { sendLine(line) }
    }

    func respond(_ id: JSONValue, result: JSONValue) {
        send(["jsonrpc": "2.0", "id": id, "result": result])
    }

    func respond(_ id: JSONValue, error: RPCError) {
        send(["jsonrpc": "2.0", "id": id, "error": error.json])
    }

    /// Handles one message; a request runs in a task of its own (returned),
    /// so that answers to the server's own requests keep being read meanwhile.
    func receive(_ line: String) -> Task<Void, Never>? {
        let message: JSONValue
        do { message = try JSONValue.parse(line) } catch {
            send(["jsonrpc": "2.0", "id": .null, "error": RPCError(code: MCP.Code.parseError, message: "Parse error").json])
            return nil
        }
        guard case .object(let o) = message, o["jsonrpc"] == "2.0" else {
            // Batches are not part of MCP (since 2025-06-18).
            send(["jsonrpc": "2.0", "id": .null, "error": RPCError(code: MCP.Code.invalidRequest, message: "Invalid Request: expected one JSON-RPC 2.0 object").json])
            return nil
        }
        let id = o["id"]
        if let id, !Self.isValidId(id) {
            send(["jsonrpc": "2.0", "id": .null, "error": RPCError(code: MCP.Code.invalidRequest, message: "Invalid Request: id must be a string or an integer").json])
            return nil
        }
        guard let methodValue = o["method"] else {
            // A response to a request of the server's.
            if let id, o["result"] != nil || o["error"] != nil { resolveOutgoing(id, o["error"] == nil ? o["result"] : nil) }
            return nil
        }
        guard case .string(let method) = methodValue else {
            if let id { respond(id, error: RPCError(code: MCP.Code.invalidRequest, message: "Invalid Request: method must be a string")) }
            return nil
        }
        let params = o["params"] ?? .object([:])
        guard params.objectValue != nil else {
            if let id { respond(id, error: .invalidParams("params must be an object")) }
            return nil
        }
        guard let id else {
            notification(method, params)
            return nil
        }
        let task = Task { [self] in
            let outcome: Result<JSONValue, RPCError>
            do { outcome = .success(try await request(method, params, id: id)) } catch let e as RPCError {
                outcome = .failure(e)
            } catch {
                outcome = .failure(RPCError(code: MCP.Code.internalError, message: "Internal error"))
            }
            // A cancelled request gets no answer.
            let skip = lock.withLock { () -> Bool in
                inFlight[id] = nil
                return cancelled.remove(id) != nil
            }
            if skip { return }
            switch outcome {
            case .success(let result): respond(id, result: result)
            case .failure(let e): respond(id, error: e)
            }
        }
        lock.withLock { inFlight[id] = task }
        return task
    }

    static func isValidId(_ id: JSONValue) -> Bool {
        switch id {
        case .string, .int: true
        default: false
        }
    }

    func notification(_ method: String, _ params: JSONValue) {
        switch method {
        case "notifications/cancelled":
            guard let requestId = params["requestId"], Self.isValidId(requestId) else { return }
            let task = lock.withLock { () -> Task<Void, Never>? in
                guard let t = inFlight[requestId] else { return nil }
                cancelled.insert(requestId)
                return t
            }
            task?.cancel()
        default:
            // notifications/initialized and anything else: nothing to do.
            break
        }
    }

    // MARK: Requests

    func request(_ method: String, _ params: JSONValue, id: JSONValue) async throws -> JSONValue {
        if method == "initialize" { return try initialize(params) }
        if method == "ping" { return era(of: params).map { Self.complete([:], $0) } ?? [:] }
        guard let era = try resolveEra(params) else {
            throw RPCError.invalidParams("Missing _meta[\"\(MCP.Meta.protocolVersion)\"]. Send it with every request (protocol \(MCP.modernVersions[0])), or `initialize` first (\(MCP.legacyVersions.joined(separator: ", "))).")
        }
        switch method {
        case "server/discover":
            guard era.isModern else { throw RPCError.methodNotFound(method) }
            return Self.complete([
                "supportedVersions": .array(MCP.supportedVersions.map(JSONValue.string)),
                "capabilities": capabilities,
                "instructions": .string(instructions),
            ], era)
        case "tools/list":
            return Self.complete(["tools": .array(tools.definitions(config).map(\.json))], era)
        case "tools/call":
            return try await callTool(params, era: era, id: id)
        default:
            throw RPCError.methodNotFound(method)
        }
    }

    /// The era of a request: modern when it carries a protocol version in
    /// `_meta` (which must be one the server speaks), legacy after `initialize`,
    /// nil otherwise.
    func resolveEra(_ params: JSONValue) throws -> MCPEra? {
        if let meta = params["_meta"]?.objectValue, let raw = meta[MCP.Meta.protocolVersion] {
            guard case .string(let version) = raw, MCP.modernVersions.contains(version) else {
                throw RPCError(code: MCP.Code.unsupportedProtocolVersion, message: "Unsupported protocol version", data: [
                    "supported": .array(MCP.supportedVersions.map(JSONValue.string)),
                    "requested": raw.stringValue.map { .string(MCPText.clip($0, 64)) } ?? .string(raw.typeName),
                ])
            }
            guard let capabilities = meta[MCP.Meta.clientCapabilities], capabilities.objectValue != nil else {
                throw RPCError.invalidParams("Missing _meta[\"\(MCP.Meta.clientCapabilities)\"].")
            }
            return .modern(version: version, capabilities: capabilities)
        }
        return lock.withLock { legacy.map { .legacy(version: $0.version, capabilities: $0.capabilities) } }
    }

    /// `resolveEra` without throwing (ping).
    func era(of params: JSONValue) -> MCPEra? { (try? resolveEra(params)) ?? nil }

    /// A result: modern ones say they are complete and who answered.
    static func complete(_ fields: [String: JSONValue], _ era: MCPEra) -> JSONValue {
        var o = fields
        if era.isModern {
            o["resultType"] = "complete"
            var meta = o["_meta"]?.objectValue ?? [:]
            meta[MCP.Meta.serverInfo] = serverInfo
            o["_meta"] = .object(meta)
        }
        return .object(o)
    }

    static var serverInfo: JSONValue {
        ["name": .string(MCP.serverName), "title": "Pimento (Azure PIM)", "version": .string(AppInfo.version)]
    }

    var capabilities: JSONValue { ["tools": ["listChanged": false]] }

    var instructions: String {
        var parts = [
            "Pimento lists and activates the user's Azure PIM roles (Azure resource roles: management groups, subscriptions, resource groups, resources).",
            "Use list_eligible_roles to see what the user may activate (with each role's policy: maximum duration, approval, ticket), list_active_roles for what is active and until when.",
        ]
        if config.allowActivate {
            parts.append("activate_roles, deactivate_roles and renew_roles change roles. Name each role by its exact role name and scope (from list_eligible_roles), give the user's real reason as the justification, and expect the user to be asked to confirm. Never retry a declined or refused request on your own.")
        } else {
            parts.append("This server is read-only: it cannot activate, deactivate or renew roles.")
        }
        if config.demo { parts.append("Demo mode: a simulated Azure with synthetic data (Contoso); nothing real is read or changed.") }
        return parts.joined(separator: " ")
    }

    func initialize(_ params: JSONValue) throws -> JSONValue {
        let requested = params["protocolVersion"]?.stringValue ?? ""
        // The client's version if the server speaks it, else the newest legacy one.
        let version = MCP.legacyVersions.contains(requested) ? requested : MCP.legacyVersions[0]
        let capabilities = params["capabilities"].flatMap { $0.objectValue != nil ? $0 : nil } ?? .object([:])
        lock.withLock { legacy = (version, capabilities) }
        return [
            "protocolVersion": .string(version),
            "capabilities": self.capabilities,
            "serverInfo": Self.serverInfo,
            "instructions": .string(instructions),
        ]
    }

    // MARK: Server-to-client requests (handshake revisions)

    /// Sends `method` to the client and waits for the result: nil for an
    /// error, no answer within `timeout`, the end of input, or cancellation.
    func ask(_ method: String, _ params: JSONValue, timeout: TimeInterval) async -> JSONValue? {
        let id: String = lock.withLock {
            defer { nextOutgoing += 1 }
            return "pimento-\(nextOutgoing)"
        }
        let key = JSONValue.string(id)
        let timer = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(0, timeout) * 1_000_000_000))
            if !Task.isCancelled { self?.resolveOutgoing(key, nil) }
        }
        defer { timer.cancel() }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<JSONValue?, Never>) in
                let refuse = lock.withLock { () -> Bool in
                    if finished || Task.isCancelled { return true }
                    outgoing[id] = continuation
                    return false
                }
                if refuse {
                    continuation.resume(returning: nil)
                    return
                }
                send(["jsonrpc": "2.0", "id": key, "method": .string(method), "params": params])
            }
        } onCancel: {
            resolveOutgoing(key, nil)
        }
    }

    func resolveOutgoing(_ id: JSONValue, _ result: JSONValue?) {
        guard case .string(let key) = id else { return }
        let continuation = lock.withLock { outgoing.removeValue(forKey: key) }
        continuation?.resume(returning: result)
    }

    private func takeAllOutgoing() -> [String: CheckedContinuation<JSONValue?, Never>] {
        lock.withLock {
            let all = outgoing
            outgoing = [:]
            return all
        }
    }
}

// MARK: - Tool calls

extension MCPServer {
    func callTool(_ params: JSONValue, era: MCPEra, id: JSONValue) async throws -> JSONValue {
        guard case .string(let name)? = params["name"] else { throw RPCError.invalidParams("tools/call needs a tool name.") }
        let definitions = tools.definitions(config)
        guard let tool = definitions.first(where: { $0.name == name }) else {
            if MCPToolbox.writeToolNames.contains(name) {
                throw RPCError.invalidParams("Unknown tool: \(name). The server is read-only; it was not started with --allow-activate.")
            }
            throw RPCError.invalidParams("Unknown tool: \(MCPText.clip(name, 100))")
        }
        let arguments = params["arguments"] ?? .object([:])
        guard arguments.objectValue != nil else { throw RPCError.invalidParams("arguments must be an object.") }

        do {
            try MCPSchema.validate(arguments, tool.fields)
        } catch let e as MCPArgumentError {
            return toolResult(.failure("Invalid arguments: \(e.message)"), era)
        }
        // Calls that reach Azure (or the user) are limited.
        let limiter = tool.isWrite ? writeLimiter : readLimiter
        guard limiter.allow() else {
            return toolResult(.failure("Too many \(tool.isWrite ? "write" : "read") calls; try again in a minute."), era)
        }
        let args = MCPArguments(arguments)
        guard tool.isWrite else {
            return toolResult(await tools.read(name, args, config: config), era)
        }
        // One write at a time: one confirmation on screen, and each plan sees the previous write.
        return try await writeGate.run {
            try await self.write(tool, args, params: params, era: era)
        }
    }

    func toolResult(_ result: MCPToolResult, _ era: MCPEra) -> JSONValue {
        Self.complete(result.json.objectValue ?? [:], era)
    }

    /// A write: plan (read-only), confirm with the human, plan again, and send
    /// only when the plan is still exactly what was confirmed.
    func write(_ tool: MCPToolDefinition, _ args: MCPArguments, params: JSONValue, era: MCPEra) async throws -> JSONValue {
        let plan: MCPWritePlan
        switch await tools.prepare(tool.name, args, config: config) {
        case .failure(let result): return toolResult(result, era)
        case .success(let p): plan = p
        }
        if plan.isEmpty { return toolResult(await tools.execute(plan), era) }

        if era.canElicitForm {
            let request = MCPConfirmation.request(for: plan, withMode: era.isModern || era.version >= "2025-11-25")
            if era.isModern {
                // Stateless revision: ask through an InputRequiredResult; the
                // client retries the same call with the answer and our state.
                guard let state = params["requestState"]?.stringValue,
                      let confirmed = confirmations.take(state, tool: tool.name, arguments: args.canonical) else {
                    return inputRequired(plan, tool: tool.name, args: args, era: era)
                }
                guard let answer = params["inputResponses"]?[MCPConfirmation.inputKey] else {
                    return inputRequired(plan, tool: tool.name, args: args, era: era)
                }
                if let refusal = MCPConfirmation.refusal(answer, plan: plan) { return toolResult(refusal, era) }
                guard confirmed == plan.fingerprint else {
                    return toolResult(.failure("Nothing was sent: the roles or their policies changed after the user confirmed. Call the tool again to show the user the current plan."), era)
                }
                return await execute(plan, era)
            }
            // Handshake revisions: the server asks the client itself.
            let answer = await ask("elicitation/create", request, timeout: config.confirmationTimeout)
            guard let answer else {
                return toolResult(.failure("Nothing was sent: the user's confirmation did not arrive (dismissed, timed out or cancelled)."), era)
            }
            if let refusal = MCPConfirmation.refusal(answer, plan: plan) { return toolResult(refusal, era) }
            // The user may have taken a while: plan again from fresh data and
            // send only if it is still what they saw.
            let fresh: MCPWritePlan
            switch await tools.prepare(tool.name, args, config: config) {
            case .failure(let result): return toolResult(result, era)
            case .success(let p): fresh = p
            }
            guard fresh.fingerprint == plan.fingerprint else {
                return toolResult(.failure("Nothing was sent: the roles or their policies changed while the user was deciding. Call the tool again to show the user the current plan."), era)
            }
            return await execute(fresh, era)
        }

        guard config.noConfirm else {
            let why = "This client cannot ask its user to confirm (no form elicitation), and pimento mcp does not "
                + "change roles without the user's confirmation. Nothing was sent. Use a client that supports MCP "
                + "elicitation, or let the user activate the roles themselves (`pimento activate`). The user can "
                + "also restart the server with --no-confirm to rely on the client's own tool approval instead."
            if era.isModern {
                throw RPCError(code: MCP.Code.missingRequiredClientCapability, message: why,
                               data: ["requiredCapabilities": ["elicitation": ["form": [:]]]])
            }
            return toolResult(.failure(why), era)
        }
        return await execute(plan, era)
    }

    /// Sends a plan that may be sent, unless the client withdrew the call
    /// (`notifications/cancelled`) while it waited for its turn or its answer.
    func execute(_ plan: MCPWritePlan, _ era: MCPEra) async -> JSONValue {
        if Task.isCancelled { return toolResult(.failure("Nothing was sent: the request was cancelled."), era) }
        return toolResult(await tools.execute(plan), era)
    }

    func inputRequired(_ plan: MCPWritePlan, tool: String, args: MCPArguments, era: MCPEra) -> JSONValue {
        let state = confirmations.issue(tool: tool, arguments: args.canonical, fingerprint: plan.fingerprint)
        return [
            "resultType": "input_required",
            "inputRequests": [MCPConfirmation.inputKey: ["method": "elicitation/create", "params": MCPConfirmation.request(for: plan)]],
            "requestState": .string(state),
            "_meta": [MCP.Meta.serverInfo: Self.serverInfo],
        ]
    }
}

// MARK: - Helpers

/// Confirmations handed out on the stateless revision. The `requestState` the
/// client echoes is a random, single-use handle into this store (never the
/// plan itself): a client cannot forge or alter it, and it is bound to the
/// tool, its exact arguments, and what the user was shown.
final class MCPConfirmationStore: @unchecked Sendable {
    struct Entry {
        let tool: String
        let arguments: String
        let fingerprint: String
        let expires: Date
    }

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    let ttl: TimeInterval
    let clock: @Sendable () -> Date
    static let maxEntries = 64

    init(ttl: TimeInterval, clock: @escaping @Sendable () -> Date) {
        self.ttl = ttl
        self.clock = clock
    }

    func issue(tool: String, arguments: String, fingerprint: String) -> String {
        var generator = SystemRandomNumberGenerator()
        // 256 random bits, as 64 hex digits.
        let handle = (0..<4).map { _ -> String in
            let hex = String(generator.next() as UInt64, radix: 16)
            return String(repeating: "0", count: 16 - hex.count) + hex
        }.joined()
        let now = clock()
        lock.withLock {
            entries = entries.filter { $0.value.expires > now }
            if entries.count >= Self.maxEntries, let oldest = entries.min(by: { $0.value.expires < $1.value.expires })?.key {
                entries[oldest] = nil
            }
            entries[handle] = Entry(tool: tool, arguments: arguments, fingerprint: fingerprint, expires: now.addingTimeInterval(ttl))
        }
        return handle
    }

    /// The confirmed plan's fingerprint, once: the handle is removed whatever
    /// the outcome. nil when unknown, expired, or issued for another call.
    func take(_ handle: String, tool: String, arguments: String) -> String? {
        let now = clock()
        guard let entry = lock.withLock({ entries.removeValue(forKey: handle) }),
              entry.expires > now, entry.tool == tool, entry.arguments == arguments else { return nil }
        return entry.fingerprint
    }
}

/// Runs one operation at a time, in order.
actor MCPAsyncGate {
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func run<T: Sendable>(_ body: @Sendable () async throws -> T) async throws -> T {
        await acquire()
        defer { release() }
        return try await body()
    }

    private func acquire() async {
        if !busy {
            busy = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    private func release() {
        if waiters.isEmpty { busy = false } else { waiters.removeFirst().resume() }
    }
}

/// At most `perMinute` calls in any 60 seconds.
final class MCPRateLimiter: @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [Date] = []
    let perMinute: Int
    let clock: @Sendable () -> Date

    init(perMinute: Int, clock: @escaping @Sendable () -> Date) {
        self.perMinute = perMinute
        self.clock = clock
    }

    func allow() -> Bool {
        let now = clock()
        return lock.withLock {
            calls.removeAll { now.timeIntervalSince($0) >= 60 }
            guard calls.count < perMinute else { return false }
            calls.append(now)
            return true
        }
    }
}
