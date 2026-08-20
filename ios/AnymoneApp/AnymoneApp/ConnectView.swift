import AnymoneKit
import SwiftUI

/// Joins a broadcast room over the client plane. The config's
/// stream_bootstrappers must be reachable from the phone, so a dev network on a
/// laptop needs LAN addresses rather than 127.0.0.1.
struct ConnectView: View {
    @EnvironmentObject private var session: Session
    @AppStorage("client_toml") private var configToml = bundledConfig()
    @AppStorage("tag") private var tag = "anymone.chat"
    @State private var draft = ""

    var body: some View {
        SectionLabel(index: "01", title: "room", trailing: session.running ? "joined" : "not started")

        if !session.running {
            Text("SERVICE TAG").font(.mono(10, .bold)).tracking(1.4).foregroundStyle(Ink.lichen)
            HouseField(placeholder: "anymone.chat", text: $tag)

            Text("CLIENT CONFIG").font(.mono(10, .bold)).tracking(1.4).foregroundStyle(Ink.lichen)
            TextEditor(text: $configToml)
                .font(.mono(10))
                .foregroundStyle(Ink.paper)
                .scrollContentBackground(.hidden)
                .background(Ink.canopy.opacity(0.55))
                .frame(height: 190)
                .overlay(Rectangle().stroke(Ink.line, lineWidth: 1))

            Button("start") {
                Task { await session.start(configToml: configToml, tag: tag, attested: false) }
            }
            .buttonStyle(HouseButton())
        } else {
            VStack(spacing: 0) {
                Hairline()
                ForEach(session.messages) { m in
                    VStack(spacing: 0) {
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text(m.ownEcho ? "SENT ✓" : "r\(m.round)")
                                .font(.mono(9, .bold))
                                .tracking(1.2)
                                .foregroundStyle(m.ownEcho ? Ink.lichen : Ink.fog)
                                .frame(width: 58, alignment: .leading)
                            Text(m.text).font(.mono(12)).foregroundStyle(Ink.paper)
                            Spacer(minLength: 0)
                        }
                        .padding(.vertical, 9)
                        Hairline()
                    }
                }
                if session.messages.isEmpty {
                    Row(key: "no rounds decoded yet", value: "—", accent: Ink.fog)
                    Hairline()
                }
            }

            HStack(spacing: 10) {
                HouseField(placeholder: "message", text: $draft)
                Button("send") {
                    let text = draft
                    draft = ""
                    Task { await session.send(text) }
                }
                .buttonStyle(HouseButton())
                .frame(width: 96)
                .disabled(draft.isEmpty || draft.utf8.count > Int(session.maxPayload))
            }

            Button("stop") { session.stop() }
                .buttonStyle(HouseButton(outline: true))
        }

        SectionLabel(index: "02", title: "state")
        VStack(spacing: 0) {
            Hairline()
            Row(key: "status", value: session.status, accent: Ink.paper)
            Hairline()
            Row(key: "round", value: session.roundMs == 0 ? "—" : "\(session.roundMs) ms")
            Hairline()
            Row(key: "max payload", value: session.maxPayload == 0 ? "—" : "\(session.maxPayload) B")
            Hairline()
            Row(
                key: "queued",
                value: "\(session.queued) rounds",
                accent: session.queued > 0 ? Ink.ember : Ink.moon)
            Hairline()
        }
    }
}

func bundledConfig() -> String {
    guard let url = Bundle.main.url(forResource: "client", withExtension: "toml"),
        let text = try? String(contentsOf: url)
    else {
        return """
            # Copy from anymone's deploy/local/configs/client.toml, with the
            # relay addresses rewritten to the dev machine's LAN IP.
            [network]
            stream_bootstrappers = ["ed25519:<hex>@192.168.1.10:7620"]

            [governance]
            threshold = 2
            """
    }
    return text
}
