# anymone-mobile

> [!WARNING]
> This repository is under active development, and it has not been audited. Do not use it for any production use case.
> Do use it to experiment with the protocol 💖

iOS and Android clients using [Anymone](https://github.com/flashbots/anymone)
UniFFI bindings.

- **Remote**: phone-hosted protocol client, paired with a desktop by code.
- **Room**: broadcast chat.
- **Bench**: on-device crypto benchmarks.
- **Attest**: App Attest on iOS; hardware key attestation on Android.

## Build

Requires Rust. Build scripts expect a sibling `../anymone` checkout; override
with `ANYMONE_DIR` or `ANYMONE_MANIFEST`. Keep its revision aligned with
`Cargo.toml` and CI's `ANYMONE_REF`.

### Android

Requires JDK 17, Android SDK 35, Gradle 8.9, and an NDK selected by
`ANDROID_NDK_HOME`.

If you have Nix installed, run `nix develop` from the project root to open a
development shell which supplies these dependencies. You can also skip
`cargo install cargo-ndk` below.

```sh
cargo install cargo-ndk --locked
./scripts/build-android.sh
cd android
gradle --no-daemon assembleDebug
adb install -r app/build/outputs/apk/debug/app-debug.apk
```

For an x86-64 emulator, set `WITH_EMULATOR=1` on the build script and pass
`-Pemulator` to Gradle. Minimum Android API: 29.

### iOS

Requires macOS, Xcode and XcodeGen.

```sh
./scripts/build-ios.sh
cd ios/AnymoneApp
xcodegen generate
```

Open the generated project in Xcode to build and run.
`scripts/archive-ios.sh` produces an unsigned archive and
`Release.entitlements`. TestFlight distribution requires signing with those
entitlements, a distribution certificate and a provisioning profile.

## Connect

Follow the [remote client guide](https://github.com/flashbots/anymone/blob/main/crates/anymone-remote-session/README.md)
for a local demo, code pairing and ADB forwarding. Keep Remote foregrounded;
restart and pair again after restarting the desktop. Remote uses developer
keys without platform attestation.

Room needs a bootstrap configuration with relay addresses reachable from the
phone. Desktop loopback addresses will not work.

For Attest, configure the relay's policy with the iOS team and bundle IDs or
Android package and signing-certificate digest. App Attest requires a physical
device; TestFlight uses the production policy. Client identities are stored
through iOS Keychain or Android Keystore.

## Benchmarks

Export CSV from Bench. The detailed suite uses four workers; core sweep tests
1, 2, 4 and 8 workers. Smoke and core-sweep CSVs cannot be merged into host timings.

To merge a detailed handset result with a matching Panetiere host benchmark:

```sh
cargo run --manifest-path tools/panetiere-mobile/Cargo.toml --release \
  --bin panetiere-mobile-merge -- mobile.csv host.csv mobile-merged.csv
```

Server count, clients, payload, encoding geometry and RS plan must match.
The merge replaces client timings and preserves host server/verifier timings.

## License

MIT — see [LICENSE](LICENSE).
