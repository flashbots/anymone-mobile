#!/usr/bin/env bash
# arm64 (and optionally x86_64 emulator) .so into the :core module, plus the
# Kotlin bindings. Needs ANDROID_NDK_HOME and `cargo install cargo-ndk`.
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT=$PWD
ANYMONE_DIR=${ANYMONE_DIR:-../anymone}
ANYMONE_MANIFEST=${ANYMONE_MANIFEST:-$ANYMONE_DIR/Cargo.toml}
BENCH_MANIFEST=${BENCH_MANIFEST:-$ROOT/crates/anymone-bench/Cargo.toml}
export CARGO_TARGET_DIR=${CARGO_TARGET_DIR:-$ROOT/target}
export CARGO_PROFILE_RELEASE_LTO=${CARGO_PROFILE_RELEASE_LTO:-thin}
PROFILE=${PROFILE:-release}
: "${ANDROID_NDK_HOME:?set ANDROID_NDK_HOME to your NDK install}"

TARGETS=(-t arm64-v8a)
[ "${WITH_EMULATOR:-0}" = 1 ] && TARGETS+=(-t x86_64)

rustup target add aarch64-linux-android x86_64-linux-android >/dev/null

CARGO_FLAGS=(--manifest-path "$ANYMONE_MANIFEST" -p anymone-ffi)
[ "$PROFILE" = release ] && CARGO_FLAGS+=(--release)
BENCH_FLAGS=(--manifest-path "$BENCH_MANIFEST")
[ "$PROFILE" = release ] && BENCH_FLAGS+=(--release)

# Cleaned first: cargo emits hash-suffixed .so names, so stale ones would keep
# accumulating and get packaged alongside the current build.
rm -rf android/core/src/main/jniLibs
cargo ndk "${TARGETS[@]}" --platform 29 \
  -o android/core/src/main/jniLibs build "${CARGO_FLAGS[@]}"
cargo ndk "${TARGETS[@]}" --platform 29 \
  -o android/core/src/main/jniLibs build "${BENCH_FLAGS[@]}"

cargo build "${CARGO_FLAGS[@]}"
cargo build "${BENCH_FLAGS[@]}"
for candidate in "target/$PROFILE"/libanymone_ffi.{so,dylib}; do
  [ -f "$candidate" ] && HOST_LIB=$candidate && break
done
: "${HOST_LIB:?no host library under target/$PROFILE}"
for candidate in "target/$PROFILE"/libanymone_bench.{so,dylib}; do
  [ -f "$candidate" ] && BENCH_HOST_LIB=$candidate && break
done
: "${BENCH_HOST_LIB:?no benchmark host library under target/$PROFILE}"

OUT=android/core/src/main/kotlin
rm -rf "$OUT/net" && mkdir -p "$OUT"
cargo run --manifest-path tools/uniffi-bindgen/Cargo.toml -- generate \
  --library "$HOST_LIB" --language kotlin --out-dir "$OUT" --no-format \
  --config "$ANYMONE_DIR/crates/anymone-ffi/uniffi.toml"
cargo run --manifest-path tools/uniffi-bindgen/Cargo.toml -- generate \
  --library "$BENCH_HOST_LIB" --language kotlin --out-dir "$OUT" --no-format \
  --config crates/anymone-bench/uniffi.toml

echo "built jniLibs and Kotlin bindings under android/core/src/main"
