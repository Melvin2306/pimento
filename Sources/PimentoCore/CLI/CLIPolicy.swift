import Foundation

/// Exit status of the `pimento` command.
public enum CLIExit: Int32, Sendable {
    /// Everything worked (also: nothing to do).
    case success = 0
    /// Something failed: an activation, a request, or you declined the prompt.
    case failure = 1
    /// Bad command line: unknown option, missing justification, no selection,
    /// or `activate` without `--yes` when nobody can answer the prompt.
    case usage = 2
    /// az is missing, not signed in, or ARM rejected the token.
    case auth = 3

    public static func code(for error: Error) -> CLIExit {
        switch error {
        case is CLIParseError, is TenantError, is ConfirmationRequired:
            return .usage
        case let e as PresetError:
            switch e {
            case .ambiguous, .otherTenant, .emptyName, .noRoles: return .usage
            default: return .failure
            }
        case let e as ActivationRequestError:
            return e == .missingPrincipal ? .auth : .usage
        case is AzureCLIError:
            return .auth
        case let e as PIMServiceError:
            switch e {
            case .noIdentity: return .auth
            case .http(let status, let message):
                let tokenError = ActivationResponseMapper.authErrorCodes.contains { message.contains($0) }
                return status == 401 || tokenError ? .auth : .failure
            }
        default:
            return .failure
        }
    }

    /// 0 when nothing failed; 3 when every failure was a rejected token; 1 otherwise.
    public static func code(for outcomes: [ActivationOutcome]) -> CLIExit {
        let failures = outcomes.filter(\.isFailure)
        if failures.isEmpty { return .success }
        return failures.allSatisfy(\.isAuthFailure) ? .auth : .failure
    }
}

/// Thrown when a command that changes roles would have to ask, but stdin is
/// not a terminal.
public struct ConfirmationRequired: Error, LocalizedError, Equatable {
    /// `activate`, `deactivate`, `renew` or `extend`.
    public var command = "activate"

    public init(command: String = "activate") { self.command = command }

    public var errorDescription: String? {
        "Refusing to \(command) without confirmation: stdin is not a terminal. "
            + "Add --yes to \(command) non-interactively, or --dry-run to only print the requests."
    }
}

/// Whether `activate` may send, must ask first, or must refuse.
public enum ConfirmationPolicy: Equatable, Sendable {
    case proceed
    case ask
    case refuse

    public static func decide(dryRun: Bool, assumeYes: Bool, interactive: Bool) -> ConfirmationPolicy {
        if dryRun || assumeYes { return .proceed }
        return interactive ? .ask : .refuse
    }

    /// `y` or `yes`, any case. Everything else (including no answer) is a no.
    public static func isYes(_ answer: String?) -> Bool {
        guard let a = answer?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else { return false }
        return a == "y" || a == "yes"
    }
}
