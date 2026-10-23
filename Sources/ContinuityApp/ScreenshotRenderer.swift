import SwiftUI
import AppKit
import ContinuityCore

@MainActor
enum ScreenshotRenderer {
    static func renderAll(to directoryPath: String) {
        let dirURL = URL(fileURLWithPath: directoryPath, isDirectory: true)
        try? FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: true)

        let model = LabModel()
        let buds = BudsModel()
        let features = FeaturesModel()

        let peers: [ContinuityProfile.Peer] = [
            .init(address: "AA:BB:CC:11:22:01", name: "Galaxy S26 Ultra", deviceType: "phone", model: "SM-S948B"),
            .init(address: "AA:BB:CC:11:22:02", name: "Galaxy Tab S9+", deviceType: "tablet", model: "SM-X810"),
            .init(address: "AA:BB:CC:11:22:03", name: "Galaxy Book4 Edge", deviceType: "pc", model: "NP960XMB")
        ]
        let sampleProfile = ContinuityProfile(
            accountKey: Data(repeating: 0x42, count: 32),
            localBluetoothAddress: "AA:BB:CC:00:00:01",
            peers: peers,
            expiresAt: Int64(Date().addingTimeInterval(86_400 * 30).timeIntervalSince1970 * 1000),
            borrowedIdentity: false,
            accountFingerprint: Data([0x12, 0x34, 0x56, 0x78]),
            preferredPeerAddress: "AA:BB:CC:11:22:01"
        )

        var registry = NearbyPeerRegistry()
        registry.setPeers(peers)
        registry.setConnected(["AA:BB:CC:11:22:01", "AA:BB:CC:11:22:03"])

        model.profile = sampleProfile
        model.hasNativeSignIn = true
        model.accountEmail = "demo@example.invalid"
        model.selectedTarget = "AA:BB:CC:11:22:01"
        model.connected = true
        model.autoConnect = true
        model.automaticClipboard = true
        model.lanPeers = ["Galaxy Book4 Edge"]
        model.nearbyPeers = registry.rows()
        model.status = "Authenticated and connected to Galaxy S26 Ultra over Bluetooth L2CAP."
        model.receivedText = "https://github.com/Clascheurduturfu/galaxy-continuity-mac — Copied on Galaxy S26 Ultra and ready to paste on Mac (⌘V)."
        model.lastClipboardDirection = "From Galaxy S26 Ultra"
        model.lastClipboardDate = Date()

        buds.devices = [
            PairedBuds(id: "AA:BB:CC:33:44:55", name: "Galaxy Buds3 Pro"),
            PairedBuds(id: "AA:BB:CC:33:44:66", name: "Galaxy Buds2 Pro")
        ]
        buds.selection = buds.devices.first!.id
        buds.connected = true
        buds.automaticSwitching = true
        buds.peerStatus = "Buds connected · Mac audio active"
        buds.status = "Watching Mac audio output. Galaxy Buds3 Pro switches automatically when media plays."

        features.status = "Connected to Galaxy S26 Ultra over Wi-Fi. Storage Share and Multi Control are ready."
        features.multiConnected = true
        features.multiPeerAddress = peers[0].address

        let sections: [(SidebarSection, String)] = [
            (.home, "home-dashboard.png"),
            (.clipboard, "clipboard.png"),
            (.calls, "phone-calls.png"),
            (.buds, "galaxy-buds.png"),
            (.nearby, "nearby-devices.png"),
            (.multiControl, "multi-control.png"),
            (.hotspots, "auto-hotspot.png"),
            (.settings, "settings.png")
        ]

        let variants: [(String, ColorScheme, CGFloat, CGFloat, Set<SidebarSection>)] = [
            ("", .dark, 1040, 700, Set(SidebarSection.allCases)),
            ("light", .light, 1040, 700, [.home, .buds, .multiControl, .settings]),
            ("narrow", .dark, 900, 700, [.calls, .nearby, .multiControl, .settings]),
            ("full", .dark, 1040, 1500, [.buds, .settings])
        ]
        for (variant, scheme, width, height, included) in variants {
        let target = variant.isEmpty ? dirURL : dirURL.appendingPathComponent(variant, isDirectory: true)
        try? FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        for (section, filename) in sections where included.contains(section) {
            let rootView = LabView(
                model: model,
                buds: buds,
                features: features,
                hotspots: HotspotsModel(),
                selectedSection: section
            )
            .overlay(alignment: .bottomTrailing) { Text("Demo · fictional account and device state").font(.caption).padding(8).background(.ultraThinMaterial).padding(10) }
            .environment(\.colorScheme, scheme)
            .frame(width: width, height: height)

            renderView(rootView, size: NSSize(width: width, height: height), scheme: scheme, to: target.appendingPathComponent(filename))
        }
        }
    }

    private static func renderView<V: View>(_ view: V, size: NSSize, scheme: ColorScheme, to url: URL) {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        window.title = AppVersion.appName
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(origin: .zero, size: size)
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.15))

        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        if let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: url, options: .atomic)
        }
    }
}
