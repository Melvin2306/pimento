# Template for the tap Melvin2306/homebrew-pimento (not published yet).
# scripts/update-homebrew.sh VERSION fills in the version and the sha256 of
# Pimento-<version>.zip and writes the result to build/homebrew/Casks/pimento.rb.
cask "pimento" do
  version "0.0.0"
  sha256 "0000000000000000000000000000000000000000000000000000000000000000"

  url "https://github.com/Melvin2306/pimento/releases/download/v#{version}/Pimento-#{version}.zip"
  name "Pimento"
  desc "Bulk-activate Azure PIM role assignments"
  homepage "https://github.com/Melvin2306/pimento"

  livecheck do
    url :url
    strategy :github_latest
  end

  # The app contains the CLI: install one or the other.
  conflicts_with formula: "pimento"
  depends_on macos: :sonoma

  app "Pimento.app"
  binary "#{appdir}/Pimento.app/Contents/Helpers/pimento"

  zap trash: [
    "~/.config/pimento",
    "~/Library/Application Support/Pimento",
    "~/Library/Preferences/io.github.melvin2306.pimento.plist",
    "~/Library/Saved Application State/io.github.melvin2306.pimento.savedState",
  ]

  caveats <<~EOS
    Pimento is ad-hoc signed, not notarized. If macOS refuses to open it:
      xattr -dr com.apple.quarantine "#{appdir}/Pimento.app"

    It signs in with your Azure CLI session (brew install azure-cli && az login),
    or with its own sign-in (Settings › Account).

    `brew uninstall --zap` does not remove Pimento sign-in's refresh tokens from
    the Keychain. Sign out first (Settings › Account, or `pimento logout --all`),
    or delete the items of service io.github.melvin2306.pimento in Keychain Access.
  EOS
end
