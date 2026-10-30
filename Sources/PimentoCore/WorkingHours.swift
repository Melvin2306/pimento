import Foundation

/// When keep-alive may renew roles: some days of the week, from a time to a
/// time, in local wall-clock time (Settings › Activation › Keep alive, or
/// `pimento keep-alive --days … --window …`). Mon–Fri 08:00–18:00 by default.
///
/// A window starts on each chosen day at `start` and ends at `end` that day,
/// or the next day when `end` is not after `start` (22:00–06:00 is a night
/// shift starting on the chosen day; equal times mean 24 hours).
public struct WorkingHours: Equatable, Sendable {
    /// `Calendar` weekday numbers (1 = Sunday … 7 = Saturday) on which a window starts.
    public var days: Set<Int>
    public var start: ClockTime
    public var end: ClockTime

    public static let weekdays: Set<Int> = [2, 3, 4, 5, 6]

    public init(days: Set<Int> = WorkingHours.weekdays, start: ClockTime = ClockTime(hour: 8, minute: 0),
                end: ClockTime = ClockTime(hour: 18, minute: 0)) {
        self.days = days.filter { (1...7).contains($0) }
        self.start = start
        self.end = end
    }

    /// How long a window lasts, in minutes (1 to 1440).
    public var lengthMinutes: Int {
        let d = (end.minutes - start.minutes + 1440) % 1440
        return d == 0 ? 1440 : d
    }

    /// The window that starts on the day of `day`, if that is one of `days`.
    public func window(startingOn day: Date, calendar: Calendar) -> DateInterval? {
        guard days.contains(calendar.component(.weekday, from: day)) else { return nil }
        let midnight = calendar.startOfDay(for: day)
        guard let from = calendar.date(bySettingHour: start.hour, minute: start.minute, second: 0, of: midnight) else { return nil }
        let endDay = end.minutes > start.minutes ? midnight : (calendar.date(byAdding: .day, value: 1, to: midnight) ?? midnight)
        guard let until = calendar.date(bySettingHour: end.hour, minute: end.minute, second: 0, of: endDay), until > from else { return nil }
        return DateInterval(start: from, end: until)
    }

    /// The window `date` falls in (start included, end not), if any.
    public func window(containing date: Date, calendar: Calendar) -> DateInterval? {
        let today = calendar.startOfDay(for: date)
        for offset in [0, -1] {
            guard let day = calendar.date(byAdding: .day, value: offset, to: today),
                  let w = window(startingOn: day, calendar: calendar) else { continue }
            if w.start <= date && date < w.end { return w }
        }
        return nil
    }

    /// The first window that starts after `date`; nil without working days.
    public func nextWindow(after date: Date, calendar: Calendar) -> DateInterval? {
        let today = calendar.startOfDay(for: date)
        for offset in 0...8 {
            guard let day = calendar.date(byAdding: .day, value: offset, to: today),
                  let w = window(startingOn: day, calendar: calendar) else { continue }
            if w.start > date { return w }
        }
        return nil
    }

    // MARK: Text

    /// Monday first, as people read a week.
    static let weekOrder = [2, 3, 4, 5, 6, 7, 1]
    static let shortNames = [1: "Sun", 2: "Mon", 3: "Tue", 4: "Wed", 5: "Thu", 6: "Fri", 7: "Sat"]

    public static func dayName(_ weekday: Int) -> String { shortNames[weekday] ?? "?" }

    /// `Mon–Fri`, `Mon, Wed, Fri`, `Every day`, `No days`.
    public var daysLabel: String {
        if days.isEmpty { return "No days" }
        if days.count == 7 { return "Every day" }
        var runs: [[Int]] = []
        for d in Self.weekOrder where days.contains(d) {
            if let last = runs.last?.last, Self.weekOrder.firstIndex(of: last)! + 1 == Self.weekOrder.firstIndex(of: d)! {
                runs[runs.count - 1].append(d)
            } else {
                runs.append([d])
            }
        }
        return runs.map { run in
            run.count >= 3 ? "\(Self.dayName(run.first!))–\(Self.dayName(run.last!))" : run.map(Self.dayName).joined(separator: ", ")
        }.joined(separator: ", ")
    }

    /// `Mon–Fri 08:00–18:00`.
    public var label: String { "\(daysLabel) \(start.text)–\(end.text)" }

    // MARK: Parsing (`pimento keep-alive --days … --window …`)

    static let dayWords: [String: Int] = [
        "sun": 1, "sunday": 1, "mon": 2, "monday": 2, "tue": 3, "tues": 3, "tuesday": 3, "wed": 4, "wednesday": 4,
        "thu": 5, "thur": 5, "thurs": 5, "thursday": 5, "fri": 6, "friday": 6, "sat": 7, "saturday": 7,
    ]

    /// `mon-fri`, `mon,wed,fri`, `fri-mon` (wraps), `weekdays`, `weekend`,
    /// `all` / `daily`. nil when unreadable or empty.
    public static func parseDays(_ text: String) -> Set<Int>? {
        let s = text.trimmingCharacters(in: .whitespaces).lowercased()
        switch s {
        case "all", "daily", "every-day", "everyday": return Set(1...7)
        case "weekdays", "workdays": return weekdays
        case "weekend", "weekends": return [1, 7]
        default: break
        }
        var result = Set<Int>()
        for part in s.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) }) {
            let ends = part.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
            switch ends.count {
            case 1:
                guard let d = dayWords[ends[0]] else { return nil }
                result.insert(d)
            case 2:
                guard let a = dayWords[ends[0]], let b = dayWords[ends[1]],
                      var i = weekOrder.firstIndex(of: a), let j = weekOrder.firstIndex(of: b) else { return nil }
                result.insert(weekOrder[i])
                while i != j {
                    i = (i + 1) % 7
                    result.insert(weekOrder[i])
                }
            default:
                return nil
            }
        }
        return result.isEmpty ? nil : result
    }

    /// `08:00-18:00`, `8-18`, `22:00-06:00`. nil when unreadable.
    public static func parseWindow(_ text: String) -> (start: ClockTime, end: ClockTime)? {
        let parts = text.trimmingCharacters(in: .whitespaces).split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 2, let a = ScheduleTime.clock(String(parts[0])), let b = ScheduleTime.clock(String(parts[1])) else { return nil }
        return (ClockTime(hour: a.0, minute: a.1), ClockTime(hour: b.0, minute: b.1))
    }

    // MARK: Persistence

    /// The stored format's version. Version 1: `days` (weekday numbers),
    /// `start` and `end` as `HH:mm`.
    public static let version = 1

    /// A property list dictionary, readable with `defaults read`.
    public var storedValue: [String: Any] {
        ["version": Self.version, "days": days.sorted(), "start": start.text, "end": end.text]
    }

    /// Lenient: anything unreadable keeps its default.
    public init(storedValue: Any?) {
        self.init()
        guard let stored = storedValue as? [String: Any] else { return }
        if let list = stored["days"] as? [Int] { days = Set(list.filter { (1...7).contains($0) }) }
        if let text = stored["start"] as? String, let t = ClockTime(parsing: text) { start = t }
        if let text = stored["end"] as? String, let t = ClockTime(parsing: text) { end = t }
    }
}
