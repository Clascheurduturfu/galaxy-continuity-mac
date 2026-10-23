import SwiftUI
import AppKit
import ContinuityCore

@MainActor final class HotspotsModel: ObservableObject {
    @Published var busy = false
    @Published var target = ""
    @Published var status = "Choose a nearby Galaxy device to request its mobile hotspot."
    private var session: ClipboardSession?
    private var ownsSession = false
    private var previousHandler: ((HotspotCredentials) -> Void)?
    private var operation: Task<Void, Never>?
    private var timeout: Task<Void, Never>?
    private var joinTask: Task<Void, Never>?
    private var received = false
    private var generation = UUID()
    private let joiner = HotspotJoiner()
    func join(profile base: ContinuityProfile, peer: NearbyPeer, existing: ClipboardSession?) {
        guard !busy, peer.nearby else { return }
        var profile = base; profile.preferredPeerAddress = peer.address
        busy = true; target = peer.address; received = false
        generation = UUID(); let generation = self.generation
        status = "Requesting hotspot from \(peer.name)…"
        do {
            let command: ClipboardSession
            if let existing { command = existing; ownsSession = false; previousHandler = existing.hotspotReceived }
            else { command = ClipboardSession(connection: try BLEMCFTransport(profile: profile), profile: profile); ownsSession = true; previousHandler = nil }
            session = command
            command.hotspotReceived = { [weak self] credentials in
                guard let self, self.generation == generation, self.busy, !self.received else { return }
                self.received = true; self.timeout?.cancel()
                self.previousHandler?(credentials)
                self.joinTask = Task {
                    defer { if self.generation == generation { self.finish() } }
                    do {
                        guard credentials.isSuccess == true else { throw ContinuityError.message("This device declined the hotspot request (reason \(credentials.mhsfailed_reason ?? -1)). It may not have cellular tethering available.") }
                        self.status = "Hotspot accepted. Joining Wi-Fi…"
                        try await self.joiner.join(credentials)
                        if self.generation == generation { self.status = "Connected to \(peer.name)'s hotspot." }
                    } catch { if self.generation == generation { self.status = error.localizedDescription } }
                }
            }
            timeout = Task {
                do { try await Task.sleep(nanoseconds: 45_000_000_000) } catch { return }
                guard self.generation == generation else { return }
                self.status = "Hotspot request timed out. Keep the device nearby with Auto Hotspot enabled."; self.finish()
            }
            operation = Task {
                do {
                    if self.ownsSession { try await command.connect() }
                    try await command.requestHotspot()
                    if self.ownsSession { try await command.run() }
                } catch {
                    if self.generation == generation, !self.received && !Task.isCancelled { self.status = error.localizedDescription; self.finish() }
                }
            }
        } catch { status = error.localizedDescription; finish() }
    }
    func cancel() { generation = UUID(); joinTask?.cancel(); joinTask = nil; finish(); status = "Hotspot request cancelled." }
    private func finish() {
        timeout?.cancel(); timeout = nil; operation?.cancel(); operation = nil
        if ownsSession { session?.stop() } else { session?.hotspotReceived = previousHandler }
        session = nil; previousHandler = nil; busy = false
    }
}

struct HotspotsPage: View {
    @ObservedObject var model: LabModel
    @ObservedObject var hotspots: HotspotsModel
    private var peers: [NearbyPeer] { model.nearbyPeers.filter { $0.nearby && ["phone", "tablet", "tab"].contains($0.deviceType?.lowercased() ?? "") } }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                OneUIPageHeader("Auto Hotspot", subtitle: "Connect through any nearby Galaxy with mobile tethering, using its own hotspot connection")
                ForEach(peers) { peer in
                    OneUICard {
                        HStack(spacing: 14) {
                            Image(systemName: "personalhotspot").font(.system(size: 26)).foregroundStyle(OneUI.blue)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(peer.name).font(.headline)
                                Text("Nearby · hotspot availability checked when requested").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button(hotspots.busy && hotspots.target == peer.address ? "Connecting…" : "Connect") {
                                if let profile = model.profile {
                                    let existing = model.connected && model.selectedTarget == peer.address ? model.session : nil
                                    hotspots.join(profile: profile, peer: peer, existing: existing)
                                }
                            }.buttonStyle(OneUIPrimaryButtonStyle()).disabled(hotspots.busy)
                        }
                    }
                }
                if peers.isEmpty {
                    OneUICard { Text("No nearby phone or tablet detected. Turn on Bluetooth and Samsung Auto Hotspot on the device. Wi-Fi-only tablets cannot provide mobile tethering.").foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).padding(.vertical, 22) }
                }
                OneUICard {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(hotspots.status).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        if hotspots.busy { Button("Cancel Request") { hotspots.cancel() } }
                        Text("Samsung enables the hotspot after account authentication. macOS needs Location Services to find and join its Wi-Fi. Nothing is enabled just by opening this page.").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }

            }.padding(28)
        }
    }
}
