import Foundation

/// Turning a selection of roles into the requests an activation or a renewal
/// sends: shared by `pimento activate` / `renew` and `pimento mcp`, so that
/// both cap durations, carry tickets and skip roles in the same way.
public enum ActivationPlanning {
    /// Splits `matched` into the roles still active at `start` (now when nil),
    /// which are skipped, and the ones to activate. A role whose activation
    /// has ended by a later start can be scheduled.
    public static func split(_ matched: [EligibleRole], start: Date?) -> (skipped: [EligibleRole], toActivate: [EligibleRole]) {
        func activeAtStart(_ r: EligibleRole) -> Bool {
            guard r.isActive else { return false }
            guard let start, let until = r.activeUntil else { return true }
            return until > start
        }
        return (matched.filter(activeAtStart), matched.filter { !activeAtStart($0) })
    }

    /// One `SelfActivate` per role for `requested`, capped at each role's
    /// policy maximum (the asked duration when the policy is unknown).
    public static func activationPlans(
        _ roles: [EligibleRole], policies: [RoleMatcher.Key: PolicyLookup], principalId: String, justification: String,
        requested: RequestedDuration, ticket: TicketInfo?, now: Date, start: Date? = nil
    ) throws -> [PlannedRequest] {
        try ActivationRequestBuilder.plan(
            roles, principalId: principalId, justification: justification, now: now, start: start, ticket: ticket
        ) { role in
            EffectiveDuration.resolve(requested, policyMaxMinutes: policies[role.policyKey]?.maxMinutes,
                                      fallbackHours: ActivationRequestBuilder.defaultHours)
        }
    }

    /// What a renewal of some roles sends, and why the others are left out.
    public struct Renewal: Sendable {
        public var selection: RoleLifecycle.Selection
        public var plans: [RenewPlan]
        /// The roles that are not renewed and why: too soon to end, approval
        /// required, policy unknown, ticket missing.
        public var outcomes: [String: ActivationOutcome]
        public var policies: [RoleMatcher.Key: PolicyLookup]
    }
}

extension PIMService {
    /// Plans the renewal of `matched` (read-only: policies and your requests,
    /// for the ticket each activation was made with). `given` is a ticket
    /// passed now; it wins over the original one.
    public func planRenewal(
        _ matched: [EligibleRole], principalId: String, justification: String, requested: RequestedDuration,
        given: TicketInfo?, now: Date
    ) async throws -> ActivationPlanning.Renewal {
        let active = matched.filter(\.isActive)
        let policies = (try? await loadPolicies(for: active)) ?? [:]
        let originals = active.isEmpty ? [:] : ((try? await loadRequestHistory(now: now))?.activationTickets ?? [:])
        func ticket(_ role: EligibleRole) -> TicketInfo? {
            RenewTicket.choose(given: given, original: RequestHistory.ticket(for: role, in: originals))
        }
        let selection = RoleLifecycle.select(
            matched, now: now, forRenewal: true,
            needsTicket: { RenewTicket.isMissing($0, ticket: ticket($0), policy: policies[$0.policyKey]) },
            requiresApproval: { policies[$0.policyKey]?.policy?.requiresApproval == true },
            // A policy that could not be read is not taken as "no approval needed".
            policyKnown: { policies[$0.policyKey]?.policy != nil })
        let plans = try ActivationRequestBuilder.renewPlan(
            selection.ready, principalId: principalId, justification: justification, now: now, ticket: ticket
        ) { role in
            EffectiveDuration.resolve(requested, policyMaxMinutes: policies[role.policyKey]?.maxMinutes,
                                      fallbackHours: ActivationRequestBuilder.defaultHours)
        }
        var outcomes: [String: ActivationOutcome] = [:]
        for r in selection.tooSoon { outcomes[r.id] = .tooSoon(possibleAt: RoleLifecycle.earliestDeactivation(of: r)) }
        for r in selection.needsApproval {
            outcomes[r.id] = .failed(code: "ApprovalRequired", message: "the role's policy requires approval; renewing would leave it off until approved")
        }
        for r in selection.policyUnknown {
            outcomes[r.id] = .failed(code: "PolicyUnknown",
                                     message: "the role's policy could not be read; renewing might leave it off until approved")
        }
        for r in selection.needsTicket {
            outcomes[r.id] = .failed(code: "TicketRequired",
                                     message: "the role's policy requires a ticket and the current activation's is unknown; add --ticket NUMBER --ticket-system NAME")
        }
        return ActivationPlanning.Renewal(selection: selection, plans: plans, outcomes: outcomes, policies: policies)
    }
}
