#!/usr/bin/env bash
# Builds GhosttyKit.xcframework (libghostty) from upstream Ghostty for the app to link.
# Everything is kept inside the repo: toolchain in .deps/, output in Vendor/ (both gitignored).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEPS="$ROOT/.deps"
VENDOR="$ROOT/Vendor"

# Ghostty main pinned to a commit: v1.3.x needs Zig 0.15, which cannot link against the macOS 26 SDK.
GHOSTTY_COMMIT="4ae9f1a2de5484de3d6a13fe03676b8853b9c41c"
ZIG_VERSION="0.16.0"
ZIG_SHA256="b23d70deaa879b5c2d486ed3316f7eaa53e84acf6fc9cc747de152450d401489"
ZIG_DIR="$DEPS/zig-aarch64-macos-$ZIG_VERSION"

mkdir -p "$DEPS" "$VENDOR"

if [[ "$(uname -m)" != "arm64" ]]; then
  echo "error: this script currently supports Apple Silicon only" >&2
  exit 1
fi

# 1. Zig toolchain pinned to what the Ghostty tag requires.
if [[ ! -x "$ZIG_DIR/zig" ]]; then
  echo "==> Downloading Zig $ZIG_VERSION"
  tarball="$DEPS/zig-$ZIG_VERSION.tar.xz"
  curl -fL --progress-bar "https://ziglang.org/download/$ZIG_VERSION/zig-aarch64-macos-$ZIG_VERSION.tar.xz" -o "$tarball"
  echo "$ZIG_SHA256  $tarball" | shasum -a 256 -c -
  tar -xJf "$tarball" -C "$DEPS"
  rm "$tarball"
fi
export PATH="$ZIG_DIR:$PATH"

# 2. Ghostty source at a pinned commit.
if [[ ! -d "$DEPS/ghostty/.git" ]]; then
  git init -q "$DEPS/ghostty"
  git -C "$DEPS/ghostty" remote add origin https://github.com/ghostty-org/ghostty.git
fi
if [[ "$(git -C "$DEPS/ghostty" rev-parse HEAD 2>/dev/null)" != "$GHOSTTY_COMMIT" ]]; then
  echo "==> Fetching Ghostty $GHOSTTY_COMMIT"
  git -C "$DEPS/ghostty" fetch -q --depth 1 origin "$GHOSTTY_COMMIT"
  git -C "$DEPS/ghostty" checkout -q --force FETCH_HEAD
fi

# 3. Build the macOS-only xcframework plus runtime resources (terminfo, shell integration).
echo "==> Building GhosttyKit (this takes a few minutes the first time)"
cd "$DEPS/ghostty"
# Zig's package fetcher gets "400 Bad Request" through a local HTTP proxy; fetch directly.
unset http_proxy https_proxy all_proxy socks5_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY
zig build --fetch
zig build \
  -Doptimize=ReleaseFast \
  -Demit-xcframework=true \
  -Demit-macos-app=false \
  -Dxcframework-target=native

rm -rf "$VENDOR/GhosttyKit.xcframework" "$VENDOR/ghostty-resources"
cp -R macos/GhosttyKit.xcframework "$VENDOR/"
mkdir -p "$VENDOR/ghostty-resources"
cp -R zig-out/share/ghostty "$VENDOR/ghostty-resources/ghostty"
cp -R zig-out/share/terminfo "$VENDOR/ghostty-resources/terminfo"

echo "==> Done: $VENDOR/GhosttyKit.xcframework"
