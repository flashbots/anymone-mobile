#!/usr/bin/env bash
# One staticlib per $TARGETS -> AnymoneFFI.xcframework, plus the Swift bindings.
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT=$PWD
PROFILE=${PROFILE:-release}
TARGETS=${TARGETS:-"aarch64-apple-ios aarch64-apple-ios-sim"}
CARGO_FLAGS=(-p anymone-ffi)
[ "$PROFILE" = release ] && CARGO_FLAGS+=(--release)

rustup target add $TARGETS >/dev/null

for target in $TARGETS; do
  cargo build "${CARGO_FLAGS[@]}" --target "$target"
done
# Host build only so uniffi-bindgen can read the metadata out of a loadable dylib.
# Unoptimized: nothing runs it, the bindings only need its metadata.
cargo build -p anymone-ffi

for candidate in target/debug/libanymone_ffi.{dylib,so}; do
  [ -f "$candidate" ] && HOST_LIB=$candidate && break
done
: "${HOST_LIB:?no host library under target/debug}"
rm -rf gen/swift
cargo run -p anymone-ffi --bin uniffi-bindgen -- generate \
  --library "$HOST_LIB" --language swift --out-dir gen/swift --no-format

# Xcode wants `module.modulemap`; uniffi emits `<name>FFI.modulemap`.
HEADERS=gen/swift/headers
rm -rf "$HEADERS" && mkdir -p "$HEADERS"
cp gen/swift/*.h "$HEADERS"/
cat gen/swift/*.modulemap > "$HEADERS/module.modulemap"

OUT=ios/AnymoneKit/AnymoneFFI.xcframework
rm -rf "$OUT"
SLICES=()
for target in $TARGETS; do
  SLICES+=(-library "target/$target/$PROFILE/libanymone_ffi.a" -headers "$HEADERS")
done
xcodebuild -create-xcframework "${SLICES[@]}" -output "$OUT"

mkdir -p ios/AnymoneKit/Sources/AnymoneKit
cp gen/swift/*.swift ios/AnymoneKit/Sources/AnymoneKit/

echo "built $OUT and the Swift bindings in $ROOT/ios/AnymoneKit"
