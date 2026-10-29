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
        #expect(p.defaultHours == ActivationRequestBuilder.defaultHours)
        #expect(p.confirmOwnerRoles, "the Owner confirmation is a safety net and must default to on")
        #expect(p.maxParallelRequests == 8)
        #expect(p.launchTenant == .lastUsed)
        #expect(p.refreshOnLaunch)
        #expect(p.autoRefreshMinutes == 0)
    }

    @Test func roundTripsThroughTheStore() {
        var p = Preferences()
        p.notifyOnlyOnFailure = true
        p.playSound = false
        p.reminderLeadMinutes = 30
        p.defaultHours = 2
        p.confirmOwnerRoles = false
        p.maxParallelRequests = 3
        p.launchTenant = .specific("contoso.onmicrosoft.com")
        p.autoRefreshMinutes = 5
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
