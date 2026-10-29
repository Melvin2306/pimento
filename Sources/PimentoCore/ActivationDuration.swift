import Foundation

/// ISO 8601 durations as ARM uses them in PIM policies and requests
/// (`PT8H`, `PT30M`, `PT1H30M`, `P1D`, `P365D`).
public enum ISODuration {
    /// Seconds, or nil when `text` is not an ISO 8601 duration. Years and
    /// months count as 365 and 30 days (they only appear in admin rules).
    public static func parse(_ text: String?) -> TimeInterval? {
        guard var s = text?.trimmingCharacters(in: .whitespaces).uppercased(), s.hasPrefix("P") else { return nil }
        s.removeFirst()
        guard !s.isEmpty else { return nil }
        var seconds: TimeInterval = 0
        var number = ""
        var inTime = false
        var sawComponent = false
        var sawTimeComponent = false
        for ch in s {
            if ch == "T" {
                guard !inTime, number.isEmpty else { return nil }
                inTime = true
                continue
            }
            if ch.isASCII, ch.isNumber || ch == "." || ch == "," {
                number.append(ch == "," ? "." : ch)
                continue
            }
            guard let value = Double(number) else { return nil }
            let unit: TimeInterval
            switch (ch, inTime) {
            case ("Y", false): unit = 365 * 86400
            case ("M", false): unit = 30 * 86400
            case ("W", false): unit = 7 * 86400
            case ("D", false): unit = 86400
            case ("H", true): unit = 3600
            case ("M", true): unit = 60
            case ("S", true): unit = 1
            default: return nil
            }
            seconds += value * unit
            number = ""
            sawComponent = true
            if inTime { sawTimeComponent = true }
        }
        // `P1DT` (a T with nothing after it) is not a duration.
        guard number.isEmpty, sawComponent, !inTime || sawTimeComponent else { return nil }
        return seconds
    }

    /// `PT8H`, `PT30M`, `PT1H30M` for a whole number of minutes.
    public static func format(minutes: Int) -> String {
        let h = minutes / 60, m = minutes % 60
        switch (h, m) {
        case (_, 0) where h > 0: return "PT\(h)H"
        case (0, _): return "PT\(m)M"
        default: return "PT\(h)H\(m)M"
        }
    }
}

/// A duration for people: `8 h`, `30 min`, `1 h 30 min`.
public enum DurationText {
    public static func short(minutes: Int) -> String {
        let h = minutes / 60, m = minutes % 60
        switch (h, m) {
        case (0, _): return "\(m) min"
        case (_, 0): return "\(h) h"
        default: return "\(h) h \(m) min"
        }
    }
}

/// The duration the user asks for: a number of hours, or whatever each
/// role's PIM policy allows.
public enum RequestedDuration: Hashable, Sendable {
    case hours(Int)
    case maximum

    /// `max` (or `maximum`) or a whole number of hours in `range`; nil otherwise.
    public init?(argument: String, range: ClosedRange<Int> = 1...ActivationRequestBuilder.maxHours) {
        let a = argument.trimmingCharacters(in: .whitespaces).lowercased()
        if a == "max" || a == "maximum" {
            self = .maximum
        } else if let h = Int(a), range.contains(h) {
            self = .hours(h)
        } else {
            return nil
        }
    }

    /// `max` or an ISO 8601 duration (`PT8H`): the JSON spelling.
    public var stringValue: String {
        switch self {
        case .maximum: "max"
        case .hours(let h): ISODuration.format(minutes: h * 60)
        }
    }

    /// Parses `stringValue`: `max`, or whole hours within 1-24 as ISO 8601.
    public init?(stringValue: String) {
        if stringValue.lowercased() == "max" {
            self = .maximum
            return
        }
        guard let seconds = ISODuration.parse(stringValue), seconds > 0,
              seconds.truncatingRemainder(dividingBy: 3600) == 0 else { return nil }
        let h = Int(seconds / 3600)
        guard (1...ActivationRequestBuilder.maxHours).contains(h) else { return nil }
        self = .hours(h)
    }

    /// `8 h` or `Maximum allowed`.
    public var label: String {
        switch self {
        case .maximum: "Maximum allowed"
        case .hours(let h): "\(h) h"
        }
    }

    public var hours: Int? {
        if case .hours(let h) = self { return h }
        return nil
    }
}

/// What one role is actually requested for: the asked duration, capped at the
/// role's policy maximum when that is known.
public struct EffectiveDuration: Equatable, Sendable {
    public let minutes: Int
    public let requested: RequestedDuration
    /// The policy's maximum in minutes; nil when it is unknown (not loaded,
    /// failed, or the policy sets none).
    public let policyMaxMinutes: Int?

    /// `min(requested, policy max)`; for `.maximum` the policy's maximum, or
    /// `fallbackHours` when the policy is unknown. Never above 24 hours.
    public static func resolve(_ requested: RequestedDuration, policyMaxMinutes: Int?, fallbackHours: Int) -> EffectiveDuration {
        let cap = ActivationRequestBuilder.maxHours * 60
        let policy = policyMaxMinutes.flatMap { $0 > 0 ? $0 : nil }
        let wanted: Int = switch requested {
        case .hours(let h): h * 60
        case .maximum: policy ?? fallbackHours * 60
        }
        let minutes = min(wanted, policy ?? cap, cap)
        return EffectiveDuration(minutes: max(1, minutes), requested: requested, policyMaxMinutes: policy)
    }

    public init(minutes: Int, requested: RequestedDuration, policyMaxMinutes: Int?) {
        self.minutes = minutes
        self.requested = requested
        self.policyMaxMinutes = policyMaxMinutes
    }

    /// True when the asked number of hours exceeds the policy's maximum.
    public var isClamped: Bool {
        guard case .hours(let h) = requested, let max = policyMaxMinutes else { return false }
        return h * 60 > max
    }

    /// `.maximum` was asked but the policy is unknown: the fallback was used.
    public var isFallback: Bool { requested == .maximum && policyMaxMinutes == nil }

    public var iso: String { ISODuration.format(minutes: minutes) }
    public var text: String { DurationText.short(minutes: minutes) }

    /// `8 h (max 8 h)`, `4 h (max 4 h)`, or just `8 h` when the maximum is unknown.
    public var label: String {
        guard let max = policyMaxMinutes else { return text }
        return "\(text) (max \(DurationText.short(minutes: max)))"
    }

    /// Why the duration differs from what was asked, if it does.
    public var note: String? {
        if isClamped, case .hours(let h) = requested {
            return "capped at the role's maximum of \(text) (asked \(h) h)"
        }
        if isFallback { return "maximum unknown, using \(text)" }
        return nil
    }
}
