#!/usr/bin/env bash
# One-time setup for signed, notarized releases. Asks for the Apple signing details, then:
#   1. checks the Apple ID + app-specific password with Apple and saves them in the login Keychain
#      as the notarytool profile "seperate-notary" (used by scripts/release-local.sh)
#   2. uploads them as GitHub Actions secrets (used by .github/workflows/release.yml)
# Usage: scripts/setup-signing.sh [--local-only] [owner/repo]
set -euo pipefail

LOCAL_ONLY=""
REPO="BarrySong97/seperate"
for arg in "$@"; do
  case "$arg" in
    --local-only) LOCAL_ONLY=1 ;;
    *) REPO="$arg" ;;
  esac
done
PROFILE="seperate-notary"

bold() { printf '\n\033[1m%s\033[0m\n' "$1"; }
ask() {   # ask <var> <prompt> [default]
  local v; read -r -p "$2${3:+ [$3]}: " v; printf -v "$1" '%s' "${v:-${3:-}}"
}
ask_secret() {   # ask_secret <var> <prompt>
  local v; read -r -s -p "$2: " v; echo; printf -v "$1" '%s' "$v"
}

bold "Developer ID certificate"
IDENTITY="$(security find-identity -v -p codesigning | grep -m1 'Developer ID Application' | sed -E 's/.*"(.*)"/\1/' || true)"
if [[ -n "$IDENTITY" ]]; then echo "Found in Keychain: $IDENTITY"; else echo "warning: no Developer ID Application certificate in your Keychain; local signed builds won't work" >&2; fi

if [[ -z "$LOCAL_ONLY" ]]; then
  ask P12 "Path to the exported .p12" "$HOME/Documents/DeveloperID.p12"
  P12="${P12/#\~/$HOME}"
  [[ -f "$P12" ]] || { echo "error: $P12 not found" >&2; exit 1; }
  ask_secret P12_PASSWORD "Password you set when exporting the .p12"
  # Catch a wrong password now instead of in the release build.
  CHECK_KC="$(mktemp -d)/check.keychain-db"
  security create-keychain -p x "$CHECK_KC" >/dev/null
  if ! security import "$P12" -k "$CHECK_KC" -P "$P12_PASSWORD" >/dev/null 2>&1; then
    security delete-keychain "$CHECK_KC"; echo "error: that .p12 password is wrong" >&2; exit 1
  fi
  security delete-keychain "$CHECK_KC"
  echo "✓ .p12 password is correct"
fi

bold "Apple notarization login"
echo "Use the app-specific password from account.apple.com → Sign-In and Security → App-Specific Passwords."
ask APPLE_ID "Apple ID email"
ask_secret APPLE_PASSWORD "App-specific password"
ask APPLE_TEAM_ID "Team ID" "UKPFND4844"

echo "Checking the login with Apple…"
xcrun notarytool store-credentials "$PROFILE" --apple-id "$APPLE_ID" --team-id "$APPLE_TEAM_ID" --password "$APPLE_PASSWORD" --validate >/dev/null
echo "✓ Apple accepted it; saved in Keychain as notarytool profile \"$PROFILE\""

if [[ -z "$LOCAL_ONLY" ]]; then
  bold "GitHub secrets for $REPO"
  base64 -i "$P12" | gh secret set APPLE_CERTIFICATE -R "$REPO"
  printf '%s' "$P12_PASSWORD" | gh secret set APPLE_CERTIFICATE_PASSWORD -R "$REPO"
  printf '%s' "$APPLE_ID" | gh secret set APPLE_ID -R "$REPO"
  printf '%s' "$APPLE_PASSWORD" | gh secret set APPLE_PASSWORD -R "$REPO"
  printf '%s' "$APPLE_TEAM_ID" | gh secret set APPLE_TEAM_ID -R "$REPO"
  gh secret list -R "$REPO"

  ask DELETE "Delete $P12 now that it is uploaded? (y/n)" "y"
  if [[ "$DELETE" == [yY]* ]]; then rm -f "$P12"; echo "Deleted $P12"; fi
fi

bold "Done"
echo "Test a signed build on this Mac: scripts/release-local.sh"
