import AnymoneKit
import SwiftUI

/// The first thing to measure on a handset: whether a client's per-round crypto
/// fits the round budget. Needs no network and no accounts.
struct BenchmarkView: View {
    @State private var results: [BenchResult] = []
    @State private var running: String?

    /// Committee default `public_round_ms`, which is what the client round has
    /// to fit inside.
    private let roundBudgetNs: UInt64 = 4_000_000_000

    var body: some View {
        SectionLabel(index: "01", title: "bench", trailing: "client hot paths")

        Text("Times what a client actually runs each round: KAHE encryption, the coded lanes, one ML-KEM seal per relay, signatures.")
            .font(.mono(11))
            .lineSpacing(4)
            .foregroundStyle(Ink.fog)

        Button(running.map { "running \($0)" } ?? "run all") {
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
            if let round = results.first(where: { $0.name == "panetiere_client_round" }) {
                Text(verdict(round))
                    .font(.mono(11))
                    .lineSpacing(4)
                    .foregroundStyle(round.medianNs < roundBudgetNs ? Ink.lichen : Ink.ember)
            }
            ShareLink(item: report) { Text("export") }
                .buttonStyle(HouseButton(outline: true))
        }
    }

    private func runAll() async {
        results = []
        for name in benchNames() {
            running = name
            // Off the main actor: each bench is CPU-bound for up to seconds.
            let r = await Task.detached(priority: .userInitiated) {
                try? runBench(name: name, reps: benchReps(name: name))
            }.value
            if let r { results.append(r) }
        }
        running = nil
    }

    private func accent(for r: BenchResult) -> Color {
        guard r.name == "panetiere_client_round" else { return Ink.moon }
        return r.medianNs < roundBudgetNs ? Ink.moon : Ink.ember
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
        let rows = results.map { "\($0.name),\($0.reps),\($0.medianNs),\($0.minNs),\($0.maxNs)" }
            .joined(separator: "\n")
        return "device,\(UIDevice.current.model)\nname,reps,median_ns,min_ns,max_ns\n\(rows)"
    }
}
