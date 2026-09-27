#!/usr/bin/env bash
# @purpose Renders the website's screenshots from the real app: `Workbench --render-shots` on demo projects.
# @role    Dev tool; builds the debug binary and runs ShotRenderer (Sources/Workbench/App/ShotRenderer.swift).
# @deps    swift, the demo projects under ~/SeperateDemo with real Claude Code / Codex sessions in them
# @gotcha  Never touches the installed Seperate. Runs with a clean environment so nothing from the calling
#          shell (API keys, agent session variables) leaks into the resumed agents. docs/plans/2026-09-27-render-shots.md
# Usage: scripts/render-shots.sh [output dir]   (default build/shots)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${1:-$ROOT/build/shots}"
DEMO="${SEPERATE_SHOTS_ROOT:-$HOME/SeperateDemo}"
[[ -d "$DEMO" ]] || { echo "error: $DEMO missing (demo projects with real agent sessions)" >&2; exit 1; }

cd "$ROOT"
"$ROOT/scripts/build-core.sh" >/dev/null
swift build >/dev/null
BIN="$(swift build --show-bin-path)/Workbench"

DATA="$(mktemp -d)"      # a throwaway Store: layout, workspaces and window state never mix with the real app's
trap 'rm -r "$DATA"' EXIT
mkdir -p "$OUT"
# Clean environment: only what a login shell needs; the terminals' shells load the user's own profile.
env -i HOME="$HOME" USER="$USER" LOGNAME="${LOGNAME:-$USER}" SHELL="${SHELL:-/bin/zsh}" PATH="/usr/bin:/bin:/usr/sbin:/sbin" \
  LANG="${LANG:-en_US.UTF-8}" TMPDIR="${TMPDIR:-/tmp}" \
  SEPERATE_DATA_DIR="$DATA" SEPERATE_SHOTS_ROOT="$DEMO" \
  SHOTS_DEBUG="${SHOTS_DEBUG:-}" SHOTS_PALETTE_QUERY="${SHOTS_PALETTE_QUERY:-}" \
  perl -e 'alarm 300; exec @ARGV' "$BIN" --render-shots "$OUT"
