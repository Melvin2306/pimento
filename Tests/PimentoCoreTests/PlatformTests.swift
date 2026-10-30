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

#if os(Windows)
import WinSDK

@Suite("Platform: replacing a file Windows holds open")
struct WindowsReplaceTests {
    /// A scanner holding the file without FILE_SHARE_DELETE for a moment:
    /// the write waits for it instead of failing with error 32.
    @Test func aBrieflyHeldFileIsStillReplaced() throws {
        let dir = TestTemp.url("replace")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("auth.json")
        try PrivateFile.write(Data("old".utf8), to: file)
        let path = file.withUnsafeFileSystemRepresentation { String(cString: $0!) }
        let held = path.withCString(encodedAs: UTF16.self) {
            CreateFileW($0, DWORD(GENERIC_READ), DWORD(FILE_SHARE_READ) | DWORD(FILE_SHARE_WRITE), nil,
                        DWORD(OPEN_EXISTING), DWORD(FILE_ATTRIBUTE_NORMAL), nil)
        }
        let handle = try #require(held)
        #expect(handle != INVALID_HANDLE_VALUE)
        let address = UInt(bitPattern: handle)
        // A thread of its own, not the shared dispatch pool: with the whole
        // suite running in parallel the pool can be busy for longer than the
        // replace waits (about two seconds), and the handle would close late.
        Thread {
            Thread.sleep(forTimeInterval: 0.3)
            CloseHandle(HANDLE(bitPattern: address))
        }.start()
        try PrivateFile.write(Data("new".utf8), to: file)
        #expect(try String(contentsOf: file, encoding: .utf8) == "new")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasPrefix(".") }
        #expect(leftovers.isEmpty)
    }
}
#endif
