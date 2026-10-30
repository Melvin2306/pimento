import Foundation

extension CLIJSON {
    /// `pimento version --json` (and `--check`).
    public struct Version: Encodable, Equatable, Sendable {
        public let version: String
        /// Whether GitHub was asked (`--check`).
        public let checked: Bool?
        public let latest: String?
        public let publishedAt: String?
        public let updateAvailable: Bool?
        public let releasePage: String?
        public let diskImage: String?
        public let installCommand: String?
        public let error: String?

        init(version: String = AppInfo.version, checked: Bool? = nil, result: UpdateCheckResult? = nil,
             platform: HostPlatform = .current, error: String? = nil) {
            self.version = version
            self.checked = checked
            self.error = error
            let latest = result?.latest
            self.latest = latest?.version.description
            publishedAt = latest?.publishedAt.map(AzureDate.format)
            updateAvailable = result.map { $0.update != nil }
            let update = result?.update
            releasePage = update?.releasePageURL.absoluteString
            diskImage = update?.diskImageURL?.absoluteString
            installCommand = update == nil ? nil : UpdateCheck.installCommand(platform: platform)
        }
    }
}

extension CLIRunner {
    /// `pimento version [--check] [--json]`. Only `--check` reaches the
    /// network: one GET of GitHub's latest release (never in demo mode or with
    /// `PIMENTO_NO_UPDATE_CHECK`). Exit 0 when the check worked (whether or
    /// not there is a newer version), 1 when it could not be made.
    func version(_ o: VersionOptions) async -> CLIExit {
        guard o.check else {
            out(o.json ? CLIJSON.encode(CLIJSON.Version()) : "pimento \(AppInfo.version)")
            return .success
        }
        let failed: (String) -> CLIExit = { message in
            if o.json {
                out(CLIJSON.encode(CLIJSON.Version(checked: false, error: message)))
            } else {
                out("pimento \(AppInfo.version)")
                err(errStyle.red("error:") + " " + message)
            }
            return .failure
        }
        if let reason = UpdateCheck.disabledReason(environment: env.variables, demo: env.demo != nil) {
            return failed(reason)
        }
        let result: UpdateCheckResult
        do {
            result = try await UpdateCheck.check(transport: UpdateCheckTransport(env.updateTransport))
        } catch {
            return failed("could not check for updates: " + error.localizedDescription)
        }
        if o.json {
            out(CLIJSON.encode(CLIJSON.Version(checked: true, result: result)))
        } else {
            for line in UpdateText.cliReport(result, bundledWithApp: UpdateText.isBundledWithApp(env.executablePath)) { out(line) }
        }
        return .success
    }
}
