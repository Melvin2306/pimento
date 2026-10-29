import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, Int)
}

public struct URLSessionTransport: HTTPTransport {
    public init() {}

    public func send(_ request: URLRequest) async throws -> (Data, Int) {
        let (data, response) = try await URLSession.shared.data(for: request)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
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
}

public final class PIMService: Sendable {
    let transport: HTTPTransport
    let tokens: TokenProvider

    public init(transport: HTTPTransport = URLSessionTransport(), tokens: TokenProvider = AzureCLITokenProvider()) {
        self.transport = transport
        self.tokens = tokens
    }

    /// GETs eligibilities + active instances and joins them. Read-only.
    public func loadRoles(now: Date = Date()) async throws -> RoleSnapshot {
        let token = try await tokens.accessToken()
        guard let identity = JWT.identity(fromToken: token) else { throw PIMServiceError.noIdentity }
        async let eligibilities: [EligibilityScheduleInstance] = listAll(ARM.eligibilityInstancesURL, token: token)
        async let assignments: [AssignmentScheduleInstance] = listAll(ARM.assignmentInstancesURL, token: token)
        let rows = try await RoleMatcher.rows(eligibilities: eligibilities, assignments: assignments, now: now)
        return RoleSnapshot(identity: identity, roles: rows)
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
                let env = try? JSONDecoder().decode(ARMErrorEnvelope.self, from: data)
                let msg = [env?.error?.code, env?.error?.message].compactMap { $0 }.joined(separator: ": ")
                throw PIMServiceError.http(status, msg.isEmpty ? String(decoding: data.prefix(300), as: UTF8.self) : msg)
            }
            let page = try JSONDecoder().decode(ARMList<Item>.self, from: data)
            items += page.value
            // Only follow pagination links back to ARM, never send the token elsewhere.
            next = page.nextLink.flatMap(URL.init(string:)).flatMap { $0.host == ARM.host ? $0 : nil }
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
            return ActivationResponseMapper.outcome(statusCode: status, data: data, requestedAt: plan.requestedAt, hours: plan.hours)
        } catch {
            return .failed(code: "NetworkError", message: error.localizedDescription)
        }
    }
}
