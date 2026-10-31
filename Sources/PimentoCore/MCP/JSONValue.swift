import Foundation

/// A JSON value, parsed and written by hand: the MCP server must read
/// whatever a client sends exactly the same way on macOS, Linux and Windows
/// (`JSONSerialization` differs in how it reports booleans and numbers), keep
/// integers exact (JSON-RPC ids), and refuse oversized or deeply nested input.
public enum JSONValue: Hashable, Sendable {
    case null
    case bool(Bool)
    /// A number without fraction or exponent that fits `Int`.
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public subscript(key: String) -> JSONValue? {
        if case .object(let o) = self { return o[key] }
        return nil
    }

    public var stringValue: String? { if case .string(let s) = self { s } else { nil } }
    public var boolValue: Bool? { if case .bool(let b) = self { b } else { nil } }
    public var objectValue: [String: JSONValue]? { if case .object(let o) = self { o } else { nil } }
    public var arrayValue: [JSONValue]? { if case .array(let a) = self { a } else { nil } }
    public var isNull: Bool { self == .null }

    /// The JSON type name, for error messages.
    public var typeName: String {
        switch self {
        case .null: "null"
        case .bool: "boolean"
        case .int: "integer"
        case .double: "number"
        case .string: "string"
        case .array: "array"
        case .object: "object"
        }
    }
}

extension JSONValue: ExpressibleByStringLiteral, ExpressibleByBooleanLiteral, ExpressibleByIntegerLiteral,
    ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral, ExpressibleByNilLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(integerLiteral value: Int) { self = .int(value) }
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { _, last in last }))
    }
    public init(nilLiteral: ()) { self = .null }
}

// MARK: Parsing

public struct JSONParseError: Error, Equatable, LocalizedError {
    public let message: String
    public var errorDescription: String? { message }
}

extension JSONValue {
    /// Limits of `parse`: a JSON-RPC message from a client is small.
    public static let maxDepth = 64

    /// Parses one JSON document. Strict: no trailing commas, comments, NaN,
    /// or anything after the value but whitespace; duplicate keys are refused.
    public static func parse(_ text: String) throws -> JSONValue {
        var parser = Parser(Array(text.utf8))
        let value = try parser.value(depth: 0)
        parser.skipWhitespace()
        guard parser.atEnd else { throw parser.error("unexpected data after the JSON value") }
        return value
    }

    struct Parser {
        let bytes: [UInt8]
        var i = 0

        init(_ bytes: [UInt8]) { self.bytes = bytes }

        var atEnd: Bool { i >= bytes.count }

        func error(_ what: String) -> JSONParseError { JSONParseError(message: "Invalid JSON at byte \(i): \(what)") }

        mutating func skipWhitespace() {
            while i < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[i]) { i += 1 }
        }

        mutating func value(depth: Int) throws -> JSONValue {
            guard depth <= JSONValue.maxDepth else { throw error("nested too deeply") }
            skipWhitespace()
            guard i < bytes.count else { throw error("unexpected end") }
            switch bytes[i] {
            case UInt8(ascii: "{"): return try object(depth: depth)
            case UInt8(ascii: "["): return try array(depth: depth)
            case UInt8(ascii: "\""): return .string(try string())
            case UInt8(ascii: "t"): try literal("true"); return .bool(true)
            case UInt8(ascii: "f"): try literal("false"); return .bool(false)
            case UInt8(ascii: "n"): try literal("null"); return .null
            default: return try number()
            }
        }

        mutating func literal(_ word: String) throws {
            let w = Array(word.utf8)
            guard i + w.count <= bytes.count, Array(bytes[i..<(i + w.count)]) == w else { throw error("unknown literal") }
            i += w.count
        }

        mutating func object(depth: Int) throws -> JSONValue {
            i += 1
            var result: [String: JSONValue] = [:]
            skipWhitespace()
            if i < bytes.count, bytes[i] == UInt8(ascii: "}") { i += 1; return .object(result) }
            while true {
                skipWhitespace()
                guard i < bytes.count, bytes[i] == UInt8(ascii: "\"") else { throw error("expected a key") }
                let key = try string()
                skipWhitespace()
                guard i < bytes.count, bytes[i] == UInt8(ascii: ":") else { throw error("expected ':'") }
                i += 1
                let v = try value(depth: depth + 1)
                guard result[key] == nil else { throw error("duplicate key \"\(TerminalText.sanitize(String(key.prefix(64))))\"") }
                result[key] = v
                skipWhitespace()
                guard i < bytes.count else { throw error("unexpected end") }
                if bytes[i] == UInt8(ascii: ",") { i += 1; continue }
                if bytes[i] == UInt8(ascii: "}") { i += 1; return .object(result) }
                throw error("expected ',' or '}'")
            }
        }

        mutating func array(depth: Int) throws -> JSONValue {
            i += 1
            var result: [JSONValue] = []
            skipWhitespace()
            if i < bytes.count, bytes[i] == UInt8(ascii: "]") { i += 1; return .array(result) }
            while true {
                result.append(try value(depth: depth + 1))
                skipWhitespace()
                guard i < bytes.count else { throw error("unexpected end") }
                if bytes[i] == UInt8(ascii: ",") { i += 1; continue }
                if bytes[i] == UInt8(ascii: "]") { i += 1; return .array(result) }
                throw error("expected ',' or ']'")
            }
        }

        mutating func hex4() throws -> UInt32 {
            guard i + 4 <= bytes.count else { throw error("short \\u escape") }
            var v: UInt32 = 0
            for _ in 0..<4 {
                let c = bytes[i]
                let d: UInt32
                switch c {
                case UInt8(ascii: "0")...UInt8(ascii: "9"): d = UInt32(c - UInt8(ascii: "0"))
                case UInt8(ascii: "a")...UInt8(ascii: "f"): d = UInt32(c - UInt8(ascii: "a") + 10)
                case UInt8(ascii: "A")...UInt8(ascii: "F"): d = UInt32(c - UInt8(ascii: "A") + 10)
                default: throw error("bad \\u escape")
                }
                v = v * 16 + d
                i += 1
            }
            return v
        }

        mutating func string() throws -> String {
            i += 1
            var out: [UInt8] = []
            while true {
                guard i < bytes.count else { throw error("unterminated string") }
                let c = bytes[i]
                if c == UInt8(ascii: "\"") { i += 1; break }
                if c < 0x20 { throw error("control character in a string") }
                if c != UInt8(ascii: "\\") { out.append(c); i += 1; continue }
                i += 1
                guard i < bytes.count else { throw error("unterminated escape") }
                let e = bytes[i]
                i += 1
                switch e {
                case UInt8(ascii: "\""): out.append(0x22)
                case UInt8(ascii: "\\"): out.append(0x5C)
                case UInt8(ascii: "/"): out.append(0x2F)
                case UInt8(ascii: "b"): out.append(0x08)
                case UInt8(ascii: "f"): out.append(0x0C)
                case UInt8(ascii: "n"): out.append(0x0A)
                case UInt8(ascii: "r"): out.append(0x0D)
                case UInt8(ascii: "t"): out.append(0x09)
                case UInt8(ascii: "u"):
                    var scalar = try hex4()
                    if (0xD800...0xDBFF).contains(scalar) {
                        guard i + 6 <= bytes.count, bytes[i] == UInt8(ascii: "\\"), bytes[i + 1] == UInt8(ascii: "u") else {
                            throw error("lone surrogate")
                        }
                        i += 2
                        let low = try hex4()
                        guard (0xDC00...0xDFFF).contains(low) else { throw error("lone surrogate") }
                        scalar = 0x10000 + ((scalar - 0xD800) << 10) + (low - 0xDC00)
                    } else if (0xDC00...0xDFFF).contains(scalar) {
                        throw error("lone surrogate")
                    }
                    guard let u = Unicode.Scalar(scalar) else { throw error("bad \\u escape") }
                    out.append(contentsOf: Array(String(Character(u)).utf8))
                default: throw error("unknown escape")
                }
            }
            // The input came from a `String`, so its bytes are valid UTF-8.
            return String(decoding: out, as: UTF8.self)
        }

        mutating func number() throws -> JSONValue {
            let start = i
            if i < bytes.count, bytes[i] == UInt8(ascii: "-") { i += 1 }
            func digits() -> Int {
                let s = i
                while i < bytes.count, (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(bytes[i]) { i += 1 }
                return i - s
            }
            let intStart = i
            let n = digits()
            guard n > 0 else { throw error("unexpected character") }
            if n > 1, bytes[intStart] == UInt8(ascii: "0") { throw error("leading zero") }
            var isInteger = true
            if i < bytes.count, bytes[i] == UInt8(ascii: ".") {
                i += 1
                isInteger = false
                guard digits() > 0 else { throw error("expected digits after '.'") }
            }
            if i < bytes.count, bytes[i] == UInt8(ascii: "e") || bytes[i] == UInt8(ascii: "E") {
                i += 1
                isInteger = false
                if i < bytes.count, bytes[i] == UInt8(ascii: "+") || bytes[i] == UInt8(ascii: "-") { i += 1 }
                guard digits() > 0 else { throw error("expected exponent digits") }
            }
            let text = String(decoding: bytes[start..<i], as: UTF8.self)
            if isInteger, let v = Int(text) { return .int(v) }
            guard let d = Double(text), d.isFinite else { throw error("number out of range") }
            return .double(d)
        }
    }
}

// MARK: Writing

extension JSONValue {
    /// Compact JSON on one line (keys sorted): what goes on the stdio
    /// transport, where a message must not contain a raw newline. Line and
    /// paragraph separators, DEL, C1 controls and bidi characters are escaped
    /// too, so the text is harmless wherever it ends up.
    public var serialized: String {
        var out = ""
        write(to: &out)
        return out
    }

    func write(to out: inout String) {
        switch self {
        case .null: out += "null"
        case .bool(let b): out += b ? "true" : "false"
        case .int(let n): out += String(n)
        case .double(let d):
            // `1000.0`, `1e+20`: stays a number with a fraction or exponent.
            out += d.isFinite ? "\(d)" : "null"
        case .string(let s): Self.writeString(s, to: &out)
        case .array(let a):
            out += "["
            for (n, v) in a.enumerated() {
                if n > 0 { out += "," }
                v.write(to: &out)
            }
            out += "]"
        case .object(let o):
            out += "{"
            for (n, key) in o.keys.sorted().enumerated() {
                if n > 0 { out += "," }
                Self.writeString(key, to: &out)
                out += ":"
                o[key]!.write(to: &out)
            }
            out += "}"
        }
    }

    static func writeString(_ s: String, to out: inout String) {
        out += "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 || TerminalText.isUnsafe(scalar) {
                    let hex = String(scalar.value, radix: 16)
                    out += "\\u" + String(repeating: "0", count: max(0, 4 - hex.count)) + hex
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        out += "\""
    }

    /// Any `Encodable` (the CLI's `--json` shapes) as a JSON value.
    public static func encoding<T: Encodable>(_ value: T) throws -> JSONValue {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var c = encoder.singleValueContainer()
            try c.encode(AzureDate.format(date))
        }
        return try parse(String(decoding: try encoder.encode(value), as: UTF8.self))
    }
}
