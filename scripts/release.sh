#!/usr/bin/env bash
# Starts a release: tags v<version> on the current commit and pushes the tag.
# GitHub Actions (.github/workflows/release.yml) then builds, signs and publishes it.
# Usage: scripts/release.sh 0.2.0
set -euo pipefail
VERSION="${1:?usage: scripts/release.sh <version, e.g. 0.2.0>}"
VERSION="${VERSION#v}"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "error: version must look like 1.2.3" >&2; exit 1; }
cd "$(dirname "$0")/.."

[[ -z "$(git status --porcelain)" ]] || { echo "error: commit or stash your changes first" >&2; exit 1; }
git fetch --tags --quiet
git rev-parse -q --verify "refs/tags/v$VERSION" >/dev/null && { echo "error: v$VERSION already exists" >&2; exit 1; }

git push origin HEAD
git tag -a "v$VERSION" -m "Seperate $VERSION"
git push origin "v$VERSION"
echo "Tagged v$VERSION. Follow the build with: gh run watch"
