import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// Approval workflow for Azure-resource PIM.
//
// Requester side: an activation of a role whose policy requires approval is
// answered with status `PendingApproval`. The request stays in
// `roleAssignmentScheduleRequests` (`$filter=asTarget()`); once an approver
// decides, its status becomes `Provisioned` (or `Granted` for a later start),
// `Denied`, or, after 24 hours without a decision, `TimedOut`.
//
// Approver side (ARM, documented as preview):
// - `GET /providers/Microsoft.Authorization/roleAssignmentScheduleRequests?$filter=asApprover()`
//   (api-version 2020-10-01): the requests you may decide, with requester,
//   role, scope, justification, ticket and schedule.
// - `GET /providers/Microsoft.Authorization/roleAssignmentApprovals?$filter=asApprover()`
//   (2021-01-01-preview): their approvals with `stages`. `asApprover()` is the
//   only filter this endpoint accepts at the tenant root; anything else is a
//   400 `{"Message": …}`.
// - `PATCH /providers/Microsoft.Authorization/roleAssignmentApprovals/{approvalId}/stages/{stageId}`
//   with `{"reviewResult": "Approve"|"Deny", "justification": …}` records the decision.

extension ARM {
    /// The api-version of `roleAssignmentApprovals` (preview; the only one).
    public static let approvalsApiVersion = "2021-01-01-preview"

    /// Requests you may approve or deny, at the tenant root.
    public static var approverRequestsURL: URL {
        URL(string: "\(baseURL)/providers/Microsoft.Authorization/roleAssignmentScheduleRequests?api-version=\(apiVersion)&$filter=asApprover()")!
    }

    /// Your approvals, with their stages.
    public static var approvalsURL: URL {
        URL(string: "\(baseURL)/providers/Microsoft.Authorization/roleAssignmentApprovals?api-version=\(approvalsApiVersion)&$filter=asApprover()")!
    }

    /// `…/roleAssignmentApprovals/{approvalId}/stages`, or nil for an id that is not one.
    public static func approvalStagesURL(approvalId: String) -> URL? {
        guard isResourceName(approvalId) else { return nil }
        return URL(string: "\(baseURL)/providers/Microsoft.Authorization/roleAssignmentApprovals/\(approvalId)/stages?api-version=\(approvalsApiVersion)")
    }

    /// `…/roleAssignmentApprovals/{approvalId}/stages/{stageId}`: where a decision goes.
    public static func approvalStageURL(approvalId: String, stageId: String) -> URL? {
        guard isResourceName(approvalId), isResourceName(stageId) else { return nil }
        return URL(string: "\(baseURL)/providers/Microsoft.Authorization/roleAssignmentApprovals/\(approvalId)/stages/\(stageId)?api-version=\(approvalsApiVersion)")
    }

    /// A GUID-like path segment: letters, digits and dashes only.
    static func isResourceName(_ s: String) -> Bool {
        !s.isEmpty && s.count <= 64 && s.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
    }
}

// MARK: - ARM shapes

/// One `roleAssignmentApprovals` item (only the fields Pimento reads).
public struct RoleAssignmentApprovalItem: Decodable, Sendable {
    public struct Properties: Decodable, Sendable {
        public let stages: [ApprovalStageItem]?
    }

    public let id: String?
    public let name: String?
    public let properties: Properties?
}

/// One stage of an approval.
public struct ApprovalStageItem: Decodable, Sendable {
    public struct Properties: Decodable, Sendable {
        public struct Reviewer: Decodable, Sendable {
            public let principalId: String?
            public let principalName: String?
            public let principalType: String?
            public let userPrincipalName: String?
        }

        public let displayName: String?
        public let status: String?
        public let assignedToMe: Bool?
        public let reviewResult: String?
        public let justification: String?
        public let reviewedBy: Reviewer?
        public let reviewedDateTime: String?
    }

    public let id: String?
    public let name: String?
    public let properties: Properties?
}

// MARK: - Approver side

/// One stage of an approval: who may decide, and what was decided.
public struct ApprovalStage: Hashable, Sendable {
    /// The stage's id: what a decision is sent to.
    public let id: String
    public let displayName: String?
    /// `NotStarted`, `InProgress`, `Completed`, `Expired`, `Escalated`, …
    public let status: String
    public let assignedToMe: Bool?
    /// `NotReviewed`, `Approve` or `Deny`.
    public let reviewResult: String?
    public let justification: String?
    public let reviewedBy: String?
    public let reviewedAt: Date?

    public init(id: String, displayName: String? = nil, status: String, assignedToMe: Bool? = nil, reviewResult: String? = nil,
                justification: String? = nil, reviewedBy: String? = nil, reviewedAt: Date? = nil) {
        self.id = id
        self.displayName = displayName
        self.status = status
        self.assignedToMe = assignedToMe
        self.reviewResult = reviewResult
        self.justification = justification
        self.reviewedBy = reviewedBy
        self.reviewedAt = reviewedAt
    }

    /// Statuses of a stage that still waits for a decision.
    static let openStatuses: Set<String> = ["inprogress", "escalating", "escalated", "initializing"]

    /// Waits for a decision (and nobody has decided it yet).
    public var isOpen: Bool {
        Self.openStatuses.contains(status.lowercased())
            && (reviewResult.map { $0.caseInsensitiveCompare("NotReviewed") == .orderedSame || $0.isEmpty } ?? true)
    }

    /// Someone approved or denied it.
    public var isReviewed: Bool {
        guard let r = reviewResult?.lowercased() else { return false }
        return r == "approve" || r == "deny"
    }

    /// The stage the caller can decide: an open one assigned to them, else
    /// any open one (ARM does not always say `assignedToMe`).
    public static func decidable(_ stages: [ApprovalStage]) -> ApprovalStage? {
        stages.first { $0.isOpen && $0.assignedToMe == true } ?? stages.first { $0.isOpen && $0.assignedToMe != false }
    }

    /// The stages of an ARM approval. A stage's id is the last segment of its
    /// `id`: Microsoft's sample answers a different `name` in a list, and the
    /// PATCH example uses the id's.
    public static func parse(_ items: [ApprovalStageItem]) -> [ApprovalStage] {
        items.compactMap { item in
            guard let id = (item.id.map(RoleMatcher.lastPathComponent) ?? item.name)?.nonEmpty else { return nil }
            let p = item.properties
            let reviewer = p?.reviewedBy.flatMap { $0.principalName?.nonEmpty ?? $0.userPrincipalName?.nonEmpty }
            return ApprovalStage(
                id: id, displayName: p?.displayName?.nonEmpty, status: p?.status ?? "", assignedToMe: p?.assignedToMe,
                reviewResult: p?.reviewResult?.nonEmpty, justification: p?.justification?.nonEmpty, reviewedBy: reviewer,
                reviewedAt: AzureDate.parse(p?.reviewedDateTime))
        }
    }
}

/// A request someone else made that you may approve or deny.
public struct ApprovalRequest: Identifiable, Hashable, Sendable {
    /// The ARM id of the request.
    public let id: String
    /// The request GUID (what `pimento approve` takes).
    public let name: String
    /// The approval it belongs to (`roleAssignmentApprovals/{approvalId}`).
    public let approvalId: String
    /// The stage you can decide, when the approvals listing named it; nil:
    /// read when deciding (`…/stages`).
    public var stage: ApprovalStage?
    public let scope: String
    public let roleDefinitionId: String
    public let roleName: String
    public let scopeName: String
    public let scopeType: String
    public let requesterId: String
    public let requesterName: String?
    public let requesterEmail: String?
    public let status: String
    public let requestType: String
    public let start: Date?
    public let end: Date?
    public let justification: String?
    public let ticketNumber: String?
    public let ticketSystem: String?
    public let createdOn: Date?

    public init(
        id: String, name: String, approvalId: String, stage: ApprovalStage? = nil, scope: String, roleDefinitionId: String,
        roleName: String, scopeName: String, scopeType: String, requesterId: String, requesterName: String? = nil,
        requesterEmail: String? = nil, status: String = "PendingApproval", requestType: String = RequestAction.activate.requestType,
        start: Date? = nil, end: Date? = nil, justification: String? = nil, ticketNumber: String? = nil, ticketSystem: String? = nil,
        createdOn: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.approvalId = approvalId
        self.stage = stage
        self.scope = scope
        self.roleDefinitionId = roleDefinitionId
        self.roleName = roleName
        self.scopeName = scopeName
        self.scopeType = scopeType
        self.requesterId = requesterId
        self.requesterName = requesterName
        self.requesterEmail = requesterEmail
        self.status = status
        self.requestType = requestType
        self.start = start
        self.end = end
        self.justification = justification
        self.ticketNumber = ticketNumber
        self.ticketSystem = ticketSystem
        self.createdOn = createdOn
    }

    public var isOwner: Bool {
        RoleMatcher.lastPathComponent(roleDefinitionId).lowercased() == EligibleRole.ownerRoleGUID
            || roleName.caseInsensitiveCompare("Owner") == .orderedSame
    }

    /// The first 8 characters of the request GUID.
    public var shortId: String { String(name.prefix(8)) }

    /// `Megan Bowen <megan@contoso.example>`, or whatever is known.
    public var requesterLabel: String {
        switch (requesterName, requesterEmail) {
        case let (n?, e?): "\(n) <\(e)>"
        case let (n?, nil): n
        case let (nil, e?): e
        default: requesterId
        }
    }

    /// How long the activation would last, in minutes.
    public var durationMinutes: Int? {
        guard let start, let end else { return nil }
        return max(0, Int(end.timeIntervalSince(start) / 60))
    }

    /// When PIM lets the request expire: 24 hours after it was made.
    public var expiresAt: Date? { createdOn.map { $0.addingTimeInterval(ScheduledRequest.approvalWindow) } }

    public var ticket: TicketInfo? { TicketInfo.make(number: ticketNumber, system: ticketSystem) }

    /// The row as an eligibility, for the shared filters.
    public var asRole: EligibleRole {
        EligibleRole(id: id, eligibilityScheduleId: "", roleDefinitionId: roleDefinitionId, roleName: roleName,
                     scope: scope, scopeName: scopeName, scopeType: scopeType, membership: .direct)
    }

    public var scopeTypeLabel: String { asRole.scopeTypeLabel }
}

/// What the approver listing returned.
public struct ApprovalInbox: Equatable, Sendable {
    public var requests: [ApprovalRequest]
    /// Set when ARM refused the listing (no approver permissions, the preview
    /// endpoint unavailable, …): show "nothing to review", not an error.
    public var unavailable: String?

    public init(requests: [ApprovalRequest] = [], unavailable: String? = nil) {
        self.requests = requests
        self.unavailable = unavailable
    }

    public var isEmpty: Bool { requests.isEmpty }

    /// HTTP statuses that mean "you cannot list approvals here" rather than
    /// a failure worth an error: forbidden, not found, or the preview
    /// endpoint refusing the call.
    public static func isQuietRefusal(_ status: Int) -> Bool { status == 400 || status == 403 || status == 404 }
}

public enum ApprovalParser {
    /// Request statuses that wait for an approver's decision. (`PendingAdminDecision`
    /// is a `SelfExtend` for an administrator; ARM cannot approve those.)
    public static let decidableStatuses: Set<String> = ["pendingapproval", "pendingapprovalprovisioning"]

    /// Requests among `items` that wait for your decision, joined with their
    /// approvals' stages; oldest first (they expire first). Your own requests
    /// are left out: PIM does not let you approve them.
    public static func inbox(
        requests items: [AssignmentScheduleRequestItem], approvals: [RoleAssignmentApprovalItem], me: String?
    ) -> [ApprovalRequest] {
        var stagesByApproval: [String: [ApprovalStage]] = [:]
        for a in approvals {
            guard let key = (a.name ?? a.id.map(RoleMatcher.lastPathComponent))?.lowercased(), !key.isEmpty else { continue }
            stagesByApproval[key] = ApprovalStage.parse(a.properties?.stages ?? [])
        }
        var seen = Set<String>()
        let requests = items.compactMap { item -> ApprovalRequest? in
            guard let p = item.properties, let status = p.status, decidableStatuses.contains(status.lowercased()),
                  let scope = p.scope, let roleDefinitionId = p.roleDefinitionId
            else { return nil }
            let principal = p.principalId ?? p.requestorId ?? ""
            if let me, !principal.isEmpty, principal.caseInsensitiveCompare(me) == .orderedSame { return nil }
            let name = item.name ?? item.id.map(RoleMatcher.lastPathComponent) ?? ""
            guard !name.isEmpty, seen.insert(name.lowercased()).inserted else { return nil }
            // ARM's sample says the approval id is the request name; prefer the explicit field.
            let approvalId = p.approvalId.map(RoleMatcher.lastPathComponent)?.nonEmpty ?? name
            let start = AzureDate.parse(p.scheduleInfo?.startDateTime)
            let expiration = p.scheduleInfo?.expiration
            let end = AzureDate.parse(expiration?.endDateTime)
                ?? start.flatMap { s in ISODuration.parse(expiration?.duration).map { s.addingTimeInterval($0) } }
            let x = p.expandedProperties
            return ApprovalRequest(
                id: item.id ?? name, name: name, approvalId: approvalId,
                stage: ApprovalStage.decidable(stagesByApproval[approvalId.lowercased()] ?? []),
                scope: scope, roleDefinitionId: roleDefinitionId,
                roleName: x?.roleDefinition?.displayName ?? RoleMatcher.lastPathComponent(roleDefinitionId),
                scopeName: x?.scope?.displayName ?? RoleMatcher.lastPathComponent(scope),
                scopeType: x?.scope?.type ?? RoleMatcher.inferScopeType(scope),
                requesterId: principal, requesterName: x?.principal?.displayName?.nonEmpty, requesterEmail: x?.principal?.email?.nonEmpty,
                status: status, requestType: p.requestType ?? RequestAction.activate.requestType,
                start: start, end: end, justification: p.justification?.nonEmpty,
                ticketNumber: p.ticketInfo?.ticketNumber?.nonEmpty, ticketSystem: p.ticketInfo?.ticketSystem?.nonEmpty,
                createdOn: AzureDate.parse(p.createdOn))
        }
        return requests.sorted {
            ($0.createdOn ?? .distantPast, $0.requesterLabel.lowercased(), $0.roleName) < ($1.createdOn ?? .distantPast, $1.requesterLabel.lowercased(), $1.roleName)
        }
    }

    /// Requests in `current` that were not in `previous` (the last listing).
    /// nil `previous` (the first listing) reports nothing: only arrivals
    /// while Pimento watches are news.
    public static func arrivals(previous: Set<String>?, current: [ApprovalRequest]) -> [ApprovalRequest] {
        guard let previous else { return [] }
        return current.filter { !previous.contains($0.name.lowercased()) }
    }

    /// The names a listing is remembered by, for `arrivals`.
    public static func names(_ requests: [ApprovalRequest]) -> Set<String> { Set(requests.map { $0.name.lowercased() }) }
}

/// Approve or deny.
public enum ApprovalDecision: String, CaseIterable, Sendable {
    case approve = "Approve"
    case deny = "Deny"

    /// `reviewResult` in the request body.
    public var reviewResult: String { rawValue }
    /// `approve` / `deny`: the CLI command.
    public var command: String { rawValue.lowercased() }
    /// `approved` / `denied`.
    public var pastTense: String { self == .approve ? "approved" : "denied" }
}

/// Body of the stage PATCH. ARM's REST reference lists `reviewResult` and
/// `justification` as top-level fields of the body (the PIM how-to does the
/// same); one sample wraps them in `properties`. Pimento follows the reference.
public struct ApprovalDecisionBody: Codable, Equatable, Sendable {
    public let reviewResult: String
    public let justification: String

    public init(decision: ApprovalDecision, justification: String) {
        reviewResult = decision.reviewResult
        self.justification = justification
    }
}

public enum ApprovalDecisionError: Error, Equatable, LocalizedError {
    case missingJustification

    public var errorDescription: String? {
        switch self {
        case .missingJustification: "A justification is required to approve or deny."
        }
    }
}

/// One decision, ready to send: what dry runs show.
public struct PlannedDecision: Identifiable, Equatable, Sendable {
    public var id: String { request.name }
    public let request: ApprovalRequest
    public let decision: ApprovalDecision
    public let body: ApprovalDecisionBody
    /// nil when no stage of the approval waits for you.
    public var url: URL? { request.stage.flatMap { ARM.approvalStageURL(approvalId: request.approvalId, stageId: $0.id) } }

    public var bodyJSON: Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(body)) ?? Data()
    }

    public var prettyBody: String { String(decoding: bodyJSON, as: UTF8.self) }

    public static func plan(_ requests: [ApprovalRequest], decision: ApprovalDecision, justification: String) throws -> [PlannedDecision] {
        let text = justification.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw ApprovalDecisionError.missingJustification }
        return requests.map { PlannedDecision(request: $0, decision: decision, body: ApprovalDecisionBody(decision: decision, justification: text)) }
    }
}

/// What sending a decision did.
public enum DecisionOutcome: Equatable, Sendable {
    case decided(ApprovalDecision)
    /// No open stage waits for you: decided by someone else, expired, or not yours.
    case notPending(String)
    case failed(code: String, message: String)

    public var isFailure: Bool {
        if case .decided = self { return false }
        return true
    }

    public var isAuthFailure: Bool {
        guard case .failed(let code, _) = self else { return false }
        return ActivationResponseMapper.authErrorCodes.contains(code)
    }

    public var summary: String {
        switch self {
        case .decided(let d): d == .approve ? "Approved" : "Denied"
        case .notPending(let why): "Not pending any more: \(why)"
        case .failed(let code, let message): message.isEmpty ? code : "\(code): \(message)"
        }
    }

    public static let noOpenStageMessage = "no stage of this approval waits for you (decided by someone else, expired, or not assigned to you)"

    public static func from(statusCode: Int, data: Data, decision: ApprovalDecision) -> DecisionOutcome {
        if (200..<300).contains(statusCode) { return .decided(decision) }
        let (code, message) = ActivationResponseMapper.error(statusCode: statusCode, data: data)
        if ActivationResponseMapper.authErrorCodes.contains(code) {
            return .failed(code: code, message: "Token rejected. Refresh, or sign in again with `az login`. (\(message))")
        }
        if statusCode == 404 { return .notPending(noOpenStageMessage) }
        if statusCode == 403 { return .failed(code: code, message: "You may not decide this request. (\(message))") }
        return .failed(code: code, message: message)
    }
}

// MARK: - Requester side

/// How a request that waited for approval ended.
public enum RequestResolution: Equatable, Sendable {
    /// Approved: the role is active (or starts at `start`) until `until`.
    case approved(until: Date?)
    case denied
    /// Nobody decided within 24 hours (`TimedOut`).
    case expired
    case canceled
    case failed(status: String)

    /// nil while the status still waits for a decision (or is unknown).
    public init?(status: String, until: Date? = nil) {
        switch status.lowercased() {
        case "provisioned", "granted", "accepted", "adminapproved", "schedulecreated", "pendingschedulecreation",
             "pendingprovisioning", "provisioningstarted", "pendingexternalprovisioning":
            self = .approved(until: until)
        case "denied", "admindenied": self = .denied
        case "timedout": self = .expired
        case "canceled", "cancelled", "revoked": self = .canceled
        case "failed", "failedasresourceislocked", "invalid": self = .failed(status: status)
        default: return nil
        }
    }

    public var isApproved: Bool {
        if case .approved = self { return true }
        return false
    }

    /// `approved`, `denied`, `expired`, `canceled`, `failed` (JSON).
    public var label: String {
        switch self {
        case .approved: "approved"
        case .denied: "denied"
        case .expired: "expired"
        case .canceled: "canceled"
        case .failed: "failed"
        }
    }
}

/// What the approver said, read from the approval's stages (best effort: the
/// requester may not be allowed to read them).
public struct ReviewInfo: Equatable, Sendable {
    public var reviewer: String?
    public var justification: String?

    public init(reviewer: String? = nil, justification: String? = nil) {
        self.reviewer = reviewer
        self.justification = justification
    }

    /// The last reviewed stage's reviewer and justification.
    public init?(stages: [ApprovalStage]) {
        guard let stage = stages.last(where: \.isReviewed) else { return nil }
        reviewer = stage.reviewedBy
        justification = stage.justification
    }
}

/// A tracked request that was decided.
public struct ApprovalTransition: Equatable, Sendable {
    public let request: ScheduledRequest
    public let resolution: RequestResolution
    /// The status that decided it (`Provisioned`, `Denied`, `TimedOut`, …).
    public let status: String

    public init(request: ScheduledRequest, resolution: RequestResolution, status: String) {
        self.request = request
        self.resolution = resolution
        self.status = status
    }
}

/// Follows your requests that wait for approval from one listing to the next
/// and reports the ones that were decided. Pure: the caller lists
/// `roleAssignmentScheduleRequests` (`asTarget()`) and feeds the items in.
public struct ApprovalTracker: Equatable, Sendable {
    /// Waiting requests by lower-cased name.
    public private(set) var pending: [String: ScheduledRequest] = [:]
    private var misses: [String: Int] = [:]
    /// Listings in a row a tracked request may be missing from before it is
    /// dropped silently (it should not vanish; if it does, nothing is said).
    public static let maxMisses = 3

    public init() {}

    public var isEmpty: Bool { pending.isEmpty }
    public var count: Int { pending.count }

    /// Starts following `requests` (they must be waiting for approval).
    public mutating func track(_ requests: [ScheduledRequest]) {
        for r in requests where r.kind == .awaitingApproval {
            pending[r.name.lowercased()] = r
            misses[r.name.lowercased()] = nil
        }
    }

    public mutating func forget(_ name: String) {
        pending[name.lowercased()] = nil
        misses[name.lowercased()] = nil
    }

    /// Feeds a fresh listing in. Tracked requests whose status changed to a
    /// decision are returned (and no longer tracked); with `trackNew`, requests
    /// that newly wait for approval are followed from now on.
    public mutating func update(
        items: [AssignmentScheduleRequestItem], principalId: String?, now: Date, trackNew: Bool = true
    ) -> [ApprovalTransition] {
        var byName: [String: AssignmentScheduleRequestItem] = [:]
        for item in items {
            guard let p = item.properties else { continue }
            if let principalId, let mine = p.principalId, mine.caseInsensitiveCompare(principalId) != .orderedSame { continue }
            guard let name = (item.name ?? item.id.map(RoleMatcher.lastPathComponent))?.lowercased(), !name.isEmpty else { continue }
            byName[name] = item
        }
        var transitions: [ApprovalTransition] = []
        for (name, request) in pending.sorted(by: { $0.key < $1.key }) {
            guard let item = byName[name], let status = item.properties?.status else {
                let n = (misses[name] ?? 0) + 1
                if n >= Self.maxMisses { forget(name) } else { misses[name] = n }
                continue
            }
            misses[name] = nil
            if let resolution = RequestResolution(status: status, until: Self.end(of: item)) {
                transitions.append(ApprovalTransition(request: request, resolution: resolution, status: status))
                forget(name)
            }
        }
        if trackNew {
            let waiting = ScheduledRequestParser.pending(items, principalId: principalId, now: now).filter { $0.kind == .awaitingApproval }
            for r in waiting where pending[r.name.lowercased()] == nil { track([r]) }
        }
        return transitions
    }

    /// When the activation a request asks for ends.
    static func end(of item: AssignmentScheduleRequestItem) -> Date? {
        let s = item.properties?.scheduleInfo
        if let end = AzureDate.parse(s?.expiration?.endDateTime) { return end }
        guard let start = AzureDate.parse(s?.startDateTime), let d = ISODuration.parse(s?.expiration?.duration) else { return nil }
        return start.addingTimeInterval(d)
    }

    /// How a request (any status) stands: its resolution, or nil while it
    /// waits. For `pimento wait`, which may be given an already decided one.
    public static func resolution(of item: AssignmentScheduleRequestItem) -> RequestResolution? {
        guard let status = item.properties?.status else { return nil }
        return RequestResolution(status: status, until: end(of: item))
    }
}

/// When Pimento looks for decisions in the app.
public enum ApprovalPolling {
    /// How often the app re-reads your requests while some wait for approval.
    public static let interval: TimeInterval = 60

    /// Poll separately only while something waits, and not when a refresh
    /// every minute (auto-refresh) already reads the same list.
    public static func shouldPoll(pendingCount: Int, autoRefreshMinutes: Int) -> Bool {
        pendingCount > 0 && autoRefreshMinutes != 1
    }
}

// MARK: - Notifications

/// The text of approval notifications. Pure, so the wording is tested; the
/// app posts them.
public struct ApprovalNotice: Equatable, Sendable {
    public let id: String
    public let title: String
    public let body: String

    static let listed = 3

    /// A request of yours was decided. `until`: the activation's end as Azure
    /// lists it now (better than the request's own estimate).
    public static func decision(_ t: ApprovalTransition, review: ReviewInfo? = nil, until: Date? = nil,
                                now: Date, timeZone: TimeZone = .current) -> ApprovalNotice {
        let r = t.request
        let time = Date.FormatStyle(date: .omitted, time: .shortened, timeZone: timeZone)
        var lines: [String] = []
        let title: String
        switch t.resolution {
        case .approved(let estimate):
            let end = until ?? estimate
            if r.start > now.addingTimeInterval(ScheduleTime.immediateSlack) {
                title = "Approved: \(r.roleName)"
                lines.append("\(r.scopeName). Starts \(ScheduleTime.label(r.start, now: now, timeZone: timeZone))"
                    + (end.map { ", until \($0.formatted(time))" } ?? "") + ".")
            } else {
                title = "Approved and active: \(r.roleName)"
                lines.append(r.scopeName + (end.map { ". Active until \($0.formatted(time))." } ?? ". Active now."))
            }
        case .denied:
            title = "Denied: \(r.roleName)"
            lines.append(r.scopeName + ".")
        case .expired:
            title = "Request expired: \(r.roleName)"
            lines.append("\(r.scopeName). No approver decided within 24 hours; request it again.")
        case .canceled:
            title = "Request cancelled: \(r.roleName)"
            lines.append(r.scopeName + ".")
        case .failed(let status):
            title = "Request failed: \(r.roleName)"
            lines.append("\(r.scopeName). Status: \(status).")
        }
        if let review {
            if let text = review.justification {
                lines.append("“\(text)”" + (review.reviewer.map { " (\($0))" } ?? ""))
            } else if let who = review.reviewer {
                lines.append("By \(who).")
            }
        }
        return ApprovalNotice(id: "approval-\(r.name.lowercased())", title: title, body: lines.joined(separator: "\n"))
    }

    /// New requests for you to decide; nil when there are none.
    public static func arrivals(_ requests: [ApprovalRequest]) -> ApprovalNotice? {
        guard !requests.isEmpty else { return nil }
        let lines = requests.prefix(listed).map { "\($0.requesterName ?? $0.requesterEmail ?? "Someone"): \($0.roleName) · \($0.scopeName)" }
        let more = requests.count - lines.count
        let n = requests.count
        return ApprovalNotice(
            id: "approvals-" + requests.map { $0.name.lowercased() }.sorted().joined(separator: ",").prefix(200),
            title: n == 1 ? "Approval requested" : "\(n) approvals requested",
            body: (lines + (more > 0 ? ["and \(more) more"] : [])).joined(separator: "\n"))
    }
}

// MARK: - Service

extension PIMService {
    /// The requests you may decide, with the stage to decide. Read-only.
    /// ARM refusing the listing (403, 404, or 400 from the preview endpoint)
    /// is not an error: the inbox is empty and says why.
    public func loadApprovalInbox() async throws -> (identity: Identity, inbox: ApprovalInbox) {
        let token = try await tokens.accessToken()
        guard let identity = JWT.identity(fromToken: token) else { throw PIMServiceError.noIdentity }
        let items: [AssignmentScheduleRequestItem]
        do {
            items = try await listAll(ARM.approverRequestsURL, token: token)
        } catch PIMServiceError.http(let status, let message) where ApprovalInbox.isQuietRefusal(status) {
            return (identity, ApprovalInbox(unavailable: "HTTP \(status): \(message)"))
        }
        let waiting = items.filter { ApprovalParser.decidableStatuses.contains(($0.properties?.status ?? "").lowercased()) }
        guard !waiting.isEmpty else { return (identity, ApprovalInbox()) }
        // Stages come from the preview endpoint; without them the stage is read when deciding.
        let approvals: [RoleAssignmentApprovalItem] = (try? await listAll(ARM.approvalsURL, token: token)) ?? []
        return (identity, ApprovalInbox(requests: ApprovalParser.inbox(requests: waiting, approvals: approvals, me: identity.objectId)))
    }

    /// The stages of an approval (`GET …/roleAssignmentApprovals/{id}/stages`). Read-only.
    public func approvalStages(approvalId: String) async throws -> [ApprovalStage] {
        guard let url = ARM.approvalStagesURL(approvalId: approvalId) else { return [] }
        let token = try await tokens.accessToken()
        let items: [ApprovalStageItem] = try await listAll(url, token: token)
        return ApprovalStage.parse(items)
    }

    /// `requests` with the stage you can decide filled in where the listing
    /// did not name one (read-only). Requests without one keep `stage == nil`.
    public func resolvingStages(_ requests: [ApprovalRequest]) async -> [ApprovalRequest] {
        var result: [ApprovalRequest] = []
        for var r in requests {
            if r.stage == nil, let stages = try? await approvalStages(approvalId: r.approvalId) {
                r.stage = ApprovalStage.decidable(stages)
            }
            result.append(r)
        }
        return result
    }

    /// What the approver of a decided request said, if the requester may read it.
    public func review(approvalId: String?) async -> ReviewInfo? {
        guard let approvalId, let stages = try? await approvalStages(approvalId: approvalId) else { return nil }
        return ReviewInfo(stages: stages)
    }

    /// Sends the decisions (PATCH on each approval's open stage), a few at a
    /// time. A request without an open stage is not sent (`notPending`).
    public func decide(
        _ plans: [PlannedDecision], maxConcurrent: Int = 4,
        onResult: @escaping @Sendable (PlannedDecision, DecisionOutcome) async -> Void
    ) async throws {
        guard !plans.isEmpty else { return }
        let token = try await tokens.accessToken()
        await withTaskGroup(of: (PlannedDecision, DecisionOutcome).self) { group in
            var pending = plans.makeIterator()
            func enqueue(_ p: PlannedDecision) {
                group.addTask { (p, await self.decide(p, token: token)) }
            }
            for _ in 0..<max(1, maxConcurrent) {
                guard let next = pending.next() else { break }
                enqueue(next)
            }
            while let (p, outcome) = await group.next() {
                await onResult(p, outcome)
                if let next = pending.next() { enqueue(next) }
            }
        }
    }

    func decide(_ plan: PlannedDecision, token: String) async -> DecisionOutcome {
        guard let url = plan.url else { return .notPending(DecisionOutcome.noOpenStageMessage) }
        var request = URLRequest(url: url, timeoutInterval: 60)
        request.httpMethod = "PATCH"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = plan.bodyJSON
        do {
            let (data, status) = try await transport.send(request)
            return DecisionOutcome.from(statusCode: status, data: data, decision: plan.decision)
        } catch {
            return .failed(code: "NetworkError", message: error.localizedDescription)
        }
    }
}
