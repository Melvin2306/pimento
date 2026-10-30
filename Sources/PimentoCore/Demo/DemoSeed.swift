import Foundation

/// The demo's local files at the start: presets, about 40 history records
/// over the past three weeks, and the sign-in settings. All synthetic.
public enum DemoSeed {
    public static let recentJustifications = [
        "Investigate checkout latency spike",
        "Staging cut-over for release 2026.11",
        "Load-test the new pricing service",
        "Rotate the storage account keys",
        "Daily cost and health review",
    ]

    public static let recentTickets = [
        TicketInfo(number: "CHG-2290", system: "ServiceNow"),
        TicketInfo(number: "INC-4821", system: "ServiceNow"),
        TicketInfo(number: "CHG-2268", system: "ServiceNow"),
        TicketInfo(number: "DATA-512", system: "Jira"),
    ]

    /// "On-call", "Release day" and "Data team".
    public static func presets(now: Date) -> PresetLibrary {
        func role(_ key: String) -> PresetRole {
            let e = DemoDirectory.find(key)
            return PresetRole(scope: e.scope.path, roleDefinitionId: e.role.definitionId(at: e.scope), roleName: e.role.name,
                              scopeName: e.scope.displayName)
        }
        let contoso = DemoDirectory.contoso.id
        var library = PresetLibrary()
        let presets = [
            Preset(id: UUID(uuidString: DemoID.uuid("preset-oncall"))!, name: "On-call", tenantId: contoso,
                   roles: [role("prod-contributor"), role("prod-reader"), role("web-website")],
                   justification: "On-call shift: production support", duration: .hours(4), ticketSystem: "ServiceNow",
                   createdAt: now.addingTimeInterval(-30 * 86400), updatedAt: now.addingTimeInterval(-9 * 86400)),
            Preset(id: UUID(uuidString: DemoID.uuid("preset-release"))!, name: "Release day", tenantId: contoso,
                   roles: [role("stg-contributor")],
                   match: [PresetRule(filters: ["rg-contoso-web-prod"], roles: ["Contributor", "Website Contributor"])],
                   justification: "Release 2026.11 rollout", duration: .maximum,
                   createdAt: now.addingTimeInterval(-21 * 86400), updatedAt: now.addingTimeInterval(-6 * 86400)),
            Preset(id: UUID(uuidString: DemoID.uuid("preset-data"))!, name: "Data team", tenantId: contoso,
                   roles: [role("st-blob"), role("data-blob"), role("root-reader")],
                   justification: "Monthly data quality checks", duration: .hours(8), ticketSystem: "Jira",
                   createdAt: now.addingTimeInterval(-18 * 86400), updatedAt: now.addingTimeInterval(-12 * 86400)),
        ]
        for p in presets { _ = try? library.save(p, now: p.updatedAt ?? now) }
        return library
    }

    private struct Entry {
        enum When { case ago(TimeInterval), day(Int, Int, Int) }
        var when: When
        var action: HistoryAction
        var result: HistoryResult
        var status: String?
        var key: String
        var minutes: Int? = nil
        var requested: String? = nil
        var justification: String? = nil
        var ticket: TicketInfo? = nil
        var message: String? = nil
        var requester: String? = nil
        var source: HistorySource = .app
        var startDay: (Int, Int, Int)? = nil
    }

    /// About 40 records of the past three weeks, newest first.
    public static func history(now: Date, timeZone: TimeZone = .current) -> [HistoryRecord] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let today = calendar.startOfDay(for: now)
        func day(_ d: Int, _ h: Int, _ m: Int) -> Date {
            calendar.date(byAdding: DateComponents(day: -d, hour: h, minute: m), to: today) ?? now
        }
        let minute: TimeInterval = 60
        let inc4821 = TicketInfo(number: "INC-4821", system: "ServiceNow")
        let policyTicket = "a ticket is required: give a ticket number and ticket system"
        let policyLength = "duration exceeds the role's maximum activation time"
        let entries: [Entry] = [
            Entry(when: .ago(40 * minute), action: .schedule, result: .succeeded, status: "Granted", key: "stg-contributor", minutes: 480,
                  requested: "PT8H", justification: "Staging cut-over for release 2026.11", startDay: (-1, 8, 0)),
            Entry(when: .ago(80 * minute), action: .activate, result: .succeeded, status: "Provisioned", key: "prod-contributor", minutes: 240,
                  requested: "PT4H", justification: "Investigate checkout latency spike", ticket: inc4821),
            Entry(when: .ago(81 * minute), action: .activate, result: .failed, status: "RoleAssignmentRequestPolicyValidationFailed",
                  key: "prod-contributor", minutes: 240, requested: "PT4H", justification: "Investigate checkout latency spike",
                  message: policyTicket),
            Entry(when: .ago(170 * minute), action: .activate, result: .succeeded, status: "Provisioned", key: "dev-contributor", minutes: 480,
                  requested: "PT8H", justification: "Load-test the new pricing service", source: .cli),
            Entry(when: .ago(52 * minute), action: .activate, result: .succeeded, status: "Provisioned", key: "kv-secrets", minutes: 60,
                  requested: "PT1H", justification: "Rotate the storage account keys", ticket: TicketInfo(number: "CHG-2290", system: "ServiceNow")),
            Entry(when: .day(1, 17, 5), action: .deactivate, result: .succeeded, status: "Revoked", key: "web-contributor",
                  justification: "Ended early with Pimento"),
            Entry(when: .day(1, 14, 20), action: .activate, result: .succeeded, status: "Provisioned", key: "web-contributor", minutes: 240,
                  requested: "PT4H", justification: "Roll back the storefront CDN rules"),
            Entry(when: .day(1, 11, 42), action: .approve, result: .succeeded, status: "Approve", key: "data-contributor",
                  justification: "Matches change CHG-2280", requester: "Adele Vance <adele.vance@contoso.example>"),
            Entry(when: .day(1, 9, 15), action: .renew, result: .succeeded, status: "Provisioned", key: "prod-reader", minutes: 480,
                  requested: "PT8H", justification: "Daily cost and health review"),
            Entry(when: .day(1, 9, 2), action: .extend, result: .pending, status: "PendingAdminDecision", key: "assigned-stg-reader",
                  minutes: 30 * 1440, requested: "P30D", justification: "Quarterly audit support", message: "waiting for an administrator",
                  source: .cli),
            Entry(when: .day(2, 16, 48), action: .deactivate, result: .succeeded, status: "Revoked", key: "stg-owner",
                  justification: "Done early"),
            Entry(when: .day(2, 13, 10), action: .activate, result: .succeeded, status: "Provisioned", key: "stg-owner", minutes: 240,
                  requested: "PT4H", justification: "Rebuild the staging AKS node pool"),
            Entry(when: .day(2, 13, 9), action: .activate, result: .failed, status: "RoleAssignmentRequestPolicyValidationFailed",
                  key: "stg-owner", minutes: 480, requested: "PT8H", justification: "Rebuild the staging AKS node pool", message: policyLength),
            Entry(when: .day(2, 8, 55), action: .activate, result: .succeeded, status: "Provisioned", key: "root-reader", minutes: 480,
                  requested: "PT8H", justification: "Monthly governance review"),
            Entry(when: .day(3, 15, 12), action: .deny, result: .succeeded, status: "Deny", key: "prod-owner",
                  justification: "Use the break-glass account for this", requester: "Diego Siciliani <diego.siciliani@contoso.example>"),
            Entry(when: .day(3, 10, 31), action: .activate, result: .succeeded, status: "Provisioned", key: "kv-secrets", minutes: 60,
                  requested: "PT1H", justification: "Rotate the payment gateway secret", ticket: TicketInfo(number: "CHG-2268", system: "ServiceNow")),
            Entry(when: .day(3, 10, 33), action: .deactivate, result: .failed, status: "ActiveDurationTooShort", key: "kv-secrets",
                  justification: "Ended early with Pimento", message: "PIM ends an activation only after 5 minutes"),
            Entry(when: .day(4, 11, 6), action: .cancel, result: .succeeded, status: "Canceled", key: "prod-uaa",
                  justification: "Grant the backup vault access", ticket: TicketInfo(number: "CHG-2251", system: "ServiceNow")),
            Entry(when: .day(4, 11, 2), action: .schedule, result: .succeeded, status: "Granted", key: "prod-uaa", minutes: 60, requested: "PT1H",
                  justification: "Grant the backup vault access", ticket: TicketInfo(number: "CHG-2251", system: "ServiceNow"), startDay: (4, 14, 0)),
            Entry(when: .day(4, 9, 30), action: .activate, result: .succeeded, status: "Provisioned", key: "fab-reader", minutes: 480,
                  requested: "PT8H", justification: "Support the Fabrikam quarterly close", source: .cli),
            Entry(when: .day(5, 8, 45), action: .activate, result: .skipped, status: "RoleAssignmentExists", key: "prod-contributor",
                  minutes: 240, requested: "PT4H", justification: "Change the production firewall rules", message: "already active"),
            Entry(when: .day(5, 8, 44), action: .activate, result: .pending, status: "PendingApproval", key: "prod-owner", minutes: 60,
                  requested: "PT1H", justification: "Change the production firewall rules", message: "awaiting approval"),
            Entry(when: .day(6, 18, 10), action: .deactivate, result: .succeeded, status: "Revoked", key: "web-website",
                  justification: "Ended early with Pimento"),
            Entry(when: .day(6, 14, 3), action: .activate, result: .succeeded, status: "Provisioned", key: "web-website", minutes: 480,
                  requested: "max", justification: "Deploy the storefront hotfix"),
            Entry(when: .day(6, 14, 3), action: .activate, result: .succeeded, status: "Provisioned", key: "web-contributor", minutes: 240,
                  requested: "max", justification: "Deploy the storefront hotfix"),
            Entry(when: .day(7, 16, 22), action: .approve, result: .succeeded, status: "Approve", key: "prod-owner",
                  justification: "Planned certificate rotation", requester: "Megan Bowen <megan.bowen@contoso.example>"),
            Entry(when: .day(7, 9, 0), action: .activate, result: .succeeded, status: "Provisioned", key: "nw-contributor", minutes: 480,
                  requested: "PT8H", justification: "ERP month-end support"),
            Entry(when: .day(8, 10, 15), action: .renew, result: .succeeded, status: "Provisioned", key: "dev-contributor", minutes: 480,
                  requested: "PT8H", justification: "Feature branch environment setup"),
            Entry(when: .day(8, 8, 30), action: .activate, result: .succeeded, status: "Provisioned", key: "dev-contributor", minutes: 480,
                  requested: "PT8H", justification: "Feature branch environment setup", source: .cli),
            Entry(when: .day(9, 12, 40), action: .activate, result: .succeeded, status: "Provisioned", key: "data-blob", minutes: 240,
                  requested: "PT4H", justification: "Quarterly churn analysis"),
            Entry(when: .day(9, 7, 58), action: .activate, result: .pending, status: "PendingApproval", key: "prod-owner", minutes: 60,
                  requested: "PT1H", justification: "Weekend maintenance window", message: "awaiting approval"),
            Entry(when: .day(10, 11, 13), action: .activate, result: .succeeded, status: "Provisioned", key: "data-contributor", minutes: 240,
                  requested: "PT4H", justification: "Fix the nightly ingestion job", ticket: TicketInfo(number: "DATA-498", system: "Jira")),
            Entry(when: .day(10, 11, 11), action: .activate, result: .failed, status: "RoleAssignmentRequestPolicyValidationFailed",
                  key: "data-contributor", minutes: 240, requested: "PT4H", justification: "Fix the nightly ingestion job", message: policyTicket),
            Entry(when: .day(12, 13, 45), action: .activate, result: .succeeded, status: "Provisioned", key: "st-blob", minutes: 480,
                  requested: "PT8H", justification: "Invoice reconciliation"),
            Entry(when: .day(12, 9, 20), action: .activate, result: .succeeded, status: "Provisioned", key: "data-contributor", minutes: 240,
                  requested: "PT4H", justification: "Backfill the October sales partitions", ticket: TicketInfo(number: "DATA-512", system: "Jira")),
            Entry(when: .day(13, 10, 5), action: .activate, result: .succeeded, status: "Provisioned", key: "aw-reader", minutes: 480,
                  requested: "PT8H", justification: "Retail dashboard review", source: .cli),
            Entry(when: .day(14, 15, 30), action: .approve, result: .succeeded, status: "Approve", key: "web-website",
                  justification: "On-call handover", requester: "Isaiah Langer <isaiah.langer@contoso.example>"),
            Entry(when: .day(14, 9, 10), action: .activate, result: .succeeded, status: "Provisioned", key: "prod-contributor", minutes: 240,
                  requested: "PT4H", justification: "Database failover drill", ticket: TicketInfo(number: "INC-4712", system: "ServiceNow")),
            Entry(when: .day(16, 8, 40), action: .schedule, result: .succeeded, status: "Granted", key: "stg-owner", minutes: 240,
                  requested: "PT4H", justification: "Load test window", startDay: (15, 8, 0)),
            Entry(when: .day(17, 14, 0), action: .deactivate, result: .skipped, status: "RoleAssignmentDoesNotExist", key: "prod-contributor",
                  justification: "Ended early with Pimento", message: "not active (already ended)"),
            Entry(when: .day(18, 9, 26), action: .activate, result: .succeeded, status: "Provisioned", key: "fab-contributor", minutes: 240,
                  requested: "PT4H", justification: "Fabrikam data migration", ticket: TicketInfo(number: "FAB-1182", system: "Jira")),
            Entry(when: .day(18, 9, 25), action: .activate, result: .failed, status: "RoleAssignmentRequestPolicyValidationFailed",
                  key: "fab-contributor", minutes: 480, requested: "PT8H", justification: "Fabrikam data migration", message: policyLength),
            Entry(when: .day(20, 11, 0), action: .activate, result: .succeeded, status: "Provisioned", key: "root-reader", minutes: 480,
                  requested: "PT8H", justification: "Policy compliance review"),
            Entry(when: .day(21, 10, 0), action: .activate, result: .succeeded, status: "Provisioned", key: "prod-reader", minutes: 480,
                  requested: "PT8H", justification: "Daily cost and health review"),
        ]
        let tenants = Dictionary(DemoDirectory.tenants.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return entries.enumerated().map { index, e in
            let at: Date = switch e.when {
            case .ago(let seconds): now.addingTimeInterval(-seconds)
            case .day(let d, let h, let m): day(d, h, m)
            }
            let scope: DemoScope, role: DemoRole, tenantId: String
            if e.key == "assigned-stg-reader" {
                (scope, role, tenantId) = (DemoDirectory.staging, .reader, DemoDirectory.contoso.id)
            } else {
                let el = DemoDirectory.find(e.key)
                (scope, role, tenantId) = (el.scope, el.role, el.tenantId)
            }
            let start: Date? = switch e.action {
            case .deactivate, .cancel, .approve, .deny: nil
            default: e.startDay.map { day($0.0, $0.1, $0.2) } ?? at
            }
            let end: Date? = switch e.action {
            case .deactivate: at
            case .extend: now.addingTimeInterval(36 * 86400)
            default: start.flatMap { s in e.minutes.map { s.addingTimeInterval(TimeInterval($0) * 60) } }
            }
            return HistoryRecord(
                id: DemoID.uuid("history-\(index)"), at: at, action: e.action, result: e.result, status: e.status, message: e.message,
                tenantId: tenantId, tenantLabel: tenants[tenantId]?.displayName, scope: scope.path, scopeName: scope.displayName,
                scopeType: scope.type, roleName: role.name, roleDefinitionId: role.definitionId(at: scope), requestedDuration: e.requested,
                durationMinutes: e.minutes, start: start, end: end, justification: e.justification,
                ticketNumber: e.ticket?.ticketNumber, ticketSystem: e.ticket?.ticketSystem,
                requestId: DemoID.uuid("history-request-\(index)"), requester: e.requester, source: e.source,
                version: e.source == .azure ? nil : AppInfo.version)
        }
    }

    /// Demo sign-in: Pimento's own sign-in, with Alex Wilber signed in.
    public static func authSettings() -> AuthSettings {
        AuthSettings(source: .pimento, clientId: DemoDirectory.clientId, accountId: account(signedInAt: Date()).id)
    }

    public static func account(signedInAt: Date) -> SignedInAccount {
        let user = DemoDirectory.user
        return SignedInAccount(objectId: user.id, homeTenantId: DemoDirectory.contoso.id, tenantId: DemoDirectory.contoso.id,
                               username: user.email, name: user.displayName, clientId: DemoDirectory.clientId, signedInAt: signedInAt)
    }
}
