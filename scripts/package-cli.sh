#!/usr/bin/env bash
# Builds the pimento command-line tool on its own and packs it as
# build/pimento-cli-<version>-macos.tar.gz:
#   pimento-cli-<version>-macos/pimento       universal binary (arm64 + x86_64), ad-hoc signed
#   pimento-cli-<version>-macos/completions/  _pimento (zsh), pimento.bash, pimento.fish
#   pimento-cli-<version>-macos/LICENSE
#   pimento-cli-<version>-macos/README.md     the command-line part of the README
#
#   scripts/package-cli.sh              # universal binary
#   scripts/package-cli.sh --host-arch  # only this Mac's architecture (faster)
set -euo pipefail

cd "$(dirname "$0")/.."
PRODUCT="pimento"
BUNDLE_ID="io.github.melvin2306.pimento"
VERSION="$(sed -n 's/.*static let version = "\(.*\)".*/\1/p' Sources/PimentoCore/AppInfo.swift)"
[[ -n "$VERSION" ]] || { echo "could not read the version from AppInfo.swift" >&2; exit 1; }
NAME="${PRODUCT}-cli-${VERSION}-macos"
STAGE="build/$NAME"
TARBALL="build/$NAME.tar.gz"

ARCHS=(--arch arm64 --arch x86_64)
case "${1:-}" in
  --host-arch) ARCHS=() ;;
  "") ;;
  *) echo "unknown option: $1" >&2; exit 64 ;;
esac
# (bash 3.2 treats an empty array as unset under `set -u`, hence the ${…+…}.)
swift build -c release --product "$PRODUCT" ${ARCHS[@]+"${ARCHS[@]}"}
BIN="$(swift build -c release --product "$PRODUCT" ${ARCHS[@]+"${ARCHS[@]}"} --show-bin-path)/$PRODUCT"

rm -rf "$STAGE" "$TARBALL"
mkdir -p "$STAGE/completions"
cp "$BIN" "$STAGE/$PRODUCT"
codesign --force --sign - --identifier "${BUNDLE_ID}.cli" "$STAGE/$PRODUCT" >/dev/null 2>&1
codesign --verify --strict "$STAGE/$PRODUCT"
"$STAGE/$PRODUCT" version >/dev/null
"$STAGE/$PRODUCT" completions zsh > "$STAGE/completions/_pimento"
"$STAGE/$PRODUCT" completions bash > "$STAGE/completions/pimento.bash"
"$STAGE/$PRODUCT" completions fish > "$STAGE/completions/pimento.fish"
cp LICENSE "$STAGE/LICENSE"

# README.md: the part between the cli-readme markers, under a short header.
{
  echo "# pimento ${VERSION}: Azure PIM from the command line"
  echo
  echo "Command-line tool of Pimento (https://github.com/melvin2306/pimento)."
  echo "Copy \`pimento\` to a folder on your PATH, e.g. \`/usr/local/bin\` or \`~/.local/bin\`."
  echo "It is ad-hoc signed, not notarized: if macOS blocks it, run"
  echo "\`xattr -d com.apple.quarantine pimento\`. Shell completions are in \`completions/\`."
  echo
  sed -n '/<!-- cli-readme:start -->/,/<!-- cli-readme:end -->/{//!p;}' README.md
} > "$STAGE/README.md"
grep -q "pimento activate" "$STAGE/README.md" || { echo "README excerpt is empty: check the cli-readme markers" >&2; exit 1; }

COPYFILE_DISABLE=1 tar --no-xattrs -czf "$TARBALL" -C build "$NAME"
rm -rf "$STAGE"
echo "Packed $TARBALL ($(lipo -archs "$BIN" 2>/dev/null || echo "?")):"
shasum -a 256 "$TARBALL"
