import PimentoCore
import SwiftUI

/// A one-line notice above the role table when a newer Pimento exists:
/// Download (the disk image), Release Notes, and a close button that hides it
/// until a newer version appears. Styled like the info banner.
struct UpdateNotice: View {
    let updates: UpdateChecker
    @Environment(\.appTheme) private var theme
    @Environment(\.colorScheme) private var scheme
    @Environment(\.ultraDark) private var ultra

    var body: some View {
        if let release = updates.notice {
            let palette = ThemePalette(theme, scheme, ultra: ultra)
            HStack(spacing: 8) {
                Image(systemName: "arrow.down.circle.fill")
                    .foregroundStyle(theme == .native ? Color.accentColor : palette.accent)
                    .accessibilityHidden(true)
                Text(UpdateText.available(release))
                Text("You have \(AppInfo.version).").foregroundStyle(.secondary)
                Spacer()
                if release.diskImageURL != nil {
                    Button("Download") { updates.open(release.diskImageURL) }
                        .help("Download \(release.diskImageName ?? "the disk image") from GitHub")
                }
                Button("Release Notes") { updates.open(release.releasePageURL) }
                    .help("The release page on GitHub")
                Button { updates.dismiss(release) } label: { Image(systemName: "xmark") }
                    .accessibilityLabel("Hide until the next version")
                    .help("Hide until the next version")
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(theme == .native ? Color.accentColor.opacity(0.12) : palette.infoFill)
        }
    }
}

/// The same notice in the menu bar popover, compact.
struct MenuBarUpdateNotice: View {
    let updates: UpdateChecker
    let colors: MenuBarColors

    var body: some View {
        if let release = updates.notice {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "arrow.down.circle").foregroundStyle(colors.accent)
                Text(UpdateText.available(release))
                    .font(.caption)
                    .foregroundStyle(colors.text)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button(release.diskImageURL != nil ? "Download" : "Release Notes") {
                    updates.open(release.diskImageURL ?? release.releasePageURL)
                }
                .font(.caption)
                Button { updates.dismiss(release) } label: { Image(systemName: "xmark").font(.caption2) }
                    .help("Hide until the next version")
                    .accessibilityLabel("Hide until the next version")
            }
            .buttonStyle(.borderless)
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 6).fill(colors.surface))
        }
    }
}

/// Settings › General › Updates.
struct UpdateSettingsSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        let updates = model.updates
        SettingsGroup("Updates") {
            Toggle("Check for updates automatically", isOn: $model.prefs.checkForUpdates)
                .help("Once a day, ask GitHub whether a newer release of Pimento exists")
                .disabled(!updates.isAvailable)
            HStack(spacing: 8) {
                Button("Check Now") { Task { await updates.check(manual: true) } }
                    .disabled(!updates.isAvailable || updates.isChecking)
                if updates.isChecking { ProgressView().controlSize(.small) }
                if let release = updates.newer {
                    if release.diskImageURL != nil {
                        Button("Download") { updates.open(release.diskImageURL) }
                    }
                    Button("Release Notes") { updates.open(release.releasePageURL) }
                }
            }
            if let reason = updates.disabledReason {
                SettingsNote(reason)
            } else {
                SettingsNote(UpdateText.status(record: updates.record, now: Date()),
                             kind: updates.record?.error != nil ? .warning : .info)
            }
        } accessory: {
            InfoButton("Pimento asks api.github.com for the latest release of github.com/Melvin2306/pimento, "
                + "sending only “User-Agent: Pimento/\(AppInfo.version)”. It only tells you: nothing is downloaded or "
                + "installed. The links open the release on github.com. \(UpdateCheck.disableVariable)=1 turns checks off.",
                label: "About update checks")
        }
    }
}
