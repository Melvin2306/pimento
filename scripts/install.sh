#!/bin/sh
# Installs the pimento command-line tool on macOS or Linux from a GitHub release,
# for the current user (no sudo):
#
#   curl -fsSL https://raw.githubusercontent.com/Melvin2306/pimento/main/scripts/install.sh | sh
#   curl -fsSL https://raw.githubusercontent.com/Melvin2306/pimento/main/scripts/install.sh | sh -s -- --uninstall
#
# It downloads the archive for this system and SHA256SUMS.txt, checks the
# archive's SHA-256 (and, when the GitHub CLI is installed and signed in, its
# build provenance attestation), installs `pimento` to ~/.local/bin and the
# shell completions for your shell, and changes no shell configuration file.
#
# Options (environment variables in brackets):
#   --version X        install release X instead of the latest   [PIMENTO_VERSION]
#   --dir DIR          install into DIR (default ~/.local/bin)    [PIMENTO_INSTALL_DIR]
#   --no-completions   do not install shell completions
#   --no-attestation   do not check the attestation, even with gh
#   --uninstall        remove pimento and its completions again
#   --from DIR         use the archive and SHA256SUMS.txt in DIR instead of
#                      downloading them (for testing builds)
#   [PIMENTO_DOWNLOAD_BASE]  the URL to download from instead of the release
set -eu

REPO="Melvin2306/pimento"

say() { printf '%s\n' "$*"; }
warn() { printf 'pimento-install: %s\n' "$*" >&2; }
die() { printf 'pimento-install: error: %s\n' "$*" >&2; exit 1; }
has() { command -v "$1" >/dev/null 2>&1; }

usage() {
  cat <<'USAGE'
Installs the pimento command-line tool (macOS, Linux) for the current user.

  install.sh [--version X] [--dir DIR] [--no-completions] [--no-attestation]
  install.sh --uninstall [--dir DIR]

  --version X        install release X instead of the latest   (PIMENTO_VERSION)
  --dir DIR          install into DIR, default ~/.local/bin     (PIMENTO_INSTALL_DIR)
  --no-completions   do not install shell completions
  --no-attestation   do not check the build attestation, even with gh
  --uninstall        remove pimento and its completions again
  --from DIR         use the archive and SHA256SUMS.txt in DIR (testing)
USAGE
}

version="${PIMENTO_VERSION:-}"
install_dir="${PIMENTO_INSTALL_DIR:-}"
download_base="${PIMENTO_DOWNLOAD_BASE:-}"
from_dir=""
completions=1
attestation=1
action=install

while [ $# -gt 0 ]; do
  case "$1" in
    --version) [ $# -ge 2 ] || die "--version needs a value"; version="$2"; shift 2 ;;
    --version=*) version="${1#--version=}"; shift ;;
    --dir) [ $# -ge 2 ] || die "--dir needs a value"; install_dir="$2"; shift 2 ;;
    --dir=*) install_dir="${1#--dir=}"; shift ;;
    --from) [ $# -ge 2 ] || die "--from needs a value"; from_dir="$2"; shift 2 ;;
    --from=*) from_dir="${1#--from=}"; shift ;;
    --no-completions) completions=0; shift ;;
    --no-attestation) attestation=0; shift ;;
    --uninstall) action=uninstall; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown option: $1 (see --help)" ;;
  esac
done

[ -n "${HOME:-}" ] || die "HOME is not set"
[ -n "$install_dir" ] || install_dir="$HOME/.local/bin"
case "$install_dir" in
  /*) ;;
  *) install_dir="$(pwd)/$install_dir" ;;
esac
dest="$install_dir/pimento"

data_home="${XDG_DATA_HOME:-$HOME/.local/share}"
config_home="${XDG_CONFIG_HOME:-$HOME/.config}"
zsh_completion="$data_home/zsh/site-functions/_pimento"
bash_completion="$data_home/bash-completion/completions/pimento"
fish_completion="$config_home/fish/completions/pimento.fish"
user_shell="$(basename "${SHELL:-sh}")"

# --- uninstall ---------------------------------------------------------------

if [ "$action" = uninstall ]; then
  if [ -L "$dest" ]; then
    warn "$dest is a link (made by Pimento.app's Install Command Line Tool?): left alone."
    warn "Remove it with Pimento > Uninstall Command Line Tool..., or: rm \"$dest\""
  elif [ -f "$dest" ]; then
    rm -f "$dest"
    say "Removed $dest"
  else
    say "No pimento in $install_dir"
  fi
  for f in "$zsh_completion" "$bash_completion" "$fish_completion"; do
    if [ -f "$f" ] && [ ! -L "$f" ]; then rm -f "$f"; say "Removed $f"; fi
  done
  say "Pimento's own files (presets, history, sign-in) are kept:"
  case "$(uname -s)" in
    Darwin) say "  ~/Library/Application Support/Pimento (and, after pimento login, Keychain items named io.github.melvin2306.pimento)" ;;
    *) say "  $config_home/pimento" ;;
  esac
  say "Run 'pimento logout --all' before uninstalling to remove the sign-in, or delete that folder."
  exit 0
fi

# --- what to download --------------------------------------------------------

case "$(uname -s)" in
  Darwin) os=macos ;;
  Linux) os=linux ;;
  MINGW*|MSYS*|CYGWIN*) die "on Windows, use install.ps1 in PowerShell: irm https://raw.githubusercontent.com/$REPO/main/scripts/install.ps1 | iex" ;;
  *) die "unsupported system: $(uname -s) (pimento runs on macOS, Linux and Windows)" ;;
esac
case "$(uname -m)" in
  x86_64|amd64) arch=x86_64 ;;
  arm64|aarch64) arch=aarch64 ;;
  *) die "unsupported processor: $(uname -m)" ;;
esac

# The macOS archive is universal (Apple silicon and Intel).
if [ "$os" = macos ]; then platform=macos; else platform="linux-$arch"; fi

version="${version#v}"
case "$version" in
  *[!0-9A-Za-z.-]*) die "not a version: $version" ;;
esac
if [ -n "$version" ]; then
  asset="pimento-cli-$version-$platform.tar.gz"
  [ -n "$download_base" ] || download_base="https://github.com/$REPO/releases/download/v$version"
else
  asset="pimento-cli-$platform.tar.gz"
  [ -n "$download_base" ] || download_base="https://github.com/$REPO/releases/latest/download"
fi

tmp="$(mktemp -d 2>/dev/null || mktemp -d -t pimento-install)"
[ -n "$tmp" ] && [ -d "$tmp" ] || die "could not create a temporary folder"
trap 'rm -rf "$tmp"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

fetch() { # URL FILE
  if has curl; then
    curl -fsSL --retry 3 --proto '=https,file' --proto-redir '=https' -o "$2" "$1"
  elif has wget; then
    wget -q --https-only -O "$2" "$1"
  else
    die "neither curl nor wget is installed"
  fi
}

if [ -n "$from_dir" ]; then
  [ -f "$from_dir/$asset" ] || die "$from_dir/$asset not found"
  [ -f "$from_dir/SHA256SUMS.txt" ] || die "$from_dir/SHA256SUMS.txt not found"
  say "Using $asset from $from_dir"
  cp "$from_dir/$asset" "$tmp/$asset"
  cp "$from_dir/SHA256SUMS.txt" "$tmp/SHA256SUMS.txt"
else
  say "Downloading $asset from $download_base"
  fetch "$download_base/$asset" "$tmp/$asset" \
    || die "could not download $download_base/$asset${version:+ (is $version a released version?)}"
  fetch "$download_base/SHA256SUMS.txt" "$tmp/SHA256SUMS.txt" \
    || die "could not download $download_base/SHA256SUMS.txt"
fi

# --- verify ------------------------------------------------------------------

expected="$(awk -v f="$asset" '$2 == f || $2 == "*" f { print tolower($1); exit }' "$tmp/SHA256SUMS.txt")"
[ -n "$expected" ] || die "SHA256SUMS.txt has no checksum for $asset"
if has sha256sum; then
  actual="$(sha256sum "$tmp/$asset" | awk '{ print tolower($1) }')"
elif has shasum; then
  actual="$(shasum -a 256 "$tmp/$asset" | awk '{ print tolower($1) }')"
elif has openssl; then
  actual="$(openssl dgst -sha256 -r "$tmp/$asset" | awk '{ print tolower($1) }')"
else
  die "no SHA-256 tool found (sha256sum, shasum or openssl)"
fi
if [ "$actual" != "$expected" ]; then
  die "checksum mismatch for $asset: expected $expected, got $actual. Nothing was installed."
fi
say "Checksum OK (SHA-256 $actual)"

if [ "$attestation" = 1 ] && [ -z "$from_dir" ] && has gh; then
  if gh auth status >/dev/null 2>&1; then
    if gh attestation verify "$tmp/$asset" --repo "$REPO" \
      --signer-workflow "$REPO/.github/workflows/release.yml" >/dev/null 2>&1; then
      say "Build provenance attestation OK (built by $REPO's release workflow)"
    else
      die "gh attestation verify failed for $asset: it was not built by $REPO's release workflow. Nothing was installed. (--no-attestation skips this check.)"
    fi
  else
    say "Skipping the attestation check: gh is not signed in (gh auth login)."
  fi
fi

# --- install -----------------------------------------------------------------

mkdir -p "$tmp/x"
tar -xzf "$tmp/$asset" -C "$tmp/x"
src=""
for f in "$tmp"/x/*/pimento; do
  [ -f "$f" ] || continue
  [ -z "$src" ] || die "$asset holds more than one pimento"
  src="$f"
done
[ -n "$src" ] || die "$asset holds no pimento"
pkg="$(dirname "$src")"

if [ -L "$dest" ]; then
  die "$dest is a link (made by Pimento.app's Install Command Line Tool?). Remove it first (Pimento > Uninstall Command Line Tool..., or rm \"$dest\"), or install elsewhere with --dir."
fi
mkdir -p "$install_dir"
cp "$src" "$dest.tmp.$$"
chmod 755 "$dest.tmp.$$"
if [ "$os" = macos ] && has xattr; then
  xattr -d com.apple.quarantine "$dest.tmp.$$" 2>/dev/null || true
fi
mv -f "$dest.tmp.$$" "$dest"
installed_version="$("$dest" version 2>&1)" || die "$dest does not run: $installed_version"
say "Installed $dest ($installed_version)"

if [ "$completions" = 1 ] && [ -d "$pkg/completions" ]; then
  case "$user_shell" in
    zsh) target="$zsh_completion"; file="_pimento" ;;
    bash) target="$bash_completion"; file="pimento.bash" ;;
    fish) target="$fish_completion"; file="pimento.fish" ;;
    *) target=""; file="" ;;
  esac
  if [ -n "$target" ] && [ -f "$pkg/completions/$file" ]; then
    mkdir -p "$(dirname "$target")"
    cp "$pkg/completions/$file" "$target"
    chmod 644 "$target"
    say "Installed $user_shell completions: $target"
    if [ "$user_shell" = zsh ]; then
      say "  zsh loads them from a folder on \$fpath. If completions do not work, add to ~/.zshrc (before compinit):"
      say "    fpath=(\"$(dirname "$target")\" \$fpath)"
    fi
  else
    say "Shell completions: pimento completions zsh|bash|fish prints them (see the README)."
  fi
fi

# --- next steps --------------------------------------------------------------

on_path=0
case ":${PATH:-}:" in
  *":$install_dir:"*) on_path=1 ;;
esac
if [ "$on_path" = 0 ]; then
  say ""
  say "$install_dir is not on your PATH. Add it, then open a new terminal:"
  case "$user_shell" in
    zsh) say "  echo 'export PATH=\"$install_dir:\$PATH\"' >> ~/.zshrc" ;;
    bash)
      # shellcheck disable=SC2088 # shown to the user, not expanded
      if [ "$os" = macos ]; then rc="~/.bash_profile"; else rc="~/.bashrc"; fi
      say "  echo 'export PATH=\"$install_dir:\$PATH\"' >> $rc" ;;
    fish) say "  fish_add_path \"$install_dir\"" ;;
    *) say "  export PATH=\"$install_dir:\$PATH\"   (in your shell's startup file)" ;;
  esac
  say "Until then, run it as $dest."
else
  found="$(command -v pimento 2>/dev/null || true)"
  if [ -n "$found" ] && [ "$found" != "$dest" ]; then
    warn "another pimento comes first on your PATH: $found"
  fi
fi

say ""
say "Next steps:"
say "  pimento --demo list    try it with synthetic data, no Azure needed"
say "  az login               sign in with the Azure CLI (or: pimento login, see the README)"
say "  pimento list           your eligible PIM roles"
say "  pimento help           all commands"
