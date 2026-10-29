# Template for a Homebrew tap, NOT published yet (future work, once the
# repository is public). For each release: set `version`, and `sha256` from the
# release's SHA256SUMS.txt (line for pimento-cli-<version>-macos.tar.gz).
class Pimento < Formula
  desc "Bulk-activate your Azure PIM roles from the command line"
  homepage "https://github.com/melvin2306/pimento"
  version "0.0.0"
  url "https://github.com/melvin2306/pimento/releases/download/v#{version}/pimento-cli-#{version}-macos.tar.gz"
  sha256 "0000000000000000000000000000000000000000000000000000000000000000"
  license "MIT"

  depends_on :macos

  def install
    bin.install "pimento"
    zsh_completion.install "completions/_pimento"
    bash_completion.install "completions/pimento.bash" => "pimento"
    fish_completion.install "completions/pimento.fish"
  end

  def caveats
    <<~EOS
      pimento uses your Azure CLI session. If you don't have it yet:
        brew install azure-cli && az login
    EOS
  end

  test do
    assert_match version.to_s, shell_output("#{bin}/pimento version")
  end
end
