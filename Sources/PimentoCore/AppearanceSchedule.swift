import Foundation

/// A wall-clock time of day, to the minute (`07:00`).
public struct ClockTime: Hashable, Comparable, Sendable {
    /// Minutes since midnight, 0..<1440.
    public let minutes: Int

    /// Wraps into the day: 1440 is 00:00, -60 is 23:00.
    public init(minutes: Int) {
        self.minutes = ((minutes % 1440) + 1440) % 1440
    }

    public init(hour: Int, minute: Int) {
        self.init(minutes: hour * 60 + minute)
    }

    /// `HH:mm` or `H:mm`, 00:00 to 23:59; nil for anything else.
    public init?(parsing text: String) {
        let parts = text.trimmingCharacters(in: .whitespaces).split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, (1...2).contains(parts[0].count), parts[1].count == 2,
              parts.allSatisfy({ $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) }),
              let hour = Int(parts[0]), let minute = Int(parts[1]),
              (0..<24).contains(hour), (0..<60).contains(minute) else { return nil }
        self.init(hour: hour, minute: minute)
    }

    public var hour: Int { minutes / 60 }
    public var minute: Int { minutes % 60 }
    /// `07:00`: how it is stored.
    public var text: String { String(format: "%02d:%02d", hour, minute) }

    public static func < (a: ClockTime, b: ClockTime) -> Bool { a.minutes < b.minutes }
}

/// Settings › Appearance › By time of day: light, dark and,
/// optionally, ultra dark, each from a time of day.
///
/// The rules, all in local wall-clock time:
/// 1. Light applies from `lightFrom` until `darkFrom`, dark from `darkFrom`
///    until `lightFrom`. Either may be the later time: the periods wrap
///    across midnight (light from 20:00 and dark from 06:00 works).
/// 2. Ultra dark, when on, is a deeper stage of the dark period: it applies
///    from `ultraDarkFrom` until `lightFrom`.
/// 3. An ultra dark time inside the light period (from `lightFrom` up to,
///    not including, `darkFrom`, e.g. 18:00 with dark from 19:00) cannot
///    start ultra dark while it is light; ultra dark then starts with dark,
///    at `darkFrom`, for the whole dark period. The same goes for an ultra
///    dark time equal to `lightFrom`.
/// 4. An ultra dark time equal to `darkFrom` replaces dark entirely.
/// 5. Equal light and dark times leave no light period: dark all day (with
///    ultra dark from its time until `lightFrom`, if on).
/// Each period starts at its minute (00 seconds) and ends just before the
/// next one starts.
public struct AppearanceSchedule: Equatable, Sendable {
    public var lightFrom = ClockTime(hour: 7, minute: 0)
    public var darkFrom = ClockTime(hour: 19, minute: 0)
    public var ultraDarkEnabled = false
    public var ultraDarkFrom = ClockTime(hour: 23, minute: 0)

    public init() {}

    public init(lightFrom: ClockTime, darkFrom: ClockTime, ultraDarkFrom: ClockTime? = nil) {
        self.lightFrom = lightFrom
        self.darkFrom = darkFrom
        if let ultraDarkFrom {
            ultraDarkEnabled = true
            self.ultraDarkFrom = ultraDarkFrom
        }
    }

    /// How rules 3 and 5 changed what the times alone suggest, for a note in Settings.
    public enum Adjustment: Equatable, Sendable {
        /// Light and dark start at the same time: dark all day.
        case noLightPeriod
        /// The ultra dark time lies in the light period: ultra dark starts at `darkFrom`.
        case ultraDarkStartsWithDark
    }

    public var adjustment: Adjustment? {
        if lightFrom == darkFrom { return .noLightPeriod }
        if ultraDarkEnabled, ultraDarkFrom != darkFrom, effectiveUltraDarkFrom == darkFrom { return .ultraDarkStartsWithDark }
        return nil
    }

    /// When ultra dark starts after rule 3; nil when it is off.
    public var effectiveUltraDarkFrom: ClockTime? {
        guard ultraDarkEnabled else { return nil }
        let light = Self.forward(lightFrom.minutes, darkFrom.minutes)
        return light > 0 && Self.forward(lightFrom.minutes, ultraDarkFrom.minutes) < light ? darkFrom : ultraDarkFrom
    }

    /// The mode at `date` (never `.system`).
    public func mode(at date: Date, calendar: Calendar) -> ResolvedAppearance {
        let parts = calendar.dateComponents([.hour, .minute, .second], from: date)
        let seconds = (parts.hour ?? 0) * 3600 + (parts.minute ?? 0) * 60 + (parts.second ?? 0)
        let light = lightFrom.minutes * 60, dark = darkFrom.minutes * 60
        let lightLength = Self.forward(light, dark, day: 86400)
        if Self.forward(light, seconds, day: 86400) < lightLength { return .light }
        guard let ultra = effectiveUltraDarkFrom else { return .dark }
        return Self.forward(dark, seconds, day: 86400) >= Self.forward(dark, ultra.minutes * 60, day: 86400) ? .ultraDark : .dark
    }

    /// The first moment after `date` at which the mode changes; nil when it
    /// never does (equal light and dark times without ultra dark).
    public func nextBoundary(after date: Date, calendar: Calendar) -> Date? {
        let current = mode(at: date, calendar: calendar)
        let starts = [lightFrom, darkFrom] + (effectiveUltraDarkFrom.map { [$0] } ?? [])
        // `.nextTime`: a start that a daylight-saving jump skips happens at the first time after it.
        let candidates = starts.compactMap { start in
            calendar.nextDate(after: date, matching: DateComponents(hour: start.hour, minute: start.minute, second: 0),
                              matchingPolicy: .nextTime)
        }.sorted()
        // The mode is constant between consecutive starts, so the first one with another mode is the change.
        return candidates.first { mode(at: $0, calendar: calendar) != current }
    }

    /// The mode at `date` and when it ends, for "Now: Dark until 23:00".
    public func status(at date: Date, calendar: Calendar) -> (mode: ResolvedAppearance, until: Date?) {
        (mode(at: date, calendar: calendar), nextBoundary(after: date, calendar: calendar))
    }

    /// Distance from `a` forward to `b` on a clock of `day` units.
    private static func forward(_ a: Int, _ b: Int, day: Int = 1440) -> Int {
        ((b - a) % day + day) % day
    }

    // MARK: Persistence

    /// The stored format's version. Version 1: `lightFrom`, `darkFrom`,
    /// `ultraDarkFrom` as `HH:mm`, `ultraDark` as a bool.
    public static let version = 1

    /// A property list dictionary, readable with `defaults read`.
    public var storedValue: [String: Any] {
        [
            "version": Self.version,
            "lightFrom": lightFrom.text,
            "darkFrom": darkFrom.text,
            "ultraDark": ultraDarkEnabled,
            "ultraDarkFrom": ultraDarkFrom.text,
        ]
    }

    /// Lenient: anything that is not a dictionary gives the defaults, and each
    /// missing, mistyped or out-of-range field keeps its default. Unknown keys
    /// (from a newer version) are ignored; the known ones are still read.
    /// Times may also be minutes since midnight (0..<1440).
    public init(storedValue: Any?) {
        self.init()
        guard let stored = storedValue as? [String: Any] else { return }
        func time(_ key: String) -> ClockTime? {
            switch stored[key] {
            case let text as String: ClockTime(parsing: text)
            case let minutes as Int where (0..<1440).contains(minutes): ClockTime(minutes: minutes)
            default: nil
            }
        }
        if let t = time("lightFrom") { lightFrom = t }
        if let t = time("darkFrom") { darkFrom = t }
        if let t = time("ultraDarkFrom") { ultraDarkFrom = t }
        if let on = stored["ultraDark"] as? Bool { ultraDarkEnabled = on }
    }
}
