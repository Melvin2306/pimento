import AppKit
import Foundation
import Observation
import PimentoCore

/// The app's side of the update check (`UpdateCheck` in PimentoCore): the
/// daily automatic check (Settings › General › Updates), the manual one
/// (Pimento › Check for Updates…, Settings' Check Now), the notice in the main
/// window and the menu bar, and the links it opens. It only tells: nothing is
/// downloaded or installed. Off in demo mode and with PIMENTO_NO_UPDATE_CHECK.
@MainActor
@Observable
final class UpdateChecker {
    /// The last check and what it found, kept in the defaults between launches.
    private(set) var record: UpdateCheckRecord?
    private(set) var isChecking = false
    /// The version whose notice was closed: hidden until a newer one appears.
    private(set) var dismissedVersion: String?
    /// Why checks are off for this process; nil: they may run.
    let disabledReason: String?

    @ObservationIgnored private let store: PreferenceStore
    @ObservationIgnored private let transport: HTTPTransport
    @ObservationIgnored private var dailyTask: Task<Void, Never>?

    /// How long after launch the first automatic check waits (roles load first).
    nonisolated static let launchDelay: TimeInterval = 5

    init(store: PreferenceStore,
         environment: [String: String] = ProcessInfo.processInfo.environment,
         demo: Bool,
         transport: HTTPTransport = UpdateCheckTransport(URLSessionTransport())) {
        self.store = store
        self.transport = transport
        disabledReason = UpdateCheck.disabledReason(environment: environment, demo: demo)
        record = UpdateCheckRecord.load(from: store)
        dismissedVersion = UpdateCheckRecord.dismissedVersion(in: store)
    }

    var isAvailable: Bool { disabledReason == nil }

    /// A newer release, unless its notice was closed (main window, menu bar).
    var notice: ReleaseInfo? { isAvailable ? record?.update(dismissed: dismissedVersion) : nil }

    /// A newer release, closed or not (Settings).
    var newer: ReleaseInfo? { isAvailable ? record?.update() : nil }

    /// Starts the automatic check (now if a day has passed since the last
    /// one, then once a day while Pimento runs), or stops it.
    func setAutomatic(_ on: Bool, initialDelay: TimeInterval = launchDelay) {
        dailyTask?.cancel()
        dailyTask = nil
        guard on, isAvailable else { return }
        dailyTask = Task { [weak self] in
            var delay = initialDelay
            while !Task.isCancelled {
                // In steps of at most an hour, so a sleeping Mac catches up on wake.
                if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(min(delay, 3600) * 1_000_000_000)) }
                guard !Task.isCancelled, let checker = self else { return }
                let next = UpdateCheck.nextCheck(after: checker.record?.checkedAt, now: Date())
                delay = next.timeIntervalSinceNow
                if delay <= 0 {
                    await checker.check()
                    delay = UpdateCheck.interval
                }
            }
        }
    }

    /// Asks GitHub now. A manual check shows a closed notice again when the
    /// newer version is still there. nil when checks are off or one is running.
    @discardableResult
    func check(manual: Bool = false) async -> Result<UpdateCheckResult, Error>? {
        guard isAvailable, !isChecking else { return nil }
        isChecking = true
        defer { isChecking = false }
        let result: Result<UpdateCheckResult, Error>
        do { result = .success(try await UpdateCheck.check(transport: transport)) } catch { result = .failure(error) }
        let updated = (record ?? UpdateCheckRecord(checkedAt: Date(), latest: nil)).updated(at: Date(), with: result)
        record = updated
        updated.save(to: store)
        if manual, case .success(let r) = result, let update = r.update, dismissedVersion == update.version.description {
            setDismissed(nil)
        }
        return result
    }

    /// Hides the notice of `release` until a newer version appears.
    func dismiss(_ release: ReleaseInfo) { setDismissed(release.version.description) }

    private func setDismissed(_ version: String?) {
        dismissedVersion = version
        UpdateCheckRecord.setDismissedVersion(version, in: store)
    }

    /// Opens the release page or the disk image in the browser: only links
    /// inside github.com/Melvin2306/pimento (built from the version, never
    /// taken from GitHub's answer).
    func open(_ url: URL?) {
        guard isAvailable, let url, UpdateCheck.isAllowedToOpen(url) else { return }
        NSWorkspace.shared.open(url)
    }

    /// Pimento › Check for Updates…: checks, then says what it found in an alert.
    func checkFromMenu() {
        Task {
            guard let result = await check(manual: true) else { return }
            let alert = NSAlert()
            switch result {
            case .success(let r):
                if let update = r.update {
                    alert.messageText = UpdateText.available(update)
                    alert.informativeText = UpdateText.availableDetails(update)
                    if update.diskImageURL != nil { alert.addButton(withTitle: "Download") }
                    alert.addButton(withTitle: "Release Notes")
                    alert.addButton(withTitle: "Later")
                    NSApp.activate(ignoringOtherApps: true)
                    let response = alert.runModal()
                    let buttons: [URL?] = (update.diskImageURL.map { [$0] } ?? []) + [update.releasePageURL]
                    let index = response.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
                    if buttons.indices.contains(index) { open(buttons[index]) }
                    return
                }
                alert.messageText = "\(AppInfo.name) is up to date"
                alert.informativeText = UpdateText.upToDate(latest: r.latest)
            case .failure(let error):
                alert.alertStyle = .warning
                alert.messageText = "Could not check for updates"
                alert.informativeText = error.localizedDescription
            }
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
    }
}
