#!/usr/bin/env bash
# Writes the Sparkle appcast for one release: build/appcast.xml
# Usage: scripts/make-appcast.sh <version> <zip> <private-key-file> [release-notes.html]
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="$1"; ZIP="$2"; KEY="$3"; NOTES="${4:-}"
REPO="${GITHUB_REPOSITORY:-BarrySong97/seperate}"

APP="$ROOT/build/Seperate.app"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist")"
MIN_OS="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$APP/Contents/Info.plist")"
# Prints: sparkle:edSignature="…" length="…"
SIGNATURE="$("$ROOT/.build/artifacts/sparkle/Sparkle/bin/sign_update" --ed-key-file "$KEY" "$ZIP")"
URL="https://github.com/$REPO/releases/download/v$VERSION/$(basename "$ZIP")"
DESCRIPTION=""
if [[ -n "$NOTES" && -s "$NOTES" ]]; then
  DESCRIPTION="<description><![CDATA[$(cat "$NOTES")]]></description>"
fi

cat > "$ROOT/build/appcast.xml" <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Seperate</title>
    <link>https://github.com/$REPO</link>
    <item>
      <title>Seperate $VERSION</title>
      <pubDate>$(LC_ALL=C date -u "+%a, %d %b %Y %H:%M:%S +0000")</pubDate>
      <sparkle:version>$BUILD</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>$MIN_OS</sparkle:minimumSystemVersion>
      <sparkle:fullReleaseNotesLink>https://github.com/$REPO/releases/tag/v$VERSION</sparkle:fullReleaseNotesLink>
      $DESCRIPTION
      <enclosure url="$URL" $SIGNATURE type="application/octet-stream"/>
    </item>
  </channel>
</rss>
XML
echo "$ROOT/build/appcast.xml"
