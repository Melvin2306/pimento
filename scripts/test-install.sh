#!/usr/bin/env bash
# Tests scripts/install.sh against the CLI archive that scripts/package-cli.sh
# left in build/, laid out like a release (stable and versioned names plus
# SHA256SUMS.txt) in a temporary folder. Everything is installed under a
# temporary HOME: your own ~/.local/bin and shell configuration are not touched.
#
#   scripts/package-cli.sh && scripts/test-install.sh
set -euo pipefail

cd "$(dirname "$0")/.."
case "$(uname -s)" in
  Darwin) platform=macos ;;
  Linux)
    case "$(uname -m)" in
      x86_64|amd64) platform=linux-x86_64 ;;
      arm64|aarch64) platform=linux-aarch64 ;;
      *) echo "unsupported processor: $(uname -m)" >&2; exit 1 ;;
    esac
    ;;
  *) echo "unsupported system: $(uname -s)" >&2; exit 1 ;;
esac
VERSION="$(sed -n 's/.*static let version = "\(.*\)".*/\1/p' Sources/PimentoCore/AppInfo.swift)"
archive="build/pimento-cli-${VERSION}-${platform}.tar.gz"
[[ -f "$archive" ]] || { echo "$archive is missing: run scripts/package-cli.sh first" >&2; exit 1; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/pimento-install-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
sum() { if command -v sha256sum >/dev/null; then sha256sum "$@"; else shasum -a 256 "$@"; fi; }

dist="$WORK/dist"
mkdir -p "$dist"
cp "$archive" "$dist/pimento-cli-${VERSION}-${platform}.tar.gz"
cp "$archive" "$dist/pimento-cli-${platform}.tar.gz"
(cd "$dist" && sum ./*.tar.gz | sed 's| \./| |' > SHA256SUMS.txt)

home="$WORK/home"
bin="$home/.local/bin"
# A clean environment: only a system PATH, the temporary HOME and a login shell.
run() { # SHELL-NAME ARGS...
  local shell="$1"; shift
  env -i PATH="/usr/bin:/bin" HOME="$home" SHELL="/bin/$shell" TMPDIR="$WORK" sh scripts/install.sh "$@"
}
fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "ok: $*"; }

# Latest (stable name), for each shell's completions.
for shell in zsh bash fish; do
  rm -rf "$home"
  run "$shell" --from "$dist" > "$WORK/out.txt" || { cat "$WORK/out.txt"; fail "install ($shell)"; }
  [[ "$("$bin/pimento" version)" == "pimento $VERSION" ]] || fail "pimento version ($shell)"
  case "$shell" in
    zsh) completion="$home/.local/share/zsh/site-functions/_pimento" ;;
    bash) completion="$home/.local/share/bash-completion/completions/pimento" ;;
    fish) completion="$home/.config/fish/completions/pimento.fish" ;;
  esac
  [[ -s "$completion" ]] || fail "$shell completions missing"
  grep -q "is not on your PATH" "$WORK/out.txt" || fail "no PATH hint ($shell)"
  pass "install from a release layout with $shell completions"
done

# Uninstall removes the binary and the completions.
run zsh --uninstall > /dev/null
[[ ! -e "$bin/pimento" ]] || fail "uninstall left $bin/pimento"
[[ -z "$(find "$home" -type f)" ]] || { find "$home" -type f; fail "uninstall left files"; }
pass "uninstall"

# A pinned version, downloaded with curl from a file:// base (the download path
# the real install takes), into --dir.
if command -v curl >/dev/null; then
  rm -rf "$home"
  env -i PATH="/usr/bin:/bin" HOME="$home" SHELL=/bin/sh TMPDIR="$WORK" \
    PIMENTO_VERSION="$VERSION" PIMENTO_DOWNLOAD_BASE="file://$dist" \
    sh scripts/install.sh --dir "$WORK/custom" --no-attestation > /dev/null || fail "pinned install via curl"
  [[ "$("$WORK/custom/pimento" version)" == "pimento $VERSION" ]] || fail "pinned pimento version"
  pass "pinned version downloaded with curl"
fi

# A tampered archive is refused and the installed pimento stays as it was.
rm -rf "$home"
run bash --from "$dist" --no-completions > /dev/null
before="$(sum "$bin/pimento")"
bad="$WORK/bad"
mkdir -p "$bad"
cp "$dist"/* "$bad/"
printf 'x' >> "$bad/pimento-cli-${platform}.tar.gz"
if run bash --from "$bad" > "$WORK/out.txt" 2>&1; then cat "$WORK/out.txt"; fail "a tampered archive was installed"; fi
grep -q "checksum mismatch" "$WORK/out.txt" || { cat "$WORK/out.txt"; fail "no checksum mismatch message"; }
[[ "$(sum "$bin/pimento")" == "$before" ]] || fail "the installed pimento changed"
pass "tampered archive refused"

# No checksum for the archive: refused.
grep -v " pimento-cli-${platform}.tar.gz\$" "$dist/SHA256SUMS.txt" > "$bad/SHA256SUMS.txt"
cp "$dist/pimento-cli-${platform}.tar.gz" "$bad/"
if run bash --from "$bad" > "$WORK/out.txt" 2>&1; then fail "installed without a checksum"; fi
grep -q "no checksum for" "$WORK/out.txt" || { cat "$WORK/out.txt"; fail "no missing-checksum message"; }
pass "missing checksum refused"

# A link in the way (Pimento.app's Install Command Line Tool) is left alone.
rm -f "$bin/pimento"
ln -s /nonexistent/Pimento.app/Contents/Helpers/pimento "$bin/pimento"
if run bash --from "$dist" > /dev/null 2>&1; then fail "replaced a link"; fi
run bash --uninstall > /dev/null 2>&1
[[ -L "$bin/pimento" ]] || fail "uninstall removed a link"
pass "links left alone"

echo "install.sh: all tests passed ($platform, $VERSION)"
