# Template for the tap Melvin2306/homebrew-pimento (not published yet).
# scripts/update-homebrew.sh VERSION fills in the version and each archive's
# sha256 and writes the result to build/homebrew/Formula/pimento.rb.
class Pimento < Formula
  desc "Command-line tool to bulk-activate Azure PIM role assignments"
  homepage "https://github.com/Melvin2306/pimento"
  version "0.0.0"
  license "MIT"
  # Prebuilt archives from the GitHub release (no build from source, no bottles).
  if OS.mac?
    url "https://github.com/Melvin2306/pimento/releases/download/v#{version}/pimento-cli-#{version}-macos.tar.gz"
    sha256 "0000000000000000000000000000000000000000000000000000000000000001"
  elsif Hardware::CPU.arm?
    url "https://github.com/Melvin2306/pimento/releases/download/v#{version}/pimento-cli-#{version}-linux-aarch64.tar.gz"
    sha256 "0000000000000000000000000000000000000000000000000000000000000002"
  else
    url "https://github.com/Melvin2306/pimento/releases/download/v#{version}/pimento-cli-#{version}-linux-x86_64.tar.gz"
    sha256 "0000000000000000000000000000000000000000000000000000000000000003"
  end

  depends_on macos: :sonoma

  on_linux do
    depends_on "curl"
  end

  def install
    bin.install "pimento"
    bash_completion.install "completions/pimento.bash" => "pimento"
    zsh_completion.install "completions/_pimento"
    fish_completion.install "completions/pimento.fish"
  end

  def caveats
    <<~EOS
      pimento signs in with your Azure CLI session (brew install azure-cli && az login),
      or without it: pimento login (README › Pimento sign-in).
    EOS
  end

  test do
    assert_match "pimento #{version}", shell_output("#{bin}/pimento version")
    assert_match "activate", shell_output("#{bin}/pimento help")
  end
end
