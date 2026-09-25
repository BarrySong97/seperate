#!/usr/bin/env bash
# Builds a release Seperate.app and packages it for distribution:
#   build/Seperate-<version>.dmg  drag-to-install image for new users
#   build/Seperate-<version>.zip  archive Sparkle downloads for in-app updates
# Env: VERSION, BUILD, CODESIGN_IDENTITY (see build-app.sh); PACKAGE_ONLY=1 packages the existing build/Seperate.app
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

if [[ -z "${PACKAGE_ONLY:-}" ]]; then "$ROOT/scripts/build-app.sh" release >/dev/null; fi
APP="$ROOT/build/Seperate.app"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
DMG="$ROOT/build/Seperate-$VERSION.dmg"
ZIP="$ROOT/build/Seperate-$VERSION.zip"

rm -f "$ZIP"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

rm -f "$DMG"
hdiutil create -volname "Seperate $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG" >/dev/null
echo "$DMG"
echo "$ZIP"
