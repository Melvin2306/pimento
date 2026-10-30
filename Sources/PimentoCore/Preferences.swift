import Foundation

/// Where preferences live. `UserDefaults` in the app, a dictionary in tests.
public protocol PreferenceStore: AnyObject {
    func object(forKey defaultName: String) -> Any?
    func set(_ value: Any?, forKey defaultName: String)
    func removeObject(forKey defaultName: String)
}

extension UserDefaults: PreferenceStore {}

/// The look of the app's windows (Settings › Appearance). Only
/// styling changes; every control and shortcut stays the same.
public enum AppTheme: String, Codable, CaseIterable, Sendable {
    /// The standard macOS look, following the system's light or dark mode.
    case native
    /// Flat and blue, in the style of the Azure portal. Light and dark.
    case azure
    /// Beige and glossy blue, in the style of Windows XP. Always light.
    case windowsXP

    public var title: String {
        switch self {
        case .native: "Native"
        case .azure: "Azure-style"
        case .windowsXP: "Windows XP-style"
        }
    }

    /// The stored value, or `.native` for anything unknown (a theme from a
    /// newer version, a typo in `defaults write`).
    public init(storedValue: String?) {
        self = storedValue.flatMap(AppTheme.init(rawValue:)) ?? .native
    }

    /// Whether the theme has a dark variant. Windows XP-style is light-only.
    public var supportsDarkMode: Bool { self != .windowsXP }
}

/// Light or dark (Settings › Appearance), for every window.
public enum AppearanceMode: String, Codable, CaseIterable, Sendable {
    /// Follow the system's light or dark mode.
    case system
    case light
    case dark
    /// Dark with pure black backgrounds, for OLED screens and dark rooms.
    case ultraDark
    /// Light, dark or ultra dark by the clock (`Preferences.appearanceSchedule`).
    case timeOfDay

    public var title: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        case .ultraDark: "Ultra dark"
        case .timeOfDay: "By time of day"
        }
    }

    /// The stored value, or `.system` for anything unknown.
    public init(storedValue: String?) {
        self = storedValue.flatMap(AppearanceMode.init(rawValue:)) ?? .system
    }
}

/// The appearance that applies right now: the chosen mode, made concrete.
public enum ResolvedAppearance: String, Codable, CaseIterable, Sendable {
    /// Whatever the system uses.
    case system
    case light
    case dark
    /// Dark appearance plus pure black backgrounds.
    case ultraDark

    public var title: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        case .ultraDark: "Ultra dark"
        }
    }
}

/// The user's settings (Settings window, ⌘,). A plain value: loading clamps
/// anything out of range, so the app never sees an invalid setting.
public struct Preferences: Equatable, Sendable {
    /// Which tenant the app opens with when no `--tenant` / `PIMENTO_TENANT` is given.
    public enum LaunchTenant: Equatable, Sendable {
        /// The tenant last picked in the app (az's current one if none).
        case lastUsed
        /// Always az's current tenant (`az account show`).
        case azDefault
        /// Always this tenant ID or domain.
        case specific(String)
    }

    // Notifications
    public var notifyOnCompletion = true
    public var notifyOnlyOnFailure = false
    public var playSound = true
    public var expiryReminders = true
    public var reminderLeadMinutes = 10
    /// A notification when a scheduled activation starts (local, best-effort).
    public var notifyScheduledStart = true
    /// A notification when a request of yours that waited for approval is
    /// approved, denied, expires or is cancelled.
    public var notifyApprovalDecisions = true
    /// A notification when someone asks you to approve a request.
    public var notifyNewApprovals = true

    // Activation
    public var defaultHours = ActivationRequestBuilder.defaultHours
    /// Keep recently used justifications and offer them as suggestions.
    public var rememberJustifications = true
    /// Start with the most recent justification filled in.
    public var prefillLastJustification = false
    /// Ask before activating Owner roles. A safety net: on by default.
    public var confirmOwnerRoles = true
    public var maxParallelRequests = 8

    // General
    public var launchTenant: LaunchTenant = .lastUsed
    public var refreshOnLaunch = true
    /// 0 = off.
    public var autoRefreshMinutes = 0
    public var theme: AppTheme = .native
    /// Light, dark or the system's. The stored choice is kept while a
    /// light-only theme is selected; `effectiveAppearance` is what applies.
    public var appearanceMode: AppearanceMode = .system
    /// When light, dark and ultra dark apply in `.timeOfDay` mode.
    public var appearanceSchedule = AppearanceSchedule()

    // Menu bar
    /// The menu bar extra: active roles with their countdown, presets, quick actions.
    public var showInMenuBar = true
    /// The soonest end (`1:24`) next to the menu bar icon, not only the count.
    public var menuBarShowsRemainingTime = false
    /// No Dock icon or app menu: the app lives in the menu bar. Applies only
    /// while `showInMenuBar` is on (`AppPresence`).
    public var hideDockIcon = false

    public static let reminderLeadOptions = [5, 10, 15, 30]
    public static let autoRefreshOptions = [0, 1, 5, 15]
    public static let maxParallelRange = 1...16
    public static let hoursRange = 1...ActivationRequestBuilder.maxHours
    public static let recentJustificationLimit = 10

    public init() {}

    public var reminderLead: TimeInterval { TimeInterval(reminderLeadMinutes * 60) }

    /// The mode the app's windows get: always light for a light-only theme,
    /// the chosen mode otherwise.
    public var effectiveAppearance: AppearanceMode {
        theme.supportsDarkMode ? appearanceMode : .light
    }

    /// What applies at `date`: `effectiveAppearance` made concrete.
    public func resolvedAppearance(at date: Date = Date(), calendar: Calendar = .autoupdatingCurrent) -> ResolvedAppearance {
        switch effectiveAppearance {
        case .system: .system
        case .light: .light
        case .dark: .dark
        case .ultraDark: .ultraDark
        case .timeOfDay: appearanceSchedule.mode(at: date, calendar: calendar)
        }
    }

    /// When `resolvedAppearance` changes next on its own: the schedule's next
    /// boundary in `.timeOfDay` mode, nil otherwise (and for light-only themes).
    public func nextAppearanceChange(after date: Date, calendar: Calendar = .autoupdatingCurrent) -> Date? {
        effectiveAppearance == .timeOfDay ? appearanceSchedule.nextBoundary(after: date, calendar: calendar) : nil
    }

    /// Clamps numbers into range and snaps choices to the offered options.
    public func validated() -> Preferences {
        var p = self
        p.reminderLeadMinutes = Self.nearest(reminderLeadMinutes, in: Self.reminderLeadOptions)
        p.autoRefreshMinutes = autoRefreshMinutes <= 0 ? 0 : Self.nearest(autoRefreshMinutes, in: Self.autoRefreshOptions.filter { $0 > 0 })
        p.defaultHours = defaultHours.clamped(to: Self.hoursRange)
        p.maxParallelRequests = maxParallelRequests.clamped(to: Self.maxParallelRange)
        if case .specific(let id) = launchTenant, !TenantResolver.isValid(id) { p.launchTenant = .lastUsed }
        return p
    }

    /// The `saved` value for `TenantResolver.resolve` at launch.
    public func startupTenant(lastUsed: String?) -> String? {
        switch launchTenant {
        case .lastUsed: lastUsed
        case .azDefault: nil
        case .specific(let id): id
        }
    }

    /// `recent` with `justification` moved to the front, de-duplicated and capped.
    public static func recording(_ justification: String, in recent: [String], limit: Int = recentJustificationLimit) -> [String] {
        let text = justification.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return recent }
        return Array(([text] + recent.filter { $0 != text }).prefix(max(0, limit)))
    }

    private static func nearest(_ value: Int, in options: [Int]) -> Int {
        options.min { abs($0 - value) < abs($1 - value) } ?? value
    }

    // MARK: Persistence

    /// The stored key of `showInMenuBar`: the app's scene reads it directly
    /// (`@AppStorage`) to insert or remove the menu bar extra.
    public static let showInMenuBarKey = Key.showInMenuBar

    enum Key {
        static let notifyOnCompletion = "notifications.onCompletion"
        static let notifyOnlyOnFailure = "notifications.onlyOnFailure"
        static let playSound = "notifications.sound"
        static let expiryReminders = "notifications.expiryReminders"
        static let reminderLeadMinutes = "notifications.reminderLeadMinutes"
        static let notifyScheduledStart = "notifications.scheduledStart"
        static let notifyApprovalDecisions = "notifications.approvalDecisions"
        static let notifyNewApprovals = "notifications.newApprovals"
        static let defaultHours = "activation.defaultHours"
        static let rememberJustifications = "activation.rememberJustifications"
        static let prefillLastJustification = "activation.prefillLastJustification"
        static let confirmOwnerRoles = "activation.confirmOwnerRoles"
        static let maxParallelRequests = "activation.maxParallelRequests"
        static let launchTenant = "general.launchTenant"
        static let refreshOnLaunch = "general.refreshOnLaunch"
        static let autoRefreshMinutes = "general.autoRefreshMinutes"
        static let theme = "general.theme"
        static let appearanceMode = "general.appearanceMode"
        static let appearanceSchedule = "general.appearanceSchedule"
        static let showInMenuBar = "general.showInMenuBar"
        static let menuBarShowsRemainingTime = "general.menuBarRemainingTime"
        static let hideDockIcon = "general.hideDockIcon"

        static let all = [
            notifyOnCompletion, notifyOnlyOnFailure, playSound, expiryReminders, reminderLeadMinutes, notifyScheduledStart,
            notifyApprovalDecisions, notifyNewApprovals,
            defaultHours, rememberJustifications, prefillLastJustification, confirmOwnerRoles, maxParallelRequests,
            launchTenant, refreshOnLaunch, autoRefreshMinutes, theme, appearanceMode, appearanceSchedule,
            showInMenuBar, menuBarShowsRemainingTime, hideDockIcon,
        ]
    }

    /// Reads every setting; a missing or mistyped value keeps its default.
    public static func load(from store: PreferenceStore) -> Preferences {
        var p = Preferences()
        func bool(_ key: String, _ target: inout Bool) { if let v = store.object(forKey: key) as? Bool { target = v } }
        func int(_ key: String, _ target: inout Int) { if let v = store.object(forKey: key) as? Int { target = v } }
        bool(Key.notifyOnCompletion, &p.notifyOnCompletion)
        bool(Key.notifyOnlyOnFailure, &p.notifyOnlyOnFailure)
        bool(Key.playSound, &p.playSound)
        bool(Key.expiryReminders, &p.expiryReminders)
        int(Key.reminderLeadMinutes, &p.reminderLeadMinutes)
        bool(Key.notifyScheduledStart, &p.notifyScheduledStart)
        bool(Key.notifyApprovalDecisions, &p.notifyApprovalDecisions)
        bool(Key.notifyNewApprovals, &p.notifyNewApprovals)
        int(Key.defaultHours, &p.defaultHours)
        bool(Key.rememberJustifications, &p.rememberJustifications)
        bool(Key.prefillLastJustification, &p.prefillLastJustification)
        bool(Key.confirmOwnerRoles, &p.confirmOwnerRoles)
        int(Key.maxParallelRequests, &p.maxParallelRequests)
        switch store.object(forKey: Key.launchTenant) as? String {
        case nil, "lastUsed": p.launchTenant = .lastUsed
        case "azDefault": p.launchTenant = .azDefault
        case let id?: p.launchTenant = .specific(id)
        }
        bool(Key.refreshOnLaunch, &p.refreshOnLaunch)
        int(Key.autoRefreshMinutes, &p.autoRefreshMinutes)
        p.theme = AppTheme(storedValue: store.object(forKey: Key.theme) as? String)
        p.appearanceMode = AppearanceMode(storedValue: store.object(forKey: Key.appearanceMode) as? String)
        p.appearanceSchedule = AppearanceSchedule(storedValue: store.object(forKey: Key.appearanceSchedule))
        bool(Key.showInMenuBar, &p.showInMenuBar)
        bool(Key.menuBarShowsRemainingTime, &p.menuBarShowsRemainingTime)
        bool(Key.hideDockIcon, &p.hideDockIcon)
        return p.validated()
    }

    public func save(to store: PreferenceStore) {
        let p = validated()
        store.set(p.notifyOnCompletion, forKey: Key.notifyOnCompletion)
        store.set(p.notifyOnlyOnFailure, forKey: Key.notifyOnlyOnFailure)
        store.set(p.playSound, forKey: Key.playSound)
        store.set(p.expiryReminders, forKey: Key.expiryReminders)
        store.set(p.reminderLeadMinutes, forKey: Key.reminderLeadMinutes)
        store.set(p.notifyScheduledStart, forKey: Key.notifyScheduledStart)
        store.set(p.notifyApprovalDecisions, forKey: Key.notifyApprovalDecisions)
        store.set(p.notifyNewApprovals, forKey: Key.notifyNewApprovals)
        store.set(p.defaultHours, forKey: Key.defaultHours)
        store.set(p.rememberJustifications, forKey: Key.rememberJustifications)
        store.set(p.prefillLastJustification, forKey: Key.prefillLastJustification)
        store.set(p.confirmOwnerRoles, forKey: Key.confirmOwnerRoles)
        store.set(p.maxParallelRequests, forKey: Key.maxParallelRequests)
        let launch: String = switch p.launchTenant {
        case .lastUsed: "lastUsed"
        case .azDefault: "azDefault"
        case .specific(let id): id
        }
        store.set(launch, forKey: Key.launchTenant)
        store.set(p.refreshOnLaunch, forKey: Key.refreshOnLaunch)
        store.set(p.autoRefreshMinutes, forKey: Key.autoRefreshMinutes)
        store.set(p.theme.rawValue, forKey: Key.theme)
        store.set(p.appearanceMode.rawValue, forKey: Key.appearanceMode)
        store.set(p.appearanceSchedule.storedValue, forKey: Key.appearanceSchedule)
        store.set(p.showInMenuBar, forKey: Key.showInMenuBar)
        store.set(p.menuBarShowsRemainingTime, forKey: Key.menuBarShowsRemainingTime)
        store.set(p.hideDockIcon, forKey: Key.hideDockIcon)
    }

    /// Removes every stored setting, so the defaults apply again.
    public static func reset(in store: PreferenceStore) {
        for key in Key.all { store.removeObject(forKey: key) }
    }
}

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self { min(max(self, range.lowerBound), range.upperBound) }
}
