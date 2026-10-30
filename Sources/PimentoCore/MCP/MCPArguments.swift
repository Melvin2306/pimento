import Foundation

/// The input schema of a tool, written once: `tools/list` publishes it as JSON
/// Schema and `tools/call` validates arguments against it. Tool arguments come
/// from a language model and are untrusted (a prompt-injected agent writes
/// whatever it is told to), so validation is strict: no unknown keys, exact
/// types, bounded lengths and counts, no control or bidi characters.
indirect enum MCPArgType: Sendable {
    /// `allowed`: an extra check on the trimmed value; returns why it is refused.
    case string(maxLength: Int, check: (@Sendable (String) -> String?)? = nil)
    case integer(ClosedRange<Int>)
    case boolean
    case enumeration([String])
    case array(MCPArgType, maxItems: Int)
    case object([MCPField])
}

struct MCPField: Sendable {
    let name: String
    let type: MCPArgType
    let required: Bool
    let description: String

    init(_ name: String, _ type: MCPArgType, required: Bool = false, _ description: String) {
        self.name = name
        self.type = type
        self.required = required
        self.description = description
    }
}

/// A tool argument that failed validation: reported to the model as a tool
/// error it can correct.
struct MCPArgumentError: Error, Equatable, LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

enum MCPSchema {
    /// The JSON Schema of `fields` as an object.
    static func json(_ fields: [MCPField]) -> JSONValue {
        var properties: [String: JSONValue] = [:]
        for f in fields {
            var schema = json(f.type)
            if case .object(var o) = schema {
                o["description"] = .string(f.description)
                schema = .object(o)
            }
            properties[f.name] = schema
        }
        var o: [String: JSONValue] = [
            "type": "object",
            "properties": .object(properties),
            "additionalProperties": false,
        ]
        let required = fields.filter(\.required).map { JSONValue.string($0.name) }
        if !required.isEmpty { o["required"] = .array(required) }
        return .object(o)
    }

    static func json(_ type: MCPArgType) -> JSONValue {
        switch type {
        case .string(let max, _): ["type": "string", "minLength": 1, "maxLength": .int(max)]
        case .integer(let r): ["type": "integer", "minimum": .int(r.lowerBound), "maximum": .int(r.upperBound)]
        case .boolean: ["type": "boolean"]
        case .enumeration(let values): ["type": "string", "enum": .array(values.map(JSONValue.string))]
        case .array(let item, let max): ["type": "array", "items": json(item), "minItems": 1, "maxItems": .int(max)]
        case .object(let fields): json(fields)
        }
    }

    /// Checks `value` against `fields` (as an object). Throws the first problem.
    static func validate(_ value: JSONValue, _ fields: [MCPField], path: String = "arguments") throws {
        guard case .object(let o) = value else { throw MCPArgumentError(message: "\(path) must be an object, got \(value.typeName).") }
        let known = Set(fields.map(\.name))
        if let unknown = o.keys.sorted().first(where: { !known.contains($0) }) {
            throw MCPArgumentError(message: "Unknown argument \(path).\(MCPText.clip(unknown, 64)). Allowed: \(fields.map(\.name).joined(separator: ", ")).")
        }
        for f in fields {
            guard let v = o[f.name], !v.isNull else {
                if f.required { throw MCPArgumentError(message: "Missing required argument \(path).\(f.name).") }
                continue
            }
            try validate(v, f.type, path: "\(path).\(f.name)")
        }
    }

    static func validate(_ value: JSONValue, _ type: MCPArgType, path: String) throws {
        switch type {
        case .string(let max, let check):
            guard case .string(let s) = value else { throw MCPArgumentError(message: "\(path) must be a string, got \(value.typeName).") }
            let t = s.trimmingCharacters(in: .whitespaces)
            guard !t.isEmpty else { throw MCPArgumentError(message: "\(path) must not be empty.") }
            guard s.count <= max else { throw MCPArgumentError(message: "\(path) is too long (at most \(max) characters).") }
            if s.unicodeScalars.contains(where: MCPText.isForbidden) {
                throw MCPArgumentError(message: "\(path) contains a control, formatting or bidi character, which is not allowed.")
            }
            if let check, let why = check(t) { throw MCPArgumentError(message: "\(path): \(why)") }
        case .integer(let range):
            guard case .int(let n) = value else { throw MCPArgumentError(message: "\(path) must be an integer, got \(value.typeName).") }
            guard range.contains(n) else {
                throw MCPArgumentError(message: "\(path) must be between \(range.lowerBound) and \(range.upperBound), got \(n).")
            }
        case .boolean:
            guard case .bool = value else { throw MCPArgumentError(message: "\(path) must be a boolean, got \(value.typeName).") }
        case .enumeration(let values):
            guard case .string(let s) = value, values.contains(s) else {
                throw MCPArgumentError(message: "\(path) must be one of \(values.joined(separator: ", ")).")
            }
        case .array(let item, let max):
            guard case .array(let a) = value else { throw MCPArgumentError(message: "\(path) must be an array, got \(value.typeName).") }
            guard !a.isEmpty else { throw MCPArgumentError(message: "\(path) must not be empty.") }
            guard a.count <= max else { throw MCPArgumentError(message: "\(path) has too many items (at most \(max)).") }
            for (n, v) in a.enumerated() { try validate(v, item, path: "\(path)[\(n)]") }
        case .object(let fields):
            try validate(value, fields, path: path)
        }
    }
}

/// Read access to validated arguments.
struct MCPArguments: Sendable {
    let values: [String: JSONValue]

    init(_ value: JSONValue) { values = value.objectValue ?? [:] }

    func string(_ key: String) -> String? { values[key]?.stringValue?.trimmingCharacters(in: .whitespaces) }
    func int(_ key: String) -> Int? { if case .int(let n)? = values[key] { n } else { nil } }
    func bool(_ key: String) -> Bool? { values[key]?.boolValue }
    func strings(_ key: String) -> [String]? { values[key]?.arrayValue?.compactMap { $0.stringValue?.trimmingCharacters(in: .whitespaces) } }
    func objects(_ key: String) -> [MCPArguments]? { values[key]?.arrayValue?.map(MCPArguments.init) }

    /// The arguments as one canonical string (keys sorted): binds a
    /// confirmation to exactly these arguments.
    var canonical: String { JSONValue.object(values).serialized }
}

/// Text helpers for what the server shows: to the model and, in a
/// confirmation, to the human.
enum MCPText {
    /// Characters refused in arguments: C0/C1 controls (line breaks and tabs
    /// too), DEL, bidi controls, line and paragraph separators, and zero-width,
    /// blank or other invisible characters that could make a confirmation say
    /// something other than what it seems to (or a justification look empty).
    static func isForbidden(_ s: Unicode.Scalar) -> Bool {
        if TerminalText.isUnsafe(s) { return true }
        switch s.value {
        case 0x00AD, 0x180E, 0x200B...0x200D, 0x2060...0x2064, 0xFEFF, 0xFFF9...0xFFFB: return true
        // Letters and symbols that render as nothing: Hangul fillers, the
        // combining grapheme joiner, Khmer inherent vowels, the blank Braille cell.
        case 0x034F, 0x115F, 0x1160, 0x17B4, 0x17B5, 0x2800, 0x3164, 0xFFA0: return true
        default: return s.properties.generalCategory == .format || s.properties.generalCategory == .privateUse
        }
    }

    /// At most `n` characters, control characters made visible.
    static func clip(_ s: String, _ n: Int) -> String {
        let safe = TerminalText.sanitize(s)
        return safe.count <= n ? safe : String(safe.prefix(max(1, n - 1))) + "…"
    }

    /// Absolute file paths, home-relative paths and anything that looks like a
    /// JWT or bearer token, replaced: tool results never carry the location of
    /// Pimento's files, az, the token store, or a token.
    static func redact(_ s: String) -> String {
        var out = s
        for (pattern, replacement) in redactions {
            out = out.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression)
        }
        return out
    }

    static let redactions: [(String, String)] = [
        // JWTs (access and ID tokens) and bearer values.
        (#"eyJ[A-Za-z0-9_-]{4,}\.[A-Za-z0-9_-]{4,}\.[A-Za-z0-9_-]*"#, "<token>"),
        (#"(?i)bearer\s+[A-Za-z0-9._~+/=-]{8,}"#, "Bearer <token>"),
        // POSIX paths under the usual roots, and ~/…
        (#"(?:~|\$HOME|(?<![A-Za-z0-9_.-])/(?:Users|home|private|var|tmp|opt|usr|etc|Library|Applications|Volumes|root|mnt|run|snap|nix|System))(?:/[^\s'"“”‘’`,;:()<>\[\]{}]*)+"#, "<path>"),
        // Windows paths: C:\…, \\server\share\…, %APPDATA%\…
        (#"(?:[A-Za-z]:\\|\\\\[A-Za-z0-9._-]+\\|%[A-Za-z_]+%\\?)[^\s'"“”‘’`,;()<>\[\]{}]*"#, "<path>"),
    ]

    /// `redact` applied to every string in `value`.
    static func redact(_ value: JSONValue) -> JSONValue {
        switch value {
        case .string(let s): .string(redact(s))
        case .array(let a): .array(a.map(redact))
        case .object(let o): .object(o.mapValues(redact))
        default: value
        }
    }
}
