#!/usr/bin/env bash
# Builds the Rust core and wraps it as Vendor/WorkbenchCore.xcframework for SwiftPM to link.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export PATH="$HOME/.cargo/bin:$PATH"

cd "$ROOT/core"
cargo build --release --quiet
LIB="$ROOT/core/target/release/libworkbench_core.a"

OUT="$ROOT/Vendor/WorkbenchCore.xcframework"
rm -rf "$OUT"
xcodebuild -create-xcframework -library "$LIB" -headers "$ROOT/core/include" -output "$OUT" >/dev/null
echo "$OUT"
