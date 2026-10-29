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
scripts/bundle.sh             # build/Pimento.app
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
  commit the regenerated files in `Assets/`.

## Pull requests

- One topic per pull request; add a line to `CHANGELOG.md` under *Unreleased*.
- Commit messages follow [Conventional Commits](https://www.conventionalcommits.org/)
  (`feat: ...`, `fix: ...`, `docs: ...`).
- CI (`swift build`, `swift test`, bundling) must pass.

## Releasing

1. Bump `AppInfo.version` in `Sources/PimentoCore/AppInfo.swift` and move the *Unreleased*
   changelog entries under the new version.
2. Tag `vX.Y.Z` and push the tag. The release workflow tests and builds `Pimento-X.Y.Z.zip` (ad-hoc
   signed, not notarized), the CLI archives for macOS, Linux and Windows and `SHA256SUMS.txt`, and
   attaches them to a GitHub release.
3. Optionally run `scripts/update-homebrew.sh X.Y.Z --release` and copy the files it writes to
   `build/homebrew/` into the tap (see `packaging/homebrew/README.md`).
