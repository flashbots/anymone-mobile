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

# Cleaned first: cargo emits hash-suffixed .so names, so stale ones would keep
# accumulating and get packaged alongside the current build.
rm -rf android/core/src/main/jniLibs
cargo ndk "${TARGETS[@]}" --platform 29 \
  -o android/core/src/main/jniLibs build "${CARGO_FLAGS[@]}"

cargo build "${CARGO_FLAGS[@]}"
for candidate in "target/$PROFILE"/libanymone_ffi.{so,dylib}; do
  [ -f "$candidate" ] && HOST_LIB=$candidate && break
done
: "${HOST_LIB:?no host library under target/$PROFILE}"

OUT=android/core/src/main/kotlin
rm -rf "$OUT/net" && mkdir -p "$OUT"
cargo run -p anymone-ffi --bin uniffi-bindgen -- generate \
  --library "$HOST_LIB" --language kotlin --out-dir "$OUT" --no-format

echo "built jniLibs and Kotlin bindings under android/core/src/main"
