#!/usr/bin/env bash
# @purpose Produces build/Seperate-<version>.dmg (styled, with installer) and the Sparkle update .zip.
# @role    Dev, CI ci.yml Package step, release.yml / release-local.sh (with PACKAGE_ONLY=1).
# @deps    build-app.sh, build-installer.sh, dmgbuild in .deps/dmgbuild venv (python3), tiffutil, codesign; env VERSION, BUILD, CODESIGN_IDENTITY, PACKAGE_ONLY.
# @gotcha  Ad-hoc builds use the -unsigned background (Gatekeeper hint); PACKAGE_ONLY=1 reuses the already signed/notarized build/Seperate.app instead of rebuilding it; see docs/modules/release/README.md
# Builds a release Seperate.app and packages it for distribution:
#   build/Seperate-<version>.dmg  styled DMG with the double-click installer (安装 Seperate.app)
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

INSTALLER="$("$ROOT/scripts/build-installer.sh" | tail -1)"

# dmgbuild writes the Finder layout directly, so no AppleScript or Finder automation is needed.
VENV="$ROOT/.deps/dmgbuild"
if [[ ! -x "$VENV/bin/dmgbuild" ]]; then
  python3 -m venv "$VENV"
  "$VENV/bin/pip" install --quiet "dmgbuild==1.6.7"
fi
BG="$ROOT/build/dmg-background.tiff"
VARIANT=""; [[ "${CODESIGN_IDENTITY:--}" == "-" ]] && VARIANT="-unsigned"   # unsigned: footer explains Gatekeeper
tiffutil -cathidpicheck "$ROOT/Resources/Installer/dmg-background$VARIANT.png" "$ROOT/Resources/Installer/dmg-background$VARIANT@2x.png" -out "$BG" 2>/dev/null

rm -f "$DMG"
"$VENV/bin/dmgbuild" -s "$ROOT/scripts/dmg-settings.py" -D installer="$INSTALLER" -D background="$BG" "Seperate $VERSION" "$DMG" >/dev/null
if [[ "${CODESIGN_IDENTITY:--}" != "-" ]]; then
  codesign --force --timestamp --sign "$CODESIGN_IDENTITY" "$DMG"
fi
echo "$DMG"
echo "$ZIP"
