#!/usr/bin/env bash
# Fills the Homebrew templates in packaging/homebrew/ with a release's version
# and SHA-256 sums and writes ready-to-copy files to build/homebrew/:
#
#   build/homebrew/Formula/pimento.rb   the CLI (macOS, Linux x86_64 and, if built, aarch64)
#   build/homebrew/Casks/pimento.rb     the app, with the CLI linked in
#
# It never pushes or publishes anything: copying the files into the tap
# repository is a manual step (packaging/homebrew/README.md).
#
#   scripts/update-homebrew.sh 0.2.0                  # sums of the archives in build/
#   scripts/update-homebrew.sh 0.2.0 --from DIR       # ...in DIR (archives or SHA256SUMS.txt)
#   scripts/update-homebrew.sh 0.2.0 --release        # SHA256SUMS.txt of the GitHub release v0.2.0 (gh)
#
# Needs: Pimento-<v>.zip, pimento-cli-<v>-macos.tar.gz and
# pimento-cli-<v>-linux-x86_64.tar.gz; pimento-cli-<v>-linux-aarch64.tar.gz is
# optional (without it, the formula is x86_64-only on Linux).
set -euo pipefail

cd "$(dirname "$0")/.."
REPO="Melvin2306/pimento"
usage() { sed -n '2,19p' "$0" | sed 's/^# \{0,1\}//'; exit 64; }

VERSION="${1:-}"
[[ -n "$VERSION" && "$VERSION" != -* ]] || usage
shift
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+([-.][0-9A-Za-z.]+)?$ ]] || { echo "not a version: $VERSION" >&2; exit 64; }
FROM="build"
RELEASE=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --from) FROM="${2:?--from needs a folder}"; shift 2 ;;
    --release) RELEASE=1; shift ;;
    -h|--help) usage ;;
    *) echo "unknown option: $1" >&2; usage ;;
  esac
done

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
if [[ $RELEASE == 1 ]]; then
  command -v gh >/dev/null || { echo "--release needs the GitHub CLI (gh)" >&2; exit 1; }
  gh release download "v$VERSION" --repo "$REPO" --pattern SHA256SUMS.txt --dir "$WORK" >/dev/null
  FROM="$WORK"
fi

sha256_of() { if command -v sha256sum >/dev/null; then sha256sum "$1"; else shasum -a 256 "$1"; fi | cut -d' ' -f1; }

# The SHA-256 of a release asset: from SHA256SUMS.txt in $FROM, else of the file itself. Empty if neither.
sum() {
  local name="$1" line
  if [[ -f "$FROM/SHA256SUMS.txt" ]]; then
    line="$(awk -v n="$name" '{ f = $2; sub(/^\*/, "", f) } f == n { print $1; exit }' "$FROM/SHA256SUMS.txt")"
    if [[ -n "$line" ]]; then echo "$line"; return; fi
  fi
  if [[ -f "$FROM/$name" ]]; then sha256_of "$FROM/$name"; fi
}

APP_ZIP="Pimento-$VERSION.zip"
MACOS="pimento-cli-$VERSION-macos.tar.gz"
LINUX_X64="pimento-cli-$VERSION-linux-x86_64.tar.gz"
LINUX_ARM="pimento-cli-$VERSION-linux-aarch64.tar.gz"
APP_SUM="$(sum "$APP_ZIP")"
MACOS_SUM="$(sum "$MACOS")"
LINUX_X64_SUM="$(sum "$LINUX_X64")"
LINUX_ARM_SUM="$(sum "$LINUX_ARM")"

missing=()
[[ -n "$APP_SUM" ]] || missing+=("$APP_ZIP")
[[ -n "$MACOS_SUM" ]] || missing+=("$MACOS")
[[ -n "$LINUX_X64_SUM" ]] || missing+=("$LINUX_X64")
if [[ ${#missing[@]} -gt 0 ]]; then
  echo "no SHA-256 for: ${missing[*]} (looked in $FROM)" >&2
  exit 1
fi
for s in "$APP_SUM" "$MACOS_SUM" "$LINUX_X64_SUM" ${LINUX_ARM_SUM:+"$LINUX_ARM_SUM"}; do
  [[ "$s" =~ ^[0-9a-f]{64}$ ]] || { echo "not a SHA-256: $s" >&2; exit 1; }
done

OUT="build/homebrew"
mkdir -p "$OUT/Formula" "$OUT/Casks"

# Formula: each url line names its archive; the sha256 line after it gets that
# archive's sum. Without an aarch64 archive the arm branch is left out and
# Linux installs need x86_64. The template's header comment is dropped.
awk -v version="$VERSION" -v mac="$MACOS_SUM" -v x64="$LINUX_X64_SUM" -v arm="$LINUX_ARM_SUM" '
  NR == 1, /^class / { if ($0 !~ /^class /) next }
  /^  version "/ { print "  version \"" version "\""; next }
  /^  elsif Hardware::CPU.arm\?/ && arm == "" { skip = 1; next }
  skip && /^  else$/ { skip = 0; print "  else"; next }
  skip { next }
  /url ".*-macos\.tar\.gz"/ { want = mac }
  /url ".*-linux-x86_64\.tar\.gz"/ { want = x64 }
  /url ".*-linux-aarch64\.tar\.gz"/ { want = arm }
  /^ *sha256 "/ && want != "" { sub(/"[0-9a-f]*"/, "\"" want "\""); want = "" }
  /^    depends_on "curl"$/ && arm == "" { print "    depends_on arch: :x86_64" }
  { print }
' packaging/homebrew/Formula/pimento.rb > "$OUT/Formula/pimento.rb"

awk -v version="$VERSION" -v sum="$APP_SUM" '
  NR == 1, /^cask / { if ($0 !~ /^cask /) next }
  /^  version "/ { print "  version \"" version "\""; next }
  /^  sha256 "/ { print "  sha256 \"" sum "\""; next }
  { print }
' packaging/homebrew/Casks/pimento.rb > "$OUT/Casks/pimento.rb"

if grep -q '"0\{63\}[0-9]"' "$OUT/Formula/pimento.rb" "$OUT/Casks/pimento.rb"; then
  echo "a placeholder sha256 is left in $OUT" >&2
  exit 1
fi

echo "Wrote $OUT/Formula/pimento.rb and $OUT/Casks/pimento.rb for $VERSION"
[[ -n "$LINUX_ARM_SUM" ]] || echo "(no $LINUX_ARM: the formula is x86_64-only on Linux)"
if command -v brew >/dev/null && [[ "${PIMENTO_SKIP_BREW_STYLE:-}" != 1 ]]; then
  HOMEBREW_NO_AUTO_UPDATE=1 brew style "$OUT/Formula/pimento.rb" "$OUT/Casks/pimento.rb"
fi
