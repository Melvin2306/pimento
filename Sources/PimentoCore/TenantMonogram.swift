import Foundation

/// A tenant's offline badge: one or two initials on a colour picked from the
/// tenant ID. Used wherever a tenant is shown, unless a logo was fetched.
public struct TenantMonogram: Equatable, Sendable {
    public let initials: String
    public let color: MonogramColor

    public init(initials: String, color: MonogramColor) {
        self.initials = initials
        self.color = color
    }

    public init(tenant: TenantInfo) {
        self.init(initials: Self.initials(name: tenant.displayName, domain: tenant.defaultDomain),
                  color: Self.color(for: tenant.id))
    }

    /// What unnamed tenants without a domain show.
    public static let unknownInitials = "?"

    /// Rules, in order:
    /// - the display name, else the domain's first label (`www.` skipped,
    ///   hyphens as word breaks), else `?`;
    /// - text in brackets or parentheses is dropped (`Contoso (Test)`), and so are
    ///   legal forms anywhere but the first word (`SE`, `GmbH`, `& Co. KG`, `Inc.`, `Ltd`,
    ///   `LLC`, …) and filler words (`The`, `of`, `and`, …), unless nothing would be left;
    /// - two or more words: the first letter or digit of the first and the last word
    ///   (`Northwind Traders` → `NT`); one word: its first (`Contoso` → `C`);
    /// - Chinese, Japanese and Korean names give one character: two would not fit.
    public static func initials(name: String?, domain: String?) -> String {
        if let name, let fromName = initials(of: words(in: name, stripLegalForms: true)) { return fromName }
        if let label = domainLabel(domain), let fromDomain = initials(of: words(in: label, stripLegalForms: false)) {
            return fromDomain
        }
        return unknownInitials
    }

    /// The palette colour for a tenant ID: stable across launches and machines
    /// (FNV-1a of the lower-cased ID, not Swift's per-process `hashValue`).
    public static func color(for tenantId: String) -> MonogramColor {
        MonogramColor.palette[colorIndex(for: tenantId)]
    }

    static func colorIndex(for tenantId: String) -> Int {
        var hash: UInt32 = 2_166_136_261
        for byte in tenantId.lowercased().utf8 {
            hash ^= UInt32(byte)
            hash = hash &* 16_777_619
        }
        return Int(hash % UInt32(MonogramColor.palette.count))
    }

    // MARK: Words

    /// Legal forms, compared lower-cased with dots removed (`e.V.` → `ev`).
    static let legalForms: Set<String> = [
        "ab", "ag", "as", "asa", "bhd", "bv", "co", "corp", "corporation", "ev", "gbr", "gmbh", "inc",
        "incorporated", "kft", "kg", "kgaa", "kk", "limited", "llc", "llp", "lp", "ltd", "mbh", "nv", "ohg",
        "oy", "oyj", "plc", "pte", "pty", "sa", "sarl", "sas", "sdn", "se", "sl", "spa", "sro", "srl", "ug",
    ]

    /// Words that start many company names but say little.
    static let fillerWords: Set<String> = ["the", "of", "and", "und", "for", "de", "la", "le", "der", "die", "das", "von", "et"]

    /// Legal forms written without spaces in Chinese and Japanese names.
    static let cjkLegalAffixes = ["股份有限公司", "有限公司", "株式会社", "有限会社", "合同会社", "(株)", "（株）", "㈱"]

    static let separators = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ",/|&+·•:;"))

    static func words(in text: String, stripLegalForms: Bool) -> [String] {
        var text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let unbracketed = text.replacingOccurrences(of: #"\([^)]*\)|\[[^\]]*\]|（[^）]*）"#, with: " ", options: .regularExpression)
        if hasContent(unbracketed) { text = unbracketed }
        if stripLegalForms {
            for affix in cjkLegalAffixes {
                if text.hasPrefix(affix), hasContent(String(text.dropFirst(affix.count))) { text = String(text.dropFirst(affix.count)) }
                if text.hasSuffix(affix), hasContent(String(text.dropLast(affix.count))) { text = String(text.dropLast(affix.count)) }
            }
        }
        var words = text.components(separatedBy: separators)
            .map { $0.trimmingCharacters(in: CharacterSet.alphanumerics.inverted) }
            .filter(hasContent)
        let withoutFillers = words.filter { !fillerWords.contains($0.lowercased()) }
        if !withoutFillers.isEmpty { words = withoutFillers }
        if stripLegalForms, let first = words.first {
            words = [first] + words.dropFirst().filter { !legalForms.contains($0.lowercased().replacingOccurrences(of: ".", with: "")) }
        }
        return words
    }

    static func initials(of words: [String]) -> String? {
        guard let first = words.first.flatMap({ initial(of: $0) }) else { return nil }
        guard words.count > 1, !isWide(first), let last = words.last.flatMap({ initial(of: $0) }), !isWide(last) else { return first }
        return first + last
    }

    /// The first letter or digit, upper-cased where that stays one character
    /// (`ß` would become `SS`).
    static func initial(of word: String) -> String? {
        guard let c = word.first(where: { $0.isLetter || $0.isNumber }) else { return nil }
        let upper = String(c).uppercased()
        return upper.count == 1 ? upper : String(c)
    }

    /// Han, kana and Hangul: full-width characters.
    static func isWide(_ s: String) -> Bool {
        s.unicodeScalars.contains { scalar in
            let v = scalar.value
            return scalar.properties.isIdeographic
                || (0x3040...0x30FF).contains(v) || (0x31F0...0x31FF).contains(v) || (0xFF66...0xFF9F).contains(v)
                || (0x1100...0x11FF).contains(v) || (0x3130...0x318F).contains(v) || (0xAC00...0xD7AF).contains(v)
        }
    }

    static func hasContent(_ s: String) -> Bool {
        s.contains { $0.isLetter || $0.isNumber }
    }

    /// `contoso` from `www.contoso.com`, with hyphens and underscores as spaces.
    static func domainLabel(_ domain: String?) -> String? {
        guard var d = domain?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !d.isEmpty else { return nil }
        if d.hasPrefix("www.") { d.removeFirst(4) }
        guard let label = d.split(separator: ".").first else { return nil }
        return label.replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "_", with: " ")
    }
}

/// One badge colour. White initials on it reach WCAG AA (4.5:1) and the
/// badge stays visible on Pimento's darkest backgrounds (ultra dark's black)
/// and its lightest (white, the XP beige): `TenantMonogramTests` checks both.
public struct MonogramColor: Equatable, Sendable {
    public let name: String
    /// 0xRRGGBB.
    public let rgb: UInt32

    public init(name: String, rgb: UInt32) {
        self.name = name
        self.rgb = rgb
    }

    public static let palette: [MonogramColor] = [
        MonogramColor(name: "blue", rgb: 0x1F6FD1),
        MonogramColor(name: "indigo", rgb: 0x4F46E5),
        MonogramColor(name: "violet", rgb: 0x7C3AED),
        MonogramColor(name: "purple", rgb: 0x9333EA),
        MonogramColor(name: "magenta", rgb: 0xA21CAF),
        MonogramColor(name: "pink", rgb: 0xBE185D),
        MonogramColor(name: "red", rgb: 0xC62828),
        MonogramColor(name: "orange", rgb: 0xC2410C),
        MonogramColor(name: "amber", rgb: 0xA16207),
        MonogramColor(name: "green", rgb: 0x15803D),
        MonogramColor(name: "teal", rgb: 0x0F766E),
        MonogramColor(name: "cyan", rgb: 0x0E7490),
    ]

    /// WCAG relative luminance.
    public static func luminance(_ rgb: UInt32) -> Double {
        func channel(_ shift: UInt32) -> Double {
            let c = Double((rgb >> shift) & 0xFF) / 255
            return c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(16) + 0.7152 * channel(8) + 0.0722 * channel(0)
    }

    /// WCAG contrast ratio, 1 to 21.
    public static func contrast(_ a: UInt32, _ b: UInt32) -> Double {
        let (x, y) = (luminance(a), luminance(b))
        return (max(x, y) + 0.05) / (min(x, y) + 0.05)
    }
}
