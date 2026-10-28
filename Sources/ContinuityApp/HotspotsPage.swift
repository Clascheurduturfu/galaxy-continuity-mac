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
    /// Cached answers and device capability come from the shared LabModel state.
    var center: HotspotCenter?
    var capability: HotspotCapabilityMemory?
    func join(profile base: ContinuityProfile, peer: NearbyPeer, existing: ClipboardSession?) {
        guard !busy, peer.nearby else { return }
        guard capability?.unavailable(peer.address) != true else { status = "\(peer.name) reported no mobile hotspot. Retry checks again."; return }
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
                        guard credentials.isSuccess == true else {
                            self.capability?.markUnavailable(peer.address, reason: credentials.mhsfailed_reason)
                            throw ContinuityError.message("This device declined the hotspot request (reason \(credentials.mhsfailed_reason ?? -1)). Retry from this page when the device is ready.")
                        }
                        self.center?.store(address: peer.address, credentials: credentials)
                        self.capability?.markAvailable(peer.address)
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
                    // A still-fresh cached answer skips the radio query entirely.
                    if let cached = self.center?.cached(address: peer.address), cached.isSuccess == true {
                        self.status = "Using the hotspot answer cached moments ago."
                        command.hotspotReceived?(cached)
                    } else {
                        try await command.requestHotspot()
                    }
                    if self.ownsSession { try await command.run() }
                } catch {
                    if self.generation == generation, !self.received && !Task.isCancelled { self.status = error.localizedDescription; self.finish() }
                }
            }
        } catch { status = error.localizedDescription; finish() }
    }
    func cancel() { generation = UUID(); joinTask?.cancel(); joinTask = nil; finish(); status = "Hotspot request cancelled." }
    /// Clears a stored "no hotspot" verdict so the device can be re-checked.
    func retry(peer: NearbyPeer) {
        capability?.markAvailable(peer.address)
        center?.invalidate(address: peer.address)
        status = "\(peer.name) will be asked again next time."
        objectWillChange.send()
    }
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
    private func statusText(for peer: NearbyPeer) -> String {
        if model.hotspotCenter.information(address: peer.address) != nil { return "Nearby · hotspot service available" }
        switch model.hotspotInformationStates[peer.address] {
        case .checking?: return "Nearby · checking hotspot availability…"
        case .unanswered?: return "Nearby · no hotspot status reply"
        case nil: return "Nearby · hotspot availability not confirmed"
        }
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                OneUIPageHeader("Auto Hotspot", subtitle: "Connect through any nearby Galaxy with mobile tethering, using its own hotspot connection")
                ForEach(peers) { peer in
                    if model.hotspotCapability.unavailable(peer.address) {
                        OneUICard {
                            HStack(spacing: 14) {
                                Image(systemName: "personalhotspot").font(.system(size: 26)).foregroundStyle(.secondary)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(peer.name).font(.headline)
                                    if let battery = model.batteryPercent(for: peer.address) {
                                        DeviceBatteryBadge(percent: battery)
                                    }
                                    Text("No hotspot — this device declined the request. Retry is delayed; Wi-Fi-only models cannot tether.").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                                }
                                Spacer()
                                Button("Retry") { hotspots.retry(peer: peer); model.retryHotspotInformation(for: peer.address) }.buttonStyle(OneUISecondaryButtonStyle())
                            }
                        }
                    } else {
                        OneUICard {
                            HStack(spacing: 14) {
                                Image(systemName: "personalhotspot").font(.system(size: 26)).foregroundStyle(OneUI.blue)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(peer.name).font(.headline)
                                    if let battery = model.batteryPercent(for: peer.address) {
                                        DeviceBatteryBadge(percent: battery)
                                    }
                                    Text(statusText(for: peer)).font(.caption).foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                        .help("A missing reply can mean Auto Hotspot is off or unsupported on this device. It is not a permanent hardware verdict.")
                                }
                                Spacer()
                                Button(hotspots.busy && hotspots.target == peer.address ? "Connecting…" : "Connect") {
                                    if let profile = model.profile {
                                        let existing = model.clipboardSession(for: peer.address)
                                        hotspots.center = model.hotspotCenter
                                        hotspots.capability = model.hotspotCapability
                                        hotspots.join(profile: profile, peer: peer, existing: existing)
                                    }
                                }.buttonStyle(OneUIPrimaryButtonStyle()).disabled(hotspots.busy)
                            }
                        }
                    }
                }
                if peers.isEmpty {
                    OneUICard { Text("No nearby phone or tablet detected. Turn on Bluetooth and Samsung Auto Hotspot on the device. Wi-Fi-only tablets cannot provide mobile tethering.").foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).padding(.vertical, 22) }
                }
                WiFiMenuHotspotCard(wifiMenu: model.wifiMenu)
                OneUICard {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(hotspots.status).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        if hotspots.busy { Button("Cancel Request") { hotspots.cancel() } }
                        Text("Samsung enables the hotspot after account authentication. macOS needs Location Services to find and join its Wi-Fi. Status is checked once per connection and cached for five minutes; activation only happens when you choose Connect.").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }

            }.padding(28)
        }.onAppear { model.refreshHotspotInformation() }
    }
}
