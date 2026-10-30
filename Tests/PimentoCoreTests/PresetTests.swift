import Foundation
import Testing
@testable import PimentoCore

private let contoso = "11111111-2222-4333-8444-555555555555"
private let fabrikam = "99999999-2222-4333-8444-555555555555"

private func row(_ id: String, _ role: String, _ guid: String, scope: String, name: String,
                 _ membership: Membership = .direct, active: Bool = false) -> EligibleRole {
    EligibleRole(id: id, eligibilityScheduleId: "s-\(id)",
                 roleDefinitionId: "/providers/Microsoft.Authorization/roleDefinitions/\(guid)",
                 roleName: role, scope: scope, scopeName: name, scopeType: "subscription", membership: membership, isActive: active)
}

@Suite("Presets")
struct PresetResolutionTests {
    @Test func exactRolesMatchCaseInsensitivelyByScopeAndRoleGUID() throws {
        let rows = try Fixture.rows()
        let owner = try Fixture.role("Contoso Production", "Owner")
        // Different case, trailing slash, and the role id read through no subscription.
        let preset = Preset(name: "p", tenantId: nil, roles: [
            PresetRole(scope: owner.scope.uppercased() + "/", roleDefinitionId: "/providers/Microsoft.Authorization/roleDefinitions/\(EligibleRole.ownerRoleGUID.uppercased())"),
        ])
        let r = preset.resolve(in: rows)
        #expect(r.roles.map(\.id) == [owner.id])
        #expect(r.missing.isEmpty)
        #expect(r.active.count == 1 && r.eligible.isEmpty)
    }

    @Test func missingRolesAreReportedNotFatal() throws {
        let rows = try Fixture.rows()
        let reader = try Fixture.role("Contoso Production", "Reader")
        let gone = PresetRole(scope: "/subscriptions/dddddddd-0000-0000-0000-00000000000d", roleDefinitionId: "/providers/Microsoft.Authorization/roleDefinitions/\(EligibleRole.ownerRoleGUID)",
                              roleName: "Owner", scopeName: "Fabrikam Legacy")
        let preset = Preset(name: "p", tenantId: nil, roles: [PresetRole(reader), gone, gone])
        let r = preset.resolve(in: rows)
        #expect(r.eligible.map(\.id) == [reader.id])
        #expect(r.missing == [gone])
        #expect(gone.label == "Owner · Fabrikam Legacy")
    }

    @Test func rulesResolveNowAndDeduplicateWithExactRoles() throws {
        let rows = try Fixture.rows()
        let reader = try Fixture.role("Contoso Production", "Reader")
        let preset = Preset(name: "On-call", tenantId: nil, roles: [PresetRole(reader)], match: [
            PresetRule(filters: ["contoso"], roles: ["owner", "reader"]),
            PresetRule(filters: ["fabrikam"]),
        ])
        let r = preset.resolve(in: rows)
        #expect(Set(r.roles.map(\.roleName)) == ["Owner", "Reader"])
        // Owner and Reader on Contoso Production; Reader only once.
        #expect(r.roles.count == 2)
        #expect(r.roles.filter { $0.id == reader.id }.count == 1)
        #expect(r.unmatchedRules == [PresetRule(filters: ["fabrikam"])])
        // In table order.
        let order = rows.map(\.id)
        #expect(r.roles.map(\.id) == order.filter { id in r.roles.contains { $0.id == id } })
    }

    @Test func directEligibilityIsPreferredOverTheSameRoleThroughAGroup() {
        let scope = "/subscriptions/aaaaaaaa-0000-0000-0000-00000000000a"
        let viaGroup = row("g", "Owner", EligibleRole.ownerRoleGUID, scope: scope, name: "Contoso Production", .group("sg-admins"))
        let direct = row("d", "Owner", EligibleRole.ownerRoleGUID, scope: scope, name: "Contoso Production")
        let preset = Preset(name: "p", tenantId: nil, roles: [PresetRole(viaGroup)])
        #expect(preset.resolve(in: [viaGroup, direct]).roles.map(\.id) == ["d"])
        #expect(preset.resolve(in: [direct, viaGroup]).roles.map(\.id) == ["d"])
        #expect(preset.resolve(in: [viaGroup]).roles.map(\.id) == ["g"])
    }

    @Test func tenantFiltering() {
        let a = Preset(name: "b-contoso", tenantId: contoso.uppercased(), roles: [PresetRole(scope: "/s", roleDefinitionId: "r")])
        let b = Preset(name: "A-fabrikam", tenantId: fabrikam, roles: [PresetRole(scope: "/s", roleDefinitionId: "r")])
        let any = Preset(name: "c-any", tenantId: nil, roles: [PresetRole(scope: "/s", roleDefinitionId: "r")])
        let library = PresetLibrary(presets: [any, a, b])
        #expect(library.presets(forTenant: contoso).map(\.name) == ["b-contoso", "c-any"])
        #expect(library.presets(forTenant: nil).map(\.name) == ["A-fabrikam", "b-contoso", "c-any"])
        #expect(a.applies(toTenant: contoso) && !a.applies(toTenant: fabrikam) && a.applies(toTenant: nil))
        #expect(any.applies(toTenant: fabrikam))
    }

    @Test func summaryAndRuleLabel() {
        let p = Preset(name: "p", tenantId: nil, roles: [PresetRole(scope: "/s", roleDefinitionId: "r")],
                       match: [PresetRule(filters: ["prod", "web app"], roles: ["Owner", "Key Vault*"])])
        #expect(p.summary == "1 role + 1 rule")
        #expect(p.match[0].label == #"prod "web app" --role Owner --role "Key Vault*""#)
    }
}

@Suite("Preset library")
struct PresetLibraryTests {
    let role = PresetRole(scope: "/subscriptions/x", roleDefinitionId: "/providers/Microsoft.Authorization/roleDefinitions/r")
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func namesAreUniquePerTenant() throws {
        var library = PresetLibrary()
        let first = try library.save(Preset(name: " On-call ", tenantId: contoso, roles: [role]), now: t0)
        #expect(first.name == "On-call")
        #expect(first.createdAt == t0 && first.updatedAt == t0)
        #expect(throws: PresetError.duplicateName("on-call")) {
            try library.save(Preset(name: "on-call", tenantId: contoso.uppercased(), roles: [role]))
        }
        // Same name in another tenant is fine.
        try library.save(Preset(name: "On-call", tenantId: fabrikam, roles: [role]))
        #expect(library.presets.count == 2)

        // Replacing keeps the original creation date.
        let later = t0.addingTimeInterval(60)
        let replaced = try library.save(Preset(name: "ON-CALL", tenantId: contoso, roles: [role, role], justification: "x"), replacing: true, now: later)
        #expect(library.presets.count == 2)
        #expect(replaced.createdAt == t0 && replaced.updatedAt == later)
        #expect(try library.find("on-call", tenantId: contoso).roles.count == 2)
    }

    @Test func savingNeedsANameAndRoles() {
        var library = PresetLibrary()
        #expect(throws: PresetError.emptyName) { try library.save(Preset(name: "  ", tenantId: nil, roles: [role])) }
        #expect(throws: PresetError.noRoles) { try library.save(Preset(name: "x", tenantId: nil)) }
    }

    @Test func findByNameAndTenant() throws {
        let library = PresetLibrary(presets: [
            Preset(name: "Deploy", tenantId: contoso, roles: [role]),
            Preset(name: "deploy", tenantId: fabrikam, roles: [role]),
            Preset(name: "Read", tenantId: nil, roles: [role]),
            Preset(name: "Solo", tenantId: fabrikam, roles: [role]),
        ])
        #expect(try library.find("DEPLOY", tenantId: fabrikam).tenantId == fabrikam)
        #expect(try library.find("read", tenantId: contoso).name == "Read")
        #expect(try library.find("solo", tenantId: nil).tenantId == fabrikam)
        #expect(throws: PresetError.ambiguous("Deploy", tenants: [contoso, fabrikam])) { try library.find("deploy", tenantId: nil) }
        #expect(throws: PresetError.otherTenant("Solo", tenantId: fabrikam)) { try library.find("solo", tenantId: contoso) }
        #expect(throws: PresetError.notFound("nope")) { try library.find("nope", tenantId: nil) }
    }

    @Test func renameAndDelete() throws {
        var library = PresetLibrary()
        let a = try library.save(Preset(name: "A", tenantId: contoso, roles: [role]))
        let b = try library.save(Preset(name: "B", tenantId: contoso, roles: [role]))
        try library.rename(a.id, to: "Alpha")
        #expect(library.presets.first { $0.id == a.id }?.name == "Alpha")
        #expect(throws: PresetError.duplicateName("alpha")) { try library.rename(b.id, to: "alpha") }
        library.delete(a.id)
        #expect(library.presets.map(\.name) == ["B"])
    }
}

@Suite("Presets file")
struct PresetFileTests {
    /// The app and the CLI (each its own store value) saving at the same time.
    @Test func concurrentUpdatesLoseNoPreset() async throws {
        let url = temporaryPresetsURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let writers = 8, perWriter = 10
        await withTaskGroup(of: Void.self) { group in
            for w in 0..<writers {
                group.addTask {
                    let store = PresetStore(url: url)
                    for i in 0..<perWriter {
                        let preset = Preset(name: "p\(w)-\(i)", tenantId: nil, match: [PresetRule(filters: ["x"])])
                        _ = try? store.update { try $0.save(preset) }
                    }
                }
            }
        }
        let names = try PresetStore(url: url).load().presets.map(\.name)
        #expect(names.count == writers * perWriter)
        #expect(Set(names).count == writers * perWriter)
        #expect(hasMode(url.path + ".lock", 0o600))
    }

    @Test func aHeldLockMakesAWriterWait() throws {
        let url = temporaryPresetsURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let lock = try FileLock(url: FileLock.lockURL(for: url))
        let done = DispatchSemaphore(value: 0)
        Thread {
            _ = try? PresetStore(url: url).update { try $0.save(Preset(name: "late", tenantId: nil, match: [PresetRule(filters: ["x"])])) }
            done.signal()
        }.start()
        #expect(done.wait(timeout: .now() + 0.3) == .timedOut)
        lock.unlock()
        #expect(done.wait(timeout: .now() + 10) == .success)
        #expect(try PresetStore(url: url).load().presets.map(\.name) == ["late"])
    }
    @Test func roundTripsWithAVersionedSchema() throws {
        let p = Preset(
            id: UUID(uuidString: "6F9619FF-8B86-D011-B42D-00C04FC964FF")!, name: "On-call", tenantId: contoso,
            roles: [PresetRole(scope: "/subscriptions/aaaaaaaa-0000-0000-0000-00000000000a", roleDefinitionId: "/providers/Microsoft.Authorization/roleDefinitions/\(EligibleRole.ownerRoleGUID)",
                               roleName: "Owner", scopeName: "Contoso Production")],
            match: [PresetRule(filters: ["prod"], roles: ["Owner"])],
            justification: "on-call", duration: .maximum,
            createdAt: Date(timeIntervalSince1970: 1_800_000_000), updatedAt: Date(timeIntervalSince1970: 1_800_000_060))
        let data = PresetLibrary(presets: [p]).encoded()
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["version"] as? Int == 1)
        let stored = try #require((json["presets"] as? [[String: Any]])?.first)
        #expect(stored["duration"] as? String == "max")
        #expect(stored["createdAt"] as? String == "2027-01-15T08:00:00Z")
        #expect(try PresetLibrary.decode(data) == PresetLibrary(presets: [p]))
    }

    @Test func decodingIsLenientButRefusesNewerVersions() throws {
        let lenient = Data(#"""
        {"version": 1, "future": true, "presets": [
          {"name": "Minimal", "roles": [{"scope": "/subscriptions/x", "roleDefinitionId": "r", "extra": 1}],
           "duration": "PT90M", "match": [{"filters": []}, {"roles": ["Owner"]}]}
        ]}
        """#.utf8)
        let library = try PresetLibrary.decode(lenient)
        let p = try #require(library.presets.first)
        #expect(p.name == "Minimal" && p.tenantId == nil)
        #expect(p.duration == nil)  // not whole hours: dropped, not fatal
        #expect(p.match == [PresetRule(roles: ["Owner"])])  // the empty rule is dropped
        #expect(throws: PresetError.unsupportedVersion(2)) {
            try PresetLibrary.decode(Data(#"{"version": 2, "presets": []}"#.utf8))
        }
        #expect(throws: (any Error).self) { try PresetLibrary.decode(Data("not json".utf8)) }
    }

    @Test func storeReadsWritesAndUpdates() throws {
        let url = temporaryPresetsURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = PresetStore(url: url)
        #expect(try store.load() == PresetLibrary())  // no file yet
        let role = PresetRole(scope: "/s", roleDefinitionId: "r")
        try store.update { try $0.save(Preset(name: "A", tenantId: nil, roles: [role])) }
        // Someone else (the app or the CLI) adds one; an update keeps it.
        var other = try store.load()
        try other.save(Preset(name: "B", tenantId: nil, roles: [role]))
        try store.save(other)
        let (library, _) = try store.update { try $0.save(Preset(name: "C", tenantId: nil, roles: [role])) }
        #expect(library.presets.map(\.name) == ["A", "B", "C"])
        #expect(try store.load().presets.map(\.name) == ["A", "B", "C"])
        #expect(hasMode(url.path, 0o600))
        // The folder it created is yours only, and no temporary file is left (only the empty lock file).
        #expect(hasMode(url.deletingLastPathComponent().path, 0o700))
        #expect(try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path).sorted()
            == [url.lastPathComponent, url.lastPathComponent + ".lock"])
    }

    @Test func locationDefaultAndOverride() {
        func location(_ environment: [String: String], _ platform: HostPlatform = .macOS) -> String {
            PresetStore.location(environment: environment, home: "/Users/alex", platform: platform).path
        }
        #expect(location([:]) == filePath("/Users/alex/Library/Application Support/Pimento/presets.json"))
        #expect(location(["PIMENTO_PRESETS": "~/dotfiles/pimento.json"]) == filePath("/Users/alex/dotfiles/pimento.json"))
        #expect(location(["PIMENTO_PRESETS": "/tmp/p.json"]) == filePath("/tmp/p.json"))
        #expect(location(["PIMENTO_PRESETS": " "]) == filePath("/Users/alex/Library/Application Support/Pimento/presets.json"))
        #expect(location([:], .linux) == filePath("/Users/alex/.config/pimento/presets.json"))
        #expect(location(["XDG_CONFIG_HOME": "/cfg"], .linux) == filePath("/cfg/pimento/presets.json"))
    }
}
