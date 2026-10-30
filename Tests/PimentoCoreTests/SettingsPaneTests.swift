import Testing
@testable import PimentoCore

@Suite("Settings window")
struct SettingsPaneTests {
    @Test func panesInToolbarOrderWithDistinctTitlesAndSymbols() {
        #expect(SettingsPane.allCases.map(\.title) == ["General", "Appearance", "Account", "Activation", "Notifications", "History"])
        #expect(Set(SettingsPane.allCases.map(\.symbolName)).count == SettingsPane.allCases.count)
    }

    @Test func autoRefreshAndLeadTimeTitles() {
        #expect(Preferences.autoRefreshOptions.map(SettingsText.autoRefresh(minutes:)) == ["Off", "Every minute", "Every 5 minutes", "Every 15 minutes"])
        #expect(SettingsText.reminderLead(minutes: 10) == "10 minutes before")
        #expect(SettingsText.reminderLead(minutes: 1) == "1 minute before")
    }

    @Test func menuBarStatusFollowsTheOptions() {
        #expect(SettingsText.menuBarStatus(showInMenuBar: false, hideDockIcon: true, appName: "P") == "Without the menu bar icon, closing the window quits P.")
        #expect(SettingsText.menuBarStatus(showInMenuBar: true, hideDockIcon: true, appName: "P").hasPrefix("P runs in the menu bar only"))
        #expect(SettingsText.menuBarStatus(showInMenuBar: true, hideDockIcon: false, appName: "P").hasPrefix("Closing the window keeps P running"))
    }

    @Test func lightOnlyNoteOnlyForLightOnlyThemes() {
        for mode in AppearanceMode.allCases {
            #expect(SettingsText.lightOnlyNote(theme: .native, mode: mode) == nil)
            #expect(SettingsText.lightOnlyNote(theme: .azure, mode: mode) == nil)
        }
        #expect(SettingsText.lightOnlyNote(theme: .windowsXP, mode: .light) == "Windows XP-style is light-only.")
        #expect(SettingsText.lightOnlyNote(theme: .windowsXP, mode: .system) == "Windows XP-style is light-only.")
        #expect(SettingsText.lightOnlyNote(theme: .windowsXP, mode: .ultraDark)?.hasSuffix("Ultra dark applies again with another theme.") == true)
        #expect(SettingsText.lightOnlyNote(theme: .windowsXP, mode: .timeOfDay)?.contains("schedule") == true)
    }

    @Test func ownerConfirmationNoteWarnsWhenOff() {
        #expect(SettingsText.ownerConfirmation(isOn: true).hasSuffix("Recommended."))
        #expect(SettingsText.ownerConfirmation(isOn: false).hasPrefix("Owner roles are activated without asking"))
    }

    @Test func rememberedCountsUseSingulars() {
        #expect(SettingsText.remembered(justifications: 3, tickets: 1) == "3 justifications, 1 ticket")
        #expect(SettingsText.remembered(justifications: 0, tickets: 0) == "0 justifications, 0 tickets")
    }

    @Test func everyThemeHasACardText() {
        for theme in AppTheme.allCases {
            #expect(!theme.summary.isEmpty && theme.details.count > theme.summary.count)
        }
        #expect(AppTheme.windowsXP.details.contains("Light only"))
    }
}
