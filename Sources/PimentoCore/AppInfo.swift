import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum AppInfo {
    public static let name = "Pimento"
    /// Keep in sync with CHANGELOG.md; scripts/bundle.sh reads it from here.
    public static let version = "0.2.0"
    public static let tagline = "Bulk-activate your Azure PIM roles"
    public static let repositoryURL = URL(string: "https://github.com/melvin2306/pimento")!
    public static let issuesURL = URL(string: "https://github.com/melvin2306/pimento/issues")!
}

extension AppInfo {
    /// The `User-Agent` of the requests Pimento sends outside Azure (the
    /// update check, tenant logos): the name and version, nothing else.
    public static var userAgent: String { "\(name)/\(version)" }
    /// Their `Accept-Language`: the same for everyone (otherwise Foundation
    /// adds the user's preferred languages, `de-DE,…`).
    public static let fixedAcceptLanguage = "en"
}

extension URLRequest {
    /// Sets the only headers that say who asks (`AppInfo.userAgent`, the
    /// fixed `Accept-Language`) and turns cookies off. Shared by the update
    /// check and the logo fetch.
    mutating func setAnonymousClientHeaders() {
        httpShouldHandleCookies = false
        setValue(AppInfo.userAgent, forHTTPHeaderField: "User-Agent")
        setValue(AppInfo.fixedAcceptLanguage, forHTTPHeaderField: "Accept-Language")
    }
}
