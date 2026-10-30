import Foundation

/// The demo's time: the real time, shifted and sped up as asked. With rate
/// 0 it stands still (a frozen 10:30 for screenshots, or a test's manual
/// clock that only `advance(by:)` moves).
public final class DemoClock: @unchecked Sendable {
    private let lock = NSLock()
    private let realNow: @Sendable () -> Date
    /// Demo time `anchorDemo` was at real time `anchorReal`.
    private var anchorReal: Date
    private var anchorDemo: Date
    private var storedRate: Double

    /// `start`: what the demo clock shows now (nil: the real time); `rate`:
    /// demo seconds per real second (0: frozen).
    public init(start: Date? = nil, rate: Double = 1, realNow: @escaping @Sendable () -> Date = { Date() }) {
        self.realNow = realNow
        let real = realNow()
        anchorReal = real
        anchorDemo = start ?? real
        storedRate = max(0, rate)
    }

    /// A clock that only moves with `advance(by:)`.
    public static func manual(at date: Date) -> DemoClock { DemoClock(start: date, rate: 0) }

    public func now() -> Date {
        lock.lock()
        defer { lock.unlock() }
        return anchorDemo.addingTimeInterval(realNow().timeIntervalSince(anchorReal) * storedRate)
    }

    /// Demo seconds per real second.
    public var rate: Double {
        get { lock.withLock { storedRate } }
        set {
            lock.lock()
            defer { lock.unlock() }
            let real = realNow()
            anchorDemo = anchorDemo.addingTimeInterval(real.timeIntervalSince(anchorReal) * storedRate)
            anchorReal = real
            storedRate = max(0, newValue)
        }
    }

    public var isFrozen: Bool { rate == 0 }

    /// Moves the demo time forward (tests, and the CLI's waits).
    public func advance(by seconds: TimeInterval) {
        lock.lock()
        defer { lock.unlock() }
        anchorDemo = anchorDemo.addingTimeInterval(max(0, seconds))
    }

    /// Real seconds until the demo clock shows `date` (at least 1); nil when
    /// the clock is frozen and never gets there.
    public func realInterval(until date: Date) -> TimeInterval? {
        let rate = self.rate
        guard rate > 0 else { return nil }
        return max(1, date.timeIntervalSince(now()) / rate)
    }

    /// `minutes` after midnight on the day of `now`, in `timeZone`.
    public static func today(atMinutes minutes: Int, now: Date, timeZone: TimeZone = .current) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let midnight = calendar.startOfDay(for: now)
        return calendar.date(byAdding: .minute, value: minutes, to: midnight) ?? now
    }
}
