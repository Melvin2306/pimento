import Foundation
import Testing
@testable import PimentoCore

@Suite("Menu bar")
struct MenuBarTests {
    static let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
    static let contributor = "b24988ac-6180-42a0-ab88-20f7382dd24c"
    static let reader = "acdd72a7-3385-48ef-bd42-f606fba81ae7"

    static func role(_ id: String, _ name: String = "Contributor", guid: String = contributor, scope: String = "rg-contoso-web",
                     membership: Membership = .direct, until: TimeInterval?, active: Bool = true) -> EligibleRole {
        EligibleRole(
            id: id, eligibilityScheduleId: "s-\(id)",
            roleDefinitionId: "/providers/Microsoft.Authorization/roleDefinitions/\(guid)",
            roleName: name, scope: "/subscriptions/00000000-0000-4000-8000-000000000001/resourceGroups/\(scope)",
            scopeName: scope, scopeType: "resourcegroup", membership: membership,
            isActive: active, activeUntil: until.map { now.addingTimeInterval($0) })
    }

    // MARK: Entries

    @Test func listsActiveRolesSoonestFirstAndOpenEndedLast() {
        let roles = [
            Self.role("a", "Reader", guid: Self.reader, scope: "rg-b", until: 3 * 3600),
            Self.role("b", scope: "rg-a", until: nil),
            Self.role("c", scope: "rg-c", until: 600),
            Self.role("d", scope: "rg-d", until: nil, active: false),
            Self.role("e", "Reader", guid: Self.reader, scope: "rg-a", until: 3 * 3600),
        ]
        let entries = MenuBarStatus.entries(roles, now: Self.now)
        #expect(entries.map(\.id) == ["c", "e", "a", "b"], "soonest first, equal ends by role then scope, open-ended last, eligible-only rows left out")
        #expect(entries[0].remaining(at: Self.now) == 600)
        #expect(entries[3].remaining(at: Self.now) == nil)
    }

    @Test func oneEntryPerActivationPreferringTheDirectRow() {
        let roles = [
            Self.role("group-row", membership: .group("sg-contoso-ops"), until: 3600),
            Self.role("direct-row", until: 3600),
        ]
        let entries = MenuBarStatus.entries(roles, now: Self.now)
        #expect(entries.map(\.id) == ["direct-row"])
    }

    @Test func endedActivationsDropOutBeforeTheNextRefresh() {
        let roles = [Self.role("a", until: -1), Self.role("b", scope: "rg-b", until: 0), Self.role("c", scope: "rg-c", until: 1)]
        #expect(MenuBarStatus.entries(roles, now: Self.now).map(\.id) == ["c"])
        #expect(MenuBarStatus.entries([], now: Self.now).isEmpty)
    }

    @Test func warningWithinTheReminderLeadTime() {
        #expect(MenuBarStatus.isWarning(remaining: 600, lead: 600))
        #expect(MenuBarStatus.isWarning(remaining: 30, lead: 600))
        #expect(!MenuBarStatus.isWarning(remaining: 601, lead: 600))
        #expect(!MenuBarStatus.isWarning(remaining: nil, lead: 600), "open-ended never warns")
    }

    // MARK: Formatting

    @Test func shortTextIsHoursAndMinutesRoundedUp() {
        #expect(MenuBarStatus.shortText(remaining: 84 * 60) == "1:24")
        #expect(MenuBarStatus.shortText(remaining: 84 * 60 - 30) == "1:24", "a part minute counts as a minute")
        #expect(MenuBarStatus.shortText(remaining: 84 * 60 + 1) == "1:25")
        #expect(MenuBarStatus.shortText(remaining: 5 * 60) == "0:05")
        #expect(MenuBarStatus.shortText(remaining: 1) == "0:01", "never 0:00 while still active")
        #expect(MenuBarStatus.shortText(remaining: 0) == "0:00")
        #expect(MenuBarStatus.shortText(remaining: -20) == "0:00")
        #expect(MenuBarStatus.shortText(remaining: 8 * 3600) == "8:00")
        #expect(MenuBarStatus.shortText(remaining: 24 * 3600 - 60) == "23:59")
        #expect(MenuBarStatus.shortText(remaining: 24 * 3600) == "1d")
        #expect(MenuBarStatus.shortText(remaining: 2 * 86400 + 3 * 3600) == "2d 3h")
    }

    @Test func countdownShowsSecondsWhileThePopoverIsOpen() {
        #expect(MenuBarStatus.countdownText(remaining: 3600 + 24 * 60 + 5, seconds: true) == "1:24:05")
        #expect(MenuBarStatus.countdownText(remaining: 3600 + 24 * 60 + 4.2, seconds: true) == "1:24:05")
        #expect(MenuBarStatus.countdownText(remaining: 59, seconds: true) == "0:00:59")
        #expect(MenuBarStatus.countdownText(remaining: 0, seconds: true) == "0:00:00")
        #expect(MenuBarStatus.countdownText(remaining: 3 * 86400, seconds: true) == "3d")
        #expect(MenuBarStatus.countdownText(remaining: 3600 + 24 * 60 + 5, seconds: false) == "1:25")
    }

    @Test func spokenText() {
        #expect(MenuBarStatus.spokenText(remaining: 84 * 60) == "1 h 24 min")
        #expect(MenuBarStatus.spokenText(remaining: 10) == "1 min")
    }

    // MARK: Badge

    @Test func badgeTextRules() {
        let one = MenuBarStatus.entries([Self.role("a", until: 84 * 60)], now: Self.now)
        let two = MenuBarStatus.entries([Self.role("a", until: 84 * 60), Self.role("b", scope: "rg-b", until: 5 * 3600)], now: Self.now)
        #expect(MenuBarStatus.badgeText([], now: Self.now, showsRemainingTime: true) == nil, "icon only without active roles")
        #expect(MenuBarStatus.badgeText(one, now: Self.now, showsRemainingTime: false) == "1")
        #expect(MenuBarStatus.badgeText(two, now: Self.now, showsRemainingTime: false) == "2")
        #expect(MenuBarStatus.badgeText(one, now: Self.now, showsRemainingTime: true) == "1:24")
        #expect(MenuBarStatus.badgeText(two, now: Self.now, showsRemainingTime: true) == "2 · 1:24", "the soonest end")
        let openEnded = MenuBarStatus.entries([Self.role("a", until: nil)], now: Self.now)
        #expect(MenuBarStatus.badgeText(openEnded, now: Self.now, showsRemainingTime: true) == "1")
    }

    @Test func accessibilityText() {
        let two = MenuBarStatus.entries([Self.role("a", until: 84 * 60), Self.role("b", scope: "rg-b", until: 5 * 3600)], now: Self.now)
        #expect(MenuBarStatus.accessibilityText(two, now: Self.now) == "Pimento, 2 active roles, the next ends in 1 h 24 min")
        #expect(MenuBarStatus.accessibilityText(Array(two.prefix(1)), now: Self.now) == "Pimento, 1 active role, ends in 1 h 24 min")
        #expect(MenuBarStatus.accessibilityText([], now: Self.now) == "Pimento, no active roles")
    }

    // MARK: Timer

    @Test func noTimerWithoutActiveRoles() {
        #expect(MenuBarStatus.nextTick(after: Self.now, ends: [], showsRemainingTime: true, popoverOpen: false) == nil)
        #expect(MenuBarStatus.nextTick(after: Self.now, ends: [Self.now.addingTimeInterval(-5)], showsRemainingTime: true, popoverOpen: false) == nil)
    }

    @Test func everySecondWhileThePopoverIsOpen() {
        let now = Self.now.addingTimeInterval(0.4)
        #expect(MenuBarStatus.nextTick(after: now, ends: [], showsRemainingTime: false, popoverOpen: true) == Self.now.addingTimeInterval(1),
                "on the next whole second")
        #expect(MenuBarStatus.nextTick(after: Self.now, ends: [Self.now.addingTimeInterval(9000)], showsRemainingTime: false, popoverOpen: true)
            == Self.now.addingTimeInterval(1))
    }

    @Test func countOnlyTicksWhenAnActivationEnds() {
        let ends = [Self.now.addingTimeInterval(7200), Self.now.addingTimeInterval(600)]
        #expect(MenuBarStatus.nextTick(after: Self.now, ends: ends, showsRemainingTime: false, popoverOpen: false) == Self.now.addingTimeInterval(600))
    }

    @Test func remainingTimeTicksWhenItsMinuteChanges() {
        // 1:24 left and 30 s: shows 1:25 until exactly 84 minutes are left.
        let end = Self.now.addingTimeInterval(84 * 60 + 30)
        #expect(MenuBarStatus.nextTick(after: Self.now, ends: [end], showsRemainingTime: true, popoverOpen: false) == Self.now.addingTimeInterval(30))
        // On a whole minute: the next change is a minute later.
        let whole = Self.now.addingTimeInterval(84 * 60)
        #expect(MenuBarStatus.nextTick(after: Self.now, ends: [whole], showsRemainingTime: true, popoverOpen: false) == Self.now.addingTimeInterval(60))
        // In the last minute: when it ends.
        let last = Self.now.addingTimeInterval(42)
        #expect(MenuBarStatus.nextTick(after: Self.now, ends: [last], showsRemainingTime: true, popoverOpen: false) == last)
        // Another role ending before the soonest's minute changes.
        let other = Self.now.addingTimeInterval(10)
        #expect(MenuBarStatus.nextTick(after: Self.now, ends: [end, other], showsRemainingTime: true, popoverOpen: false) == other)
    }

    @Test func followingTheTicksChangesTheTextEachTime() {
        // Walk the timer for ten minutes: every tick changes the text, and
        // the text never changes between two ticks.
        let end = Self.now.addingTimeInterval(9 * 60 + 17)
        var t = Self.now
        var texts = [MenuBarStatus.shortText(remaining: end.timeIntervalSince(t))]
        while let next = MenuBarStatus.nextTick(after: t, ends: [end], showsRemainingTime: true, popoverOpen: false) {
            #expect(next.timeIntervalSince(t) <= 60)
            #expect(MenuBarStatus.shortText(remaining: end.timeIntervalSince(next.addingTimeInterval(-0.5))) == texts.last)
            t = next
            texts.append(MenuBarStatus.shortText(remaining: end.timeIntervalSince(t)))
        }
        #expect(texts == ["0:10", "0:09", "0:08", "0:07", "0:06", "0:05", "0:04", "0:03", "0:02", "0:01", "0:00"])
    }

    // MARK: Settings and app presence

    @Test func menuBarSettingsDefaults() {
        let p = Preferences.load(from: MemoryStore())
        #expect(p.showInMenuBar)
        #expect(!p.menuBarShowsRemainingTime)
        #expect(!p.hideDockIcon)
        #expect(AppPresence.activationPolicy(p) == .regular)
        #expect(!AppPresence.terminatesAfterLastWindowClosed(p), "the menu bar extra keeps the app running")
    }

    @Test func menuBarSettingsRoundTripAndDecodeLeniently() {
        let store = MemoryStore()
        var p = Preferences()
        p.showInMenuBar = false
        p.menuBarShowsRemainingTime = true
        p.hideDockIcon = true
        p.save(to: store)
        #expect(store.values["general.showInMenuBar"] as? Bool == false)
        #expect(store.values["general.menuBarRemainingTime"] as? Bool == true)
        #expect(store.values["general.hideDockIcon"] as? Bool == true)
        #expect(Preferences.load(from: store) == p)
        #expect(Preferences.showInMenuBarKey == "general.showInMenuBar")

        store.values = ["general.showInMenuBar": "no", "general.hideDockIcon": 1, "general.menuBarRemainingTime": "yes"]
        let q = Preferences.load(from: store)
        #expect(q.showInMenuBar && !q.hideDockIcon && !q.menuBarShowsRemainingTime, "mistyped values keep their defaults")

        Preferences.reset(in: store)
        p.save(to: store)
        Preferences.reset(in: store)
        #expect(store.values.isEmpty, "reset removes the menu bar settings too")
    }

    @Test func dockIconHidesOnlyWithTheMenuBarExtra() {
        var p = Preferences()
        p.hideDockIcon = true
        #expect(AppPresence.activationPolicy(p) == .accessory)
        p.showInMenuBar = false
        #expect(AppPresence.activationPolicy(p) == .regular, "without the menu bar extra the app would be unreachable")
        p.hideDockIcon = false
        #expect(AppPresence.activationPolicy(p) == .regular)
    }

    @Test func lastWindowClosedQuitsOnlyWithoutTheMenuBarExtra() {
        var p = Preferences()
        #expect(!AppPresence.terminatesAfterLastWindowClosed(p))
        p.hideDockIcon = true
        #expect(!AppPresence.terminatesAfterLastWindowClosed(p))
        p.showInMenuBar = false
        #expect(AppPresence.terminatesAfterLastWindowClosed(p))
        p.hideDockIcon = false
        #expect(AppPresence.terminatesAfterLastWindowClosed(p))
    }

    // MARK: Launch at login

    @Test func loginItemStates() {
        #expect(LoginItemState(statusRawValue: 0) == .disabled)
        #expect(LoginItemState(statusRawValue: 1) == .enabled)
        #expect(LoginItemState(statusRawValue: 2) == .requiresApproval)
        #expect(LoginItemState(statusRawValue: 3) == .notFound)
        #expect(LoginItemState(statusRawValue: 42) == .disabled)
        #expect(LoginItemState.enabled.isOn && LoginItemState.requiresApproval.isOn)
        #expect(!LoginItemState.disabled.isOn && !LoginItemState.notFound.isOn)
        #expect(LoginItemState.enabled.caption == nil)
        #expect(LoginItemState.requiresApproval.caption?.contains("Login Items") == true)
        #expect(LoginItemState.notFound.caption?.contains("Pimento.app") == true)
    }

    @Test func loginItemFailureExplainsAdHocSigning() {
        let signature = LoginItemState.failureMessage(code: 3, description: "Invalid code signature", isAppBundle: true)
        #expect(signature.hasPrefix("Could not change Launch at login: Invalid code signature."))
        #expect(signature.contains("ad hoc"))
        let denied = LoginItemState.failureMessage(code: 1, description: "Operation not permitted.", isAppBundle: true)
        #expect(denied.contains("Operation not permitted. macOS refused"), "no doubled full stop")
        let unknown = LoginItemState.failureMessage(code: 99, description: "Something odd", isAppBundle: true)
        #expect(unknown == "Could not change Launch at login: Something odd.")
        let bare = LoginItemState.failureMessage(code: nil, description: "Invalid argument", isAppBundle: false)
        #expect(bare.hasSuffix("Only Pimento.app can open at login (scripts/bundle.sh --install builds it)."))
    }
}
