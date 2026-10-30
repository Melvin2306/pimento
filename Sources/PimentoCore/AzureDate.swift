import Foundation

/// ISO 8601 helpers tolerant of ARM's variable fractional seconds
/// (`.66Z`, `.603Z`, `.4170000Z`).
public enum AzureDate {
    public static func parse(_ string: String?) -> Date? {
        guard let string, !string.isEmpty else { return nil }
        let normalized = normalizeFraction(string)
        return formatters.withLock { f in f.fraction.date(from: normalized) ?? f.plain.date(from: normalized) }
    }

    /// UTC, millisecond precision, `Z` suffix — the shape the portal sends.
    public static func format(_ date: Date) -> String {
        formatters.withLock { $0.output.string(from: date) }
    }

    /// Made once (a formatter is expensive to create: rows, history and
    /// approvals parse thousands of dates), used under a lock: formatters are
    /// not documented as thread-safe in swift-corelibs-foundation.
    private static let formatters = Formatters()

    private final class Formatters: @unchecked Sendable {
        private let lock = NSLock()
        let fraction = ISO8601DateFormatter()
        let plain = ISO8601DateFormatter()
        let output = ISO8601DateFormatter()

        init() {
            fraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            plain.formatOptions = [.withInternetDateTime]
            output.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            output.timeZone = TimeZone(identifier: "UTC")
        }

        func withLock<T>(_ body: (Formatters) -> T) -> T {
            lock.lock()
            defer { lock.unlock() }
            return body(self)
        }
    }

    /// Pads or truncates the fractional-seconds part to exactly 3 digits.
    static func normalizeFraction(_ s: String) -> String {
        guard let tIndex = s.firstIndex(of: "T"),
              let dot = s[tIndex...].firstIndex(of: ".") else { return s }
        let digitsStart = s.index(after: dot)
        var digitsEnd = digitsStart
        while digitsEnd < s.endIndex, s[digitsEnd].isASCII, s[digitsEnd].isNumber {
            digitsEnd = s.index(after: digitsEnd)
        }
        var digits = String(s[digitsStart..<digitsEnd])
        if digits.isEmpty { return s }
        digits = String((digits + "000").prefix(3))
        return String(s[..<digitsStart]) + digits + String(s[digitsEnd...])
    }
}
