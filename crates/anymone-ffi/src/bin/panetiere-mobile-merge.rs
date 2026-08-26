use std::collections::HashMap;
use std::path::PathBuf;

const KEYS: &[&str] = &[
    "s",
    "rho",
    "active",
    "cover",
    "flow",
    "payload_client_b",
    "delta",
    "xi",
    "n_polys",
    "mu_kahe",
    "iblt_cells",
    "rs_k",
    "rs_n",
];

const PRONY_PHASES: &[(&str, &str)] = &[
    ("panetiere_enc_app", "enc_app"),
    ("panetiere_kahe_keygen", "kahe_keygen"),
    ("panetiere_kahe_enc", "kahe_enc"),
    ("panetiere_share", "share"),
    ("panetiere_cs_commit", "cs_commit"),
    ("panetiere_seal", "seal"),
    ("panetiere_rs_dgt_embed", "rs_dgt_embed"),
    ("panetiere_rs_enc", "rs_enc"),
    ("panetiere_rs_share_commit", "rs_share_commit"),
    ("panetiere_rs_client_sign", "rs_client_sign"),
];

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let [mobile_path, host_path, out_path] = args.as_slice() else {
        eprintln!("usage: panetiere-mobile-merge <mobile.csv> <host.csv> <out.csv>");
        std::process::exit(2);
    };
    if let Err(e) = run(mobile_path, host_path, out_path) {
        eprintln!("{e}");
        std::process::exit(1);
    }
}

fn run(mobile_path: &str, host_path: &str, out_path: &str) -> Result<(), String> {
    let mobile = table(mobile_path)?;
    let host_text = std::fs::read_to_string(host_path).map_err(|e| format!("{host_path}: {e}"))?;
    let mut host_lines = host_text.lines();
    let host_header_line = host_lines
        .next()
        .ok_or_else(|| format!("{host_path}: empty csv"))?;
    let host_header: Vec<&str> = host_header_line.split(',').collect();
    let host_index = index(&host_header);
    let mobile_index = index(&mobile.header);
    if mobile.rows.is_empty() {
        return Err(format!("{mobile_path}: no benchmark rows"));
    }

    for key in KEYS {
        required(&mobile_index, key)?;
        required(&host_index, key)?;
    }
    for key in [
        "mode",
        "env",
        "device",
        "m_threads",
        "m_affinity",
        "name",
        "median_ns",
        "min_ns",
        "max_ns",
    ] {
        required(&mobile_index, key)?;
    }
    if mobile
        .rows
        .iter()
        .any(|row| field(row, &mobile_index, "mode").ok() != Some("benchmark"))
    {
        return Err(format!("{mobile_path}: smoke results cannot be merged"));
    }

    let mobile_cells: std::collections::HashSet<String> = mobile
        .rows
        .iter()
        .filter(|row| merge_phase(row, &mobile_index))
        .map(|row| cell_key(row, &mobile_index))
        .collect::<Result<_, _>>()?;

    let mut output = String::from(host_header_line);
    output.push('\n');
    let mut matched_cells = std::collections::HashSet::new();
    for line in host_lines.filter(|line| !line.trim().is_empty()) {
        let mut row: Vec<String> = line.split(',').map(str::to_string).collect();
        let matching: Vec<&Vec<String>> = mobile
            .rows
            .iter()
            .filter(|mobile_row| {
                merge_phase(mobile_row, &mobile_index)
                    && KEYS.iter().all(|key| {
                        field(&row, &host_index, key).ok()
                            == field(mobile_row, &mobile_index, key).ok()
                    })
            })
            .collect();
        if let Some(first) = matching.first().copied() {
            let phases = PRONY_PHASES;
            let mut timings: HashMap<&str, (&str, &str, &str)> = HashMap::new();
            for mobile_row in matching {
                let name = field(mobile_row, &mobile_index, "name")?;
                if let Some((_, phase)) =
                    phases.iter().find(|(mobile_name, _)| *mobile_name == name)
                {
                    timings.insert(
                        phase,
                        (
                            field(mobile_row, &mobile_index, "median_ns")?,
                            field(mobile_row, &mobile_index, "min_ns")?,
                            field(mobile_row, &mobile_index, "max_ns")?,
                        ),
                    );
                }
            }
            for (_, phase) in phases {
                if !timings.contains_key(phase) {
                    return Err(format!(
                        "{mobile_path}: missing {phase} for {}",
                        cell_key(first, &mobile_index)?
                    ));
                }
            }
            let key = cell_key(first, &mobile_index)?;
            if !matched_cells.insert(key.clone()) {
                return Err(format!("host csv has multiple rows for mobile cell {key}"));
            }
            let env = format!(
                "{}-{}-t{}-cpu{}+{}",
                field(first, &mobile_index, "env")?,
                field(first, &mobile_index, "device")?.replace(' ', "-"),
                field(first, &mobile_index, "m_threads")?,
                field(first, &mobile_index, "m_affinity")?,
                field(&row, &host_index, "env")?,
            );
            set(&mut row, &host_index, "env", env)?;
            for (_, phase) in phases {
                let (med, min, max) = timings[phase];
                for (stat, ns) in [("med", med), ("min", min), ("max", max)] {
                    let us = ns
                        .parse::<f64>()
                        .map_err(|_| format!("{mobile_path}: bad {phase} {stat}: {ns}"))?
                        / 1_000.0;
                    set(
                        &mut row,
                        &host_index,
                        &format!("m_{phase}_us_{stat}"),
                        format!("{us:.3}"),
                    )?;
                }
            }
        }
        output.push_str(&row.join(","));
        output.push('\n');
    }
    if matched_cells != mobile_cells {
        let missing: Vec<_> = mobile_cells.difference(&matched_cells).collect();
        return Err(format!("host csv has no row for mobile cells: {missing:?}"));
    }

    let mut raw = PathBuf::from(out_path);
    raw.set_extension("mobile-raw.csv");
    std::fs::write(&raw, output).map_err(|e| format!("{}: {e}", raw.display()))?;
    panetiere::scaling_bench::recompute(raw.to_str().ok_or("non-UTF-8 output path")?, out_path);
    std::fs::remove_file(&raw).map_err(|e| format!("{}: {e}", raw.display()))?;
    println!("merged mobile client timings into {out_path}");
    Ok(())
}

struct Table {
    header: Vec<String>,
    rows: Vec<Vec<String>>,
}

fn table(path: &str) -> Result<Table, String> {
    let text = std::fs::read_to_string(path).map_err(|e| format!("{path}: {e}"))?;
    let mut lines = text.lines();
    let header = lines
        .next()
        .ok_or_else(|| format!("{path}: empty csv"))?
        .split(',')
        .map(str::to_string)
        .collect();
    let rows = lines
        .filter(|line| !line.trim().is_empty())
        .map(|line| line.split(',').map(str::to_string).collect())
        .collect();
    Ok(Table { header, rows })
}

fn index<T: AsRef<str>>(header: &[T]) -> HashMap<&str, usize> {
    header
        .iter()
        .enumerate()
        .map(|(i, name)| (name.as_ref(), i))
        .collect()
}

fn required(index: &HashMap<&str, usize>, name: &str) -> Result<(), String> {
    index
        .contains_key(name)
        .then_some(())
        .ok_or_else(|| format!("missing csv column {name}"))
}

fn cell_key(row: &[String], index: &HashMap<&str, usize>) -> Result<String, String> {
    KEYS.iter()
        .map(|key| field(row, index, key))
        .collect::<Result<Vec<_>, _>>()
        .map(|parts| parts.join("/"))
}

fn merge_phase(row: &[String], index: &HashMap<&str, usize>) -> bool {
    field(row, index, "name").ok().is_some_and(|name| {
        PRONY_PHASES
            .iter()
            .any(|(mobile_name, _)| *mobile_name == name)
    })
}

fn field<'a>(
    row: &'a [String],
    index: &HashMap<&str, usize>,
    name: &str,
) -> Result<&'a str, String> {
    row.get(
        *index
            .get(name)
            .ok_or_else(|| format!("missing csv column {name}"))?,
    )
    .map(String::as_str)
    .ok_or_else(|| format!("short csv row at {name}"))
}

fn set(
    row: &mut [String],
    index: &HashMap<&str, usize>,
    name: &str,
    value: String,
) -> Result<(), String> {
    let i = *index
        .get(name)
        .ok_or_else(|| format!("host csv lacks {name}"))?;
    *row.get_mut(i)
        .ok_or_else(|| format!("short host csv row at {name}"))? = value;
    Ok(())
}
