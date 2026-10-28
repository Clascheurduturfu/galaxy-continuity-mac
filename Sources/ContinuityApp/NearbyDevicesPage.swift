import SwiftUI
import AppKit
import ContinuityCore

struct NearbyDevicesPage: View {
    @ObservedObject var model: LabModel
    @ObservedObject var features: FeaturesModel
    @Binding var section: SidebarSection
    private var peers: [NearbyPeer] { model.nearbyPeers.filter(\.nearby) }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                OneUIPageHeader("Nearby Devices", subtitle: "Choose a device for file access, clipboard or keyboard and mouse sharing") {
                    OneUIStatusPill("\(peers.count) nearby", tone: peers.isEmpty ? .neutral : .connected)
                }
                Text(model.discoveryStatus).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if peers.isEmpty {
                    OneUICard {
                        Label(model.profile == nil ? "Sign in with Samsung to discover your devices." : "No Samsung devices detected nearby. Turn on their Bluetooth; Storage Share and Multi Control also need a reachable Wi-Fi connection.", systemImage: "dot.radiowaves.left.and.right")
                            .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).padding(.vertical, 24)
                    }
                }
                ForEach(peers) { peer in
                    NearbyFeatureCard(model: model, features: features, peer: peer, section: $section)
                }
                Text("Only detected or connected devices appear here. Sharing still requires the device's permission. Account registration alone does not mean a device is nearby.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }.padding(28)
        }
        .onAppear { features.ensurePlacements(peers.map(\.address)) }
        .onAppear { model.refreshHotspotInformation() }
        .onChange(of: peers.map(\.address)) { features.ensurePlacements($0) }
    }
}

private struct NearbyFeatureCard: View {
    @ObservedObject var model: LabModel
    @ObservedObject var features: FeaturesModel
    let peer: NearbyPeer
    @Binding var section: SidebarSection
    private var profile: ContinuityProfile? {
        guard var value = model.profile else { return nil }; value.preferredPeerAddress = peer.address; return value
    }
    private func command() {
        features.sharedCommand = model.clipboardSession(for: peer.address)
        features.sharedCommandPeerAddress = features.sharedCommand?.peerAddress
    }
    private var mounted: Bool { features.storagePeerAddress == peer.address && features.storage.mountURL != nil }
    private var controlling: Bool { features.multiPeerAddress == peer.address && features.multiConnected }
    var body: some View {
        OneUICard {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 14) {
                    Image(systemName: peer.symbol).font(.system(size: 28)).foregroundStyle(OneUI.blue).frame(width: 42)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(peer.name).font(.system(size: 18, weight: .bold, design: .rounded))
                        if let battery = model.batteryPercent(for: peer.address) { DeviceBatteryBadge(percent: battery) }
                        Text(peer.connected ? "Connected" : peer.bluetoothNearby ? "Nearby over Bluetooth" : "Found on local network").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if peer.connected { OneUIStatusPill("Connected", tone: .connected) }
                }
                Divider()
                HStack(spacing: 10) {
                    if mounted, let url = features.storage.mountURL {
                        Button("Open Storage") { NSWorkspace.shared.open(url) }.buttonStyle(OneUIPrimaryButtonStyle())
                        Button("Disconnect Storage") { Task { await features.storage.disconnect() } }.buttonStyle(OneUISecondaryButtonStyle())
                    } else {
                        Button("Storage Share") { if let profile { command(); features.connectStorage(profile: profile, device: peer.network) } }
                            .buttonStyle(OneUIPrimaryButtonStyle()).disabled(features.busy || profile == nil)
                    }
                    if peer.deviceType?.lowercased() != "pc" {
                        Button(controlling ? "Arrange & Control" : "Multi Control") {
                            if let profile, !controlling { command(); features.connectMulti(profile: profile, device: peer.network) }
                            section = .multiControl
                        }.buttonStyle(OneUISecondaryButtonStyle()).disabled(features.busy || profile == nil)
                    }
                    Label(model.automaticClipboard ? (peer.connected ? "Clipboard connected" : "Clipboard joins automatically") : "Clipboard sync off", systemImage: "doc.on.clipboard")
                        .font(.caption).foregroundStyle(.secondary)
                        .help("Clipboard Sync in Quick Access controls sharing with all nearby account devices. No per-device activation is needed.")
                }
                if (features.storagePeerAddress == peer.address || features.multiPeerAddress == peer.address) && !features.status.isEmpty {
                    Text(features.status).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

struct MultiControlPage: View {
    @ObservedObject var model: LabModel
    @ObservedObject var features: FeaturesModel
    @State private var selected = ""
    private var peers: [NearbyPeer] { model.nearbyPeers.filter { $0.nearby && $0.deviceType?.lowercased() != "pc" } }
    private var address: String { peers.contains(where: { $0.address == selected }) ? selected : peers.first(where: { $0.address == features.multiPeerAddress })?.address ?? peers.first?.address ?? "" }
    private var connected: Bool { features.multiConnected && features.multiPeerAddress == address }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                OneUIPageHeader("Multi Control", subtitle: "Arrange a Galaxy device beside a Mac screen, then cross that edge to switch") {
                    OneUIStatusPill(features.multi.controlling ? "Controlling" : connected ? "Ready" : "Disconnected", tone: connected ? .connected : .neutral)
                }
                OneUICard {
                    VStack(alignment: .leading, spacing: 14) {
                        Picker("Galaxy device", selection: Binding(get: { address }, set: { selected = $0 })) {
                            if peers.isEmpty { Text("No phone or tablet nearby").tag("") }
                            ForEach(peers) { Text($0.name).tag($0.address) }
                        }.disabled(features.busy || features.multi.controlling)
                        if !address.isEmpty {
                            DeviceArrangement(features: features, peers: peers, selected: address, select: { selected = $0 })
                            Picker("Position", selection: Binding(get: { features.placement(for: address).side }, set: {
                                var p = features.placement(for: address); p.side = $0; features.place(address, p)
                            })) { ForEach(DeviceSide.allCases, id: \.self) { Text($0.title).tag($0) } }.pickerStyle(.segmented)
                            Picker("Mac screen", selection: Binding(get: { features.placement(for: address).screenID }, set: {
                                var p = features.placement(for: address); p.screenID = $0; features.place(address, p)
                            })) {
                                Text("Main screen").tag(UInt32(0))
                                ForEach(Array(NSScreen.screens.enumerated()), id: \.offset) { _, screen in
                                    Text(screen.localizedName).tag((screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0)
                                }
                            }.disabled(features.multiConnected)
                        }
                        Text("Drag a device around the Mac to choose its side and edge position. A central part of that edge is shared; hot corners and edges leading to another Mac display stay local.")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                OneUICard {
                    VStack(alignment: .leading, spacing: 14) {
                        Toggle("Switch by pushing the pointer through the arranged screen edge", isOn: $features.edgeSwitching)
                            .toggleStyle(.switch).disabled(!connected)
                        HStack {
                            Button(connected ? "Disconnect" : "Connect Multi Control") {
                                if connected { features.disconnectMulti() }
                                else if var profile = model.profile, let peer = peers.first(where: { $0.address == address }) {
                                    profile.preferredPeerAddress = address
                                    features.sharedCommand = model.clipboardSession(for: peer.address)
                                    features.sharedCommandPeerAddress = features.sharedCommand?.peerAddress
                                    features.connectMulti(profile: profile, device: peer.network)
                                }
                            }.buttonStyle(OneUIPrimaryButtonStyle()).disabled(features.busy || address.isEmpty || features.multi.controlling)
                            Button("Control Now") { features.control() }.disabled(!connected || !features.multi.isReadyForControl || features.multi.controlling).buttonStyle(OneUISecondaryButtonStyle())
                            Button("Return to Mac (Esc)") { Task { await features.multi.release() } }.disabled(!features.multi.controlling).buttonStyle(OneUISecondaryButtonStyle())
                            if features.busy { ProgressView().controlSize(.small) }
                        }
                        Text(features.status).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        Text("Escape always releases input. One Galaxy device is controlled at a time. Keyboard layout follows the receiving device.").font(.caption).foregroundStyle(.secondary)
                        if !features.pointerSummary.isEmpty {
                            DisclosureGroup("Pointer performance") { Text(features.pointerSummary).font(.system(size: 11, design: .monospaced)).textSelection(.enabled) }
                        }
                    }
                }
            }.padding(28)
        }
        .onAppear { features.ensurePlacements(peers.map(\.address)) }
        .onChange(of: peers.map(\.address)) { features.ensurePlacements($0) }
    }
}

private struct DeviceArrangement: View {
    @ObservedObject var features: FeaturesModel
    let peers: [NearbyPeer]
    let selected: String
    var select: (String) -> Void
    var body: some View {
        GeometryReader { geometry in
            let center = CGPoint(x: geometry.size.width / 2, y: 150)
            ZStack {
                RoundedRectangle(cornerRadius: 20).fill(Color.primary.opacity(0.035))
                VStack(spacing: 6) {
                    Image(systemName: "laptopcomputer").font(.system(size: 54)).foregroundStyle(OneUI.blue)
                    Text("This Mac").font(.caption.bold())
                }.frame(width: 150, height: 100).position(center)
                ForEach(peers.prefix(6)) { peer in
                    ArrangementTile(peer: peer, placement: features.placement(for: peer.address), selected: peer.address == selected, center: center,
                                    select: { select(peer.address) }, place: { features.place(peer.address, $0) })
                }
            }
        }.frame(height: 300).accessibilityLabel("Drag Galaxy devices to arrange their position around this Mac")
    }
}

private struct ArrangementTile: View {
    let peer: NearbyPeer
    let placement: DevicePlacement
    let selected: Bool
    let center: CGPoint
    var select: () -> Void
    var place: (DevicePlacement) -> Void
    @State private var translation = CGSize.zero
    private var point: CGPoint {
        switch placement.side {
        case .left: return .init(x: center.x - 145, y: center.y + placement.offset * 70)
        case .right: return .init(x: center.x + 145, y: center.y + placement.offset * 70)
        case .above: return .init(x: center.x + placement.offset * 120, y: center.y - 100)
        case .below: return .init(x: center.x + placement.offset * 120, y: center.y + 100)
        }
    }
    var body: some View {
        VStack(spacing: 5) {
            Image(systemName: peer.symbol).font(.system(size: 30))
            Text(peer.name).font(.caption2).lineLimit(2).multilineTextAlignment(.center)
        }.foregroundStyle(selected ? OneUI.blue : Color.secondary).padding(9).frame(width: 100, height: 76)
            .background(RoundedRectangle(cornerRadius: 12).fill(selected ? OneUI.blue.opacity(0.12) : Color.primary.opacity(0.045)))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(selected ? OneUI.blue : Color.clear, lineWidth: 2))
            .position(x: point.x + translation.width, y: point.y + translation.height)
            .onTapGesture(perform: select)
            .gesture(DragGesture().onChanged { translation = $0.translation }.onEnded { value in
                let x = point.x + value.translation.width - center.x, y = point.y + value.translation.height - center.y
                var p = placement
                if abs(x) > abs(y) { p.side = x < 0 ? .left : .right; p.offset = max(-0.65, min(0.65, y / 70)) }
                else { p.side = y < 0 ? .above : .below; p.offset = max(-0.65, min(0.65, x / 120)) }
                translation = .zero; select(); place(p)
            })
    }
}
