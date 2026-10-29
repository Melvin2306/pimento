#!/usr/bin/env bash
# Builds a release binary and wraps it into "build/Pimento.app" (ad-hoc signed).
#   scripts/bundle.sh            # build the .app
#   scripts/bundle.sh --install  # ...and copy it to ~/Applications
#   scripts/bundle.sh --zip      # ...and zip it to build/Pimento-<version>.zip
set -euo pipefail

cd "$(dirname "$0")/.."
APP_NAME="Pimento"
EXECUTABLE="pimento"
BUNDLE_ID="io.github.melvin2306.pimento"
VERSION="$(sed -n 's/.*static let version = "\(.*\)".*/\1/p' Sources/PimentoCore/AppInfo.swift)"
BUILD_NUMBER="$(git rev-list --count HEAD 2>/dev/null || echo 1)"
APP="build/${APP_NAME}.app"

[[ -n "$VERSION" ]] || { echo "could not read the version from AppInfo.swift" >&2; exit 1; }
[[ -f Assets/AppIcon.icns ]] || { echo "Assets/AppIcon.icns missing; run: swift scripts/make-icon.swift" >&2; exit 1; }

swift build -c release --product "$EXECUTABLE"
BIN="$(swift build -c release --show-bin-path)/$EXECUTABLE"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$EXECUTABLE"
cp Assets/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

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

# Ad-hoc signature so Gatekeeper treats it as a locally built app. Not notarized.
codesign --force --deep --sign - "$APP" >/dev/null
echo "Built $APP ($VERSION, build $BUILD_NUMBER)"

case "${1:-}" in
  --install)
    mkdir -p "$HOME/Applications"
    rm -rf "$HOME/Applications/${APP_NAME}.app"
    cp -R "$APP" "$HOME/Applications/"
    echo "Installed to ~/Applications/${APP_NAME}.app"
    ;;
  --zip)
    ZIP="build/${APP_NAME}-${VERSION}.zip"
    rm -f "$ZIP"
    ditto -c -k --keepParent "$APP" "$ZIP"
    echo "Packed $ZIP"
    ;;
  "") ;;
  *) echo "unknown option: $1" >&2; exit 64 ;;
esac
