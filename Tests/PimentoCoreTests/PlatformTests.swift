import Foundation
import Testing
@testable import PimentoCore

@Suite("Platform: folders and paths")
struct PlatformPathTests {
    @Test func dataDirectoryPerPlatform() {
        #expect(PimentoPaths.dataDirectoryPath(environment: [:], home: "/Users/alex", platform: .macOS)
            == "/Users/alex/Library/Application Support/Pimento")
        #expect(PimentoPaths.dataDirectoryPath(environment: [:], home: "/home/alex", platform: .linux) == "/home/alex/.config/pimento")
        #expect(PimentoPaths.dataDirectoryPath(environment: ["XDG_CONFIG_HOME": "/cfg"], home: "/home/alex", platform: .linux)
            == "/cfg/pimento")
        #expect(PimentoPaths.dataDirectoryPath(environment: ["XDG_CONFIG_HOME": " "], home: "/home/alex", platform: .linux)
            == "/home/alex/.config/pimento")
        // macOS ignores XDG: the app and the CLI share Application Support.
        #expect(PimentoPaths.dataDirectoryPath(environment: ["XDG_CONFIG_HOME": "/cfg"], home: "/Users/alex", platform: .macOS)
            == "/Users/alex/Library/Application Support/Pimento")
        #expect(PimentoPaths.dataDirectoryPath(environment: ["APPDATA": #"C:\Users\alex\AppData\Roaming"#], home: #"C:\Users\alex"#,
                                               platform: .windows) == #"C:\Users\alex\AppData\Roaming\Pimento"#)
        #expect(PimentoPaths.dataDirectoryPath(environment: [:], home: #"C:\Users\alex"#, platform: .windows)
            == #"C:\Users\alex\AppData\Roaming\Pimento"#)
    }

    /// Presets, history, sign-in settings and the token file share one folder
    /// off macOS. (Linux paths: a Windows path is not a path on the test host.)
    @Test func everyFileSharesTheFolderOnLinux() {
        let env = ["XDG_CONFIG_HOME": "/cfg"]
        let dir = PimentoPaths.dataDirectory(environment: env, home: "/home/alex", platform: .linux).standardizedFileURL.path
        for url in [PresetStore.location(environment: env, home: "/home/alex", platform: .linux),
                    HistoryStore.location(environment: env, home: "/home/alex", platform: .linux),
                    AuthSettingsStore.location(environment: env, home: "/home/alex", platform: .linux),
                    FileTokenStore.location(environment: env, home: "/home/alex", platform: .linux)] {
            #expect(url.deletingLastPathComponent().standardizedFileURL.path == dir, "\(url.path)")
        }
    }

    @Test func pathListSeparator() {
        #expect(HostPlatform.windows.pathListSeparator == ";")
        #expect(HostPlatform.linux.pathListSeparator == ":")
        #expect(HostPlatform.windows.join(#"C:\a\"#, "b") == #"C:\a\b"#)
    }

    @Test func tildeExpansion() {
        #expect(PimentoPaths.expandTilde("~", home: "/home/u", platform: .linux) == "/home/u")
        #expect(PimentoPaths.expandTilde("~/a/b.json", home: "/home/u", platform: .linux) == "/home/u/a/b.json")
        #expect(PimentoPaths.expandTilde("~\\a.json", home: "/home/u", platform: .linux) == "~\\a.json")
        #expect(PimentoPaths.expandTilde("~\\a.json", home: #"C:\Users\u"#, platform: .windows) == #"C:\Users\u\a.json"#)
        #expect(PimentoPaths.expandTilde("~/a.json", home: #"C:\Users\u"#, platform: .windows) == #"C:\Users\u\a.json"#)
        #expect(PimentoPaths.expandTilde("/abs/~/x", home: "/home/u", platform: .linux) == "/abs/~/x")
    }

    @Test func displayedFolders() {
        #expect(PimentoPaths.displayFile("history.jsonl", platform: .macOS) == "~/Library/Application Support/Pimento/history.jsonl")
        #expect(PimentoPaths.displayFile("history.jsonl", platform: .linux) == "~/.config/pimento/history.jsonl")
        #expect(PimentoPaths.displayFile("history.jsonl", platform: .windows) == #"%APPDATA%\Pimento\history.jsonl"#)
    }
}
