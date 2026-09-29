#!/usr/bin/env bash
# @purpose Wraps build/Seperate.app into the double-click installer build/Install Seperate.app (“安装 Seperate” in Chinese).
# @role    Called by package-dmg.sh; needs build-app.sh release to have run first.
# @deps    swift (SeperateInstaller product), PlistBuddy, codesign, Resources/Installer/InstallerIcon.icns; env CODESIGN_IDENTITY.
# @gotcha  Version/build are copied from the payload's Info.plist; the payload keeps its own signature (no --deep); see docs/modules/release/README.md
# Wraps build/Seperate.app inside the double-click installer: build/Install Seperate.app
# Run scripts/build-app.sh release first. Env: CODESIGN_IDENTITY (default: ad-hoc "-")
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
IDENTITY="${CODESIGN_IDENTITY:--}"

PAYLOAD="$ROOT/build/Seperate.app"
[[ -d "$PAYLOAD" ]] || { echo "build/Seperate.app missing — run scripts/build-app.sh release first" >&2; exit 1; }
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PAYLOAD/Contents/Info.plist")"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$PAYLOAD/Contents/Info.plist")"

swift build -c release --product SeperateInstaller
BIN="$(swift build -c release --show-bin-path)/SeperateInstaller"

APP="$ROOT/build/Install Seperate.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/SeperateInstaller"
cp "$ROOT/Resources/Installer/InstallerIcon.icns" "$APP/Contents/Resources/InstallerIcon.icns"
ditto "$PAYLOAD" "$APP/Contents/Resources/Seperate.app"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Install Seperate</string>
  <key>CFBundleDisplayName</key><string>Install Seperate</string>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleLocalizations</key><array><string>en</string><string>zh-Hans</string></array>
  <key>LSHasLocalizedDisplayName</key><true/>
  <key>CFBundleIdentifier</key><string>dev.workbench.installer</string>
  <key>CFBundleExecutable</key><string>SeperateInstaller</string>
  <key>CFBundleIconFile</key><string>InstallerIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST

# Finder shows “安装 Seperate” on a Chinese system (LSHasLocalizedDisplayName); the file keeps its English name.
for L in en zh-Hans; do mkdir -p "$APP/Contents/Resources/$L.lproj"; done
echo '"CFBundleDisplayName" = "Install Seperate"; "CFBundleName" = "Install Seperate";' > "$APP/Contents/Resources/en.lproj/InfoPlist.strings"
echo '"CFBundleDisplayName" = "安装 Seperate"; "CFBundleName" = "安装 Seperate";' > "$APP/Contents/Resources/zh-Hans.lproj/InfoPlist.strings"

# The payload keeps its own signature; only the installer's executable and seal are signed here.
if [[ "$IDENTITY" == "-" ]]; then
  codesign --force --sign - "$APP" >/dev/null
else
  codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP" >/dev/null
fi
echo "$APP"
