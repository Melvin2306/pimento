# Homebrew: formula and cask (not published yet)

Templates for a Homebrew tap, ready for when the repository is public:

| File | Installs | From the release asset |
| --- | --- | --- |
| [`Formula/pimento.rb`](Formula/pimento.rb) | the `pimento` CLI, with bash, zsh and fish completions | `pimento-cli-<v>-macos.tar.gz` (macOS 14+), `pimento-cli-<v>-linux-x86_64.tar.gz` / `-linux-aarch64.tar.gz` (Linux) |
| [`Casks/pimento.rb`](Casks/pimento.rb) | Pimento.app, and its bundled CLI as `pimento` | `Pimento-<v>.zip` (macOS 14+) |

Both install the prebuilt archives of a GitHub release: nothing is built from source and there
are no bottles. The formula needs `curl` on Linux (the binary links libcurl). Install one or the
other, not both: they both provide `pimento`. The cask declares it with `conflicts_with formula:`,
which Homebrew does not enforce yet, so installing both fails only when the second links `pimento`.

The cask's `zap` removes `~/Library/Application Support/Pimento` (presets, history, sign-in
settings), the preferences, the saved window state and `~/.config/pimento` (the token file, when
`PIMENTO_TOKEN_STORE=file`). It cannot remove Keychain items: sign out first (`pimento logout --all`
or Settings › Account), or delete the items of service `io.github.melvin2306.pimento` in Keychain
Access. The cask's caveats say the same.

## Fill in a release

The templates have version `0.0.0` and placeholder sums. For a release:

```sh
scripts/update-homebrew.sh 0.2.0 --release        # sums from the release's SHA256SUMS.txt (needs gh)
scripts/update-homebrew.sh 0.2.0                  # or: sums of the archives in build/
scripts/update-homebrew.sh 0.2.0 --from ~/Downloads/pimento-0.2.0
```

It writes `build/homebrew/Formula/pimento.rb` and `build/homebrew/Casks/pimento.rb`, and runs
`brew style` on them when Homebrew is installed (`PIMENTO_SKIP_BREW_STYLE=1` skips that). It never
pushes anything. Without a `linux-aarch64` archive (the release builds it only once the repository
is public, on GitHub's free arm64 runners) the formula is x86_64-only on Linux
(`depends_on arch: :x86_64`).

## Create the tap (once, by hand)

A tap is a GitHub repository named `homebrew-<name>`; `brew tap Melvin2306/pimento` then finds
`Melvin2306/homebrew-pimento`.

1. Create a **public** repository `Melvin2306/homebrew-pimento` with a short README and the MIT
   license (GitHub's web UI, or `gh repo create Melvin2306/homebrew-pimento --public`).
2. Clone it and add the generated files:

   ```sh
   git clone https://github.com/Melvin2306/homebrew-pimento.git
   cd homebrew-pimento
   mkdir -p Formula Casks
   cp ../pimento/build/homebrew/Formula/pimento.rb Formula/
   cp ../pimento/build/homebrew/Casks/pimento.rb Casks/
   ```

3. Check them from the tap (it has to be tapped for `brew audit`):

   ```sh
   brew tap Melvin2306/pimento "$PWD"        # taps the local clone
   brew style Melvin2306/pimento
   brew audit --new --formula Melvin2306/pimento/pimento
   brew audit --new --cask Melvin2306/pimento/pimento
   brew install --formula Melvin2306/pimento/pimento && brew test Melvin2306/pimento/pimento
   brew uninstall pimento
   brew install --cask Melvin2306/pimento/pimento
   ```

4. Commit and push. Users then run:

   ```sh
   brew install melvin2306/pimento/pimento          # the CLI (macOS or Linux)
   brew install --cask melvin2306/pimento/pimento   # the app, CLI included
   ```

For each later release: run `scripts/update-homebrew.sh <version> --release`, copy the two files
into the tap, `brew style` / `brew audit`, commit and push.

## Not done (on purpose)

- No tap repository exists yet and nothing is published.
- No pull requests to homebrew-core or homebrew-cask. homebrew-core builds from source and wants
  a notable project; homebrew-cask wants signed and notarized apps (Pimento is ad-hoc signed).
  A tap has neither requirement.
- No bottles: the formula installs the release's prebuilt, already universal (macOS) binary.

## Checks

`brew style` passes on the templates and on the generated files (`brew style
packaging/homebrew/Formula/pimento.rb packaging/homebrew/Casks/pimento.rb`; it is read-only).
`brew audit` needs a tapped tap, see above.
