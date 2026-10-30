#!/usr/bin/env bash
# Packs build/Pimento.app (from scripts/bundle.sh) into a compressed disk image
# for people who just want the app:
#
#   build/Pimento-<version>.dmg   volume "Pimento": Pimento.app and a link to /Applications
#
# The image is built from a folder (hdiutil create -srcfolder), checked with
# `hdiutil verify`, then attached once with -nobrowse -noautoopen (no Finder
# window, not shown on the desktop) to check what is inside, and detached.
#
#   scripts/bundle.sh && scripts/make-dmg.sh
set -euo pipefail

cd "$(dirname "$0")/.."
APP_NAME="Pimento"
VERSION="$(sed -n 's/.*static let version = "\(.*\)".*/\1/p' Sources/PimentoCore/AppInfo.swift)"
APP="build/${APP_NAME}.app"
DMG="build/${APP_NAME}-${VERSION}.dmg"

[[ -n "$VERSION" ]] || { echo "could not read the version from AppInfo.swift" >&2; exit 1; }
[[ -d "$APP" ]] || { echo "$APP is missing: run scripts/bundle.sh first" >&2; exit 1; }
codesign --verify --strict "$APP"
APP_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
[[ "$APP_VERSION" == "$VERSION" ]] || { echo "$APP is $APP_VERSION, AppInfo.swift says $VERSION: run scripts/bundle.sh again" >&2; exit 1; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/pimento-dmg.XXXXXX")"
MOUNT="$WORK/mount"
ATTACHED=""
cleanup() {
  [[ -z "$ATTACHED" ]] || hdiutil detach "$MOUNT" -quiet -force >/dev/null 2>&1 || true
  rm -rf "$WORK"
}
trap cleanup EXIT

# The image's contents: the app (ditto keeps its signature and attributes) and
# a link to /Applications to drag it onto.
mkdir -p "$WORK/src"
ditto "$APP" "$WORK/src/${APP_NAME}.app"
ln -s /Applications "$WORK/src/Applications"

# ULFO (LZFSE) needs macOS 10.11 or later; the app needs macOS 14.
rm -f "$DMG"
hdiutil create -quiet -volname "$APP_NAME" -srcfolder "$WORK/src" -fs HFS+ -format ULFO -ov "$DMG"

# Ad-hoc signature on the image, like the app's (not notarized, no Developer ID).
codesign --force --sign - --identifier "io.github.melvin2306.pimento.dmg" "$DMG" >/dev/null 2>&1 || echo "note: could not sign $DMG ad hoc; it is left unsigned" >&2

hdiutil verify -quiet "$DMG"

# Look inside once, without Finder.
mkdir -p "$MOUNT"
hdiutil attach "$DMG" -nobrowse -noautoopen -readonly -noverify -quiet -mountpoint "$MOUNT"
ATTACHED=1
[[ -x "$MOUNT/${APP_NAME}.app/Contents/MacOS/${APP_NAME}" ]] || { echo "the image has no ${APP_NAME}.app" >&2; exit 1; }
[[ "$(readlink "$MOUNT/Applications")" == "/Applications" ]] || { echo "the image has no Applications link" >&2; exit 1; }
codesign --verify --strict "$MOUNT/${APP_NAME}.app"
"$MOUNT/${APP_NAME}.app/Contents/Helpers/pimento" version >/dev/null
# (Right after use the volume can be busy for a moment, e.g. while Spotlight looks at it.)
for _ in 1 2 3 4 5; do
  hdiutil detach "$MOUNT" -quiet 2>/dev/null && ATTACHED="" && break
  sleep 1
done
[[ -z "$ATTACHED" ]] || { hdiutil detach "$MOUNT" -quiet -force; ATTACHED=""; }

echo "Packed $DMG ($(du -h "$DMG" | cut -f1 | tr -d ' ')):"
shasum -a 256 "$DMG"
