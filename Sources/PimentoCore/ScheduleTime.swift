import Foundation

/// When a scheduled activation starts, from what people type (`--at`).
///
/// PIM accepts a `SelfActivate` with a future `scheduleInfo.startDateTime`
/// (status `Granted` until it starts), also while the role is active, and
/// refuses a start more than a month ahead (`ScheduleStartTimeTooFarAhead`:
/// "Schedule start time should be earlier than a month later").
///
/// Grammar (case-insensitive, local time zone unless a zone is given):
///
/// | Input                          | Meaning                                          |
/// |--------------------------------|--------------------------------------------------|
/// | `now`                          | right away (no schedule)                         |
/// | `+90m`, `+1h`, `+1h30m`, `+2d` | from now; units `d`, `h`, `m`/`min`              |
/// | `08:00`, `8:30`, `8`           | the next time it is that time (today or tomorrow)|
/// | `today 17:00`                  | today                                            |
/// | `tomorrow 08:00`, `tomorrow08:00` | tomorrow                                      |
/// | `mon 08:00` … `sunday 9:15`    | the next such weekday (today if still ahead)     |
/// | `workday 08:00`                | the next working day (Mon–Fri) after today       |
/// | `2026-11-02 08:00`, `2026-11-02T08:00` | that local date and time                 |
/// | `2026-11-02T08:00:00Z`, `…+01:00` | ISO 8601 with a zone                          |
public enum ScheduleTime {
    /// PIM refuses a start more than a month ahead; 30 days is safe for every month.
    public static let maxDaysAhead = 30
    /// ARM's error code for a start beyond that.
    public static let tooFarAheadCode = "ScheduleStartTimeTooFarAhead"
    /// A start less than this ahead of the request counts as "now".
    public static let immediateSlack: TimeInterval = 60

    /// The start `text` stands for, checked against `now`: nil for `now`.
    public static func resolve(_ text: String, now: Date, timeZone: TimeZone = .current) throws -> Date? {
        guard let date = try parse(text, now: now, timeZone: timeZone) else { return nil }
        try validate(date, now: now, text: text)
        return date
    }

    /// Throws when `date` is not in the future or more than `maxDaysAhead` days ahead.
    public static func validate(_ date: Date, now: Date, text: String? = nil) throws {
        let label = text ?? AzureDate.format(date)
        guard date > now else { throw ScheduleTimeError.inThePast(label) }
        guard date <= now.addingTimeInterval(TimeInterval(maxDaysAhead) * 86400) else {
            throw ScheduleTimeError.tooFarAhead(label)
        }
    }

    /// The date `text` stands for, without range checks: nil for `now`.
    public static func parse(_ text: String, now: Date, timeZone: TimeZone = .current) throws -> Date? {
        let raw = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let s = raw.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !s.isEmpty else { throw ScheduleTimeError.unreadable(raw) }
        if s == "now" { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone

        if s.hasPrefix("+") {
            guard let seconds = relativeSeconds(String(s.dropFirst())), seconds > 0 else { throw ScheduleTimeError.unreadable(raw) }
            return now.addingTimeInterval(seconds)
        }
        if let date = try absolute(s, raw: raw, calendar: calendar) { return date }

        // A day word, optionally glued to the time: `tomorrow08:00`.
        let letters = s.prefix { $0.isLetter || $0 == "-" }
        let rest = s.dropFirst(letters.count).trimmingCharacters(in: .whitespaces)
        if letters.isEmpty {
            guard let (h, m) = clock(rest) else { throw ScheduleTimeError.unreadable(raw) }
            guard let today = at(h, m, on: now, calendar) else { throw ScheduleTimeError.unreadable(raw) }
            return today > now ? today : at(h, m, on: add(days: 1, to: now, calendar), calendar)
        }
        let word = String(letters)
        let known = dayWords.contains(word) || weekdays[word] != nil
        guard let (h, m) = clock(rest) else {
            throw rest.isEmpty && known ? ScheduleTimeError.missingTime(raw) : ScheduleTimeError.unreadable(raw)
        }
        switch word {
        case "today":
            return at(h, m, on: now, calendar)
        case "tomorrow", "tmrw":
            return at(h, m, on: add(days: 1, to: now, calendar), calendar)
        case "workday", "next-workday", "weekday":
            return at(h, m, on: nextWorkingDay(after: now, calendar), calendar)
        default:
            guard let weekday = weekdays[word] else { throw ScheduleTimeError.unreadable(raw) }
            for offset in 0...7 {
                let day = add(days: offset, to: now, calendar)
                guard calendar.component(.weekday, from: day) == weekday, let date = at(h, m, on: day, calendar) else { continue }
                if date > now { return date }
            }
            throw ScheduleTimeError.unreadable(raw)
        }
    }

    static let dayWords: Set<String> = ["today", "tomorrow", "tmrw", "workday", "next-workday", "weekday"]

    /// `Calendar` weekday numbers (Sunday = 1).
    static let weekdays: [String: Int] = [
        "sun": 1, "sunday": 1, "mon": 2, "monday": 2, "tue": 3, "tues": 3, "tuesday": 3,
        "wed": 4, "wednesday": 4, "thu": 5, "thur": 5, "thurs": 5, "thursday": 5,
        "fri": 6, "friday": 6, "sat": 7, "saturday": 7,
    ]

    /// `1h30m`, `90m`, `90min`, `2d`, `1d 2h` → seconds; nil when unreadable.
    static func relativeSeconds(_ s: String) -> TimeInterval? {
        var total: TimeInterval = 0
        var number = ""
        var unit = ""
        var parts = 0
        func flush() -> Bool {
            guard let n = Int(number) else { return false }
            let seconds: TimeInterval
            switch unit {
            case "d", "day", "days": seconds = 86400
            case "h", "hr", "hrs", "hour", "hours": seconds = 3600
            case "m", "min", "mins", "minute", "minutes": seconds = 60
            default: return false
            }
            total += TimeInterval(n) * seconds
            number = ""
            unit = ""
            parts += 1
            return true
        }
        for ch in s where ch != " " {
            if ch.isASCII, ch.isNumber {
                if !unit.isEmpty { guard flush() else { return nil } }
                number.append(ch)
            } else if ch.isLetter {
                guard !number.isEmpty else { return nil }
                unit.append(ch)
            } else {
                return nil
            }
        }
        guard !number.isEmpty || !unit.isEmpty else { return parts > 0 ? total : nil }
        guard flush() else { return nil }
        return total
    }

    /// `08:00`, `8:00`, `8`, `0800` → (hour, minute).
    static func clock(_ s: String) -> (Int, Int)? {
        let t = s.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty, t.allSatisfy({ ($0.isASCII && $0.isNumber) || $0 == ":" }) else { return nil }
        let pieces = t.split(separator: ":", omittingEmptySubsequences: false)
        let h: Int?, m: Int?
        switch pieces.count {
        case 1 where t.count <= 2: (h, m) = (Int(t), 0)
        case 1 where t.count == 4: (h, m) = (Int(t.prefix(2)), Int(t.suffix(2)))
        case 2 where pieces[1].count == 2: (h, m) = (Int(pieces[0]), Int(pieces[1]))
        default: return nil
        }
        guard let h, let m, (0...23).contains(h), (0...59).contains(m) else { return nil }
        return (h, m)
    }

    /// `2026-11-02 08:00`, `2026-11-02T08:00[:SS[.fff]][Z|±HH:MM]`. nil when `s` is not a date.
    static func absolute(_ s: String, raw: String, calendar: Calendar) throws -> Date? {
        let pattern = #"^(\d{4})-(\d{2})-(\d{2})(?:[t ](\d{1,2}):(\d{2})(?::(\d{2})(?:\.\d+)?)?)?\s*(z|[+-]\d{2}:?\d{2})?$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) else { return nil }
        func group(_ i: Int) -> String? {
            guard let r = Range(match.range(at: i), in: s) else { return nil }
            return String(s[r])
        }
        guard group(4) != nil else { throw ScheduleTimeError.missingTime(raw) }
        var c = DateComponents()
        c.year = Int(group(1)!)
        c.month = Int(group(2)!)
        c.day = Int(group(3)!)
        c.hour = Int(group(4)!)
        c.minute = Int(group(5)!)
        c.second = group(6).flatMap(Int.init) ?? 0
        guard let month = c.month, (1...12).contains(month), let day = c.day, (1...31).contains(day),
              let hour = c.hour, (0...23).contains(hour), let minute = c.minute, (0...59).contains(minute),
              let second = c.second, (0...59).contains(second) else { throw ScheduleTimeError.unreadable(raw) }
        var cal = calendar
        if let zone = group(7) {
            guard let tz = timeZone(zone) else { throw ScheduleTimeError.unreadable(raw) }
            cal.timeZone = tz
        }
        guard let date = cal.date(from: c),
              cal.component(.day, from: date) == day else { throw ScheduleTimeError.unreadable(raw) }
        return date
    }

    static func timeZone(_ zone: String) -> TimeZone? {
        if zone == "z" { return TimeZone(identifier: "UTC") }
        let sign = zone.hasPrefix("-") ? -1 : 1
        let digits = zone.dropFirst().replacingOccurrences(of: ":", with: "")
        guard digits.count == 4, let h = Int(digits.prefix(2)), let m = Int(digits.suffix(2)), h <= 14, m < 60 else { return nil }
        return TimeZone(secondsFromGMT: sign * (h * 3600 + m * 60))
    }

    static func at(_ hour: Int, _ minute: Int, on day: Date, _ calendar: Calendar) -> Date? {
        calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day)
    }

    static func add(days: Int, to date: Date, _ calendar: Calendar) -> Date {
        calendar.date(byAdding: .day, value: days, to: calendar.startOfDay(for: date)) ?? date.addingTimeInterval(TimeInterval(days) * 86400)
    }

    /// The next Monday–Friday after `date`'s day.
    static func nextWorkingDay(after date: Date, _ calendar: Calendar) -> Date {
        var day = add(days: 1, to: date, calendar)
        while [1, 7].contains(calendar.component(.weekday, from: day)) { day = add(days: 1, to: day, calendar) }
        return day
    }

    // MARK: Presets and labels

    /// The quick choices of the app's start menu.
    public enum Preset: String, CaseIterable, Sendable {
        case inOneHour, tomorrowMorning, nextWorkingDayMorning

        public var title: String {
            switch self {
            case .inOneHour: "In 1 hour"
            case .tomorrowMorning: "Tomorrow 08:00"
            case .nextWorkingDayMorning: "Next working day 08:00"
            }
        }

        public func date(now: Date, timeZone: TimeZone = .current) -> Date {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = timeZone
            switch self {
            case .inOneHour:
                // On the next whole minute, so it reads as a time.
                let t = now.addingTimeInterval(3600).timeIntervalSinceReferenceDate
                return Date(timeIntervalSinceReferenceDate: (t / 60).rounded(.up) * 60)
            case .tomorrowMorning:
                return ScheduleTime.at(8, 0, on: ScheduleTime.add(days: 1, to: now, calendar), calendar)!
            case .nextWorkingDayMorning:
                return ScheduleTime.at(8, 0, on: ScheduleTime.nextWorkingDay(after: now, calendar), calendar)!
            }
        }
    }

    /// `today 14:00`, `Tue 08:00` (within a week), `Tue 10 Nov 08:00` (later).
    public static func label(_ date: Date, now: Date, timeZone: TimeZone = .current) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        if calendar.isDate(date, inSameDayAs: now) {
            formatter.dateFormat = "HH:mm"
            return "today " + formatter.string(from: date)
        }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: date)).day ?? 0
        formatter.dateFormat = (1...6).contains(days) ? "EEE HH:mm" : "EEE d MMM HH:mm"
        return formatter.string(from: date)
    }
}

public enum ScheduleTimeError: Error, Equatable, LocalizedError {
    case unreadable(String)
    case missingTime(String)
    case inThePast(String)
    case tooFarAhead(String)

    public var errorDescription: String? {
        switch self {
        case .unreadable(let s):
            "Cannot read the start time “\(s)”. Use e.g. +1h, 08:00, tomorrow 08:00, mon 9:30, workday 08:00, "
                + "2026-11-02 08:00 or an ISO 8601 time with a zone."
        case .missingTime(let s): "“\(s)” needs a time of day, e.g. “\(s) 08:00”."
        case .inThePast(let s): "The start time “\(s)” is not in the future."
        case .tooFarAhead(let s):
            "The start time “\(s)” is more than \(ScheduleTime.maxDaysAhead) days ahead; PIM accepts a start up to a month ahead."
        }
    }
}
