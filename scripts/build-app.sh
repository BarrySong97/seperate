#!/usr/bin/env bash
# Builds the app and wraps the binary in a runnable Seperate.app bundle.
# (The Swift target is still called Workbench; only the product the user sees is named Seperate.)
# Usage: scripts/build-app.sh [debug|release] [--open]
# Env: VERSION (default 0.1.0), BUILD (default: git commit count), CODESIGN_IDENTITY (default: ad-hoc "-")
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="${1:-debug}"
cd "$ROOT"

VERSION="${VERSION:-0.1.0}"
BUILD="${BUILD:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}"
IDENTITY="${CODESIGN_IDENTITY:--}"
# In-app updates: the appcast attached to the latest GitHub Release, verified with this EdDSA key.
# Checks happen at launch and from "检查更新…" only: the scheduled interval is set to a year so
# Sparkle's own timer never fires while the app stays open.
FEED_URL="https://github.com/BarrySong97/seperate/releases/latest/download/appcast.xml"
SPARKLE_PUBLIC_KEY="hBvX/YMu49uiKG3IQMxZ9UFKkA+e0vr6Zjy7SiFw40k="

if [[ ! -d Vendor/GhosttyKit.xcframework ]]; then
  echo "GhosttyKit missing — run scripts/setup-ghostty.sh first" >&2
  exit 1
fi

"$ROOT/scripts/build-core.sh" >/dev/null
swift build -c "$CONFIG"
BIN="$(swift build -c "$CONFIG" --show-bin-path)/Workbench"

APP="$ROOT/build/Seperate.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BIN" "$APP/Contents/MacOS/Seperate"
ditto "$(dirname "$BIN")/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"
install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/MacOS/Seperate"
cp "$(dirname "$BIN")/SeperateHook" "$APP/Contents/MacOS/seperate-hook"
cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
# Ghostty looks for Contents/Resources/{ghostty,terminfo} next to the executable.
cp -R Vendor/ghostty-resources/ghostty "$APP/Contents/Resources/ghostty"
cp -R Vendor/ghostty-resources/terminfo "$APP/Contents/Resources/terminfo"

# Codex logo: OpenAI's asset, taken from the local ChatGPT.app rather than committed to the repo.
CODEX_ICON="/Applications/ChatGPT.app/Contents/Resources/icon-codex-light.png"
if [[ -f "$CODEX_ICON" ]]; then
  sips -z 64 64 "$CODEX_ICON" --out "$APP/Contents/Resources/codex-icon.png" >/dev/null
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Seperate</string>
  <key>CFBundleDisplayName</key><string>Seperate</string>
  <key>CFBundleIdentifier</key><string>dev.workbench.app</string>
  <key>CFBundleExecutable</key><string>Seperate</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>SUFeedURL</key><string>$FEED_URL</string>
  <key>SUPublicEDKey</key><string>$SPARKLE_PUBLIC_KEY</string>
  <key>SUEnableAutomaticChecks</key><true/>
  <key>SUScheduledCheckInterval</key><integer>31536000</integer>
</dict>
</plist>
PLIST

# Ad-hoc by default; Sparkle verifies updates with its EdDSA key, not the Apple signature.
if [[ "$IDENTITY" == "-" ]]; then
  codesign --force --deep --sign - "$APP" >/dev/null
else
  codesign --force --deep --options runtime --timestamp --sign "$IDENTITY" "$APP" >/dev/null
fi
echo "$APP"
if [[ "${2:-}" == "--open" ]]; then open "$APP"; fi
