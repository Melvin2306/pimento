import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// An in-memory Azure: answers every ARM and sign-in request Pimento sends
/// (role listings, policies, activation / deactivation / extension requests,
/// cancel, approvals and their stages, `/tenants`, the token and device-code
/// endpoints) from synthetic data, with PIM's statuses and error codes. It is
/// an `HTTPTransport`, so `PIMService`, `TenantDirectory` and `TokenBroker`
/// run unchanged on top of it. Nothing is sent anywhere.
///
/// State changes last as long as the object: activations become active and
/// expire on `clock`, scheduled activations start, a simulated approver
/// (Megan Bowen) decides the demo user's requests after `approvalDelay`, and
/// a colleague's request arrives in the approver inbox after a while.
public final class DemoAzure: HTTPTransport, @unchecked Sendable {
    public struct Behavior: Sendable {
        /// Items per page of a list (more are behind `nextLink`).
        public var pageSize = 10
        /// Demo seconds until the simulated approver decides a request of the demo user.
        public var approvalDelay: TimeInterval = 45
        /// Demo seconds PIM still refuses a new activation (`RoleAssignmentExists`)
        /// after one was ended: what Renew retries through.
        public var removalDelay: TimeInterval = 8
        /// What PIM answers a deactivation in an activation's first five
        /// minutes: `RoleAssignmentDoesNotExist` (what it really does) or `ActiveDurationTooShort`.
        public var tooSoonCode = "RoleAssignmentDoesNotExist"
        /// Device-code polls answered `authorization_pending` before the sign-in completes.
        public var deviceCodePolls = 1
        /// Real seconds each answer takes (0: at once).
        public var latency: ClosedRange<TimeInterval> = 0...0

        public init() {}
    }

    /// Thrown for a request to any host but ARM and the Microsoft identity platform.
    public struct UnknownHost: Error, LocalizedError, Equatable {
        public let url: String
        public var errorDescription: String? { "Demo mode: no simulated service at \(url)." }
    }

    public let clock: DemoClock
    private let lock = NSLock()
    private var storedBehavior: Behavior
    var state: DemoState
    private var log: [String] = []

    public init(clock: DemoClock = DemoClock(), behavior: Behavior = Behavior(), timeZone: TimeZone = .current) {
        self.clock = clock
        storedBehavior = behavior
        state = DemoDirectory.initialState(now: clock.now(), timeZone: timeZone)
    }

    public var behavior: Behavior {
        get { lock.withLock { storedBehavior } }
        set { lock.withLock { storedBehavior = newValue } }
    }

    /// `METHOD path` of every request so far (tests).
    public var requestLog: [String] { lock.withLock { log } }

    public var user: DemoPrincipal { DemoDirectory.user }
    public var homeTenant: DemoTenant { DemoDirectory.contoso }

    /// The tenants of the demo account, as the tenant picker lists them.
    public var tenants: [TenantInfo] { TenantDirectory.sorted(lock.withLock { state.tenants.map(\.info) }) }

    // MARK: Transport

    public func send(_ request: URLRequest) async throws -> (Data, Int) {
        let latency = behavior.latency
        if latency.upperBound > 0 {
            let seconds = Double.random(in: latency)
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        }
        return try handle(request)
    }

    /// Answers one request (synchronously; `send` adds the latency).
    public func handle(_ request: URLRequest) throws -> (Data, Int) {
        guard let url = request.url, url.scheme?.lowercased() == "https", url.port == nil || url.port == 443 else {
            throw UnknownHost(url: request.url?.absoluteString ?? "?")
        }
        let method = (request.httpMethod ?? "GET").uppercased()
        lock.lock()
        defer { lock.unlock() }
        log.append("\(method) \(url.path)")
        tick(clock.now())
        switch url.host?.lowercased() {
        case ARM.host: return arm(method: method, url: url, request: request)
        case MicrosoftIdentity.host: return identity(method: method, url: url, body: request.httpBody ?? Data())
        default: throw UnknownHost(url: url.absoluteString)
        }
    }

    // MARK: Tokens

    /// What `az account get-access-token --tenant` would print in the demo:
    /// an (unsigned) token for `tenantId` (nil: the home tenant). An unknown
    /// tenant fails like az does.
    public func cliAccessToken(tenantId: String?) throws -> String {
        lock.lock()
        defer { lock.unlock() }
        guard let tenant = resolveTenant(tenantId) else {
            throw AzureCLIError.failed("ERROR: AADSTS90002: Tenant '\(tenantId ?? "")' not found. (Pimento demo: the demo account knows "
                + state.tenants.compactMap(\.displayName).joined(separator: ", ") + ".)")
        }
        return accessToken(tenant: tenant)
    }

    /// A token provider standing in for the Azure CLI.
    public func cliTokens(tenantId: String?) -> TokenProvider { DemoCLITokenProvider(azure: self, tenantId: tenantId) }

    /// Claims every demo token carries; the simulator accepts no other token.
    static let demoClaim = "pimento_demo"

    func accessToken(tenant: DemoTenant) -> String {
        let now = clock.now().timeIntervalSince1970
        return DemoToken.make([
            "aud": ARM.resource, "iss": "https://sts.windows.net/\(tenant.id)/", "iat": Int(now), "nbf": Int(now), "exp": Int(now) + 3600,
            "oid": user.id, "tid": tenant.id, "name": user.displayName, "upn": user.email ?? "", "unique_name": user.email ?? "",
            "scp": "user_impersonation", Self.demoClaim: true,
        ])
    }

    /// A tenant by GUID or domain; nil, `organizations` and `common` mean the home tenant.
    func resolveTenant(_ idOrDomain: String?) -> DemoTenant? {
        guard let raw = idOrDomain?.trimmingCharacters(in: .whitespaces).lowercased(), !raw.isEmpty,
              raw != MicrosoftIdentity.organizations, raw != "common" else { return homeTenant }
        return state.tenants.first { $0.id == raw || $0.defaultDomain?.lowercased() == raw }
    }

    struct Caller {
        let tenant: DemoTenant
        let objectId: String
    }

    /// The tenant and user of a request's bearer token; nil for anything not minted here.
    func caller(_ request: URLRequest) -> Caller? {
        guard let header = request.value(forHTTPHeaderField: "Authorization"), header.hasPrefix("Bearer "),
              let claims = JWT.claims(String(header.dropFirst("Bearer ".count))), claims[Self.demoClaim] as? Bool == true,
              let tid = claims["tid"] as? String, let oid = claims["oid"] as? String,
              let tenant = state.tenants.first(where: { $0.id == tid.lowercased() }) else { return nil }
        return Caller(tenant: tenant, objectId: oid.lowercased())
    }

    // MARK: ARM

    private static let authorization = "/providers/microsoft.authorization/"

    func arm(method: String, url: URL, request: URLRequest) -> (Data, Int) {
        let query = Dictionary(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.map { ($0.name, $0.value ?? "") } ?? [],
                               uniquingKeysWith: { a, _ in a })
        let path = url.path
        if path.lowercased() == "/tenants" {
            guard method == "GET" else { return Self.error(405, "MethodNotAllowed", "The requested resource does not support http method '\(method)'.") }
            guard query["api-version"] == "2022-12-01" else { return Self.badApiVersion(query["api-version"]) }
            guard caller(request) != nil else { return Self.unauthenticated }
            return page(TenantDirectory.sorted(state.tenants.map(\.info)).map { t in state.tenants.first { $0.id == t.id }! }.map(Self.json(tenant:)),
                        url: url, query: query, pageSize: 3)
        }
        guard let caller = caller(request) else { return Self.unauthenticated }
        let lower = path.lowercased()
        guard lower.count == path.count, let split = lower.range(of: Self.authorization) else {
            return Self.error(404, "InvalidResourceType", "The resource type could not be found in the namespace 'Microsoft.Authorization'.")
        }
        let prefix = lower.distance(from: lower.startIndex, to: split.lowerBound)
        let scope = String(path.prefix(prefix))
        let rest = path.dropFirst(prefix + Self.authorization.count).split(separator: "/").map(String.init)
        guard let type = rest.first?.lowercased() else { return Self.error(404, "InvalidResourceType", "No resource type.") }
        let filter = query["$filter"] ?? ""
        let apiVersion = query["api-version"]

        switch (method, type, rest.count) {
        case ("GET", "roleeligibilityscheduleinstances", 1):
            guard apiVersion == ARM.apiVersion else { return Self.badApiVersion(apiVersion) }
            guard scope.isEmpty, filter == "asTarget()" else { return Self.unsupportedFilter(filter) }
            return page(eligibilities(of: caller).map { Self.json(eligibility: $0, user: user) }, url: url, query: query)
        case ("GET", "roleassignmentscheduleinstances", 1):
            guard apiVersion == ARM.apiVersion else { return Self.badApiVersion(apiVersion) }
            guard scope.isEmpty, filter == "asTarget()" else { return Self.unsupportedFilter(filter) }
            let mine = state.assignments.filter { $0.tenantId == caller.tenant.id && caller.objectId == user.id }
            return page(mine.map { Self.json(assignment: $0, user: user) }, url: url, query: query)
        case ("GET", "roleassignmentschedulerequests", 1):
            guard apiVersion == ARM.apiVersion else { return Self.badApiVersion(apiVersion) }
            guard scope.isEmpty else { return Self.unsupportedFilter(filter) }
            switch filter {
            case "asTarget()":
                let mine = state.requests.filter { $0.tenantId == caller.tenant.id && $0.principal.id == caller.objectId }
                return page(mine.sorted { $0.createdOn > $1.createdOn }.map(Self.json(request:)), url: url, query: query)
            case "asApprover()":
                let ids = Set(approvals(of: caller).map(\.id))
                let theirs = state.requests.filter { r in
                    r.tenantId == caller.tenant.id && r.principal.id != caller.objectId && r.approvalId.map(ids.contains) == true
                }
                return page(theirs.sorted { $0.createdOn < $1.createdOn }.map(Self.json(request:)), url: url, query: query)
            case "asRequestor()":
                return Self.error(403, "InsufficientPermissions", "The requestor does not have permissions to list requests at this scope.")
            default:
                return Self.unsupportedFilter(filter)
            }
        case ("PUT", "roleassignmentschedulerequests", 2):
            guard apiVersion == ARM.apiVersion else { return Self.badApiVersion(apiVersion) }
            return createRequest(name: rest[1], scope: scope, body: request.httpBody ?? Data(), caller: caller)
        case ("POST", "roleassignmentschedulerequests", 3) where rest[2].lowercased() == "cancel":
            guard apiVersion == ARM.apiVersion else { return Self.badApiVersion(apiVersion) }
            return cancelRequest(name: rest[1], caller: caller)
        case ("GET", "rolemanagementpolicyassignments", 1):
            guard apiVersion == ARM.apiVersion else { return Self.badApiVersion(apiVersion) }
            return policies(scope: scope, filter: filter, caller: caller)
        case ("GET", "roleassignmentapprovals", 1):
            guard apiVersion == ARM.approvalsApiVersion else { return Self.badApiVersion(apiVersion) }
            guard scope.isEmpty, filter == "asApprover()" else {
                return Self.message(400, "The filter '\(filter)' is not supported. Use $filter=asApprover().")
            }
            return page(approvals(of: caller).map { Self.json(approval: $0, caller: caller.objectId) }, url: url, query: query)
        case ("GET", "roleassignmentapprovals", 3) where rest[2].lowercased() == "stages":
            guard apiVersion == ARM.approvalsApiVersion else { return Self.badApiVersion(apiVersion) }
            guard let approval = visibleApproval(rest[1], caller: caller) else {
                return Self.message(404, "The approval \(rest[1]) was not found.")
            }
            return page([Self.json(stage: approval, caller: caller.objectId)], url: url, query: query)
        case ("PATCH", "roleassignmentapprovals", 4) where rest[2].lowercased() == "stages":
            guard apiVersion == ARM.approvalsApiVersion else { return Self.badApiVersion(apiVersion) }
            return decide(approvalId: rest[1], stageId: rest[3], body: request.httpBody ?? Data(), caller: caller)
        default:
            return Self.error(404, "InvalidResourceType", "The resource type '\(rest.joined(separator: "/"))' could not be found.")
        }
    }

    func eligibilities(of caller: Caller) -> [DemoEligibility] {
        guard caller.objectId == user.id else { return [] }
        return state.eligibilities.filter { $0.tenantId == caller.tenant.id }
    }

    func approvals(of caller: Caller) -> [DemoApproval] {
        state.approvals.filter { $0.tenantId == caller.tenant.id && $0.approvers.contains { $0.id == caller.objectId } }
    }

    /// An approval the caller decides or asked for.
    func visibleApproval(_ id: String, caller: Caller) -> DemoApproval? {
        guard let approval = state.approvals.first(where: { $0.tenantId == caller.tenant.id && $0.id.caseInsensitiveCompare(id) == .orderedSame })
        else { return nil }
        let requester = state.requests.first { $0.name == approval.requestName }?.principal.id
        return approval.approvers.contains { $0.id == caller.objectId } || requester == caller.objectId ? approval : nil
    }

    /// One page of `items`; `$skiptoken` says where it starts, `nextLink` where the next one does.
    func page(_ items: [[String: Any]], url: URL, query: [String: String], pageSize: Int? = nil) -> (Data, Int) {
        let size = max(1, pageSize ?? storedBehavior.pageSize)
        let skip = min(items.count, max(0, Int(query["$skiptoken"] ?? "") ?? 0))
        let slice = Array(items[skip..<min(items.count, skip + size)])
        var body: [String: Any] = ["value": slice]
        if skip + size < items.count, var components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            var items = (components.queryItems ?? []).filter { $0.name != "$skiptoken" }
            items.append(URLQueryItem(name: "$skiptoken", value: String(skip + size)))
            components.queryItems = items
            body["nextLink"] = components.url?.absoluteString
        }
        return Self.ok(body)
    }

    func policies(scope: String, filter: String, caller: Caller) -> (Data, Int) {
        // `roleDefinitionId eq '/subscriptions/…/roleDefinitions/<guid>'`
        guard filter.hasPrefix("roleDefinitionId eq '"), filter.hasSuffix("'"),
              let guid = filter.dropLast().split(separator: "/").last.map({ String($0).lowercased() }) else {
            return Self.error(400, "InvalidFilter", "The filter '\(filter)' is not valid.")
        }
        let key = RoleMatcher.key(scope: scope, roleDefinitionId: guid)
        guard let eligibility = state.eligibilities.first(where: { $0.tenantId == caller.tenant.id && $0.policyKey == key }) else {
            return Self.ok(["value": [] as [Any]])
        }
        return Self.ok(["value": [Self.json(policyOf: eligibility)]])
    }

    // MARK: Time

    /// Applies everything that happened by `now`: arrivals, decisions of the
    /// simulated approver, expired requests, scheduled starts, expiry.
    func tick(_ now: Date) {
        while let next = state.arrivals.first, next.at <= now {
            state.arrivals.removeFirst()
            state.requests.append(next.request)
            state.approvals.append(next.approval)
        }
        for i in state.requests.indices where state.requests[i].status == "PendingApproval" {
            let r = state.requests[i]
            if let at = r.decideAt, at <= now, r.principal.id == user.id {
                decideByApprover(i, at: at)
            } else if r.createdOn.addingTimeInterval(ScheduledRequest.approvalWindow) <= now {
                state.requests[i].status = "TimedOut"
                updateApproval(of: r) { $0.status = "Expired" }
            }
        }
        for i in state.requests.indices where state.requests[i].status == "Granted" && state.requests[i].start <= now {
            state.requests[i].status = "Provisioned"
            if state.requests[i].principal.id == user.id { startActivation(state.requests[i], at: state.requests[i].start) }
        }
        state.assignments.removeAll { $0.end.map { $0 <= now } ?? false }
        state.lingering = state.lingering.filter { $0.value > now }
    }

    /// The simulated approver decides request `i` at `at`.
    private func decideByApprover(_ i: Int, at: Date) {
        let r = state.requests[i]
        let approve = r.decision != .deny
        updateApproval(of: r) {
            $0.status = "Completed"
            $0.reviewResult = approve ? "Approve" : "Deny"
            $0.reviewedBy = DemoDirectory.megan
            $0.reviewedAt = at
            $0.justification = approve ? "Approved for the change window" : "Please attach a change ticket and ask again"
        }
        guard approve else {
            state.requests[i].status = "Denied"
            return
        }
        if r.start <= at.addingTimeInterval(ScheduleTime.immediateSlack) {
            // Active from the approval on, for the asked duration.
            state.requests[i].start = at
            state.requests[i].status = "Provisioned"
            startActivation(state.requests[i], at: at)
        } else {
            state.requests[i].status = "Granted"
        }
    }

    private func updateApproval(of request: DemoRequest, _ change: (inout DemoApproval) -> Void) {
        guard let id = request.approvalId, let j = state.approvals.firstIndex(where: { $0.id == id }) else { return }
        change(&state.approvals[j])
    }

    private func startActivation(_ r: DemoRequest, at start: Date) {
        state.assignments.removeAll { $0.kind == .activated && $0.tenantId == r.tenantId && $0.policyKey == r.policyKey }
        state.assignments.append(DemoAssignment(
            tenantId: r.tenantId, name: r.name, scope: r.scope, role: r.role, kind: .activated, start: start,
            end: r.minutes.map { start.addingTimeInterval(TimeInterval($0) * 60) }, linkedEligibilityScheduleId: r.linkedEligibilityScheduleId,
            condition: r.condition))
    }

    // MARK: Writes

    func createRequest(name rawName: String, scope rawScope: String, body: Data, caller: Caller) -> (Data, Int) {
        let now = clock.now()
        let name = rawName.lowercased()
        guard UUID(uuidString: name) != nil else { return Self.error(400, "InvalidRoleAssignmentScheduleRequestName", "The request name must be a GUID.") }
        guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any], let p = object["properties"] as? [String: Any] else {
            return Self.error(400, "InvalidRequestContent", "The request content was invalid and could not be deserialized.")
        }
        guard (p["principalId"] as? String)?.lowercased() == caller.objectId else {
            return Self.error(403, "AuthorizationFailed", "The client does not have authorization to make requests for another principal.")
        }
        guard !state.requests.contains(where: { $0.name == name }) else {
            return Self.error(409, "RoleAssignmentScheduleRequestExists", "A request with the name \(name) already exists.")
        }
        let roleGUID = RoleMatcher.lastPathComponent(p["roleDefinitionId"] as? String ?? "").lowercased()
        let key = RoleMatcher.key(scope: rawScope, roleDefinitionId: roleGUID)
        let requestType = p["requestType"] as? String ?? ""
        let justification = (p["justification"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let ticketObject = p["ticketInfo"] as? [String: Any]
        let ticket = TicketInfo.make(number: ticketObject?["ticketNumber"] as? String, system: ticketObject?["ticketSystem"] as? String)
        let schedule = p["scheduleInfo"] as? [String: Any]
        let expiration = schedule?["expiration"] as? [String: Any]
        let condition = (p["condition"] as? String)?.nonEmpty

        switch requestType {
        case RequestAction.activate.requestType:
            let candidates = state.eligibilities.filter { $0.tenantId == caller.tenant.id && $0.policyKey == key }
            let linked = (p["linkedRoleEligibilityScheduleId"] as? String)?.lowercased()
            guard let eligibility = candidates.first(where: { $0.scheduleId.lowercased() == linked }) ?? candidates.first,
                  caller.objectId == user.id else {
                return Self.error(403, "InsufficientPermissions", "No eligible role assignment exists for this principal at this scope.")
            }
            guard condition == eligibility.condition else {
                return Self.error(400, "InvalidCondition", "The condition must be the eligibility's condition, unchanged.")
            }
            let start = AzureDate.parse(schedule?["startDateTime"] as? String) ?? now
            let seconds = ISODuration.parse(expiration?["duration"] as? String)
                ?? AzureDate.parse(expiration?["endDateTime"] as? String).map { $0.timeIntervalSince(start) } ?? 0
            let minutes = Int((seconds / 60).rounded())
            guard minutes > 0 else { return Self.error(400, "InvalidScheduleInfo", "The expiration of the request is invalid.") }
            var failed: [String] = []
            if eligibility.policy.justification && justification.isEmpty { failed.append("JustificationRule") }
            if eligibility.policy.ticket && !(ticket?.isComplete ?? false) { failed.append("TicketingRule") }
            if minutes > eligibility.policy.maxMinutes { failed.append("ExpirationRule") }
            if !failed.isEmpty {
                return Self.error(400, "RoleAssignmentRequestPolicyValidationFailed",
                                  "The following policy rules failed: [\(failed.map { "\"\($0)\"" }.joined(separator: ","))]")
            }
            let scheduled = start > now.addingTimeInterval(ScheduleTime.immediateSlack)
            if state.requests.contains(where: { $0.tenantId == caller.tenant.id && $0.policyKey == key && $0.principal.id == user.id
                && $0.status == "PendingApproval" }) {
                return Self.error(400, "PendingRoleAssignmentRequest", "There is already an existing pending Role assignment request.")
            }
            let active = state.assignments.first { $0.tenantId == caller.tenant.id && $0.policyKey == key && $0.kind == .activated }
            if let active, (active.end ?? .distantFuture) > start {
                return Self.error(400, "RoleAssignmentExists", "The Role assignment already exists.")
            }
            if !scheduled, let until = state.lingering[key], until > now {
                return Self.error(400, "RoleAssignmentExists", "The Role assignment already exists.")
            }
            var request = DemoRequest(
                tenantId: caller.tenant.id, name: name, scope: eligibility.scope, role: eligibility.role, principal: user,
                requestType: requestType, status: "Provisioned", start: scheduled ? start : now, minutes: minutes, end: nil,
                justification: justification.nonEmpty, ticket: ticket, createdOn: now,
                linkedEligibilityScheduleId: eligibility.scheduleId, approvalId: nil, targetScheduleId: nil, condition: condition)
            if eligibility.policy.approval {
                let approval = DemoApproval(tenantId: caller.tenant.id, id: DemoID.uuid("approval-\(name)"), requestName: name,
                                            approvers: [DemoDirectory.megan])
                state.approvals.append(approval)
                request.approvalId = approval.id
                request.status = "PendingApproval"
                request.decideAt = now.addingTimeInterval(storedBehavior.approvalDelay)
                // Say "deny" in the justification to see a denial.
                request.decision = justification.lowercased().contains("deny") ? .deny : .approve
            } else if scheduled {
                request.status = "Granted"
            } else {
                startActivation(request, at: now)
            }
            state.requests.append(request)
            return Self.created(Self.json(request: request))

        case RequestAction.deactivate.requestType:
            guard let i = state.assignments.firstIndex(where: { $0.tenantId == caller.tenant.id && $0.policyKey == key && $0.kind == .activated }),
                  caller.objectId == user.id else {
                return Self.error(400, "RoleAssignmentDoesNotExist", "The Role assignment does not exist.")
            }
            let active = state.assignments[i]
            if now < active.start.addingTimeInterval(ActivationResponseMapper.minimumActiveTime) {
                let code = storedBehavior.tooSoonCode
                return Self.error(400, code, code == "ActiveDurationTooShort"
                    ? "The role assignment cannot be removed within 5 minutes of its activation."
                    : "The Role assignment does not exist.")
            }
            state.assignments.remove(at: i)
            state.lingering[key] = now.addingTimeInterval(storedBehavior.removalDelay)
            let request = DemoRequest(
                tenantId: caller.tenant.id, name: name, scope: active.scope, role: active.role, principal: user, requestType: requestType,
                status: "Revoked", start: now, minutes: nil, end: nil, justification: justification.nonEmpty, ticket: nil, createdOn: now,
                linkedEligibilityScheduleId: (p["linkedRoleEligibilityScheduleId"] as? String) ?? active.linkedEligibilityScheduleId,
                approvalId: nil, targetScheduleId: active.scheduleId, condition: condition)
            state.requests.append(request)
            return Self.created(Self.json(request: request))

        case RequestAction.extend.requestType:
            let target = (p["targetRoleAssignmentScheduleId"] as? String)?.lowercased()
            guard let assignment = state.assignments.first(where: {
                $0.tenantId == caller.tenant.id && $0.kind == .assigned && $0.scheduleId.lowercased() == target
            }) else {
                return Self.error(400, "RoleAssignmentDoesNotExist", "The Role assignment does not exist.")
            }
            if state.requests.contains(where: { $0.targetScheduleId?.lowercased() == target && $0.status == "PendingAdminDecision" }) {
                return Self.error(400, "PendingRoleAssignmentRequest", "There is already an existing pending Role assignment request.")
            }
            guard !justification.isEmpty else {
                return Self.error(400, "RoleAssignmentRequestPolicyValidationFailed", "The following policy rules failed: [\"JustificationRule\"]")
            }
            let request = DemoRequest(
                tenantId: caller.tenant.id, name: name, scope: assignment.scope, role: assignment.role, principal: user,
                requestType: requestType, status: "PendingAdminDecision",
                start: AzureDate.parse(schedule?["startDateTime"] as? String) ?? assignment.start, minutes: nil,
                end: AzureDate.parse(expiration?["endDateTime"] as? String), justification: justification, ticket: ticket, createdOn: now,
                linkedEligibilityScheduleId: nil, approvalId: nil, targetScheduleId: assignment.scheduleId, condition: condition)
            state.requests.append(request)
            return Self.created(Self.json(request: request))

        default:
            return Self.error(400, "InvalidRequestType", "The request type '\(requestType)' is not valid here.")
        }
    }

    func cancelRequest(name: String, caller: Caller) -> (Data, Int) {
        guard let i = state.requests.firstIndex(where: {
            $0.tenantId == caller.tenant.id && $0.name.caseInsensitiveCompare(name) == .orderedSame && $0.principal.id == caller.objectId
        }) else {
            return Self.error(404, "RoleAssignmentScheduleRequestNotFound", "The role assignment schedule request \(name) was not found.")
        }
        let r = state.requests[i]
        let cancellable = ["pendingapproval", "pendingadmindecision"].contains(r.status.lowercased())
            || (r.status == "Granted" && r.start > clock.now())
        guard cancellable else {
            return Self.error(400, CancelOutcome.notCancellableCode, "Only requests in pending state can be cancelled.")
        }
        state.requests[i].status = "Canceled"
        updateApproval(of: r) { $0.status = "Canceled" }
        return (Data(), 200)
    }

    func decide(approvalId: String, stageId: String, body: Data, caller: Caller) -> (Data, Int) {
        guard let j = state.approvals.firstIndex(where: {
            $0.tenantId == caller.tenant.id && $0.id.caseInsensitiveCompare(approvalId) == .orderedSame
                && $0.stageId.caseInsensitiveCompare(stageId) == .orderedSame
        }) else {
            return Self.message(404, "The approval stage \(stageId) was not found.")
        }
        guard state.approvals[j].approvers.contains(where: { $0.id == caller.objectId }) else {
            return Self.error(403, "AuthorizationFailed", "You are not an approver of this request.")
        }
        guard state.approvals[j].isOpen else { return Self.message(404, "The approval stage is no longer in progress.") }
        guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let result = object["reviewResult"] as? String, ["Approve", "Deny"].contains(result) else {
            return Self.message(400, "reviewResult must be Approve or Deny.")
        }
        let justification = (object["justification"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !justification.isEmpty else { return Self.message(400, "A justification is required.") }
        let now = clock.now()
        state.approvals[j].status = "Completed"
        state.approvals[j].reviewResult = result
        state.approvals[j].justification = justification
        state.approvals[j].reviewedBy = state.approvals[j].approvers.first { $0.id == caller.objectId }
        state.approvals[j].reviewedAt = now
        if let i = state.requests.firstIndex(where: { $0.name == state.approvals[j].requestName }) {
            if result == "Deny" {
                state.requests[i].status = "Denied"
            } else if state.requests[i].start > now.addingTimeInterval(ScheduleTime.immediateSlack) {
                state.requests[i].status = "Granted"
            } else {
                state.requests[i].start = now
                state.requests[i].status = "Provisioned"
            }
        }
        return Self.ok(Self.json(stage: state.approvals[j], caller: caller.objectId))
    }

    // MARK: Sign-in (login.microsoftonline.com)

    func identity(method: String, url: URL, body: Data) -> (Data, Int) {
        let parts = url.path.split(separator: "/").map(String.init)
        guard method == "POST", parts.count == 4, parts[1] == "oauth2", parts[2] == "v2.0" else {
            return Self.oauthError(404, "invalid_request", "AADSTS900561: The endpoint only accepts POST requests.", code: 900561)
        }
        guard let tenant = resolveTenant(parts[0]) else {
            return Self.oauthError(400, "invalid_request", "AADSTS90002: Tenant '\(parts[0])' not found.", code: 90002)
        }
        let form = TokenRequest.formDecode(String(decoding: body, as: UTF8.self))
        guard MicrosoftIdentity.isValidClientId(form["client_id"] ?? "") else {
            return Self.oauthError(400, "unauthorized_client", "AADSTS700016: Application not found in the directory.", code: 700016)
        }
        switch parts[3] {
        case "devicecode":
            let device = "demo-device-\(UUID().uuidString.lowercased())"
            state.deviceCodes[device] = 0
            return Self.ok([
                "device_code": device, "user_code": "DEMO-4821", "verification_uri": "https://microsoft.com/devicelogin",
                "expires_in": 900, "interval": 1,
                "message": "Pimento demo: no browser needed, the demo signs you in by itself in a moment.",
            ])
        case "token":
            switch form["grant_type"] ?? "" {
            case "refresh_token":
                guard form["refresh_token"] == DemoDirectory.refreshToken else {
                    return Self.oauthError(400, "invalid_grant", "AADSTS70000: The provided grant is invalid or malformed.", code: 70000)
                }
                return tokens(tenant: tenant, nonce: nil)
            case "urn:ietf:params:oauth:grant-type:device_code":
                guard let device = form["device_code"], let polls = state.deviceCodes[device] else {
                    return Self.oauthError(400, "expired_token", "AADSTS70019: Verification code expired.", code: 70019)
                }
                guard polls >= storedBehavior.deviceCodePolls else {
                    state.deviceCodes[device] = polls + 1
                    return Self.oauthError(400, "authorization_pending", "AADSTS70016: OAuth 2.0 device flow error. Authorization is pending.",
                                           code: 70016)
                }
                state.deviceCodes[device] = nil
                return tokens(tenant: tenant, nonce: nil)
            case "authorization_code":
                // `demo-code.<nonce>`: what a demo "browser" hands back.
                guard let code = form["code"], code.hasPrefix("demo-code") else {
                    return Self.oauthError(400, "invalid_grant", "AADSTS70000: The provided grant is invalid or malformed.", code: 70000)
                }
                let nonce = code.split(separator: ".", maxSplits: 1).dropFirst().first.map(String.init)
                return tokens(tenant: tenant, nonce: nonce)
            default:
                return Self.oauthError(400, "unsupported_grant_type", "AADSTS70003: The app requested an unsupported grant type.", code: 70003)
            }
        default:
            return Self.oauthError(404, "invalid_request", "AADSTS900561: Unknown endpoint.", code: 900561)
        }
    }

    func tokens(tenant: DemoTenant, nonce: String?) -> (Data, Int) {
        let now = Int(clock.now().timeIntervalSince1970)
        var idClaims: [String: Any] = [
            "aud": DemoDirectory.clientId, "iss": "https://login.microsoftonline.com/\(tenant.id)/v2.0", "iat": now, "exp": now + 3600,
            "oid": user.id, "tid": tenant.id, "name": user.displayName, "preferred_username": user.email ?? "",
        ]
        if let nonce { idClaims["nonce"] = nonce }
        let info = try! JSONSerialization.data(withJSONObject: ["uid": user.id, "utid": homeTenant.id], options: [.sortedKeys])
        return Self.ok([
            "token_type": "Bearer", "scope": MicrosoftIdentity.scope, "expires_in": 3599, "ext_expires_in": 3599,
            "access_token": accessToken(tenant: tenant), "refresh_token": DemoDirectory.refreshToken,
            "id_token": DemoToken.make(idClaims), "client_info": Base64URL.encode(Array(info)),
        ])
    }
}

/// The demo's stand-in for `az account get-access-token`.
struct DemoCLITokenProvider: TokenProvider {
    let azure: DemoAzure
    let tenantId: String?

    func accessToken() async throws -> String { try azure.cliAccessToken(tenantId: tenantId) }
}

/// Unsigned JWTs (`alg: none`): the simulator reads their claims as ARM
/// would read a real token's; nothing else ever sees them.
public enum DemoToken {
    public static func make(_ claims: [String: Any]) -> String {
        func b64(_ object: Any) -> String {
            Base64URL.encode(Array((try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()))
        }
        return "\(b64(["alg": "none", "typ": "JWT"])).\(b64(claims)).demo"
    }
}
