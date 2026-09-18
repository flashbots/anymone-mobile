import AnymoneKit
import Darwin
import SwiftUI
import UIKit

@MainActor
final class RemoteClientSessionModel: NSObject, ObservableObject, NetServiceDelegate {
    @Published var address = ""
    @Published var status = "Stopped"
    @Published var activity = "Session is not running"
    @Published var issue: String?
    @Published var connected = false
    @Published var participant = ""
    @Published var protocolName = ""
    @Published var currentRound: UInt64?
    @Published var requestsProcessed: UInt64 = 0
    @Published var pendingMessages: UInt64?
    @Published var pairing = ""
    @Published var pairingCode = ""
    @Published var running = false
    @Published var starting = false
    @Published var discovery = "not advertised"

    private var host: RemoteProtocolHost?
    private var service: NetService?
    private var poll: Task<Void, Never>?
    private var generation = 0

    func refreshAddress() {
        guard !running && !starting else { return }
        var interfaces: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaces) == 0 else { return }
        defer { freeifaddrs(interfaces) }
        var cursor = interfaces
        var candidates: [(String, String)] = []
        while let current = cursor {
            defer { cursor = current.pointee.ifa_next }
            guard let socket = current.pointee.ifa_addr,
                socket.pointee.sa_family == UInt8(AF_INET),
                current.pointee.ifa_flags & UInt32(IFF_UP) != 0,
                current.pointee.ifa_flags & UInt32(IFF_LOOPBACK) == 0
            else { continue }
            var name = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(socket, socklen_t(socket.pointee.sa_len),
                           &name, socklen_t(name.count), nil, 0, NI_NUMERICHOST) == 0 {
                candidates.append((String(cString: current.pointee.ifa_name), String(cString: name)))
            }
        }
        address = candidates.first(where: { $0.0 == "en0" })?.1 ?? candidates.first?.1 ?? ""
    }

    func start() async {
        guard !running && !starting else { return }
        generation += 1
        let attempt = generation
        starting = true
        status = "Starting"
        activity = "Starting developer host"
        issue = nil
        do {
            let created = try await RemoteProtocolHost.startDeveloper(
                listenAddress: "0.0.0.0:0")
            guard generation == attempt else { await created.stop(); return }
            host = created
            let rawPairing = try created.pairingJson()
            pairingCode = try created.pairingCode()
            let data = Data(rawPairing.utf8)
            guard var info = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let bound = info["address"] as? String,
                  let port = bound.split(separator: ":").last.flatMap({ Int32($0) })
            else { throw RemoteScreenError.badPairing }
            let endpoint = "\(address):\(port)"
            info["address"] = endpoint
            pairing = String(data: try JSONSerialization.data(withJSONObject: info), encoding: .utf8)
                ?? { throw RemoteScreenError.badPairing }()
            let advertised = NetService(
                domain: "local.", type: "_anymone-remote._tcp.",
                name: "Anymone-" + String(UUID().uuidString.prefix(8)), port: port)
            advertised.delegate = self
            advertised.setTXTRecord(NetService.data(fromTXTRecord: [
                "pairing": Data("code".utf8),
                "address": Data(address.utf8),
            ]))
            service = advertised
            discovery = "advertising"
            advertised.publish()
            running = true
            starting = false
            status = "Waiting"
            activity = "Waiting for desktop"
            UIApplication.shared.isIdleTimerDisabled = true
            poll = Task {
                while !Task.isCancelled {
                    do {
                        let state = try await created.statusJson()
                        guard generation == attempt else { return }
                        if let value = try JSONSerialization.jsonObject(with: Data(state.utf8)) as? [String: Any] {
                            if value["closed"] as? Bool == true { await stop(); return }
                            let paired = value["paired"] as? Bool == true
                            let attempts = (value["pairing_attempts_remaining"] as? NSNumber)?.intValue ?? 0
                            if paired || attempts == 0 { pairingCode = "" }
                            connected = value["connected"] as? Bool == true
                            activity = value["last_activity"] as? String ?? activity
                            if let error = value["last_error"] as? String { issue = error }
                            let client = value["client"] as? [String: Any]
                            participant = client?["participant"] as? String ?? ""
                            protocolName = client?["protocol"] as? String ?? ""
                            currentRound = (client?["current_round"] as? NSNumber)?.uint64Value
                            requestsProcessed = (value["next_request"] as? NSNumber)?.uint64Value ?? 0
                            pendingMessages = (client?["pending_messages"] as? NSNumber)?.uint64Value
                            status = connected ? "Connected" : paired ? "Disconnected" : "Waiting"
                            if !paired && attempts == 0 { status = "Pairing locked" }
                        }
                        try await Task.sleep(nanoseconds: 1_000_000_000)
                    } catch {
                        if !Task.isCancelled {
                            status = "Failed"
                            activity = "Could not read host status"
                            issue = String(describing: error)
                        }
                        return
                    }
                }
            }
        } catch {
            guard generation == attempt else { return }
            await stop()
            status = "Failed"
            activity = "Developer host did not start"
            issue = String(describing: error)
        }
    }

    func stop() async {
        generation += 1
        poll?.cancel()
        poll = nil
        service?.stop()
        service = nil
        discovery = "not advertised"
        let previous = host
        host = nil
        pairing = ""
        pairingCode = ""
        participant = ""
        protocolName = ""
        currentRound = nil
        requestsProcessed = 0
        pendingMessages = nil
        connected = false
        running = false
        starting = false
        UIApplication.shared.isIdleTimerDisabled = false
        status = "Stopped"
        activity = "Session stopped"
        issue = nil
        await previous?.stop()
    }

    func netServiceDidPublish(_ sender: NetService) {
        guard sender === service else { return }
        discovery = sender.name
    }

    func netService(_ sender: NetService, didNotPublish errorDict: [String: NSNumber]) {
        guard sender === service else { return }
        discovery = "discovery failed \(errorDict); use the IP address"
        issue = discovery
    }
}

private enum RemoteScreenError: Error { case badPairing }

struct RemoteSessionView: View {
    @EnvironmentObject private var remote: RemoteClientSessionModel

    var body: some View {
        SectionLabel(index: "01", title: "remote", trailing: "developer keys")
        Text("Your computer controls the protocol client on this phone. Keep the app open while connected.")
            .font(.mono(11)).foregroundStyle(Ink.fog)
        if !remote.running && !remote.starting {
            HouseField(placeholder: "LAN IPv4 address", text: $remote.address)
            Button("refresh address") { remote.refreshAddress() }
                .buttonStyle(HouseButton(outline: true))
            Button("start developer host") { Task { await remote.start() } }
                .buttonStyle(HouseButton()).disabled(remote.address.isEmpty)
        } else {
            Button("stop") { Task { await remote.stop() } }
                .buttonStyle(HouseButton(outline: true))
        }
        Text("STATE  \(remote.status)").font(.mono(11)).foregroundStyle(Ink.paper).textSelection(.enabled)
        Text("ACTIVITY  \(remote.activity)").font(.mono(11)).foregroundStyle(Ink.moon).textSelection(.enabled)
        if let issue = remote.issue {
            Text("ISSUE  \(issue)").font(.mono(11)).foregroundStyle(Ink.ember).textSelection(.enabled)
        }
        if !remote.pairing.isEmpty,
           let data = remote.pairing.data(using: .utf8),
           let info = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let endpoint = info["address"] as? String {
            Text("DIRECT  --remote \(endpoint)").font(.mono(10)).foregroundStyle(Ink.fog).textSelection(.enabled)
        }
        if !remote.protocolName.isEmpty {
            Text("\(remote.protocolName) · round \(remote.currentRound ?? 0) · \(remote.requestsProcessed) requests · \(remote.pendingMessages ?? 0) pending")
                .font(.mono(10)).foregroundStyle(Ink.fog).textSelection(.enabled)
        }
        if !remote.participant.isEmpty {
            Text(remote.participant).font(.mono(10)).foregroundStyle(Ink.fog).textSelection(.enabled)
        }
        Text(remote.discovery).font(.mono(10)).foregroundStyle(Ink.fog)
        if !remote.pairingCode.isEmpty {
            Text("PAIRING CODE").font(.mono(10, .bold)).foregroundStyle(Ink.lichen)
            Text("\(remote.pairingCode.prefix(4)) \(remote.pairingCode.suffix(4))")
                .font(.mono(24, .bold)).foregroundStyle(Ink.moon)
                .accessibilityLabel("Pairing code " + remote.pairingCode.map { String($0) }.joined(separator: " "))
            Text("Select this phone on your computer and enter this code.")
                .font(.mono(11)).foregroundStyle(Ink.fog)
        }
        if !remote.pairing.isEmpty {
            DisclosureGroup("Automation") {
                ShareLink("share pairing data", item: remote.pairing).buttonStyle(HouseButton(outline: true))
                Text("For automated test drivers. Pairing data grants control of this host.")
                    .font(.mono(10)).foregroundStyle(Ink.fog)
            }
            .font(.mono(11)).foregroundStyle(Ink.fog)
        }
        Text("Developer mode uses software keys. Platform attestation is disabled.")
            .font(.mono(10)).foregroundStyle(Ink.lichen)
        .onAppear { if remote.address.isEmpty { remote.refreshAddress() } }
    }
}
