#!/usr/bin/env bash
# Wraps build/Seperate.app inside the double-click installer: build/安装 Seperate.app
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

APP="$ROOT/build/安装 Seperate.app"
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
  <key>CFBundleName</key><string>安装 Seperate</string>
  <key>CFBundleDisplayName</key><string>安装 Seperate</string>
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

# The payload keeps its own signature; only the installer's executable and seal are signed here.
if [[ "$IDENTITY" == "-" ]]; then
  codesign --force --sign - "$APP" >/dev/null
else
  codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP" >/dev/null
fi
echo "$APP"
