import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum ActivationOutcome: Equatable, Sendable {
    /// Request accepted. `status` is the request status (`Provisioned`, `PendingApproval`, …).
    case activated(status: String, until: Date?)
    /// `RoleAssignmentExists`: the role was already active.
    case alreadyActive
    /// `RoleAssignmentRequestPolicyValidationFailed`, with the failing rule names.
    case policyViolation(rules: [String], message: String)
    case failed(code: String, message: String)
    /// `SelfDeactivate` accepted: the activation ends now.
    case deactivated(status: String)
    /// `RoleAssignmentDoesNotExist` on a deactivation: it had already ended.
    case notActive
    /// PIM does not end an activation in its first five minutes: it answers
    /// `RoleAssignmentDoesNotExist` then (`ActiveDurationTooShort` is mapped
    /// the same way). `possibleAt`: from when it can be ended.
    case tooSoon(possibleAt: Date?)
    /// Deactivated and activated again (Renew).
    case renewed(until: Date?)
    /// Accepted for a later start (PIM answers `Granted` and activates the
    /// role at `start`). `until`: when that activation ends.
    case scheduled(status: String, start: Date, until: Date?)

    public var isFailure: Bool {
        switch self {
        case .policyViolation, .failed, .tooSoon: true
        default: false
        }
    }

    /// The role is (still or again) active after this outcome.
    public var leavesRoleActive: Bool {
        switch self {
        case .activated(let status, _): Self.isGranted(status: status)
        case .alreadyActive, .renewed, .tooSoon: true
        case .deactivated, .notActive, .scheduled: false
        case .policyViolation, .failed: false
        }
    }

    /// Accepted, but waiting for an approver (`PendingApproval`).
    public var isAwaitingApproval: Bool {
        guard case .activated(let status, _) = self else { return false }
        return ApprovalParser.decidableStatuses.contains(status.lowercased())
    }

    /// True for a request status that means the role is active now; anything
    /// else (`PendingApproval`, …) was only submitted.
    public static func isGranted(status: String) -> Bool {
        status.isEmpty || ["Provisioned", "Accepted", "Granted"].contains { status.caseInsensitiveCompare($0) == .orderedSame }
    }

    /// True for ARM's token errors: signing in again is the fix.
    public var isAuthFailure: Bool {
        guard case .failed(let code, _) = self else { return false }
        return ActivationResponseMapper.authErrorCodes.contains(code)
    }

    /// One-line text for the result column.
    public var summary: String {
        switch self {
        case .activated(let status, let until):
            if isAwaitingApproval { return "Awaiting approval" }
            if !Self.isGranted(status: status) { return "Submitted (\(status))" }
            if let until { return "Activated until \(until.formatted(date: .omitted, time: .shortened))" }
            return "Activated"
        case .alreadyActive:
            return "Skipped (already active)"
        case .policyViolation(let rules, let message):
            if rules.isEmpty { return "Policy: \(message)" }
            return "Policy: " + rules.map(ActivationResponseMapper.describe(rule:)).joined(separator: "; ")
        case .failed(let code, let message):
            return message.isEmpty ? code : "\(code): \(message)"
        case .deactivated(let status):
            return Self.isEnded(status: status) ? "Deactivated" : "Deactivation \(status)"
        case .notActive:
            return "Not active (already ended)"
        case .tooSoon(let at):
            if let at { return "Too soon: can be ended from \(at.formatted(date: .omitted, time: .shortened))" }
            return "Too soon: PIM ends an activation only after 5 minutes"
        case .renewed(let until):
            if let until { return "Renewed until \(until.formatted(date: .omitted, time: .shortened))" }
            return "Renewed"
        case .scheduled(_, let start, _):
            return "Scheduled for \(ScheduleTime.label(start, now: Date()))"
        }
    }

    /// True for a deactivation request status that means the role is gone.
    public static func isEnded(status: String) -> Bool {
        status.isEmpty || ["Revoked", "Provisioned", "Accepted", "Granted", "Canceled"].contains { status.caseInsensitiveCompare($0) == .orderedSame }
    }
}

public enum ActivationResponseMapper {
    static let authErrorCodes: Set<String> = ["InvalidAuthenticationToken", "ExpiredAuthenticationToken", "AuthenticationFailed"]

    public static func outcome(statusCode: Int, data: Data, requestedAt: Date, hours: Int) -> ActivationOutcome {
        outcome(statusCode: statusCode, data: data, requestedAt: requestedAt, minutes: hours * 60)
    }

    /// PIM's minimum time between activating and deactivating a role.
    public static let minimumActiveTime: TimeInterval = 5 * 60

    /// Maps the answer to `action`'s request. `activeSince` (deactivation):
    /// when the activation started, to say when ending it becomes possible.
    /// `scheduledStart`: the start a scheduled activation asked for.
    public static func outcome(
        for action: RequestAction, statusCode: Int, data: Data, requestedAt: Date, minutes: Int, activeSince: Date? = nil,
        scheduledStart: Date? = nil
    ) -> ActivationOutcome {
        switch action {
        case .activate:
            return outcome(statusCode: statusCode, data: data, requestedAt: requestedAt, minutes: minutes, scheduledStart: scheduledStart)
        case .deactivate:
            if (200..<300).contains(statusCode) {
                let response = try? JSONDecoder().decode(RequestResponse.self, from: data)
                return .deactivated(status: response?.properties?.status ?? "")
            }
            let (code, message) = error(statusCode: statusCode, data: data)
            switch code {
            case "ActiveDurationTooShort":
                return .tooSoon(possibleAt: activeSince.map { $0.addingTimeInterval(minimumActiveTime) })
            case "RoleAssignmentDoesNotExist":
                // PIM also answers this (not ActiveDurationTooShort) in the
                // first five minutes after an activation.
                if let since = activeSince, requestedAt < since.addingTimeInterval(minimumActiveTime) {
                    return .tooSoon(possibleAt: since.addingTimeInterval(minimumActiveTime))
                }
                return .notActive
            default:
                return failure(code: code, message: message)
            }
        case .extend:
            if (200..<300).contains(statusCode) {
                // Only a request: PIM keeps the current schedule until an
                // administrator decides.
                let response = try? JSONDecoder().decode(RequestResponse.self, from: data)
                let status = response?.properties?.status ?? ""
                return .activated(status: status.isEmpty ? "PendingAdminDecision" : status, until: nil)
            }
            let (code, message) = error(statusCode: statusCode, data: data)
            return failure(code: code, message: message)
        }
    }

    static func error(statusCode: Int, data: Data) -> (code: String, message: String) {
        let envelope = try? JSONDecoder().decode(ARMErrorEnvelope.self, from: data)
        let code = envelope?.error?.code ?? "HTTP \(statusCode)"
        let message = envelope?.error?.message ?? envelope?.topLevelMessage
            ?? (data.isEmpty ? HTTPURLResponse.localizedString(forStatusCode: statusCode) : String(decoding: data.prefix(500), as: UTF8.self))
        return (code, message)
    }

    /// The generic mapping of an error code, shared by every request type.
    static func failure(code: String, message: String) -> ActivationOutcome {
        switch code {
        case "RoleAssignmentRequestPolicyValidationFailed":
            return .policyViolation(rules: failedRules(in: message), message: message)
        case _ where authErrorCodes.contains(code):
            return .failed(code: code, message: "Token rejected. Refresh, or sign in again with `az login`. (\(message))")
        case _ where pendingRequestCodes.contains(code):
            return .failed(code: code, message: "A request for this role is already pending; cancel it in the Azure portal (PIM › My requests) or wait. (\(message))")
        default:
            return .failed(code: code, message: message)
        }
    }

    /// Codes PIM uses when another request for the same assignment is open.
    static let pendingRequestCodes: Set<String> = ["RoleAssignmentRequestExistsWithSameAssignmentId", "PendingRoleAssignmentRequest"]

    public static func outcome(statusCode: Int, data: Data, requestedAt: Date, minutes: Int, scheduledStart: Date? = nil) -> ActivationOutcome {
        if (200..<300).contains(statusCode) {
            let response = try? JSONDecoder().decode(RequestResponse.self, from: data)
            let p = response?.properties
            let start = AzureDate.parse(p?.scheduleInfo?.startDateTime) ?? scheduledStart ?? requestedAt
            let until = AzureDate.parse(p?.scheduleInfo?.expiration?.endDateTime)
                ?? start.addingTimeInterval(TimeInterval(minutes) * 60)
            let status = p?.status ?? ""
            // A start in the future: PIM schedules it (`Granted` until then).
            // Requests waiting for approval stay "submitted".
            if start > requestedAt.addingTimeInterval(ScheduleTime.immediateSlack),
               !ScheduledRequest.approvalStatuses.contains(status.lowercased()),
               status.caseInsensitiveCompare("Provisioned") != .orderedSame {
                return .scheduled(status: status.isEmpty ? "Granted" : status, start: start, until: until)
            }
            return .activated(status: status, until: until)
        }
        let (code, message) = error(statusCode: statusCode, data: data)
        if code == "RoleAssignmentExists" { return .alreadyActive }
        return failure(code: code, message: message)
    }

    /// Extracts rule identifiers such as `ExpirationRule`, `JustificationRule`
    /// from the ARM message (`The following policy rules failed: ["ExpirationRule"]`).
    public static func failedRules(in message: String) -> [String] {
        var rules: [String] = []
        var token = ""
        func flush() {
            if token.count > 4, token.hasSuffix("Rule"), token.first?.isUppercase == true, !rules.contains(token) {
                rules.append(token)
            }
            token = ""
        }
        for ch in message {
            if ch.isLetter || ch.isNumber || ch == "_" { token.append(ch) } else { flush() }
        }
        flush()
        return rules
    }

    public static func describe(rule: String) -> String {
        switch rule {
        case "ExpirationRule": "duration exceeds the role's maximum activation time"
        case "JustificationRule": "justification required"
        case "TicketingRule": "a ticket is required: give a ticket number and ticket system"
        case "MfaRule", "AuthenticationContextRule": "MFA or authentication context required (see README)"
        case "ApprovalRule": "approval required"
        case "EnablementRule": "an enablement rule failed (justification/ticket/MFA)"
        default: rule
        }
    }

    private struct RequestResponse: Decodable {
        struct Properties: Decodable {
            struct ScheduleInfo: Decodable {
                struct Expiration: Decodable { let endDateTime: String? }
                let startDateTime: String?
                let expiration: Expiration?
            }

            let status: String?
            let scheduleInfo: ScheduleInfo?
        }

        let properties: Properties?
    }
}
