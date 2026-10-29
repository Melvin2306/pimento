import Foundation

/// Parsed command line. Without one of the mode flags the binary opens the app.
public struct CLIOptions: Equatable, Sendable {
    public enum Mode: Equatable, Sendable {
        case app
        case help
        case version
        case tenants
        case list
        case dryRun
    }

    public var mode: Mode = .app
    public var tenant: String?
    public var justification = ""
    public var hours = ActivationRequestBuilder.defaultHours
    public var roleFilter: String?
    /// Case-insensitive substrings of the resource name (OR-ed).
    public var filters: [String] = []

    public init() {}

    public enum ParseError: Error, Equatable, LocalizedError {
        case missingValue(String)
        case invalidHours(String)
        case unknownOption(String)
        case conflictingModes

        public var errorDescription: String? {
            switch self {
            case .missingValue(let flag): "\(flag) needs a value."
            case .invalidHours(let value): "--hours must be a whole number of hours, got “\(value)”."
            case .unknownOption(let flag): "Unknown option \(flag). See --help."
            case .conflictingModes: "Use only one of --list, --dry-run, --tenants."
            }
        }
    }

    static let modeFlags: [String: Mode] = [
        "--help": .help, "-h": .help, "--version": .version,
        "--tenants": .tenants, "--list": .list, "--dry-run": .dryRun,
    ]

    public static func parse(_ args: [String]) throws -> CLIOptions {
        var options = CLIOptions()
        let modes = Set(args.compactMap { modeFlags[$0] })
        if modes.contains(.help) { options.mode = .help; return options }
        if modes.contains(.version) { options.mode = .version; return options }
        guard modes.count <= 1 else { throw ParseError.conflictingModes }
        options.mode = modes.first ?? .app

        var it = args.makeIterator()
        func value(for flag: String) throws -> String {
            guard let v = it.next(), !v.hasPrefix("--") else { throw ParseError.missingValue(flag) }
            return v
        }
        while let arg = it.next() {
            if modeFlags[arg] != nil { continue }
            if arg.hasPrefix("--tenant=") {
                options.tenant = String(arg.dropFirst("--tenant=".count))
                continue
            }
            switch arg {
            case "--tenant", "-t":
                options.tenant = try value(for: arg)
            case "-j", "--justification":
                options.justification = try value(for: arg)
            case "--hours":
                let raw = try value(for: arg)
                guard let h = Int(raw) else { throw ParseError.invalidHours(raw) }
                options.hours = h
            case "--role":
                options.roleFilter = try value(for: arg).lowercased()
            default:
                // The app ignores what it doesn't know (macOS passes its own
                // arguments, e.g. -NSDocumentRevisionsDebugMode).
                if options.mode == .app { continue }
                if arg.hasPrefix("-") { throw ParseError.unknownOption(arg) }
                guard options.mode == .dryRun else { throw ParseError.unknownOption(arg) }
                options.filters.append(arg.lowercased())
            }
        }
        return options
    }
}
