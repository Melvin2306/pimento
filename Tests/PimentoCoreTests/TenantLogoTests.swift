import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(ImageIO)
import CoreGraphics
import ImageIO
#endif
import Testing
@testable import PimentoCore

// Every request here goes to a RecordingTransport: nothing reaches the network.

private let contosoId = "00000000-0000-0000-0000-0000000c0de0"
private let tileURL = "https://aadcdn.msauthimages.net/00000000-contoso/logintenantbranding/0/tilelogo?ts=1"

/// A stand-in image: the fake check accepts bytes that start with "IMG".
private func fakeImage(_ size: Int = 64) -> Data { Data("IMG".utf8) + Data(repeating: 0x2A, count: max(0, size - 3)) }
private let fakeInspect: @Sendable (Data) -> LogoImageInfo? = { data in
    data.starts(with: Array("IMG".utf8)) ? LogoImageInfo(width: 64, height: 64) : nil
}

private func tenant(_ defaultDomain: String? = "contoso.com", domains: [String] = ["contoso.onmicrosoft.com", "contoso.com"],
                    id: String = contosoId) -> TenantInfo {
    TenantInfo(id: id, displayName: "Contoso", defaultDomain: defaultDomain, category: "Home", domains: domains)
}

/// The shape `GetCredentialType` answers with (fields Pimento ignores included).
private func brandingAnswer(tile: Any? = tileURL, banner: Any? = "https://aadcdn.msauthimages.net/00000000-contoso/logintenantbranding/0/bannerlogo") -> Data {
    var branding: [String: Any] = ["Locale": 0, "BackgroundColor": "#0078D4", "KeepMeSignedInDisabled": false]
    if let tile { branding["TileLogo"] = tile }
    if let banner { branding["BannerLogo"] = banner }
    let doc: [String: Any] = [
        "Username": "pimento-logo-lookup@contoso.example.com", "IfExistsResult": 1, "ThrottleStatus": 0,
        "Credentials": ["PrefCredential": 1, "HasPassword": true],
        "EstsProperties": ["UserTenantBranding": [branding], "DomainType": 3],
    ]
    return try! JSONSerialization.data(withJSONObject: doc)
}

private func isBrandingLookup(_ r: URLRequest) -> Bool { r.url == TenantLogoPolicy.brandingURL }

final class LogoTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date
    init(_ date: Date) { value = date }
    var now: Date { lock.withLock { value } }
    func advance(_ seconds: TimeInterval) { lock.withLock { value += seconds } }
}

@Suite("Tenant logos")
struct TenantLogoTests {
    // MARK: Domains

    @Test func theBrandingLookupUsesTheOnMicrosoftDomainAndTheIconTheCompanyDomain() {
        let t = tenant()
        #expect(TenantLogoPolicy.brandingDomain(for: t) == "contoso.onmicrosoft.com")
        #expect(TenantLogoPolicy.websiteDomain(for: t) == "contoso.com")
    }

    @Test func theDefaultDomainComesFirstForTheWebsite() {
        let t = tenant("fabrikam.com", domains: ["contoso.onmicrosoft.com", "contoso.com", "fabrikam.com"])
        #expect(TenantLogoPolicy.websiteDomain(for: t) == "fabrikam.com")
        // A Microsoft-hosted default: the first verified company domain.
        let m = tenant("contoso.onmicrosoft.com", domains: ["contoso.onmicrosoft.com", "contoso.mail.onmicrosoft.com", "woodgrovebank.com"])
        #expect(TenantLogoPolicy.websiteDomain(for: m) == "woodgrovebank.com")
        #expect(TenantLogoPolicy.brandingDomain(for: m) == "contoso.onmicrosoft.com")
    }

    @Test func onlyMicrosoftDomainsMeanNoWebsite() {
        let t = tenant("contoso.onmicrosoft.com", domains: ["contoso.onmicrosoft.com", "contoso.onmicrosoft.de", "contoso.onmschina.cn"])
        #expect(TenantLogoPolicy.websiteDomain(for: t) == nil)
        #expect(TenantLogoPolicy.brandingDomain(for: t) == "contoso.onmicrosoft.com")
    }

    @Test func withoutAnOnMicrosoftDomainTheBrandingLookupUsesTheFirstDomain() {
        let t = tenant("northwindtraders.com", domains: [])
        #expect(TenantLogoPolicy.brandingDomain(for: t) == "northwindtraders.com")
        #expect(TenantLogoPolicy.websiteDomain(for: t) == "northwindtraders.com")
    }

    @Test func unusableDomainsAreSkipped() {
        let bad = ["localhost", "10.0.0.1", "[::1]", "contoso", "contoso.local", "contoso.internal", "-flag.com", "contoso.example",
                   "contoso.invalid", "contoso.test", "contoso..com", "contoso.com/path", "contoso.com:8443", "user@contoso.example.com",
                   "contoso_corp.com", "", " ", "c.o"]
        for domain in bad {
            #expect(TenantLogoPolicy.websiteDomain(for: tenant(domain, domains: [])) == nil, "\(domain)")
            #expect(TenantLogoPolicy.brandingDomain(for: tenant(domain, domains: [])) == nil, "\(domain)")
        }
        let mixed = tenant("10.0.0.1", domains: ["contoso.local", "Contoso.COM "])
        #expect(TenantLogoPolicy.websiteDomain(for: mixed) == "contoso.com", "trimmed and lower-cased")
        #expect(TenantLogoPolicy.websiteDomain(for: tenant(nil, domains: [])) == nil)
    }

    @Test func demoTenantsHaveNoUsableDomain() {
        // `.example` is reserved: even without the demo guard nothing would be sent.
        for t in DemoDirectory.tenants {
            #expect(TenantLogoPolicy.brandingDomain(for: t.info) == nil)
            #expect(TenantLogoPolicy.websiteDomain(for: t.info) == nil)
        }
    }

    @Test func armTenantDomainsAreDecodedAndMerged() throws {
        let page = try #require(TenantDirectory.parseARMPage(try Fixture.data("arm-tenants-page1")))
        #expect(page.tenants[0].domains == ["contoso.onmicrosoft.com", "contoso.example"])
        #expect(page.tenants[1].domains == [])
        // A `domains` of the wrong type costs the domains, not the tenant.
        let odd = Data(#"{"value":[{"tenantId":"\#(contosoId)","displayName":"Contoso","domains":"contoso.com"}]}"#.utf8)
        let parsed = try #require(TenantDirectory.parseARMPage(odd))
        #expect(parsed.tenants.map(\.label) == ["Contoso"])
        #expect(parsed.tenants[0].domains == [])
        // az's cache has no domains; the merge keeps ARM's.
        let merged = TenantDirectory.merge([page.tenants, [TenantInfo(id: page.tenants[0].id, displayName: "Contoso (az)")]])
        #expect(merged.first { $0.id == page.tenants[0].id }?.domains == ["contoso.onmicrosoft.com", "contoso.example"])
    }

    // MARK: The branding lookup

    @Test func theLookupSendsOnlyAMadeUpUserName() throws {
        let request = TenantLogoPolicy.brandingRequest(domain: "contoso.example.com")
        #expect(request.url?.absoluteString == "https://login.microsoftonline.com/common/GetCredentialType")
        #expect(request.httpMethod == "POST")
        let body = try #require(request.httpBody)
        #expect(String(decoding: body, as: UTF8.self) == #"{"username":"pimento-logo-lookup@contoso.example.com"}"#)
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(request.value(forHTTPHeaderField: "Cookie") == nil)
    }

    @Test func parsesTheTileLogo() {
        #expect(TenantLogoPolicy.tileLogoURL(fromBranding: brandingAnswer())?.absoluteString == tileURL)
    }

    @Test func missingOrGarbageBrandingMeansNoLogo() {
        let cases: [(String, Data)] = [
            ("no tile, only a banner", brandingAnswer(tile: nil)),
            ("empty tile", brandingAnswer(tile: "")),
            ("tile of the wrong type", brandingAnswer(tile: 42)),
            ("tile as an object", brandingAnswer(tile: ["url": tileURL])),
            ("banner of the wrong type", brandingAnswer(banner: false)),
            ("tile not a URL", brandingAnswer(tile: "not a url at all")),
            ("no EstsProperties", Data(#"{"Username":"x","IfExistsResult":1}"#.utf8)),
            ("null branding", Data(#"{"EstsProperties":{"UserTenantBranding":null}}"#.utf8)),
            ("empty branding", Data(#"{"EstsProperties":{"UserTenantBranding":[]}}"#.utf8)),
            ("branding not a list", Data(#"{"EstsProperties":{"UserTenantBranding":{"TileLogo":"\#(tileURL)"}}}"#.utf8)),
            ("EstsProperties a string", Data(#"{"EstsProperties":"x"}"#.utf8)),
            ("a JSON list", Data("[]".utf8)),
            ("HTML", Data("<html><body>Sign in</body></html>".utf8)),
            ("empty", Data()),
            ("not UTF-8", Data([0xFF, 0xFE, 0x00, 0x7B])),
        ]
        for (name, data) in cases {
            #expect(TenantLogoPolicy.tileLogoURL(fromBranding: data) == nil, "\(name)")
        }
    }

    @Test func theFirstBrandingWithATileWins() {
        let doc = #"{"EstsProperties":{"UserTenantBranding":[{"Locale":0,"BannerLogo":"https://aadcdn.msauthimages.net/b"},{"Locale":1033,"TileLogo":"\#(tileURL)"}]}}"#
        #expect(TenantLogoPolicy.tileLogoURL(fromBranding: Data(doc.utf8))?.absoluteString == tileURL)
    }

    @Test func tileLogosOffMicrosoftsCDNAreRefused() {
        for url in ["https://evil.example.com/tilelogo", "http://aadcdn.msauthimages.net/tilelogo", "javascript:alert(1)",
                    "file:///etc/passwd", "https://aadcdn.msauthimages.net.evil.com/tilelogo"] {
            #expect(TenantLogoPolicy.tileLogoURL(fromBranding: brandingAnswer(tile: url)) == nil, "\(url)")
        }
    }

    @Test func anOversizedLookupAnswerIsIgnored() {
        var doc = brandingAnswer()
        doc.append(Data(repeating: 0x20, count: TenantLogoPolicy.maxBytes))
        #expect(TenantLogoPolicy.tileLogoURL(fromBranding: doc) == nil)
    }

    // MARK: Host allowlist

    @Test func onlyMicrosoftsBrandingCDNsAreAllowed() {
        for host in ["aadcdn.msftauthimages.net", "aadcdn.msauthimages.net", "secure.aadcdn.microsoftonline-p.com", "AADCDN.MSAUTHIMAGES.NET"] {
            #expect(TenantLogoPolicy.isAllowedBrandingImage(URL(string: "https://\(host)/x/tilelogo")!), "\(host)")
        }
        for url in ["http://aadcdn.msauthimages.net/x", "https://aadcdn.msauthimages.net:8443/x", "https://user@aadcdn.msauthimages.net/x",
                    "https://aadcdn.msauthimages.net.evil.com/x", "https://evil.com/aadcdn.msauthimages.net",
                    "https://msauthimages.net/x", "https://login.microsoftonline.com/x", "https://contoso.com/favicon.ico"] {
            #expect(!TenantLogoPolicy.isAllowedBrandingImage(URL(string: url)!), "\(url)")
        }
        #expect(TenantLogoPolicy.isAllowedBrandingImage(URL(string: "https://aadcdn.msauthimages.net:443/x")!))
    }

    @Test func websiteIconsStayOnTheDomain() {
        let d = "contoso.com"
        for url in ["https://contoso.com/favicon.ico", "https://www.contoso.com/favicon.ico", "https://cdn.contoso.com/i.png"] {
            #expect(TenantLogoPolicy.isAllowedWebsiteURL(URL(string: url)!, domain: d), "\(url)")
        }
        for url in ["http://contoso.com/favicon.ico", "https://contoso.com.evil.com/x", "https://evilcontoso.com/x",
                    "https://fabrikam.com/x", "https://127.0.0.1/x", "https://contoso.com:8080/x"] {
            #expect(!TenantLogoPolicy.isAllowedWebsiteURL(URL(string: url)!, domain: d), "\(url)")
        }
        #expect(TenantLogoPolicy.websiteIconURLs(domain: d).map(\.absoluteString)
            == ["https://contoso.com/apple-touch-icon.png", "https://contoso.com/favicon.ico"])
    }

    // MARK: Fetching

    @Test func brandingFirst() async throws {
        let transport = RecordingTransport { r in
            if isBrandingLookup(r) { return (brandingAnswer(), 200) }
            if r.url?.absoluteString == tileURL { return (fakeImage(), 200) }
            return (Data(), 404)
        }
        let logo = await TenantLogoFetcher(transport: transport, inspect: fakeInspect).fetch(tenant())
        #expect(logo?.source == .branding)
        let sent = await transport.requests
        #expect(sent.map { $0.url?.absoluteString ?? "" } == [TenantLogoPolicy.brandingURL.absoluteString, tileURL])
        #expect(sent[1].httpMethod == "GET")
        #expect(sent.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == nil })
    }

    @Test func withoutBrandingTheWebsiteIconIsTried() async {
        let transport = RecordingTransport { r in
            if isBrandingLookup(r) { return (brandingAnswer(tile: nil), 200) }
            if r.url?.path == "/favicon.ico" { return (fakeImage(), 200) }
            return (Data("<html>not found</html>".utf8), 404)
        }
        let logo = await TenantLogoFetcher(transport: transport, inspect: fakeInspect).fetch(tenant())
        #expect(logo?.source == .website)
        let urls = await transport.requests.map { $0.url?.absoluteString ?? "" }
        #expect(urls == [TenantLogoPolicy.brandingURL.absoluteString, "https://contoso.com/apple-touch-icon.png", "https://contoso.com/favicon.ico"])
    }

    @Test func aFailedLookupFallsThroughToo() async {
        for failure in [500, 429] {
            let transport = RecordingTransport { r in
                if isBrandingLookup(r) { return (brandingAnswer(), failure) }
                return (fakeImage(), 200)
            }
            #expect(await TenantLogoFetcher(transport: transport, inspect: fakeInspect).fetch(tenant())?.source == .website)
        }
        let throwing = RecordingTransport { r in
            if isBrandingLookup(r) { throw URLError(.timedOut) }
            return (fakeImage(), 200)
        }
        #expect(await TenantLogoFetcher(transport: throwing, inspect: fakeInspect).fetch(tenant())?.source == .website)
    }

    @Test func aTileLogoOffTheCDNIsNeverRequested() async {
        let transport = RecordingTransport { r in
            if isBrandingLookup(r) { return (brandingAnswer(tile: "https://tracker.example.com/pixel.png"), 200) }
            return (Data(), 404)
        }
        #expect(await TenantLogoFetcher(transport: transport, inspect: fakeInspect).fetch(tenant()) == nil)
        let hosts = await transport.requests.compactMap { $0.url?.host }
        #expect(!hosts.contains("tracker.example.com"))
        #expect(hosts == ["login.microsoftonline.com", "contoso.com", "contoso.com"])
    }

    @Test func notAnImageMeansNoLogo() async {
        let transport = RecordingTransport { r in
            if isBrandingLookup(r) { return (brandingAnswer(), 200) }
            return (Data("<html>a soft 404 page</html>".utf8), 200)
        }
        #expect(await TenantLogoFetcher(transport: transport, inspect: fakeInspect).fetch(tenant()) == nil)
        #expect(await transport.requests.count == 4)
    }

    @Test func imagesOverTheSizeCapAreRejected() async {
        let cap = TenantLogoPolicy.maxBytes
        #expect(cap == 512 * 1024)
        let tooBig = RecordingTransport { r in
            if isBrandingLookup(r) { return (brandingAnswer(), 200) }
            return (fakeImage(cap + 1), 200)
        }
        #expect(await TenantLogoFetcher(transport: tooBig, inspect: fakeInspect).fetch(tenant()) == nil)
        let atCap = RecordingTransport { r in
            if isBrandingLookup(r) { return (brandingAnswer(), 200) }
            return (fakeImage(cap), 200)
        }
        #expect(await TenantLogoFetcher(transport: atCap, inspect: fakeInspect).fetch(tenant())?.data.count == cap)
        // The real check refuses it too, whatever the transport let through.
        #expect(LogoImageCheck.inspect(Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) + Data(count: cap)) == nil)
    }

    @Test func websiteRedirectsAreFollowedOnlyWithinTheDomain() async {
        let followed = RecordingTransport { r in
            if isBrandingLookup(r) { return (Data("{}".utf8), 200) }
            if r.url?.host == "contoso.com" {
                throw URLSessionTransport.RedirectRefused(status: 301, location: "https://www.contoso.com\(r.url!.path)")
            }
            return (fakeImage(), 200)
        }
        let logo = await TenantLogoFetcher(transport: followed, inspect: fakeInspect).fetch(tenant())
        #expect(logo?.source == .website)
        #expect(await followed.requests.last?.url?.absoluteString == "https://www.contoso.com/apple-touch-icon.png")

        for target in ["https://evil.com/favicon.ico", "http://www.contoso.com/favicon.ico", "https://10.0.0.1/favicon.ico", "//evil.com/x"] {
            let refused = RecordingTransport { r in
                if isBrandingLookup(r) { return (Data("{}".utf8), 200) }
                if r.url?.host == "contoso.com" { throw URLSessionTransport.RedirectRefused(status: 302, location: target) }
                return (fakeImage(), 200)
            }
            #expect(await TenantLogoFetcher(transport: refused, inspect: fakeInspect).fetch(tenant()) == nil, "\(target)")
            #expect(await refused.requests.allSatisfy { $0.url?.host == "contoso.com" || isBrandingLookup($0) }, "\(target)")
        }
    }

    @Test func aRedirectLoopStops() async {
        let loop = RecordingTransport { r in
            if isBrandingLookup(r) { return (Data("{}".utf8), 200) }
            let next = r.url?.host == "contoso.com" ? "https://www.contoso.com/i" : "https://contoso.com/i"
            throw URLSessionTransport.RedirectRefused(status: 302, location: next)
        }
        #expect(await TenantLogoFetcher(transport: loop, inspect: fakeInspect).fetch(tenant()) == nil)
        // The lookup, then per icon URL the first request and maxRedirects redirects.
        #expect(await loop.requests.count == 1 + 2 * (1 + TenantLogoPolicy.maxRedirects))
    }

    @Test func aCDNRedirectMustStayOnTheCDN() async {
        let transport = RecordingTransport { r in
            if isBrandingLookup(r) { return (brandingAnswer(), 200) }
            if r.url?.absoluteString == tileURL {
                throw URLSessionTransport.RedirectRefused(status: 302, location: "https://tracker.example.com/tile.png")
            }
            return (Data(), 404)
        }
        #expect(await TenantLogoFetcher(transport: transport, inspect: fakeInspect).fetch(tenant()) == nil)
        #expect(await !transport.requests.contains { $0.url?.host == "tracker.example.com" })
    }

    // MARK: Cache

    private func service(_ transport: RecordingTransport, clock: LogoTestClock, directory: URL = TestTemp.url("logos")) -> TenantLogoService {
        TenantLogoService(cache: TenantLogoCache(directory: directory),
                          fetcher: TenantLogoFetcher(transport: transport, inspect: fakeInspect),
                          clock: { clock.now })
    }

    private func brandingTransport() -> RecordingTransport {
        RecordingTransport { r in
            if isBrandingLookup(r) { return (brandingAnswer(), 200) }
            return (fakeImage(), 200)
        }
    }

    @Test func aLogoIsKeptForSevenDays() async {
        let clock = LogoTestClock(Fixture.now)
        let transport = brandingTransport()
        let s = service(transport, clock: clock)
        #expect(TenantLogoPolicy.ttl == 7 * 86400)
        #expect(await s.logo(for: tenant(), enabled: true, demo: false)?.source == .branding)
        #expect(await transport.requests.count == 2)

        clock.advance(TenantLogoPolicy.ttl - 60)
        #expect(await s.logo(for: tenant(), enabled: true, demo: false)?.source == .branding)
        #expect(await transport.requests.count == 2, "fresh: from the cache")

        clock.advance(60)
        #expect(await s.logo(for: tenant(), enabled: true, demo: false)?.source == .branding)
        #expect(await transport.requests.count == 4, "expired: fetched again")
    }

    @Test func noLogoIsCachedToo() async {
        let clock = LogoTestClock(Fixture.now)
        let transport = RecordingTransport { _ in (Data(), 404) }
        let s = service(transport, clock: clock)
        #expect(await s.logo(for: tenant(), enabled: true, demo: false) == nil)
        let first = await transport.requests.count
        #expect(first == 3)
        #expect(await s.logo(for: tenant(), enabled: true, demo: false) == nil)
        #expect(await transport.requests.count == first)
        #expect(s.cache.lookup(tenantId: contosoId, now: clock.now) == .fresh(nil))
    }

    @Test func refreshAndClearInvalidate() async {
        let clock = LogoTestClock(Fixture.now)
        let transport = brandingTransport()
        let dir = TestTemp.url("logos")
        let s = service(transport, clock: clock, directory: dir)
        _ = await s.logo(for: tenant(), enabled: true, demo: false)
        _ = await s.logo(for: tenant(), enabled: true, demo: false, refresh: true)
        #expect(await transport.requests.count == 4, "refresh skips the cache")

        s.cache.remove(tenantId: contosoId)
        #expect(s.cache.lookup(tenantId: contosoId, now: clock.now) == .missing)
        _ = await s.logo(for: tenant(), enabled: true, demo: false)
        #expect(await transport.requests.count == 6)

        s.cache.clear()
        #expect(!FileManager.default.fileExists(atPath: dir.path))
        #expect(s.cache.lookup(tenantId: contosoId, now: clock.now) == .missing)
    }

    @Test func cacheFilesArePrivateAndNamedByTenantID() throws {
        let dir = TestTemp.url("logos")
        let cache = TenantLogoCache(directory: dir)
        let logo = TenantLogo(data: fakeImage(), source: .website)
        try cache.store(tenantId: contosoId.uppercased(), logo: logo, now: Fixture.now)
        #expect(cache.lookup(tenantId: contosoId, now: Fixture.now) == .fresh(logo))
        #expect(hasMode(dir.appendingPathComponent("\(contosoId).img").path, 0o600))
        #expect(hasMode(dir.appendingPathComponent("\(contosoId).json").path, 0o600))
        #expect(hasMode(dir.path, 0o700))
        // Anything but a GUID is never a file name.
        try cache.store(tenantId: "../../evil", logo: logo, now: Fixture.now)
        #expect(cache.lookup(tenantId: "../../evil", now: Fixture.now) == .missing)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted() == ["\(contosoId).img", "\(contosoId).json"])
        // A clock set back makes the entry stale, not fresh forever.
        #expect(cache.lookup(tenantId: contosoId, now: Fixture.now.addingTimeInterval(-3600)) == .missing)
        // Replacing a logo with "none" removes the image.
        try cache.store(tenantId: contosoId, logo: nil, now: Fixture.now)
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("\(contosoId).img").path))
    }

    @Test func aCorruptCacheEntryIsRefetched() async throws {
        let clock = LogoTestClock(Fixture.now)
        let dir = TestTemp.url("logos")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("garbage".utf8).write(to: dir.appendingPathComponent("\(contosoId).json"))
        let transport = brandingTransport()
        #expect(await service(transport, clock: clock, directory: dir).logo(for: tenant(), enabled: true, demo: false) != nil)
        #expect(await transport.requests.count == 2)
    }

    // MARK: Off, demo mode, no domains

    @Test func offOrInDemoModeNothingIsSentOrRead() async throws {
        let clock = LogoTestClock(Fixture.now)
        let transport = brandingTransport()
        let dir = TestTemp.url("logos")
        let s = service(transport, clock: clock, directory: dir)
        // Even a cached logo is not shown while the setting is off.
        try s.cache.store(tenantId: contosoId, logo: TenantLogo(data: fakeImage(), source: .branding), now: clock.now)
        #expect(await s.logo(for: tenant(), enabled: false, demo: false) == nil)
        #expect(await s.logo(for: tenant(), enabled: false, demo: false, refresh: true) == nil)
        #expect(await s.logo(for: tenant(), enabled: true, demo: true, refresh: true) == nil)
        #expect(await s.logo(for: tenant(), enabled: false, demo: true) == nil)
        #expect(await transport.requests.isEmpty)
        #expect(!TenantLogoService.isAllowed(enabled: false, demo: false))
        #expect(!TenantLogoService.isAllowed(enabled: true, demo: true))
        #expect(TenantLogoService.isAllowed(enabled: true, demo: false))
    }

    @Test func whileTheNetworkIsBlockedNothingIsSent() async {
        let clock = LogoTestClock(Fixture.now)
        let transport = brandingTransport()
        let s = service(transport, clock: clock)
        let monitor = NetworkGuard.Monitor()
        let logo = await NetworkGuard.$monitor.withValue(monitor) {
            await s.logo(for: tenant(), enabled: true, demo: false, refresh: true)
        }
        #expect(logo == nil)
        #expect(await transport.requests.isEmpty)
        #expect(monitor.blocked.isEmpty, "refused before any request was even attempted")
    }

    @Test func theLogoTransportRefusesWhileBlockedAndWithoutHTTPS() async {
        let monitor = NetworkGuard.Monitor()
        await NetworkGuard.$monitor.withValue(monitor) {
            await #expect(throws: NetworkGuard.Blocked.self) {
                _ = try await LogoTransport().send(TenantLogoPolicy.brandingRequest(domain: "contoso.onmicrosoft.com"))
            }
        }
        #expect(monitor.blocked == ["a logo request to login.microsoftonline.com"])
        await #expect(throws: LogoTransport.Refused.self) {
            _ = try await LogoTransport().send(URLRequest(url: URL(string: "http://contoso.com/favicon.ico")!))
        }
        #expect(LogoTransport.userAgent == "Pimento/\(AppInfo.version)")
    }

    @Test func theLogoTransportSendsOnlyFixedHeaders() {
        // Foundation would otherwise add the user's preferred languages (Accept-Language: de-DE,…).
        for request in [TenantLogoPolicy.brandingRequest(domain: "contoso.onmicrosoft.com"),
                        TenantLogoPolicy.imageRequest(URL(string: "https://contoso.com/favicon.ico")!)] {
            let sent = LogoTransport.prepared(request)
            #expect(sent.value(forHTTPHeaderField: "User-Agent") == "Pimento/\(AppInfo.version)")
            #expect(sent.value(forHTTPHeaderField: "Accept-Language") == "en")
            #expect(!sent.httpShouldHandleCookies)
            let names = Set((sent.allHTTPHeaderFields ?? [:]).keys.map { $0.lowercased() })
            #expect(names.isSubset(of: ["user-agent", "accept-language", "accept", "content-type"]), "\(names)")
        }
    }

    @Test func theLogoTransportOffersNoCredentials() {
        for method in [NSURLAuthenticationMethodHTTPBasic, NSURLAuthenticationMethodHTTPDigest, NSURLAuthenticationMethodNTLM,
                       NSURLAuthenticationMethodNegotiate, NSURLAuthenticationMethodClientCertificate, NSURLAuthenticationMethodDefault] {
            #expect(LogoSessionDelegate.answer(method).0 == .cancelAuthenticationChallenge, "\(method)")
            #expect(LogoSessionDelegate.answer(method).1 == nil)
        }
        // The server's certificate is still checked as usual.
        #expect(LogoSessionDelegate.answer(NSURLAuthenticationMethodServerTrust).0 == .performDefaultHandling)
    }

    @Test func aCancelledFetchSendsNothingMoreAndCachesNothing() async {
        final class Box: @unchecked Sendable {
            private let lock = NSLock()
            private var task: Task<TenantLogo?, Never>?
            var value: Task<TenantLogo?, Never>? {
                get { lock.withLock { task } }
                set { lock.withLock { task = newValue } }
            }
        }
        let clock = LogoTestClock(Fixture.now)
        let box = Box()
        // The setting is turned off while the lookup is under way.
        let transport = RecordingTransport { r in
            if isBrandingLookup(r) { box.value?.cancel() }
            return (fakeImage(), 200)
        }
        let s = service(transport, clock: clock)
        let task = Task { () -> TenantLogo? in
            while box.value == nil { await Task.yield() }
            return await s.logo(for: tenant(), enabled: true, demo: false)
        }
        box.value = task
        #expect(await task.value == nil)
        #expect(await transport.requests.count == 1, "no image or website request after the cancel")
        #expect(s.cache.lookup(tenantId: contosoId, now: clock.now) == .missing, "not cached as \"no logo\"")
    }

    @Test func aTenantWithoutDomainsSendsAndCachesNothing() async {
        let clock = LogoTestClock(Fixture.now)
        let transport = brandingTransport()
        let s = service(transport, clock: clock)
        #expect(await s.logo(for: tenant(nil, domains: []), enabled: true, demo: false) == nil)
        #expect(await transport.requests.isEmpty)
        // Its domains may come with the next tenant list: nothing was remembered.
        #expect(s.cache.lookup(tenantId: contosoId, now: clock.now) == .missing)
        #expect(await s.logo(for: TenantInfo(id: "not-a-guid", defaultDomain: "contoso.com"), enabled: true, demo: false) == nil)
        #expect(await transport.requests.isEmpty)
    }

    // MARK: The image check

    @Test func onlyRealImageFormatsPass() {
        for (name, data) in [("HTML", Data("<!doctype html><html></html>".utf8)),
                             ("SVG", Data(#"<svg xmlns="http://www.w3.org/2000/svg"></svg>"#.utf8)),
                             ("JSON", Data("{}".utf8)), ("empty", Data()), ("PNG signature only", Data([0x89, 0x50, 0x4E, 0x47]))] {
            #expect(LogoImageCheck.inspect(data) == nil, "\(name)")
        }
        #expect(LogoImageCheck.format(of: Data([0x00, 0x00, 0x01, 0x00, 0x01])) == .ico)
        #expect(LogoImageCheck.format(of: Data([0xFF, 0xD8, 0xFF, 0xE0])) == .jpeg)
        #expect(LogoImageCheck.format(of: Data("GIF89a".utf8)) == .gif)
        #expect(LogoImageCheck.format(of: Data("RIFF\0\0\0\0WEBP".utf8)) == .webp)
    }

    #if canImport(ImageIO)
    private func png(width: Int, height: Int) throws -> Data {
        let ctx = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                         space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(CGColor(red: 0.1, green: 0.4, blue: 0.8, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try #require(ctx.makeImage())
        let out = NSMutableData()
        let dest = try #require(CGImageDestinationCreateWithData(out, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(dest, image, nil)
        #expect(CGImageDestinationFinalize(dest))
        return out as Data
    }

    private func encoded(_ type: String, width: Int = 64, height: Int = 64) throws -> Data {
        let ctx = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                         space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(CGColor(red: 0.8, green: 0.2, blue: 0.1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try #require(ctx.makeImage())
        let out = NSMutableData()
        let dest = try #require(CGImageDestinationCreateWithData(out, type as CFString, 1, nil))
        CGImageDestinationAddImage(dest, image, nil)
        #expect(CGImageDestinationFinalize(dest))
        return out as Data
    }

    @Test func everyAcceptedFormatDecodes() throws {
        for type in ["public.png", "public.jpeg", "com.compuserve.gif", "com.microsoft.bmp", "com.microsoft.ico"] {
            #expect(LogoImageCheck.inspect(try encoded(type)) == LogoImageInfo(width: 64, height: 64), "\(type)")
        }
    }

    @Test func imageIOMustReadTheFormatTheMagicNames() {
        // Starts with the ICO magic (00 00 01 00), yet ImageIO hands it to its TGA parser.
        let tga = Data([0x00, 0x00, 0x01, 0x00, 0x10, 0x10, 0x80, 0x10, 0x00, 0x20, 0x20, 0x00, 0x00, 0x10, 0x80, 0x10, 0x20, 0x10])
        #expect(LogoImageCheck.format(of: tga) == .ico)
        let picked = CGImageSourceCreateWithData(tga as CFData, nil).flatMap { CGImageSourceGetType($0) as String? }
        #expect(LogoImageCheck.source(tga) == nil, "ImageIO reads it as \(picked ?? "nothing")")
        #expect(LogoImageCheck.inspect(tga) == nil)
        #expect(LogoImageCheck.thumbnail(tga, maxPixels: 64) == nil)
    }

    @Test func realImagesAreDecodedAndSized() throws {
        #expect(LogoImageCheck.inspect(try png(width: 64, height: 64)) == LogoImageInfo(width: 64, height: 64))
        #expect(LogoImageCheck.inspect(try png(width: 240, height: 180)) != nil)
        #expect(LogoImageCheck.inspect(try png(width: 16, height: 16)) == nil, "too small for a badge")
        #expect(LogoImageCheck.inspect(try png(width: 245, height: 36)) == nil, "a banner does not fit a square")
        var truncated = try png(width: 64, height: 64)
        truncated = truncated.prefix(40)
        #expect(LogoImageCheck.inspect(truncated) == nil, "a cut-off file does not decode")
        let thumb = try #require(LogoImageCheck.thumbnail(try png(width: 512, height: 512), maxPixels: 96))
        #expect(max(thumb.width, thumb.height) <= 96)
    }
    #endif
}
