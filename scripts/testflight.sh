#!/usr/bin/env bash
# Archive the app with manual signing and upload it to TestFlight.
#
# Expects, from CI secrets:
#   IOS_DIST_CERT_P12_BASE64      Apple Distribution cert + key, .p12, base64
#   IOS_DIST_CERT_PASSWORD       its export password
#   IOS_PROFILE_BASE64            App Store provisioning profile, base64
#   IOS_PROFILE_NAME              the profile's name, as the portal shows it
#   APPLE_TEAM_ID                 also pinned in the relay's AppAttestPolicy
#   ASC_KEY_ID / ASC_ISSUER_ID / ASC_PRIVATE_KEY   App Store Connect API key
# and BUILD_NUMBER (TestFlight rejects a repeated one).
set -euo pipefail

cd "$(dirname "$0")/../ios/AnymoneApp"
BUILD_NUMBER=${BUILD_NUMBER:-1}
KEYCHAIN=$RUNNER_TEMP/anymone.keychain-db
KEYCHAIN_PASSWORD=$(uuidgen)

# A throwaway keychain, unlocked without prompting, holding only this cert.
security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
security set-keychain-settings -lut 3600 "$KEYCHAIN"
security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
security list-keychains -d user -s "$KEYCHAIN" $(security list-keychains -d user | tr -d '"')

echo "$IOS_DIST_CERT_P12_BASE64" | base64 --decode > "$RUNNER_TEMP/dist.p12"
security import "$RUNNER_TEMP/dist.p12" -k "$KEYCHAIN" -P "$IOS_DIST_CERT_PASSWORD" \
  -T /usr/bin/codesign -T /usr/bin/security
# Without this, codesign blocks on a UI prompt for key access.
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN" >/dev/null

PROFILES="$HOME/Library/MobileDevice/Provisioning Profiles"
mkdir -p "$PROFILES"
echo "$IOS_PROFILE_BASE64" | base64 --decode > "$PROFILES/anymone.mobileprovision"

xcodegen generate

xcodebuild archive \
  -project AnymoneApp.xcodeproj \
  -scheme AnymoneApp \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -archivePath build/AnymoneApp.xcarchive \
  CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
  DEVELOPMENT_TEAM="$APPLE_TEAM_ID" \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="Apple Distribution" \
  PROVISIONING_PROFILE_SPECIFIER="$IOS_PROFILE_NAME" \
  OTHER_CODE_SIGN_FLAGS="--keychain $KEYCHAIN"

/usr/libexec/PlistBuddy -c "Add :teamID string $APPLE_TEAM_ID" ExportOptions.plist || true
/usr/libexec/PlistBuddy -c "Add :provisioningProfiles:net.flashbots.anymone string $IOS_PROFILE_NAME" \
  ExportOptions.plist || true

xcodebuild -exportArchive \
  -archivePath build/AnymoneApp.xcarchive \
  -exportPath build/ipa \
  -exportOptionsPlist ExportOptions.plist

mkdir -p "$HOME/private_keys"
echo "$ASC_PRIVATE_KEY" > "$HOME/private_keys/AuthKey_$ASC_KEY_ID.p8"
xcrun altool --upload-app -f build/ipa/AnymoneApp.ipa -t ios \
  --apiKey "$ASC_KEY_ID" --apiIssuer "$ASC_ISSUER_ID"

security delete-keychain "$KEYCHAIN"
echo "uploaded build $BUILD_NUMBER; it appears in TestFlight after processing"
