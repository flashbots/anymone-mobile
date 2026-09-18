import AnymoneKit
import SwiftUI

@main
struct AnymoneApp: App {
    @StateObject private var session = Session()
    @StateObject private var remote = RemoteClientSessionModel()
    @Environment(\.scenePhase) private var scenePhase
    @State private var tab = Tab.remote

    var body: some Scene {
        WindowGroup {
            Ground {
                VStack(spacing: 0) {
                    Brand()
                    Hairline()
                    ScrollView {
                        VStack(alignment: .leading, spacing: 22) {
                            switch tab {
                            case .bench: BenchmarkView()
                            case .room: ConnectView()
                            case .attest: AttestView()
                            case .remote: RemoteSessionView()
                            }
                        }
                        .padding(.horizontal, 20)
                        .padding(.vertical, 24)
                    }
                    Hairline()
                    TabStrip(tab: $tab)
                }
            }
            .environmentObject(session)
            .environmentObject(remote)
            .onChange(of: scenePhase) { phase in
                if phase == .background { Task { await remote.stop() } }
            }
            .preferredColorScheme(.dark)
        }
    }
}

enum Tab: String, CaseIterable {
    case bench, room, attest, remote
}

private struct Brand: View {
    var body: some View {
        HStack(spacing: 11) {
            Circle()
                .strokeBorder(Ink.moon, lineWidth: 1)
                .frame(width: 22, height: 22)
                .overlay(Circle().fill(Ink.moon).frame(width: 8, height: 8).offset(x: -2))
            VStack(alignment: .leading, spacing: 2) {
                Text("ANYMONE").font(.mono(12, .bold)).tracking(1.8).foregroundStyle(Ink.paper)
                Text("anonymous broadcast · handset client")
                    .font(.mono(8)).tracking(1.2).foregroundStyle(Ink.fog)
            }
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }
}

private struct TabStrip: View {
    @Binding var tab: Tab

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Tab.allCases, id: \.self) { item in
                let on = item == tab
                Button { tab = item } label: {
                    VStack(spacing: 8) {
                        Rectangle()
                            .fill(on ? Ink.moon : .clear)
                            .frame(height: 2)
                        Text(item.rawValue.uppercased())
                            .font(.mono(10, .bold))
                            .tracking(1.6)
                            .foregroundStyle(on ? Ink.moon : Ink.fog)
                        Spacer(minLength: 0)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 46)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if item != Tab.allCases.last {
                    Rectangle().fill(Ink.line).frame(width: 1, height: 46)
                }
            }
        }
        .background(Ink.night)
    }
}

struct Message: Identifiable {
    let id = UUID()
    let text: String
    let round: UInt64
    let ownEcho: Bool
}

/// Holds the one client the app runs, so the room and attestation screens act
/// on the same instance.
@MainActor
final class Session: ObservableObject {
    @Published var status = "idle"
    @Published var messages: [Message] = []
    @Published var roundMs: UInt64 = 0
    @Published var maxPayload: UInt64 = 0
    @Published var pubkey = ""
    @Published var attestation = "unattested"
    @Published var running = false

    private var client: AnymoneClient?
    private var pipe: AnymonePipe?
    private var pump: Task<Void, Never>?

    /// Transport state only — the identity lives in the Keychain. Excluded from
    /// backups so a restore cannot resurrect another device's session state.
    var dataDir: String {
        var dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("anymone")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var exclude = URLResourceValues()
        exclude.isExcludedFromBackup = true
        try? dir.setResourceValues(exclude)
        return dir.path
    }

    func start(configToml: String, tag: String, attested: Bool) async {
        guard !running else { return }
        running = true
        status = attested ? "attesting · awaiting signed config" : "awaiting signed config"
        do {
            let store = KeychainSecretStore()
            let client =
                attested
                ? try await AnymoneClient.startAttested(
                    configToml: configToml,
                    dataDir: dataDir,
                    store: store,
                    scheme: .appAttest,
                    fetcher: AppAttestFetcher())
                : try await AnymoneClient.start(
                    configToml: configToml, dataDir: dataDir, store: store)
            self.client = client
            roundMs = try client.roundDurationMs()
            maxPayload = try client.maxPayload()
            pubkey = try client.pubkey()
            refreshAttestation()

            status = "joining \(tag)"
            let pipe = try await client.subscribe(tag: tag, waitMs: 30_000)
            self.pipe = pipe
            status = "joined \(tag)"
            pump = Task { await self.receiveLoop(pipe) }
        } catch {
            status = "failed: \(error)"
            // Started but never subscribed: nothing else would stop it.
            client?.stop()
            client = nil
            running = false
        }
    }

    private func receiveLoop(_ pipe: AnymonePipe) async {
        while !Task.isCancelled {
            guard let msg = await pipe.recv() else { break }
            messages.append(
                Message(
                    text: String(decoding: msg.payload),
                    round: msg.round,
                    ownEcho: msg.ownEcho))
            refreshAttestation()
        }
    }

    func send(_ text: String) async {
        guard let pipe else { return }
        do {
            try await pipe.send(payload: Data(text.utf8))
            status = "queued · one message leaves per round"
        } catch {
            status = "send failed: \(error)"
        }
    }

    func stop() {
        pump?.cancel()
        pump = nil
        pipe = nil
        client?.stop()
        client = nil
        running = false
        status = "stopped"
    }

    func refreshAttestation() {
        guard let client else { return }
        switch client.attestationStatus() {
        case .unattested: attestation = "unattested · open subnets only"
        case .cold: attestation = "no token yet"
        case .pending(let round): attestation = "fetching for round \(round)"
        // Held locally; whether a relay accepted it is not visible from here.
        case .ready(let round, let bytes): attestation = "token held · round \(round) · \(bytes) B"
        case .failed(let detail): attestation = "failed: \(detail)"
        }
    }

    var queued: UInt64 { (try? client?.queuedOutbound()).flatMap { $0 } ?? 0 }
}

extension String {
    init(decoding bytes: Data) {
        self =
            String(data: bytes, encoding: .utf8)
            ?? bytes.map { String($0) }.joined(separator: " ")
    }
}
