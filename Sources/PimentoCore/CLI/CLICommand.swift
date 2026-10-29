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
    public var justification = ""
    public var hours = ActivationRequestBuilder.defaultHours
    public var assumeYes = false
    public var dryRun = false
    public var maxParallel = 8
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

public enum CompletionShell: String, CaseIterable, Sendable {
    case zsh, bash, fish
}

public enum CLICommand: Equatable, Sendable {
    case help(topic: String?)
    case version
    case list(ListOptions)
    case activate(ActivateOptions)
    case status(StatusOptions)
    case tenants(TenantsOptions)
    case completions(CompletionShell)

    public static let names = ["list", "activate", "status", "tenants", "completions", "version", "help"]
}

/// A parsed command line, plus a note when it used a deprecated spelling.
public struct CLIInvocation: Equatable, Sendable {
    public var command: CLICommand
    public var deprecation: String?

    public init(_ command: CLICommand, deprecation: String? = nil) {
        self.command = command
        self.deprecation = deprecation
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
    case outOfRange(flag: String, value: Int, range: ClosedRange<Int>)
    case conflicting(String, String)
    case missingJustification
    case noSelection
    case missingShell
    case unknownShell(String)

    public var errorDescription: String? {
        switch self {
        case .unknownCommand(let c): "Unknown command “\(c)”. Run `pimento help` for the list of commands."
        case .expectedCommand(let o): "Expected a command before \(o), e.g. `pimento list \(o) …`. Run `pimento help`."
        case .unknownOption(let o, let c): "Unknown option \(o) for `pimento \(c)`. Run `pimento help \(c)`."
        case .unexpectedArgument(let a, let c): "`pimento \(c)` takes no argument “\(a)”."
        case .missingValue(let flag): "\(flag) needs a value."
        case .valueNotAllowed(let flag): "\(flag) takes no value."
        case .invalidNumber(let flag, let value): "\(flag) needs a whole number, got “\(value)”."
        case .outOfRange(let flag, let value, let range):
            "\(flag) must be between \(range.lowerBound) and \(range.upperBound), got \(value)."
        case .conflicting(let a, let b): "Use either \(a) or \(b), not both."
        case .missingJustification: "activate needs a justification: -j \"TEXT\"."
        case .noSelection:
            "Say which roles to activate: resource filters, --role NAME, or --all for every eligible role."
        case .missingShell: "Name a shell: pimento completions zsh|bash|fish."
        case .unknownShell(let s): "No completions for “\(s)”. Use zsh, bash or fish."
        }
    }
}

/// Hand-written subcommand parser: `pimento <command> [options] [filters]`.
public enum CLIParser {
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
    ]) { a, _ in a }

    private static let plainFlags = tenant.merging(json) { a, _ in a }

    /// The read-only flags of 0.1.0 (`pimento --list`), still accepted for one release.
    static let legacyModes = ["--list": "list", "--dry-run": "activate --dry-run", "--tenants": "tenants"]

    public static func parse(_ args: [String]) throws -> CLIInvocation {
        guard let first = args.first else { return CLIInvocation(.help(topic: nil)) }
        if !CLICommand.names.contains(first), let legacy = try parseLegacy(args) { return legacy }
        let rest = Array(args.dropFirst())
        switch first {
        case "help", "--help", "-h":
            guard let topic = rest.first else { return CLIInvocation(.help(topic: nil)) }
            guard CLICommand.names.contains(topic) else { throw CLIParseError.unknownCommand(topic) }
            return CLIInvocation(.help(topic: topic))
        case "version", "--version":
            if let extra = rest.first { throw CLIParseError.unexpectedArgument(extra, command: "version") }
            return CLIInvocation(.version)
        case "list": return try CLIInvocation(parseList(rest))
        case "activate": return try CLIInvocation(parseActivate(rest))
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
        o.criteria.filters = scan.positionals
        o.criteria.roles = scan.values["role"] ?? []
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
        o.criteria.filters = scan.positionals
        o.criteria.roles = scan.values["role"] ?? []
        o.all = scan.values["all"] != nil
        o.assumeYes = scan.values["yes"] != nil
        o.dryRun = scan.values["dry-run"] != nil
        o.justification = (scan.values["justification"]?.last ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if let raw = scan.values["hours"]?.last {
            o.hours = try number(raw, flag: "--hours", range: Preferences.hoursRange)
        }
        if let raw = scan.values["max-parallel"]?.last {
            o.maxParallel = try number(raw, flag: "--max-parallel", range: ActivateOptions.maxParallelRange)
        }
        guard o.criteria.hasSelection || o.all else { throw CLIParseError.noSelection }
        guard !o.justification.isEmpty else { throw CLIParseError.missingJustification }
        return .activate(o)
    }

    /// `--list`, `--dry-run`, `--tenants` (0.1.0) mapped onto the subcommands.
    static func parseLegacy(_ args: [String]) throws -> CLIInvocation? {
        let modes = Set(args.compactMap { legacyModes[$0] })
        if args.contains("--help") || args.contains("-h") {
            let topic = modes.count == 1 ? modes.first?.split(separator: " ").first.map(String.init) : nil
            return CLIInvocation(.help(topic: topic))
        }
        if args.contains("--version") { return CLIInvocation(.version) }
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
                    guard i < args.count, !args[i].hasPrefix("--") else { throw CLIParseError.missingValue(name) }
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
