import Foundation

// Demo mode: Pimento against `DemoAzure`, an in-memory simulator of every
// ARM and sign-in endpoint it uses, with synthetic data (Microsoft's fictitious
// Contoso, Fabrikam, …). Nothing leaves the machine, and nothing of the
// user's own data is read or written: the demo has its own defaults suite,
// its own folder for presets, history and sign-in settings, and an in-memory
// token store.

public enum DemoMode {
    /// `--demo`: on the app's command line, and a global flag of `pimento`.
    public static let argument = "--demo"
    /// `PIMENTO_DEMO=1` turns demo mode on (`0`, `false`, `no`, `off` or empty: off).
    public static let environmentVariable = "PIMENTO_DEMO"
    /// `PIMENTO_DEMO_CLOCK=10:30` freezes the demo clock at that time today
    /// (screenshots); `live` (the default) runs it with the real time.
    public static let clockVariable = "PIMENTO_DEMO_CLOCK"
    /// `PIMENTO_DEMO_SPEED=60`: the demo clock runs that many times faster
    /// than the real one (expiry, approvals and scheduled starts come sooner).
    public static let speedVariable = "PIMENTO_DEMO_SPEED"
    /// The app's defaults in demo mode: never the real `UserDefaults.standard`.
    public static let defaultsSuite = "io.github.melvin2306.pimento.demo"
    /// The folder, inside Pimento's data folder, that holds the app's demo files.
    public static let folderName = "Demo"
    /// The time "Freeze clock" shows: 10:30.
    public static let tidyMinutes = 10 * 60 + 30

    /// Whether `arguments` or `environment` ask for demo mode.
    public static func isRequested(arguments: [String], environment: [String: String]) -> Bool {
        arguments.contains(argument) || isOn(environment[environmentVariable])
    }

    /// `1`, `true`, `yes`, `on` (any case).
    public static func isOn(_ value: String?) -> Bool {
        guard let v = value?.trimmingCharacters(in: .whitespaces).lowercased() else { return false }
        return ["1", "true", "yes", "on"].contains(v)
    }

    /// `<Pimento's data folder>/Demo`: the app's demo presets, history and
    /// sign-in settings (never the real files next to it).
    public static func dataDirectory(
        environment: [String: String] = ProcessInfo.processInfo.environment, home: String = NSHomeDirectory(),
        platform: HostPlatform = .current
    ) -> URL {
        URL(fileURLWithPath: platform.join(PimentoPaths.dataDirectoryPath(environment: environment, home: home, platform: platform), folderName),
            isDirectory: true)
    }

    /// Minutes after midnight from `10:30` / `9:05`; nil for anything else.
    public static func parseClock(_ value: String?) -> Int? {
        guard let parts = value?.trimmingCharacters(in: .whitespaces).split(separator: ":"), parts.count == 2,
              let h = Int(parts[0]), let m = Int(parts[1]), (0..<24).contains(h), (0..<60).contains(m), parts[1].count == 2
        else { return nil }
        return h * 60 + m
    }
}

/// The demo's own settings (Demo menu, and Settings › General in demo mode),
/// kept in the demo defaults suite.
public struct DemoOptions: Equatable, Sendable {
    /// Hides the small "Demo" badge (for screenshots).
    public var hideBadge = false
    /// Keeps the demo's presets, history and settings from one demo start to
    /// the next; off: every start begins with the original demo data.
    public var keepChanges = false
    /// Minutes after midnight the demo clock stays at (`DemoMode.tidyMinutes`
    /// = 10:30); nil: the clock runs.
    public var frozenAt: Int?
    /// How many times faster than real time the demo clock runs (1…3600).
    public var speed: Double = 1

    public static let speeds: [Double] = [1, 10, 60, 600]

    public init(hideBadge: Bool = false, keepChanges: Bool = false, frozenAt: Int? = nil, speed: Double = 1) {
        self.hideBadge = hideBadge
        self.keepChanges = keepChanges
        self.frozenAt = frozenAt
        self.speed = speed
    }

    enum Key {
        static let hideBadge = "demo.hideBadge"
        static let keepChanges = "demo.keepChanges"
        static let frozenAt = "demo.frozenAt"
        static let speed = "demo.speed"
        static let all = [hideBadge, keepChanges, frozenAt, speed]
    }

    public static func load(from store: PreferenceStore) -> DemoOptions {
        var o = DemoOptions()
        o.hideBadge = store.object(forKey: Key.hideBadge) as? Bool ?? false
        o.keepChanges = store.object(forKey: Key.keepChanges) as? Bool ?? false
        o.frozenAt = (store.object(forKey: Key.frozenAt) as? Int).flatMap { (0..<1440).contains($0) ? $0 : nil }
        let speed = store.object(forKey: Key.speed) as? Double ?? 1
        o.speed = (1...3600).contains(speed) ? speed : 1
        return o
    }

    public func save(to store: PreferenceStore) {
        store.set(hideBadge, forKey: Key.hideBadge)
        store.set(keepChanges, forKey: Key.keepChanges)
        if let frozenAt { store.set(frozenAt, forKey: Key.frozenAt) } else { store.removeObject(forKey: Key.frozenAt) }
        store.set(speed, forKey: Key.speed)
    }

    /// The options from `PIMENTO_DEMO_CLOCK` / `PIMENTO_DEMO_SPEED`, over `self`.
    public func applying(environment: [String: String]) -> DemoOptions {
        var o = self
        if let clock = environment[DemoMode.clockVariable]?.trimmingCharacters(in: .whitespaces), !clock.isEmpty {
            o.frozenAt = clock.lowercased() == "live" ? nil : (DemoMode.parseClock(clock) ?? o.frozenAt)
        }
        if let speed = environment[DemoMode.speedVariable].flatMap({ Double($0.trimmingCharacters(in: .whitespaces)) }),
           (1...3600).contains(speed) {
            o.speed = speed
        }
        return o
    }

    /// The demo clock these options describe, starting now.
    public func makeClock(realNow: @escaping @Sendable () -> Date = { Date() }, timeZone: TimeZone = .current) -> DemoClock {
        guard let frozenAt else { return DemoClock(rate: speed, realNow: realNow) }
        return DemoClock(start: DemoClock.today(atMinutes: frozenAt, now: realNow(), timeZone: timeZone), rate: 0, realNow: realNow)
    }
}
