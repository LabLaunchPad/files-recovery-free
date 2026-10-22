#!/usr/bin/env bash
# build_ios_engine.sh — cross-compile the Rust engine for iOS and stage the
# device-slice static archive where the Runner app links it.
#
#   scripts/build_ios_engine.sh [--skip-device] [--skip-sim]
#
# Produces:
#   ios/Engine/librecovery_core_ffi.a            (arm64 device slice — LINKED INTO THE APP)
#   build/ios-engine/recovery_core_ffi.xcframework (device + simulator, optional)
#
# The app links the device slice via -force_load (ios/Flutter/*.xcconfig);
# DynamicLibrary.process() then resolves the frf_* symbols inside the
# Runner binary. Requires: rustup target aarch64-apple-ios (+ -sim),
# Xcode xcodebuild. macOS only.
set -euo pipefail
cd "$(dirname "$0")/../.."

RUST_DIR="rust"
OUT_A="ios/Engine/librecovery_core_ffi.a"
XCF_DIR="build/ios-engine"
SKIP_DEVICE="${1:-}"
SKIP_SIM="${2:-}"

command -v cargo >/dev/null || { echo "cargo not on PATH" >&2; exit 1; }

echo "== building device slice (aarch64-apple-ios) =="
if [ "$SKIP_DEVICE" != "--skip-device" ]; then
  cargo build --manifest-path "$RUST_DIR/Cargo.toml" --release -p recovery-ffi --target aarch64-apple-ios
fi
DEV_A="$RUST_DIR/target/aarch64-apple-ios/release/librecovery_core_ffi.a"
[ -f "$DEV_A" ] || { echo "missing device slice: $DEV_A" >&2; exit 1; }

mkdir -p ios/Engine
cp "$DEV_A" "$OUT_A"
echo "staged $OUT_A ($(du -h "$OUT_A" | cut -f1))"

echo "== simulator slice + xcframework (optional) =="
if [ "$SKIP_SIM" != "--skip-sim" ]; then
  SIM_A="$RUST_DIR/target/aarch64-apple-ios-sim/release/librecovery_core_ffi.a"
  if [ ! -f "$SIM_A" ]; then
    cargo build --manifest-path "$RUST_DIR/Cargo.toml" --release -p recovery-ffi --target aarch64-apple-ios-sim
  fi
  mkdir -p "$XCF_DIR"
  xcodebuild -create-xcframework \
    -library "$DEV_A" \
    -library "$SIM_A" \
    -output "$XCF_DIR/recovery_core_ffi.xcframework" >/dev/null
  echo "xcframework at $XCF_DIR/recovery_core_ffi.xcframework"
fi

echo "== verify device slice symbols =="
nm -gU "$OUT_A" | grep -c " _frf_" | xargs -I{} echo "{} exported frf_ symbols"
nm "$OUT_A" | grep -q "_frf_version" || { echo "frf_version missing!" >&2; exit 1; }
echo "OK: engine archive staged and symbols verified."
