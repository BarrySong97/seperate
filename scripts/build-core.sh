#!/usr/bin/env bash
# @purpose Builds the Rust core (cargo --release) into Vendor/WorkbenchCore.xcframework for SwiftPM.
# @role    Dev before `swift test`/`swift build`, build-app.sh, CI ci.yml Test step.
# @deps    cargo (~/.cargo/bin), xcodebuild, core/include headers.
# @gotcha  Plain `swift build` fails without this output since Vendor/ is gitignored; see docs/modules/release/README.md
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
