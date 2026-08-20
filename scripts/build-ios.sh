#!/usr/bin/env bash
# Device + simulator staticlibs -> AnymoneFFI.xcframework, plus the Swift bindings.
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT=$PWD
PROFILE=${PROFILE:-release}
CARGO_FLAGS=(-p anymone-ffi)
[ "$PROFILE" = release ] && CARGO_FLAGS+=(--release)

rustup target add aarch64-apple-ios aarch64-apple-ios-sim >/dev/null

for target in aarch64-apple-ios aarch64-apple-ios-sim; do
  cargo build "${CARGO_FLAGS[@]}" --target "$target"
done
# Host build only so uniffi-bindgen can read the metadata out of a loadable dylib.
cargo build "${CARGO_FLAGS[@]}"

HOST_LIB=$(ls "target/$PROFILE"/libanymone_ffi.dylib "target/$PROFILE"/libanymone_ffi.so 2>/dev/null | head -1)
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
xcodebuild -create-xcframework \
  -library "target/aarch64-apple-ios/$PROFILE/libanymone_ffi.a" -headers "$HEADERS" \
  -library "target/aarch64-apple-ios-sim/$PROFILE/libanymone_ffi.a" -headers "$HEADERS" \
  -output "$OUT"

mkdir -p ios/AnymoneKit/Sources/AnymoneKit
cp gen/swift/*.swift ios/AnymoneKit/Sources/AnymoneKit/

echo "built $OUT and the Swift bindings in $ROOT/ios/AnymoneKit"
