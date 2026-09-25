#!/usr/bin/env bash
# Local dry run of .github/workflows/release.yml: same steps, same secret names, run on this Mac.
# Secrets are read from .secrets (KEY='value' lines, gitignored; scripts/setup-signing.sh writes it).
# Stops before the GitHub Release: nothing is tagged, uploaded or published.
# Usage: scripts/release-local.sh [version]   (default 0.1.0)
#
# Keep in step with release.yml when either changes.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

step() { printf '\n\033[1m==> %s\033[0m\n' "$1"; }

[[ -f .secrets ]] || { echo "error: .secrets missing — run scripts/setup-signing.sh first" >&2; exit 1; }
set -a; source .secrets; set +a
HAS_CERT=false;   [[ -n "${APPLE_CERTIFICATE:-}" ]] && HAS_CERT=true
HAS_NOTARY=false; [[ -n "${APPLE_ID:-}" && -n "${APPLE_PASSWORD:-}" && -n "${APPLE_TEAM_ID:-}" ]] && HAS_NOTARY=true

WORK="$(mktemp -d)"    # stands in for $RUNNER_TEMP
KEYCHAIN="$WORK/signing.keychain-db"
ORIGINAL_KEYCHAINS=()
cleanup() {
  # Unlike a CI runner, this Mac is kept: put the keychain search list back and drop the temporary keychain.
  if [[ ${#ORIGINAL_KEYCHAINS[@]} -gt 0 ]]; then
    security list-keychains -d user -s "${ORIGINAL_KEYCHAINS[@]}"
    security delete-keychain "$KEYCHAIN" 2>/dev/null || true
  fi
  rm -rf "$WORK"
}
trap cleanup EXIT

# --- step: Version
VERSION="${1:-0.1.0}"; export VERSION="${VERSION#v}"
export BUILD="$(git rev-list --count HEAD)"
step "Version $VERSION ($BUILD)"

# --- step: Import signing certificate (if: HAS_CERT)
if [[ "$HAS_CERT" == true ]]; then
  step "Import signing certificate"
  while IFS= read -r k; do ORIGINAL_KEYCHAINS+=("$(echo "$k" | tr -d ' "')"); done < <(security list-keychains -d user)
  security create-keychain -p "" "$KEYCHAIN"
  security set-keychain-settings -lut 21600 "$KEYCHAIN"
  security unlock-keychain -p "" "$KEYCHAIN"
  printf '%s' "$APPLE_CERTIFICATE" | base64 --decode > "$WORK/cert.p12"
  security import "$WORK/cert.p12" -k "$KEYCHAIN" -P "$APPLE_CERTIFICATE_PASSWORD" -T /usr/bin/codesign >/dev/null
  security set-key-partition-list -S apple-tool:,apple: -s -k "" "$KEYCHAIN" >/dev/null
  security list-keychains -d user -s "$KEYCHAIN" "${ORIGINAL_KEYCHAINS[@]}"
  IDENTITY="$(security find-identity -v -p codesigning "$KEYCHAIN" | grep -m1 'Developer ID Application' | sed -E 's/.*"(.*)"/\1/')"
  echo "$IDENTITY"
  # CI signs by name. This Mac also has the certificate in the login keychain, where the name would be
  # ambiguous, so sign by the identity's hash instead: same certificate, same result.
  export CODESIGN_IDENTITY="$(security find-identity -v -p codesigning "$KEYCHAIN" | grep -m1 'Developer ID Application' | awk '{print $2}')"
fi

# --- step: Build app
step "Build app"
scripts/build-app.sh release

# --- step: Notarize (if: HAS_CERT && HAS_NOTARY)
if [[ "$HAS_CERT" == true && "$HAS_NOTARY" == true ]]; then
  step "Notarize (Apple, usually 1–5 min)"
  ditto -c -k --keepParent build/Seperate.app "$WORK/notarize.zip"
  xcrun notarytool submit "$WORK/notarize.zip" --apple-id "$APPLE_ID" --team-id "$APPLE_TEAM_ID" --password "$APPLE_PASSWORD" --wait
  xcrun stapler staple build/Seperate.app
fi

# --- step: Package
step "Package"
PACKAGE_ONLY=1 scripts/package-dmg.sh

# --- step: Notarize DMG (if: HAS_CERT && HAS_NOTARY)
if [[ "$HAS_CERT" == true && "$HAS_NOTARY" == true ]]; then
  step "Notarize DMG"
  xcrun notarytool submit "build/Seperate-$VERSION.dmg" --apple-id "$APPLE_ID" --team-id "$APPLE_TEAM_ID" --password "$APPLE_PASSWORD" --wait
  xcrun stapler staple "build/Seperate-$VERSION.dmg"
fi

# --- step: Create draft release — skipped locally. Recent commits stand in for GitHub's generated notes.
{ echo "<ul>"; git log -5 --format='<li>%s</li>'; echo "</ul>"; } > "$WORK/notes.html"

# --- step: Sign update and write appcast
step "Sign update and write appcast"
printf '%s' "$SPARKLE_PRIVATE_KEY" > "$WORK/sparkle.key"
scripts/make-appcast.sh "$VERSION" "build/Seperate-$VERSION.zip" "$WORK/sparkle.key" "$WORK/notes.html"
rm -f "$WORK/sparkle.key"

# --- step: Publish release — skipped locally.

# --- local only: what a user's Mac will decide
step "Gatekeeper check"
spctl --assess --type execute -vv build/Seperate.app 2>&1 | sed 's/^/  app: /' || true
spctl --assess --type open --context context:primary-signature -vv "build/Seperate-$VERSION.dmg" 2>&1 | sed 's/^/  dmg: /' || true
if [[ "$HAS_CERT" == true && "$HAS_NOTARY" == true ]]; then echo "  Expect: accepted, source=Notarized Developer ID"; fi

# A copy marked as downloaded from the internet, so opening it goes through the same checks as a real download.
TEST="build/Seperate-$VERSION-as-downloaded.dmg"
cp "build/Seperate-$VERSION.dmg" "$TEST"
xattr -w com.apple.quarantine "0081;$(printf '%x' "$(date +%s)");Safari;" "$TEST"

step "Done"
ls -lh "build/Seperate-$VERSION.dmg" "build/Seperate-$VERSION.zip" build/appcast.xml | awk '{print "  " $5 "  " $9}'
echo "Try it like a user who downloaded it:  open \"$TEST\""
echo "(安装 Seperate installs to /Applications and quits the running Seperate first.)"
