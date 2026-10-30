import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, Int)
}

/// Sends requests with URLSession and never follows a redirect: a 3xx answer
/// throws `RedirectRefused`, so a token or sign-in data only ever goes to the
/// URL the request was built for (the host guards check that URL alone).
public struct URLSessionTransport: HTTPTransport {
    public struct RedirectRefused: Error, LocalizedError, Equatable {
        public let status: Int
        public let location: String?
        public var errorDescription: String? {
            "Refused to follow an HTTP \(status) redirect\(location.map { " to \($0)" } ?? ""): requests go only to the URL they were sent to."
        }
    }

    /// One session for every transport, with the redirect refusal as its delegate.
    static let session = URLSession(configuration: .default, delegate: RedirectRefusal.shared, delegateQueue: nil)

    public init() {}

    public func send(_ request: URLRequest) async throws -> (Data, Int) {
        // The delegate goes to the task as well: swift-corelibs-foundation asks
        // only the task's delegate about redirects of an async request.
        let (data, response) = try await Self.session.data(for: request, delegate: RedirectRefusal.shared)
        let http = response as? HTTPURLResponse
        let status = http?.statusCode ?? 0
        try Self.check(status: status, location: http?.value(forHTTPHeaderField: "Location"), requested: request.url, answered: response.url)
        return (data, status)
    }

    /// Throws for a 3xx answer, or for an answer from another origin than the
    /// one requested (a redirect a platform followed despite the delegate).
    static func check(status: Int, location: String?, requested: URL?, answered: URL?) throws {
        if (300..<400).contains(status) { throw RedirectRefused(status: status, location: location) }
        if let requested, let answered, !sameOrigin(requested, answered) {
            throw RedirectRefused(status: status, location: answered.absoluteString)
        }
    }

    static func sameOrigin(_ a: URL, _ b: URL) -> Bool {
        a.scheme?.lowercased() == b.scheme?.lowercased() && a.host?.lowercased() == b.host?.lowercased() && a.port == b.port
    }
}

/// Answers every redirect with "do not follow": the 3xx response becomes the
/// final one, and `URLSessionTransport` turns it into an error.
final class RedirectRefusal: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    static let shared = RedirectRefusal()

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

/// Wraps a transport and refuses anything but GET. Used by the CLI mode so that
/// listing and dry runs are read-only by construction.
public struct ReadOnlyTransport: HTTPTransport {
    public struct WriteRefused: Error, LocalizedError {
        public let method: String
        public var errorDescription: String? { "Read-only mode: refused to send \(method)." }
    }

    let base: HTTPTransport

    public init(_ base: HTTPTransport) { self.base = base }

    public func send(_ request: URLRequest) async throws -> (Data, Int) {
        let method = request.httpMethod ?? "GET"
        guard method == "GET" else { throw WriteRefused(method: method) }
        return try await base.send(request)
    }
}

public enum PIMServiceError: Error, LocalizedError {
    case http(Int, String)
    case noIdentity

    public var errorDescription: String? {
        switch self {
        case .http(let status, let message): "ARM returned HTTP \(status): \(message)"
        case .noIdentity: "The az token has no `oid` claim — cannot tell who you are."
        }
    }
}

public struct RoleSnapshot: Sendable {
    public let identity: Identity
    public let roles: [EligibleRole]
    /// Admin-assigned active assignments with an end date (for `extend`).
    public var timeBoundAssignments: [ActiveAssignment] = []

    public init(identity: Identity, roles: [EligibleRole], timeBoundAssignments: [ActiveAssignment] = []) {
        self.identity = identity
        self.roles = roles
        self.timeBoundAssignments = timeBoundAssignments
    }
}

/// Where a renewal of one role is.
public enum RenewPhase: Equatable, Sendable {
    case deactivating
    /// Activating again; `attempt` counts from 1 (PIM needs a moment to
    /// remove the old assignment, so the first tries may be refused).
    case reactivating(attempt: Int)
}

public final class PIMService: Sendable {
    let transport: HTTPTransport
    let tokens: TokenProvider
    let sleep: @Sendable (TimeInterval) async -> Void
    let clock: @Sendable () -> Date
    /// Where every write and its outcome is recorded (nil: nowhere).
    public let history: HistoryRecorder?

    public init(
        transport: HTTPTransport = URLSessionTransport(),
        tokens: TokenProvider = AzureCLITokenProvider(),
        sleep: @escaping @Sendable (TimeInterval) async -> Void = { try? await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) },
        clock: @escaping @Sendable () -> Date = { Date() },
        history: HistoryRecorder? = nil
    ) {
        self.transport = transport
        self.tokens = tokens
        self.sleep = sleep
        self.clock = clock
        self.history = history
    }

    /// The same service, recording its writes to `recorder`.
    public func recording(to recorder: HistoryRecorder?) -> PIMService {
        PIMService(transport: transport, tokens: tokens, sleep: sleep, clock: clock, history: recorder)
    }

    /// Records one history entry per result of a write sent with `token`.
    func record(token: String, _ make: (HistoryContext) -> HistoryRecord) {
        guard let history else { return }
        history.record([make(history.context(tenantId: JWT.identity(fromToken: token)?.tenantId))])
    }

    /// GETs eligibilities + active instances and joins them. Read-only.
    public func loadRoles(now: Date = Date()) async throws -> RoleSnapshot {
        let token = try await tokens.accessToken()
        guard let identity = JWT.identity(fromToken: token) else { throw PIMServiceError.noIdentity }
        async let eligibilities: [EligibilityScheduleInstance] = listAll(ARM.eligibilityInstancesURL, token: token)
        async let assignments: [AssignmentScheduleInstance] = listAll(ARM.assignmentInstancesURL, token: token)
        let active = try await assignments
        let rows = try await RoleMatcher.rows(eligibilities: eligibilities, assignments: active, now: now)
        return RoleSnapshot(identity: identity, roles: rows,
                            timeBoundAssignments: RoleMatcher.timeBoundAssignments(active, now: now))
    }

    func listAll<Item: Decodable>(_ first: URL, token: String) async throws -> [Item] {
        var items: [Item] = []
        var next: URL? = first
        var pages = 0
        while let url = next, pages < 100 {
            pages += 1
            var request = URLRequest(url: url, timeoutInterval: 60)
            request.httpMethod = "GET"
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            let (data, status) = try await transport.send(request)
            guard status == 200 else {
                throw PIMServiceError.http(status, ARMErrorEnvelope.describe(data) ?? String(decoding: data.prefix(300), as: UTF8.self))
            }
            let page = try JSONDecoder().decode(ARMList<Item>.self, from: data)
            items += page.value
            // Only follow pagination links back to ARM, never send the token elsewhere.
            next = ARM.followableNextLink(page.nextLink)
        }
        return items
    }

    /// Sends the planned activation requests (PUT), at most `maxConcurrent` at a
    /// time, reporting each outcome as it arrives. This is the ONLY write path.
    public func execute(
        _ plans: [PlannedRequest],
        maxConcurrent: Int = 8,
        onStart: @escaping @Sendable (PlannedRequest) async -> Void = { _ in },
        onResult: @escaping @Sendable (PlannedRequest, ActivationOutcome) async -> Void
    ) async throws {
        guard !plans.isEmpty else { return }
        let token = try await tokens.accessToken()
        let limit = max(1, maxConcurrent)
        await withTaskGroup(of: (PlannedRequest, ActivationOutcome).self) { group in
            var pending = plans.makeIterator()
            func enqueue(_ plan: PlannedRequest) {
                group.addTask {
                    await onStart(plan)
                    return (plan, await self.send(plan, token: token))
                }
            }
            for _ in 0..<limit {
                guard let plan = pending.next() else { break }
                enqueue(plan)
            }
            while let (plan, outcome) = await group.next() {
                record(token: token) { HistoryRecord(plan: plan, outcome: outcome, context: $0) }
                await onResult(plan, outcome)
                if let plan = pending.next() { enqueue(plan) }
            }
        }
    }

    func send(_ plan: PlannedRequest, token: String) async -> ActivationOutcome {
        var request = URLRequest(url: plan.url, timeoutInterval: 60)
        request.httpMethod = "PUT"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = plan.bodyJSON
        do {
            let (data, status) = try await transport.send(request)
            return ActivationResponseMapper.outcome(
                for: plan.action, statusCode: status, data: data, requestedAt: plan.requestedAt,
                minutes: plan.minutes, activeSince: plan.role.activeSince, scheduledStart: plan.start)
        } catch {
            return .failed(code: "NetworkError", message: error.localizedDescription)
        }
    }

    /// Waits before each re-activation attempt of a renewal, in seconds: about
    /// five minutes in all. After a `SelfDeactivate`, PIM answers
    /// `RoleAssignmentExists` to a new activation until it has removed the old
    /// assignment, which took about three minutes in tests.
    public static let reactivationDelays: [TimeInterval] = [0, 5, 5, 10, 10, 15, 15, 20, 20, 30, 30, 30, 30, 30, 30, 30]

    /// Renews each role: ends its activation (`SelfDeactivate`), then activates
    /// it again (`SelfActivate`, a fresh request each attempt). A role whose
    /// deactivation fails keeps its activation; one deactivated but not
    /// activated again ends as `.failed(code: "ReactivationFailed")`. When an
    /// attempt's answer was lost, the role's activations are read before a
    /// failure is reported: PIM may have accepted it (and refused the next
    /// attempts with `RoleAssignmentExists`).
    public func renew(
        _ plans: [RenewPlan],
        maxConcurrent: Int = 4,
        onPhase: @escaping @Sendable (RenewPlan, RenewPhase) async -> Void = { _, _ in },
        onResult: @escaping @Sendable (RenewPlan, ActivationOutcome) async -> Void
    ) async throws {
        guard !plans.isEmpty else { return }
        let token = try await tokens.accessToken()
        let limit = max(1, maxConcurrent)
        await withTaskGroup(of: (RenewPlan, ActivationOutcome, String?).self) { group in
            var pending = plans.makeIterator()
            func enqueue(_ plan: RenewPlan) {
                group.addTask {
                    let (outcome, requestId) = await self.renew(plan, token: token, onPhase: onPhase)
                    return (plan, outcome, requestId)
                }
            }
            for _ in 0..<limit {
                guard let plan = pending.next() else { break }
                enqueue(plan)
            }
            while let (plan, outcome, requestId) = await group.next() {
                record(token: token) { HistoryRecord(renewal: plan, outcome: outcome, requestId: requestId, context: $0) }
                await onResult(plan, outcome)
                if let plan = pending.next() { enqueue(plan) }
            }
        }
    }

    /// The outcome, and the id of the last activation request sent (nil when
    /// the deactivation already failed).
    func renew(_ plan: RenewPlan, token: String, onPhase: @Sendable (RenewPlan, RenewPhase) async -> Void) async -> (ActivationOutcome, String?) {
        await onPhase(plan, .deactivating)
        let started = clock()
        let ended = await send(plan.deactivation, token: token)
        switch ended {
        case .deactivated, .notActive: break
        default: return (ended, nil)
        }
        var last: ActivationOutcome = .failed(code: "ReactivationFailed", message: "not attempted")
        var lastId: String?
        // Attempts whose answer was lost: PIM may have accepted them, and then
        // answers `RoleAssignmentExists` to the next one.
        var unanswered: [String] = []
        for (i, delay) in Self.reactivationDelays.enumerated() {
            if delay > 0 { await sleep(delay) }
            await onPhase(plan, .reactivating(attempt: i + 1))
            guard let request = try? plan.activation(now: clock()) else { break }
            lastId = request.requestId
            last = await send(request, token: token)
            if case .failed("NetworkError", _) = last { unanswered.append(request.requestId) }
            if !RenewPlan.shouldRetry(last) { break }
        }
        let result = RenewPlan.result(of: last)
        if result.isFailure, !unanswered.isEmpty,
           let instances: [AssignmentScheduleInstance] = try? await listAll(ARM.assignmentInstancesURL, token: token),
           let found = RenewPlan.confirmedActivation(of: plan, in: instances, requestIds: unanswered, since: started, now: clock()) {
            return (.renewed(until: found.until), found.requestId ?? lastId)
        }
        return (result, lastId)
    }
}
