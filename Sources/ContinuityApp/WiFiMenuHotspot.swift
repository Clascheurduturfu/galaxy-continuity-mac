import SwiftUI
import AppKit
import ContinuityCore

/// Native macOS Wi-Fi menu integration (experimental; requires SIP disabled).
///
/// A hook dylib injected into WiFiAgent/ControlCenter shows the connected
/// Galaxy under "Personal Hotspots"; clicking it asks this app — through the
/// file protocol below — to request the phone's hotspot over the EXISTING
/// BLE session and hand back credentials the hook joins with.
///
/// File protocol in `/tmp/gcl-wifi-menu` (all files created by whichever side
/// owns them; the hook only reads/writes what the notes describe):
/// - `status.json`  app → hook: display data {name, battery, bars, network, ssid}
/// - `available`    app → hook: touched while a live session + hotspot-capable
///                   device exists; the hook hides the entry when stale (>10 s)
/// - `menu_opened`  hook → app: the Wi-Fi menu opened → prefetch, rate-limited
/// - `trigger`      hook → app: the entry was clicked → answer with creds.json
/// - `creds.json`   app → hook: {isSuccess, ssid, password, reason}
@MainActor final class WiFiMenuHotspot: ObservableObject {
    static let directory = URL(fileURLWithPath: "/tmp/gcl-wifi-menu")
    static let statusFile = WiFiMenuHotspot.directory.appendingPathComponent("status.json")
    static let availableFile = WiFiMenuHotspot.directory.appendingPathComponent("available")
    static let menuOpenedFile = WiFiMenuHotspot.directory.appendingPathComponent("menu_opened")
    static let triggerFile = WiFiMenuHotspot.directory.appendingPathComponent("trigger")
    static let credsFile = WiFiMenuHotspot.directory.appendingPathComponent("creds.json")

    @Published var enabled = UserDefaults.standard.bool(forKey: "hotspot.wifiMenu.enabled") {
        didSet {
            UserDefaults.standard.set(enabled, forKey: "hotspot.wifiMenu.enabled")
            if !internalChange { applyEnabled() }
        }
    }
    /// Guards didSet while applyEnabled flips the toggle itself.
    private var internalChange = false
    /// nil while unchecked; false shows the SIP requirement.
    @Published var sipDisabled: Bool?
    @Published var status = "Not set up."
    private var loop: Task<Void, Never>?
    private var handling = false
    /// Wired by LabModel: the live session and the device it targets.
    var liveSession: (() -> (session: ClipboardSession, address: String, name: String)?)?
    var center: HotspotCenter?
    var capability: HotspotCapabilityMemory?
    var note: ((String) -> Void)?

    // MARK: SIP

    static func systemIntegrityProtectionDisabled() -> Bool {
        let process = Process(); let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/csrutil"); process.arguments = ["status"]
        process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return false }
        let data = pipe.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        return String(decoding: data, as: UTF8.self).contains("disabled")
    }
    func refreshSIP() { sipDisabled = Self.systemIntegrityProtectionDisabled() }

    // MARK: enable / disable

    private func applyEnabled() {
        loop?.cancel(); loop = nil
        guard enabled else {
            removeFile(Self.availableFile); removeFile(Self.menuOpenedFile); removeFile(Self.triggerFile)
            Self.launchctl(["unsetenv", "DYLD_INSERT_LIBRARIES"])
            Self.restartTargets()
            status = "Off. The Wi-Fi menu is back to stock after the menu apps restart."
            return
        }
        refreshSIP()
        guard sipDisabled == true else { disableInternally("System Integrity Protection is enabled, so macOS blocks the Wi-Fi menu hook. Disable SIP (csrutil disable in Recovery) to use this."); return }
        guard let dylib = Self.installedHookPath() else { disableInternally("The Wi-Fi menu hook is missing from this build. Update the app and try again."); return }
        try? FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        Self.launchctl(["setenv", "DYLD_INSERT_LIBRARIES", dylib.path])
        Self.restartTargets()
        status = "Hook injected into the Wi-Fi menu apps. The entry appears once a Galaxy session is live."
        loop = Task { [weak self] in
            var tick = 0
            while !Task.isCancelled {
                await self?.poll(tick: tick)
                tick += 1
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }
    }
    /// Refusal path: flip the stored toggle off without re-running the turn-off cleanup.
    private func disableInternally(_ message: String) {
        internalChange = true; enabled = false; internalChange = false
        status = message
    }
    private func poll(tick: Int) async {
        publishAvailability(tick: tick)
        guard !handling else { return }
        if FileManager.default.fileExists(atPath: Self.menuOpenedFile.path) { removeFile(Self.menuOpenedFile) ; await prefetch() }
        if FileManager.default.fileExists(atPath: Self.triggerFile.path) { await handleTrigger() }
    }

    // MARK: availability

    /// The hook only shows the entry while `available` is fresh, so a phone
    /// that left (session down) or a known hotspot-less device never appears.
    /// Refreshed every 5 s — the hook treats it as stale after 10 s.
    private func publishAvailability(tick: Int) {
        guard tick % 10 == 0 else { return }
        guard let capability else { return }
        guard let live = liveSession?(), !capability.unavailable(live.address) else {
            removeFile(Self.availableFile)
            if tick % 20 == 0 { center?.invalidate() }   // no session: drop cached answers
            return
        }
        let payload: [String: Any] = [
            "name": live.name, "battery": 88, "bars": 4, "network": "5G",
            "ssid": center?.cached(address: live.address)?.ssid ?? ""
        ]
        if let data = try? JSONSerialization.data(withJSONObject: payload) { try? data.write(to: Self.statusFile, options: .atomic) }
        FileManager.default.createFile(atPath: Self.availableFile.path, contents: nil, attributes: [.modificationDate: Date()])
    }

    // MARK: queries (on demand only, cached, existing session only)

    /// Wi-Fi menu opened: warm the cache so a click is instant. Rate-limited
    /// by the cache window; the phone is only re-asked after it expires or a
    /// wake/disconnect invalidated it.
    private func prefetch() async {
        guard let live = liveSession?(), let center, let capability else { return }
        guard center.cached(address: live.address) == nil, !capability.unavailable(live.address) else { return }
        do {
            let answer = try await live.session.requestHotspotAnswer(timeout: 15)
            center.store(address: live.address, credentials: answer)
            if answer.isSuccess == true { capability.markAvailable(live.address) } else { capability.markUnavailable(live.address, reason: answer.mhsfailed_reason) }
            note?("Wi-Fi menu opened: refreshed the hotspot answer from \(live.name).")
        } catch { note?("Wi-Fi menu prefetch: \(error.localizedDescription)") }
    }
    /// The entry was clicked: reuse a fresh cached answer, else ask once over
    /// the existing session, then hand the credentials to the hook.
    private func handleTrigger() async {
        handling = true
        defer { handling = false; removeFile(Self.triggerFile) }
        guard let live = liveSession?(), let center, let capability else { writeCreds(nil, reason: -1); return }
        let answer = center.cached(address: live.address)
            ?? (try? await live.session.requestHotspotAnswer(timeout: 15))
        guard let answer else { writeCreds(nil, reason: -1); return }
        center.store(address: live.address, credentials: answer)
        if answer.isSuccess == true { capability.markAvailable(live.address) } else { capability.markUnavailable(live.address, reason: answer.mhsfailed_reason) }
        writeCreds(answer)
    }
    private func writeCreds(_ answer: HotspotCredentials?, reason: Int) {
        let payload: [String: Any] = [
            "isSuccess": answer?.isSuccess == true,
            "ssid": answer?.ssid ?? "",
            "password": answer?.password ?? "",
            "reason": answer?.mhsfailed_reason ?? reason
        ]
        if let data = try? JSONSerialization.data(withJSONObject: payload) { try? data.write(to: Self.credsFile, options: .atomic) }
    }
    /// Wake, disconnect or user action: the next query re-asks the phone.
    func invalidateCache() { center?.invalidate() }

    // MARK: injection plumbing

    static func installedHookPath() -> URL? {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Galaxy Continuity Lab/GalaxyContinuityWiFiMenuHook.dylib", isDirectory: false)
        if FileManager.default.fileExists(atPath: support.path) { return support }
        guard let bundled = Bundle.main.url(forResource: "GalaxyContinuityWiFiMenuHook", withExtension: "dylib") else { return nil }
        do {
            try FileManager.default.createDirectory(at: support.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            if FileManager.default.fileExists(atPath: support.path) { try FileManager.default.removeItem(at: support) }
            try FileManager.default.copyItem(at: bundled, to: support)
            return support
        } catch { return nil }
    }
    private static func launchctl(_ arguments: [String]) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl"); process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try? process.run()
    }
    /// Relaunch the menu-owning processes so they pick up (or drop) the hook.
    private static func restartTargets() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        process.arguments = ["WiFiAgent", "ControlCenter"]
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try? process.run()
    }
    private func removeFile(_ url: URL) { try? FileManager.default.removeItem(at: url) }
}

struct WiFiMenuHotspotCard: View {
    @ObservedObject var wifiMenu: WiFiMenuHotspot
    var body: some View {
        OneUICard {
            VStack(alignment: .leading, spacing: 12) {
                Label("macOS Wi-Fi menu", systemImage: "wifi").font(.headline)
                Text("Show the connected Galaxy as a native Personal Hotspot in the macOS Wi-Fi menu. Experimental: needs SIP disabled and restarts the menu apps once. Queries only on demand, cached 20 s, and only while the phone session is live.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Toggle("Integrate with the Wi-Fi menu", isOn: $wifiMenu.enabled).toggleStyle(OneUIAlignedSwitchStyle())
                    Spacer()
                    Button("Check SIP") { wifiMenu.refreshSIP() }.buttonStyle(OneUISecondaryButtonStyle())
                }
                if let sip = wifiMenu.sipDisabled {
                    Label(sip ? "SIP is disabled — hook allowed." : "SIP is enabled — macOS will block the hook.",
                          systemImage: sip ? "checkmark.shield" : "lock.shield")
                        .font(.caption).foregroundStyle(sip ? Color.green : Color.orange)
                }
                Text(wifiMenu.status).font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
