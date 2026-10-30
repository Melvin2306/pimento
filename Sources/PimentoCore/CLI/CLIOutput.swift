import Foundation

/// ANSI styling, on only for a terminal and when `NO_COLOR` is not set
/// (https://no-color.org: any non-empty value turns colour off).
public struct TerminalStyle: Equatable, Sendable {
    public let colors: Bool

    public init(colors: Bool) { self.colors = colors }

    public static func detect(isTTY: Bool, environment: [String: String]) -> TerminalStyle {
        let noColor = !(environment["NO_COLOR"] ?? "").isEmpty
        let dumb = environment["TERM"] == "dumb"
        return TerminalStyle(colors: isTTY && !noColor && !dumb)
    }

    private func wrap(_ s: String, _ code: String) -> String { colors && !s.isEmpty ? "\u{1B}[\(code)m\(s)\u{1B}[0m" : s }

    public func bold(_ s: String) -> String { wrap(s, "1") }
    public func dim(_ s: String) -> String { wrap(s, "2") }
    public func red(_ s: String) -> String { wrap(s, "31") }
    public func green(_ s: String) -> String { wrap(s, "32") }
    public func yellow(_ s: String) -> String { wrap(s, "33") }
    public func boldRed(_ s: String) -> String { wrap(s, "1;31") }
}

/// Makes text safe for a terminal. Much of what the CLI shows comes from
/// other people: a requester's justification and ticket, role, resource,
/// group and tenant names, Azure's error messages. Raw, a carriage return
/// could overwrite a table row just before a `[y/N]` prompt, an escape
/// sequence could hide text, set the clipboard or fake a link, and a bidi
/// override could reorder what is shown. Every such character is shown as a
/// visible escape instead (`\r`, `\e`, `\u{202E}`).
public enum TerminalText {
    /// The colour codes `TerminalStyle` writes; nothing else passes `output`.
    static let styleSequences: [[Unicode.Scalar]] = ["0", "1", "2", "31", "32", "33", "1;31"].map {
        Array("\u{1B}[\($0)m".unicodeScalars)
    }

    /// C0 and C1 controls, DEL, bidi embeddings, overrides, isolates and
    /// marks, and the Unicode line and paragraph separators.
    static func isUnsafe(_ s: Unicode.Scalar) -> Bool {
        switch s.value {
        case 0x00...0x1F, 0x7F...0x9F: true
        case 0x061C, 0x200E, 0x200F, 0x202A...0x202E, 0x2066...0x2069, 0x2028, 0x2029: true
        default: false
        }
    }

    static func visible(_ s: Unicode.Scalar) -> String {
        switch s.value {
        case 0x0A: "\\n"
        case 0x0D: "\\r"
        case 0x09: "\\t"
        case 0x1B: "\\e"
        case 0x07: "\\a"
        case 0x08: "\\b"
        default: "\\u{" + String(s.value, radix: 16, uppercase: true) + "}"
        }
    }

    /// Text from elsewhere, for one line or cell: every unsafe character
    /// (line breaks and tabs too) escaped.
    public static func sanitize(_ text: String) -> String {
        guard text.unicodeScalars.contains(where: isUnsafe) else { return text }
        var out = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            if isUnsafe(scalar) { out.append(contentsOf: visible(scalar).unicodeScalars) } else { out.append(scalar) }
        }
        return String(out)
    }

    /// What the CLI writes to stdout or stderr: line breaks and tabs stay,
    /// and with `keepStyles` the exact colour codes `TerminalStyle` writes;
    /// every other unsafe character is escaped. The last line of defence for
    /// text interpolated into messages.
    public static func output(_ text: String, keepStyles: Bool) -> String {
        guard text.unicodeScalars.contains(where: { isUnsafe($0) && $0 != "\n" && $0 != "\t" }) else { return text }
        let scalars = Array(text.unicodeScalars)
        var out = String.UnicodeScalarView()
        var i = 0
        outer: while i < scalars.count {
            let scalar = scalars[i]
            if scalar == "\u{1B}", keepStyles {
                for sequence in styleSequences where scalars[i...].starts(with: sequence) {
                    out.append(contentsOf: sequence)
                    i += sequence.count
                    continue outer
                }
            }
            if isUnsafe(scalar), scalar != "\n", scalar != "\t" {
                out.append(contentsOf: visible(scalar).unicodeScalars)
            } else {
                out.append(scalar)
            }
            i += 1
        }
        return String(out)
    }

    /// JSON text with DEL, C1 controls, bidi characters and line separators
    /// written as `\uXXXX` escapes: the same values, harmless on a terminal.
    /// (JSONEncoder escapes C0 controls itself; these occur only in strings.)
    public static func json(_ text: String) -> String {
        guard text.unicodeScalars.contains(where: { isUnsafe($0) && $0.value >= 0x7F }) else { return text }
        var out = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            if isUnsafe(scalar), scalar.value >= 0x7F {
                let hex = String(scalar.value, radix: 16)
                out.append(contentsOf: ("\\u" + String(repeating: "0", count: 4 - hex.count) + hex).unicodeScalars)
            } else {
                out.append(scalar)
            }
        }
        return String(out)
    }
}

/// Aligned plain-text columns. Widths come from the content; on a terminal
/// the flexible columns shrink (with "…") to fit `maxWidth`.
public struct TextTable: Sendable {
    public enum Tone: Sendable { case plain, dim, good, warn, bad, strong }

    public struct Cell: Sendable {
        public var text: String
        public var tone: Tone

        /// `text` is shown as given, with controls escaped (`TerminalText`).
        public init(_ text: String, _ tone: Tone = .plain) {
            self.text = TerminalText.sanitize(text)
            self.tone = tone
        }
    }

    public var headers: [String]
    public var rows: [[Cell]] = []
    /// Columns that may be truncated to fit the terminal.
    public var flexible: Set<Int> = []
    public static let gap = 2
    public static let minFlexibleWidth = 12

    public init(headers: [String], flexible: Set<Int> = []) {
        self.headers = headers
        self.flexible = flexible
    }

    public mutating func append(_ cells: [Cell]) { rows.append(cells) }

    /// Column widths after fitting into `maxWidth` (nil = no limit).
    public func widths(maxWidth: Int?) -> [Int] {
        var widths = headers.map(\.count)
        for row in rows {
            for (i, cell) in row.enumerated() where i < widths.count { widths[i] = max(widths[i], cell.text.count) }
        }
        guard let maxWidth else { return widths }
        var total: Int { widths.reduce(0, +) + Self.gap * max(0, widths.count - 1) }
        while total > maxWidth {
            let candidates = flexible.filter { $0 < widths.count && widths[$0] > Self.minFlexibleWidth }
            guard let widest = candidates.max(by: { widths[$0] < widths[$1] }) else { break }
            widths[widest] -= 1
        }
        return widths
    }

    public func render(style: TerminalStyle, maxWidth: Int? = nil) -> [String] {
        let widths = widths(maxWidth: maxWidth)
        func line(_ cells: [Cell], header: Bool) -> String {
            var parts: [String] = []
            for (i, width) in widths.enumerated() {
                let cell = i < cells.count ? cells[i] : Cell("")
                let text = Self.fit(cell.text, width)
                let last = i == widths.count - 1
                let padded = last ? text : text + String(repeating: " ", count: width - text.count)
                parts.append(header ? style.bold(padded) : Self.paint(padded, cell.tone, style))
            }
            var result = parts.joined(separator: String(repeating: " ", count: Self.gap))
            while result.hasSuffix(" ") { result.removeLast() }
            return result
        }
        return [line(headers.map { Cell($0) }, header: true)] + rows.map { line($0, header: false) }
    }

    static func fit(_ s: String, _ width: Int) -> String {
        guard s.count > width else { return s }
        guard width > 1 else { return String(s.prefix(width)) }
        return String(s.prefix(width - 1)) + "…"
    }

    static func paint(_ s: String, _ tone: Tone, _ style: TerminalStyle) -> String {
        // Style only the text, not the padding, so underlines etc. stay tidy.
        let trimmed = s.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
        let padding = String(s.dropFirst(trimmed.count))
        let styled: String = switch tone {
        case .plain: trimmed
        case .dim: style.dim(trimmed)
        case .good: style.green(trimmed)
        case .warn: style.yellow(trimmed)
        case .bad: style.red(trimmed)
        case .strong: style.boldRed(trimmed)
        }
        return styled + padding
    }
}

/// Human-readable times for the CLI. Deterministic for a given time zone.
public enum CLIFormat {
    /// `45m`, `2h 05m`, `1d 3h`, `<1m`; `expired` when `until` has passed.
    public static func timeLeft(until: Date, now: Date) -> String {
        let seconds = Int(until.timeIntervalSince(now))
        guard seconds > 0 else { return "expired" }
        let minutes = seconds / 60
        if minutes < 1 { return "<1m" }
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)h " + String(format: "%02dm", minutes % 60) }
        return "\(hours / 24)d \(hours % 24)h"
    }

    /// `18:42` today, `Oct 30 18:42` on another day.
    public static func clock(_ date: Date, now: Date, timeZone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = calendar.isDate(date, inSameDayAs: now) ? "HH:mm" : "MMM d HH:mm"
        return formatter.string(from: date)
    }

    public static func plural(_ n: Int, _ noun: String) -> String { "\(n) \(noun)\(n == 1 ? "" : "s")" }
}

// MARK: JSON output

/// The shapes `--json` prints. Keys are sorted; absent values are left out.
public enum CLIJSON {
    public struct User: Encodable, Equatable, Sendable {
        public let objectId: String
        public let name: String?
        public let upn: String?

        public init(_ identity: Identity) {
            objectId = identity.objectId
            name = identity.name
            upn = identity.upn
        }
    }

    public struct Role: Encodable, Equatable, Sendable {
        public let id: String
        public let roleName: String
        public let roleDefinitionId: String
        public let scope: String
        public let scopeName: String
        public let scopeType: String
        /// `direct` or `group`.
        public let membership: String
        public let group: String?
        public let isOwner: Bool
        public let hasCondition: Bool
        public let isActive: Bool
        public let activeUntil: String?
        /// Seconds until the activation ends (`status` only).
        public let secondsLeft: Int?
        public let eligibilityScheduleId: String
        /// The policy's longest activation, ISO 8601 (`list` only; absent when unknown).
        public let maxDuration: String?
        /// What the role's PIM policy asks for on activation (`list` only).
        public let policy: Policy?

        public init(_ role: EligibleRole, now: Date? = nil, policy lookup: PolicyLookup? = nil) {
            id = role.id
            roleName = role.roleName
            roleDefinitionId = role.roleDefinitionId
            scope = role.scope
            scopeName = role.scopeName
            scopeType = role.scopeType
            switch role.membership {
            case .direct: membership = "direct"; group = nil
            case .group(let name): membership = "group"; group = name
            }
            isOwner = role.isOwner
            hasCondition = role.hasCondition
            isActive = role.isActive
            activeUntil = role.activeUntil.map(AzureDate.format)
            secondsLeft = now.flatMap { now in role.activeUntil.map { max(0, Int($0.timeIntervalSince(now))) } }
            eligibilityScheduleId = role.eligibilityScheduleId
            maxDuration = lookup?.policy?.maxDurationISO
            policy = lookup.map(Policy.init)
        }
    }

    public struct Policy: Encodable, Equatable, Sendable {
        /// `loaded`, `notFound` or `failed`.
        public let status: String
        public let maxDuration: String?
        public let requiresJustification: Bool?
        public let requiresTicket: Bool?
        public let requiresMfa: Bool?
        public let requiresApproval: Bool?
        public let authenticationContext: String?
        public let error: String?

        public init(_ lookup: PolicyLookup) {
            let p = lookup.policy
            switch lookup {
            case .loaded: status = "loaded"; error = nil
            case .notFound: status = "notFound"; error = nil
            case .failed(let message): status = "failed"; error = message
            }
            maxDuration = p?.maxDurationISO
            requiresJustification = p?.requiresJustification
            requiresTicket = p?.requiresTicket
            requiresMfa = p?.requiresMFA
            requiresApproval = p?.requiresApproval
            authenticationContext = p?.authenticationContext?.nonEmpty
        }
    }

    public struct RoleList: Encodable, Equatable, Sendable {
        public let tenantId: String?
        public let user: User
        public let roles: [Role]
    }

    public struct Tenant: Encodable, Equatable, Sendable {
        public let id: String
        public let displayName: String?
        public let defaultDomain: String?
        public let category: String?

        public init(_ t: TenantInfo) {
            id = t.id
            displayName = t.displayName
            defaultDomain = t.defaultDomain
            category = t.category
        }
    }

    public struct TenantList: Encodable, Equatable, Sendable {
        public let tenants: [Tenant]
    }

    public struct Request: Encodable, Equatable, Sendable {
        public let method: String
        public let url: String
        public let body: ActivationRequestBody
    }

    public struct Result: Encodable, Equatable, Sendable {
        /// `activated`, `submitted` (pending approval), `scheduled` (starts
        /// later), `skipped` (already active / not active), `failed`, `planned`
        /// (dry run), `deactivated` or `renewed`.
        public let outcome: String
        public let role: Role
        public let status: String?
        public let until: String?
        public let code: String?
        public let message: String?
        public let rules: [String]?
        public let request: Request?
        /// The duration requested for this role, ISO 8601, after the policy cap.
        public let duration: String?
        /// The role's policy maximum, ISO 8601, when known.
        public let maxDuration: String?
        /// True when the asked duration was capped at the policy maximum.
        public let capped: Bool?
        /// Renew dry run: the deactivation and the activation that follows.
        public let requests: [Request]?
        /// Too soon to end: from when it is possible.
        public let possibleAt: String?
        /// A scheduled activation: when it starts (also for a planned one).
        public let start: String?
        /// A request waiting for approval: its id (for `pimento wait`).
        public let requestId: String?

        public init(role: EligibleRole, outcome: ActivationOutcome?, plan: PlannedRequest?,
                    followUp: PlannedRequest? = nil, skipReason: String = "already active") {
            self.role = Role(role)
            let timed = plan?.action == .activate ? plan : followUp
            duration = timed?.duration.iso
            maxDuration = timed?.duration.policyMaxMinutes.map { ISODuration.format(minutes: $0) }
            capped = timed?.duration.isClamped == true ? true : nil
            let planned = outcome == nil ? plan.map { Request(method: "PUT", url: $0.url.absoluteString, body: $0.body) } : nil
            if let followUp, let planned, outcome == nil {
                request = nil
                requests = [planned, Request(method: "PUT", url: followUp.url.absoluteString, body: followUp.body)]
            } else {
                request = planned
                requests = nil
            }
            var status: String?, until: String?, code: String?, message: String?, rules: [String]?, possibleAt: String?
            var start = timed?.start.map(AzureDate.format)
            switch outcome {
            case nil:
                self.outcome = plan == nil ? "skipped" : "planned"
                if plan == nil { message = skipReason; until = role.activeUntil.map(AzureDate.format) }
            case .activated(let s, let u)?:
                self.outcome = ActivationOutcome.isGranted(status: s) ? "activated" : "submitted"
                status = s.isEmpty ? nil : s
                until = u.map(AzureDate.format)
            case .alreadyActive?:
                self.outcome = "skipped"
                message = "already active"
            case .policyViolation(let r, let m)?:
                self.outcome = "failed"
                code = "RoleAssignmentRequestPolicyValidationFailed"
                rules = r
                message = m
            case .failed(let c, let m)?:
                self.outcome = "failed"
                code = c
                message = m
            case .deactivated(let s)?:
                self.outcome = "deactivated"
                status = s.isEmpty ? nil : s
            case .notActive?:
                self.outcome = "skipped"
                message = "not active"
            case .tooSoon(let at)?:
                self.outcome = "failed"
                code = "ActiveDurationTooShort"
                message = "PIM ends an activation only after 5 minutes"
                possibleAt = at.map(AzureDate.format)
            case .renewed(let u)?:
                self.outcome = "renewed"
                until = u.map(AzureDate.format)
            case .scheduled(let s, let begin, let u)?:
                self.outcome = "scheduled"
                status = s.isEmpty ? nil : s
                start = AzureDate.format(begin)
                until = u.map(AzureDate.format)
            }
            self.start = start
            requestId = outcome?.isAwaitingApproval == true ? plan?.requestId : nil
            self.possibleAt = possibleAt
            self.status = status
            self.until = until
            self.code = code
            self.message = message
            self.rules = rules
        }
    }

    public struct Summary: Encodable, Equatable, Sendable {
        public var activated = 0
        public var submitted = 0
        public var skipped = 0
        public var failed = 0
        public var planned = 0
        /// Only in deactivate / renew output.
        public var deactivated: Int?
        public var renewed: Int?
        /// Only when activations were scheduled (`activate --at`).
        public var scheduled: Int?

        public init(_ results: [Result], operation: ActivationSummary.Operation = .activate) {
            if operation == .deactivate { deactivated = 0 }
            if operation == .renew { renewed = 0 }
            for r in results {
                switch r.outcome {
                case "activated": activated += 1
                case "submitted": submitted += 1
                case "skipped": skipped += 1
                case "planned": planned += 1
                case "deactivated": deactivated = (deactivated ?? 0) + 1
                case "renewed": renewed = (renewed ?? 0) + 1
                case "scheduled": scheduled = (scheduled ?? 0) + 1
                default: failed += 1
                }
            }
        }
    }

    /// `pimento deactivate | renew | extend --json`.
    public struct Lifecycle: Encodable, Equatable, Sendable {
        /// `deactivate`, `renew` or `extend`.
        public let action: String
        public let dryRun: Bool
        public let tenantId: String?
        public let user: User
        public let preset: String?
        public let justification: String?
        /// Renew: the asked duration (`max` or ISO 8601). Extend: `P30D`.
        public let duration: String?
        public let results: [Result]
        public let missing: [MissingRole]?
        public let summary: Summary
    }

    public struct MissingRole: Encodable, Equatable, Sendable {
        public let scope: String
        public let roleDefinitionId: String
        public let roleName: String?
        public let scopeName: String?

        public init(_ r: PresetRole) {
            scope = r.scope
            roleDefinitionId = r.roleDefinitionId
            roleName = r.roleName
            scopeName = r.scopeName
        }
    }

    public struct Activation: Encodable, Equatable, Sendable {
        public let dryRun: Bool
        public let tenantId: String?
        public let user: User
        /// The asked hours; absent for `--hours max`.
        public let hours: Int?
        /// The asked duration: `max` or ISO 8601 (`PT8H`).
        public let duration: String
        public let preset: String?
        public let justification: String
        /// `--at`: when the activations start (ISO 8601, UTC); absent for now.
        public let start: String?
        public let ticket: TicketInfo?
        public let results: [Result]
        /// Preset roles that are no longer eligible.
        public let missing: [MissingRole]?
        public let summary: Summary

        static func empty(
            _ o: ActivateOptions, preset: Preset?, tenantId: String?, user: Identity, justification: String,
            requested: RequestedDuration, missing: [PresetRole], start: Date?, ticket: TicketInfo?
        ) -> Activation {
            Activation(
                dryRun: o.dryRun, tenantId: tenantId, user: .init(user), hours: requested.hours,
                duration: requested.stringValue, preset: preset?.name, justification: justification,
                start: start.map(AzureDate.format), ticket: ticket, results: [],
                missing: missing.isEmpty ? nil : missing.map(MissingRole.init), summary: .init([]))
        }
    }

    /// One preset in `pimento presets list|show --json`.
    public struct PresetDoc: Encodable, Equatable, Sendable {
        public let id: String
        public let name: String
        public let tenantId: String?
        public let roles: [MissingRole]
        public let match: [PresetRule]?
        public let justification: String?
        public let duration: String?
        public let ticketSystem: String?
        public let createdAt: String?
        public let updatedAt: String?

        public init(_ p: Preset) {
            id = p.id.uuidString.lowercased()
            name = p.name
            tenantId = p.tenantId
            roles = p.roles.map(MissingRole.init)
            match = p.match.isEmpty ? nil : p.match
            justification = p.trimmedJustification
            duration = p.duration?.stringValue
            ticketSystem = p.trimmedTicketSystem
            createdAt = p.createdAt.map(AzureDate.format)
            updatedAt = p.updatedAt.map(AzureDate.format)
        }
    }

    public struct PresetList: Encodable, Equatable, Sendable {
        public let file: String
        public let presets: [PresetDoc]
    }

    public static func encode<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return TerminalText.json(String(decoding: (try? encoder.encode(value)) ?? Data("{}".utf8), as: UTF8.self))
    }
}
