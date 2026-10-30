import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(ImageIO)
import ImageIO
#endif

// Tenant logos (Settings › General › Fetch tenant logos, off by default).
//
// For each tenant shown, Pimento asks, unauthenticated and without cookies:
//
// 1. Microsoft's sign-in service for the tenant's sign-in page branding:
//    `POST https://login.microsoftonline.com/common/GetCredentialType` with
//    `{"username":"pimento-logo-lookup@<the tenant's verified domain>"}` (the
//    `.onmicrosoft.com` one when listed), then downloads its square `TileLogo`
//    from Microsoft's branding CDN (`cdnHosts`) only;
// 2. else the tenant's own website: `https://<first verified domain that is
//    not Microsoft's>/apple-touch-icon.png`, then `/favicon.ico`;
// 3. else nothing: the monogram stays.
//
// No token, no account and no cookie is sent anywhere. Every answer is
// capped in size and must decode as an image; any failure means "no logo".

/// Where a cached logo came from.
public enum TenantLogoSource: String, Codable, Sendable {
    /// Microsoft's sign-in page branding (`TileLogo`).
    case branding
    /// The tenant's website (`apple-touch-icon.png` or `favicon.ico`).
    case website
}

public struct TenantLogo: Equatable, Sendable {
    /// The image file as downloaded (PNG, JPEG, GIF, ICO, BMP or WebP).
    public let data: Data
    public let source: TenantLogoSource

    public init(data: Data, source: TenantLogoSource) {
        self.data = data
        self.source = source
    }
}

/// The rules: which domains, URLs and hosts, and the limits.
public enum TenantLogoPolicy {
    /// The sign-in page's unauthenticated user-realm lookup. Undocumented:
    /// its answer is decoded strictly and anything odd counts as "no logo".
    public static let brandingURL = URL(string: "https://login.microsoftonline.com/common/GetCredentialType")!
    /// The account name sent with the lookup: no such user exists, and the name
    /// says what it is for to whoever at Microsoft sees it. The lookup is not a
    /// sign-in attempt; Microsoft does not document what it records about it.
    public static let lookupUser = "pimento-logo-lookup"
    /// Microsoft's branding CDNs, as `organizationalBranding.cdnList` lists them
    /// (Microsoft Graph documentation). Logos are downloaded from these only.
    public static let cdnHosts: Set<String> = ["aadcdn.msftauthimages.net", "aadcdn.msauthimages.net", "secure.aadcdn.microsoftonline-p.com"]
    /// Largest answer read, for the lookup and for images.
    public static let maxBytes = 512 * 1024
    /// How long a logo, or the finding that there is none, is kept.
    public static let ttl: TimeInterval = 7 * 86400
    public static let timeout: TimeInterval = 10
    /// Redirects followed for a website icon (same domain, HTTPS only).
    public static let maxRedirects = 3
    /// Smallest and largest side accepted, in pixels.
    public static let minPixels = 32
    public static let maxPixels = 4096
    /// Wider or taller than this does not fit a square badge.
    public static let maxAspectRatio = 2.0

    /// Domains hosted by Microsoft: they name the tenant, not a company website.
    static let microsoftSuffixes = [".onmicrosoft.com", ".onmicrosoft.de", ".onmicrosoft.us", ".onmschina.cn"]
    /// Names that never reach a public website.
    static let reservedSuffixes = [".local", ".localhost", ".internal", ".intranet", ".lan", ".corp", ".home", ".arpa",
                                   ".example", ".invalid", ".test", ".onion"]

    /// The tenant's verified domains, default first, cleaned, without duplicates.
    static func candidateDomains(_ tenant: TenantInfo) -> [String] {
        var seen = Set<String>()
        return ([tenant.defaultDomain] + tenant.domains.map(Optional.some)).compactMap { raw in
            guard let d = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), isPublicHostname(d),
                  seen.insert(d).inserted else { return nil }
            return d
        }
    }

    static func isMicrosoftHosted(_ domain: String) -> Bool {
        microsoftSuffixes.contains { domain.hasSuffix($0) }
    }

    /// The domain for the branding lookup: the tenant's `.onmicrosoft.com`
    /// domain (always the tenant's own), else its first verified domain.
    public static func brandingDomain(for tenant: TenantInfo) -> String? {
        let domains = candidateDomains(tenant)
        return domains.first(where: { $0.hasSuffix(".onmicrosoft.com") }) ?? domains.first
    }

    /// The domain whose website icon is tried: the first verified domain that
    /// is not Microsoft's (the default domain when it qualifies).
    public static func websiteDomain(for tenant: TenantInfo) -> String? {
        candidateDomains(tenant).first { !isMicrosoftHosted($0) }
    }

    /// A DNS name of two or more labels with an alphabetic top-level label: no
    /// IP literal, no single-label or reserved name, nothing that looks like a flag.
    static func isPublicHostname(_ host: String) -> Bool {
        guard (4...253).contains(host.count), !host.hasPrefix("-") else { return false }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2, let tld = labels.last, tld.count >= 2, tld.allSatisfy({ $0.isASCII && $0.isLetter }) else { return false }
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789-")
        for label in labels {
            guard (1...63).contains(label.count), label.allSatisfy(allowed.contains),
                  label.first != "-", label.last != "-" else { return false }
        }
        return !reservedSuffixes.contains { host.hasSuffix($0) }
    }

    /// HTTPS on the default port, no credentials in the URL.
    static func isPlainHTTPS(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https" && (url.port == nil || url.port == 443) && url.user == nil && url.password == nil
            && url.host != nil
    }

    /// A logo URL from the branding answer: HTTPS on one of `cdnHosts`.
    public static func isAllowedBrandingImage(_ url: URL) -> Bool {
        guard isPlainHTTPS(url), let host = url.host?.lowercased() else { return false }
        return cdnHosts.contains(host)
    }

    /// Where a website icon may redirect: HTTPS on the domain, `www.` of it, or
    /// a subdomain (and the bare domain from `www.`).
    static func isAllowedWebsiteURL(_ url: URL, domain: String) -> Bool {
        guard isPlainHTTPS(url), let host = url.host?.lowercased(), isPublicHostname(host) else { return false }
        let bare = domain.hasPrefix("www.") ? String(domain.dropFirst(4)) : domain
        return host == bare || host.hasSuffix("." + bare)
    }

    public static func websiteIconURLs(domain: String) -> [URL] {
        ["apple-touch-icon.png", "favicon.ico"].compactMap { URL(string: "https://\(domain)/\($0)") }
    }

    /// The lookup request: what is sent, and all that is sent.
    public static func brandingRequest(domain: String) -> URLRequest {
        var request = URLRequest(url: brandingURL, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["username": "\(lookupUser)@\(domain)"], options: [.sortedKeys])
        return request
    }

    static func imageRequest(_ url: URL) -> URLRequest {
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "GET"
        request.setValue("image/png,image/x-icon,image/*;q=0.8", forHTTPHeaderField: "Accept")
        return request
    }

    /// The `TileLogo` of the first branding that has one, when its URL is on
    /// Microsoft's CDN. `BannerLogo` is not used: Microsoft caps it at 245 × 36
    /// pixels, unreadable in a square badge. A missing field, a field of the
    /// wrong type, an unexpected shape: nil.
    public static func tileLogoURL(fromBranding data: Data) -> URL? {
        struct Answer: Decodable {
            struct Properties: Decodable { let UserTenantBranding: [Branding]? }
            struct Branding: Decodable {
                let TileLogo: String?
                let BannerLogo: String?
            }
            let EstsProperties: Properties?
        }
        guard data.count <= maxBytes, let answer = try? JSONDecoder().decode(Answer.self, from: data) else { return nil }
        for branding in answer.EstsProperties?.UserTenantBranding ?? [] {
            guard let text = branding.TileLogo?.trimmingCharacters(in: .whitespaces), !text.isEmpty else { continue }
            guard let url = URL(string: text), isAllowedBrandingImage(url) else { return nil }
            return url
        }
        return nil
    }
}

/// What an image check found out.
public struct LogoImageInfo: Equatable, Sendable {
    public let width: Int
    public let height: Int

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }
}

/// Is it a real, reasonably sized image? Sniffs the format, then (with
/// ImageIO) reads the size of its largest frame without decoding it and
/// decodes a small thumbnail.
public enum LogoImageCheck {
    enum Format { case png, jpeg, gif, ico, bmp, webp }

    static func format(of data: Data) -> Format? {
        let b = [UInt8](data.prefix(12))
        func starts(_ prefix: [UInt8]) -> Bool { b.count >= prefix.count && Array(b.prefix(prefix.count)) == prefix }
        if starts([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) { return .png }
        if starts([0xFF, 0xD8, 0xFF]) { return .jpeg }
        if starts(Array("GIF87a".utf8)) || starts(Array("GIF89a".utf8)) { return .gif }
        if starts([0x00, 0x00, 0x01, 0x00]) { return .ico }
        if starts([0x42, 0x4D]) { return .bmp }
        if b.count >= 12, starts(Array("RIFF".utf8)), Array(b[8..<12]) == Array("WEBP".utf8) { return .webp }
        return nil
    }

    /// The image's size when it is one Pimento shows; nil for anything else
    /// (not an image, SVG or HTML, too small, too large, too wide).
    public static func inspect(_ data: Data) -> LogoImageInfo? {
        guard !data.isEmpty, data.count <= TenantLogoPolicy.maxBytes, format(of: data) != nil else { return nil }
        #if canImport(ImageIO)
        guard let info = largestFrame(data), thumbnail(data, maxPixels: 64) != nil else { return nil }
        #else
        // Without ImageIO (Linux, Windows: the CLI, which shows no logos) only a PNG's size is known.
        let info = pngSize(data) ?? LogoImageInfo(width: TenantLogoPolicy.minPixels, height: TenantLogoPolicy.minPixels)
        #endif
        let (w, h) = (info.width, info.height)
        guard min(w, h) >= TenantLogoPolicy.minPixels, max(w, h) <= TenantLogoPolicy.maxPixels,
              Double(max(w, h)) / Double(min(w, h)) <= TenantLogoPolicy.maxAspectRatio else { return nil }
        return info
    }

    /// Width and height from a PNG's IHDR chunk.
    static func pngSize(_ data: Data) -> LogoImageInfo? {
        let b = [UInt8](data.prefix(24))
        guard b.count == 24, format(of: data) == .png, Array(b[12..<16]) == Array("IHDR".utf8) else { return nil }
        func be(_ i: Int) -> Int { Int(b[i]) << 24 | Int(b[i + 1]) << 16 | Int(b[i + 2]) << 8 | Int(b[i + 3]) }
        return LogoImageInfo(width: be(16), height: be(20))
    }

    #if canImport(ImageIO)
    /// The ImageIO types each sniffed format may be read as. ImageIO picks its
    /// own parser from the bytes: a file with the ICO magic can be read as
    /// TGA, so the type it picked must be the one the magic named.
    static let imageIOTypes: [Format: Set<String>] = [
        .png: ["public.png"], .jpeg: ["public.jpeg", "public.mpo-image"], .gif: ["com.compuserve.gif"],
        .ico: ["com.microsoft.ico"], .bmp: ["com.microsoft.bmp"], .webp: ["org.webmproject.webp"],
    ]

    static func source(_ data: Data) -> CGImageSource? {
        guard let format = format(of: data),
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let type = CGImageSourceGetType(source) as String?, imageIOTypes[format]?.contains(type) == true else { return nil }
        return source
    }

    /// The index and size of the largest frame (an `.ico` holds several).
    static func largestFrameIndex(_ source: CGImageSource) -> (Int, LogoImageInfo)? {
        var best: (Int, LogoImageInfo)?
        for i in 0..<min(CGImageSourceGetCount(source), 32) {
            guard let props = CGImageSourceCopyPropertiesAtIndex(source, i, nil) as? [CFString: Any],
                  let w = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
                  let h = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue, w > 0, h > 0 else { continue }
            if best == nil || w * h > best!.1.width * best!.1.height { best = (i, LogoImageInfo(width: w, height: h)) }
        }
        return best
    }

    static func largestFrame(_ data: Data) -> LogoImageInfo? {
        source(data).flatMap(largestFrameIndex)?.1
    }

    /// A decoded thumbnail of the largest frame, at most `maxPixels` on its
    /// long side: ImageIO scales while decoding, so a huge image never lands
    /// in memory whole. What the app draws.
    public static func thumbnail(_ data: Data, maxPixels: Int) -> CGImage? {
        guard data.count <= TenantLogoPolicy.maxBytes, let source = source(data), let (index, info) = largestFrameIndex(source),
              max(info.width, info.height) <= TenantLogoPolicy.maxPixels else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, index, options as CFDictionary)
    }
    #endif
}

/// Fetches one tenant's logo over `transport`; never throws: no logo is nil.
public struct TenantLogoFetcher: Sendable {
    let transport: HTTPTransport
    let inspect: @Sendable (Data) -> LogoImageInfo?

    public init(transport: HTTPTransport = LogoTransport(), inspect: @escaping @Sendable (Data) -> LogoImageInfo? = { LogoImageCheck.inspect($0) }) {
        self.transport = transport
        self.inspect = inspect
    }

    /// Branding first, then the website, else nil.
    public func fetch(_ tenant: TenantInfo) async -> TenantLogo? {
        if let domain = TenantLogoPolicy.brandingDomain(for: tenant), let logo = await branding(domain: domain) { return logo }
        if let domain = TenantLogoPolicy.websiteDomain(for: tenant), let logo = await website(domain: domain) { return logo }
        return nil
    }

    func branding(domain: String) async -> TenantLogo? {
        guard !Task.isCancelled, let (data, status) = try? await transport.send(TenantLogoPolicy.brandingRequest(domain: domain)), status == 200,
              let url = TenantLogoPolicy.tileLogoURL(fromBranding: data),
              let image = await download(url, allowed: TenantLogoPolicy.isAllowedBrandingImage) else { return nil }
        return TenantLogo(data: image, source: .branding)
    }

    func website(domain: String) async -> TenantLogo? {
        for url in TenantLogoPolicy.websiteIconURLs(domain: domain) {
            if let image = await download(url, allowed: { TenantLogoPolicy.isAllowedWebsiteURL($0, domain: domain) }) {
                return TenantLogo(data: image, source: .website)
            }
        }
        return nil
    }

    /// GETs `url`, following up to `maxRedirects` redirects that `allowed`
    /// accepts; the image bytes when the answer is a 200 within the size cap
    /// that passes the image check.
    func download(_ url: URL, allowed: (URL) -> Bool) async -> Data? {
        var next = url
        for _ in 0...TenantLogoPolicy.maxRedirects {
            // Turned off or cleared meanwhile: no further request.
            guard !Task.isCancelled, allowed(next) else { return nil }
            do {
                let (data, status) = try await transport.send(TenantLogoPolicy.imageRequest(next))
                guard status == 200, data.count <= TenantLogoPolicy.maxBytes, inspect(data) != nil else { return nil }
                return data
            } catch let redirect as URLSessionTransport.RedirectRefused {
                guard let location = redirect.location, let target = URL(string: location, relativeTo: next)?.absoluteURL else { return nil }
                next = target
            } catch {
                return nil
            }
        }
        return nil
    }
}

/// The logos on disk, one pair of files per tenant in `directory`:
/// `<tenant-id>.json` (when it was fetched, and from where, or that there is
/// none) and `<tenant-id>.img` (the image). Mode 600 in a 700 folder.
public struct TenantLogoCache: Sendable {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    /// `TenantLogos` in Pimento's folder (`PimentoPaths.dataDirectory`).
    public static func defaultDirectory(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        PimentoPaths.dataDirectory(environment: environment).appendingPathComponent("TenantLogos", isDirectory: true)
    }

    public enum Lookup: Equatable, Sendable {
        /// Fetched within the TTL: the logo, or nil when there is none.
        case fresh(TenantLogo?)
        /// Never fetched, or older than the TTL.
        case missing
    }

    struct Entry: Codable {
        var fetchedAt: Date
        /// nil: looked, found nothing.
        var source: TenantLogoSource?
    }

    /// Lower-case GUIDs only: the ID becomes a file name.
    static func key(_ tenantId: String) -> String? {
        guard UUID(uuidString: tenantId) != nil else { return nil }
        return tenantId.lowercased()
    }

    func files(_ key: String) -> (entry: URL, image: URL) {
        (directory.appendingPathComponent("\(key).json"), directory.appendingPathComponent("\(key).img"))
    }

    public func lookup(tenantId: String, now: Date, ttl: TimeInterval = TenantLogoPolicy.ttl) -> Lookup {
        guard let key = Self.key(tenantId) else { return .missing }
        let (entryURL, imageURL) = files(key)
        guard let data = try? Data(contentsOf: entryURL), let entry = try? Self.decoder.decode(Entry.self, from: data) else { return .missing }
        let age = now.timeIntervalSince(entry.fetchedAt)
        // A date in the future (clock moved back) counts as expired.
        guard age >= 0, age < ttl else { return .missing }
        guard let source = entry.source else { return .fresh(nil) }
        guard let image = try? Data(contentsOf: imageURL), !image.isEmpty, image.count <= TenantLogoPolicy.maxBytes else { return .missing }
        return .fresh(TenantLogo(data: image, source: source))
    }

    /// Records `logo` (nil: none found) as fetched at `now`.
    public func store(tenantId: String, logo: TenantLogo?, now: Date) throws {
        guard let key = Self.key(tenantId) else { return }
        let (entryURL, imageURL) = files(key)
        if let logo {
            try PrivateFile.write(logo.data, to: imageURL)
        } else {
            try? FileManager.default.removeItem(at: imageURL)
        }
        try PrivateFile.write(Self.encoder.encode(Entry(fetchedAt: now, source: logo?.source)), to: entryURL)
    }

    /// Forgets one tenant's logo.
    public func remove(tenantId: String) {
        guard let key = Self.key(tenantId) else { return }
        let (entryURL, imageURL) = files(key)
        try? FileManager.default.removeItem(at: entryURL)
        try? FileManager.default.removeItem(at: imageURL)
    }

    /// Deletes the folder and everything in it.
    public func clear() {
        try? FileManager.default.removeItem(at: directory)
    }

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}

/// Cache first, then the network: what the app asks for each tenant it shows.
public struct TenantLogoService: Sendable {
    public let cache: TenantLogoCache
    let fetcher: TenantLogoFetcher
    let clock: @Sendable () -> Date

    public init(cache: TenantLogoCache, fetcher: TenantLogoFetcher = TenantLogoFetcher(), clock: @escaping @Sendable () -> Date = { Date() }) {
        self.cache = cache
        self.fetcher = fetcher
        self.clock = clock
    }

    /// Logos are fetched only with the setting on, never in demo mode, and
    /// never while the network is blocked (demo mode, tests).
    public static func isAllowed(enabled: Bool, demo: Bool) -> Bool {
        enabled && !demo && NetworkGuard.monitor == nil && NetworkGuard.processWide == nil
    }

    /// The tenant's logo: from the cache while fresh, else fetched and cached.
    /// nil when there is none, and always (without reading the cache or
    /// sending anything) when `isAllowed` says no. A tenant without a usable
    /// domain sends nothing and caches nothing: its domains may arrive later.
    public func logo(for tenant: TenantInfo, enabled: Bool, demo: Bool, refresh: Bool = false) async -> TenantLogo? {
        guard Self.isAllowed(enabled: enabled, demo: demo), TenantLogoCache.key(tenant.id) != nil else { return nil }
        if !refresh, case .fresh(let logo) = cache.lookup(tenantId: tenant.id, now: clock()) { return logo }
        guard TenantLogoPolicy.brandingDomain(for: tenant) != nil || TenantLogoPolicy.websiteDomain(for: tenant) != nil else { return nil }
        let logo = await fetcher.fetch(tenant)
        // Cancelled (the setting was turned off): an answer cut short is not "no logo".
        guard !Task.isCancelled else { return nil }
        try? cache.store(tenantId: tenant.id, logo: logo, now: clock())
        return logo
    }
}

/// The transport for logos: URLSession with no cookies, no cache, no stored
/// credentials, a plain `User-Agent` and a fixed `Accept-Language`; HTTPS
/// only; redirects and authentication challenges refused (the fetcher decides
/// which redirects to follow); answers over `maxBytes` abandoned while they
/// download. Refused while the network is blocked (demo mode).
public struct LogoTransport: HTTPTransport {
    public struct Refused: Error, Equatable {
        public let reason: String
    }

    public let maxBytes: Int

    public init(maxBytes: Int = TenantLogoPolicy.maxBytes) {
        self.maxBytes = maxBytes
    }

    public static var userAgent: String { "\(AppInfo.name)/\(AppInfo.version)" }

    static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieAcceptPolicy = .never
        config.httpShouldSetCookies = false
        config.httpCookieStorage = nil
        config.urlCache = nil
        config.urlCredentialStorage = nil
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        config.timeoutIntervalForRequest = TenantLogoPolicy.timeout
        config.timeoutIntervalForResource = TenantLogoPolicy.timeout * 2
        return URLSession(configuration: config, delegate: LogoSessionDelegate.shared, delegateQueue: nil)
    }()

    /// What `send` adds to every request: no cookies, `User-Agent: Pimento/<version>`
    /// and `Accept-Language: en` (otherwise Foundation sends the user's preferred languages).
    static func prepared(_ request: URLRequest) -> URLRequest {
        var request = request
        request.httpShouldHandleCookies = false
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("en", forHTTPHeaderField: "Accept-Language")
        return request
    }

    public func send(_ request: URLRequest) async throws -> (Data, Int) {
        try NetworkGuard.check("a logo request to \(request.url?.host ?? "?")")
        guard let url = request.url, TenantLogoPolicy.isPlainHTTPS(url) else { throw Refused(reason: "not HTTPS") }
        let request = Self.prepared(request)
        #if canImport(Darwin)
        let (bytes, response) = try await Self.session.bytes(for: request, delegate: LogoSessionDelegate.shared)
        let http = response as? HTTPURLResponse
        let status = http?.statusCode ?? 0
        try URLSessionTransport.check(status: status, location: http?.value(forHTTPHeaderField: "Location"), requested: url, answered: response.url)
        if response.expectedContentLength > Int64(maxBytes) { throw Refused(reason: "too large") }
        var data = Data()
        for try await byte in bytes {
            data.append(byte)
            if data.count > maxBytes { throw Refused(reason: "too large") }
        }
        return (data, status)
        #else
        let (data, response) = try await Self.session.data(for: request, delegate: LogoSessionDelegate.shared)
        let http = response as? HTTPURLResponse
        let status = http?.statusCode ?? 0
        try URLSessionTransport.check(status: status, location: http?.value(forHTTPHeaderField: "Location"), requested: url, answered: response.url)
        guard data.count <= maxBytes else { throw Refused(reason: "too large") }
        return (data, status)
        #endif
    }
}

/// The logo session's delegate: refuses every redirect (as `RedirectRefusal`)
/// and every authentication challenge but the server's certificate check, so
/// that no credential (a Kerberos ticket, a client certificate, a password)
/// is ever offered to a tenant's website.
final class LogoSessionDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    static let shared = LogoSessionDelegate()

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        let (disposition, credential) = Self.answer(challenge.protectionSpace.authenticationMethod)
        completionHandler(disposition, credential)
    }

    /// The server's certificate check (swift-corelibs-foundation has no such
    /// challenge and marks the constant unavailable).
    #if canImport(Darwin)
    static let serverTrust = NSURLAuthenticationMethodServerTrust
    #else
    static let serverTrust = "NSURLAuthenticationMethodServerTrust"
    #endif

    /// The certificate check runs as usual; anything else is cancelled.
    static func answer(_ authenticationMethod: String) -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        authenticationMethod == serverTrust ? (.performDefaultHandling, nil) : (.cancelAuthenticationChallenge, nil)
    }
}
