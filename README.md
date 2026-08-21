# anymone-mobile

Anymone clients on iOS and Android: one Rust crate (`crates/anymone-ffi`) wrapping
`anymone-core` behind UniFFI, plus a SwiftUI app and an Android skeleton over the
generated bindings.

Three screens, in the order they became useful:

1. **Bench** — times the client-side crypto on the device. No network, no accounts.
2. **Room** — joins a broadcast tag over the client plane and exchanges messages.
3. **Attest** — starts the client with App Attest / Play Integrity so it is
   admitted on `attested = true` subnets.

## Layout

```
crates/anymone-ffi   the FFI surface: AnymoneClient, AnymonePipe,
                     AttestationTokenFetcher, run_bench
scripts/build-ios.sh     staticlibs -> AnymoneFFI.xcframework + Swift bindings
scripts/build-android.sh cargo-ndk -> jniLibs + Kotlin bindings
ios/AnymoneKit       SwiftPM package wrapping the xcframework
ios/AnymoneApp       the app (project.yml -> `xcodegen generate`)
android              :core (bindings + .so) and :app (Compose)
```

## The anymone dependency

The crate depends on anymone as a pinned git dependency:

```
ssh://git@github.com/flashbots/anymone  rev 2833fb0  (branch attested-subnets)
```

That revision carries the `tee` module this crate's prover plugs into. Core
changes reach the mobile build only once they are pushed and the `rev` in
`crates/anymone-ffi/Cargo.toml` is bumped. Repoint it at a `main` rev once
attested-subnets lands there.

## Getting a build onto an iPhone

The iOS build runs on a macOS CI runner and ships to TestFlight; installs come
over the air. Push to `main`, or run the workflow manually, and
`scripts/testflight.sh` archives with manual signing and uploads via the App
Store Connect API. Secrets it needs are listed at the top of that script.

Because TestFlight builds attest in App Attest's **production** environment, the
relay's `AppAttestPolicy` must set `production = true`. The `development`
entitlement — and `production = false` — only applies to builds signed locally
by Xcode (`AnymoneApp.Debug.entitlements`).

Debugging without a Mac means no `os_log` and no Xcode previews, which is why
every screen keeps its protocol state on screen.

## Where the identity lives

The Ed25519 identity plus its exchange scalar are the client's entire standing in
the network — they authenticate the stream handshake, sign every round, and are
what an attestation enrols. So Rust never writes them to disk. `AnymoneClient`
takes a `SecretStore`, and the shells implement it over the iOS Keychain
(`afterFirstUnlockThisDeviceOnly`: background-readable, device-bound, absent from
backups) and the Android Keystore (an AES-GCM key generated in secure hardware
wraps the blob, with `allowBackup=false` on top). `data_dir` then holds only
transport state, and is excluded from iOS backups.

A store that fails to open is an error rather than a cue to mint a fresh
identity: silently rotating would look like a new client to every relay and drop
the enrolment along with any reputation attached to the key. Losing the store
means losing the identity, which is the intended trade.

## How the attestation bridge works

Rust owns the challenge: `sha256("anymone/attest/v0" ‖ scheme ‖ pubkey ‖ round)`,
32 bytes, handed to the shell. The shell calls the platform SDK and returns the
evidence — a Play Integrity verdict token requested with
`requestHash = base64url-nopad(challenge)`, `key_id ‖ CBOR attestation object`
from App Attest with `clientDataHash = challenge`, or the Keystore certificate
chain of a key generated with `setAttestationChallenge(challenge)`. Rust frames
it and the stream transport re-sends it on every reconnect.

`TeeProver::attest` is synchronous and runs on a runtime worker, while both SDKs
are async, so `BridgeProver` never waits: it serves a cached token, or starts a
fetch and reports that none is ready. A client without a token stays off attested
subnets and retries — no failure, just no admission yet. One token covers a
validity window (100 rounds by default), which is what keeps Play's daily request
quota irrelevant.

## What each platform still needs

- **iOS**: Apple Developer org enrolment, an App ID with the App Attest
  capability, an App Store distribution cert and provisioning profile for the
  TestFlight lane, and the team ID in the relay's `AppAttestPolicy`. App Attest
  does not run on the simulator — the fetcher reports `Unavailable` there and the
  client falls back to open subnets.
- **Android**: nothing, for now. The Attest screen uses **hardware key
  attestation**, which chains to Google's public root and verifies offline — no
  Play Console, no Cloud project, no install through Play. A sideloaded debug APK
  can enrol on an attested subnet, provided the relay's `AndroidKeyPolicy` lists
  the debug signing certificate's SHA-256 (`apksigner verify --print-certs`) and
  leaves `require_strongbox` off for handsets without a secure element.

  Switching to Play Integrity later needs a Play Console app entry linked to a
  Google Cloud project, its response-decryption and verification keys in
  `PlayIntegrityPolicy`, the project number passed to `PlayIntegrityFetcher`, and
  an install through the internal testing track — `PLAY_RECOGNIZED` is never
  issued for a sideloaded build.

  The two attest different things: key attestation proves the device and its boot
  state, Play Integrity proves the build came from Play. Key attestation says
  nothing about provenance, so a rebuilt APK under the same package name attests
  fine and only the signing digest separates it.

Bundle id, package name and signing-certificate digest are all pinned in the
signed network policy, so pick them before relays are configured.

## Running against a dev network

`deploy/local` in anymone binds to 127.0.0.1; regenerate the client config with
the machine's LAN address, then paste it into the Room screen. The phone only
needs outbound TCP — the client never listens.
