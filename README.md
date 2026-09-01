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
ssh://git@github.com/flashbots/anymone  rev eeae218
```

That revision carries the `tee` module this crate's prover plugs into. Core
changes reach the mobile build only once they are pushed and the `rev` in
`crates/anymone-ffi/Cargo.toml` is bumped. Repoint it at a `main` rev once
attested-subnets lands there.

## Merging handset benchmarks into Panetiere

The Bench screen measures every client-owned direct and RS phase for Prony, an
MSE encoding microbenchmark, and the full Anymone Prony round. Each operation
gets one untimed warmup. Protocol operations use five measured samples, setup
uses three, and ECDH and signing use 200.

The detailed suite runs on four workers pinned to the four highest-frequency
allowed physical cores. `Core sweep 1·2·4·8` measures the full Prony client
round at each width using three samples plus one untimed warmup. Its CSV carries
`mode=core-sweep` and is not accepted by the merge tool.

`Smoke 4×10` is the emulator lane: one Prony round, one MSE round, ECDH and
signing at 4 servers and 10 expected messages. Each runs once without a warmup.
Smoke CSVs carry `mode=smoke` and the merge tool rejects them.

For the same core sweep on a desktop, in the background:

```sh
nohup cargo run --release -p anymone-ffi --bin panetiere-mobile-bench -- \
  desktop-core-sweep.csv >desktop-core-sweep.log 2>&1 &
```

This uses the handset benchmark cell: Prony, 8 servers, 50 expected messages,
1 KB input, 7 KAHE polys and RS 6/8. Workers are pinned to the fastest allowed
non-SMT cores first. Restrict the candidate CPUs with `taskset` when needed.
Export writes the cell identity, Android/iOS environment, hardware, OS, build,
Rayon width, CPU affinity and timing spread to CSV.

Run the matching cell in Panetiere. The host sweep's payload knob uses 36-bit
MSE symbols; `248` maps to the mobile channel's 256 35-bit Prony symbols. The
legacy `rs_dgt_embed` CSV column now contains direct RNS encryption time.

```sh
SWEEP_SERVERS=8 SWEEP_CLIENTS=50x50 SWEEP_PAYLOAD_SYMBOLS=248 \
SWEEP_RS=6x8 SWEEP_SCHED_BYTES= BENCH_CSV=host.csv \
  ./target/release/panetiere_scaling
```

Then replace that host row's client timings and recompute its composed and
projected columns:

```sh
cargo run --release -p anymone-ffi --bin panetiere-mobile-merge -- \
  mobile.csv host.csv mobile-merged.csv
```

The merge refuses a missing or ambiguous cell and requires matching server,
client, flow, payload, encoding geometry and RS plan. Host server/verifier
measurements remain unchanged.

## Getting a build onto an iPhone

The iOS build runs on a macOS CI runner and ships to TestFlight; installs come
over the air. This repo goes as far as the archive: `scripts/archive-ios.sh`
produces an ad-hoc-signed Release `.xcarchive` and CI publishes it as
`AnymoneApp.xcarchive.tar.gz`. Signing it with the distribution certificate and
uploading it through the App Store Connect API happen in the separate
`apple-store-workflows` repo, which is where the Apple credentials live — none of
them are needed here.

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

- **iOS**: Apple Developer enrolment, an App ID with the App Attest capability, an
  App Store distribution cert and provisioning profile, and the team ID in the
  relay's `AppAttestPolicy`. This CI only archives (`scripts/archive-ios.sh`,
  ad-hoc signed); the distribution cert and App Store Connect key live in the
  `apple-store-workflows` repo, which signs that archive and uploads it. App Attest
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
