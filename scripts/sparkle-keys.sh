#!/usr/bin/env bash
# One-time setup for signed in-app updates.
# Creates (or reuses) the Sparkle EdDSA key pair in the login Keychain, prints the public key for
# scripts/build-app.sh, and stores the private key as the GitHub secret SPARKLE_PRIVATE_KEY.
# Usage: scripts/sparkle-keys.sh [owner/repo]
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
REPO="${1:-BarrySong97/seperate}"

swift package resolve >/dev/null
BIN="$ROOT/.build/artifacts/sparkle/Sparkle/bin"

"$BIN/generate_keys" --account seperate >/dev/null
echo "Public key (SUPublicEDKey): $("$BIN/generate_keys" --account seperate -p)"

KEY="$(mktemp)"
trap 'rm -f "$KEY"' EXIT
rm -f "$KEY"
"$BIN/generate_keys" --account seperate -x "$KEY"
gh secret set SPARKLE_PRIVATE_KEY --repo "$REPO" < "$KEY"
echo "Stored SPARKLE_PRIVATE_KEY in $REPO"
