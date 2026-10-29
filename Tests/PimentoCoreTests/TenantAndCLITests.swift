import Foundation
import Testing
@testable import PimentoCore

@Suite("Tenant resolution")
struct TenantResolverTests {
    let guid = "00000000-0000-0000-0000-0000000c0de0"

    @Test func precedenceIsFlagThenEnvironmentThenSavedThenAzDefault() throws {
        let env = [TenantResolver.environmentVariable: "env.onmicrosoft.com"]
        #expect(try TenantResolver.resolve(commandLine: guid, environment: env, saved: "saved.example.com")
            == TenantSelection(tenantId: guid, source: .commandLine))
        #expect(try TenantResolver.resolve(commandLine: nil, environment: env, saved: "saved.example.com")
            == TenantSelection(tenantId: "env.onmicrosoft.com", source: .environment))
        #expect(try TenantResolver.resolve(commandLine: "  ", environment: [:], saved: "saved.example.com")
            == TenantSelection(tenantId: "saved.example.com", source: .saved))
        let fallback = try TenantResolver.resolve(commandLine: nil, environment: [:], saved: nil)
        #expect(fallback == TenantSelection(tenantId: nil, source: .azDefault))
        #expect(!fallback.isOverride)
        #expect(try TenantResolver.resolve(commandLine: guid, environment: [:], saved: nil).isOverride)
    }

    @Test func invalidOverridesThrowButInvalidSavedValueIsIgnored() throws {
        #expect(throws: TenantError.invalid("--evil")) {
            try TenantResolver.resolve(commandLine: "--evil", environment: [:], saved: nil)
        }
        #expect(throws: TenantError.self) {
            try TenantResolver.resolve(commandLine: nil, environment: [TenantResolver.environmentVariable: "not a tenant"], saved: nil)
        }
        #expect(try TenantResolver.resolve(commandLine: nil, environment: [:], saved: "bad value")
            == TenantSelection(tenantId: nil, source: .azDefault))
    }

    @Test(arguments: [
        ("00000000-0000-0000-0000-0000000c0de0", true),
        ("contoso.onmicrosoft.com", true),
        ("login.contoso-corp.de", true),
        ("contoso", false),
        ("-contoso.com", false),
        ("contoso.com.", false),
        ("con toso.com", false),
        ("contoso.com;rm", false),
        ("", false),
    ])
    func validation(value: String, valid: Bool) {
        #expect(TenantResolver.isValid(value) == valid)
    }
}

@Suite("Tenant directory")
struct TenantDirectoryTests {
    let contosoId = "00000000-0000-0000-0000-0000000c0de0"

    @Test func mergesAccountAndTenantListsIntoDistinctTenants() throws {
        let tenants = TenantDirectory.parse([try Fixture.data("az-account-list"), try Fixture.data("az-tenant-list")])
        // Case-insensitive de-duplication; named tenants by name, then unnamed ones.
        #expect(tenants.map(\.id) == [
            contosoId,
            "00000000-0000-0000-0000-0000000aa0e0",
            "00000000-0000-0000-0000-00000fab41c0",
        ])
        let contoso = tenants[0]
        #expect(contoso.label == "Contoso")
        #expect(contoso.detail == "contoso.onmicrosoft.com")
        #expect(tenants[1].label == "Northwind")
        let unnamed = tenants[2]
        #expect(!unnamed.isNamed)
        #expect(unnamed.label == "Unnamed tenant 00000000")
        #expect(unnamed.detail == nil)
    }

    @Test func parsesARMTenantPagesAndOnlyFollowsARMLinks() throws {
        let page1 = try #require(TenantDirectory.parseARMPage(try Fixture.data("arm-tenants-page1")))
        #expect(page1.tenants.map(\.id) == [contosoId, "00000000-0000-0000-0000-0000000fab00"])
        #expect(page1.tenants[0].displayName == "Contoso Ltd")
        #expect(page1.tenants[0].defaultDomain == "contoso.example")
        #expect(page1.tenants[1].isManaged)
        #expect(page1.next?.host == "management.azure.com")

        let page2 = try #require(TenantDirectory.parseARMPage(try Fixture.data("arm-tenants-page2")))
        #expect(page2.next == nil)
        // An empty display name falls back to the domain; a non-GUID ID is dropped.
        #expect(page2.tenants.map(\.label) == ["adventure-works.onmicrosoft.com"])

        for link in ["https://evil.example/tenants", "http://management.azure.com/tenants"] {
            let doc = Data(#"{"value":[],"nextLink":"\#(link)"}"#.utf8)
            #expect(TenantDirectory.parseARMPage(doc)?.next == nil)
        }
        #expect(TenantDirectory.parseARMPage(Data("[]".utf8)) == nil)
    }

    @Test func mergePrefersARMNamesAndFillsGapsFromAz() throws {
        let arm = try #require(TenantDirectory.parseARMPage(try Fixture.data("arm-tenants-page1"))).tenants
        let az = [try Fixture.data("az-account-list"), try Fixture.data("az-tenant-list")].map(TenantDirectory.parseAzure)
        let tenants = TenantDirectory.merge([arm] + az)
        #expect(tenants.map(\.label) == ["Contoso Ltd", "Fabrikam", "Northwind", "Unnamed tenant 00000000"])
        // ARM's name wins over az's; the tenant az alone knows keeps az's name.
        #expect(tenants[0].id == contosoId)
        #expect(tenants[0].detail == "contoso.example")
        #expect(tenants[2].defaultDomain == "northwind.onmicrosoft.com")
        #expect(tenants.last?.id == "00000000-0000-0000-0000-00000fab41c0")
    }

    @Test func aLaterSourceFillsAMissingNameAndGUIDNamesDontCount() {
        let id = "00000000-0000-0000-0000-000000000001"
        let merged = TenantDirectory.merge([
            [TenantInfo(id: id, displayName: nil, defaultDomain: nil, category: "Home")],
            TenantDirectory.parseAzure(Data(#"[{"tenantId":"\#(id)","tenantDisplayName":"\#(id)"}]"#.utf8)),
            [TenantInfo(id: id, displayName: "Wide World Importers", defaultDomain: "wwi.example")],
        ])
        #expect(merged.count == 1)
        #expect(merged[0].label == "Wide World Importers")
        #expect(merged[0].category == "Home")
    }

    @Test func fetchARMFollowsPagesWithTheTokenOnlyToARM() async throws {
        let page1 = try Fixture.data("arm-tenants-page1"), page2 = try Fixture.data("arm-tenants-page2")
        let transport = RecordingTransport { request in
            (request.url?.query?.contains("skiptoken") == true ? page2 : page1, 200)
        }
        let tenants = try await TenantDirectory.fetchARM(tokens: StaticTokenProvider(), transport: transport)
        #expect(tenants.count == 3)
        let requests = await transport.requests
        #expect(requests.count == 2)
        #expect(requests.allSatisfy { $0.url?.host == "management.azure.com" && $0.httpMethod == "GET" })
        #expect(requests[0].url == TenantDirectory.armTenantsURL)
    }

    @Test func fetchARMSurfacesHTTPErrors() async {
        let transport = RecordingTransport { _ in (Data(#"{"error":{"code":"InvalidAuthenticationToken"}}"#.utf8), 401) }
        await #expect(throws: PIMServiceError.self) {
            try await TenantDirectory.fetchARM(tokens: StaticTokenProvider(), transport: transport)
        }
    }

    @Test func pickerFiltersByQueryAndHidesTenantsExceptTheCurrentOne() {
        let a = TenantInfo(id: "00000000-0000-0000-0000-00000000000a", displayName: "Contoso", defaultDomain: "contoso.example")
        let b = TenantInfo(id: "00000000-0000-0000-0000-00000000000b", displayName: "Fabrikam", defaultDomain: "fabrikam.example")
        let c = TenantInfo(id: "00000000-0000-0000-0000-00000000000c")
        let all = [a, b, c]
        #expect(TenantDirectory.visible(all, query: "fabri", hidden: [], showHidden: false, current: nil) == [b])
        #expect(TenantDirectory.visible(all, query: "contoso.ex", hidden: [], showHidden: false, current: nil) == [a])
        #expect(TenantDirectory.visible(all, query: "0000000c", hidden: [], showHidden: false, current: nil) == [c])
        #expect(TenantDirectory.visible(all, hidden: [b.id, c.id], showHidden: false, current: nil) == [a])
        #expect(TenantDirectory.visible(all, hidden: [b.id, c.id], showHidden: true, current: nil) == all)
        // The tenant in use never disappears from the list, even when hidden.
        #expect(TenantDirectory.visible(all, hidden: [b.id], showHidden: false, current: b.id.uppercased()) == all)
    }

    @Test func sortsByNameCaseInsensitivelyWithUnnamedLast() {
        let ids = (1...4).map { String(format: "00000000-0000-0000-0000-%012d", $0) }
        let sorted = TenantDirectory.sorted([
            TenantInfo(id: ids[0]),
            TenantInfo(id: ids[1], displayName: "fabrikam"),
            TenantInfo(id: ids[2], defaultDomain: "adventure-works.example"),
            TenantInfo(id: ids[3], displayName: "Contoso"),
        ])
        #expect(sorted.map(\.label) == ["adventure-works.example", "Contoso", "fabrikam", "Unnamed tenant 00000000"])
    }

    @Test func garbageIsIgnored() {
        #expect(TenantDirectory.parse([Data("not json".utf8), Data("{}".utf8)]).isEmpty)
    }
}

@Suite("Command-line parsing")
struct CLIOptionsTests {
    @Test func noModeFlagOpensTheAppAndIgnoresUnknownArguments() throws {
        let o = try CLIOptions.parse(["-NSDocumentRevisionsDebugMode", "YES", "--tenant", "contoso.onmicrosoft.com"])
        #expect(o.mode == .app)
        #expect(o.tenant == "contoso.onmicrosoft.com")
        #expect(try CLIOptions.parse([]).mode == .app)
    }

    @Test func dryRunCollectsOptionsAndFilters() throws {
        let o = try CLIOptions.parse(["--dry-run", "-j", "INC-42 hotfix", "--hours", "4", "--role", "Owner",
                                      "--tenant=00000000-0000-0000-0000-0000000c0de0", "prod", "Staging"])
        #expect(o.mode == .dryRun)
        #expect(o.justification == "INC-42 hotfix")
        #expect(o.hours == 4)
        #expect(o.roleFilter == "owner")
        #expect(o.tenant == "00000000-0000-0000-0000-0000000c0de0")
        #expect(o.filters == ["prod", "staging"])
    }

    @Test func defaultsAndModes() throws {
        #expect(try CLIOptions.parse(["--dry-run"]).hours == ActivationRequestBuilder.defaultHours)
        #expect(try CLIOptions.parse(["--list", "-t", "x.example.com"]).tenant == "x.example.com")
        #expect(try CLIOptions.parse(["--tenants"]).mode == .tenants)
        #expect(try CLIOptions.parse(["--list", "--help"]).mode == .help)
        #expect(try CLIOptions.parse(["--version"]).mode == .version)
    }

    @Test func errors() {
        #expect(throws: CLIOptions.ParseError.conflictingModes) { try CLIOptions.parse(["--list", "--dry-run"]) }
        #expect(throws: CLIOptions.ParseError.missingValue("--tenant")) { try CLIOptions.parse(["--list", "--tenant"]) }
        #expect(throws: CLIOptions.ParseError.missingValue("-j")) { try CLIOptions.parse(["--dry-run", "-j", "--hours", "2"]) }
        #expect(throws: CLIOptions.ParseError.invalidHours("four")) { try CLIOptions.parse(["--dry-run", "--hours", "four"]) }
        #expect(throws: CLIOptions.ParseError.unknownOption("--frobnicate")) { try CLIOptions.parse(["--list", "--frobnicate"]) }
        #expect(throws: CLIOptions.ParseError.unknownOption("prod")) { try CLIOptions.parse(["--list", "prod"]) }
    }
}
