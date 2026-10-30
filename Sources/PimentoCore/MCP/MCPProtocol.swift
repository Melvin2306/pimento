import Foundation

/// Model Context Protocol constants: the protocol revisions `pimento mcp`
/// speaks, JSON-RPC error codes and the `_meta` keys of the stateless
/// (2026-07-28) revision.
///
/// `pimento mcp` is *dual-era*: a request that carries
/// `_meta["io.modelcontextprotocol/protocolVersion"]` is served statelessly
/// (2026-07-28: version and client capabilities on every request, elicitation
/// through multi round-trip requests); an `initialize` request selects the
/// handshake-based revisions (2025-11-25 and earlier), where the server asks
/// the client with an `elicitation/create` request of its own.
public enum MCP {
    /// The stateless revision(s), newest first.
    public static let modernVersions = ["2026-07-28"]
    /// Revisions with an `initialize` handshake, newest first.
    public static let legacyVersions = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]
    public static var supportedVersions: [String] { modernVersions + legacyVersions }
    /// Elicitation exists from this revision on.
    static let firstVersionWithElicitation = "2025-06-18"

    public static let serverName = "pimento"

    enum Meta {
        static let protocolVersion = "io.modelcontextprotocol/protocolVersion"
        static let clientCapabilities = "io.modelcontextprotocol/clientCapabilities"
        static let clientInfo = "io.modelcontextprotocol/clientInfo"
        static let serverInfo = "io.modelcontextprotocol/serverInfo"
    }

    /// JSON-RPC and MCP error codes.
    enum Code {
        static let parseError = -32700
        static let invalidRequest = -32600
        static let methodNotFound = -32601
        static let invalidParams = -32602
        static let internalError = -32603
        static let missingRequiredClientCapability = -32021
        static let unsupportedProtocolVersion = -32022
    }

    /// Longest line read from the client (one JSON-RPC message).
    static let maxMessageBytes = 1_000_000
}

/// A JSON-RPC error answered to a request.
struct RPCError: Error, Equatable {
    let code: Int
    let message: String
    var data: JSONValue?

    static func invalidParams(_ message: String) -> RPCError { RPCError(code: MCP.Code.invalidParams, message: message) }
    static func methodNotFound(_ method: String) -> RPCError {
        RPCError(code: MCP.Code.methodNotFound, message: "Method not found: \(TerminalText.sanitize(String(method.prefix(100))))")
    }

    var json: JSONValue {
        var o: [String: JSONValue] = ["code": .int(code), "message": .string(message)]
        if let data { o["data"] = data }
        return .object(o)
    }
}

/// Which revision a request is served under.
enum MCPEra: Equatable, Sendable {
    /// 2026-07-28 and later: everything is in the request.
    case modern(version: String, capabilities: JSONValue)
    /// After `initialize`: the negotiated revision and the client's capabilities.
    case legacy(version: String, capabilities: JSONValue)

    var version: String {
        switch self {
        case .modern(let v, _), .legacy(let v, _): v
        }
    }

    var capabilities: JSONValue {
        switch self {
        case .modern(_, let c), .legacy(_, let c): c
        }
    }

    var isModern: Bool { if case .modern = self { true } else { false } }

    /// Whether the client can show a form to its user: the `elicitation`
    /// capability with form mode (an empty object means form mode), and a
    /// revision that has elicitation at all.
    var canElicitForm: Bool {
        if case .legacy(let v, _) = self, v < MCP.firstVersionWithElicitation { return false }
        guard let e = capabilities["elicitation"]?.objectValue else { return false }
        return e.isEmpty || e["form"]?.objectValue != nil
    }
}
