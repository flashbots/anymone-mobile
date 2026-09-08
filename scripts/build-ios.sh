#!/usr/bin/env bash
# One staticlib per $TARGETS -> AnymoneFFI.xcframework, plus the Swift bindings.
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT=$PWD
ANYMONE_DIR=${ANYMONE_DIR:-../anymone}
ANYMONE_MANIFEST=${ANYMONE_MANIFEST:-$ANYMONE_DIR/Cargo.toml}
BENCH_MANIFEST=${BENCH_MANIFEST:-$ROOT/crates/anymone-bench/Cargo.toml}
export CARGO_TARGET_DIR=${CARGO_TARGET_DIR:-$ROOT/target}
export CARGO_PROFILE_RELEASE_LTO=${CARGO_PROFILE_RELEASE_LTO:-thin}
PROFILE=${PROFILE:-release}
TARGETS=${TARGETS:-"aarch64-apple-ios aarch64-apple-ios-sim"}
CARGO_FLAGS=(--manifest-path "$ANYMONE_MANIFEST" -p anymone-ffi)
[ "$PROFILE" = release ] && CARGO_FLAGS+=(--release)
BENCH_FLAGS=(--manifest-path "$BENCH_MANIFEST")
[ "$PROFILE" = release ] && BENCH_FLAGS+=(--release)

rustup target add $TARGETS >/dev/null

for target in $TARGETS; do
  cargo build "${CARGO_FLAGS[@]}" --target "$target"
  cargo build "${BENCH_FLAGS[@]}" --target "$target"
done
# Host build only so uniffi-bindgen can read the metadata out of a loadable dylib.
# Unoptimized: nothing runs it, the bindings only need its metadata.
cargo build --manifest-path "$ANYMONE_MANIFEST" -p anymone-ffi
cargo build --manifest-path "$BENCH_MANIFEST"

for candidate in target/debug/libanymone_ffi.{dylib,so}; do
  [ -f "$candidate" ] && HOST_LIB=$candidate && break
done
: "${HOST_LIB:?no host library under target/debug}"
: "${BENCH_HOST_LIB:=$(find target/debug -maxdepth 1 \( -name 'libanymone_bench.dylib' -o -name 'libanymone_bench.so' \) -print -quit)}"
: "${BENCH_HOST_LIB:?no benchmark host library under target/debug}"
rm -rf gen/swift
rm -rf gen/swift-bench
cargo run --manifest-path tools/uniffi-bindgen/Cargo.toml -- generate \
  --library "$HOST_LIB" --language swift --out-dir gen/swift --no-format \
  --config "$ANYMONE_DIR/crates/anymone-ffi/uniffi.toml"
cargo run --manifest-path tools/uniffi-bindgen/Cargo.toml -- generate \
  --library "$BENCH_HOST_LIB" --language swift --out-dir gen/swift-bench --no-format \
  --config crates/anymone-bench/uniffi.toml

# Xcode wants `module.modulemap`; uniffi emits `<name>FFI.modulemap`.
HEADERS=gen/swift/headers
rm -rf "$HEADERS" && mkdir -p "$HEADERS"
cp gen/swift/*.h "$HEADERS"/
cat gen/swift/*.modulemap > "$HEADERS/module.modulemap"

BENCH_HEADERS=gen/swift-bench/headers
rm -rf "$BENCH_HEADERS" && mkdir -p "$BENCH_HEADERS"
cp gen/swift-bench/*.h "$BENCH_HEADERS"/
cat gen/swift-bench/*.modulemap > "$BENCH_HEADERS/module.modulemap"

OUT=ios/AnymoneKit/AnymoneFFI.xcframework
BENCH_OUT=ios/AnymoneKit/AnymoneBenchFFI.xcframework
rm -rf "$OUT"
rm -rf "$BENCH_OUT"
SLICES=()
BENCH_SLICES=()
for target in $TARGETS; do
  SLICES+=(-library "target/$target/$PROFILE/libanymone_ffi.a" -headers "$HEADERS")
  BENCH_SLICES+=(-library "target/$target/$PROFILE/libanymone_bench.a" -headers "$BENCH_HEADERS")
done
xcodebuild -create-xcframework "${SLICES[@]}" -output "$OUT"
xcodebuild -create-xcframework "${BENCH_SLICES[@]}" -output "$BENCH_OUT"

mkdir -p ios/AnymoneKit/Sources/AnymoneKit
mkdir -p ios/AnymoneKit/Sources/AnymoneBenchKit
cp gen/swift/*.swift ios/AnymoneKit/Sources/AnymoneKit/
cp gen/swift-bench/*.swift ios/AnymoneKit/Sources/AnymoneBenchKit/

echo "built $OUT and the Swift bindings in $ROOT/ios/AnymoneKit"
