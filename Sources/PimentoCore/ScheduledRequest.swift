import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A request of yours that has not taken effect yet: an activation scheduled
/// for later, or one waiting for an approver. Read from
/// `roleAssignmentScheduleRequests` (`$filter=asTarget()` at the tenant root;
/// `asRequestor()` is refused there with `InsufficientPermissions`).
public struct ScheduledRequest: Identifiable, Hashable, Sendable {
    public enum Kind: String, Sendable {
        /// Accepted, starts later (status `Granted`, `ScheduleCreated`, …).
        case scheduled
        /// Waiting for an approver (`PendingApproval`, …).
        case awaitingApproval
    }

    /// The ARM id of the request.
    public let id: String
    /// The request GUID: what `pimento cancel` takes.
    public let name: String
    public let scope: String
    public let roleDefinitionId: String
    public let roleName: String
    public let scopeName: String
    public let scopeType: String
    public let status: String
    public let requestType: String
    public let start: Date
    /// nil: open-ended or unknown.
    public let end: Date?
    public let justification: String?
    public let ticketNumber: String?
    public let ticketSystem: String?
    public let createdOn: Date?
    public let linkedRoleEligibilityScheduleId: String?
    public let kind: Kind
    /// The approval a request waiting for one belongs to, when ARM names it.
    public let approvalId: String?

    public init(
        id: String, name: String, scope: String, roleDefinitionId: String, roleName: String, scopeName: String,
        scopeType: String, status: String, requestType: String = RequestAction.activate.requestType, start: Date, end: Date?,
        justification: String? = nil, ticketNumber: String? = nil, ticketSystem: String? = nil, createdOn: Date? = nil,
        linkedRoleEligibilityScheduleId: String? = nil, kind: Kind = .scheduled, approvalId: String? = nil
    ) {
        self.id = id
        self.name = name
        self.scope = scope
        self.roleDefinitionId = roleDefinitionId
        self.roleName = roleName
        self.scopeName = scopeName
        self.scopeType = scopeType
        self.status = status
        self.requestType = requestType
        self.start = start
        self.end = end
        self.justification = justification
        self.ticketNumber = ticketNumber
        self.ticketSystem = ticketSystem
        self.createdOn = createdOn
        self.linkedRoleEligibilityScheduleId = linkedRoleEligibilityScheduleId
        self.kind = kind
        self.approvalId = approvalId
    }

    /// Approvers have this long to decide; then PIM lets the request expire
    /// (`TimedOut`). Not configurable.
    public static let approvalWindow: TimeInterval = 24 * 3600

    /// When a request waiting for approval expires (creation + 24 hours);
    /// nil for scheduled ones or when the creation time is unknown.
    public var expiresAt: Date? {
        guard kind == .awaitingApproval, let createdOn else { return nil }
        return createdOn.addingTimeInterval(Self.approvalWindow)
    }

    /// Scope + role, to find the eligibility row it belongs to.
    public var policyKey: RoleMatcher.Key { RoleMatcher.key(scope: scope, roleDefinitionId: roleDefinitionId) }

    public var isOwner: Bool {
        RoleMatcher.lastPathComponent(roleDefinitionId).lowercased() == EligibleRole.ownerRoleGUID
            || roleName.caseInsensitiveCompare("Owner") == .orderedSame
    }

    /// The first 8 characters of the request GUID, as `pimento scheduled` shows it.
    public var shortId: String { String(name.prefix(8)) }

    /// How long the activation lasts once it starts, in minutes.
    public var durationMinutes: Int? { end.map { max(0, Int($0.timeIntervalSince(start) / 60)) } }

    public var scopeTypeLabel: String {
        EligibleRole(id: "", eligibilityScheduleId: "", roleDefinitionId: "", roleName: "", scope: scope, scopeName: "",
                     scopeType: scopeType, membership: .direct).scopeTypeLabel
    }

    /// The row as an eligibility, for the shared filters (`RoleCriteria`).
    public var asRole: EligibleRole {
        EligibleRole(id: id, eligibilityScheduleId: linkedRoleEligibilityScheduleId ?? "", roleDefinitionId: roleDefinitionId,
                     roleName: roleName, scope: scope, scopeName: scopeName, scopeType: scopeType, membership: .direct)
    }

    /// `POST {scope}/providers/Microsoft.Authorization/roleAssignmentScheduleRequests/{name}/cancel`.
    public var cancelURL: URL? {
        guard !name.isEmpty, name.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }) else { return nil }
        guard let path = ARMScope.path(scope) else { return nil }
        return URL(string: "\(ARM.baseURL)\(path)/providers/Microsoft.Authorization/roleAssignmentScheduleRequests/\(name)/cancel?api-version=\(ARM.apiVersion)")
    }

    /// Statuses of a request that was accepted and only waits for its start.
    public static let scheduledStatuses: Set<String> = [
        "granted", "schedulecreated", "pendingschedulecreation", "accepted", "pendingprovisioning",
        "pendingevaluation", "adminapproved",
    ]
    /// Statuses of a request waiting for someone to decide.
    public static let approvalStatuses: Set<String> = ["pendingapproval", "pendingapprovalprovisioning", "pendingadmindecision"]

    /// The kind of a `SelfActivate` request in `status` starting at `start`;
    /// nil when it is done, failed, or already started.
    public static func kind(status: String, start: Date, now: Date) -> Kind? {
        let s = status.lowercased()
        if approvalStatuses.contains(s) { return .awaitingApproval }
        if scheduledStatuses.contains(s), start > now { return .scheduled }
        return nil
    }
}

/// One `roleAssignmentScheduleRequests` item (only the fields Pimento reads).
public struct AssignmentScheduleRequestItem: Decodable, Sendable {
    public struct Properties: Decodable, Sendable {
        public struct ScheduleInfo: Decodable, Sendable {
            public struct Expiration: Decodable, Sendable {
                public let type: String?
                public let duration: String?
                public let endDateTime: String?
            }

            public let startDateTime: String?
            public let expiration: Expiration?
        }

        public struct TicketInfo: Decodable, Sendable {
            public let ticketNumber: String?
            public let ticketSystem: String?
        }

        public let scope: String?
        public let roleDefinitionId: String?
        public let principalId: String?
        public let requestType: String?
        public let status: String?
        public let scheduleInfo: ScheduleInfo?
        public let justification: String?
        public let ticketInfo: TicketInfo?
        public let createdOn: String?
        public let linkedRoleEligibilityScheduleId: String?
        /// The approval of a request that needs one (`roleAssignmentApprovals/{id}`).
        public let approvalId: String?
        /// Who made the request (the requester; the principal for `SelfActivate`).
        public let requestorId: String?
        /// The assignment schedule the request created (its last path component
        /// is the request's name).
        public let targetRoleAssignmentScheduleId: String?
        public let expandedProperties: ExpandedProperties?
    }

    public let id: String?
    public let name: String?
    public let properties: Properties?
}

public enum ScheduledRequestParser {
    /// Your pending `SelfActivate` requests among `items` (scheduled for later,
    /// or awaiting approval), soonest first.
    public static func pending(_ items: [AssignmentScheduleRequestItem], principalId: String? = nil, now: Date) -> [ScheduledRequest] {
        var seen = Set<String>()
        let requests = items.compactMap { item -> ScheduledRequest? in
            guard let p = item.properties,
                  p.requestType?.caseInsensitiveCompare(RequestAction.activate.requestType) == .orderedSame,
                  let status = p.status, let start = AzureDate.parse(p.scheduleInfo?.startDateTime)
            else { return nil }
            if let principalId, let mine = p.principalId, mine.caseInsensitiveCompare(principalId) != .orderedSame { return nil }
            guard let kind = ScheduledRequest.kind(status: status, start: start, now: now),
                  let request = describe(item, kind: kind), seen.insert(request.name.lowercased()).inserted
            else { return nil }
            return request
        }
        return requests.sorted { ($0.start, $0.scopeName.lowercased(), $0.roleName) < ($1.start, $1.scopeName.lowercased(), $1.roleName) }
    }

    /// Any request as a `ScheduledRequest` of `kind`, whatever its status
    /// (for `pimento wait`, which also reports decided ones). nil without a
    /// name, scope, role or start.
    public static func describe(_ item: AssignmentScheduleRequestItem, kind: ScheduledRequest.Kind) -> ScheduledRequest? {
        guard let p = item.properties, let scope = p.scope, let roleDefinitionId = p.roleDefinitionId,
              let start = AzureDate.parse(p.scheduleInfo?.startDateTime)
        else { return nil }
        let id = item.id ?? ""
        let name = item.name ?? RoleMatcher.lastPathComponent(id)
        guard !name.isEmpty else { return nil }
        let expiration = p.scheduleInfo?.expiration
        let end = AzureDate.parse(expiration?.endDateTime)
            ?? ISODuration.parse(expiration?.duration).map { start.addingTimeInterval($0) }
        let x = p.expandedProperties
        return ScheduledRequest(
            id: id, name: name, scope: scope, roleDefinitionId: roleDefinitionId,
            roleName: x?.roleDefinition?.displayName ?? RoleMatcher.lastPathComponent(roleDefinitionId),
            scopeName: x?.scope?.displayName ?? RoleMatcher.lastPathComponent(scope),
            scopeType: x?.scope?.type ?? RoleMatcher.inferScopeType(scope),
            status: p.status ?? "", requestType: p.requestType ?? RequestAction.activate.requestType,
            start: start, end: end,
            justification: p.justification?.nonEmpty,
            ticketNumber: p.ticketInfo?.ticketNumber?.nonEmpty, ticketSystem: p.ticketInfo?.ticketSystem?.nonEmpty,
            createdOn: AzureDate.parse(p.createdOn),
            linkedRoleEligibilityScheduleId: p.linkedRoleEligibilityScheduleId, kind: kind,
            approvalId: p.approvalId?.nonEmpty)
    }

    /// Requests by scope + role, to badge the rows they belong to.
    public static func byRole(_ requests: [ScheduledRequest]) -> [RoleMatcher.Key: [ScheduledRequest]] {
        Dictionary(grouping: requests, by: \.policyKey)
    }
}

/// What a cancel request did.
public enum CancelOutcome: Equatable, Sendable {
    case canceled
    /// `RequestCannotBeCancelled`: it already started, was cancelled, or was decided.
    case notCancellable(String)
    case failed(code: String, message: String)

    public var isFailure: Bool { self != .canceled }

    public var summary: String {
        switch self {
        case .canceled: "Cancelled"
        case .notCancellable: "Cannot be cancelled any more (started, cancelled or decided)"
        case .failed(let code, let message): message.isEmpty ? code : "\(code): \(message)"
        }
    }

    public var isAuthFailure: Bool {
        guard case .failed(let code, _) = self else { return false }
        return ActivationResponseMapper.authErrorCodes.contains(code)
    }

    public static let notCancellableCode = "RequestCannotBeCancelled"

    public static func from(statusCode: Int, data: Data) -> CancelOutcome {
        if (200..<300).contains(statusCode) { return .canceled }
        let (code, message) = ActivationResponseMapper.error(statusCode: statusCode, data: data)
        if code == notCancellableCode { return .notCancellable(message) }
        if ActivationResponseMapper.authErrorCodes.contains(code) {
            return .failed(code: code, message: "Token rejected. Refresh, or sign in again with `az login`. (\(message))")
        }
        return .failed(code: code, message: message)
    }
}

extension ARM {
    /// Every request that targets you, at the tenant root.
    public static var assignmentRequestsURL: URL {
        URL(string: "\(baseURL)/providers/Microsoft.Authorization/roleAssignmentScheduleRequests?api-version=\(apiVersion)&$filter=asTarget()")!
    }
}

/// Your requests as `asTarget()` lists them: the pending ones, plus the
/// history Pimento reads tickets and decisions from.
public struct RequestHistory: Sendable {
    public let identity: Identity
    /// Your requests (any status, any type).
    public let items: [AssignmentScheduleRequestItem]
    /// Scheduled or waiting for approval.
    public let pending: [ScheduledRequest]

    public init(identity: Identity, items: [AssignmentScheduleRequestItem], now: Date) {
        self.identity = identity
        self.items = items.filter { item in
            guard let mine = item.properties?.principalId else { return true }
            return mine.caseInsensitiveCompare(identity.objectId) == .orderedSame
        }
        pending = ScheduledRequestParser.pending(self.items, principalId: identity.objectId, now: now)
    }

    /// The ticket of each request, by lower-cased request name. A request's
    /// name is the last segment of the assignment schedule it creates, so an
    /// active role's `activeScheduleId` finds the request behind it.
    public var activationTickets: [String: TicketInfo] {
        var result: [String: TicketInfo] = [:]
        for item in items {
            guard let name = (item.name ?? item.id.map(RoleMatcher.lastPathComponent))?.lowercased(),
                  let t = TicketInfo.make(number: item.properties?.ticketInfo?.ticketNumber, system: item.properties?.ticketInfo?.ticketSystem)
            else { continue }
            result[name] = t
        }
        return result
    }

    /// The ticket the activation of `role` was requested with, if any.
    public static func ticket(for role: EligibleRole, in tickets: [String: TicketInfo]) -> TicketInfo? {
        guard role.isActive, let schedule = role.activeScheduleId else { return nil }
        return tickets[RoleMatcher.lastPathComponent(schedule).lowercased()]
    }

    /// Your requests whose name starts with `prefix`.
    public func items(matching prefix: String) -> [AssignmentScheduleRequestItem] {
        let p = prefix.lowercased()
        return items.filter { ($0.name ?? $0.id.map(RoleMatcher.lastPathComponent) ?? "").lowercased().hasPrefix(p) }
    }
}

extension PIMService {
    /// Your pending activation requests (scheduled or awaiting approval). Read-only.
    public func loadScheduledRequests(now: Date? = nil) async throws -> (identity: Identity, requests: [ScheduledRequest]) {
        let history = try await loadRequestHistory(now: now)
        return (history.identity, history.pending)
    }

    /// Every request that targets you (`asTarget()`), pending and past. Read-only.
    /// `now` nil: the service's clock.
    public func loadRequestHistory(now: Date? = nil) async throws -> RequestHistory {
        let now = now ?? clock()
        let token = try await tokens.accessToken()
        guard let identity = JWT.identity(fromToken: token) else { throw PIMServiceError.noIdentity }
        let items: [AssignmentScheduleRequestItem] = try await listAll(ARM.assignmentRequestsURL, token: token)
        return RequestHistory(identity: identity, items: items, now: now)
    }

    /// Cancels `requests` (POST …/cancel), a few at a time.
    public func cancel(
        _ requests: [ScheduledRequest],
        maxConcurrent: Int = 4,
        onResult: @escaping @Sendable (ScheduledRequest, CancelOutcome) async -> Void
    ) async throws {
        guard !requests.isEmpty else { return }
        let token = try await tokens.accessToken()
        await withTaskGroup(of: (ScheduledRequest, CancelOutcome).self) { group in
            var pending = requests.makeIterator()
            func enqueue(_ r: ScheduledRequest) {
                group.addTask { (r, await self.cancel(r, token: token)) }
            }
            for _ in 0..<max(1, maxConcurrent) {
                guard let next = pending.next() else { break }
                enqueue(next)
            }
            while let (r, outcome) = await group.next() {
                record(token: token) { HistoryRecord(cancelled: r, outcome: outcome, context: $0) }
                await onResult(r, outcome)
                if let next = pending.next() { enqueue(next) }
            }
        }
    }

    func cancel(_ r: ScheduledRequest, token: String) async -> CancelOutcome {
        guard let url = r.cancelURL else { return .failed(code: "InvalidRequestId", message: "Not a request id: \(r.name)") }
        var request = URLRequest(url: url, timeoutInterval: 60)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("0", forHTTPHeaderField: "Content-Length")
        do {
            let (data, status) = try await transport.send(request)
            return CancelOutcome.from(statusCode: status, data: data)
        } catch {
            return .failed(code: "NetworkError", message: error.localizedDescription)
        }
    }
}

/// The local notification that a scheduled activation has started: one per
/// tenant and start minute, at the start. Best-effort (macOS shows it whether
/// or not PIM activated the role); rebuilt from the pending requests whenever
/// they are read, so cancelled requests lose theirs.
public struct ScheduledStartNotice: Equatable, Sendable {
    public let id: String
    public let fireAt: Date
    public let title: String
    public let body: String

    public static let prefix = "scheduled-"
    static let listed = 3

    /// What every notice of `tenantId` starts with (to replace them all).
    public static func idPrefix(tenantId: String?) -> String {
        prefix + (tenantId?.lowercased().nonEmpty ?? "default") + "-"
    }

    public static func isNotice(_ identifier: String) -> Bool { identifier.hasPrefix(prefix) }

    /// One notice per start minute of the scheduled (not awaiting approval)
    /// requests that start after `now`.
    public static func notices(for requests: [ScheduledRequest], tenantId: String?, now: Date,
                               timeZone: TimeZone = .current) -> [ScheduledStartNotice] {
        var byMinute: [Date: [ScheduledRequest]] = [:]
        for r in requests where r.kind == .scheduled && r.start > now {
            let minute = Date(timeIntervalSince1970: (r.start.timeIntervalSince1970 / 60).rounded(.down) * 60)
            byMinute[minute, default: []].append(r)
        }
        let time = Date.FormatStyle(date: .omitted, time: .shortened, timeZone: timeZone)
        return byMinute.keys.sorted().map { minute in
            let items = byMinute[minute]!
            let lines = items.prefix(listed).map { r in
                "\(r.roleName) · \(r.scopeName)" + (r.end.map { ", until \($0.formatted(time))" } ?? "")
            }
            let more = items.count - lines.count
            return ScheduledStartNotice(
                id: idPrefix(tenantId: tenantId) + String(Int(minute.timeIntervalSince1970)),
                fireAt: minute,
                title: items.count == 1 ? "Scheduled activation started" : "Scheduled activations started (\(items.count) roles)",
                body: (lines + (more > 0 ? ["and \(more) more"] : [])).joined(separator: "\n"))
        }
    }
}

public extension ScheduledRequest {
    /// "3 scheduled activations", "1 request awaiting approval", or both
    /// joined with "and": what the Scheduled view lists, by kind.
    static func countLabel(_ requests: [ScheduledRequest]) -> String {
        let awaiting = requests.filter { $0.kind == .awaitingApproval }.count
        let scheduled = requests.count - awaiting
        var parts: [String] = []
        if scheduled > 0 || awaiting == 0 { parts.append("\(scheduled) scheduled activation\(scheduled == 1 ? "" : "s")") }
        if awaiting > 0 { parts.append("\(awaiting) request\(awaiting == 1 ? "" : "s") awaiting approval") }
        return parts.joined(separator: " and ")
    }
}
