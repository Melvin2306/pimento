import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import PimentoCore

/// GitHub's "latest release" JSON, synthetic: the fields Pimento reads plus
/// links it must ignore (they point elsewhere on purpose).
func releaseJSON(tag: String = "v0.2.0", draft: Bool = false, prerelease: Bool = false,
                 assets: [String] = ["Pimento-0.2.0.dmg", "Pimento.dmg", "SHA256SUMS.txt"],
                 publishedAt: String? = "2026-11-02T09:15:00Z") -> Data {
    var doc: [String: Any] = [
        "tag_name": tag, "name": "Pimento \(tag)", "draft": draft, "prerelease": prerelease,
        "html_url": "https://example.com/not-pimento",
        "body": "Release notes",
        "assets": assets.map { ["name": $0, "browser_download_url": "https://example.com/\($0)"] },
    ]
    if let publishedAt { doc["published_at"] = publishedAt }
    return try! JSONSerialization.data(withJSONObject: doc)
}

/// A transport that answers every update check with `body` and `status`.
func releaseTransport(_ body: Data = releaseJSON(), status: Int = 200, delayNanos: UInt64 = 0) -> RecordingTransport {
    RecordingTransport(delayNanos: delayNanos) { _ in (body, status) }
}

@Suite("Update check: versions")
struct SemanticVersionTests {
    @Test func parsesStrictSemanticVersions() throws {
        let v = try #require(SemanticVersion("1.2.3"))
        #expect((v.major, v.minor, v.patch) == (1, 2, 3) && !v.isPrerelease)
        #expect(SemanticVersion("0.1.0")?.description == "0.1.0")
        #expect(SemanticVersion("1.0.0-rc.1")?.prerelease == ["rc", "1"])
        #expect(SemanticVersion("1.0.0-alpha-2.x")?.description == "1.0.0-alpha-2.x")
        #expect(SemanticVersion("1.0.0+build.5")?.description == "1.0.0", "build metadata is dropped")
        #expect(SemanticVersion("v1.2.3", allowPrefix: true) == SemanticVersion(1, 2, 3))
        #expect(SemanticVersion(AppInfo.version) != nil, "this build's version parses")
    }

    @Test func refusesAnythingElse() {
        let bad = [
            "", "1", "1.2", "1.2.3.4", "01.2.3", "1.02.3", "1.2.03", "1.2.3-", "1.2.3+", "1.2.3-01", "1.2.3-rc..1",
            "1.2.3-rc.", " 1.2.3", "1.2.3 ", "1.2.3\n", "-1.2.3", "1.-2.3", "a.b.c", "1.2.3-ü", "１.2.3", "1.2.3-rc_1",
            "v1.2.3", "V1.2.3", "vv1.2.3", "1234567890.0.0", "1.2.3/../evil", "1.2.3?x", "1.2.3#x", "1.2.3%2F",
            "1.2.3-" + String(repeating: "a", count: 80),
        ]
        for text in bad { #expect(SemanticVersion(text) == nil, "\(text.debugDescription) must not parse") }
        #expect(SemanticVersion("v1.2.3+build", allowPrefix: true, allowBuild: false) == nil)
        #expect(SemanticVersion("v", allowPrefix: true) == nil)
    }

    @Test func ordersBySemverPrecedence() throws {
        // The example list of semver.org § 11, plus number widths.
        let ordered = ["1.0.0-alpha", "1.0.0-alpha.1", "1.0.0-alpha.beta", "1.0.0-beta", "1.0.0-beta.2", "1.0.0-beta.11",
                       "1.0.0-rc.1", "1.0.0", "1.0.1", "1.9.0", "1.10.0", "2.0.0", "10.0.0"]
        let versions = try ordered.map { try #require(SemanticVersion($0)) }
        for (a, b) in zip(versions, versions.dropFirst()) {
            #expect(a < b, "\(a) < \(b)")
            #expect(!(b < a))
        }
        #expect(versions.shuffled().sorted() == versions)
        #expect(SemanticVersion("1.0.0+a") == SemanticVersion("1.0.0+b"))
    }

    @Test func numericPrereleaseIdentifiersOfAnyLengthAndHyphens() throws {
        // `-5` is an alphanumeric identifier (a hyphen and a digit), not the number -5:
        // above every numeric one.
        let numeric = try #require(SemanticVersion("1.0.0-rc.5"))
        let hyphen = try #require(SemanticVersion("1.0.0-rc.-5"))
        #expect(numeric < hyphen && !(hyphen < numeric))
        // Numbers longer than Int are still compared as numbers.
        let small = try #require(SemanticVersion("1.0.0-rc.99999999999999999999"))
        let large = try #require(SemanticVersion("1.0.0-rc.100000000000000000000"))
        #expect(small < large && !(large < small))
        #expect(SemanticVersion("1.0.0-rc.11")! > SemanticVersion("1.0.0-rc.9")!)
    }
}

@Suite("Update check: GitHub's answer")
struct UpdateCheckParseTests {
    @Test func readsTheLatestReleaseAndBuildsItsLinks() throws {
        let release = try #require(try UpdateCheck.parse(releaseJSON(), status: 200))
        #expect(release.version == SemanticVersion(0, 2, 0))
        #expect(release.tag == "v0.2.0")
        #expect(release.diskImageName == "Pimento-0.2.0.dmg")
        #expect(release.publishedAt == AzureDate.parse("2026-11-02T09:15:00Z"))
        // Built from the version, never from html_url / browser_download_url.
        #expect(release.releasePageURL.absoluteString == "https://github.com/Melvin2306/pimento/releases/tag/v0.2.0")
        #expect(release.diskImageURL?.absoluteString == "https://github.com/Melvin2306/pimento/releases/download/v0.2.0/Pimento-0.2.0.dmg")
        #expect(UpdateCheck.isAllowedToOpen(release.releasePageURL))
        #expect(UpdateCheck.isAllowedToOpen(try #require(release.diskImageURL)))
    }

    @Test func picksTheStableDiskImageOrNone() throws {
        let stable = try #require(try UpdateCheck.parse(releaseJSON(assets: ["Pimento.dmg"]), status: 200))
        #expect(stable.diskImageURL?.absoluteString == "https://github.com/Melvin2306/pimento/releases/download/v0.2.0/Pimento.dmg")
        // An asset named like a path, or another release's image, is not used.
        let none = try #require(try UpdateCheck.parse(releaseJSON(assets: ["../Pimento.dmg", "Pimento-0.1.0.dmg", "evil.dmg"]), status: 200))
        #expect(none.diskImageName == nil && none.diskImageURL == nil)
        let missing = try #require(try UpdateCheck.parse(Data(#"{"tag_name": "v0.2.0"}"#.utf8), status: 200))
        #expect(missing.diskImageName == nil && missing.publishedAt == nil)
    }

    @Test func ignoresDraftsAndPrereleases() throws {
        #expect(try UpdateCheck.parse(releaseJSON(draft: true), status: 200) == nil)
        #expect(try UpdateCheck.parse(releaseJSON(prerelease: true), status: 200) == nil)
        // A pre-release tag published as a release is still a pre-release.
        #expect(try UpdateCheck.parse(releaseJSON(tag: "v0.3.0-rc.1"), status: 200) == nil)
        // No release at all.
        #expect(try UpdateCheck.parse(Data(#"{"message": "Not Found"}"#.utf8), status: 404) == nil)
    }

    @Test func refusesUnexpectedAnswers() {
        #expect(throws: UpdateCheckError.rateLimited) { try UpdateCheck.parse(Data(), status: 403) }
        #expect(throws: UpdateCheckError.rateLimited) { try UpdateCheck.parse(Data(), status: 429) }
        #expect(throws: UpdateCheckError.http(500)) { try UpdateCheck.parse(Data(), status: 500) }
        #expect(throws: UpdateCheckError.http(301)) { try UpdateCheck.parse(Data(), status: 301) }
        #expect(throws: UpdateCheckError.invalidResponse("not a release")) { try UpdateCheck.parse(Data("<html>".utf8), status: 200) }
        #expect(throws: UpdateCheckError.invalidResponse("not a release")) { try UpdateCheck.parse(Data("[]".utf8), status: 200) }
        #expect(throws: UpdateCheckError.invalidResponse("no tag")) { try UpdateCheck.parse(Data("{}".utf8), status: 200) }
        for tag in ["latest", "0.2", "v0.2.0+evil", "v0.2.0/../../x", "v0.2.0\u{202E}", "https://example.com/v9.9.9"] {
            #expect(throws: UpdateCheckError.invalidResponse("the tag is not a version")) {
                try UpdateCheck.parse(releaseJSON(tag: tag), status: 200)
            }
        }
        let huge = Data(repeating: UInt8(ascii: " "), count: UpdateCheck.maxResponseBytes + 1)
        #expect(throws: UpdateCheckError.invalidResponse("more than 1024 KB")) { try UpdateCheck.parse(huge, status: 200) }
        // A published date that is not a date is left out, not trusted.
        #expect((try? UpdateCheck.parse(releaseJSON(publishedAt: "yesterday"), status: 200))??.publishedAt == nil)
    }
}

@Suite("Update check: request")
struct UpdateCheckRequestTests {
    @Test func sendsOnePlainGetToGitHub() async throws {
        let transport = releaseTransport()
        let result = try await UpdateCheck.check(current: "0.1.0", transport: transport)
        let requests = await transport.requests
        #expect(requests.count == 1)
        let request = try #require(requests.first)
        #expect(request.httpMethod == "GET")
        #expect(request.url == UpdateCheck.endpoint)
        #expect(request.url?.absoluteString == "https://api.github.com/repos/Melvin2306/pimento/releases/latest")
        #expect(request.httpBody == nil)
        #expect(request.timeoutInterval == UpdateCheck.timeout)
        #expect(!request.httpShouldHandleCookies)
        #expect(request.cachePolicy == .reloadIgnoringLocalAndRemoteCacheData)
        // Header names compared case-insensitively: Foundation on Linux and
        // Windows normalises their case (X-Github-Api-Version).
        let headers = request.allHTTPHeaderFields ?? [:]
        #expect(request.value(forHTTPHeaderField: "User-Agent") == "Pimento/\(AppInfo.version)")
        #expect(Set(headers.keys.map { $0.lowercased() }) == ["user-agent", "accept", "x-github-api-version"],
                "no identifiers, tokens or cookies")
        #expect(result.update?.version == SemanticVersion(0, 2, 0))
    }

    @Test func comparesWithTheRunningVersion() async throws {
        let same = try await UpdateCheck.check(current: "0.2.0", transport: releaseTransport())
        #expect(same.update == nil && same.latest?.version == SemanticVersion(0, 2, 0))
        let newer = try await UpdateCheck.check(current: "0.10.0", transport: releaseTransport())
        #expect(newer.update == nil, "a development build newer than the release")
        let candidate = try await UpdateCheck.check(current: "0.2.0-rc.1", transport: releaseTransport())
        #expect(candidate.update?.version == SemanticVersion(0, 2, 0), "the release is newer than its candidate")
        let none = try await UpdateCheck.check(current: "0.1.0", transport: releaseTransport(Data(), status: 404))
        #expect(none.latest == nil && none.update == nil)
        await #expect(throws: UpdateCheckError.self) { try await UpdateCheck.check(current: "dev", transport: releaseTransport()) }
    }

    @Test func networkErrorsAndTimeouts() async throws {
        await #expect(throws: UpdateCheckError.network(URLError(.notConnectedToInternet).localizedDescription)) {
            try await UpdateCheck.check(transport: OfflineTransport())
        }
        await #expect(throws: UpdateCheckError.rateLimited) {
            try await UpdateCheck.check(transport: releaseTransport(Data(), status: 403))
        }
        // An answer that takes too long is given up on, whatever the transport does.
        let slow = releaseTransport(delayNanos: 5_000_000_000)
        let start = Date()
        await #expect(throws: UpdateCheckError.network("GitHub did not answer within 0 seconds.")) {
            try await UpdateCheck.check(transport: slow, deadline: 0.05)
        }
        #expect(Date().timeIntervalSince(start) < 4)
    }

    @Test func theGuardRefusesEveryOtherRequest() async throws {
        let base = releaseTransport()
        let guarded = UpdateCheckTransport(base)
        var other = UpdateCheck.request()
        other.url = URL(string: "https://api.github.com/repos/Melvin2306/pimento/releases")
        var post = UpdateCheck.request()
        post.httpMethod = "POST"
        var elsewhere = UpdateCheck.request()
        elsewhere.url = URL(string: "https://example.com/repos/Melvin2306/pimento/releases/latest")
        var plain = UpdateCheck.request()
        plain.url = URL(string: "http://api.github.com/repos/Melvin2306/pimento/releases/latest")
        for request in [other, post, elsewhere, plain] {
            await #expect(throws: UpdateCheckTransport.Refused.self) { try await guarded.send(request) }
        }
        #expect(await base.requests.isEmpty)
        _ = try await guarded.send(UpdateCheck.request())
        #expect(await base.requests.count == 1)
    }

    @Test func demoModeNeverReachesTheNetwork() async {
        let monitor = NetworkGuard.Monitor()
        await NetworkGuard.$monitor.withValue(monitor) {
            await #expect(throws: UpdateCheckError.self) { try await UpdateCheck.check(transport: URLSessionTransport()) }
        }
        #expect(monitor.blocked == ["an HTTPS request to api.github.com"])
        #expect(UpdateCheck.disabledReason(environment: [:], demo: true) != nil)
    }

    @Test func theEnvironmentVariableTurnsChecksOff() {
        #expect(UpdateCheck.disabledReason(environment: [:], demo: false) == nil)
        for value in ["1", "true", "YES", "on"] {
            #expect(UpdateCheck.disabledReason(environment: [UpdateCheck.disableVariable: value], demo: false) != nil)
        }
        for value in ["0", "false", "", "off"] {
            #expect(UpdateCheck.disabledReason(environment: [UpdateCheck.disableVariable: value], demo: false) == nil)
        }
    }
}

@Suite("Update check: links, schedule, record")
struct UpdateCheckStateTests {
    @Test func opensOnlyLinksInsideTheRepository() throws {
        let allowed = [
            "https://github.com/Melvin2306/pimento/releases/tag/v0.2.0",
            "https://github.com/Melvin2306/pimento/releases/download/v0.2.0/Pimento-0.2.0.dmg",
            "https://github.com/melvin2306/pimento/releases",
            "https://GitHub.com/Melvin2306/pimento/releases",
        ]
        for text in allowed { #expect(UpdateCheck.isAllowedToOpen(try #require(URL(string: text))), "\(text)") }
        let refused = [
            "http://github.com/Melvin2306/pimento/releases",
            "https://api.github.com/repos/Melvin2306/pimento/releases/latest",
            "https://github.com.example.com/Melvin2306/pimento/releases",
            "https://github.com/Melvin2306/pimento-evil/releases",
            "https://github.com/Contoso/pimento/releases",
            "https://github.com/Melvin2306/pimento",
            "https://github.com/Melvin2306/pimento/../../Contoso/x",
            "https://github.com/Melvin2306/pimento/releases/%2e%2e/x",
            "https://github.com/Melvin2306/pimento//releases",
            "https://github.com:8443/Melvin2306/pimento/releases",
            "https://github.com/Melvin2306/pimento/releases?redirect=https://example.com",
            "https://github.com/Melvin2306/pimento/releases#x",
            "file:///Applications/Pimento.app",
            "javascript:alert(1)",
        ]
        for text in refused {
            guard let url = URL(string: text) else { continue }
            #expect(!UpdateCheck.isAllowedToOpen(url), "\(text) must be refused")
        }
        // Credentials in the URL.
        var withUser = try #require(URLComponents(string: "https://github.com/Melvin2306/pimento/releases"))
        withUser.user = "alex"
        #expect(!UpdateCheck.isAllowedToOpen(try #require(withUser.url)))
    }

    @Test func checksAtMostOnceADay() {
        let now = Fixture.now
        #expect(UpdateCheck.isDue(lastCheck: nil, now: now))
        #expect(!UpdateCheck.isDue(lastCheck: now.addingTimeInterval(-3600), now: now))
        #expect(!UpdateCheck.isDue(lastCheck: now.addingTimeInterval(-86399), now: now))
        #expect(UpdateCheck.isDue(lastCheck: now.addingTimeInterval(-86400), now: now))
        #expect(UpdateCheck.isDue(lastCheck: now.addingTimeInterval(7200), now: now), "a check in the future: the clock went back")
        #expect(UpdateCheck.nextCheck(after: nil, now: now) == now)
        #expect(UpdateCheck.nextCheck(after: now.addingTimeInterval(-3600), now: now) == now.addingTimeInterval(86400 - 3600))
    }

    @Test func persistsTheLastCheckAndTheDismissedVersion() throws {
        let store = MemoryStore()
        #expect(UpdateCheckRecord.load(from: store) == nil)
        let release = ReleaseInfo(version: SemanticVersion(0, 2, 0), publishedAt: Fixture.now, diskImageName: "Pimento-0.2.0.dmg")
        let record = UpdateCheckRecord(checkedAt: Fixture.now, latest: release)
        record.save(to: store)
        #expect(UpdateCheckRecord.load(from: store) == record)
        #expect(record.update(current: "0.1.0") == release)
        #expect(record.update(current: "0.2.0") == nil)
        #expect(record.update(current: "0.1.0", dismissed: "0.2.0") == nil)
        #expect(record.update(current: "0.1.0", dismissed: "0.1.5") == release, "a dismissed older version does not hide a newer one")

        UpdateCheckRecord.setDismissedVersion("0.2.0", in: store)
        #expect(UpdateCheckRecord.dismissedVersion(in: store) == "0.2.0")
        UpdateCheckRecord.setDismissedVersion(nil, in: store)
        #expect(UpdateCheckRecord.dismissedVersion(in: store) == nil)
        store.values["updates.dismissedVersion"] = "not a version"
        #expect(UpdateCheckRecord.dismissedVersion(in: store) == nil)

        // A failed check keeps the last known release and says why.
        let failed = record.updated(at: Fixture.now.addingTimeInterval(86400), with: .failure(UpdateCheckError.rateLimited))
        #expect(failed.latest == release && failed.error == UpdateCheckError.rateLimited.localizedDescription)
        let worked = failed.updated(at: Fixture.now.addingTimeInterval(2 * 86400),
                                    with: .success(UpdateCheckResult(current: SemanticVersion(0, 1, 0), latest: nil)))
        #expect(worked.latest == nil && worked.error == nil)
    }

    @Test func aTamperedRecordIsNotTrusted() throws {
        let store = MemoryStore()
        store.values["updates.lastCheck"] = Data(#"{"checkedAt": 0, "latest": {"version": "../9.9.9"}}"#.utf8)
        #expect(UpdateCheckRecord.load(from: store) == nil)
        store.values["updates.lastCheck"] = Data(#"{"checkedAt": 0, "latest": {"version": "0.2.0", "diskImageName": "../../evil.dmg"}}"#.utf8)
        let record = try #require(UpdateCheckRecord.load(from: store))
        #expect(record.latest?.diskImageName == nil && record.latest?.diskImageURL == nil)
        store.values["updates.lastCheck"] = "garbage"
        #expect(UpdateCheckRecord.load(from: store) == nil)
    }

    @Test func settingsAndCLITexts() throws {
        let utc = TimeZone(identifier: "UTC")!
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc
        let locale = Locale(identifier: "en_GB")
        let release = ReleaseInfo(version: SemanticVersion(0, 2, 0), publishedAt: Fixture.now, diskImageName: "Pimento.dmg")
        let now = Fixture.now
        #expect(UpdateText.status(record: nil, now: now) == "Not checked yet.")
        let upToDate = UpdateText.status(record: UpdateCheckRecord(checkedAt: now, latest: release), current: "0.2.0", now: now,
                                         calendar: calendar, locale: locale)
        #expect(upToDate == "Pimento 0.2.0 is up to date. Checked today at 12:00.")
        let available = UpdateText.status(record: UpdateCheckRecord(checkedAt: now.addingTimeInterval(-86400), latest: release),
                                          current: "0.1.0", now: now, calendar: calendar, locale: locale)
        #expect(available == "Pimento 0.2.0 is available (this is 0.1.0). Checked yesterday at 12:00.")
        let failed = UpdateText.status(record: UpdateCheckRecord(checkedAt: now, latest: nil, error: "Offline."), now: now,
                                       calendar: calendar, locale: locale)
        #expect(failed == "Could not check today at 12:00: Offline.")
        #expect(UpdateText.upToDate(current: "0.2.0", latest: release) == "Pimento 0.2.0 is the latest version.")
        #expect(UpdateText.upToDate(current: "0.3.0", latest: release) == "Pimento 0.3.0 is newer than the latest release (0.2.0).")

        let result = UpdateCheckResult(current: SemanticVersion(0, 1, 0), latest: release)
        let unix = UpdateText.cliReport(result, platform: .linux)
        #expect(unix == [
            "current  0.1.0",
            "latest   0.2.0 (released 2026-10-29)",
            "",
            "A newer version is available: https://github.com/Melvin2306/pimento/releases/tag/v0.2.0",
            "To update, re-run the installer:",
            "  curl -fsSL https://raw.githubusercontent.com/Melvin2306/pimento/main/scripts/install.sh | sh",
        ])
        #expect(UpdateText.cliReport(result, platform: .windows).last
            == "  irm https://raw.githubusercontent.com/Melvin2306/pimento/main/scripts/install.ps1 | iex")
        #expect(UpdateText.cliReport(result, platform: .macOS, bundledWithApp: true).contains { $0.contains("inside Pimento.app") })
        #expect(UpdateText.isBundledWithApp("/Applications/Pimento.app/Contents/Helpers/pimento"))
        #expect(!UpdateText.isBundledWithApp("/home/alex/.local/bin/pimento") && !UpdateText.isBundledWithApp(nil))
        #expect(UpdateText.cliReport(UpdateCheckResult(current: SemanticVersion(0, 2, 0), latest: release)).last == "pimento is up to date.")
        #expect(UpdateText.cliReport(UpdateCheckResult(current: SemanticVersion(0, 2, 0), latest: nil))
            == ["current  0.2.0", "latest   none published yet", "pimento is up to date."])
    }

    @Test func theSettingIsOnByDefaultAndReset() {
        #expect(Preferences().checkForUpdates)
        let store = MemoryStore()
        var p = Preferences()
        p.checkForUpdates = false
        p.save(to: store)
        #expect(!Preferences.load(from: store).checkForUpdates)
        Preferences.reset(in: store)
        #expect(Preferences.load(from: store).checkForUpdates)
    }
}

@Suite("Update check: pimento version --check")
struct CLIVersionCheckTests {
    func run(_ h: CLIHarness, _ transport: HTTPTransport, _ args: String...) async -> Int32 {
        var env = h.environment()
        env.updateTransport = transport
        return await CLIRunner(environment: env).run(args)
    }

    @Test func parsesTheFlags() throws {
        #expect(try CLIParser.parse(["version", "--check"]).command == .version(VersionOptions(check: true)))
        #expect(try CLIParser.parse(["--version", "--check", "--json"]).command == .version(VersionOptions(check: true, json: true)))
        #expect(try CLIParser.parse(["version", "--json"]).command == .version(VersionOptions(json: true)))
        #expect(try CLIParser.parse(["version", "--help"]).command == .help(topic: "version"))
        #expect(throws: CLIParseError.unknownOption("--tenant", command: "version")) { try CLIParser.parse(["version", "--tenant", "x"]) }
        #expect(!CLICommand.version(VersionOptions(check: true)).needsAzure)
        #expect(CLIHelp.text(for: "version").contains("--check"))
        #expect(CLIHelp.text(for: "version").contains(UpdateCheck.disableVariable))
        for shell in CompletionShell.allCases { #expect(CLIHelp.completionScript(for: shell).contains("check")) }
    }

    @Test func ordinaryCommandsNeverAskGitHub() async {
        let transport = releaseTransport()
        for args in [["version"], ["version", "--json"], ["list"], ["status"], ["help"], ["presets", "list"], ["history"], ["--version"]] {
            let h = CLIHarness()
            var env = h.environment()
            env.updateTransport = transport
            _ = await CLIRunner(environment: env).run(args)
        }
        #expect(await transport.requests.isEmpty)
    }

    @Test func reportsANewerVersionAndHowToUpdate() async throws {
        let h = CLIHarness()
        let transport = releaseTransport(releaseJSON(tag: "v99.0.0", assets: ["Pimento.dmg"]))
        #expect(await run(h, transport, "version", "--check") == 0)
        #expect(h.out.hasPrefix("current  \(AppInfo.version)\nlatest   99.0.0 (released 2026-11-02)\n"))
        #expect(h.out.contains("A newer version is available: https://github.com/Melvin2306/pimento/releases/tag/v99.0.0"))
        #expect(h.out.contains(UpdateCheck.installCommand()))
        #expect(await transport.requests.count == 1)

        let json = CLIHarness()
        #expect(await run(json, transport, "version", "--check", "--json") == 0)
        let doc = try #require(try JSONSerialization.jsonObject(with: Data(json.out.utf8)) as? [String: Any])
        #expect(doc["version"] as? String == AppInfo.version)
        #expect(doc["checked"] as? Bool == true)
        #expect(doc["latest"] as? String == "99.0.0")
        #expect(doc["updateAvailable"] as? Bool == true)
        #expect(doc["releasePage"] as? String == "https://github.com/Melvin2306/pimento/releases/tag/v99.0.0")
        #expect(doc["diskImage"] as? String == "https://github.com/Melvin2306/pimento/releases/download/v99.0.0/Pimento.dmg")
        #expect(doc["installCommand"] as? String == UpdateCheck.installCommand())
    }

    @Test func upToDateAndFailures() async throws {
        let current = CLIHarness()
        #expect(await run(current, releaseTransport(releaseJSON(tag: "v" + AppInfo.version)), "version", "--check") == 0)
        #expect(current.out.hasSuffix("pimento is up to date.\n"))

        let offline = CLIHarness()
        #expect(await run(offline, OfflineTransport(), "version", "--check") == 1)
        #expect(offline.out == "pimento \(AppInfo.version)\n")
        #expect(offline.err.contains("error: could not check for updates"))

        let limited = CLIHarness()
        #expect(await run(limited, releaseTransport(Data(), status: 403), "version", "--check", "--json") == 1)
        let doc = try #require(try JSONSerialization.jsonObject(with: Data(limited.out.utf8)) as? [String: Any])
        #expect(doc["checked"] as? Bool == false && (doc["error"] as? String)?.contains("rate limit") == true)
    }

    @Test func theEnvironmentVariableKeepsItOffline() async {
        let transport = releaseTransport()
        let h = CLIHarness()
        h.variables[UpdateCheck.disableVariable] = "1"
        #expect(await run(h, transport, "version", "--check") == 1)
        #expect(h.err.contains(UpdateCheck.disableVariable))
        #expect(await transport.requests.isEmpty)
    }

    @Test func demoModeKeepsItOffline() async {
        let demo = DemoCLIRun()
        let transport = releaseTransport()
        var env = demo.environment
        env.updateTransport = transport
        let status = await NetworkGuard.$monitor.withValue(demo.monitor) {
            await CLIRunner(environment: env).run(["--demo", "version", "--check"])
        }
        #expect(status == 1)
        #expect(demo.stderr.contains("Demo mode is offline"))
        #expect(await transport.requests.isEmpty)
        demo.expectIsolated()
    }
}
