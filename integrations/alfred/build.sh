#!/bin/sh
# Packs the workflow's source files into build/Pimento.alfredworkflow (a zip),
# with the app icon as icon.png and the version from AppInfo.swift. Opening
# that file installs it in Alfred.
#
#   integrations/alfred/build.sh
set -eu

here=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
root=$(CDPATH='' cd -- "$here/../.." && pwd)
version=$(sed -n 's/.*static let version = "\(.*\)".*/\1/p' "$root/Sources/PimentoCore/AppInfo.swift")
[ -n "$version" ] || {
  echo "could not read the version from AppInfo.swift" >&2
  exit 1
}
out="$root/build/Pimento.alfredworkflow"

stage=$(mktemp -d "${TMPDIR:-/tmp}/pimento-alfred-build.XXXXXX")
trap 'rm -rf "$stage"' EXIT INT TERM

cp "$here/info.plist" "$here/alfred.js" "$here/lib.sh" "$here/scriptfilter.sh" "$here/action.sh" "$stage/"
cp "$root/Assets/AppIcon.iconset/icon_256x256.png" "$stage/icon.png"
chmod 755 "$stage/scriptfilter.sh" "$stage/action.sh"
chmod 644 "$stage/info.plist" "$stage/alfred.js" "$stage/lib.sh" "$stage/icon.png"
plutil -replace version -string "$version" "$stage/info.plist"
plutil -lint "$stage/info.plist" >/dev/null

mkdir -p "$root/build"
rm -f "$out"
# -X: no extended attributes or resource forks; Unix permissions are kept (the scripts stay executable).
(cd "$stage" && zip -q -X -r "$out" .)
echo "$out ($version)"
