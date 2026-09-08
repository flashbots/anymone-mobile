use anymone_bench::{core_sweep_report_csv, core_sweep_threads, run_core_bench};

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let [out] = args.as_slice() else {
        eprintln!("usage: panetiere-mobile-bench <out.csv>");
        std::process::exit(2);
    };
    let mut results = Vec::new();
    for threads in core_sweep_threads() {
        eprintln!("running Prony client round on {threads} core(s)");
        match run_core_bench(threads) {
            Ok(result) => results.push(result),
            Err(e) => {
                eprintln!("{e}");
                std::process::exit(1);
            }
        }
    }
    let report = core_sweep_report_csv(
        results,
        "desktop".into(),
        cpu_model(),
        os_name(),
        if cfg!(debug_assertions) {
            "native debug".into()
        } else {
            "native release".into()
        },
    );
    if let Err(e) = std::fs::write(out, report) {
        eprintln!("{out}: {e}");
        std::process::exit(1);
    }
    println!("csv: {out}");
}

fn cpu_model() -> String {
    std::fs::read_to_string("/proc/cpuinfo")
        .ok()
        .and_then(|text| {
            text.lines().find_map(|line| {
                line.split_once(':')
                    .filter(|(key, _)| matches!(key.trim(), "model name" | "Hardware"))
                    .map(|(_, value)| value.trim().to_string())
            })
        })
        .unwrap_or_else(|| "unknown CPU".into())
}

fn os_name() -> String {
    std::fs::read_to_string("/etc/os-release")
        .ok()
        .and_then(|text| {
            text.lines()
                .find_map(|line| line.strip_prefix("PRETTY_NAME="))
                .map(|value| value.trim_matches('"').to_string())
        })
        .unwrap_or_else(|| std::env::consts::OS.into())
}
