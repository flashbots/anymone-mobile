//! On-device timing of the client's per-round cost, in two views.
//!
//! The `panetiere_*` phases mirror the client role in flashnet's
//! `scaling_bench`: every Prony direct and RS client phase plus an MSE encoding
//! microbenchmark, at 8 servers, 50 expected messages and 1 KB payloads. The
//! `anymone_*` rounds time what a client actually runs per round instead.

use std::collections::HashMap;
use std::sync::Arc;
use std::time::Instant;

use anymone_core::adcnet::{AdcnetClientSession, IbltMsgParamsOwned, OneRoundConfig, ServerId};
use anymone_core::config::{Encoding, PanetiereConfig};
use anymone_core::panetiere::{params_for, pke, ServerId as PanetiereServerId};
use anymone_core::{max_message_payload, Identity, PanetiereClientSession, Session};
use once_cell::sync::Lazy;
use panetiere::bulletin::RsClientBulletinEntry;
use panetiere::channel::{self, ChannelParams};
use panetiere::kahe::{Kahe, KaheScheme};
use panetiere::protocol::client::{
    cs_commit, kahe_encrypt, kahe_keygen, seal_openings, shamir_share,
};
use panetiere::protocol::{message_polys, ClientId, ProtocolParams, SessionId};
use panetiere::rs::Rs;
use panetiere::share_commitment::commit_shares;
use panetiere::sig::SigningKey;
use rand_chacha::rand_core::SeedableRng;
use rand_chacha::ChaCha20Rng;

use crate::AnymoneError;

/// The sweep cell this mirrors: 8 servers, 50 expected messages a round, 1 KB
/// payloads. ξ is derived from the message size, so the size is what pins the
/// cell.
const SERVERS: usize = 8;
const CLIENTS: u32 = 50;
const MESSAGE_BYTES: usize = 1024;
const SMOKE_SERVERS: usize = 4;
const SMOKE_CLIENTS: u32 = 10;
const BENCH_THREADS: u32 = 4;
const CORE_SWEEP_REPS: usize = 3;
const CORE_SWEEP_THREADS: &[u32] = &[1, 2, 4, 8];

/// Fixed so a rerun times the same work, and so the phases compose: the key
/// fed to `kahe_enc` is the one `share` splits.
const SEED: [u8; 32] = [7u8; 32];
const SESSION: SessionId = SessionId([0x5c; 32]);
const PANETIERE_REV: &str = "e5c9cdf033b4873ee3a97210d97b37f435c5f573";
const ANYMONE_REV: &str = "eeae218fda1403d6ce7fcbac2befca3c2654a5d2";

const PANETIERE_SETUP: &str = "panetiere_setup";
const ENC_APP: &str = "panetiere_enc_app";
const KAHE_KEYGEN: &str = "panetiere_kahe_keygen";
const KAHE_ENC: &str = "panetiere_kahe_enc";
const SHARE: &str = "panetiere_share";
const CS_COMMIT: &str = "panetiere_cs_commit";
const SEAL: &str = "panetiere_seal";
const RS_DGT_EMBED: &str = "panetiere_rs_dgt_embed";
const RS_ENC: &str = "panetiere_rs_enc";
const RS_SHARE_COMMIT: &str = "panetiere_rs_share_commit";
const RS_CLIENT_SIGN: &str = "panetiere_rs_client_sign";
const MSE_ENC_APP: &str = "panetiere_mse_enc_app";
const ANYMONE_PANETIERE_ROUND: &str = "anymone_panetiere_round";
const ANYMONE_ADCNET_ROUND: &str = "anymone_adcnet_round";
const ECDH_SHARED_SECRET: &str = "ecdh_shared_secret";
const ED25519_SIGN: &str = "ed25519_sign";
const SMOKE_PRONY_ROUND: &str = "smoke_panetiere_prony_round";
const SMOKE_MSE_ROUND: &str = "smoke_panetiere_mse_round";
const SMOKE_ECDH: &str = "smoke_ecdh_shared_secret";
const SMOKE_ED25519: &str = "smoke_ed25519_sign";

/// flashnet's `client_us`: the phases one client runs per round. Their sum is
/// the serial client wall, which is what compares against the round budget.
const CLIENT_ROLE: &[&str] = &[
    ENC_APP,
    KAHE_KEYGEN,
    SHARE,
    CS_COMMIT,
    SEAL,
    RS_DGT_EMBED,
    RS_ENC,
    RS_SHARE_COMMIT,
    RS_CLIENT_SIGN,
];

#[derive(Clone, Copy)]
enum ClientPhase {
    EncApp,
    KaheKeygen,
    KaheEnc,
    Share,
    CsCommit,
    Seal,
    RsDgtEmbed,
    RsEnc,
    RsShareCommit,
    RsClientSign,
}

#[derive(Clone, uniffi::Record)]
pub struct BenchResult {
    pub name: String,
    pub reps: u32,
    pub threads: u32,
    pub affinity: String,
    pub median_ns: u64,
    pub min_ns: u64,
    pub max_ns: u64,
}

#[uniffi::export]
pub fn bench_names() -> Vec<String> {
    [
        PANETIERE_SETUP,
        ENC_APP,
        KAHE_KEYGEN,
        KAHE_ENC,
        SHARE,
        CS_COMMIT,
        SEAL,
        RS_DGT_EMBED,
        RS_ENC,
        RS_SHARE_COMMIT,
        RS_CLIENT_SIGN,
        MSE_ENC_APP,
        ANYMONE_PANETIERE_ROUND,
        ANYMONE_ADCNET_ROUND,
        ECDH_SHARED_SECRET,
        ED25519_SIGN,
    ]
    .iter()
    .map(|s| s.to_string())
    .collect()
}

#[uniffi::export]
pub fn smoke_names() -> Vec<String> {
    [
        SMOKE_PRONY_ROUND,
        SMOKE_MSE_ROUND,
        SMOKE_ECDH,
        SMOKE_ED25519,
    ]
    .iter()
    .map(|s| s.to_string())
    .collect()
}

#[uniffi::export]
pub fn bench_threads() -> u32 {
    BENCH_THREADS
}

#[uniffi::export]
pub fn core_sweep_threads() -> Vec<u32> {
    CORE_SWEEP_THREADS.to_vec()
}

/// Five for anything protocol-shaped, matching `scaling_bench`'s `REPS`; the
/// primitives are cheap enough to average over many more.
#[uniffi::export]
pub fn bench_reps(name: String) -> u32 {
    match name.as_str() {
        ECDH_SHARED_SECRET | ED25519_SIGN => 200,
        PANETIERE_SETUP => 3,
        _ => 5,
    }
}

/// Sum of the Prony RS client phase medians.
#[uniffi::export]
pub fn client_role_median_ns(results: Vec<BenchResult>) -> u64 {
    results
        .iter()
        .filter(|r| CLIENT_ROLE.contains(&r.name.as_str()))
        .map(|r| r.median_ns)
        .sum()
}

/// CPU-bound for seconds (`panetiere_setup` especially). Run off the UI thread,
/// one benchmark at a time.
#[uniffi::export]
pub fn run_bench(name: String, reps: u32, threads: u32) -> Result<BenchResult, AnymoneError> {
    run_in_pool(threads, || run_bench_inner(name, reps))
}

fn run_bench_inner(name: String, reps: u32) -> Result<BenchResult, AnymoneError> {
    let reps = reps.max(1) as usize;
    if let Some((ch, pp, phase)) = client_phase(&name) {
        return Ok(result(name, measure_client_phase(reps, ch, pp, phase)));
    }
    let ns = match name.as_str() {
        PANETIERE_SETUP => measure(reps, panetiere_config, |cfg, _| params_for(cfg, SERVERS)),
        ANYMONE_PANETIERE_ROUND => {
            let payload = vec![0xab; channel_params().max_payload_bytes()];
            measure(reps, panetiere_session, move |session, round| {
                session.stage(payload.clone());
                let out = session.begin_round(round, Instant::now());
                assert!(!out.is_empty(), "panetiere client emitted nothing");
                out
            })
        }
        ANYMONE_ADCNET_ROUND => {
            let payload = vec![0xab; max_message_payload(MESSAGE_BYTES)];
            measure(reps, adcnet_session, move |session, round| {
                session.stage_message(payload.clone());
                let out = session.begin_round(round, Instant::now());
                assert!(!out.is_empty(), "adcnet client emitted nothing");
                out
            })
        }

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
    Ok(result(name, ns))
}

#[uniffi::export]
pub fn run_smoke(name: String) -> Result<BenchResult, AnymoneError> {
    run_in_pool(1, || run_smoke_inner(name))
}

fn run_smoke_inner(name: String) -> Result<BenchResult, AnymoneError> {
    let ns = match name.as_str() {
        SMOKE_PRONY_ROUND => {
            let payload = vec![0xab; smoke_prony_channel_params().max_payload_bytes()];
            measure_once(smoke_prony_session, move |session, _| {
                session.stage(payload.clone());
                let out = session.begin_round(0, Instant::now());
                assert!(!out.is_empty(), "Prony smoke client emitted nothing");
                out
            })
        }
        SMOKE_MSE_ROUND => {
            let payload = vec![0xab; smoke_mse_channel_params().max_payload_bytes()];
            measure_once(smoke_mse_session, move |session, _| {
                session.stage(payload.clone());
                let out = session.begin_round(0, Instant::now());
                assert!(!out.is_empty(), "MSE smoke client emitted nothing");
                out
            })
        }
        SMOKE_ECDH => {
            let theirs = Identity::generate().exchange_pubkey();
            measure_once(Identity::generate, |ours, _| ours.exchange().ecdh(&theirs))
        }
        SMOKE_ED25519 => {
            let msg = [0x5au8; 32];
            measure_once(Identity::generate, |identity, _| identity.sign(&msg))
        }
        _ => return Err(AnymoneError::UnknownBench(name)),
    };
    Ok(result(name, ns))
}

#[uniffi::export]
pub fn run_core_bench(threads: u32) -> Result<BenchResult, AnymoneError> {
    if !CORE_SWEEP_THREADS.contains(&threads) {
        return Err(AnymoneError::UnknownBench(format!("core count {threads}")));
    }
    run_in_pool(threads, || {
        let payload = vec![0xab; channel_params().max_payload_bytes()];
        let ns = measure(CORE_SWEEP_REPS, panetiere_session, move |session, round| {
            session.stage(payload.clone());
            let out = session.begin_round(round, Instant::now());
            assert!(!out.is_empty(), "core-sweep client emitted nothing");
            out
        });
        Ok(result(format!("anymone_panetiere_round_t{threads}"), ns))
    })
}

fn result(name: String, mut ns: Vec<u64>) -> BenchResult {
    ns.sort_unstable();
    BenchResult {
        name,
        reps: ns.len() as u32,
        threads: rayon::current_num_threads() as u32,
        affinity: "?".into(),
        median_ns: ns[ns.len() / 2],
        min_ns: ns[0],
        max_ns: *ns.last().unwrap(),
    }
}

fn run_in_pool(
    threads: u32,
    op: impl FnOnce() -> Result<BenchResult, AnymoneError> + Send,
) -> Result<BenchResult, AnymoneError> {
    let threads = threads.max(1) as usize;
    let cpus = performance_cpus(threads);
    let affinity = cpus
        .iter()
        .map(usize::to_string)
        .collect::<Vec<_>>()
        .join(";");
    #[cfg(any(target_os = "android", target_os = "linux"))]
    let pin_failed = std::sync::Arc::new(std::sync::atomic::AtomicBool::new(false));
    #[cfg(any(target_os = "android", target_os = "linux"))]
    let builder = {
        let worker_cpus = cpus.clone();
        let pin_failed = pin_failed.clone();
        rayon::ThreadPoolBuilder::new()
            .num_threads(threads)
            .spawn_handler(move |thread| {
                let cpu = worker_cpus[thread.index() % worker_cpus.len()];
                // spawn_handler is FnMut, so each worker needs its own handle.
                let pin_failed = pin_failed.clone();
                std::thread::Builder::new()
                    .name(format!("bench-{cpu}"))
                    .spawn(move || {
                        if !pin_current_cpu(cpu) {
                            pin_failed.store(true, std::sync::atomic::Ordering::Relaxed);
                        }
                        thread.run();
                    })
                    .map(|_| ())
            })
    };
    #[cfg(not(any(target_os = "android", target_os = "linux")))]
    let builder = rayon::ThreadPoolBuilder::new().num_threads(threads);
    let pool = builder
        .build()
        .map_err(|e| AnymoneError::Config(format!("benchmark pool: {e}")))?;
    let mut result = pool.install(op)?;
    result.threads = threads as u32;
    #[cfg(any(target_os = "android", target_os = "linux"))]
    {
        result.affinity = if pin_failed.load(std::sync::atomic::Ordering::Relaxed) {
            format!("pin-failed;{affinity}")
        } else {
            affinity
        };
    }
    #[cfg(not(any(target_os = "android", target_os = "linux")))]
    {
        result.affinity = format!("scheduler;{threads}");
    }
    Ok(result)
}

fn performance_cpus(threads: usize) -> Vec<usize> {
    let mut cpus: Vec<_> = allowed_cpus()
        .into_iter()
        .map(|cpu| {
            let path = format!("/sys/devices/system/cpu/cpu{cpu}/cpufreq/cpuinfo_max_freq");
            let freq = std::fs::read_to_string(path)
                .ok()
                .and_then(|v| v.trim().parse::<u64>().ok())
                .unwrap_or(0);
            (cpu, freq, physical_core(cpu))
        })
        .collect();
    cpus.sort_by_key(|&(cpu, freq, _)| std::cmp::Reverse((freq, cpu)));
    let mut physical = std::collections::HashSet::new();
    let mut selected = Vec::new();
    for &(cpu, _, core) in &cpus {
        if physical.insert(core) {
            selected.push(cpu);
            if selected.len() == threads {
                return selected;
            }
        }
    }
    for (cpu, _, _) in cpus {
        if !selected.contains(&cpu) {
            selected.push(cpu);
            if selected.len() == threads {
                break;
            }
        }
    }
    if selected.is_empty() {
        selected.push(0);
    }
    selected
}

fn physical_core(cpu: usize) -> (usize, usize) {
    let read = |name: &str| {
        std::fs::read_to_string(format!("/sys/devices/system/cpu/cpu{cpu}/topology/{name}"))
            .ok()
            .and_then(|v| v.trim().parse::<usize>().ok())
    };
    (
        read("physical_package_id").unwrap_or(0),
        read("core_id").unwrap_or(cpu),
    )
}

fn allowed_cpus() -> Vec<usize> {
    let list = std::fs::read_to_string("/proc/self/status")
        .ok()
        .and_then(|s| {
            s.lines()
                .find_map(|line| line.strip_prefix("Cpus_allowed_list:"))
                .map(str::trim)
                .map(str::to_string)
        });
    let mut out = Vec::new();
    if let Some(list) = list {
        for part in list.split(',') {
            let (start, end) = part
                .split_once('-')
                .map_or((part, part), |(start, end)| (start, end));
            if let (Ok(start), Ok(end)) = (start.parse::<usize>(), end.parse::<usize>()) {
                out.extend(start..=end);
            }
        }
    }
    if out.is_empty() {
        out.extend(0..std::thread::available_parallelism().map_or(1, usize::from));
    }
    out
}

#[cfg(any(target_os = "android", target_os = "linux"))]
fn pin_current_cpu(cpu: usize) -> bool {
    unsafe {
        let mut set: libc::cpu_set_t = std::mem::zeroed();
        libc::CPU_ZERO(&mut set);
        libc::CPU_SET(cpu, &mut set);
        libc::sched_setaffinity(0, std::mem::size_of::<libc::cpu_set_t>(), &set) == 0
    }
}

fn measure_once<S, R>(setup: impl Fn() -> S, mut op: impl FnMut(&mut S, u64) -> R) -> Vec<u64> {
    let mut state = setup();
    let start = Instant::now();
    let out = op(&mut state, 0);
    let elapsed = start.elapsed().as_nanos() as u64;
    drop(out);
    vec![elapsed]
}

fn client_phase(
    name: &str,
) -> Option<(&'static ChannelParams, &'static ProtocolParams, ClientPhase)> {
    let phase = match name {
        ENC_APP | MSE_ENC_APP => ClientPhase::EncApp,
        KAHE_KEYGEN => ClientPhase::KaheKeygen,
        KAHE_ENC => ClientPhase::KaheEnc,
        SHARE => ClientPhase::Share,
        CS_COMMIT => ClientPhase::CsCommit,
        SEAL => ClientPhase::Seal,
        RS_DGT_EMBED => ClientPhase::RsDgtEmbed,
        RS_ENC => ClientPhase::RsEnc,
        RS_SHARE_COMMIT => ClientPhase::RsShareCommit,
        RS_CLIENT_SIGN => ClientPhase::RsClientSign,
        _ => return None,
    };
    let (ch, pp) = if name.starts_with("panetiere_mse_") {
        (mse_channel_params(), mse_protocol_params())
    } else {
        (channel_params(), protocol_params())
    };
    Some((ch, pp, phase))
}

fn measure_client_phase(
    reps: usize,
    ch: &'static ChannelParams,
    pp: &'static ProtocolParams,
    phase: ClientPhase,
) -> Vec<u64> {
    match phase {
        ClientPhase::EncApp => measure(
            reps,
            || (rng(), symbols_for(ch)),
            |(rng, symbols), _| channel::encode_symbols(rng, ch, symbols),
        ),
        ClientPhase::KaheKeygen => measure(reps, rng, |rng, _| kahe_keygen(rng, pp)),
        ClientPhase::KaheEnc => measure(
            reps,
            || {
                let mut rng = rng();
                let key = kahe_keygen(&mut rng, pp);
                (rng, key, message_for(ch, pp))
            },
            |(rng, key, msg), _| kahe_encrypt(rng, pp, key, msg),
        ),
        ClientPhase::Share => measure(
            reps,
            || {
                let mut rng = rng();
                let key = kahe_keygen(&mut rng, pp);
                (rng, key)
            },
            |(rng, key), _| shamir_share(rng, pp, key),
        ),
        ClientPhase::CsCommit => measure(
            reps,
            || {
                let mut rng = rng();
                let key = kahe_keygen(&mut rng, pp);
                let shares = shamir_share(&mut rng, pp, &key);
                (rng, shares)
            },
            |(rng, shares), _| cs_commit(rng, pp, shares),
        ),
        ClientPhase::Seal => measure(
            reps,
            || {
                let mut rng = rng();
                let key = kahe_keygen(&mut rng, pp);
                let shares = shamir_share(&mut rng, pp, &key);
                let (_, openings) = cs_commit(&mut rng, pp, &shares);
                (rng, openings, seal_keys())
            },
            |(rng, openings, servers), _| {
                seal_openings(rng, pp, &SESSION, ClientId(0), openings, servers)
            },
        ),
        ClientPhase::RsDgtEmbed => measure(
            reps,
            || {
                let mut rng = rng();
                let key = kahe_keygen(&mut rng, pp);
                (rng, key, message_for(ch, pp))
            },
            |(rng, key, msg), _| Kahe::enc_ntt(rng, &pp.kahe, key, msg),
        ),
        ClientPhase::RsEnc => measure(
            reps,
            || embedded_ciphertext_for(ch, pp),
            |embedded, _| Rs::encode(pp.rs.as_ref().unwrap(), embedded),
        ),
        ClientPhase::RsShareCommit => measure(
            reps,
            || rs_shares_for(ch, pp),
            |shares, _| commit_shares(pp.share_comm.as_ref().unwrap(), shares),
        ),
        ClientPhase::RsClientSign => measure(
            reps,
            || {
                let mut rng = rng();
                let key = SigningKey::generate(&mut rng);
                let kahe_key = kahe_keygen(&mut rng, pp);
                let shares = shamir_share(&mut rng, pp, &kahe_key);
                let (comm, _) = cs_commit(&mut rng, pp, &shares);
                let rs_shares = rs_shares_for(ch, pp);
                let (share_root, _) = commit_shares(pp.share_comm.as_ref().unwrap(), &rs_shares);
                let bytes =
                    RsClientBulletinEntry::signing_bytes(&SESSION, ClientId(0), &comm, &share_root);
                (key, bytes)
            },
            |(key, bytes), _| key.sign(bytes),
        ),
    }
}

/// One untimed warmup, then one timing per requested rep. The spread shows the
/// noise in the same shape `scaling_bench` reports.
fn measure<S, R, F>(reps: usize, setup: impl Fn() -> S, mut op: F) -> Vec<u64>
where
    F: FnMut(&mut S, u64) -> R,
{
    let mut state = setup();
    drop(op(&mut state, 0));
    let mut times = Vec::with_capacity(reps);
    let mut keep = None;
    for rep in 0..reps {
        let start = Instant::now();
        let out = op(&mut state, rep as u64 + 1);
        times.push(start.elapsed().as_nanos() as u64);
        // Assigned after the clock stops: dropping the previous rep's output
        // must not land inside the window.
        keep = Some(out);
    }
    drop(keep);
    times
}

/// Setup is seconds at this cell, and every phase needs the same parameters, so
/// it is paid once per process. `panetiere_setup` times it separately.
static PARAMS: Lazy<(ChannelParams, Arc<ProtocolParams>)> =
    Lazy::new(|| params_for(&panetiere_config(), SERVERS));
static MSE_PARAMS: Lazy<(ChannelParams, Arc<ProtocolParams>)> =
    Lazy::new(|| params_for(&mse_panetiere_config(), SERVERS));
static SMOKE_PRONY_PARAMS: Lazy<(ChannelParams, Arc<ProtocolParams>)> = Lazy::new(|| {
    params_for(
        &panetiere_config_for(Encoding::Prony, SMOKE_SERVERS, SMOKE_CLIENTS),
        SMOKE_SERVERS,
    )
});
static SMOKE_MSE_PARAMS: Lazy<(ChannelParams, Arc<ProtocolParams>)> = Lazy::new(|| {
    params_for(
        &panetiere_config_for(Encoding::Mse, SMOKE_SERVERS, SMOKE_CLIENTS),
        SMOKE_SERVERS,
    )
});

fn channel_params() -> &'static ChannelParams {
    &PARAMS.0
}

fn protocol_params() -> &'static ProtocolParams {
    &PARAMS.1
}

fn mse_channel_params() -> &'static ChannelParams {
    &MSE_PARAMS.0
}

fn mse_protocol_params() -> &'static ProtocolParams {
    &MSE_PARAMS.1
}

fn smoke_prony_channel_params() -> &'static ChannelParams {
    &SMOKE_PRONY_PARAMS.0
}

fn smoke_mse_channel_params() -> &'static ChannelParams {
    &SMOKE_MSE_PARAMS.0
}

fn smoke_prony_protocol_params() -> &'static ProtocolParams {
    &SMOKE_PRONY_PARAMS.1
}

fn smoke_mse_protocol_params() -> &'static ProtocolParams {
    &SMOKE_MSE_PARAMS.1
}

fn rng() -> ChaCha20Rng {
    ChaCha20Rng::from_seed(SEED)
}

/// A full-width symbol payload, as the host sweep's non-scheduled flow builds.
fn symbols_for(ch: &ChannelParams) -> Vec<i64> {
    (0..ch.payload_symbols()).map(|j| j as i64 + 1).collect()
}

/// One encoded message, padded to the KAHE plaintext width.
fn message_for(ch: &ChannelParams, pp: &ProtocolParams) -> <Kahe as KaheScheme>::Message {
    let mut polys = channel::encode_symbols(&mut rng(), ch, &symbols_for(ch));
    polys.resize(message_polys(pp), Default::default());
    polys
}

fn embedded_ciphertext_for(ch: &ChannelParams, pp: &ProtocolParams) -> Vec<panetiere::RsNTTPoly> {
    let mut rng = rng();
    let key = kahe_keygen(&mut rng, pp);
    Kahe::enc_ntt(&mut rng, &pp.kahe, &key, &message_for(ch, pp))
}

fn rs_shares_for(ch: &ChannelParams, pp: &ProtocolParams) -> Vec<panetiere::rs::Share> {
    Rs::encode(pp.rs.as_ref().unwrap(), &embedded_ciphertext_for(ch, pp))
}

#[uniffi::export]
pub fn bench_report_csv(
    results: Vec<BenchResult>,
    env: String,
    device: String,
    os: String,
    build: String,
) -> String {
    report_csv(results, env, device, os, build, "benchmark")
}

#[uniffi::export]
pub fn smoke_report_csv(
    results: Vec<BenchResult>,
    env: String,
    device: String,
    os: String,
    build: String,
) -> String {
    report_csv(results, env, device, os, build, "smoke")
}

#[uniffi::export]
pub fn core_sweep_report_csv(
    results: Vec<BenchResult>,
    env: String,
    device: String,
    os: String,
    build: String,
) -> String {
    report_csv(results, env, device, os, build, "core-sweep")
}

fn report_csv(
    results: Vec<BenchResult>,
    env: String,
    device: String,
    os: String,
    build: String,
    mode: &str,
) -> String {
    let smoke = mode == "smoke";
    let profile = if cfg!(debug_assertions) {
        "debug"
    } else {
        "release"
    };
    let mut out = String::from(
        "mode,env,device,os,build,profile,panetiere_rev,anymone_rev,warmups,s,rho,active,cover,flow,payload_client_b,delta,xi,n_polys,mu_kahe,iblt_cells,rs_k,rs_n,m_threads,m_affinity,name,reps,median_ns,min_ns,max_ns\n",
    );
    for r in results {
        let mse = r.name.contains("_mse_");
        let (ch, pp, servers, clients) = if smoke && mse {
            (
                smoke_mse_channel_params(),
                smoke_mse_protocol_params(),
                SMOKE_SERVERS,
                SMOKE_CLIENTS,
            )
        } else if smoke {
            (
                smoke_prony_channel_params(),
                smoke_prony_protocol_params(),
                SMOKE_SERVERS,
                SMOKE_CLIENTS,
            )
        } else if mse {
            (
                mse_channel_params(),
                mse_protocol_params(),
                SERVERS,
                CLIENTS,
            )
        } else {
            (channel_params(), protocol_params(), SERVERS, CLIENTS)
        };
        let (flow, delta, iblt_cells) = match ch {
            ChannelParams::Mse(p) => ("mse", p.delta, p.total_cells()),
            ChannelParams::Prony(p) => ("prony", p.cols(), p.cols()),
        };
        let rs = pp.rs.as_ref().unwrap();
        let warmups = usize::from(!smoke);
        let common = format!(
            "{mode},{},{},{},{},{profile},{PANETIERE_REV},{ANYMONE_REV},{warmups},{servers},{clients},{clients},0,{flow},{},{},{},{},{},{iblt_cells},{},{},{},{}",
            csv_field(&env),
            csv_field(&device),
            csv_field(&os),
            csv_field(&build),
            ch.payload_symbols() * ch.bits_per_symbol() / 8,
            delta,
            ch.payload_symbols(),
            message_polys(pp),
            message_polys(pp),
            rs.k,
            rs.n,
            r.threads,
            csv_field(&r.affinity),
        );
        out.push_str(&format!(
            "{common},{},{},{},{},{}\n",
            r.name, r.reps, r.median_ns, r.min_ns, r.max_ns
        ));
    }
    out
}

fn csv_field(value: &str) -> String {
    value.replace([',', '\n', '\r'], " ")
}

fn panetiere_config() -> PanetiereConfig {
    panetiere_config_for(Encoding::Prony, SERVERS, CLIENTS)
}

fn mse_panetiere_config() -> PanetiereConfig {
    panetiere_config_for(Encoding::Mse, SERVERS, CLIENTS)
}

fn panetiere_config_for(encoding: Encoding, servers: usize, clients: u32) -> PanetiereConfig {
    PanetiereConfig {
        round_duration_ms: 4_000,
        message_size: MESSAGE_BYTES,
        estimated_messages: clients,
        client_set_min: 0,
        client_set_max: clients,
        threshold: (servers as u32 / 2 + 1).max(servers as u32 - 2),
        encoding,
        ..PanetiereConfig::default()
    }
}

fn seal_keys() -> Vec<(PanetiereServerId, pke::PublicKey)> {
    seal_keys_for(SERVERS)
}

fn seal_keys_for(servers: usize) -> Vec<(PanetiereServerId, pke::PublicKey)> {
    (0..servers)
        .map(|i| {
            let seal = Identity::generate()
                .exchange_keys()
                .to_seal_key()
                .expect("seal key decodes");
            (PanetiereServerId(i as u32), seal)
        })
        .collect()
}

/// KAHE encryption, Reed-Solomon lanes, one ML-KEM seal per relay, and the
/// per-message signatures — the whole per-round client cost.
fn panetiere_session() -> PanetiereClientSession {
    panetiere_session_for(&PARAMS, SERVERS)
}

fn smoke_prony_session() -> PanetiereClientSession {
    panetiere_session_for(&SMOKE_PRONY_PARAMS, SMOKE_SERVERS)
}

fn smoke_mse_session() -> PanetiereClientSession {
    panetiere_session_for(&SMOKE_MSE_PARAMS, SMOKE_SERVERS)
}

fn panetiere_session_for(
    params: &(ChannelParams, Arc<ProtocolParams>),
    servers: usize,
) -> PanetiereClientSession {
    PanetiereClientSession::new(
        params.1.clone(),
        params.0.clone(),
        Identity::generate(),
        seal_keys_for(servers),
        SEED,
    )
}

/// ECDH-derived keystreams plus the IBLT contribution.
fn adcnet_session() -> AdcnetClientSession {
    let identity = Identity::generate();
    let secrets: HashMap<ServerId, _> = (0..SERVERS)
        .map(|i| {
            let relay = Identity::generate().exchange_pubkey();
            (ServerId(i as u32), identity.exchange().ecdh(&relay))
        })
        .collect();
    AdcnetClientSession::new(
        OneRoundConfig {
            iblt: IbltMsgParamsOwned {
                estimated_messages: CLIENTS,
                max_payload_bytes: MESSAGE_BYTES,
            },
        },
        identity.to_adcnet_signing_key(),
        secrets,
        identity.exchange_pubkey(),
        SEED,
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Every advertised name runs and reports a non-zero cost. One rep each:
    /// this cell is the host sweep's, not a toy, so a full run is slow.
    #[test]
    fn all_benches_run() {
        for name in bench_names() {
            let r = run_bench(name.clone(), 1, BENCH_THREADS).expect("bench runs");
            assert_eq!(r.name, name);
            assert!(r.min_ns > 0, "{name} reported no time");
            assert!(r.min_ns <= r.median_ns && r.median_ns <= r.max_ns);
            assert!(bench_reps(name) > 0);
        }
    }

    /// Pins the cell. ξ counts 4-byte symbols here, while the sweep's own label
    /// divides by the full 36-bit symbol width — so the same payload reads as a
    /// different ξ on each side.
    #[test]
    fn the_cell_matches_the_host_sweep() {
        let (ch, pp) = params_for(&panetiere_config(), SERVERS);
        assert_eq!(ch.max_payload_bytes(), MESSAGE_BYTES);
        assert_eq!(ch.payload_symbols(), MESSAGE_BYTES / 4);
        assert_eq!(pp.shamir.n, SERVERS);
    }

    /// The client role is the sum of its phases, and nothing else.
    #[test]
    fn client_role_sums_only_the_phase_medians() {
        let row = |name: &str, ns: u64| BenchResult {
            name: name.into(),
            reps: 1,
            threads: 4,
            affinity: "0;1;2;3".into(),
            median_ns: ns,
            min_ns: ns,
            max_ns: ns,
        };
        let rows = vec![
            row(ENC_APP, 1),
            row(KAHE_KEYGEN, 2),
            row(KAHE_ENC, 4),
            row(SHARE, 8),
            row(CS_COMMIT, 16),
            row(SEAL, 32),
            row(RS_DGT_EMBED, 64),
            row(RS_ENC, 128),
            row(RS_SHARE_COMMIT, 256),
            row(RS_CLIENT_SIGN, 512),
            row(ANYMONE_PANETIERE_ROUND, 1_000),
            row(PANETIERE_SETUP, 1_000),
        ];
        assert_eq!(client_role_median_ns(rows), 1_019);
    }

    #[test]
    fn advertises_prony_client_phases_and_mse_encoding() {
        let names = bench_names();
        for name in CLIENT_ROLE {
            assert!(names.iter().any(|candidate| candidate == name));
        }
        assert!(names.iter().any(|candidate| candidate == KAHE_ENC));
        assert!(names.iter().any(|candidate| candidate == MSE_ENC_APP));
    }

    #[test]
    fn client_total_excludes_mse_microbenchmark() {
        let row = |name: &str, ns: u64| BenchResult {
            name: name.into(),
            reps: 1,
            threads: 4,
            affinity: "0;1;2;3".into(),
            median_ns: ns,
            min_ns: ns,
            max_ns: ns,
        };
        let rows = vec![row(ENC_APP, 3), row(MSE_ENC_APP, 5)];
        assert_eq!(client_role_median_ns(rows), 3);
    }

    #[test]
    fn report_keeps_prony_and_mse_as_separate_cells() {
        let row = |name: &str| BenchResult {
            name: name.into(),
            reps: 1,
            threads: 4,
            affinity: "0;1;2;3".into(),
            median_ns: 3,
            min_ns: 2,
            max_ns: 4,
        };
        let csv = bench_report_csv(
            vec![row(ENC_APP), row(MSE_ENC_APP)],
            "android".into(),
            "device".into(),
            "os".into(),
            "build".into(),
        );
        let mut lines = csv.lines();
        let header: Vec<_> = lines.next().unwrap().split(',').collect();
        let flow = header.iter().position(|name| *name == "flow").unwrap();
        let rows: Vec<Vec<_>> = lines.map(|line| line.split(',').collect()).collect();
        assert_eq!(rows[0][flow], "prony");
        assert_eq!(rows[1][flow], "mse");
    }

    #[test]
    fn smoke_report_is_marked_and_uses_4_by_10_cell() {
        let result = BenchResult {
            name: SMOKE_MSE_ROUND.into(),
            reps: 1,
            threads: 1,
            affinity: "0".into(),
            median_ns: 3,
            min_ns: 2,
            max_ns: 4,
        };
        let csv = smoke_report_csv(
            vec![result],
            "android".into(),
            "emulator".into(),
            "os".into(),
            "build".into(),
        );
        let mut lines = csv.lines();
        let header: Vec<_> = lines.next().unwrap().split(',').collect();
        let row: Vec<_> = lines.next().unwrap().split(',').collect();
        let value = |name| row[header.iter().position(|column| *column == name).unwrap()];
        assert_eq!(value("mode"), "smoke");
        assert_eq!(value("s"), "4");
        assert_eq!(value("rho"), "10");
        assert_eq!(value("active"), "10");
        assert_eq!(value("flow"), "mse");
        assert_eq!(value("warmups"), "0");
    }

    #[test]
    fn unknown_bench_is_an_error() {
        assert!(matches!(
            run_bench("nope".into(), 1, BENCH_THREADS),
            Err(AnymoneError::UnknownBench(_))
        ));
    }
}
