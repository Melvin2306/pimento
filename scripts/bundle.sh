#!/usr/bin/env bash
# Builds release binaries and wraps them into "build/Pimento.app" (ad-hoc signed):
#   Contents/MacOS/Pimento        the app
#   Contents/Helpers/pimento      the command-line tool (Pimento › Install Command Line Tool…)
# Universal (Apple silicon and Intel) unless --host-arch is given.
#   scripts/bundle.sh              # build the .app
#   scripts/bundle.sh --install    # ...and move it to ~/Applications
#   scripts/bundle.sh --zip        # ...and zip it to build/Pimento-<version>.zip
#   scripts/bundle.sh --host-arch  # only this Mac's architecture (faster); combines with the others
set -euo pipefail

cd "$(dirname "$0")/.."
APP_NAME="Pimento"
APP_PRODUCT="PimentoApp"   # SwiftPM product of the app; installed as Contents/MacOS/Pimento
CLI_PRODUCT="pimento"      # the command-line tool; installed as Contents/Helpers/pimento
EXECUTABLE="$APP_NAME"
BUNDLE_ID="io.github.melvin2306.pimento"
VERSION="$(sed -n 's/.*static let version = "\(.*\)".*/\1/p' Sources/PimentoCore/AppInfo.swift)"
BUILD_NUMBER="$(git rev-list --count HEAD 2>/dev/null || echo 1)"
APP="build/${APP_NAME}.app"

[[ -n "$VERSION" ]] || { echo "could not read the version from AppInfo.swift" >&2; exit 1; }
[[ -f Assets/AppIcon.icns && -f Assets/MenuBarIcon.png ]] || { echo "Assets/AppIcon.icns or MenuBarIcon.png missing; run: swift scripts/make-icon.swift" >&2; exit 1; }

ACTION=""
BUILD_FLAGS=(--arch arm64 --arch x86_64)
for arg in "$@"; do
  case "$arg" in
    --host-arch) BUILD_FLAGS=() ;;
    --install|--zip) [[ -z "$ACTION" ]] || { echo "use either --install or --zip" >&2; exit 64; }; ACTION="$arg" ;;
    *) echo "unknown option: $arg" >&2; exit 64 ;;
  esac
done

# (bash 3.2 treats an empty array as unset under `set -u`, hence the ${…+…}.)
swift build -c release --product "$APP_PRODUCT" ${BUILD_FLAGS[@]+"${BUILD_FLAGS[@]}"}
swift build -c release --product "$CLI_PRODUCT" ${BUILD_FLAGS[@]+"${BUILD_FLAGS[@]}"}
BIN_DIR="$(swift build -c release ${BUILD_FLAGS[@]+"${BUILD_FLAGS[@]}"} --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Helpers" "$APP/Contents/Resources"
cp "$BIN_DIR/$APP_PRODUCT" "$APP/Contents/MacOS/$EXECUTABLE"
cp "$BIN_DIR/$CLI_PRODUCT" "$APP/Contents/Helpers/$CLI_PRODUCT"
cp Assets/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
# The menu bar glyph (template image), from scripts/make-icon.swift.
cp Assets/MenuBarIcon.png Assets/MenuBarIcon@2x.png "$APP/Contents/Resources/"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>${APP_NAME}</string>
  <key>CFBundleDisplayName</key><string>${APP_NAME}</string>
  <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
  <key>CFBundleExecutable</key><string>${EXECUTABLE}</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${BUILD_NUMBER}</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
  <key>NSHumanReadableCopyright</key><string>Copyright © 2026 Melvin Rinkleff. MIT License.</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSSupportsAutomaticTermination</key><false/>
</dict>
</plist>
PLIST
plutil -lint "$APP/Contents/Info.plist" >/dev/null

# Ad-hoc signatures so Gatekeeper treats it as a locally built app. Not
# notarized. Nested code first, then the bundle that seals it.
codesign --force --sign - --identifier "${BUNDLE_ID}.cli" "$APP/Contents/Helpers/$CLI_PRODUCT" >/dev/null 2>&1
codesign --force --sign - "$APP" >/dev/null 2>&1
codesign --verify --strict "$APP"
"$APP/Contents/Helpers/$CLI_PRODUCT" version >/dev/null
echo "Built $APP ($VERSION, build $BUILD_NUMBER, $(lipo -archs "$APP/Contents/MacOS/$EXECUTABLE"))"

case "$ACTION" in
  --install)
    mkdir -p "$HOME/Applications"
    rm -rf "$HOME/Applications/${APP_NAME}.app"
    cp -R "$APP" "$HOME/Applications/"
    # One registered copy per bundle ID: with build/ and ~/Applications both
    # known to LaunchServices, notifications can go to the wrong one. The
    # build/ copy is removed too, or LaunchServices finds it again.
    LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
    [[ -x "$LSREGISTER" ]] && { "$LSREGISTER" -u "$PWD/$APP" >/dev/null 2>&1 || true; }
    rm -rf "$APP"
    [[ -x "$LSREGISTER" ]] && { "$LSREGISTER" -f "$HOME/Applications/${APP_NAME}.app" >/dev/null 2>&1 || true; }
    echo "Installed to ~/Applications/${APP_NAME}.app (the build/ copy is removed)"
    ;;
  --zip)
    ZIP="build/${APP_NAME}-${VERSION}.zip"
    rm -f "$ZIP"
    ditto -c -k --keepParent "$APP" "$ZIP"
    echo "Packed $ZIP"
    ;;
  "") ;;
esac
