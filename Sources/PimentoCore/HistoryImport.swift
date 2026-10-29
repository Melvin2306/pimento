import Foundation

/// Your past requests as Azure lists them (`roleAssignmentScheduleRequests`,
/// `$filter=asTarget()`, read-only), as history records: activity from the
/// portal, other tools, or before Pimento kept a history. Only your own
/// self-service requests are taken (`SelfActivate`, `SelfDeactivate`,
/// `SelfExtend`, `SelfRenew`); assignments an administrator made are not.
public enum HistoryImport {
    /// The action of a request type; nil for types that are not yours to make.
    /// A `SelfActivate` that starts more than a minute (`ScheduleTime.immediateSlack`) after it was made is
    /// a scheduled activation.
    public static func action(requestType: String?, start: Date?, createdOn: Date?) -> HistoryAction? {
        switch requestType?.lowercased() {
        case "selfactivate":
            if let start, let createdOn, start > createdOn.addingTimeInterval(ScheduleTime.immediateSlack) { return .schedule }
            return .activate
        case "selfdeactivate": return .deactivate
        case "selfextend": return .extend
        case "selfrenew": return .renew
        default: return nil
        }
    }

    /// The result of a request status.
    public static func result(status: String?) -> HistoryResult {
        switch status?.lowercased() ?? "" {
        case "provisioned", "granted", "accepted", "adminapproved", "schedulecreated", "pendingschedulecreation",
             "pendingprovisioning", "provisioningstarted", "pendingexternalprovisioning", "revoked":
            .succeeded
        case "pendingapproval", "pendingapprovalprovisioning", "pendingadmindecision", "pendingevaluation", "pendingrevocation":
            .pending
        case "denied", "admindenied": .denied
        case "canceled", "cancelled": .canceled
        case "timedout": .expired
        case "failed", "failedasresourceislocked", "invalid": .failed
        default: .unknown
        }
    }

    /// The records of `items` made at or after `since`, oldest first. Items
    /// without a name, scope or time are left out, and so are other people's.
    public static func records(
        from items: [AssignmentScheduleRequestItem], principalId: String?, tenantId: String?, tenantLabel: String? = nil,
        since: Date? = nil
    ) -> [HistoryRecord] {
        var seen = Set<String>()
        let records = items.compactMap { item -> HistoryRecord? in
            guard let p = item.properties, let scope = p.scope?.nonEmpty else { return nil }
            if let principalId, let mine = p.principalId, mine.caseInsensitiveCompare(principalId) != .orderedSame { return nil }
            let name = item.name ?? item.id.map(RoleMatcher.lastPathComponent) ?? ""
            guard !name.isEmpty, seen.insert(name.lowercased()).inserted else { return nil }
            let created = AzureDate.parse(p.createdOn)
            let start = AzureDate.parse(p.scheduleInfo?.startDateTime)
            guard let at = created ?? start else { return nil }
            if let since, at < since { return nil }
            guard let action = action(requestType: p.requestType, start: start, createdOn: created) else { return nil }
            let expiration = p.scheduleInfo?.expiration
            let end = AzureDate.parse(expiration?.endDateTime)
                ?? start.flatMap { s in ISODuration.parse(expiration?.duration).map { s.addingTimeInterval($0) } }
            let minutes: Int? = {
                if let start, let end, end > start { return Int(end.timeIntervalSince(start) / 60) }
                return nil
            }()
            let x = p.expandedProperties
            return HistoryRecord(
                id: "azure-" + name.lowercased(), at: at, action: action, result: result(status: p.status), status: p.status?.nonEmpty,
                tenantId: tenantId, tenantLabel: tenantLabel,
                scope: scope, scopeName: x?.scope?.displayName?.nonEmpty, scopeType: x?.scope?.type?.nonEmpty,
                roleName: x?.roleDefinition?.displayName?.nonEmpty, roleDefinitionId: p.roleDefinitionId?.nonEmpty,
                requestedDuration: expiration?.duration?.nonEmpty, durationMinutes: action == .deactivate ? nil : minutes,
                start: action == .deactivate ? nil : start, end: action == .deactivate ? (start ?? at) : end,
                justification: p.justification?.nonEmpty,
                ticketNumber: p.ticketInfo?.ticketNumber?.nonEmpty, ticketSystem: p.ticketInfo?.ticketSystem?.nonEmpty,
                requestId: name, source: .azure, version: nil)
        }
        return records.sorted { ($0.at, $0.id) < ($1.at, $1.id) }
    }
}

extension PIMService {
    /// Your past requests from Azure as history records (read-only).
    public func loadHistoryFromAzure(since: Date? = nil, tenantLabel: String? = nil, now: Date = Date()) async throws -> [HistoryRecord] {
        let history = try await loadRequestHistory(now: now)
        return HistoryImport.records(
            from: history.items, principalId: history.identity.objectId, tenantId: history.identity.tenantId,
            tenantLabel: tenantLabel, since: since)
    }
}
