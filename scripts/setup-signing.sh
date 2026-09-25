#!/usr/bin/env bash
# One-time setup for signed, notarized releases. Asks for the Apple signing details, checks them, and writes
# every release secret to .secrets (gitignored, readable only by you) with the same names GitHub Actions uses:
#   APPLE_CERTIFICATE  APPLE_CERTIFICATE_PASSWORD  APPLE_ID  APPLE_PASSWORD  APPLE_TEAM_ID  SPARKLE_PRIVATE_KEY
# Then uploads .secrets to the repo's Actions secrets, so local test runs (scripts/release-local.sh) and
# the release workflow use identical values.
# Usage: scripts/setup-signing.sh [--local-only] [owner/repo]
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

LOCAL_ONLY=""
REPO="BarrySong97/seperate"
for arg in "$@"; do
  case "$arg" in
    --local-only) LOCAL_ONLY=1 ;;
    *) REPO="$arg" ;;
  esac
done

bold() { printf '\n\033[1m%s\033[0m\n' "$1"; }
ask() {          # ask <var> <prompt> [default]
  local v; read -r -p "$2${3:+ [$3]}: " v; printf -v "$1" '%s' "${v:-${3:-}}"
}
ask_secret() {   # ask_secret <var> <prompt>
  local v; read -r -s -p "$2: " v; echo; printf -v "$1" '%s' "$v"
}

bold "Developer ID certificate (.p12 exported from Keychain Access)"
ask P12 "Path to the .p12" "$HOME/Documents/DeveloperID.p12"
P12="${P12/#\~/$HOME}"
[[ -f "$P12" ]] || { echo "error: $P12 not found" >&2; exit 1; }
ask_secret APPLE_CERTIFICATE_PASSWORD "Password you set when exporting the .p12"
CHECK="$(mktemp -d)"
security create-keychain -p x "$CHECK/check.keychain-db" >/dev/null
if ! security import "$P12" -k "$CHECK/check.keychain-db" -P "$APPLE_CERTIFICATE_PASSWORD" >/dev/null 2>&1; then
  security delete-keychain "$CHECK/check.keychain-db"; echo "error: that .p12 password is wrong" >&2; exit 1
fi
if ! security find-identity -v -p codesigning "$CHECK/check.keychain-db" | grep -q 'Developer ID Application'; then
  security delete-keychain "$CHECK/check.keychain-db"; echo "error: the .p12 has no Developer ID Application certificate with its private key" >&2; exit 1
fi
security delete-keychain "$CHECK/check.keychain-db"; rm -rf "$CHECK"
APPLE_CERTIFICATE="$(base64 -i "$P12" | tr -d '\n')"
echo "✓ Certificate and password OK"

bold "Apple notarization login"
echo "App-specific password: account.apple.com → Sign-In and Security → App-Specific Passwords."
ask APPLE_ID "Apple ID email"
ask_secret APPLE_PASSWORD "App-specific password"
ask APPLE_TEAM_ID "Team ID" "UKPFND4844"
echo "Checking the login with Apple…"
if ! xcrun notarytool history --apple-id "$APPLE_ID" --team-id "$APPLE_TEAM_ID" --password "$APPLE_PASSWORD" >/dev/null 2>&1; then
  echo "error: Apple rejected the Apple ID / app-specific password / team ID" >&2; exit 1
fi
echo "✓ Apple accepted the login"

bold "Sparkle update key"
swift package resolve >/dev/null
SPARKLE_KEY_FILE="$(mktemp)"; rm -f "$SPARKLE_KEY_FILE"
.build/artifacts/sparkle/Sparkle/bin/generate_keys --account seperate -x "$SPARKLE_KEY_FILE"
SPARKLE_PRIVATE_KEY="$(cat "$SPARKLE_KEY_FILE")"; rm -f "$SPARKLE_KEY_FILE"
echo "✓ Read from the login Keychain"

bold "Writing .secrets"
for v in APPLE_CERTIFICATE APPLE_CERTIFICATE_PASSWORD APPLE_ID APPLE_PASSWORD APPLE_TEAM_ID SPARKLE_PRIVATE_KEY; do
  [[ "${!v}" != *"'"* ]] || { echo "error: $v contains a single quote, which .secrets can't hold" >&2; exit 1; }
done
umask 077
{
  echo "# Release secrets, same names as the GitHub Actions secrets. Never commit this file."
  for v in APPLE_CERTIFICATE APPLE_CERTIFICATE_PASSWORD APPLE_ID APPLE_PASSWORD APPLE_TEAM_ID SPARKLE_PRIVATE_KEY; do
    printf "%s='%s'\n" "$v" "${!v}"
  done
} > .secrets
echo "✓ $ROOT/.secrets"

if [[ -z "$LOCAL_ONLY" ]]; then
  bold "Uploading to GitHub Actions secrets ($REPO)"
  gh secret set -f .secrets -R "$REPO"
  gh secret list -R "$REPO"
fi

ask DELETE "Delete $P12 now? It's no longer needed (y/n)" "y"
if [[ "$DELETE" == [yY]* ]]; then rm -f "$P12"; echo "Deleted $P12"; fi

bold "Done"
echo "Test the release workflow on this Mac: scripts/release-local.sh"
