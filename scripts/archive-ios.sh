#!/usr/bin/env bash
# Unsigned Release .xcarchive for the TestFlight lane, alongside the Release
# entitlements whoever signs it has to re-apply.
#
# The Apple Distribution cert and App Store Connect key live in a separate repo,
# so this CI cannot sign for distribution, and it cannot sign ad-hoc either — the
# iOS device SDK rejects the '-' identity ("Ad Hoc code signing is not allowed").
# An unsigned app carries no entitlements for -exportArchive to copy forward, so
# the signing lane passes Release.entitlements to codesign explicitly. Losing that
# file means losing App Attest with nothing in the build log to say so.
set -euo pipefail

cd "$(dirname "$0")/../ios/AnymoneApp"
BUILD_NUMBER=${BUILD_NUMBER:-1}
STAGE=build/testflight

xcodegen generate

# ClangStatCache only pre-indexes the SDK to speed up header lookups, and it
# fails outright on the runner's Xcode 26.6 / iPhoneOS26.5 pairing. Nothing in
# the archive depends on it.
defaults write com.apple.dt.XCBuild EnableSDKStatCaching -bool NO

rm -rf build/AnymoneApp.xcarchive "$STAGE"
xcodebuild archive \
  -project AnymoneApp.xcodeproj \
  -scheme AnymoneApp \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -archivePath build/AnymoneApp.xcarchive \
  -derivedDataPath build/DerivedData \
  CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY=""

mkdir -p "$STAGE"
cp -R build/AnymoneApp.xcarchive "$STAGE/"
cp AnymoneApp/AnymoneApp.entitlements "$STAGE/Release.entitlements"
# upload-artifact drops the executable bit, which would hand the signing lane an
# app whose binary cannot launch, so ship a tarball.
tar czf build/AnymoneApp.xcarchive.tar.gz -C "$STAGE" .
echo "archived build $BUILD_NUMBER, unsigned"
