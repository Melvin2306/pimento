import Foundation
import Testing
@testable import PimentoCore

@Suite("Tenant monograms")
struct TenantMonogramTests {
    private func initials(_ name: String?, domain: String? = nil) -> String {
        TenantMonogram.initials(name: name, domain: domain)
    }

    @Test func oneWordGivesOneLetterAndSeveralTheFirstAndLast() {
        #expect(initials("Contoso") == "C")
        #expect(initials("Northwind Traders") == "NT")
        #expect(initials("Adventure Works") == "AW")
        #expect(initials("Contoso Pharma Research") == "CR")
        #expect(initials("contoso holding") == "CH", "initials are upper-cased")
        #expect(initials("  Fabrikam  ") == "F")
    }

    @Test func legalFormsAreSkippedButNeverTheFirstWord() {
        #expect(initials("Contoso SE") == "C")
        #expect(initials("Fabrikam GmbH") == "F")
        #expect(initials("Fabrikam GmbH & Co. KG") == "F")
        #expect(initials("Woodgrove Bank Inc.") == "WB")
        #expect(initials("Northwind Traders Ltd") == "NT")
        #expect(initials("Northwind Traders LLC") == "NT")
        #expect(initials("Contoso AG") == "C")
        #expect(initials("Fabrikam e.V.") == "F")
        #expect(initials("Contoso S.p.A.") == "C")
        #expect(initials("Contoso Holding plc") == "CH")
        // Only a legal form: keep it rather than show nothing.
        #expect(initials("AG") == "A")
        #expect(initials("SE Contoso") == "SC")
    }

    @Test func fillerWordsAndBracketsAreSkipped() {
        #expect(initials("The Fabrikam Group") == "FG")
        #expect(initials("Bank of Woodgrove") == "BW")
        #expect(initials("Contoso (Test)") == "C")
        #expect(initials("Contoso Ltd [Staging]") == "C")
        #expect(initials("(Test)") == "T", "brackets around everything stay")
        #expect(initials("The") == "T", "a filler word alone stays")
    }

    @Test func digitsAndPunctuation() {
        #expect(initials("42 Labs") == "4L")
        #expect(initials("Contoso-Fabrikam") == "C", "a hyphenated name is one word")
        #expect(initials("Contoso / Fabrikam") == "CF")
        #expect(initials("\"Contoso\" Fabrikam") == "CF")
        #expect(initials("🚀 Rocket Contoso") == "RC", "symbols are not initials")
        #expect(initials("ßeta Werke") == "ßW", "ß stays one character")
    }

    @Test func nonLatinScripts() {
        #expect(initials("Контосо Групп") == "КГ")
        #expect(initials("Κοντόσο Ομάδα") == "ΚΟ")
        #expect(initials("株式会社コントソ") == "コ", "the legal prefix is skipped; one wide character")
        #expect(initials("コントソ株式会社") == "コ")
        #expect(initials("康拓索有限公司") == "康")
        #expect(initials("북풍 무역") == "북", "Hangul is wide too")
        #expect(initials("Contoso 日本") == "C", "no Latin letter next to a wide one")
    }

    @Test func anEmptyNameFallsBackToTheDomain() {
        #expect(initials(nil, domain: "adventure-works.example") == "AW")
        #expect(initials(nil, domain: "contoso.onmicrosoft.com") == "C")
        #expect(initials(nil, domain: "www.fabrikam.example") == "F")
        #expect(initials("", domain: "northwind.example") == "N")
        #expect(initials("   ", domain: "northwind.example") == "N")
        #expect(initials("---", domain: "northwind.example") == "N")
        #expect(initials(nil, domain: nil) == TenantMonogram.unknownInitials)
        #expect(initials("", domain: "") == "?")
    }

    @Test func demoTenantsGetTidyMonograms() {
        let monograms = DemoDirectory.tenants.map { TenantMonogram(tenant: $0.info) }
        #expect(monograms.map(\.initials) == ["C", "F", "NT", "AW", "?"])
        // Five tenants, at least three colours: they can be told apart.
        #expect(Set(monograms.map(\.color.name)).count >= 3)
    }

    @Test func theColourIsStableAndCaseInsensitive() {
        let id = "00000000-0000-0000-0000-0000000c0de0"
        let color = TenantMonogram.color(for: id)
        #expect(TenantMonogram.color(for: id) == color)
        #expect(TenantMonogram.color(for: id.uppercased()) == color)
        // FNV-1a, not hashValue: the same on every launch and machine.
        #expect(TenantMonogram.colorIndex(for: "") == Int(2_166_136_261 % UInt32(MonogramColor.palette.count)))
    }

    @Test func idsSpreadOverThePalette() {
        let ids = (0..<240).map { String(format: "00000000-0000-0000-0000-%012x", $0 * 7919) }
        let used = Set(ids.map { TenantMonogram.colorIndex(for: $0) })
        #expect(used.count == MonogramColor.palette.count)
    }

    @Test func thePaletteHasContrastInEveryTheme() {
        let palette = MonogramColor.palette
        #expect(Set(palette.map(\.rgb)).count == palette.count)
        #expect(Set(palette.map(\.name)).count == palette.count)
        for color in palette {
            // White initials: WCAG AA for normal text.
            #expect(MonogramColor.contrast(color.rgb, 0xFFFFFF) >= 4.5, "\(color.name) with white text")
            // The badge on the page: light, XP beige, dark, Azure dark, ultra dark.
            #expect(MonogramColor.contrast(color.rgb, 0xECE9D8) >= 4.0, "\(color.name) on the XP page")
            #expect(MonogramColor.contrast(color.rgb, 0x1E1E1E) >= 2.5, "\(color.name) on a dark window")
            #expect(MonogramColor.contrast(color.rgb, 0x1B1A19) >= 2.5, "\(color.name) on the Azure dark page")
            #expect(MonogramColor.contrast(color.rgb, 0x000000) >= 3.0, "\(color.name) on ultra dark black")
        }
        #expect(abs(MonogramColor.contrast(0x000000, 0xFFFFFF) - 21) < 0.01)
    }
}
