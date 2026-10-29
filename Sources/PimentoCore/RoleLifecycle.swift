import Foundation

/// Ending and renewing activations: what PIM allows, decided before anything
/// is sent.
///
/// - **Deactivate** (`SelfDeactivate`) ends an activation early. PIM refuses
///   it in the first five minutes after activation (it answers
///   `RoleAssignmentDoesNotExist` then; the docs also name
///   `ActiveDurationTooShort`).
/// - **Renew** = deactivate + activate again, for a fresh full duration. PIM
///   has no self-service way to lengthen an activation: `SelfExtend` on an
///   activation is accepted only as a request an administrator must approve
///   (`PendingAdminDecision`), and the schedule it carries is ignored. After
///   the deactivation PIM refuses the new activation (`RoleAssignmentExists`)
///   until it has removed the old assignment: about three minutes in tests, so
///   the role is off for minutes, not seconds. Renew is refused for roles
///   whose policy requires approval (the role would stay off until someone
///   approves).
/// - **Extend** (`SelfExtend`) is for admin-assigned time-bound assignments:
///   a request to an administrator, nothing changes until approved.
public enum RoleLifecycle {
    /// When `role`'s activation may be ended (start + 5 minutes); nil when
    /// the start is unknown.
    public static func earliestDeactivation(of role: EligibleRole) -> Date? {
        role.activeSince.map { $0.addingTimeInterval(ActivationResponseMapper.minimumActiveTime) }
    }

    /// True when PIM would refuse to end `role`'s activation at `now`.
    public static func isTooSoonToEnd(_ role: EligibleRole, now: Date) -> Bool {
        guard let at = earliestDeactivation(of: role) else { return false }
        return now < at
    }

    /// The selection split by what can be ended now. Rows that share a
    /// scope + role are one activation and appear once (direct rows first).
    public struct Selection: Equatable, Sendable {
        /// Active and old enough: will be sent.
        public var ready: [EligibleRole] = []
        /// Activated less than five minutes ago, with the time it becomes possible.
        public var tooSoon: [EligibleRole] = []
        /// Not active (eligible only): nothing to end.
        public var inactive: [EligibleRole] = []
        /// Would need approval to come back (Renew only).
        public var needsApproval: [EligibleRole] = []
        /// Its policy requires a ticket and none is known (Renew only).
        public var needsTicket: [EligibleRole] = []

        public var isEmpty: Bool { ready.isEmpty && tooSoon.isEmpty && inactive.isEmpty && needsApproval.isEmpty && needsTicket.isEmpty }
    }

    /// `needsTicket` (renewal): the role's policy requires a ticket and no
    /// ticket is available for it, so it cannot be activated again.
    public static func select(
        _ roles: [EligibleRole], now: Date, forRenewal: Bool = false,
        needsTicket: (EligibleRole) -> Bool = { _ in false },
        requiresApproval: (EligibleRole) -> Bool = { _ in false }
    ) -> Selection {
        var byKey: [RoleMatcher.Key: EligibleRole] = [:]
        var order: [RoleMatcher.Key] = []
        for role in roles {
            if let existing = byKey[role.policyKey] {
                if existing.membership != .direct, role.membership == .direct { byKey[role.policyKey] = role }
                continue
            }
            byKey[role.policyKey] = role
            order.append(role.policyKey)
        }
        var result = Selection()
        for key in order {
            let role = byKey[key]!
            if !role.isActive {
                result.inactive.append(role)
            } else if forRenewal && requiresApproval(role) {
                result.needsApproval.append(role)
            } else if forRenewal && needsTicket(role) {
                result.needsTicket.append(role)
            } else if isTooSoonToEnd(role, now: now) {
                result.tooSoon.append(role)
            } else {
                result.ready.append(role)
            }
        }
        return result
    }

    /// How long until `role` expires, if it does.
    public static func timeLeft(_ role: EligibleRole, now: Date) -> TimeInterval? {
        role.activeUntil.map { $0.timeIntervalSince(now) }
    }
}

/// Which ticket a renewal sends: one given now wins; otherwise the ticket
/// the current activation was requested with, when known.
public enum RenewTicket {
    public static func choose(given: TicketInfo?, original: TicketInfo?) -> TicketInfo? {
        if let given, !given.isEmpty { return given }
        if let original, !original.isEmpty { return original }
        return nil
    }

    /// True when `role`'s policy requires a ticket and `ticket` is not complete.
    public static func isMissing(_ role: EligibleRole, ticket: TicketInfo?, policy: PolicyLookup?) -> Bool {
        policy?.policy?.requiresTicket == true && ticket?.isComplete != true
    }
}

/// One role to renew: its deactivation and the activation that follows.
public struct RenewPlan: Identifiable, Sendable, Equatable {
    public var id: String { role.id }
    public let role: EligibleRole
    public let principalId: String
    public let justification: String
    public let duration: EffectiveDuration
    /// Sent with the new activation: the one given, or the ticket the
    /// original activation was requested with.
    public var ticket: TicketInfo?
    public let deactivation: PlannedRequest
    /// The activation as planned now (for dry runs); the real one is rebuilt
    /// with a fresh request id and start time on every attempt.
    public let plannedActivation: PlannedRequest

    /// A new `SelfActivate` request for `now`.
    public func activation(now: Date, requestId: UUID = UUID()) throws -> PlannedRequest {
        let active = Self.asEligible(role)
        return PlannedRequest(
            role: active,
            url: ActivationRequestBuilder.url(for: role, requestId: requestId),
            body: try ActivationRequestBuilder.body(
                for: active, principalId: principalId, justification: justification, minutes: duration.minutes, now: now,
                ticket: ticket),
            requestedAt: now,
            duration: duration)
    }

    /// The row as it is between the two requests.
    public static func asEligible(_ role: EligibleRole) -> EligibleRole {
        var r = role
        r.isActive = false
        r.activeUntil = nil
        r.activeSince = nil
        r.activeScheduleId = nil
        return r
    }

    /// PIM still holds the old assignment (or the deactivation request) for a
    /// moment: try again.
    public static func shouldRetry(_ outcome: ActivationOutcome) -> Bool {
        switch outcome {
        case .alreadyActive: true
        case .failed(let code, _): ActivationResponseMapper.pendingRequestCodes.contains(code) || code == "NetworkError"
        default: false
        }
    }

    /// The final outcome of a renewal, from the last activation attempt.
    public static func result(of activation: ActivationOutcome) -> ActivationOutcome {
        switch activation {
        case .activated(let status, let until) where ActivationOutcome.isGranted(status: status):
            return .renewed(until: until)
        case .activated:
            return activation
        case .alreadyActive:
            return .failed(code: "ReactivationFailed",
                           message: "Deactivated, but PIM still reported the old activation after five minutes. Refresh and activate it again.")
        default:
            return .failed(code: "ReactivationFailed",
                           message: "Deactivated, but activating it again failed: \(activation.summary). Activate it again.")
        }
    }

    public static func == (a: RenewPlan, b: RenewPlan) -> Bool {
        a.role == b.role && a.ticket == b.ticket && a.deactivation == b.deactivation && a.plannedActivation == b.plannedActivation
    }
}

extension ActivationRequestBuilder {
    /// One renewal per activation (rows sharing a scope + role count once).
    public static func renewPlan(
        _ roles: [EligibleRole],
        principalId: String,
        justification: String,
        now: Date = Date(),
        makeId: () -> UUID = UUID.init,
        ticket: (EligibleRole) -> TicketInfo? = { _ in nil },
        duration: (EligibleRole) -> EffectiveDuration
    ) throws -> [RenewPlan] {
        let text = justification.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw ActivationRequestError.missingJustification }
        let deactivations = try deactivationPlan(roles, principalId: principalId, justification: text, now: now, makeId: makeId)
        return try deactivations.map { off in
            let d = duration(off.role)
            let t = ticket(off.role).flatMap { $0.isEmpty ? nil : $0 }
            let eligible = RenewPlan.asEligible(off.role)
            let on = PlannedRequest(
                role: eligible,
                url: url(for: off.role, requestId: makeId()),
                body: try body(for: eligible, principalId: principalId, justification: text, minutes: d.minutes, now: now, ticket: t),
                requestedAt: now,
                duration: d)
            return RenewPlan(role: off.role, principalId: principalId, justification: text, duration: d, ticket: t,
                             deactivation: off, plannedActivation: on)
        }
    }
}
