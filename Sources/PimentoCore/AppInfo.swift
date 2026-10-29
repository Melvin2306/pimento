import Foundation

public enum AppInfo {
    public static let name = "Pimento"
    /// Keep in sync with CHANGELOG.md; scripts/bundle.sh reads it from here.
    public static let version = "0.1.0"
    public static let tagline = "Bulk-activate your Azure PIM roles"
    public static let repositoryURL = URL(string: "https://github.com/melvin2306/pimento")!
    public static let issuesURL = URL(string: "https://github.com/melvin2306/pimento/issues")!
}
