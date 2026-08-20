//! On-device timing of the client-side hot paths, so a phone's round cost can
//! be compared against the round budget (4 s by committee default).
//!
//! Everything here goes through anymone-core's own session types, so what is
//! measured is what a real client runs.

use std::collections::HashMap;
use std::time::Instant;

use anymone_core::adcnet::{AdcnetClientSession, IbltMsgParamsOwned, OneRoundConfig, ServerId};
use anymone_core::config::PanetiereConfig;
use anymone_core::panetiere::{params_for, pke, ServerId as PanetiereServerId};
use anymone_core::{Identity, PanetiereClientSession, Session};

use crate::AnymoneError;

/// Committee defaults, so the numbers describe a real deployment:
/// `message_size = 256`, initial capacity 8, three relays. Every protocol is
/// sized from this one scenario, or the comparison tilts.
const RELAYS: usize = 3;
const MESSAGE_SIZE: usize = 256;
const CLIENT_SET_MAX: u32 = 8;
/// The scheduler's `expected_active(client_set_max)`: half a set sends, the
/// rest covers, and cover vanishes from the IBLT and the MSE sum.
const ESTIMATED_MESSAGES: u32 = CLIENT_SET_MAX.div_ceil(2);
/// Comfortably inside `max_message_payload(256)`.
const PAYLOAD: usize = 100;

/// Reps worth running: setup costs seconds, a client round milliseconds, the
/// primitives microseconds.
#[uniffi::export]
pub fn bench_reps(name: String) -> u32 {
    match name.as_str() {
        PANETIERE_SETUP => 5,
        PANETIERE_CLIENT_ROUND | ADCNET_CLIENT_ROUND => 25,
        _ => 200,
    }
}

#[derive(uniffi::Record)]
pub struct BenchResult {
    pub name: String,
    pub reps: u32,
    pub median_ns: u64,
    pub min_ns: u64,
    pub max_ns: u64,
}

const PANETIERE_SETUP: &str = "panetiere_setup";
const PANETIERE_CLIENT_ROUND: &str = "panetiere_client_round";
const ADCNET_CLIENT_ROUND: &str = "adcnet_client_round";
const ECDH_SHARED_SECRET: &str = "ecdh_shared_secret";
const ED25519_SIGN: &str = "ed25519_sign";

#[uniffi::export]
pub fn bench_names() -> Vec<String> {
    [
        PANETIERE_SETUP,
        PANETIERE_CLIENT_ROUND,
        ADCNET_CLIENT_ROUND,
        ECDH_SHARED_SECRET,
        ED25519_SIGN,
    ]
    .iter()
    .map(|s| s.to_string())
    .collect()
}

/// CPU-bound for seconds (`panetiere_setup` especially). Run off the UI thread,
/// one benchmark at a time.
#[uniffi::export]
pub fn run_bench(name: String, reps: u32) -> Result<BenchResult, AnymoneError> {
    let reps = reps.max(1) as usize;
    let mut ns = match name.as_str() {
        PANETIERE_SETUP => measure(reps, panetiere_config, |cfg, _| params_for(cfg, RELAYS)),
        PANETIERE_CLIENT_ROUND => measure(reps, panetiere_session, |session, round| {
            session.stage(vec![0xab; PAYLOAD]);
            let out = session.begin_round(round, Instant::now());
            assert!(!out.is_empty(), "panetiere client emitted nothing");
            out
        }),
        ADCNET_CLIENT_ROUND => measure(reps, adcnet_session, |session, round| {
            session.stage_message(vec![0xab; PAYLOAD]);
            let out = session.begin_round(round, Instant::now());
            assert!(!out.is_empty(), "adcnet client emitted nothing");
            out
        }),
        ECDH_SHARED_SECRET => {
            let theirs = Identity::generate().exchange_pubkey();
            measure(reps, Identity::generate, |ours, _| {
                ours.exchange().ecdh(&theirs)
            })
        }
        ED25519_SIGN => {
            let msg = [0x5au8; 32];
            measure(reps, Identity::generate, |identity, _| identity.sign(&msg))
        }
        _ => return Err(AnymoneError::UnknownBench(name)),
    };
    ns.sort_unstable();
    Ok(BenchResult {
        name,
        reps: ns.len() as u32,
        median_ns: ns[ns.len() / 2],
        min_ns: ns[0],
        max_ns: *ns.last().unwrap(),
    })
}

/// One timing per rep, so the median discards the cold first rep and the
/// spread shows the noise. `round` advances so a session bench does real work
/// each time.
fn measure<S, R, F>(reps: usize, setup: impl Fn() -> S, mut op: F) -> Vec<u64>
where
    F: FnMut(&mut S, u64) -> R,
{
    let mut state = setup();
    let mut times = Vec::with_capacity(reps);
    let mut keep = None;
    for rep in 0..reps {
        let start = Instant::now();
        let out = op(&mut state, rep as u64);
        times.push(start.elapsed().as_nanos() as u64);
        // Assigned after the clock stops: dropping the previous rep's output
        // must not land inside the window.
        keep = Some(out);
    }
    drop(keep);
    times
}

fn panetiere_config() -> PanetiereConfig {
    PanetiereConfig {
        round_duration_ms: 4_000,
        message_size: MESSAGE_SIZE,
        estimated_messages: ESTIMATED_MESSAGES,
        client_set_min: 0,
        client_set_max: CLIENT_SET_MAX,
        threshold: 2,
        ..PanetiereConfig::default()
    }
}

/// KAHE encryption, Reed-Solomon lanes, one ML-KEM seal per relay, and the
/// per-message signatures — the whole per-round client cost.
fn panetiere_session() -> PanetiereClientSession {
    let (mse, pp) = params_for(&panetiere_config(), RELAYS);
    let servers: Vec<(PanetiereServerId, pke::PublicKey)> = (0..RELAYS)
        .map(|i| {
            let seal = Identity::generate()
                .exchange_keys()
                .to_seal_key()
                .expect("seal key decodes");
            (PanetiereServerId(i as u32), seal)
        })
        .collect();
    PanetiereClientSession::new(pp, mse, Identity::generate(), servers, [7u8; 32])
}

/// ECDH-derived keystreams plus the IBLT contribution.
fn adcnet_session() -> AdcnetClientSession {
    let identity = Identity::generate();
    let secrets: HashMap<ServerId, _> = (0..RELAYS)
        .map(|i| {
            let relay = Identity::generate().exchange_pubkey();
            (ServerId(i as u32), identity.exchange().ecdh(&relay))
        })
        .collect();
    AdcnetClientSession::new(
        OneRoundConfig {
            iblt: IbltMsgParamsOwned {
                estimated_messages: ESTIMATED_MESSAGES,
                max_payload_bytes: MESSAGE_SIZE,
            },
        },
        identity.to_adcnet_signing_key(),
        secrets,
        identity.exchange_pubkey(),
        [7u8; 32],
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Every advertised name runs and reports a non-zero cost.
    #[test]
    fn all_benches_run() {
        for name in bench_names() {
            let r = run_bench(name.clone(), 2).expect("bench runs");
            assert_eq!(r.name, name);
            assert_eq!(r.reps, 2);
            assert!(r.min_ns > 0, "{name} reported no time");
            assert!(r.min_ns <= r.median_ns && r.median_ns <= r.max_ns);
            assert!(bench_reps(name) > 0);
        }
    }

    #[test]
    fn unknown_bench_is_an_error() {
        assert!(matches!(
            run_bench("nope".into(), 1),
            Err(AnymoneError::UnknownBench(_))
        ));
    }
}
