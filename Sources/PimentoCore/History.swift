import Foundation

// The local history of every write Pimento sends (app and CLI): one JSON
// object per line in `history.jsonl` (see `HistoryStore`). A record holds what
// was asked and how Azure answered, never a token or a raw request/response body.

/// What a record is about. A string underneath, so records written by a newer
/// Pimento with an action this one does not know still load.
public struct HistoryAction: RawRepresentable, Hashable, Codable, Sendable, Comparable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    public static let activate = HistoryAction(rawValue: "activate")
    /// An activation with a later start.
    public static let schedule = HistoryAction(rawValue: "schedule")
    /// A scheduled or pending request withdrawn.
    public static let cancel = HistoryAction(rawValue: "cancel")
    public static let deactivate = HistoryAction(rawValue: "deactivate")
    public static let renew = HistoryAction(rawValue: "renew")
    public static let extend = HistoryAction(rawValue: "extend")
    public static let approve = HistoryAction(rawValue: "approve")
    public static let deny = HistoryAction(rawValue: "deny")

    public static let known: [HistoryAction] = [.activate, .schedule, .cancel, .deactivate, .renew, .extend, .approve, .deny]

    /// `Activate`, `Schedule`, …; an unknown action as stored.
    public var title: String {
        guard let first = rawValue.first else { return "" }
        return first.uppercased() + rawValue.dropFirst()
    }

    /// Activations that "Activate again" can repeat.
    public var isActivation: Bool { self == .activate || self == .schedule || self == .renew }

    /// `activate`, `ACTIVATE`, `Activate` (CLI `--action`); nil when unknown.
    public init?(argument: String) {
        let a = argument.trimmingCharacters(in: .whitespaces).lowercased()
        guard let match = Self.known.first(where: { $0.rawValue == a }) else { return nil }
        self = match
    }

    public init(from decoder: Decoder) throws { rawValue = try decoder.singleValueContainer().decode(String.self) }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(rawValue)
    }

    public static func < (a: HistoryAction, b: HistoryAction) -> Bool { a.rawValue < b.rawValue }
}

/// How a request ended, in a few words.
public struct HistoryResult: RawRepresentable, Hashable, Codable, Sendable, Comparable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    /// Done as asked (activated, scheduled, ended, cancelled, approved, …).
    public static let succeeded = HistoryResult(rawValue: "succeeded")
    /// Accepted, waiting for an approver or administrator.
    public static let pending = HistoryResult(rawValue: "pending")
    /// Nothing to do (already active, already ended, decided by someone else).
    public static let skipped = HistoryResult(rawValue: "skipped")
    public static let failed = HistoryResult(rawValue: "failed")
    /// Azure import: an approver said no.
    public static let denied = HistoryResult(rawValue: "denied")
    /// Azure import: withdrawn before it took effect.
    public static let canceled = HistoryResult(rawValue: "canceled")
    /// Azure import: nobody decided within 24 hours.
    public static let expired = HistoryResult(rawValue: "expired")
    /// Azure import: a status Pimento does not know.
    public static let unknown = HistoryResult(rawValue: "unknown")

    public static let known: [HistoryResult] = [.succeeded, .pending, .skipped, .failed, .denied, .canceled, .expired, .unknown]

    public var title: String {
        switch self {
        case .succeeded: "Succeeded"
        case .pending: "Pending"
        case .skipped: "Skipped"
        case .failed: "Failed"
        case .denied: "Denied"
        case .canceled: "Cancelled"
        case .expired: "Expired"
        case .unknown: "Unknown"
        default: rawValue.prefix(1).uppercased() + rawValue.dropFirst()
        }
    }

    /// Did not do what was asked.
    public var isFailure: Bool { self == .failed || self == .denied || self == .expired }

    public init?(argument: String) {
        let a = argument.trimmingCharacters(in: .whitespaces).lowercased()
        let aliases = ["ok": "succeeded", "success": "succeeded", "cancelled": "canceled", "error": "failed"]
        let name = aliases[a] ?? a
        guard let match = Self.known.first(where: { $0.rawValue == name }) else { return nil }
        self = match
    }

    public init(from decoder: Decoder) throws { rawValue = try decoder.singleValueContainer().decode(String.self) }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(rawValue)
    }

    public static func < (a: HistoryResult, b: HistoryResult) -> Bool { a.rawValue < b.rawValue }
}

/// Who wrote a record.
public struct HistorySource: RawRepresentable, Hashable, Codable, Sendable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    public static let app = HistorySource(rawValue: "app")
    public static let cli = HistorySource(rawValue: "cli")
    /// An AI agent through `pimento mcp` (after the user confirmed).
    public static let mcp = HistorySource(rawValue: "mcp")
    /// Read from Azure (`pimento history import-azure`, Import from Azure).
    public static let azure = HistorySource(rawValue: "azure")

    public var title: String {
        switch self {
        case .app: "App"
        case .cli: "CLI"
        case .mcp: "MCP"
        case .azure: "Azure"
        default: rawValue
        }
    }

    public init(from decoder: Decoder) throws { rawValue = try decoder.singleValueContainer().decode(String.self) }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(rawValue)
    }
}

/// One line of the history file.
public struct HistoryRecord: Codable, Hashable, Identifiable, Sendable {
    public static let formatVersion = 1

    /// A fresh UUID per record.
    public var id: String
    /// When Azure answered (local records) or the request was made (Azure import).
    public var at: Date
    public var action: HistoryAction
    public var result: HistoryResult
    /// Azure's request status (`Provisioned`, `PendingApproval`, …) or error code.
    public var status: String?
    /// A short, single-line explanation (errors, skips).
    public var message: String?
    public var tenantId: String?
    /// The tenant's display name or domain, when known.
    public var tenantLabel: String?
    public var scope: String
    public var scopeName: String?
    public var scopeType: String?
    public var roleName: String?
    public var roleDefinitionId: String?
    /// What was asked: `PT8H`, `max` (activations), `P30D` (extend).
    public var requestedDuration: String?
    /// What was requested after the policy cap, in minutes.
    public var durationMinutes: Int?
    public var start: Date?
    public var end: Date?
    public var justification: String?
    public var ticketNumber: String?
    public var ticketSystem: String?
    /// The request GUID (`roleAssignmentScheduleRequests/{name}`).
    public var requestId: String?
    /// Another request the action sent (the deactivation of a renewal).
    public var relatedRequestId: String?
    /// Approve/deny: who asked.
    public var requester: String?
    public var source: HistorySource
    /// The Pimento version that wrote it (nil for Azure imports).
    public var version: String?

    public init(
        id: String = UUID().uuidString.lowercased(), at: Date, action: HistoryAction, result: HistoryResult,
        status: String? = nil, message: String? = nil, tenantId: String? = nil, tenantLabel: String? = nil,
        scope: String, scopeName: String? = nil, scopeType: String? = nil, roleName: String? = nil,
        roleDefinitionId: String? = nil, requestedDuration: String? = nil, durationMinutes: Int? = nil,
        start: Date? = nil, end: Date? = nil, justification: String? = nil, ticketNumber: String? = nil,
        ticketSystem: String? = nil, requestId: String? = nil, relatedRequestId: String? = nil,
        requester: String? = nil, source: HistorySource, version: String? = nil
    ) {
        self.id = id
        self.at = at
        self.action = action
        self.result = result
        self.status = status
        self.message = message
        self.tenantId = tenantId
        self.tenantLabel = tenantLabel
        self.scope = scope
        self.scopeName = scopeName
        self.scopeType = scopeType
        self.roleName = roleName
        self.roleDefinitionId = roleDefinitionId
        self.requestedDuration = requestedDuration
        self.durationMinutes = durationMinutes
        self.start = start
        self.end = end
        self.justification = justification
        self.ticketNumber = ticketNumber
        self.ticketSystem = ticketSystem
        self.requestId = requestId
        self.relatedRequestId = relatedRequestId
        self.requester = requester
        self.source = source
        self.version = version
    }

    enum CodingKeys: String, CodingKey {
        case v, id, at, action, result, status, message, tenantId, tenantLabel, scope, scopeName, scopeType, roleName
        case roleDefinitionId, requestedDuration, durationMinutes, start, end, justification, ticketNumber, ticketSystem
        case requestId, relatedRequestId, requester, source, version
    }

    /// Lenient: unknown keys are ignored and a mistyped optional field is
    /// dropped. Only `at`, `action` and `scope` are required.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func string(_ key: CodingKeys) -> String? { (try? c.decodeIfPresent(String.self, forKey: key))?.flatMap { $0.isEmpty ? nil : $0 } }
        func date(_ key: CodingKeys) -> Date? { AzureDate.parse(string(key)) }
        guard let at = date(.at) else {
            throw DecodingError.dataCorruptedError(forKey: .at, in: c, debugDescription: "missing or unreadable timestamp")
        }
        guard let action = string(.action) else {
            throw DecodingError.dataCorruptedError(forKey: .action, in: c, debugDescription: "missing action")
        }
        self.at = at
        self.action = HistoryAction(rawValue: action)
        id = string(.id) ?? UUID().uuidString.lowercased()
        result = string(.result).map(HistoryResult.init(rawValue:)) ?? .unknown
        status = string(.status)
        message = string(.message)
        tenantId = string(.tenantId)
        tenantLabel = string(.tenantLabel)
        scope = string(.scope) ?? ""
        scopeName = string(.scopeName)
        scopeType = string(.scopeType)
        roleName = string(.roleName)
        roleDefinitionId = string(.roleDefinitionId)
        requestedDuration = string(.requestedDuration)
        durationMinutes = try? c.decodeIfPresent(Int.self, forKey: .durationMinutes)
        start = date(.start)
        end = date(.end)
        justification = string(.justification)
        ticketNumber = string(.ticketNumber)
        ticketSystem = string(.ticketSystem)
        requestId = string(.requestId)
        relatedRequestId = string(.relatedRequestId)
        requester = string(.requester)
        source = string(.source).map(HistorySource.init(rawValue:)) ?? .app
        version = string(.version)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(Self.formatVersion, forKey: .v)
        try c.encode(id, forKey: .id)
        try c.encode(AzureDate.format(at), forKey: .at)
        try c.encode(action, forKey: .action)
        try c.encode(result, forKey: .result)
        try c.encodeIfPresent(status, forKey: .status)
        try c.encodeIfPresent(message, forKey: .message)
        try c.encodeIfPresent(tenantId, forKey: .tenantId)
        try c.encodeIfPresent(tenantLabel, forKey: .tenantLabel)
        try c.encode(scope, forKey: .scope)
        try c.encodeIfPresent(scopeName, forKey: .scopeName)
        try c.encodeIfPresent(scopeType, forKey: .scopeType)
        try c.encodeIfPresent(roleName, forKey: .roleName)
        try c.encodeIfPresent(roleDefinitionId, forKey: .roleDefinitionId)
        try c.encodeIfPresent(requestedDuration, forKey: .requestedDuration)
        try c.encodeIfPresent(durationMinutes, forKey: .durationMinutes)
        try c.encodeIfPresent(start.map(AzureDate.format), forKey: .start)
        try c.encodeIfPresent(end.map(AzureDate.format), forKey: .end)
        try c.encodeIfPresent(justification, forKey: .justification)
        try c.encodeIfPresent(ticketNumber, forKey: .ticketNumber)
        try c.encodeIfPresent(ticketSystem, forKey: .ticketSystem)
        try c.encodeIfPresent(requestId, forKey: .requestId)
        try c.encodeIfPresent(relatedRequestId, forKey: .relatedRequestId)
        try c.encodeIfPresent(requester, forKey: .requester)
        try c.encode(source, forKey: .source)
        try c.encodeIfPresent(version, forKey: .version)
    }

    /// One line of JSON, without the newline.
    public func jsonLine() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    /// `Contoso`, else the first block of the tenant GUID.
    public var tenantDisplay: String {
        tenantLabel ?? tenantId.map { UUID(uuidString: $0) != nil ? String($0.prefix(8)) : $0 } ?? ""
    }

    public var roleDisplay: String { roleName ?? roleDefinitionId.map(RoleMatcher.lastPathComponent) ?? "" }
    public var scopeDisplay: String { scopeName ?? RoleMatcher.lastPathComponent(scope) }

    /// The first 8 characters of the request GUID.
    public var shortRequestId: String? { requestId.map { String($0.prefix(8)) } }

    public var ticket: TicketInfo? { TicketInfo.make(number: ticketNumber, system: ticketSystem) }

    public var isOwner: Bool {
        roleDefinitionId.map { RoleMatcher.lastPathComponent($0).lowercased() == EligibleRole.ownerRoleGUID } ?? false
            || roleName?.caseInsensitiveCompare("Owner") == .orderedSame
    }

    /// The duration as asked, for people: `8 h`, `Maximum`, `30 days`.
    public var durationText: String? {
        if let minutes = durationMinutes, minutes > 0 {
            if action == .extend, minutes % 1440 == 0 { return "\(minutes / 1440) day\(minutes == 1440 ? "" : "s")" }
            return DurationText.short(minutes: minutes)
        }
        if requestedDuration == "max" { return "Maximum" }
        return nil
    }

    /// Scope + role, to find the eligibility row again.
    public var policyKey: RoleMatcher.Key? {
        guard let roleDefinitionId, !scope.isEmpty else { return nil }
        return RoleMatcher.key(scope: scope, roleDefinitionId: roleDefinitionId)
    }

    /// Request ids this record stands for (lower-cased), for de-duplication.
    var requestIds: [String] { [requestId, relatedRequestId].compactMap { $0?.lowercased() } }
}

// MARK: - From what was sent

/// What every record of one write shares: who, where, when, from where.
public struct HistoryContext: Sendable, Equatable {
    public var tenantId: String?
    public var tenantLabel: String?
    public var source: HistorySource
    public var version: String?
    public var at: Date

    public init(tenantId: String?, tenantLabel: String? = nil, source: HistorySource, version: String? = AppInfo.version, at: Date) {
        self.tenantId = tenantId
        self.tenantLabel = tenantLabel
        self.source = source
        self.version = version
        self.at = at
    }
}

extension HistoryRecord {
    /// The longest message a record keeps.
    public static let maxMessageLength = 300

    /// `text` on one line and capped. Something that looks like a raw body
    /// (JSON or HTML) is not kept.
    public static func shortMessage(_ text: String?) -> String? {
        guard var s = text?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        if s.hasPrefix("{") || s.hasPrefix("[") || s.hasPrefix("<") { return nil }
        s = s.components(separatedBy: .newlines).filter { !$0.isEmpty }.joined(separator: " ")
        if s.count > maxMessageLength { s = String(s.prefix(maxMessageLength - 1)) + "…" }
        return s
    }

    /// Result, status and message of an activation-type outcome.
    public static func describe(_ outcome: ActivationOutcome) -> (HistoryResult, String?, String?) {
        switch outcome {
        case .activated(let status, _):
            let s = status.nonEmpty
            if ActivationOutcome.isGranted(status: status) { return (.succeeded, s ?? "Provisioned", nil) }
            return (.pending, s, outcome.isAwaitingApproval ? "awaiting approval" : "submitted, waiting for a decision")
        case .alreadyActive:
            return (.skipped, "RoleAssignmentExists", "already active")
        case .policyViolation(let rules, let message):
            return (.failed, "RoleAssignmentRequestPolicyValidationFailed",
                    shortMessage(rules.isEmpty ? message : rules.map(ActivationResponseMapper.describe(rule:)).joined(separator: "; ")))
        case .failed(let code, let message):
            return (.failed, code.nonEmpty, shortMessage(message))
        case .deactivated(let status):
            return (ActivationOutcome.isEnded(status: status) ? .succeeded : .pending, status.nonEmpty ?? "Revoked", nil)
        case .notActive:
            return (.skipped, "RoleAssignmentDoesNotExist", "not active (already ended)")
        case .tooSoon:
            return (.failed, "ActiveDurationTooShort", "PIM ends an activation only after 5 minutes")
        case .renewed:
            return (.succeeded, "Provisioned", nil)
        case .scheduled(let status, _, _):
            return (.succeeded, status.nonEmpty ?? "Granted", nil)
        }
    }

    /// The record of one activation, scheduled activation, deactivation or
    /// extension request and its outcome.
    public init(plan: PlannedRequest, outcome: ActivationOutcome, context: HistoryContext) {
        let (result, status, message) = Self.describe(outcome)
        let p = plan.body.properties
        let action: HistoryAction = switch plan.action {
        case .activate: plan.start == nil ? .activate : .schedule
        case .deactivate: .deactivate
        case .extend: .extend
        }
        var start: Date?, end: Date?
        var requested: String?, minutes: Int?
        switch plan.action {
        case .activate:
            start = plan.start ?? plan.requestedAt
            end = plan.plannedEnd
            requested = plan.duration.requested.stringValue
            minutes = plan.minutes
            switch outcome {
            case .activated(_, let until?): end = until
            case .scheduled(_, let s, let until): start = s; end = until ?? end
            default: break
            }
        case .deactivate:
            end = plan.requestedAt
        case .extend:
            start = AzureDate.parse(p.scheduleInfo?.startDateTime)
            end = AzureDate.parse(p.scheduleInfo?.expiration.endDateTime)
            minutes = plan.duration.minutes > 0 ? plan.duration.minutes : nil
            requested = minutes.map { "P\($0 / 1440)D" }
        }
        self.init(
            at: context.at, action: action, result: result, status: status, message: message,
            tenantId: context.tenantId, tenantLabel: context.tenantLabel,
            scope: plan.role.scope, scopeName: plan.role.scopeName.nonEmpty, scopeType: plan.role.scopeType.nonEmpty,
            roleName: plan.role.roleName.nonEmpty, roleDefinitionId: plan.role.roleDefinitionId.nonEmpty,
            requestedDuration: requested, durationMinutes: minutes, start: start, end: end,
            justification: p.justification.nonEmpty, ticketNumber: p.ticketInfo?.ticketNumber, ticketSystem: p.ticketInfo?.ticketSystem,
            requestId: plan.requestId, source: context.source, version: context.version)
    }

    /// The record of a renewal: one per role, whatever the number of attempts.
    /// `requestId`: the activation that was sent last.
    public init(renewal plan: RenewPlan, outcome: ActivationOutcome, requestId: String?, context: HistoryContext) {
        let (result, status, message) = Self.describe(outcome)
        var end: Date?
        if case .renewed(let until) = outcome { end = until }
        self.init(
            at: context.at, action: .renew, result: result, status: status, message: message,
            tenantId: context.tenantId, tenantLabel: context.tenantLabel,
            scope: plan.role.scope, scopeName: plan.role.scopeName.nonEmpty, scopeType: plan.role.scopeType.nonEmpty,
            roleName: plan.role.roleName.nonEmpty, roleDefinitionId: plan.role.roleDefinitionId.nonEmpty,
            requestedDuration: plan.duration.requested.stringValue, durationMinutes: plan.duration.minutes,
            start: result == .succeeded ? context.at : nil, end: end,
            justification: plan.justification.nonEmpty, ticketNumber: plan.ticket?.ticketNumber, ticketSystem: plan.ticket?.ticketSystem,
            requestId: requestId ?? plan.plannedActivation.requestId, relatedRequestId: plan.deactivation.requestId,
            source: context.source, version: context.version)
    }

    /// The record of cancelling a scheduled or pending request.
    public init(cancelled r: ScheduledRequest, outcome: CancelOutcome, context: HistoryContext) {
        let result: HistoryResult, status: String?, message: String?
        switch outcome {
        case .canceled: (result, status, message) = (.succeeded, "Canceled", nil)
        case .notCancellable: (result, status, message) = (.failed, CancelOutcome.notCancellableCode, "cannot be cancelled any more (started, cancelled or decided)")
        case .failed(let code, let m): (result, status, message) = (.failed, code.nonEmpty, Self.shortMessage(m))
        }
        self.init(
            at: context.at, action: .cancel, result: result, status: status, message: message,
            tenantId: context.tenantId, tenantLabel: context.tenantLabel,
            scope: r.scope, scopeName: r.scopeName.nonEmpty, scopeType: r.scopeType.nonEmpty,
            roleName: r.roleName.nonEmpty, roleDefinitionId: r.roleDefinitionId.nonEmpty,
            durationMinutes: r.durationMinutes, start: r.start, end: r.end,
            justification: r.justification, ticketNumber: r.ticketNumber, ticketSystem: r.ticketSystem,
            requestId: r.name.nonEmpty, source: context.source, version: context.version)
    }

    /// The record of an approval decision on someone else's request. The
    /// justification is the approver's.
    public init(decision plan: PlannedDecision, outcome: DecisionOutcome, context: HistoryContext) {
        let result: HistoryResult, status: String?, message: String?
        switch outcome {
        case .decided(let d): (result, status, message) = (.succeeded, d == .approve ? "Approved" : "Denied", nil)
        case .notPending(let why): (result, status, message) = (.skipped, nil, Self.shortMessage(why))
        case .failed(let code, let m): (result, status, message) = (.failed, code.nonEmpty, Self.shortMessage(m))
        }
        let r = plan.request
        self.init(
            at: context.at, action: plan.decision == .approve ? .approve : .deny, result: result, status: status, message: message,
            tenantId: context.tenantId, tenantLabel: context.tenantLabel,
            scope: r.scope, scopeName: r.scopeName.nonEmpty, scopeType: r.scopeType.nonEmpty,
            roleName: r.roleName.nonEmpty, roleDefinitionId: r.roleDefinitionId.nonEmpty,
            durationMinutes: r.durationMinutes, start: r.start, end: r.end,
            justification: plan.body.justification.nonEmpty, ticketNumber: r.ticketNumber, ticketSystem: r.ticketSystem,
            requestId: r.name.nonEmpty, requester: r.requesterLabel.nonEmpty, source: context.source, version: context.version)
    }
}

// MARK: - Filtering

/// Which records to show. Empty sets match everything.
public struct HistoryFilter: Equatable, Sendable {
    public var since: Date?
    public var until: Date?
    public var actions: Set<HistoryAction> = []
    public var results: Set<HistoryResult> = []
    public var sources: Set<HistorySource> = []
    /// A tenant GUID, or part of a tenant's name (case-insensitive).
    public var tenant: String?
    /// Words that must all appear in role, resource, scope, justification,
    /// ticket, request id, requester or message (case-insensitive).
    public var text = ""

    public init(since: Date? = nil, until: Date? = nil, actions: Set<HistoryAction> = [], results: Set<HistoryResult> = [],
                sources: Set<HistorySource> = [], tenant: String? = nil, text: String = "") {
        self.since = since
        self.until = until
        self.actions = actions
        self.results = results
        self.sources = sources
        self.tenant = tenant
        self.text = text
    }

    public func matches(_ r: HistoryRecord) -> Bool {
        if let since, r.at < since { return false }
        if let until, r.at > until { return false }
        if !actions.isEmpty, !actions.contains(r.action) { return false }
        if !results.isEmpty, !results.contains(r.result) { return false }
        if !sources.isEmpty, !sources.contains(r.source) { return false }
        if let t = tenant?.trimmingCharacters(in: .whitespaces), !t.isEmpty {
            let byId = r.tenantId?.caseInsensitiveCompare(t) == .orderedSame
            let byName = r.tenantLabel?.localizedCaseInsensitiveContains(t) ?? false
            guard byId || byName else { return false }
        }
        let words = text.split(whereSeparator: \.isWhitespace)
        if !words.isEmpty {
            let haystack = [r.roleName, r.scopeName, r.scope, r.justification, r.ticketNumber, r.ticketSystem, r.requestId,
                            r.requester, r.message, r.status, r.tenantLabel, r.action.rawValue]
                .compactMap { $0 }.joined(separator: "\n")
            guard words.allSatisfy({ haystack.localizedCaseInsensitiveContains($0) }) else { return false }
        }
        return true
    }

    /// The matching records, newest first, at most `limit`.
    public func apply(_ records: [HistoryRecord], limit: Int? = nil) -> [HistoryRecord] {
        let matching = HistoryLog.newestFirst(records.filter(matches))
        guard let limit, limit >= 0 else { return matching }
        return Array(matching.prefix(limit))
    }
}

public enum HistoryLog {
    /// Newest first; ties keep a stable order (by id).
    public static func newestFirst(_ records: [HistoryRecord]) -> [HistoryRecord] {
        records.sorted { ($0.at, $0.id) > ($1.at, $1.id) }
    }

    /// Records whose tenant has no name get the name another record of the
    /// same tenant has (the CLI does not know tenant names; the app does).
    public static func fillingTenantLabels(_ records: [HistoryRecord], known: [String: String] = [:]) -> [HistoryRecord] {
        var labels: [String: String] = [:]
        for (id, label) in known { labels[id.lowercased()] = label }
        for r in records {
            if let id = r.tenantId?.lowercased(), let label = r.tenantLabel, labels[id] == nil { labels[id] = label }
        }
        return records.map { r in
            guard r.tenantLabel == nil, let id = r.tenantId?.lowercased(), let label = labels[id] else { return r }
            var copy = r
            copy.tenantLabel = label
            return copy
        }
    }

    /// The tenants among `records` (id, display name), sorted by name.
    public static func tenants(in records: [HistoryRecord]) -> [(id: String, label: String)] {
        var seen: [String: String] = [:]
        for r in records {
            guard let id = r.tenantId?.lowercased() else { continue }
            if let label = r.tenantLabel { seen[id] = label } else if seen[id] == nil { seen[id] = r.tenantDisplay }
        }
        return seen.map { (id: $0.key, label: $0.value) }
            .sorted { $0.label.localizedStandardCompare($1.label) == .orderedAscending }
    }
}

// MARK: - Dates on the command line

/// `--since` / `--until`: `7d`, `24h`, `30m`, `2w`, `today`, `yesterday`,
/// `2026-10-01`, `2026-10-01 08:00`, or ISO 8601 with a zone.
public enum HistoryDate {
    /// `endOfDay` (for `--until`): a whole day (`today`, `yesterday`,
    /// `2026-10-01`) stands for its last moment, so that day is included.
    public static func parse(_ raw: String, now: Date, timeZone: TimeZone = .current, endOfDay: Bool = false) -> Date? {
        let s = raw.trimmingCharacters(in: .whitespaces).lowercased()
        guard !s.isEmpty else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        func day(_ start: Date?) -> Date? {
            guard endOfDay, let start else { return start }
            return calendar.date(byAdding: .day, value: 1, to: start)?.addingTimeInterval(-0.001)
        }
        switch s {
        case "today": return day(calendar.startOfDay(for: now))
        case "yesterday": return day(calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: now)))
        default: break
        }
        if let last = s.last, "mhdw".contains(last), let n = Int(s.dropLast()), n > 0, n <= 100_000 {
            let unit: TimeInterval = switch last {
            case "m": 60
            case "h": 3600
            case "d": 86400
            default: 7 * 86400
            }
            return now.addingTimeInterval(-TimeInterval(n) * unit)
        }
        if let date = AzureDate.parse(raw.trimmingCharacters(in: .whitespaces)) { return date }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        for format in ["yyyy-MM-dd HH:mm", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: raw.trimmingCharacters(in: .whitespaces)) {
                return format == "yyyy-MM-dd" ? day(date) : date
            }
        }
        return nil
    }
}

// MARK: - The app's History window

/// The period the History window shows.
public enum HistoryPeriod: String, CaseIterable, Sendable {
    case day, week, month, quarter, year, all
    /// From and to dates picked by hand.
    case custom

    public var title: String {
        switch self {
        case .day: "Last 24 Hours"
        case .week: "Last 7 Days"
        case .month: "Last 30 Days"
        case .quarter: "Last 90 Days"
        case .year: "Last Year"
        case .all: "All Time"
        case .custom: "Custom Range…"
        }
    }

    /// The start of the period; nil for all time and the custom range.
    public func since(now: Date) -> Date? {
        let days: Double? = switch self {
        case .day: 1
        case .week: 7
        case .month: 30
        case .quarter: 90
        case .year: 365
        case .all, .custom: nil
        }
        return days.map { now.addingTimeInterval(-$0 * 86400) }
    }

    /// A custom range covers whole days: from the start of `from` to the end of `to`.
    public static func customRange(from: Date, to: Date, calendar: Calendar = .current) -> (Date, Date) {
        let start = calendar.startOfDay(for: min(from, to))
        let lastDay = calendar.startOfDay(for: max(from, to))
        let end = calendar.date(byAdding: .day, value: 1, to: lastDay)?.addingTimeInterval(-0.001) ?? max(from, to)
        return (start, end)
    }
}

/// "Activate Again" on a history row: which eligible row to check, if any.
public enum HistoryReplay {
    public enum Verdict: Equatable, Sendable {
        /// Check this row; justification, ticket and duration come from the record.
        case ready(EligibleRole)
        case alreadyActive(EligibleRole)
        /// Not among your eligible roles (any more).
        case notEligible
        /// Recorded in another tenant (its id).
        case otherTenant(String)
        /// Not an activation (cancel, approve, …).
        case notAnActivation
    }

    public static func verdict(for record: HistoryRecord, roles: [EligibleRole], tenantId: String?) -> Verdict {
        guard record.action.isActivation, let key = record.policyKey else { return .notAnActivation }
        if let recorded = record.tenantId, let tenantId, recorded.caseInsensitiveCompare(tenantId) != .orderedSame {
            return .otherTenant(recorded)
        }
        let rows = roles.filter { $0.policyKey == key }
        guard !rows.isEmpty else { return .notEligible }
        if let active = rows.first(where: \.isActive) { return .alreadyActive(active) }
        // Prefer the direct eligibility when it is held directly and through a group.
        return .ready(rows.first { $0.membership == .direct } ?? rows[0])
    }

    /// The duration to ask for again: as asked then (`max` included).
    public static func duration(of record: HistoryRecord) -> RequestedDuration? {
        record.requestedDuration.flatMap(RequestedDuration.init(stringValue:))
            ?? record.durationMinutes.flatMap { $0 > 0 && $0 % 60 == 0 ? RequestedDuration(argument: String($0 / 60)) : nil }
    }
}
