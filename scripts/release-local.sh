#!/usr/bin/env bash
# Builds the same signed + notarized DMG as the GitHub release workflow, on this Mac, without a tag.
# Needs the Developer ID certificate in the Keychain and the "seperate-notary" profile from scripts/setup-signing.sh.
# Usage: scripts/release-local.sh [version] [--skip-notarize]
#   --skip-notarize  sign only (no upload to Apple): quick check that signing works and the app runs
# Output: build/Seperate-<version>.dmg and .zip, then a Gatekeeper check of both.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

VERSION="0.1.0"
NOTARIZE=1
for arg in "$@"; do
  case "$arg" in
    --skip-notarize) NOTARIZE="" ;;
    *) VERSION="${arg#v}" ;;
  esac
done
PROFILE="seperate-notary"

export VERSION
export CODESIGN_IDENTITY="${CODESIGN_IDENTITY:-$(security find-identity -v -p codesigning | grep -m1 'Developer ID Application' | sed -E 's/.*"(.*)"/\1/' || true)}"
[[ -n "$CODESIGN_IDENTITY" ]] || { echo "error: no Developer ID Application certificate in the Keychain" >&2; exit 1; }
if [[ -n "$NOTARIZE" ]] && ! xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1; then
  echo "error: notarytool profile \"$PROFILE\" missing — run scripts/setup-signing.sh --local-only (or pass --skip-notarize)" >&2
  exit 1
fi

step() { printf '\n\033[1m==> %s\033[0m\n' "$1"; }
notarize() {   # notarize <file to submit> <file to staple>
  xcrun notarytool submit "$1" --keychain-profile "$PROFILE" --wait
  xcrun stapler staple "$2"
}

step "Build Seperate $VERSION, signed as: $CODESIGN_IDENTITY"
echo "(macOS may ask to let codesign use the key: choose Always Allow)"
scripts/build-app.sh release >/dev/null

if [[ -n "$NOTARIZE" ]]; then
  step "Notarize the app (uploads to Apple, usually 1–5 minutes)"
  ditto -c -k --keepParent build/Seperate.app build/notarize.zip
  notarize build/notarize.zip build/Seperate.app
  rm -f build/notarize.zip
fi

step "Package installer + DMG"
PACKAGE_ONLY=1 scripts/package-dmg.sh >/dev/null
DMG="build/Seperate-$VERSION.dmg"

if [[ -n "$NOTARIZE" ]]; then
  step "Notarize the DMG"
  notarize "$DMG" "$DMG"
fi

step "Gatekeeper check (what a user's Mac decides)"
spctl --assess --type execute -vv build/Seperate.app 2>&1 | sed 's/^/  app: /' || true
spctl --assess --type open --context context:primary-signature -vv "$DMG" 2>&1 | sed 's/^/  dmg: /' || true
if [[ -n "$NOTARIZE" ]]; then
  echo "  Both should say \"accepted\" and \"source=Notarized Developer ID\"."
else
  echo "  Without notarization Gatekeeper rejects them (\"Unnotarized Developer ID\"); that is expected with --skip-notarize."
fi

# Mark a copy as downloaded from the internet so opening it goes through the same checks as a real download.
TEST="build/Seperate-$VERSION-as-downloaded.dmg"
cp "$DMG" "$TEST"
xattr -w com.apple.quarantine "0081;$(printf '%x' "$(date +%s)");Safari;" "$TEST"

step "Done"
echo "  $ROOT/$DMG"
echo "To try it like a user who downloaded it:  open \"$TEST\""
echo "Double-clicking 安装 Seperate there installs to /Applications and quits the running Seperate first."
