import Foundation
import Testing
@testable import PimentoCore

@Suite("Appearance schedule")
struct AppearanceScheduleTests {
    /// Berlin: daylight saving starts 2026-03-29 02:00 → 03:00, ends 2026-10-25 03:00 → 02:00.
    static let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/Berlin")!
        return c
    }()

    static func at(_ hour: Int, _ minute: Int = 0, _ second: Int = 0, day: Int = 29, month: Int = 10, calendar: Calendar = calendar) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour, minute: minute, second: second))!
    }

    static func t(_ hour: Int, _ minute: Int = 0) -> ClockTime { ClockTime(hour: hour, minute: minute) }

    func mode(_ s: AppearanceSchedule, _ hour: Int, _ minute: Int = 0, _ second: Int = 0) -> ResolvedAppearance {
        s.mode(at: Self.at(hour, minute, second), calendar: Self.calendar)
    }

    @Test func defaultsAreSevenAndNineteenWithoutUltraDark() {
        let s = AppearanceSchedule()
        #expect(s.lightFrom == Self.t(7) && s.darkFrom == Self.t(19) && s.ultraDarkFrom == Self.t(23))
        #expect(!s.ultraDarkEnabled)
        #expect(mode(s, 0) == .dark)
        #expect(mode(s, 6, 59, 59) == .dark)
        #expect(mode(s, 7) == .light, "a period starts at its minute")
        #expect(mode(s, 12) == .light)
        #expect(mode(s, 18, 59, 59) == .light)
        #expect(mode(s, 19) == .dark)
        #expect(mode(s, 23, 30) == .dark, "ultra dark is off")
        #expect(s.adjustment == nil)
    }

    @Test func ultraDarkIsALaterStageOfTheNight() {
        var s = AppearanceSchedule()
        s.ultraDarkEnabled = true
        #expect(mode(s, 18) == .light)
        #expect(mode(s, 19) == .dark)
        #expect(mode(s, 22, 59, 59) == .dark)
        #expect(mode(s, 23) == .ultraDark)
        #expect(mode(s, 0) == .ultraDark, "across midnight")
        #expect(mode(s, 6, 59) == .ultraDark)
        #expect(mode(s, 7) == .light)
        #expect(s.adjustment == nil)
    }

    @Test func ultraDarkAfterMidnight() {
        let s = AppearanceSchedule(lightFrom: Self.t(7), darkFrom: Self.t(19), ultraDarkFrom: Self.t(1, 30))
        #expect(mode(s, 23) == .dark)
        #expect(mode(s, 1, 29) == .dark)
        #expect(mode(s, 1, 30) == .ultraDark)
        #expect(mode(s, 7) == .light)
    }

    @Test func periodsWrapAcrossMidnightEitherWay() {
        // Night shift: light in the evening and night, dark during the day.
        let s = AppearanceSchedule(lightFrom: Self.t(20), darkFrom: Self.t(6), ultraDarkFrom: Self.t(10))
        #expect(mode(s, 21) == .light)
        #expect(mode(s, 2) == .light)
        #expect(mode(s, 6) == .dark)
        #expect(mode(s, 9, 59) == .dark)
        #expect(mode(s, 10) == .ultraDark)
        #expect(mode(s, 19, 59) == .ultraDark)
        #expect(mode(s, 20) == .light)
    }

    @Test func ultraDarkTimeInTheLightPeriodStartsWithDark() {
        let s = AppearanceSchedule(lightFrom: Self.t(7), darkFrom: Self.t(19), ultraDarkFrom: Self.t(18))
        #expect(s.adjustment == .ultraDarkStartsWithDark)
        #expect(s.effectiveUltraDarkFrom == Self.t(19))
        #expect(mode(s, 18, 30) == .light, "never ultra dark while it is light")
        #expect(mode(s, 19) == .ultraDark)
        #expect(mode(s, 3) == .ultraDark)
        #expect(mode(s, 7) == .light)
        // Also a time right after light starts, and one equal to it.
        for ultra in [Self.t(7, 1), Self.t(7), Self.t(12)] {
            let s2 = AppearanceSchedule(lightFrom: Self.t(7), darkFrom: Self.t(19), ultraDarkFrom: ultra)
            #expect(s2.adjustment == .ultraDarkStartsWithDark, "\(ultra.text)")
            #expect(mode(s2, 19) == .ultraDark && mode(s2, 12) == .light, "\(ultra.text)")
        }
    }

    @Test func ultraDarkJustBeforeLightIsAMinute() {
        let s = AppearanceSchedule(lightFrom: Self.t(7), darkFrom: Self.t(19), ultraDarkFrom: Self.t(6, 59))
        #expect(s.adjustment == nil)
        #expect(mode(s, 6, 58) == .dark)
        #expect(mode(s, 6, 59) == .ultraDark)
        #expect(mode(s, 7) == .light)
    }

    @Test func ultraDarkAtDarkReplacesDark() {
        let s = AppearanceSchedule(lightFrom: Self.t(7), darkFrom: Self.t(19), ultraDarkFrom: Self.t(19))
        #expect(s.adjustment == nil)
        #expect(mode(s, 18, 59) == .light)
        #expect(mode(s, 19) == .ultraDark)
        #expect(mode(s, 6) == .ultraDark)
        #expect(s.nextBoundary(after: Self.at(20), calendar: Self.calendar) == Self.at(7, day: 30))
    }

    @Test func equalLightAndDarkMeansDarkAllDay() {
        var s = AppearanceSchedule(lightFrom: Self.t(8), darkFrom: Self.t(8))
        #expect(s.adjustment == .noLightPeriod)
        for hour in [0, 7, 8, 12, 23] { #expect(mode(s, hour) == .dark, "\(hour)") }
        #expect(s.nextBoundary(after: Self.at(12), calendar: Self.calendar) == nil, "nothing ever changes")
        #expect(s.status(at: Self.at(12), calendar: Self.calendar).until == nil)

        s.ultraDarkEnabled = true
        s.ultraDarkFrom = Self.t(22)
        #expect(mode(s, 21, 59) == .dark)
        #expect(mode(s, 22) == .ultraDark)
        #expect(mode(s, 7, 59) == .ultraDark)
        #expect(mode(s, 8) == .dark)
        #expect(s.nextBoundary(after: Self.at(12), calendar: Self.calendar) == Self.at(22))
        #expect(s.nextBoundary(after: Self.at(23), calendar: Self.calendar) == Self.at(8, day: 30))

        s.ultraDarkFrom = Self.t(8)
        for hour in [0, 8, 12] { #expect(mode(s, hour) == .ultraDark, "ultra dark at the shared time: ultra dark all day") }
    }

    @Test func nextBoundaryIsTheNextChange() {
        var s = AppearanceSchedule()
        let next = { (date: Date) in s.nextBoundary(after: date, calendar: Self.calendar) }
        #expect(next(Self.at(12)) == Self.at(19))
        #expect(next(Self.at(19)) == Self.at(7, day: 30), "at a boundary: the following one")
        #expect(next(Self.at(18, 59, 59)) == Self.at(19))
        #expect(next(Self.at(3)) == Self.at(7))
        s.ultraDarkEnabled = true
        #expect(next(Self.at(20)) == Self.at(23))
        #expect(next(Self.at(23, 30)) == Self.at(7, day: 30))
        #expect(next(Self.at(5)) == Self.at(7))
        // An ultra dark time moved to dark (rule 3) is no extra boundary.
        s.ultraDarkFrom = Self.t(18)
        #expect(next(Self.at(12)) == Self.at(19))
        #expect(next(Self.at(19)) == Self.at(7, day: 30))
    }

    @Test func statusForThePreview() {
        var s = AppearanceSchedule()
        s.ultraDarkEnabled = true
        let status = s.status(at: Self.at(20), calendar: Self.calendar)
        #expect(status.mode == .dark)
        #expect(status.until == Self.at(23))
    }

    /// Between now and the next boundary the mode does not change, and at it it does.
    @Test func modeIsConstantUntilTheNextBoundary() {
        let times = [0, 7 * 60, 7 * 60 + 1, 12 * 60, 19 * 60, 23 * 60, 23 * 60 + 59].map(ClockTime.init(minutes:))
        var checked = 0
        for light in times {
            for dark in times {
                for ultra in [nil] + times {
                    let s = AppearanceSchedule(lightFrom: light, darkFrom: dark, ultraDarkFrom: ultra)
                    var now = Self.at(0)
                    for _ in 0..<(24 * 4) {
                        now += 15 * 60
                        let current = s.mode(at: now, calendar: Self.calendar)
                        guard let next = s.nextBoundary(after: now, calendar: Self.calendar) else {
                            for hours in stride(from: 1.0, through: 24, by: 1) {
                                #expect(s.mode(at: now + hours * 3600, calendar: Self.calendar) == current)
                            }
                            continue
                        }
                        #expect(next > now && next <= now + 86400)
                        #expect(s.mode(at: next - 1, calendar: Self.calendar) == current)
                        #expect(s.mode(at: now + (next.timeIntervalSince(now)) / 2, calendar: Self.calendar) == current)
                        #expect(s.mode(at: next, calendar: Self.calendar) != current, "\(light.text) \(dark.text) \(ultra?.text ?? "-")")
                        checked += 1
                    }
                }
            }
        }
        #expect(checked > 10000)
    }

    @Test func daylightSavingTime() {
        // Spring forward: 02:30 does not exist on 2026-03-29; light starts at 03:00 instead.
        let s = AppearanceSchedule(lightFrom: Self.t(2, 30), darkFrom: Self.t(19))
        let before = Self.at(1, day: 29, month: 3)
        #expect(s.mode(at: before, calendar: Self.calendar) == .dark)
        let next = s.nextBoundary(after: before, calendar: Self.calendar)
        #expect(next == Self.at(3, day: 29, month: 3))
        #expect(next.map { $0.timeIntervalSince(before) } == 3600, "01:00 → 03:00 is one real hour")
        #expect(next.map { s.mode(at: $0, calendar: Self.calendar) } == .light)

        // Fall back: 2026-10-25 has 25 hours; light still starts at 07:00 local.
        let evening = Self.at(20, day: 24)
        let morning = AppearanceSchedule().nextBoundary(after: evening, calendar: Self.calendar)
        #expect(morning == Self.at(7, day: 25))
        let hours = (morning ?? evening).timeIntervalSince(evening) / 3600
        #expect(hours == 12, "11 wall-clock hours plus the repeated one")
    }

    @Test func wallClockTimeInTheCalendarsTimeZone() {
        let s = AppearanceSchedule()
        var tokyo = Calendar(identifier: .gregorian)
        tokyo.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        let noonInBerlin = Self.at(12)  // 20:00 in Tokyo
        #expect(s.mode(at: noonInBerlin, calendar: Self.calendar) == .light)
        #expect(s.mode(at: noonInBerlin, calendar: tokyo) == .dark)
    }

    // MARK: Clock times

    @Test func clockTimeParsing() {
        #expect(ClockTime(parsing: "07:00") == Self.t(7))
        #expect(ClockTime(parsing: "7:05") == Self.t(7, 5))
        #expect(ClockTime(parsing: " 23:59 ") == Self.t(23, 59))
        #expect(ClockTime(parsing: "00:00") == Self.t(0))
        for bad in ["24:00", "7", "07:60", "7:5", "-1:00", "ab:cd", "", "07:00:00", "１２:００", "007:00"] {
            #expect(ClockTime(parsing: bad) == nil, "\(bad)")
        }
        #expect(Self.t(7, 5).text == "07:05")
        #expect(ClockTime(minutes: 1440) == Self.t(0))
        #expect(ClockTime(minutes: -60) == Self.t(23))
        #expect(Self.t(6) < Self.t(7))
    }

    // MARK: Persistence

    @Test func storedFormat() {
        var s = AppearanceSchedule()
        s.ultraDarkEnabled = true
        s.ultraDarkFrom = Self.t(22, 30)
        let stored = s.storedValue
        #expect(stored["version"] as? Int == 1)
        #expect(stored["lightFrom"] as? String == "07:00")
        #expect(stored["darkFrom"] as? String == "19:00")
        #expect(stored["ultraDark"] as? Bool == true)
        #expect(stored["ultraDarkFrom"] as? String == "22:30")
        #expect(AppearanceSchedule(storedValue: stored) == s)
    }

    @Test func lenientDecoding() {
        #expect(AppearanceSchedule(storedValue: nil) == AppearanceSchedule())
        #expect(AppearanceSchedule(storedValue: "07:00-19:00") == AppearanceSchedule())
        #expect(AppearanceSchedule(storedValue: [String: Any]()) == AppearanceSchedule())
        // Each bad field keeps its default; good ones are read.
        let mixed = AppearanceSchedule(storedValue: [
            "version": 1, "lightFrom": "25:00", "darkFrom": "20:15", "ultraDark": "yes", "ultraDarkFrom": 1440,
        ] as [String: Any])
        #expect(mixed.lightFrom == Self.t(7))
        #expect(mixed.darkFrom == Self.t(20, 15))
        #expect(!mixed.ultraDarkEnabled)
        #expect(mixed.ultraDarkFrom == Self.t(23))
        // Minutes since midnight are accepted too.
        #expect(AppearanceSchedule(storedValue: ["lightFrom": 390] as [String: Any]).lightFrom == Self.t(6, 30))
        // A newer version: unknown keys ignored, known ones read.
        let newer = AppearanceSchedule(storedValue: [
            "version": 7, "lightFrom": "06:00", "ultraDark": true, "sunrise": true, "weekend": ["lightFrom": "09:00"],
        ] as [String: Any])
        #expect(newer.lightFrom == Self.t(6))
        #expect(newer.ultraDarkEnabled)
        #expect(newer.darkFrom == Self.t(19))
    }

    @Test func preferencesStoreTheSchedule() {
        var p = Preferences()
        p.appearanceMode = .timeOfDay
        p.appearanceSchedule = AppearanceSchedule(lightFrom: Self.t(6, 45), darkFrom: Self.t(18), ultraDarkFrom: Self.t(22))
        let store = MemoryStore()
        p.save(to: store)
        #expect(store.values["general.appearanceMode"] as? String == "timeOfDay")
        #expect(store.values["general.appearanceSchedule"] is [String: Any])
        #expect(Preferences.load(from: store) == p)
        store.values["general.appearanceSchedule"] = 42
        #expect(Preferences.load(from: store).appearanceSchedule == AppearanceSchedule(), "unreadable: the defaults")
        Preferences.reset(in: store)
        #expect(store.values["general.appearanceSchedule"] == nil, "reset removes it")
    }

    @Test func timeOfDayModeResolvesByTheSchedule() {
        var p = Preferences()
        p.appearanceMode = .timeOfDay
        p.appearanceSchedule.ultraDarkEnabled = true
        let c = Self.calendar
        #expect(p.resolvedAppearance(at: Self.at(12), calendar: c) == .light)
        #expect(p.resolvedAppearance(at: Self.at(20), calendar: c) == .dark)
        #expect(p.resolvedAppearance(at: Self.at(23, 30), calendar: c) == .ultraDark)
        #expect(p.nextAppearanceChange(after: Self.at(20), calendar: c) == Self.at(23))
        p.theme = .azure
        #expect(p.resolvedAppearance(at: Self.at(23, 30), calendar: c) == .ultraDark)

        // Windows XP-style is light-only: light all day, nothing to schedule.
        p.theme = .windowsXP
        for hour in [0, 12, 20, 23] { #expect(p.resolvedAppearance(at: Self.at(hour), calendar: c) == .light) }
        #expect(p.nextAppearanceChange(after: Self.at(20), calendar: c) == nil)
        #expect(p.appearanceMode == .timeOfDay, "the choice is kept for the next theme")

        // Other modes never change on their own.
        p.theme = .native
        for mode in AppearanceMode.allCases where mode != .timeOfDay {
            p.appearanceMode = mode
            #expect(p.nextAppearanceChange(after: Self.at(20), calendar: c) == nil, "\(mode)")
        }
    }
}
