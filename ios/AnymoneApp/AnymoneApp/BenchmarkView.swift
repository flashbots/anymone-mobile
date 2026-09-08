import AnymoneKit
import AnymoneBenchKit
import Darwin
import SwiftUI

private enum BenchmarkMode {
    case benchmark
    case coreSweep
    case smoke
}

/// The first thing to measure on a handset: whether a client's per-round crypto
/// fits the round budget. Needs no network and no accounts.
struct BenchmarkView: View {
    @State private var results: [BenchResult] = []
    @State private var running: String?
    @State private var mode = BenchmarkMode.benchmark

    /// Committee default `public_round_ms`, kept as the reference to report
    /// against.
    private let roundBudgetNs: UInt64 = 4_000_000_000
    /// Flagged only past this: a large cell legitimately runs far over the 4 s
    /// reference, and calling that a failure would hide the measurement.
    private let roundCeilingNs: UInt64 = 60_000_000_000
    private let roundBench = "anymone_panetiere_round"

    var body: some View {
        SectionLabel(index: "01", title: "bench", trailing: "client hot paths")

        Text(
            "panetiere_* mirror the host sweep's Prony direct and RS phases, plus MSE encoding: 8 servers, 50 messages a round, 1 KB payloads. anymone_* time a whole round as the client runs it, framing and signatures included."
        )
            .font(.mono(11))
            .lineSpacing(4)
            .foregroundStyle(Ink.fog)

        Button("smoke 4×10") {
            Task { await runSmokeAll() }
        }
        .buttonStyle(HouseButton(outline: true))
        .disabled(running != nil)

        Button("core sweep 1·2·4·8") {
            Task { await runCoreSweep() }
        }
        .buttonStyle(HouseButton(outline: true))
        .disabled(running != nil)

        Button(running.map { "running \($0)" } ?? "run all · \(benchThreads()) cores") {
            Task { await runAll() }
        }
        .buttonStyle(HouseButton())
        .disabled(running != nil)

        if !results.isEmpty {
            SectionLabel(index: "02", title: "results", trailing: "median ns per op")
            VStack(spacing: 0) {
                Hairline()
                ForEach(results, id: \.name) { r in
                    VStack(spacing: 0) {
                        Row(key: r.name, value: format(r.medianNs), accent: accent(for: r))
                        Row(
                            key: "  \(r.reps) reps",
                            value: "\(format(r.minNs)) – \(format(r.maxNs))",
                            accent: Ink.fog)
                        Hairline()
                    }
                }
            }
            if clientRoleMedianNs(results: results) > 0 {
                Row(
                    key: "panetiere prony client",
                    value: format(clientRoleMedianNs(results: results)),
                    accent: Ink.lichen)
                Hairline()
            }
            if let round = results.first(where: { $0.name == roundBench }) {
                Text(verdict(round))
                    .font(.mono(11))
                    .lineSpacing(4)
                    .foregroundStyle(round.medianNs < roundCeilingNs ? Ink.lichen : Ink.ember)
            }
            ShareLink(item: report) { Text("export") }
                .buttonStyle(HouseButton(outline: true))
        }
    }

    private func runAll() async {
        mode = .benchmark
        results = []
        for name in benchNames() {
            running = name
            // Off the main actor: each bench is CPU-bound for up to seconds.
            let r = await Task.detached(priority: .userInitiated) {
                try? runBench(name: name, reps: benchReps(name: name), threads: benchThreads())
            }.value
            if let r { results.append(r) }
        }
        running = nil
    }

    private func runSmokeAll() async {
        mode = .smoke
        results = []
        for name in smokeNames() {
            running = name
            let r = await Task.detached(priority: .userInitiated) {
                try? runSmoke(name: name)
            }.value
            if let r { results.append(r) }
        }
        running = nil
    }

    private func runCoreSweep() async {
        mode = .coreSweep
        results = []
        for threads in coreSweepThreads() {
            running = "\(threads) cores"
            let r = await Task.detached(priority: .userInitiated) {
                try? runCoreBench(threads: threads)
            }.value
            if let r { results.append(r) }
        }
        running = nil
    }

    private func accent(for r: BenchResult) -> Color {
        guard r.name == roundBench else { return Ink.moon }
        return r.medianNs < roundCeilingNs ? Ink.moon : Ink.ember
    }

    private func verdict(_ r: BenchResult) -> String {
        let share = Double(r.medianNs) / Double(roundBudgetNs) * 100
        return String(
            format: "a client round costs %.1f%% of the 4 s round budget on this device", share)
    }

    private func format(_ ns: UInt64) -> String {
        ns > 1_000_000
            ? String(format: "%.1f ms", Double(ns) / 1_000_000)
            : String(format: "%.0f µs", Double(ns) / 1_000)
    }

    private var report: String {
        let device = UIDevice.current
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let args = (
            results: results,
            env: "ios",
            device: hardwareModel(),
            os: "\(device.systemName) \(device.systemVersion)",
            build: "app \(version)")
        switch mode {
        case .smoke:
            return smokeReportCsv(
                results: args.results, env: args.env, device: args.device, os: args.os,
                build: args.build)
        case .coreSweep:
            return coreSweepReportCsv(
                results: args.results, env: args.env, device: args.device, os: args.os,
                build: args.build)
        case .benchmark:
            return benchReportCsv(
                results: args.results, env: args.env, device: args.device, os: args.os,
                build: args.build)
        }
    }

    private func hardwareModel() -> String {
        var size = 0
        sysctlbyname("hw.machine", nil, &size, nil, 0)
        var value = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.machine", &value, &size, nil, 0)
        return String(cString: value)
    }
}
