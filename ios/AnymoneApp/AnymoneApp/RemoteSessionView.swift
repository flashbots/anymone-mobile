import AnymoneKit
import Darwin
import SwiftUI
import UIKit

@MainActor
final class RemoteHostModel: NSObject, ObservableObject, NetServiceDelegate {
    @Published var address = ""
    @Published var status = "stopped"
    @Published var participant = ""
    @Published var pairing = ""
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
        status = "starting developer host"
        do {
            let created = try await RemoteProtocolHost.startDeveloper(
                listenAddress: "\(address):0")
            guard generation == attempt else { await created.stop(); return }
            host = created
            pairing = try created.pairingJson()
            let data = Data(pairing.utf8)
            let info = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            guard let endpoint = info?["address"] as? String,
                  let port = endpoint.split(separator: ":").last.flatMap({ Int32($0) })
            else { throw RemoteScreenError.badPairing }
            let advertised = NetService(
                domain: "local.", type: "_anymone-remote._tcp.",
                name: "Anymone-" + String(UUID().uuidString.prefix(8)), port: port)
            advertised.delegate = self
            let version = (info?["interface_version"] as? NSNumber)?.stringValue ?? ""
            advertised.setTXTRecord(NetService.data(fromTXTRecord: ["version": Data(version.utf8)]))
            service = advertised
            discovery = "advertising"
            advertised.publish()
            running = true
            starting = false
            status = endpoint
            UIApplication.shared.isIdleTimerDisabled = true
            poll = Task {
                while !Task.isCancelled {
                    do {
                        let state = try await created.statusJson()
                        guard generation == attempt else { return }
                        if let value = try JSONSerialization.jsonObject(with: Data(state.utf8)) as? [String: Any] {
                            if value["closed"] as? Bool == true { await stop(); return }
                            let client = value["client"] as? [String: Any]
                            participant = client?["participant"] as? String ?? ""
                            let round = client?["current_round"] as? NSNumber ?? 0
                            let request = value["next_request"] as? NSNumber ?? 0
                            status = client == nil ? "\(endpoint) · waiting for desktop configuration" : "\(endpoint) · round \(round) · requests \(request)"
                        }
                        try await Task.sleep(nanoseconds: 1_000_000_000)
                    } catch {
                        if !Task.isCancelled { status = "status failed: \(error)" }
                        return
                    }
                }
            }
        } catch {
            guard generation == attempt else { return }
            await stop()
            status = "failed: \(error)"
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
        participant = ""
        running = false
        starting = false
        UIApplication.shared.isIdleTimerDisabled = false
        status = "stopped"
        await previous?.stop()
    }

    func netServiceDidPublish(_ sender: NetService) {
        guard sender === service else { return }
        discovery = sender.name
    }

    func netService(_ sender: NetService, didNotPublish errorDict: [String: NSNumber]) {
        guard sender === service else { return }
        discovery = "discovery failed \(errorDict); use the IP address"
    }
}

private enum RemoteScreenError: Error { case badPairing }

struct RemoteSessionView: View {
    @EnvironmentObject private var remote: RemoteHostModel

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
        Text(remote.status).font(.mono(11)).foregroundStyle(Ink.paper).textSelection(.enabled)
        if !remote.participant.isEmpty {
            Text(remote.participant).font(.mono(10)).foregroundStyle(Ink.fog).textSelection(.enabled)
        }
        Text(remote.discovery).font(.mono(10)).foregroundStyle(Ink.fog)
        if !remote.pairing.isEmpty {
            ShareLink("share pairing data", item: remote.pairing).buttonStyle(HouseButton())
            Text("Pairing data grants control of this host. Share it with your computer.")
                .font(.mono(10)).foregroundStyle(Ink.fog)
        }
        Text("Developer mode uses software keys. Platform attestation is disabled.")
            .font(.mono(10)).foregroundStyle(Ink.lichen)
        .onAppear { if remote.address.isEmpty { remote.refreshAddress() } }
    }
}
