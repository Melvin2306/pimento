import Foundation

/// Which roles a `list` / `activate` call is about.
public struct RoleCriteria: Equatable, Sendable {
    public enum State: String, Equatable, Sendable {
        case any, active, eligible
    }

    /// Resource filters, OR-ed. A filter starting with `/` matches that ARM scope
    /// and everything below it; anything else is a case-insensitive substring
    /// of the resource name.
    public var filters: [String] = []
    /// Role names, OR-ed. Matched case-insensitively and exactly, so `owner`
    /// does not also pick "Storage Blob Data Owner"; `*` is a wildcard.
    public var roles: [String] = []
    public var state: State = .any

    public init(filters: [String] = [], roles: [String] = [], state: State = .any) {
        self.filters = filters
        self.roles = roles
        self.state = state
    }

    /// True when the caller named something to narrow the roles down.
    public var hasSelection: Bool { !filters.isEmpty || !roles.isEmpty }

    public func matches(_ role: EligibleRole) -> Bool {
        switch state {
        case .any: break
        case .active: guard role.isActive else { return false }
        case .eligible: guard !role.isActive else { return false }
        }
        if !roles.isEmpty, !roles.contains(where: { Self.glob($0, matches: role.roleName) }) { return false }
        if !filters.isEmpty, !filters.contains(where: { Self.filter($0, matches: role) }) { return false }
        return true
    }

    public func apply(_ roles: [EligibleRole]) -> [EligibleRole] { roles.filter(matches) }

    /// Filters and `--role` for an admin-assigned assignment (always active).
    public func matches(_ assignment: ActiveAssignment) -> Bool {
        if state == .eligible { return false }
        return matches(assignment.asRole)
    }

    static func filter(_ filter: String, matches role: EligibleRole) -> Bool {
        if filter.hasPrefix("/") {
            let wanted = RoleMatcher.key(scope: filter, roleDefinitionId: "").scope
            let scope = RoleMatcher.key(scope: role.scope, roleDefinitionId: "").scope
            return scope == wanted || scope.hasPrefix(wanted + "/")
        }
        return role.scopeName.localizedCaseInsensitiveContains(filter)
    }

    /// Case-insensitive match of the whole name; `*` matches any run of characters.
    static func glob(_ pattern: String, matches name: String) -> Bool {
        let p = Array(pattern.lowercased()), n = Array(name.lowercased())
        var pi = 0, ni = 0, star = -1, mark = 0
        while ni < n.count {
            if pi < p.count, p[pi] != "*", p[pi] == n[ni] {
                pi += 1; ni += 1
            } else if pi < p.count, p[pi] == "*" {
                star = pi; mark = ni; pi += 1
            } else if star >= 0 {
                pi = star + 1; mark += 1; ni = mark
            } else {
                return false
            }
        }
        while pi < p.count, p[pi] == "*" { pi += 1 }
        return pi == p.count
    }
}

public struct ListOptions: Equatable, Sendable {
    public var tenant: String?
    public var json = false
    public var criteria = RoleCriteria()
    public init() {}
}

public struct ActivateOptions: Equatable, Sendable {
    public static let maxParallelRange = 1...16

    public var tenant: String?
    public var json = false
    public var criteria = RoleCriteria()
    /// Every eligible role (still narrowed by filters and `--role`).
    public var all = false
    /// A saved preset instead of filters / `--role` / `--all`.
    public var preset: String?
    /// Empty: the preset's justification, if it has one.
    public var justification = ""
    /// nil: the preset's duration, else the default (8 hours).
    public var duration: RequestedDuration?
    public var assumeYes = false
    public var dryRun = false
    public var maxParallel = 8
    /// `--at`: when the activations start (see `ScheduleTime`); nil = now.
    /// Read when the command runs, against its clock and time zone.
    public var at: String?
    /// `--ticket` / `--ticket-system`.
    public var ticketNumber: String?
    /// nil: the preset's ticket system, if any.
    public var ticketSystem: String?
    public init() {}
}

/// `pimento scheduled`: your pending activation requests.
public struct ScheduledOptions: Equatable, Sendable {
    public var tenant: String?
    public var json = false
    public init() {}
}

/// `pimento cancel`: cancel pending activation requests.
public struct CancelOptions: Equatable, Sendable {
    public var tenant: String?
    public var json = false
    /// Request ids (or their first characters) and resource filters.
    public var targets: [String] = []
    public var roles: [String] = []
    public var all = false
    public var assumeYes = false
    public var dryRun = false
    public init() {}

    public var hasSelection: Bool { !targets.isEmpty || !roles.isEmpty || all }
}

/// `pimento pending`: your requests waiting for approval.
public struct PendingOptions: Equatable, Sendable {
    public var tenant: String?
    public var json = false
    public init() {}
}

/// `pimento wait`: wait until requests are decided.
public struct WaitOptions: Equatable, Sendable {
    public static let defaultTimeout: TimeInterval = 30 * 60
    public static let timeoutRange: ClosedRange<TimeInterval> = 1...(24 * 3600)
    /// How often `wait` reads your requests.
    public static let pollInterval: TimeInterval = 30

    public var tenant: String?
    public var json = false
    /// Request ids (or their first characters).
    public var targets: [String] = []
    /// Every request of yours that waits for approval.
    public var all = false
    public var timeout = WaitOptions.defaultTimeout
    public init() {}
}

/// `pimento approvals`: requests you may decide.
public struct ApprovalsOptions: Equatable, Sendable {
    public var tenant: String?
    public var json = false
    public init() {}
}

/// `pimento approve` / `pimento deny`.
public struct DecideOptions: Equatable, Sendable {
    public var decision: ApprovalDecision = .approve
    public var tenant: String?
    public var json = false
    /// Request ids (or their first characters, at least 4).
    public var targets: [String] = []
    public var justification = ""
    public var assumeYes = false
    public var dryRun = false
    public init(decision: ApprovalDecision = .approve) { self.decision = decision }
}

/// `pimento deactivate` and `pimento renew`: act on active roles.
public struct LifecycleOptions: Equatable, Sendable {
    public var tenant: String?
    public var json = false
    public var criteria = RoleCriteria(state: .active)
    /// Every active role (filters and `--role` still narrow it).
    public var all = false
    public var preset: String?
    /// Deactivate: optional (a default is sent). Renew: required unless the preset has one.
    public var justification = ""
    /// Renew only: nil = the preset's duration, else the default (8 hours).
    public var duration: RequestedDuration?
    /// Renew only: `--ticket` / `--ticket-system`, for roles whose policy
    /// requires a ticket (default: the original activation's ticket).
    public var ticketNumber: String?
    public var ticketSystem: String?
    public var assumeYes = false
    public var dryRun = false
    public var maxParallel = 8
    public init() {}
}

/// `pimento extend`: ask an administrator to extend time-bound assignments.
public struct ExtendOptions: Equatable, Sendable {
    public var tenant: String?
    public var json = false
    public var criteria = RoleCriteria(state: .active)
    public var all = false
    public var justification = ""
    public var days = ExtendOptionsRange.defaultDays
    public var assumeYes = false
    public var dryRun = false
    public init() {}
}

/// `pimento presets …`.
public enum PresetsCommand: Equatable, Sendable {
    case list(PresetListOptions)
    case show(PresetShowOptions)
    case save(PresetSaveOptions)
    case delete(PresetShowOptions)

    public static let names = ["list", "show", "save", "delete"]
}

public struct PresetListOptions: Equatable, Sendable {
    /// Only presets of this tenant (and presets for any tenant).
    public var tenant: String?
    public var json = false
    public init() {}
}

public struct PresetShowOptions: Equatable, Sendable {
    public var name = ""
    public var tenant: String?
    public var json = false
    public init() {}
}

public struct PresetSaveOptions: Equatable, Sendable {
    public var name = ""
    public var tenant: String?
    public var json = false
    public var criteria = RoleCriteria()
    /// Store the roles that match now, instead of the filters as a rule.
    public var exact = false
    public var justification: String?
    public var duration: RequestedDuration?
    public var ticketSystem: String?
    /// Replace a preset of the same name.
    public var force = false
    public init() {}
}

/// `pimento history …`: the local log of what Pimento sent.
public enum HistoryCommand: Equatable, Sendable {
    case list(HistoryListOptions)
    /// `history export FILE.csv` (FILE `-`: stdout).
    case export(file: String, HistoryListOptions)
    case importAzure(HistoryImportOptions)
    case clear(assumeYes: Bool)

    public static let names = ["export", "import-azure", "clear"]
}

/// Which records `pimento history` shows (and `history export` writes).
public struct HistoryListOptions: Equatable, Sendable {
    /// `7d`, `24h`, `2026-10-01`, … (see `HistoryDate`); read when the command runs.
    public var since: String?
    public var until: String?
    public var actions: [HistoryAction] = []
    public var results: [HistoryResult] = []
    /// A tenant GUID or part of its name (a filter here, not the tenant to sign in to).
    public var tenant: String?
    /// Words that must all appear in the record.
    public var text: [String] = []
    public var limit: Int?
    public var json = false
    public var csv = false
    public init() {}
}

/// `pimento history import-azure`.
public struct HistoryImportOptions: Equatable, Sendable {
    /// The tenant to read from (as everywhere else).
    public var tenant: String?
    public var since: String?
    public var json = false
    public init() {}
}

public struct StatusOptions: Equatable, Sendable {
    public var tenant: String?
    public var json = false
    public init() {}
}

public struct TenantsOptions: Equatable, Sendable {
    /// Whose token lists the tenants (ARM's `GET /tenants`); az's default otherwise.
    public var tenant: String?
    public var json = false
    public init() {}
}

/// `pimento login`: Pimento's own sign-in (browser, or a device code).
public struct LoginOptions: Equatable, Sendable {
    /// The tenant to sign in to (default: `organizations`, your home tenant).
    public var tenant: String?
    public var clientId: String?
    public var deviceCode = false
    public var json = false
    public init() {}
}

/// `pimento logout`: forget the signed-in account (or all of them).
public struct LogoutOptions: Equatable, Sendable {
    public var all = false
    public var json = false
    public init() {}
}

/// `pimento whoami`: who the current auth source signs in as.
public struct WhoamiOptions: Equatable, Sendable {
    public var tenant: String?
    public var json = false
    public init() {}
}

/// `pimento version`: the version; with `--check`, also the latest release
/// (the only command that contacts GitHub).
public struct VersionOptions: Equatable, Sendable {
    public var check = false
    public var json = false
    public init(check: Bool = false, json: Bool = false) {
        self.check = check
        self.json = json
    }
}

public enum CompletionShell: String, CaseIterable, Sendable {
    case zsh, bash, fish
}

public enum CLICommand: Equatable, Sendable {
    case help(topic: String?)
    case version(VersionOptions)
    case list(ListOptions)
    case activate(ActivateOptions)
    case deactivate(LifecycleOptions)
    case renew(LifecycleOptions)
    case extend(ExtendOptions)
    case scheduled(ScheduledOptions)
    case cancel(CancelOptions)
    case pending(PendingOptions)
    case wait(WaitOptions)
    case approvals(ApprovalsOptions)
    case approve(DecideOptions)
    case deny(DecideOptions)
    case status(StatusOptions)
    case tenants(TenantsOptions)
    case presets(PresetsCommand)
    case history(HistoryCommand)
    case completions(CompletionShell)
    case login(LoginOptions)
    case logout(LogoutOptions)
    case whoami(WhoamiOptions)

    /// Whether the command needs an access token (and so the auth source).
    /// The others work offline, also with a broken `--auth` / $PIMENTO_AUTH:
    /// help, presets, the local history, and `logout`, the way out.
    public var needsAzure: Bool {
        switch self {
        case .help, .version, .completions, .logout: false
        case .presets(let p): if case .save = p { true } else { false }
        case .history(let h): if case .importAzure = h { true } else { false }
        default: true
        }
    }

    public static let names = [
        "list", "activate", "deactivate", "renew", "extend", "scheduled", "cancel", "pending", "wait", "approvals", "approve",
        "deny", "status", "tenants", "presets", "history", "login", "logout", "whoami", "completions", "version", "help",
    ]
}

/// A parsed command line, plus a note when it used a deprecated spelling.
public struct CLIInvocation: Equatable, Sendable {
    public var command: CLICommand
    public var deprecation: String?
    /// `--auth az|pimento`, accepted by every command (validated when resolved).
    public var auth: String?
    /// `--demo`, accepted by every command: run against the demo simulator.
    public var demo = false

    public init(_ command: CLICommand, deprecation: String? = nil, auth: String? = nil, demo: Bool = false) {
        self.command = command
        self.deprecation = deprecation
        self.auth = auth
        self.demo = demo
    }
}

public enum CLIParseError: Error, Equatable, LocalizedError {
    case unknownCommand(String)
    case expectedCommand(String)
    case unknownOption(String, command: String)
    case unexpectedArgument(String, command: String)
    case missingValue(String)
    case valueNotAllowed(String)
    case invalidNumber(flag: String, value: String)
    case invalidHours(String)
    case missingPresetName(String)
    case unknownPresetCommand(String)
    case outOfRange(flag: String, value: Int, range: ClosedRange<Int>)
    case conflicting(String, String)
    case missingJustification
    case missingJustificationFor(String)
    case noSelection
    case noActiveSelection(String)
    case missingShell
    case unknownShell(String)
    case invalidStart(String)
    case missingTicket(roles: [String])
    case noCancelSelection
    case ambiguousRequestId(String, matches: Int)
    case noWaitSelection
    case invalidTimeout(String)
    case noDecisionSelection(String)
    case notARequestId(String)
    case fullRequestIdRequired(String, command: String)
    case invalidDate(flag: String, value: String)
    case unknownAction(String)
    case unknownOutcome(String)
    case missingExportFile
    case clearNeedsConfirmation
    case invalidClientId(String)
    case ticketSystemWithoutTicket
    case emptyFilter(String)

    public var errorDescription: String? {
        switch self {
        case .unknownCommand(let c): "Unknown command “\(c)”. Run `pimento help` for the list of commands."
        case .expectedCommand(let o): "Expected a command before \(o), e.g. `pimento list \(o) …`. Run `pimento help`."
        case .unknownOption(let o, let c): "Unknown option \(o) for `pimento \(c)`. Run `pimento help \(c)`."
        case .unexpectedArgument(let a, let c): "`pimento \(c)` takes no argument “\(a)”."
        case .missingValue(let flag): "\(flag) needs a value."
        case .valueNotAllowed(let flag): "\(flag) takes no value."
        case .invalidNumber(let flag, let value): "\(flag) needs a whole number, got “\(value)”."
        case .invalidHours(let value):
            "--hours takes 1-\(ActivationRequestBuilder.maxHours) or max (the longest each role's policy allows), got “\(value)”."
        case .missingPresetName(let c): "`pimento presets \(c)` needs a preset name."
        case .unknownPresetCommand(let c): "Unknown presets command “\(c)”. Use list, show, save or delete."
        case .outOfRange(let flag, let value, let range):
            "\(flag) must be between \(range.lowerBound) and \(range.upperBound), got \(value)."
        case .conflicting(let a, let b): "Use either \(a) or \(b), not both."
        case .missingJustification: "activate needs a justification: -j \"TEXT\"."
        case .missingJustificationFor(let c): "\(c) needs a justification: -j \"TEXT\"."
        case .noActiveSelection(let c):
            "Say which active roles to \(c): resource filters, --role NAME\(c == "extend" ? "" : ", --preset NAME"), or --all."
        case .noSelection:
            "Say which roles to activate: resource filters, --role NAME, --preset NAME, or --all for every eligible role."
        case .missingShell: "Name a shell: pimento completions zsh|bash|fish."
        case .unknownShell(let s): "No completions for “\(s)”. Use zsh, bash or fish."
        case .invalidStart(let message): "--at: \(message)"
        case .missingTicket(let roles):
            "\(roles.count == 1 ? "This role needs" : "These roles need") a ticket (its PIM policy requires one): "
                + roles.joined(separator: "; ") + ". Add --ticket NUMBER --ticket-system NAME."
        case .noCancelSelection:
            "Say which requests to cancel: request ids (see `pimento scheduled`), resource filters, --role NAME, or --all."
        case .ambiguousRequestId(let id, let n): "“\(id)” matches \(n) requests; give more of the id."
        case .noWaitSelection: "Say which requests to wait for: request ids (see `pimento pending`) or --all."
        case .invalidTimeout(let v):
            "--timeout takes a duration up to 24h such as 30m, 2h, 1h30m or 90s (a plain number is minutes), got “\(v)”."
        case .noDecisionSelection(let c): "Say which requests to \(c): request ids from `pimento approvals`."
        case .notARequestId(let v): "“\(v)” is not a request id (at least 4 characters of hex digits and dashes)."
        case .fullRequestIdRequired(let v, let c):
            "With --yes, `pimento \(c)` takes only full request ids (36 characters, as `pimento approvals` shows them), "
                + "got “\(v)”. Without --yes Pimento shows the matching request and asks first."
        case .invalidDate(let flag, let v):
            "\(flag) takes 7d, 24h, 30m, 2w, today, yesterday, a date (2026-10-01), a date and time (2026-10-01 08:00) "
                + "or ISO 8601, got “\(v)”."
        case .unknownAction(let v):
            "Unknown action “\(v)”. Use \(HistoryAction.known.map(\.rawValue).joined(separator: ", "))."
        case .unknownOutcome(let v):
            "Unknown outcome “\(v)”. Use \(HistoryResult.known.map(\.rawValue).joined(separator: ", "))."
        case .missingExportFile: "`pimento history export` needs a file name (FILE.csv, or - for stdout)."
        case .invalidClientId(let v):
            "--client-id takes the Application (client) ID GUID of your app registration, got “\(v)”."
        case .emptyFilter(let what):
            "An empty \(what) (only spaces) would match every name; give a resource name, --role NAME or --all."
        case .ticketSystemWithoutTicket:
            "--ticket-system goes with --ticket NUMBER (--ticket NUMBER --ticket-system NAME)."
        case .clearNeedsConfirmation:
            "Refusing to clear the history without confirmation: stdin is not a terminal. Add --yes."
        }
    }
}

/// `--timeout` of `pimento wait`: `30m`, `2h`, `1h30m`, `90s`, `1d`; a plain number is minutes.
public enum WaitTimeout {
    public static func parse(_ raw: String) -> TimeInterval? {
        let s = raw.trimmingCharacters(in: .whitespaces).lowercased()
        guard !s.isEmpty else { return nil }
        // In floating point: a huge number must be refused, not trap on overflow.
        if let minutes = Int(s) { return minutes > 0 ? TimeInterval(minutes) * 60 : nil }
        var total: TimeInterval = 0
        var number = ""
        var sawUnit = false
        for ch in s {
            if ch.isNumber { number.append(ch); continue }
            guard let n = Int(number), n >= 0 else { return nil }
            switch ch {
            case "d": total += TimeInterval(n) * 86400
            case "h": total += TimeInterval(n) * 3600
            case "m": total += TimeInterval(n) * 60
            case "s": total += TimeInterval(n)
            default: return nil
            }
            number = ""
            sawUnit = true
        }
        guard number.isEmpty, sawUnit, total > 0 else { return nil }
        return total
    }

    /// `30m`, `1h 30m`, `45s`.
    public static func label(_ t: TimeInterval) -> String {
        let s = Int(t.rounded())
        if s < 60 { return "\(s)s" }
        if s % 3600 == 0 { return "\(s / 3600)h" }
        if s < 3600 { return s % 60 == 0 ? "\(s / 60)m" : "\(s / 60)m \(s % 60)s" }
        return "\(s / 3600)h \((s % 3600) / 60)m"
    }
}

/// Hand-written subcommand parser: `pimento <command> [options] [filters]`.
public enum CLIParser {
    /// Resource filters and `--role` names, trimmed. One that is empty after
    /// trimming is refused: `" "` would be a substring of most names.
    static func terms(_ values: [String], _ what: String) throws -> [String] {
        try values.map { raw in
            let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { throw CLIParseError.emptyFilter(what) }
            return value
        }
    }

    private struct Flag {
        let key: String
        let takesValue: Bool
    }

    private static let tenant = ["--tenant": Flag(key: "tenant", takesValue: true), "-t": Flag(key: "tenant", takesValue: true)]
    private static let json = ["--json": Flag(key: "json", takesValue: false)]

    private static let listFlags = tenant.merging(json) { a, _ in a }.merging([
        "--active": Flag(key: "active", takesValue: false),
        "--eligible": Flag(key: "eligible", takesValue: false),
        "--role": Flag(key: "role", takesValue: true),
    ]) { a, _ in a }

    private static let activateFlags = tenant.merging(json) { a, _ in a }.merging([
        "--role": Flag(key: "role", takesValue: true),
        "--all": Flag(key: "all", takesValue: false),
        "--justification": Flag(key: "justification", takesValue: true),
        "-j": Flag(key: "justification", takesValue: true),
        "--hours": Flag(key: "hours", takesValue: true),
        "--yes": Flag(key: "yes", takesValue: false),
        "-y": Flag(key: "yes", takesValue: false),
        "--dry-run": Flag(key: "dry-run", takesValue: false),
        "--max-parallel": Flag(key: "max-parallel", takesValue: true),
        "--preset": Flag(key: "preset", takesValue: true),
        "--at": Flag(key: "at", takesValue: true),
        "--ticket": Flag(key: "ticket", takesValue: true),
        "--ticket-system": Flag(key: "ticket-system", takesValue: true),
    ]) { a, _ in a }

    private static let cancelFlags = tenant.merging(json) { a, _ in a }.merging([
        "--role": Flag(key: "role", takesValue: true),
        "--all": Flag(key: "all", takesValue: false),
        "--yes": Flag(key: "yes", takesValue: false),
        "-y": Flag(key: "yes", takesValue: false),
        "--dry-run": Flag(key: "dry-run", takesValue: false),
    ]) { a, _ in a }

    private static let deactivateFlags = tenant.merging(json) { a, _ in a }.merging([
        "--role": Flag(key: "role", takesValue: true),
        "--all": Flag(key: "all", takesValue: false),
        "--justification": Flag(key: "justification", takesValue: true),
        "-j": Flag(key: "justification", takesValue: true),
        "--yes": Flag(key: "yes", takesValue: false),
        "-y": Flag(key: "yes", takesValue: false),
        "--dry-run": Flag(key: "dry-run", takesValue: false),
        "--max-parallel": Flag(key: "max-parallel", takesValue: true),
        "--preset": Flag(key: "preset", takesValue: true),
    ]) { a, _ in a }

    private static let renewFlags = deactivateFlags.merging([
        "--hours": Flag(key: "hours", takesValue: true),
        "--ticket": Flag(key: "ticket", takesValue: true),
        "--ticket-system": Flag(key: "ticket-system", takesValue: true),
    ]) { a, _ in a }

    private static let extendFlags = tenant.merging(json) { a, _ in a }.merging([
        "--role": Flag(key: "role", takesValue: true),
        "--all": Flag(key: "all", takesValue: false),
        "--justification": Flag(key: "justification", takesValue: true),
        "-j": Flag(key: "justification", takesValue: true),
        "--days": Flag(key: "days", takesValue: true),
        "--yes": Flag(key: "yes", takesValue: false),
        "-y": Flag(key: "yes", takesValue: false),
        "--dry-run": Flag(key: "dry-run", takesValue: false),
    ]) { a, _ in a }

    private static let presetSaveFlags = tenant.merging(json) { a, _ in a }.merging([
        "--role": Flag(key: "role", takesValue: true),
        "--exact": Flag(key: "exact", takesValue: false),
        "--justification": Flag(key: "justification", takesValue: true),
        "-j": Flag(key: "justification", takesValue: true),
        "--hours": Flag(key: "hours", takesValue: true),
        "--ticket-system": Flag(key: "ticket-system", takesValue: true),
        "--force": Flag(key: "force", takesValue: false),
        "-f": Flag(key: "force", takesValue: false),
    ]) { a, _ in a }

    private static let plainFlags = tenant.merging(json) { a, _ in a }
    private static let versionFlags = json.merging(["--check": Flag(key: "check", takesValue: false)]) { a, _ in a }

    private static let loginFlags = tenant.merging(json) { a, _ in a }.merging([
        "--client-id": Flag(key: "client-id", takesValue: true),
        "--device-code": Flag(key: "device-code", takesValue: false),
    ]) { a, _ in a }

    private static let logoutFlags = json.merging([
        "--all": Flag(key: "all", takesValue: false),
    ]) { a, _ in a }

    private static let historyFlags = tenant.merging(json) { a, _ in a }.merging([
        "--since": Flag(key: "since", takesValue: true),
        "--until": Flag(key: "until", takesValue: true),
        "--action": Flag(key: "action", takesValue: true),
        "--outcome": Flag(key: "outcome", takesValue: true),
        "--limit": Flag(key: "limit", takesValue: true),
        "-n": Flag(key: "limit", takesValue: true),
        "--csv": Flag(key: "csv", takesValue: false),
    ]) { a, _ in a }

    private static let historyImportFlags = tenant.merging(json) { a, _ in a }.merging([
        "--since": Flag(key: "since", takesValue: true),
    ]) { a, _ in a }

    private static let historyClearFlags = [
        "--yes": Flag(key: "yes", takesValue: false),
        "-y": Flag(key: "yes", takesValue: false),
    ]

    private static let waitFlags = tenant.merging(json) { a, _ in a }.merging([
        "--all": Flag(key: "all", takesValue: false),
        "--timeout": Flag(key: "timeout", takesValue: true),
    ]) { a, _ in a }

    private static let decideFlags = tenant.merging(json) { a, _ in a }.merging([
        "--justification": Flag(key: "justification", takesValue: true),
        "-j": Flag(key: "justification", takesValue: true),
        "--yes": Flag(key: "yes", takesValue: false),
        "-y": Flag(key: "yes", takesValue: false),
        "--dry-run": Flag(key: "dry-run", takesValue: false),
    ]) { a, _ in a }

    /// The read-only flags of 0.1.0 (`pimento --list`), still accepted for one release.
    static let legacyModes = ["--list": "list", "--dry-run": "activate --dry-run", "--tenants": "tenants"]

    public static func parse(_ args: [String]) throws -> CLIInvocation {
        let (withoutDemo, demo) = extractDemo(args)
        let (rest, auth) = try extractAuth(withoutDemo)
        var invocation = try parseCommand(rest)
        invocation.auth = auth
        invocation.demo = demo
        return invocation
    }

    /// Removes `--demo` (before `--`) from anywhere in the line.
    static func extractDemo(_ args: [String]) -> ([String], Bool) {
        let end = args.firstIndex(of: "--") ?? args.endIndex
        let head = args[..<end]
        guard head.contains(DemoMode.argument) else { return (args, false) }
        return (head.filter { $0 != DemoMode.argument } + args[end...], true)
    }

    /// Removes `--auth VALUE` / `--auth=VALUE` (before `--`) from anywhere in the line.
    static func extractAuth(_ args: [String]) throws -> ([String], String?) {
        var rest: [String] = []
        var auth: String?
        var i = 0
        while i < args.count {
            let arg = args[i]
            if arg == "--" {
                rest += args[i...]
                break
            }
            if arg == "--auth" {
                guard i + 1 < args.count, !args[i + 1].hasPrefix("-") else { throw CLIParseError.missingValue("--auth") }
                auth = args[i + 1]
                i += 2
                continue
            }
            if arg.hasPrefix("--auth=") {
                let value = String(arg.dropFirst("--auth=".count))
                guard !value.isEmpty else { throw CLIParseError.missingValue("--auth") }
                auth = value
                i += 1
                continue
            }
            rest.append(arg)
            i += 1
        }
        return (rest, auth)
    }

    static func parseCommand(_ args: [String]) throws -> CLIInvocation {
        guard let first = args.first else { return CLIInvocation(.help(topic: nil)) }
        // `--help` / `-h` first take a topic like `help` (`pimento --help wait`);
        // elsewhere on a 0.1-style line they still mean help.
        if !CLICommand.names.contains(first), first != "--help", first != "-h", first != "--version", let legacy = try parseLegacy(args) { return legacy }
        let rest = Array(args.dropFirst())
        switch first {
        case "help", "--help", "-h":
            guard let topic = rest.first else { return CLIInvocation(.help(topic: nil)) }
            guard CLICommand.names.contains(topic) else { throw CLIParseError.unknownCommand(topic) }
            return CLIInvocation(.help(topic: topic))
        case "version", "--version":
            let scan = try scan(rest, command: "version", flags: versionFlags, positionals: false)
            if scan.help { return CLIInvocation(.help(topic: "version")) }
            return CLIInvocation(.version(VersionOptions(check: scan.values["check"] != nil, json: scan.values["json"] != nil)))
        case "list": return try CLIInvocation(parseList(rest))
        case "activate": return try CLIInvocation(parseActivate(rest))
        case "deactivate", "renew": return try CLIInvocation(parseLifecycle(rest, command: first))
        case "extend": return try CLIInvocation(parseExtend(rest))
        case "scheduled":
            let scan = try scan(rest, command: first, flags: plainFlags, positionals: false)
            if scan.help { return CLIInvocation(.help(topic: first)) }
            var o = ScheduledOptions()
            o.tenant = scan.values["tenant"]?.last
            o.json = scan.values["json"] != nil
            return CLIInvocation(.scheduled(o))
        case "cancel": return try CLIInvocation(parseCancel(rest))
        case "pending", "approvals":
            let scan = try scan(rest, command: first, flags: plainFlags, positionals: false)
            if scan.help { return CLIInvocation(.help(topic: first)) }
            let tenant = scan.values["tenant"]?.last, json = scan.values["json"] != nil
            if first == "pending" {
                var o = PendingOptions()
                o.tenant = tenant
                o.json = json
                return CLIInvocation(.pending(o))
            }
            var o = ApprovalsOptions()
            o.tenant = tenant
            o.json = json
            return CLIInvocation(.approvals(o))
        case "wait": return try CLIInvocation(parseWait(rest))
        case "approve", "deny": return try CLIInvocation(parseDecide(rest, command: first))
        case "status":
            let scan = try scan(rest, command: first, flags: plainFlags, positionals: false)
            if scan.help { return CLIInvocation(.help(topic: first)) }
            var o = StatusOptions()
            o.tenant = scan.values["tenant"]?.last
            o.json = scan.values["json"] != nil
            return CLIInvocation(.status(o))
        case "tenants":
            let scan = try scan(rest, command: first, flags: plainFlags, positionals: false)
            if scan.help { return CLIInvocation(.help(topic: first)) }
            var o = TenantsOptions()
            o.tenant = scan.values["tenant"]?.last
            o.json = scan.values["json"] != nil
            return CLIInvocation(.tenants(o))
        case "presets": return try CLIInvocation(parsePresets(rest))
        case "history": return try CLIInvocation(parseHistory(rest))
        case "login":
            let scan = try scan(rest, command: first, flags: loginFlags, positionals: false)
            if scan.help { return CLIInvocation(.help(topic: first)) }
            var o = LoginOptions()
            o.tenant = scan.values["tenant"]?.last
            o.clientId = scan.values["client-id"]?.last?.trimmingCharacters(in: .whitespaces)
            o.deviceCode = scan.values["device-code"] != nil
            o.json = scan.values["json"] != nil
            if let id = o.clientId, !MicrosoftIdentity.isValidClientId(id) { throw CLIParseError.invalidClientId(id) }
            return CLIInvocation(.login(o))
        case "logout":
            let scan = try scan(rest, command: first, flags: logoutFlags, positionals: false)
            if scan.help { return CLIInvocation(.help(topic: first)) }
            var o = LogoutOptions()
            o.all = scan.values["all"] != nil
            o.json = scan.values["json"] != nil
            return CLIInvocation(.logout(o))
        case "whoami":
            let scan = try scan(rest, command: first, flags: plainFlags, positionals: false)
            if scan.help { return CLIInvocation(.help(topic: first)) }
            var o = WhoamiOptions()
            o.tenant = scan.values["tenant"]?.last
            o.json = scan.values["json"] != nil
            return CLIInvocation(.whoami(o))
        case "completions":
            if rest.contains("--help") || rest.contains("-h") { return CLIInvocation(.help(topic: first)) }
            guard let name = rest.first else { throw CLIParseError.missingShell }
            guard let shell = CompletionShell(rawValue: name) else { throw CLIParseError.unknownShell(name) }
            if rest.count > 1 { throw CLIParseError.unexpectedArgument(rest[1], command: first) }
            return CLIInvocation(.completions(shell))
        default:
            if first.hasPrefix("-") { throw CLIParseError.expectedCommand(first) }
            throw CLIParseError.unknownCommand(first)
        }
    }

    static func parseList(_ args: [String]) throws -> CLICommand {
        let scan = try scan(args, command: "list", flags: listFlags, positionals: true)
        if scan.help { return .help(topic: "list") }
        var o = ListOptions()
        o.tenant = scan.values["tenant"]?.last
        o.json = scan.values["json"] != nil
        o.criteria.filters = try terms(scan.positionals, "filter")
        o.criteria.roles = try terms(scan.values["role"] ?? [], "--role")
        switch (scan.values["active"] != nil, scan.values["eligible"] != nil) {
        case (true, true): throw CLIParseError.conflicting("--active", "--eligible")
        case (true, false): o.criteria.state = .active
        case (false, true): o.criteria.state = .eligible
        case (false, false): break
        }
        return .list(o)
    }

    static func parseActivate(_ args: [String]) throws -> CLICommand {
        let scan = try scan(args, command: "activate", flags: activateFlags, positionals: true)
        if scan.help { return .help(topic: "activate") }
        var o = ActivateOptions()
        o.tenant = scan.values["tenant"]?.last
        o.json = scan.values["json"] != nil
        o.criteria.filters = try terms(scan.positionals, "filter")
        o.criteria.roles = try terms(scan.values["role"] ?? [], "--role")
        o.all = scan.values["all"] != nil
        o.assumeYes = scan.values["yes"] != nil
        o.dryRun = scan.values["dry-run"] != nil
        o.preset = scan.values["preset"]?.last?.trimmingCharacters(in: .whitespaces)
        o.justification = (scan.values["justification"]?.last ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if let raw = scan.values["hours"]?.last { o.duration = try hours(raw) }
        if let raw = scan.values["max-parallel"]?.last {
            o.maxParallel = try number(raw, flag: "--max-parallel", range: ActivateOptions.maxParallelRange)
        }
        o.at = scan.values["at"]?.last?.trimmingCharacters(in: .whitespaces)
        o.ticketNumber = scan.values["ticket"]?.last?.trimmingCharacters(in: .whitespaces)
        o.ticketSystem = scan.values["ticket-system"]?.last?.trimmingCharacters(in: .whitespaces)
        // A system alone is no ticket; for renew it would also replace the original ticket.
        if o.ticketSystem != nil, o.ticketNumber == nil { throw CLIParseError.ticketSystemWithoutTicket }
        if o.preset != nil {
            if o.criteria.hasSelection || o.all { throw CLIParseError.conflicting("--preset", "filters, --role or --all") }
            // The justification may come from the preset: checked once it is loaded.
            return .activate(o)
        }
        guard o.criteria.hasSelection || o.all else { throw CLIParseError.noSelection }
        guard !o.justification.isEmpty else { throw CLIParseError.missingJustification }
        return .activate(o)
    }

    /// `deactivate` / `renew`: selection among active roles.
    static func parseLifecycle(_ args: [String], command: String) throws -> CLICommand {
        let renew = command == "renew"
        let scan = try scan(args, command: command, flags: renew ? renewFlags : deactivateFlags, positionals: true)
        if scan.help { return .help(topic: command) }
        var o = LifecycleOptions()
        o.tenant = scan.values["tenant"]?.last
        o.json = scan.values["json"] != nil
        o.criteria.filters = try terms(scan.positionals, "filter")
        o.criteria.roles = try terms(scan.values["role"] ?? [], "--role")
        o.all = scan.values["all"] != nil
        o.assumeYes = scan.values["yes"] != nil
        o.dryRun = scan.values["dry-run"] != nil
        o.preset = scan.values["preset"]?.last?.trimmingCharacters(in: .whitespaces)
        o.justification = (scan.values["justification"]?.last ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if let raw = scan.values["hours"]?.last { o.duration = try hours(raw) }
        if let raw = scan.values["max-parallel"]?.last {
            o.maxParallel = try number(raw, flag: "--max-parallel", range: ActivateOptions.maxParallelRange)
        }
        o.ticketNumber = scan.values["ticket"]?.last?.trimmingCharacters(in: .whitespaces)
        o.ticketSystem = scan.values["ticket-system"]?.last?.trimmingCharacters(in: .whitespaces)
        // A system alone is no ticket; for renew it would also replace the original ticket.
        if o.ticketSystem != nil, o.ticketNumber == nil { throw CLIParseError.ticketSystemWithoutTicket }
        if o.preset != nil {
            if o.criteria.hasSelection || o.all { throw CLIParseError.conflicting("--preset", "filters, --role or --all") }
            return renew ? .renew(o) : .deactivate(o)
        }
        guard o.criteria.hasSelection || o.all else { throw CLIParseError.noActiveSelection(command) }
        if renew {
            guard !o.justification.isEmpty else { throw CLIParseError.missingJustificationFor(command) }
            return .renew(o)
        }
        return .deactivate(o)
    }

    static func parseCancel(_ args: [String]) throws -> CLICommand {
        let scan = try scan(args, command: "cancel", flags: cancelFlags, positionals: true)
        if scan.help { return .help(topic: "cancel") }
        var o = CancelOptions()
        o.tenant = scan.values["tenant"]?.last
        o.json = scan.values["json"] != nil
        o.targets = scan.positionals
        o.roles = try terms(scan.values["role"] ?? [], "--role")
        o.all = scan.values["all"] != nil
        o.assumeYes = scan.values["yes"] != nil
        o.dryRun = scan.values["dry-run"] != nil
        guard o.hasSelection else { throw CLIParseError.noCancelSelection }
        return .cancel(o)
    }

    static func parseWait(_ args: [String]) throws -> CLICommand {
        let scan = try scan(args, command: "wait", flags: waitFlags, positionals: true)
        if scan.help { return .help(topic: "wait") }
        var o = WaitOptions()
        o.tenant = scan.values["tenant"]?.last
        o.json = scan.values["json"] != nil
        o.all = scan.values["all"] != nil
        o.targets = scan.positionals
        if let raw = scan.values["timeout"]?.last {
            guard let t = WaitTimeout.parse(raw), WaitOptions.timeoutRange.contains(t) else { throw CLIParseError.invalidTimeout(raw) }
            o.timeout = t
        }
        if o.all, let first = o.targets.first { throw CLIParseError.conflicting("--all", "request id “\(first)”") }
        guard o.all || !o.targets.isEmpty else { throw CLIParseError.noWaitSelection }
        for t in o.targets where !CancelSelection.isIdLike(t) { throw CLIParseError.notARequestId(t) }
        return .wait(o)
    }

    /// `approve` / `deny`: request ids and a justification.
    static func parseDecide(_ args: [String], command: String) throws -> CLICommand {
        let scan = try scan(args, command: command, flags: decideFlags, positionals: true)
        if scan.help { return .help(topic: command) }
        var o = DecideOptions(decision: command == "deny" ? .deny : .approve)
        o.tenant = scan.values["tenant"]?.last
        o.json = scan.values["json"] != nil
        o.targets = scan.positionals
        o.assumeYes = scan.values["yes"] != nil
        o.dryRun = scan.values["dry-run"] != nil
        o.justification = (scan.values["justification"]?.last ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !o.targets.isEmpty else { throw CLIParseError.noDecisionSelection(command) }
        for t in o.targets where !CancelSelection.isIdLike(t) { throw CLIParseError.notARequestId(t) }
        // A decision sent without a prompt must name the exact request: a
        // prefix is re-resolved against the inbox when the command runs, and
        // the requester chooses the request name (and so its prefix).
        if o.assumeYes && !o.dryRun {
            for t in o.targets where !RequestIdSelection.isFullId(t) { throw CLIParseError.fullRequestIdRequired(t, command: command) }
        }
        guard !o.justification.isEmpty else { throw CLIParseError.missingJustificationFor(command) }
        return command == "deny" ? .deny(o) : .approve(o)
    }

    static func parseExtend(_ args: [String]) throws -> CLICommand {
        let scan = try scan(args, command: "extend", flags: extendFlags, positionals: true)
        if scan.help { return .help(topic: "extend") }
        var o = ExtendOptions()
        o.tenant = scan.values["tenant"]?.last
        o.json = scan.values["json"] != nil
        o.criteria.filters = try terms(scan.positionals, "filter")
        o.criteria.roles = try terms(scan.values["role"] ?? [], "--role")
        o.all = scan.values["all"] != nil
        o.assumeYes = scan.values["yes"] != nil
        o.dryRun = scan.values["dry-run"] != nil
        o.justification = (scan.values["justification"]?.last ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if let raw = scan.values["days"]?.last { o.days = try number(raw, flag: "--days", range: ExtendOptionsRange.days) }
        guard o.criteria.hasSelection || o.all else { throw CLIParseError.noActiveSelection("extend") }
        guard !o.justification.isEmpty else { throw CLIParseError.missingJustificationFor("extend") }
        return .extend(o)
    }

    /// `history [list options]`, `history export FILE`, `history import-azure`, `history clear`.
    static func parseHistory(_ args: [String]) throws -> CLICommand {
        let sub = args.first.flatMap { HistoryCommand.names.contains($0) ? $0 : nil }
        let rest = sub == nil ? args : Array(args.dropFirst())
        switch sub {
        case "import-azure":
            let scan = try scan(rest, command: "history import-azure", flags: historyImportFlags, positionals: false)
            if scan.help { return .help(topic: "history") }
            var o = HistoryImportOptions()
            o.tenant = scan.values["tenant"]?.last
            o.json = scan.values["json"] != nil
            o.since = scan.values["since"]?.last?.trimmingCharacters(in: .whitespaces)
            return .history(.importAzure(o))
        case "clear":
            let scan = try scan(rest, command: "history clear", flags: historyClearFlags, positionals: false)
            if scan.help { return .help(topic: "history") }
            return .history(.clear(assumeYes: scan.values["yes"] != nil))
        default:
            let command = sub == "export" ? "history export" : "history"
            let scan = try scan(rest, command: command, flags: historyFlags, positionals: true)
            if scan.help { return .help(topic: "history") }
            var o = HistoryListOptions()
            o.tenant = scan.values["tenant"]?.last?.trimmingCharacters(in: .whitespaces)
            o.json = scan.values["json"] != nil
            o.csv = scan.values["csv"] != nil
            o.since = scan.values["since"]?.last?.trimmingCharacters(in: .whitespaces)
            o.until = scan.values["until"]?.last?.trimmingCharacters(in: .whitespaces)
            // Repeatable, and comma-separated: --action activate,renew.
            for raw in (scan.values["action"] ?? []).flatMap({ $0.split(separator: ",").map(String.init) }) {
                guard let a = HistoryAction(argument: raw) else { throw CLIParseError.unknownAction(raw) }
                if !o.actions.contains(a) { o.actions.append(a) }
            }
            for raw in (scan.values["outcome"] ?? []).flatMap({ $0.split(separator: ",").map(String.init) }) {
                guard let r = HistoryResult(argument: raw) else { throw CLIParseError.unknownOutcome(raw) }
                if !o.results.contains(r) { o.results.append(r) }
            }
            if let raw = scan.values["limit"]?.last { o.limit = try number(raw, flag: "--limit", range: 1...1_000_000) }
            if o.json && o.csv { throw CLIParseError.conflicting("--json", "--csv") }
            guard sub == "export" else {
                o.text = scan.positionals
                return .history(.list(o))
            }
            if o.json || o.csv { throw CLIParseError.conflicting("export", o.json ? "--json" : "--csv") }
            guard let file = scan.positionals.first?.trimmingCharacters(in: .whitespaces), !file.isEmpty else {
                throw CLIParseError.missingExportFile
            }
            if scan.positionals.count > 1 { throw CLIParseError.unexpectedArgument(scan.positionals[1], command: "history export") }
            return .history(.export(file: file, o))
        }
    }

    /// `--hours N` (1-24) or `--hours max`.
    static func hours(_ raw: String) throws -> RequestedDuration {
        if let d = RequestedDuration(argument: raw) { return d }
        if let n = Int(raw) { throw CLIParseError.outOfRange(flag: "--hours", value: n, range: Preferences.hoursRange) }
        throw CLIParseError.invalidHours(raw)
    }

    static func parsePresets(_ args: [String]) throws -> CLICommand {
        guard let sub = args.first, !sub.hasPrefix("-") || sub == "--help" || sub == "-h" else {
            // `pimento presets` alone, or with options only: list.
            return try parsePresets(["list"] + args)
        }
        if sub == "--help" || sub == "-h" || sub == "help" { return .help(topic: "presets") }
        let rest = Array(args.dropFirst())
        switch sub {
        case "list", "ls":
            let scan = try scan(rest, command: "presets list", flags: plainFlags, positionals: false)
            if scan.help { return .help(topic: "presets") }
            var o = PresetListOptions()
            o.tenant = scan.values["tenant"]?.last
            o.json = scan.values["json"] != nil
            return .presets(.list(o))
        case "show", "delete", "rm":
            let command = sub == "rm" ? "delete" : sub
            let scan = try scan(rest, command: "presets \(command)", flags: plainFlags, positionals: true)
            if scan.help { return .help(topic: "presets") }
            guard let name = scan.positionals.first?.trimmingCharacters(in: .whitespaces), !name.isEmpty else {
                throw CLIParseError.missingPresetName(command)
            }
            if scan.positionals.count > 1 { throw CLIParseError.unexpectedArgument(scan.positionals[1], command: "presets \(command)") }
            var o = PresetShowOptions()
            o.name = name
            o.tenant = scan.values["tenant"]?.last
            o.json = scan.values["json"] != nil
            return .presets(command == "show" ? .show(o) : .delete(o))
        case "save", "add":
            let scan = try scan(rest, command: "presets save", flags: presetSaveFlags, positionals: true)
            if scan.help { return .help(topic: "presets") }
            guard let name = scan.positionals.first?.trimmingCharacters(in: .whitespaces), !name.isEmpty else {
                throw CLIParseError.missingPresetName("save")
            }
            var o = PresetSaveOptions()
            o.name = name
            o.tenant = scan.values["tenant"]?.last
            o.json = scan.values["json"] != nil
            o.criteria.filters = try terms(Array(scan.positionals.dropFirst()), "filter")
            o.criteria.roles = try terms(scan.values["role"] ?? [], "--role")
            o.criteria.state = .any
            o.exact = scan.values["exact"] != nil
            o.force = scan.values["force"] != nil
            o.justification = scan.values["justification"]?.last?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let raw = scan.values["hours"]?.last { o.duration = try hours(raw) }
            o.ticketSystem = scan.values["ticket-system"]?.last?.trimmingCharacters(in: .whitespaces)
            guard o.criteria.hasSelection else { throw CLIParseError.noSelection }
            return .presets(.save(o))
        default:
            throw CLIParseError.unknownPresetCommand(sub)
        }
    }

    /// `--list`, `--dry-run`, `--tenants` (0.1.0) mapped onto the subcommands.
    static func parseLegacy(_ args: [String]) throws -> CLIInvocation? {
        let modes = Set(args.compactMap { legacyModes[$0] })
        if args.contains("--help") || args.contains("-h") {
            let topic = modes.count == 1 ? modes.first?.split(separator: " ").first.map(String.init) : nil
            return CLIInvocation(.help(topic: topic))
        }
        if args.contains("--version") { return CLIInvocation(.version(VersionOptions())) }
        guard let mode = modes.first else { return nil }
        guard modes.count == 1 else { throw CLIParseError.conflicting("--list", "--dry-run") }
        let flag = legacyModes.first { $0.value == mode }!.key
        var rest = args.filter { $0 != flag }
        let replacement = "pimento \(mode)"
        let note = "`pimento \(flag)` is deprecated and goes away in the next release; use `\(replacement)`."
        switch flag {
        case "--list":
            return try CLIInvocation(parseList(rest), deprecation: note)
        case "--tenants":
            return try CLIInvocation(parse(["tenants"] + rest).command, deprecation: note)
        default:
            // 0.1.0's dry run matched --role as a substring and, without
            // filters, planned every eligible role. Keep that for the alias.
            var hasSelection = false
            var i = 0
            while i < rest.count {
                if rest[i] == "--role", i + 1 < rest.count {
                    rest[i + 1] = "*\(rest[i + 1])*"
                    hasSelection = true
                    i += 2
                    continue
                }
                if ["-t", "--tenant", "-j", "--justification", "--hours"].contains(rest[i]) { i += 2; continue }
                if !rest[i].hasPrefix("-") { hasSelection = true }
                i += 1
            }
            if !hasSelection { rest.append("--all") }
            return try CLIInvocation(parseActivate(["--dry-run"] + rest), deprecation: note)
        }
    }

    private static func number(_ raw: String, flag: String, range: ClosedRange<Int>) throws -> Int {
        guard let n = Int(raw) else { throw CLIParseError.invalidNumber(flag: flag, value: raw) }
        guard range.contains(n) else { throw CLIParseError.outOfRange(flag: flag, value: n, range: range) }
        return n
    }

    private struct Scan {
        var values: [String: [String]] = [:]
        var positionals: [String] = []
        var help = false
    }

    private static func scan(_ args: [String], command: String, flags: [String: Flag], positionals allowed: Bool) throws -> Scan {
        var result = Scan()
        var i = 0
        var optionsEnded = false
        while i < args.count {
            let arg = args[i]
            i += 1
            if optionsEnded || arg == "-" || !arg.hasPrefix("-") {
                guard allowed else { throw CLIParseError.unexpectedArgument(arg, command: command) }
                result.positionals.append(arg)
                continue
            }
            if arg == "--" { optionsEnded = true; continue }
            if arg == "--help" || arg == "-h" { result.help = true; continue }
            var name = arg
            var inline: String?
            if arg.hasPrefix("--"), let eq = arg.firstIndex(of: "=") {
                name = String(arg[..<eq])
                inline = String(arg[arg.index(after: eq)...])
            }
            guard let flag = flags[name] else { throw CLIParseError.unknownOption(name, command: command) }
            if flag.takesValue {
                let value: String
                if let inline {
                    value = inline
                } else {
                    // Another flag of this command is no value (`-j -y` must not
                    // make "-y" the justification and drop --yes).
                    guard i < args.count, !args[i].hasPrefix("--"), flags[args[i]] == nil, args[i] != "-h" else {
                        throw CLIParseError.missingValue(name)
                    }
                    value = args[i]
                    i += 1
                }
                guard !value.isEmpty else { throw CLIParseError.missingValue(name) }
                result.values[flag.key, default: []].append(value)
            } else {
                guard inline == nil else { throw CLIParseError.valueNotAllowed(name) }
                result.values[flag.key, default: []].append("")
            }
        }
        return result
    }
}
