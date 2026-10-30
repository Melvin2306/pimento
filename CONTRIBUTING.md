# Contributing to Pimento

Thanks for helping. Bug reports, ideas and pull requests are all welcome.

## Reporting bugs

Open an issue with:

- what you did, what you expected, what happened;
- the macOS version, `az version` output and Pimento version (About Pimento, or `pimento --version`);
- the error text from the result column or banner.

**Never paste tokens, tenant IDs, subscription IDs, user names or resource names** from a real
tenant. Replace them with placeholders such as `00000000-0000-0000-0000-000000000000` or
`contoso.onmicrosoft.com`. Security issues go through [SECURITY.md](SECURITY.md), not public issues.

## Development

Requirements: macOS 14+, Swift 6.0+ (Xcode 16+ or the Command Line Tools), Azure CLI for manual testing.

```sh
swift build
swift test
swift run pimento list        # read-only, against your own tenant
scripts/bundle.sh             # build/Pimento.app (universal; --host-arch is faster)
scripts/make-dmg.sh           # build/Pimento-<version>.dmg from it
scripts/package-cli.sh        # the CLI archive for this platform
scripts/test-install.sh       # tests scripts/install.sh against that archive (temporary HOME)
```

Guidelines:

- Keep logic in `Sources/PimentoCore` and cover it with tests in `Tests/PimentoCoreTests`.
  The SwiftUI layer (`Sources/PimentoApp`) should stay thin.
- Tests must never call Azure. Use the fake transport and token provider in `Support.swift`,
  and **synthetic fixtures only** (placeholder GUIDs, `Contoso` / `Fabrikam` style names).
- Keep the safety properties intact: previews, `--dry-run` and the CLI's read-only commands go
  through `ReadOnlyTransport`; every write asks first (the CLI: `[y/N]` or `--yes`); the token
  never leaves memory or goes anywhere but `management.azure.com`.
- No third-party dependencies without discussing it in an issue first.
- The app must build with the Command Line Tools alone, so do not use macros that need full
  Xcode (for example SwiftUI's `@State` in the macOS 26 SDK; use the shared `AppModel`).
- To change the icon, edit `scripts/make-icon.swift`, run `swift scripts/make-icon.swift`, and
  commit the regenerated files in `Assets/` (and copy `icon_512x512.png` to
  `integrations/raycast/assets/icon.png`).
- The Raycast extension and the Alfred workflow in `integrations/` only run the CLI. Something
  they need goes into the CLI first (with tests); see their READMEs for their own checks.

## Pull requests

- One topic per pull request; add a line to `CHANGELOG.md` under *Unreleased*.
- Commit messages follow [Conventional Commits](https://www.conventionalcommits.org/)
  (`feat: ...`, `fix: ...`, `docs: ...`).
- CI (`swift build`, `swift test`, bundling, the disk image, the installers, ShellCheck) must pass.
  `scripts/install.sh` stays POSIX `sh` (it runs as `curl … | sh`) and `scripts/install.ps1` ASCII
  and Windows PowerShell 5.1 compatible.

## Releasing

1. Bump `AppInfo.version` in `Sources/PimentoCore/AppInfo.swift`, move the *Unreleased*
   changelog entries under the new version, and optionally write the release notes in
   `.github/release-notes/vX.Y.Z.md` (without one, the workflow writes a download section and
   adds GitHub's generated notes).
2. Tag `vX.Y.Z` on `main` and push the tag. The release workflow tests and builds
   `Pimento-X.Y.Z.dmg` and `Pimento-X.Y.Z.zip` (universal, ad-hoc signed, not notarized) and the
   CLI archives for macOS, Linux and Windows, adds copies under stable names (`Pimento.dmg`,
   `pimento-cli-macos.tar.gz`, …, for `releases/latest/download/` links and the install scripts),
   writes `SHA256SUMS.txt`, attests every file and publishes the release (a tag with `-`, such as
   `v1.2.0-rc.1`, as a pre-release, which `latest` skips).
3. Optionally run `scripts/update-homebrew.sh X.Y.Z --release` and copy the files it writes to
   `build/homebrew/` into the tap (see `packaging/homebrew/README.md`).
