import Foundation
import Testing
@testable import PimentoCore

final class MemoryStore: PreferenceStore {
    var values: [String: Any] = [:]
    func object(forKey defaultName: String) -> Any? { values[defaultName] }
    func set(_ value: Any?, forKey defaultName: String) { values[defaultName] = value }
    func removeObject(forKey defaultName: String) { values[defaultName] = nil }
}

@Suite("Preferences")
struct PreferencesTests {
    @Test func defaults() {
        let p = Preferences.load(from: MemoryStore())
        #expect(p == Preferences())
        #expect(p.notifyOnCompletion && !p.notifyOnlyOnFailure && p.playSound && p.expiryReminders)
        #expect(p.reminderLeadMinutes == 10)
        #expect(p.reminderLead == 600)
        #expect(p.notifyScheduledStart)
        #expect(p.defaultHours == ActivationRequestBuilder.defaultHours)
        #expect(p.confirmOwnerRoles, "the Owner confirmation is a safety net and must default to on")
        #expect(p.maxParallelRequests == 8)
        #expect(p.launchTenant == .lastUsed)
        #expect(p.refreshOnLaunch)
        #expect(p.autoRefreshMinutes == 0)
        #expect(p.theme == .native)
        #expect(p.appearanceMode == .system)
        #expect(p.effectiveAppearance == .system)
    }

    @Test func roundTripsThroughTheStore() {
        var p = Preferences()
        p.notifyOnlyOnFailure = true
        p.playSound = false
        p.reminderLeadMinutes = 30
        p.notifyScheduledStart = false
        p.defaultHours = 2
        p.confirmOwnerRoles = false
        p.maxParallelRequests = 3
        p.launchTenant = .specific("contoso.onmicrosoft.com")
        p.autoRefreshMinutes = 5
        p.theme = .windowsXP
        p.appearanceMode = .dark
        let store = MemoryStore()
        p.save(to: store)
        #expect(Preferences.load(from: store) == p)

        p.launchTenant = .azDefault
        p.save(to: store)
        #expect(Preferences.load(from: store).launchTenant == .azDefault)
    }

    @Test func outOfRangeValuesAreClampedOrSnapped() {
        let store = MemoryStore()
        store.values = [
            "notifications.reminderLeadMinutes": 12,
            "activation.defaultHours": 99,
            "activation.maxParallelRequests": 0,
            "general.autoRefreshMinutes": 7,
            "general.launchTenant": "--not a tenant",
            "activation.confirmOwnerRoles": "nope",
        ]
        let p = Preferences.load(from: store)
        #expect(p.reminderLeadMinutes == 10)
        #expect(p.defaultHours == ActivationRequestBuilder.maxHours)
        #expect(p.maxParallelRequests == 1)
        #expect(p.autoRefreshMinutes == 5)
        #expect(p.launchTenant == .lastUsed)
        #expect(p.confirmOwnerRoles, "a mistyped value keeps the default")

        var q = Preferences()
        q.maxParallelRequests = 64
        q.autoRefreshMinutes = -3
        q.reminderLeadMinutes = 100
        #expect(q.validated().maxParallelRequests == 16)
        #expect(q.validated().autoRefreshMinutes == 0)
        #expect(q.validated().reminderLeadMinutes == 30)
    }

    @Test func resetRemovesEverySetting() {
        let store = MemoryStore()
        var p = Preferences()
        p.playSound = false
        p.save(to: store)
        store.values["tenantId"] = "contoso.onmicrosoft.com"
        Preferences.reset(in: store)
        #expect(Preferences.load(from: store) == Preferences())
        #expect(store.values.keys.sorted() == ["tenantId"], "reset leaves data that is not a setting alone")
    }

    @Test func themeIsStoredByName() {
        let store = MemoryStore()
        for theme in AppTheme.allCases {
            var p = Preferences()
            p.theme = theme
            p.save(to: store)
            #expect(store.values["general.theme"] as? String == theme.rawValue)
            #expect(Preferences.load(from: store).theme == theme)
        }
        store.values["general.theme"] = "azure"
        #expect(Preferences.load(from: store).theme == .azure)
        store.values["general.theme"] = "windowsXP"
        #expect(Preferences.load(from: store).theme == .windowsXP)
    }

    @Test func unknownOrMistypedThemeFallsBackToNative() {
        let store = MemoryStore()
        for value: Any in ["vista", "", "Azure", 3, true] {
            store.values["general.theme"] = value
            #expect(Preferences.load(from: store).theme == .native, "\(value)")
        }
        #expect(AppTheme(storedValue: nil) == .native)
        #expect(AppTheme(storedValue: "windowsXP") == .windowsXP)
    }

    @Test func themeCodableUsesTheRawValue() throws {
        let data = try JSONEncoder().encode([AppTheme.azure, .windowsXP, .native])
        #expect(String(decoding: data, as: UTF8.self) == #"["azure","windowsXP","native"]"#)
        #expect(try JSONDecoder().decode([AppTheme].self, from: data) == [.azure, .windowsXP, .native])
        #expect(AppTheme.allCases.map(\.title) == ["Native", "Azure-style", "Windows XP-style"])
    }

    @Test func appearanceModeIsStoredByName() {
        let store = MemoryStore()
        for mode in AppearanceMode.allCases {
            var p = Preferences()
            p.appearanceMode = mode
            p.save(to: store)
            #expect(store.values["general.appearanceMode"] as? String == mode.rawValue)
            #expect(Preferences.load(from: store).appearanceMode == mode)
        }
        #expect(AppearanceMode.allCases.map(\.title) == ["System", "Light", "Dark"])
    }

    @Test func unknownOrMistypedAppearanceModeFallsBackToSystem() {
        let store = MemoryStore()
        for value: Any in ["sepia", "", "Dark", 1, false] {
            store.values["general.appearanceMode"] = value
            #expect(Preferences.load(from: store).appearanceMode == .system, "\(value)")
        }
        #expect(AppearanceMode(storedValue: nil) == .system)
        #expect(AppearanceMode(storedValue: "light") == .light)
    }

    @Test func lightOnlyThemeForcesLightButKeepsTheChoice() {
        var p = Preferences()
        p.appearanceMode = .dark
        #expect(p.effectiveAppearance == .dark)
        p.theme = .windowsXP
        #expect(!AppTheme.windowsXP.supportsDarkMode)
        #expect(p.effectiveAppearance == .light, "XP is light-only")
        #expect(p.appearanceMode == .dark, "the choice survives a detour through XP")
        p.theme = .azure
        #expect(p.effectiveAppearance == .dark)
        p.appearanceMode = .system
        p.theme = .native
        #expect(p.effectiveAppearance == .system, "back to following the system, nothing stays forced")
        for theme in AppTheme.allCases where theme.supportsDarkMode {
            for mode in AppearanceMode.allCases {
                p.theme = theme
                p.appearanceMode = mode
                #expect(p.effectiveAppearance == mode)
            }
        }
    }

    @Test func startupTenant() {
        var p = Preferences()
        #expect(p.startupTenant(lastUsed: "fabrikam.example") == "fabrikam.example")
        #expect(p.startupTenant(lastUsed: nil) == nil)
        p.launchTenant = .azDefault
        #expect(p.startupTenant(lastUsed: "fabrikam.example") == nil)
        p.launchTenant = .specific("contoso.example")
        #expect(p.startupTenant(lastUsed: "fabrikam.example") == "contoso.example")
    }

    @Test func recentJustificationsAreMostRecentFirstUniqueAndCapped() {
        var recent: [String] = []
        for i in 1...12 { recent = Preferences.recording("INC-\(i)", in: recent) }
        #expect(recent.count == Preferences.recentJustificationLimit)
        #expect(recent.first == "INC-12")
        recent = Preferences.recording("  INC-5 \n", in: recent)
        #expect(recent.first == "INC-5")
        #expect(recent.filter { $0 == "INC-5" }.count == 1)
        #expect(Preferences.recording("   ", in: recent) == recent)
    }
}
