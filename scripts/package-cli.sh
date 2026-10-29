#!/usr/bin/env bash
# Builds the pimento command-line tool on its own and packs it for this platform:
#
#   macOS    build/pimento-cli-<version>-macos.tar.gz             universal (arm64 + x86_64), ad-hoc signed
#   Linux    build/pimento-cli-<version>-linux-<arch>.tar.gz      Swift runtime linked in statically
#   Windows  build/pimento-cli-<version>-windows-<arch>.zip       (Git Bash) with the Swift runtime DLLs
#
# Each holds pimento (pimento.exe and its DLLs), LICENSE, README.md (the
# command-line part of the README) and, on macOS and Linux, completions/
# (_pimento, pimento.bash, pimento.fish). The SHA-256 of the archive is printed last.
#
#   scripts/package-cli.sh              # macOS: universal binary
#   scripts/package-cli.sh --host-arch  # macOS: only this Mac's architecture (faster)
set -euo pipefail

cd "$(dirname "$0")/.."
PRODUCT="pimento"
BUNDLE_ID="io.github.melvin2306.pimento"
VERSION="$(sed -n 's/.*static let version = "\(.*\)".*/\1/p' Sources/PimentoCore/AppInfo.swift)"
[[ -n "$VERSION" ]] || { echo "could not read the version from AppInfo.swift" >&2; exit 1; }

case "$(uname -s)" in
  Darwin) OS=macos ;;
  Linux) OS=linux ;;
  MINGW*|MSYS*|CYGWIN*) OS=windows ;;
  *) echo "unsupported platform: $(uname -s)" >&2; exit 1 ;;
esac
case "$(uname -m)" in
  x86_64|amd64) ARCH=x86_64 ;;
  arm64|aarch64) ARCH=$([[ $OS == linux ]] && echo aarch64 || echo arm64) ;;
  *) ARCH="$(uname -m)" ;;
esac

BUILD_FLAGS=()
case "$OS" in
  macos)
    NAME="${PRODUCT}-cli-${VERSION}-macos"
    BUILD_FLAGS=(--arch arm64 --arch x86_64)
    case "${1:-}" in
      --host-arch) BUILD_FLAGS=() ;;
      "") ;;
      *) echo "unknown option: $1" >&2; exit 64 ;;
    esac
    ;;
  linux)
    NAME="${PRODUCT}-cli-${VERSION}-${OS}-${ARCH}"
    # No Swift toolchain needed to run it: the Swift runtime and Foundation are linked in.
    BUILD_FLAGS=(--static-swift-stdlib)
    ;;
  windows)
    # Windows cannot link Foundation statically (no static libcurl): the
    # runtime DLLs go next to pimento.exe instead.
    NAME="${PRODUCT}-cli-${VERSION}-${OS}-${ARCH}"
    ;;
esac
EXE="$PRODUCT"; [[ $OS == windows ]] && EXE="$PRODUCT.exe"
STAGE="build/$NAME"

# (bash 3.2 treats an empty array as unset under `set -u`, hence the ${…+…}.)
swift build -c release --product "$PRODUCT" ${BUILD_FLAGS[@]+"${BUILD_FLAGS[@]}"}
BIN="$(swift build -c release --product "$PRODUCT" ${BUILD_FLAGS[@]+"${BUILD_FLAGS[@]}"} --show-bin-path)/$EXE"

rm -rf "$STAGE" "build/$NAME.tar.gz" "build/$NAME.zip"
mkdir -p "$STAGE"
cp "$BIN" "$STAGE/$EXE"
if [[ $OS == linux ]] && command -v strip >/dev/null; then
  strip "$STAGE/$EXE"
fi
if [[ $OS == macos ]]; then
  codesign --force --sign - --identifier "${BUNDLE_ID}.cli" "$STAGE/$EXE" >/dev/null 2>&1
  codesign --verify --strict "$STAGE/$EXE"
fi
if [[ $OS == windows ]]; then
  # The Swift runtime DLLs pimento.exe loads (ldd lists them with their folder).
  RUNTIME=""
  IFS=: read -ra DIRS <<< "$PATH"
  for d in "${DIRS[@]}"; do [[ -f "$d/swiftCore.dll" ]] && { RUNTIME="$d"; break; }; done
  [[ -n "$RUNTIME" ]] || { echo "swiftCore.dll is not on PATH: is the Swift runtime installed?" >&2; exit 1; }
  if command -v ldd >/dev/null; then
    ldd "$STAGE/$EXE"
    # Everything that is not part of Windows itself.
    DLLS="$(ldd "$STAGE/$EXE" | awk '$3 ~ /^\// && tolower($3) !~ /^\/c\/windows\// { print $3 }' | sort -u)"
  else
    DLLS="$(ls "$RUNTIME"/*.dll)"
  fi
  [[ -n "$DLLS" ]] || { echo "found no Swift runtime DLLs for $EXE" >&2; exit 1; }
  while IFS= read -r dll; do cp "$dll" "$STAGE/"; done <<< "$DLLS"
  echo "DLLs: $(cd "$STAGE" && ls *.dll | tr '\n' ' ')"
  # Must start without the Swift toolchain's DLLs on PATH.
  PATH="/usr/bin:$(cygpath -u "${SYSTEMROOT:-C:\\Windows}")/System32" "$STAGE/$EXE" version >/dev/null \
    || { echo "$EXE does not start on its own (status $?): a DLL is missing" >&2; exit 1; }
else
  "$STAGE/$EXE" version >/dev/null
fi
if [[ $OS != windows ]]; then
  mkdir -p "$STAGE/completions"
  "$STAGE/$EXE" completions zsh > "$STAGE/completions/_pimento"
  "$STAGE/$EXE" completions bash > "$STAGE/completions/pimento.bash"
  "$STAGE/$EXE" completions fish > "$STAGE/completions/pimento.fish"
fi
cp LICENSE "$STAGE/LICENSE"

# README.md: the part between the cli-readme markers, under a short header.
{
  echo "# pimento ${VERSION}: Azure PIM from the command line"
  echo
  echo "Command-line tool of Pimento (https://github.com/melvin2306/pimento)."
  case "$OS" in
    macos)
      echo "Copy \`pimento\` to a folder on your PATH, e.g. \`/usr/local/bin\` or \`~/.local/bin\`."
      echo "It is ad-hoc signed, not notarized: if macOS blocks it, run"
      echo "\`xattr -d com.apple.quarantine pimento\`. Shell completions are in \`completions/\`."
      ;;
    linux)
      echo "Copy \`pimento\` to a folder on your PATH, e.g. \`~/.local/bin\` or \`/usr/local/bin\`."
      echo "It needs glibc 2.35 or later (Ubuntu 22.04, Debian 12, RHEL 9) and libcurl."
      echo "Shell completions are in \`completions/\`. Files live in \`~/.config/pimento\`."
      ;;
    windows)
      echo "Keep \`pimento.exe\` and the DLLs next to it together, in a folder on your PATH."
      echo "It needs the Microsoft Visual C++ Redistributable (most systems have it). Files live in \`%APPDATA%\\Pimento\`."
      echo "Browser sign-in is not available on Windows: \`pimento login\` uses a device code."
      ;;
  esac
  echo
  sed -n '/<!-- cli-readme:start -->/,/<!-- cli-readme:end -->/{//!p;}' README.md
} > "$STAGE/README.md"
grep -q "pimento activate" "$STAGE/README.md" || { echo "README excerpt is empty: check the cli-readme markers" >&2; exit 1; }

if [[ $OS == windows ]]; then
  ARCHIVE="build/$NAME.zip"
  powershell.exe -NoProfile -NonInteractive -Command \
    "Compress-Archive -Path '$(cygpath -w "$STAGE")' -DestinationPath '$(cygpath -w "$ARCHIVE")' -Force"
else
  ARCHIVE="build/$NAME.tar.gz"
  # (macOS: no AppleDouble or extended attributes in the archive.)
  if [[ $OS == macos ]]; then
    COPYFILE_DISABLE=1 tar --no-xattrs -czf "$ARCHIVE" -C build "$NAME"
  else
    tar -czf "$ARCHIVE" -C build "$NAME"
  fi
fi
rm -rf "$STAGE"
ARCHS="$ARCH"; [[ $OS == macos ]] && ARCHS="$(lipo -archs "$BIN" 2>/dev/null || echo "?")"
echo "Packed $ARCHIVE ($ARCHS):"
if command -v sha256sum >/dev/null; then sha256sum "$ARCHIVE"; else shasum -a 256 "$ARCHIVE"; fi
