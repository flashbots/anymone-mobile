#!/usr/bin/env bash
# Release .xcarchive for the TestFlight lane, signed ad-hoc.
#
# The Apple Distribution cert and App Store Connect key live in a separate repo,
# so this CI cannot sign for distribution. It signs ad-hoc instead of not at all:
# -exportArchive over there re-signs but carries the entitlements over from the
# signature it finds, and an unsigned archive has none to carry — the exported app
# would silently lose the App Attest entitlement.
set -euo pipefail

cd "$(dirname "$0")/../ios/AnymoneApp"
BUILD_NUMBER=${BUILD_NUMBER:-1}

xcodegen generate

xcodebuild archive \
  -project AnymoneApp.xcodeproj \
  -scheme AnymoneApp \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -archivePath build/AnymoneApp.xcarchive \
  CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY=- \
  CODE_SIGNING_REQUIRED=NO \
  PROVISIONING_PROFILE_SPECIFIER=""

# upload-artifact drops the executable bit, which would hand the signing lane an
# app whose binary cannot launch, so ship a tarball.
tar czf build/AnymoneApp.xcarchive.tar.gz -C build AnymoneApp.xcarchive
echo "archived build $BUILD_NUMBER"
