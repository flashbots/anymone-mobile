import AnymoneKit
import DeviceCheck
import SwiftUI

/// Starts the client with App Attest so it is admitted on attested subnets, and
/// shows where the enrolment stands.
struct AttestView: View {
    @EnvironmentObject private var session: Session
    @AppStorage("client_toml") private var configToml = bundledConfig()
    @AppStorage("tag") private var tag = "anymone.chat"
    @State private var probe = "not run"

    private var supported: Bool { DCAppAttestService.shared.isSupported }

    var body: some View {
        SectionLabel(index: "01", title: "device", trailing: "secure enclave")
        VStack(spacing: 0) {
            Hairline()
            Row(
                key: "app attest",
                value: supported ? "supported" : "unsupported",
                accent: supported ? Ink.moon : Ink.ember)
            Hairline()
            Row(key: "key probe", value: probe, accent: Ink.paper)
            Hairline()
        }
        Button("probe key generation") { Task { await probeKey() } }
            .buttonStyle(HouseButton(outline: true))

        SectionLabel(index: "02", title: "enrolment", trailing: "device-side view")
        VStack(spacing: 0) {
            Hairline()
            Row(key: "state", value: session.attestation, accent: Ink.paper)
            Hairline()
            Row(
                key: "client key",
                value: session.pubkey.isEmpty ? "—" : String(session.pubkey.prefix(22)) + "…")
            Hairline()
            Row(key: "status", value: session.status, accent: Ink.paper)
            Hairline()
        }

        if !session.running {
            Button("start attested") {
                Task { await session.start(configToml: configToml, tag: tag, attested: true) }
            }
            .buttonStyle(HouseButton())
        } else {
            Button("refresh") { session.refreshAttestation() }
                .buttonStyle(HouseButton(outline: true))
        }

        SectionLabel(index: "03", title: "what the proof says")
        Text(
            """
            The token binds this client's key and the committee round, and the
            relay verifies it locally against the signed network policy — no
            call to Apple. It attests a store-signed build on a genuine device,
            not the code's behaviour: the trust root is the vendor.
            """
        )
        .font(.mono(11))
        .lineSpacing(4)
        .foregroundStyle(Ink.fog)
    }

    /// Cheap check that the entitlement and provisioning are right, before
    /// involving the network.
    private func probeKey() async {
        let service = DCAppAttestService.shared
        guard service.isSupported else {
            probe = "unsupported here"
            return
        }
        do {
            let keyId = try await service.generateKey()
            probe = "key \(keyId.prefix(10))…"
        } catch {
            probe = "failed: \(error.localizedDescription)"
        }
    }
}

/// Rust hands over the 32-byte challenge; the SDK call and the evidence framing
/// live here. A fresh key per attestation keeps the counter at zero, which is
/// what the verifier requires for an enrolment.
final class AppAttestFetcher: AttestationTokenFetcher {
    func fetch(challenge: Data) async throws -> Data {
        let service = DCAppAttestService.shared
        guard service.isSupported else {
            throw FetchError.Unavailable(message: "App Attest unsupported on this device")
        }
        do {
            let keyId = try await service.generateKey()
            let attestation = try await service.attestKey(keyId, clientDataHash: challenge)
            guard let rawKeyId = Data(base64Encoded: keyId), rawKeyId.count == 32 else {
                throw FetchError.Failed(message: "unexpected key id encoding")
            }
            return rawKeyId + attestation
        } catch let error as FetchError {
            throw error
        } catch {
            throw FetchError.Failed(message: error.localizedDescription)
        }
    }
}
