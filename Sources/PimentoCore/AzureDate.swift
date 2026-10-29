import Foundation

/// ISO 8601 helpers tolerant of ARM's variable fractional seconds
/// (`.66Z`, `.603Z`, `.4170000Z`).
public enum AzureDate {
    public static func parse(_ string: String?) -> Date? {
        guard let string, !string.isEmpty else { return nil }
        let normalized = normalizeFraction(string)
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: normalized) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: normalized)
    }

    /// UTC, millisecond precision, `Z` suffix — the shape the portal sends.
    public static func format(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.string(from: date)
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
