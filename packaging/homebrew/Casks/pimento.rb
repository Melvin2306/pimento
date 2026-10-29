# Template for a Homebrew tap, NOT published yet (future work, once the
# repository is public). For each release: set `version`, and `sha256` from the
# release's SHA256SUMS.txt (line for Pimento-<version>.zip).
cask "pimento" do
  version "0.0.0"
  sha256 "0000000000000000000000000000000000000000000000000000000000000000"

  url "https://github.com/melvin2306/pimento/releases/download/v#{version}/Pimento-#{version}.zip"
  name "Pimento"
  desc "Bulk-activate your Azure PIM roles from a native Mac app"
  homepage "https://github.com/melvin2306/pimento"

  depends_on macos: ">= :sonoma"
  # The app contains the CLI; don't install both.
  conflicts_with formula: "pimento"

  app "Pimento.app"
  binary "#{appdir}/Pimento.app/Contents/Helpers/pimento"

  zap trash: "~/Library/Preferences/io.github.melvin2306.pimento.plist"

  caveats <<~EOS
    Pimento is ad-hoc signed, not notarized. If macOS refuses to open it:
      xattr -dr com.apple.quarantine "#{appdir}/Pimento.app"
    It uses your Azure CLI session: brew install azure-cli && az login
  EOS
end
