import Foundation

// The demo's synthetic directory: Microsoft's fictitious companies (Contoso,
// Fabrikam, Northwind Traders, Adventure Works) on `.example` domains, the
// standard demo people (Alex Wilber, Megan Bowen, …) and Azure's built-in
// role definitions. Every ID is derived from a fixed name, so they are the
// same on every run (and in screenshots).

/// Stable GUIDs from names.
public enum DemoID {
    /// A version-4-shaped GUID derived from `name` (lower case).
    public static func uuid(_ name: String) -> String {
        var bytes = Array(SHA256.hash(Array("pimento-demo:\(name)".utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x40
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        let hex = bytes.map { String(format: "%02x", $0) }.joined()
        let p = Array(hex)
        return [String(p[0..<8]), String(p[8..<12]), String(p[12..<16]), String(p[16..<20]), String(p[20..<32])].joined(separator: "-")
    }
}

public struct DemoTenant: Hashable, Sendable {
    public let id: String
    public let displayName: String?
    public let defaultDomain: String?
    /// `Home` for the user's own tenant, `ProjectedBy` for guest tenants.
    public let category: String

    public var info: TenantInfo { TenantInfo(id: id, displayName: displayName, defaultDomain: defaultDomain, category: category) }
}

/// A user or a group.
public struct DemoPrincipal: Hashable, Sendable {
    public let id: String
    public let displayName: String
    /// Users only.
    public let email: String?
    /// `User` or `Group`.
    public let type: String

    static func user(_ key: String, _ name: String, _ email: String) -> DemoPrincipal {
        DemoPrincipal(id: DemoID.uuid("user-\(key)"), displayName: name, email: email, type: "User")
    }

    static func group(_ name: String) -> DemoPrincipal {
        DemoPrincipal(id: DemoID.uuid("group-\(name)"), displayName: name, email: nil, type: "Group")
    }
}

public struct DemoScope: Hashable, Sendable {
    public let path: String
    public let displayName: String
    /// `managementgroup`, `subscription`, `resourcegroup` or `resource`.
    public let type: String

    /// The subscription part of the path (`/subscriptions/<id>`), "" above it.
    var subscriptionPrefix: String {
        let parts = path.split(separator: "/")
        guard parts.count >= 2, parts[0].lowercased() == "subscriptions" else { return "" }
        return "/subscriptions/\(parts[1])"
    }

    static func subscription(_ key: String, _ name: String) -> DemoScope {
        DemoScope(path: "/subscriptions/\(DemoID.uuid("sub-\(key)"))", displayName: name, type: "subscription")
    }

    func resourceGroup(_ name: String) -> DemoScope {
        DemoScope(path: "\(path)/resourceGroups/\(name)", displayName: name, type: "resourcegroup")
    }

    func resource(_ provider: String, _ name: String) -> DemoScope {
        DemoScope(path: "\(path)/providers/\(provider)/\(name)", displayName: name, type: "resource")
    }
}

/// An Azure built-in role (the real, public role definition GUIDs).
public struct DemoRole: Hashable, Sendable {
    public let guid: String
    public let name: String

    public static let owner = DemoRole(guid: "8e3af657-a8ff-443c-a75c-2fe8c4bcb635", name: "Owner")
    public static let contributor = DemoRole(guid: "b24988ac-6180-42a0-ab88-20f7382dd24c", name: "Contributor")
    public static let reader = DemoRole(guid: "acdd72a7-3385-48ef-bd42-f606fba81ae7", name: "Reader")
    public static let userAccessAdministrator = DemoRole(guid: "18d7d88d-d35e-4fb5-a5c3-7773c20a72d9", name: "User Access Administrator")
    public static let keyVaultSecretsUser = DemoRole(guid: "4633458b-17de-408a-b874-0445c86b69e6", name: "Key Vault Secrets User")
    public static let storageBlobDataReader = DemoRole(guid: "2a2b9908-6ea1-4ae2-8e65-a410df84e7d1", name: "Storage Blob Data Reader")
    public static let websiteContributor = DemoRole(guid: "de139f84-1756-47ae-9be6-808fbbe84772", name: "Website Contributor")

    /// The role definition id as ARM writes it at `scope`.
    func definitionId(at scope: DemoScope) -> String {
        "\(scope.subscriptionPrefix)/providers/Microsoft.Authorization/roleDefinitions/\(guid)"
    }
}

/// What a role's PIM policy asks when you activate it yourself.
public struct DemoPolicy: Hashable, Sendable {
    public var maxMinutes: Int
    public var justification = true
    public var ticket = false
    public var mfa = false
    public var approval = false

    public init(hours: Int, ticket: Bool = false, mfa: Bool = false, approval: Bool = false) {
        maxMinutes = hours * 60
        self.ticket = ticket
        self.mfa = mfa
        self.approval = approval
    }
}

/// One eligibility of the demo user, directly or through a group.
struct DemoEligibility: Hashable, Sendable {
    let tenantId: String
    let key: String
    let scope: DemoScope
    let role: DemoRole
    /// nil: direct.
    let group: DemoPrincipal?
    let condition: String?
    let policy: DemoPolicy

    var instanceId: String {
        "\(scope.path)/providers/Microsoft.Authorization/roleEligibilityScheduleInstances/\(DemoID.uuid("eli-inst-\(key)"))"
    }

    var scheduleId: String {
        "\(scope.path)/providers/Microsoft.Authorization/roleEligibilitySchedules/\(DemoID.uuid("eli-\(key)"))"
    }

    var policyKey: RoleMatcher.Key { RoleMatcher.key(scope: scope.path, roleDefinitionId: role.guid) }
}

/// A role assignment of the demo user: a PIM activation, or one an
/// administrator assigned for a while.
struct DemoAssignment: Hashable, Sendable {
    enum Kind: String, Sendable { case activated = "Activated", assigned = "Assigned" }

    let tenantId: String
    /// The request (= schedule) name behind it.
    let name: String
    let scope: DemoScope
    let role: DemoRole
    let kind: Kind
    var start: Date
    var end: Date?
    let linkedEligibilityScheduleId: String?
    let condition: String?

    var scheduleId: String { "\(scope.path)/providers/Microsoft.Authorization/roleAssignmentSchedules/\(name)" }
    var instanceId: String { "\(scope.path)/providers/Microsoft.Authorization/roleAssignmentScheduleInstances/\(DemoID.uuid("inst-\(name)"))" }
    var policyKey: RoleMatcher.Key { RoleMatcher.key(scope: scope.path, roleDefinitionId: role.guid) }
}

/// A `roleAssignmentScheduleRequests` entry: the demo user's own, or one of
/// a colleague that waits for the demo user's approval.
struct DemoRequest: Hashable, Sendable {
    enum Decision: String, Sendable { case approve = "Approve", deny = "Deny" }

    let tenantId: String
    let name: String
    let scope: DemoScope
    let role: DemoRole
    let principal: DemoPrincipal
    let requestType: String
    var status: String
    var start: Date
    /// `AfterDuration` requests.
    var minutes: Int?
    /// `AfterDateTime` requests (extensions).
    var end: Date?
    let justification: String?
    let ticket: TicketInfo?
    let createdOn: Date
    let linkedEligibilityScheduleId: String?
    var approvalId: String?
    let targetScheduleId: String?
    let condition: String?
    /// When the simulated approver decides (the demo user's requests that need approval).
    var decideAt: Date?
    var decision: Decision?

    var id: String { "\(scope.path)/providers/Microsoft.Authorization/roleAssignmentScheduleRequests/\(name)" }
    var policyKey: RoleMatcher.Key { RoleMatcher.key(scope: scope.path, roleDefinitionId: role.guid) }
    var endDate: Date? { end ?? minutes.map { start.addingTimeInterval(TimeInterval($0) * 60) } }
}

/// The one stage of an approval.
struct DemoApproval: Hashable, Sendable {
    let tenantId: String
    let id: String
    let requestName: String
    /// Who may decide it.
    let approvers: [DemoPrincipal]
    var stageId: String { DemoID.uuid("stage-\(id)") }
    var status = "InProgress"
    var reviewResult = "NotReviewed"
    var justification: String?
    var reviewedBy: DemoPrincipal?
    var reviewedAt: Date?

    var isOpen: Bool { status == "InProgress" }
}

/// Everything the simulator knows; changed by requests and by time.
struct DemoState: Sendable {
    var tenants: [DemoTenant]
    let user: DemoPrincipal
    let groups: [DemoPrincipal]
    var eligibilities: [DemoEligibility]
    var assignments: [DemoAssignment]
    var requests: [DemoRequest]
    var approvals: [DemoApproval]
    /// Requests of colleagues that arrive later (approval arrivals), by time.
    var arrivals: [(at: Date, request: DemoRequest, approval: DemoApproval)]
    /// Ended activations PIM still holds on to for a moment (a new
    /// activation is refused with `RoleAssignmentExists` until then).
    var lingering: [RoleMatcher.Key: Date] = [:]
    /// Device codes handed out, and how many polls each has had.
    var deviceCodes: [String: Int] = [:]
}

/// The demo directory and its starting state.
public enum DemoDirectory {
    public static let user = DemoPrincipal.user("alex", "Alex Wilber", "alex.wilber@contoso.example")
    static let megan = DemoPrincipal.user("megan", "Megan Bowen", "megan.bowen@contoso.example")
    static let diego = DemoPrincipal.user("diego", "Diego Siciliani", "diego.siciliani@contoso.example")
    static let isaiah = DemoPrincipal.user("isaiah", "Isaiah Langer", "isaiah.langer@contoso.example")
    static let lynne = DemoPrincipal.user("lynne", "Lynne Robbins", "lynne.robbins@contoso.example")
    static let oncall = DemoPrincipal.group("sg-platform-oncall")
    static let analysts = DemoPrincipal.group("sg-data-analysts")

    public static let contoso = DemoTenant(id: DemoID.uuid("tenant-contoso"), displayName: "Contoso", defaultDomain: "contoso.example", category: "Home")
    public static let fabrikam = DemoTenant(id: DemoID.uuid("tenant-fabrikam"), displayName: "Fabrikam", defaultDomain: "fabrikam.example", category: "ProjectedBy")
    public static let northwind = DemoTenant(id: DemoID.uuid("tenant-northwind"), displayName: "Northwind Traders",
                                             defaultDomain: "northwindtraders.example", category: "ProjectedBy")
    public static let adventureWorks = DemoTenant(id: DemoID.uuid("tenant-adventureworks"), displayName: "Adventure Works",
                                                  defaultDomain: "adventure-works.example", category: "ProjectedBy")
    /// A tenant whose name the account cannot read.
    public static let unnamed = DemoTenant(id: DemoID.uuid("tenant-unnamed"), displayName: nil, defaultDomain: nil, category: "ProjectedBy")
    public static let tenants = [contoso, fabrikam, northwind, adventureWorks, unnamed]

    /// The app registration the demo sign-in pretends to use.
    public static let clientId = DemoID.uuid("client-pimento-demo")
    /// What the demo token store holds instead of a refresh token.
    public static let refreshToken = "demo-refresh-token"

    // Scopes
    static let contosoRoot = DemoScope(path: "/providers/Microsoft.Management/managementGroups/contoso-root",
                                       displayName: "Contoso Root", type: "managementgroup")
    static let production = DemoScope.subscription("contoso-production", "Contoso Production")
    static let staging = DemoScope.subscription("contoso-staging", "Contoso Staging")
    static let development = DemoScope.subscription("contoso-development", "Contoso Development")
    static let webProd = production.resourceGroup("rg-contoso-web-prod")
    static let dataProd = production.resourceGroup("rg-contoso-data-prod")
    static let keyVault = production.resourceGroup("rg-contoso-shared").resource("Microsoft.KeyVault/vaults", "kv-contoso-prod")
    static let storage = dataProd.resource("Microsoft.Storage/storageAccounts", "stcontosodata")
    static let fabrikamAnalytics = DemoScope.subscription("fabrikam-analytics", "Fabrikam Analytics")
    static let fabrikamLake = fabrikamAnalytics.resourceGroup("rg-fabrikam-lakehouse")
    static let northwindProd = DemoScope.subscription("northwind-production", "Northwind Production")
    static let northwindERP = northwindProd.resourceGroup("rg-northwind-erp")
    static let adventureRetail = DemoScope.subscription("adventureworks-retail", "Adventure Works Retail")

    static let blobCondition = "((!(ActionMatches{'Microsoft.Storage/storageAccounts/blobServices/containers/blobs/read'}))"
        + " OR (@Resource[Microsoft.Storage/storageAccounts/blobServices/containers:name] StringEquals 'invoices'))"
    static let lakeCondition = "((!(ActionMatches{'Microsoft.Storage/storageAccounts/blobServices/containers/blobs/read'}))"
        + " OR (@Resource[Microsoft.Storage/storageAccounts/blobServices/containers/blobs:path] StringStartsWith 'curated/'))"
    static let delegationCondition = "((!(ActionMatches{'Microsoft.Authorization/roleAssignments/write'}))"
        + " OR (@Request[Microsoft.Authorization/roleAssignments:RoleDefinitionId] ForAnyOfAnyValues:GuidEquals"
        + " {acdd72a7-3385-48ef-bd42-f606fba81ae7, b24988ac-6180-42a0-ab88-20f7382dd24c}))"

    static func eligibility(_ tenant: DemoTenant, _ key: String, _ scope: DemoScope, _ role: DemoRole, via group: DemoPrincipal? = nil,
                            condition: String? = nil, _ policy: DemoPolicy) -> DemoEligibility {
        DemoEligibility(tenantId: tenant.id, key: key, scope: scope, role: role, group: group, condition: condition, policy: policy)
    }

    /// The demo user's eligibilities: 16 in Contoso, a few in the guest tenants.
    static let eligibilities: [DemoEligibility] = [
        eligibility(contoso, "prod-owner", production, .owner, DemoPolicy(hours: 1, mfa: true, approval: true)),
        eligibility(contoso, "prod-contributor", production, .contributor, via: oncall, DemoPolicy(hours: 4, ticket: true)),
        eligibility(contoso, "prod-reader", production, .reader, DemoPolicy(hours: 8)),
        eligibility(contoso, "prod-uaa", production, .userAccessAdministrator, DemoPolicy(hours: 1, ticket: true, mfa: true)),
        eligibility(contoso, "stg-owner", staging, .owner, DemoPolicy(hours: 4)),
        eligibility(contoso, "stg-contributor", staging, .contributor, via: oncall, DemoPolicy(hours: 8)),
        eligibility(contoso, "stg-uaa", staging, .userAccessAdministrator, via: oncall, condition: delegationCondition, DemoPolicy(hours: 4)),
        eligibility(contoso, "dev-contributor", development, .contributor, DemoPolicy(hours: 8)),
        eligibility(contoso, "root-reader", contosoRoot, .reader, DemoPolicy(hours: 8)),
        eligibility(contoso, "web-contributor", webProd, .contributor, DemoPolicy(hours: 4)),
        eligibility(contoso, "web-contributor-oncall", webProd, .contributor, via: oncall, DemoPolicy(hours: 4)),
        eligibility(contoso, "web-website", webProd, .websiteContributor, via: oncall, DemoPolicy(hours: 8)),
        eligibility(contoso, "kv-secrets", keyVault, .keyVaultSecretsUser, DemoPolicy(hours: 1, ticket: true)),
        eligibility(contoso, "st-blob", storage, .storageBlobDataReader, condition: blobCondition, DemoPolicy(hours: 8)),
        eligibility(contoso, "data-blob", dataProd, .storageBlobDataReader, via: analysts, condition: lakeCondition, DemoPolicy(hours: 4)),
        eligibility(contoso, "data-contributor", dataProd, .contributor, via: analysts, DemoPolicy(hours: 4, ticket: true)),
        eligibility(fabrikam, "fab-reader", fabrikamAnalytics, .reader, DemoPolicy(hours: 8)),
        eligibility(fabrikam, "fab-contributor", fabrikamAnalytics, .contributor, DemoPolicy(hours: 4, ticket: true)),
        eligibility(fabrikam, "fab-blob", fabrikamLake, .storageBlobDataReader, condition: lakeCondition, DemoPolicy(hours: 8)),
        eligibility(northwind, "nw-contributor", northwindProd, .contributor, DemoPolicy(hours: 8)),
        eligibility(northwind, "nw-owner", northwindERP, .owner, DemoPolicy(hours: 1, approval: true)),
        eligibility(adventureWorks, "aw-reader", adventureRetail, .reader, DemoPolicy(hours: 8)),
    ]

    static func find(_ key: String) -> DemoEligibility { eligibilities.first { $0.key == key }! }

    /// The state the simulator starts in, relative to `now`.
    static func initialState(now: Date, timeZone: TimeZone = .current) -> DemoState {
        let minute: TimeInterval = 60, hour: TimeInterval = 3600, day: TimeInterval = 86400
        var requests: [DemoRequest] = []
        var assignments: [DemoAssignment] = []
        var approvals: [DemoApproval] = []

        func own(_ key: String, _ name: String, status: String, start: Date, minutes: Int, created: Date? = nil,
                 _ justification: String, ticket: TicketInfo? = nil, type: String = RequestAction.activate.requestType) -> DemoRequest {
            let e = find(key)
            return DemoRequest(
                tenantId: e.tenantId, name: DemoID.uuid("req-\(name)"), scope: e.scope, role: e.role, principal: user,
                requestType: type, status: status, start: start, minutes: type == RequestAction.deactivate.requestType ? nil : minutes,
                end: nil, justification: justification, ticket: ticket, createdOn: created ?? start,
                linkedEligibilityScheduleId: e.scheduleId, approvalId: nil, targetScheduleId: nil, condition: e.condition)
        }
        func activate(_ r: DemoRequest) {
            requests.append(r)
            assignments.append(DemoAssignment(
                tenantId: r.tenantId, name: r.name, scope: r.scope, role: r.role, kind: .activated, start: r.start, end: r.endDate,
                linkedEligibilityScheduleId: r.linkedEligibilityScheduleId, condition: r.condition))
        }

        // Active now, with different times left (Key Vault Secrets User ends
        // within the default 10-minute reminder lead).
        activate(own("prod-contributor", "active-prod-contributor", status: "Provisioned", start: now - 80 * minute, minutes: 240,
                     "Investigate checkout latency spike", ticket: TicketInfo(number: "INC-4821", system: "ServiceNow")))
        activate(own("kv-secrets", "active-kv-secrets", status: "Provisioned", start: now - 52 * minute, minutes: 60,
                     "Rotate the storage account keys", ticket: TicketInfo(number: "CHG-2290", system: "ServiceNow")))
        activate(own("dev-contributor", "active-dev-contributor", status: "Provisioned", start: now - 170 * minute, minutes: 480,
                     "Load-test the new pricing service"))
        // Scheduled for tomorrow 08:00.
        let tomorrow = ScheduleTime.Preset.tomorrowMorning.date(now: now, timeZone: timeZone)
        requests.append(own("stg-contributor", "scheduled-stg-contributor", status: "Granted", start: tomorrow, minutes: 480,
                            created: now - 40 * minute, "Staging cut-over for release 2026.11"))

        // An administrator's time-bound assignment (what `pimento extend` is for).
        assignments.append(DemoAssignment(
            tenantId: contoso.id, name: DemoID.uuid("assigned-stg-reader"), scope: staging, role: .reader, kind: .assigned,
            start: now - 24 * day, end: now + 6 * day, linkedEligibilityScheduleId: nil, condition: nil))

        // Past requests (what "Import from Azure" reads).
        requests.append(own("stg-owner", "past-stg-owner", status: "Provisioned", start: now - 2 * day - 3 * hour, minutes: 240,
                            "Rebuild the staging AKS node pool"))
        requests.append(own("stg-owner", "past-stg-owner-end", status: "Revoked", start: now - 2 * day - hour, minutes: 0,
                            "Done early", type: RequestAction.deactivate.requestType))
        requests.append(own("kv-secrets", "past-kv", status: "Provisioned", start: now - 3 * day - 5 * hour, minutes: 60,
                            "Rotate the payment gateway secret", ticket: TicketInfo(number: "CHG-2268", system: "ServiceNow")))
        requests.append(own("prod-uaa", "past-uaa", status: "Canceled", start: now - 4 * day - 2 * hour, minutes: 60,
                            "Grant the backup vault access", ticket: TicketInfo(number: "CHG-2251", system: "ServiceNow")))
        requests.append(own("web-contributor", "past-web", status: "Provisioned", start: now - 6 * day - 4 * hour, minutes: 240,
                            "Deploy the storefront hotfix"))
        requests.append(own("data-contributor", "past-data", status: "Provisioned", start: now - 12 * day - 6 * hour, minutes: 240,
                            "Backfill the October sales partitions", ticket: TicketInfo(number: "DATA-512", system: "Jira")))
        var denied = own("prod-owner", "past-prod-owner", status: "Denied", start: now - 5 * day - 7 * hour, minutes: 60,
                         "Change the production firewall rules")
        let deniedApproval = DemoApproval(
            tenantId: contoso.id, id: DemoID.uuid("approval-past-prod-owner"), requestName: denied.name, approvers: [megan],
            status: "Completed", reviewResult: "Deny", justification: "Use the break-glass process for firewall changes",
            reviewedBy: megan, reviewedAt: now - 5 * day - 6 * hour)
        denied.approvalId = deniedApproval.id
        requests.append(denied)
        approvals.append(deniedApproval)
        var timedOut = own("prod-owner", "past-prod-owner-timeout", status: "TimedOut", start: now - 9 * day - 3 * hour, minutes: 60,
                           "Weekend maintenance window")
        let timedOutApproval = DemoApproval(tenantId: contoso.id, id: DemoID.uuid("approval-past-timeout"), requestName: timedOut.name,
                                            approvers: [megan], status: "Expired")
        timedOut.approvalId = timedOutApproval.id
        requests.append(timedOut)
        approvals.append(timedOutApproval)

        // Two colleagues wait for the demo user's approval.
        func colleague(_ who: DemoPrincipal, _ key: String, scope: DemoScope, role: DemoRole, created: Date, minutes: Int,
                       _ justification: String, ticket: TicketInfo? = nil) -> (DemoRequest, DemoApproval) {
            let name = DemoID.uuid("req-inbox-\(key)")
            let approval = DemoApproval(tenantId: contoso.id, id: DemoID.uuid("approval-inbox-\(key)"), requestName: name, approvers: [user, lynne])
            let request = DemoRequest(
                tenantId: contoso.id, name: name, scope: scope, role: role, principal: who, requestType: RequestAction.activate.requestType,
                status: "PendingApproval", start: created, minutes: minutes, end: nil, justification: justification, ticket: ticket,
                createdOn: created, linkedEligibilityScheduleId: nil, approvalId: approval.id, targetScheduleId: nil, condition: nil)
            return (request, approval)
        }
        for (r, a) in [
            colleague(megan, "megan-owner", scope: production, role: .owner, created: now - 25 * minute, minutes: 60,
                      "Rotate the production TLS certificate before it expires", ticket: TicketInfo(number: "CHG-2291", system: "ServiceNow")),
            colleague(diego, "diego-uaa", scope: staging, role: .userAccessAdministrator, created: now - 130 * minute, minutes: 240,
                      "Grant the new QA pipeline identity access to staging"),
        ] {
            requests.append(r)
            approvals.append(a)
        }
        // A third one arrives while the demo runs (the "approval requested" notification).
        let arrival = colleague(isaiah, "isaiah-web", scope: webProd, role: .contributor, created: now + 150, minutes: 120,
                                "Hotfix for the checkout API", ticket: TicketInfo(number: "INC-4877", system: "ServiceNow"))

        return DemoState(
            tenants: tenants, user: user, groups: [oncall, analysts], eligibilities: eligibilities,
            assignments: assignments, requests: requests, approvals: approvals,
            arrivals: [(at: now + 150, request: arrival.0, approval: arrival.1)])
    }
}
