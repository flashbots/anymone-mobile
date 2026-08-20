#!/usr/bin/env bash
# arm64 (and optionally x86_64 emulator) .so into the :core module, plus the
# Kotlin bindings. Needs ANDROID_NDK_HOME and `cargo install cargo-ndk`.
set -euo pipefail

cd "$(dirname "$0")/.."
PROFILE=${PROFILE:-release}
: "${ANDROID_NDK_HOME:?set ANDROID_NDK_HOME to your NDK install}"

TARGETS=(-t arm64-v8a)
[ "${WITH_EMULATOR:-0}" = 1 ] && TARGETS+=(-t x86_64)

rustup target add aarch64-linux-android x86_64-linux-android >/dev/null

CARGO_FLAGS=(-p anymone-ffi)
[ "$PROFILE" = release ] && CARGO_FLAGS+=(--release)

cargo ndk "${TARGETS[@]}" --platform 29 \
  -o android/core/src/main/jniLibs build "${CARGO_FLAGS[@]}"

cargo build "${CARGO_FLAGS[@]}"
HOST_LIB=$(ls "target/$PROFILE"/libanymone_ffi.so "target/$PROFILE"/libanymone_ffi.dylib 2>/dev/null | head -1)

OUT=android/core/src/main/kotlin
rm -rf "$OUT/net" && mkdir -p "$OUT"
cargo run -p anymone-ffi --bin uniffi-bindgen -- generate \
  --library "$HOST_LIB" --language kotlin --out-dir "$OUT" --no-format

echo "built jniLibs and Kotlin bindings under android/core/src/main"
