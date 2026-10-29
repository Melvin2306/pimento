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

    public var isFailure: Bool {
        switch self {
        case .policyViolation, .failed: true
        default: false
        }
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
        }
    }
}

public enum ActivationResponseMapper {
    static let authErrorCodes: Set<String> = ["InvalidAuthenticationToken", "ExpiredAuthenticationToken", "AuthenticationFailed"]

    public static func outcome(statusCode: Int, data: Data, requestedAt: Date, hours: Int) -> ActivationOutcome {
        outcome(statusCode: statusCode, data: data, requestedAt: requestedAt, minutes: hours * 60)
    }

    public static func outcome(statusCode: Int, data: Data, requestedAt: Date, minutes: Int) -> ActivationOutcome {
        if (200..<300).contains(statusCode) {
            let response = try? JSONDecoder().decode(RequestResponse.self, from: data)
            let p = response?.properties
            let start = AzureDate.parse(p?.scheduleInfo?.startDateTime) ?? requestedAt
            let until = AzureDate.parse(p?.scheduleInfo?.expiration?.endDateTime)
                ?? start.addingTimeInterval(TimeInterval(minutes) * 60)
            return .activated(status: p?.status ?? "", until: until)
        }
        let envelope = try? JSONDecoder().decode(ARMErrorEnvelope.self, from: data)
        let code = envelope?.error?.code ?? "HTTP \(statusCode)"
        let message = envelope?.error?.message
            ?? (data.isEmpty ? HTTPURLResponse.localizedString(forStatusCode: statusCode) : String(decoding: data.prefix(500), as: UTF8.self))
        switch code {
        case "RoleAssignmentExists":
            return .alreadyActive
        case "RoleAssignmentRequestPolicyValidationFailed":
            return .policyViolation(rules: failedRules(in: message), message: message)
        case _ where authErrorCodes.contains(code):
            return .failed(code: code, message: "Token rejected. Refresh, or sign in again with `az login`. (\(message))")
        default:
            return .failed(code: code, message: message)
        }
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
        case "TicketingRule": "ticket information required"
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
