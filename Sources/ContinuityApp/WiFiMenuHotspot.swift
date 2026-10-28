import SwiftUI
import AppKit
import ContinuityCore
import Darwin

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
    nonisolated static let directory = URL(fileURLWithPath: "/tmp/gcl-wifi-menu")
    nonisolated static let statusFile = WiFiMenuHotspot.directory.appendingPathComponent("status.json")
    nonisolated static let availableFile = WiFiMenuHotspot.directory.appendingPathComponent("available")
    nonisolated static let menuOpenedFile = WiFiMenuHotspot.directory.appendingPathComponent("menu_opened")
    nonisolated static let triggerFile = WiFiMenuHotspot.directory.appendingPathComponent("trigger")
    nonisolated static let credsFile = WiFiMenuHotspot.directory.appendingPathComponent("creds.json")

    @Published var enabled = false {
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
    @Published private(set) var installing = false
    private var installation: Task<Void, Never>?
    /// Wired by LabModel: the live session and the device it targets.
    var liveSession: (() -> (session: ClipboardSession, address: String, name: String)?)?
    var center: HotspotCenter?
    var capability: HotspotCapabilityMemory?
    var note: ((String) -> Void)?

    func start() {
        guard !AppVersion.isRenderingDemo else { return }
        let wasEnabled = UserDefaults.standard.bool(forKey: "hotspot.wifiMenu.enabled")
        let isScoped = UserDefaults.standard.string(forKey: "hotspot.wifiMenu.loader") == "scoped-v1"
        if isScoped && wasEnabled {
            enabled = true
        } else {
            UserDefaults.standard.set(false, forKey: "hotspot.wifiMenu.enabled")
            installing = true
            installation = Task { [weak self] in
                let restored = await Task.detached {
                    let hadLegacy = Self.clearLegacyGlobalInjection()
                    return Self.restoreTargets(force: hadLegacy || (wasEnabled && !isScoped))
                }.value
                guard let self else { return }
                self.installing = false; self.installation = nil
                self.status = restored ? "Off. Legacy menu injection has been removed." : "Legacy injection was disabled, but the menu agents could not restart. Log out and back in to restore them."
            }
        }
    }

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
        guard !installing else { return }
        loop?.cancel(); loop = nil
        let requested = enabled
        if !requested {
            removeFile(Self.availableFile); removeFile(Self.menuOpenedFile); removeFile(Self.triggerFile); removeFile(Self.credsFile)
        } else {
            refreshSIP()
            guard sipDisabled == true else { disableInternally("System Integrity Protection blocks this experimental integration."); return }
        }
        guard !requested || Bundle.main.url(forResource: "GalaxyContinuityWiFiMenuHook", withExtension: "dylib") != nil else {
            disableInternally("The Wi-Fi menu hook is missing from this build."); return
        }
        installing = true; status = requested ? "Starting Wi-Fi menu integration…" : "Restoring the Wi-Fi menu…"
        installation = Task { [weak self] in
            let failure = await Task.detached(priority: .userInitiated) { () -> String? in
                Self.clearLegacyGlobalInjection()
                guard requested else { return Self.restoreTargets() ? nil : "The stock menu agents could not restart. Log out and back in to restore them." }
                do {
                    guard let dylib = Self.installedHookPath() else { throw ContinuityError.message("Could not copy the bundled hook.") }
                    try Self.prepareIPC()
                    try Self.installScopedTargets(dylib)
                    return nil
                } catch {
                    let restored = Self.restoreTargets()
                    return error.localizedDescription + (restored ? " Stock agents restored." : " Log out and back in to restore the menu agents.")
                }
            }.value
            guard let self else { return }
            self.installing = false; self.installation = nil
            if let failure { self.disableInternally("Wi-Fi menu integration is off. " + failure); return }
            guard requested else { self.status = "Off. The stock Wi-Fi menu has been restored."; return }
            self.status = "Wi-Fi menu integration active."
            self.loop = Task { [weak self] in
                var tick = 0
                while !Task.isCancelled {
                    await self?.poll(tick: tick); tick += 1
                    do { try await Task.sleep(nanoseconds: 500_000_000) } catch { return }
                }
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
        guard let live = liveSession?(), center?.information(address: live.address) != nil, !capability.unavailable(live.address) else {
            removeFile(Self.availableFile)
            return
        }
        let payload: [String: Any] = [
            "name": live.name, "battery": center?.information(address: live.address)?.batteryPercent ?? -1,
            "ssid": center?.cached(address: live.address)?.ssid ?? ""
        ]
        if let data = try? JSONSerialization.data(withJSONObject: payload) { try? data.write(to: Self.statusFile, options: .atomic); try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: Self.statusFile.path) }
        FileManager.default.createFile(atPath: Self.availableFile.path, contents: nil, attributes: [.modificationDate: Date(), .posixPermissions: 0o600])
    }

    // MARK: queries (on demand only, cached, existing session only)

    /// Wi-Fi menu opened: warm the cache so a click is instant. Rate-limited
    /// by the cache window; the phone is only re-asked after it expires or a
    /// wake/disconnect invalidated it.
    private func prefetch() async {
        guard let live = liveSession?(), let center, let capability else { return }
        guard center.information(address: live.address) == nil, !capability.unavailable(live.address) else { return }
        do {
            let info = try await live.session.requestHotspotInformation(timeout: 10)
            center.storeInformation(address: live.address, value: info)
            capability.markAvailable(live.address)
            note?("Wi-Fi menu opened: refreshed the hotspot answer from \(live.name).")
        } catch { note?("Wi-Fi menu prefetch: \(error.localizedDescription)") }
    }
    /// The entry was clicked: reuse a fresh cached answer, else ask once over
    /// the existing session, then hand the credentials to the hook.
    private func handleTrigger() async {
        handling = true
        defer { handling = false; removeFile(Self.triggerFile) }
        guard let live = liveSession?(), let center, let capability else { writeCreds(nil, reason: -1); return }
        var answer = center.cached(address: live.address)
        if answer == nil { answer = try? await live.session.requestHotspotAnswer(timeout: 15) }
        guard let answer else { writeCreds(nil, reason: -1); return }
        center.store(address: live.address, credentials: answer)
        if answer.isSuccess == true { capability.markAvailable(live.address) } else { capability.markUnavailable(live.address, reason: answer.mhsfailed_reason) }
        writeCreds(answer)
    }
    private func writeCreds(_ answer: HotspotCredentials?, reason: Int = -1) {
        let payload: [String: Any] = [
            "isSuccess": answer?.isSuccess == true,
            "ssid": answer?.ssid ?? "",
            "password": answer?.password ?? "",
            "reason": answer?.mhsfailed_reason ?? reason
        ]
        if let data = try? JSONSerialization.data(withJSONObject: payload) { try? data.write(to: Self.credsFile, options: .atomic); try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: Self.credsFile.path) }
    }
    /// Wake, disconnect or user action: the next query re-asks the phone.
    func invalidateCache() { center?.invalidate() }

    // MARK: injection plumbing

    private nonisolated static func prepareIPC() throws {
        var info = stat()
        if lstat(directory.path, &info) != 0 {
            guard errno == ENOENT, mkdir(directory.path, 0o700) == 0, lstat(directory.path, &info) == 0 else { throw ContinuityError.message("Could not create private Wi-Fi menu storage.") }
        }
        guard (info.st_mode & S_IFMT) == S_IFDIR, info.st_uid == getuid(), chmod(directory.path, 0o700) == 0 else {
            throw ContinuityError.message("Wi-Fi menu storage is not an owned directory.")
        }
        for name in ["status.json", "available", "menu_opened", "trigger", "creds.json", "hook.log"] {
            let path = directory.appendingPathComponent(name).path
            if lstat(path, &info) == 0 {
                guard (info.st_mode & S_IFMT) == S_IFREG, info.st_uid == getuid(), info.st_nlink == 1 else { throw ContinuityError.message("Unexpected Wi-Fi menu storage entry.") }
                _ = chmod(path, 0o600)
            }
        }
    }
    nonisolated static func installedHookPath() -> URL? {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Galaxy Continuity Lab/GalaxyContinuityWiFiMenuHook.dylib", isDirectory: false)
        // Always refresh the copied library; an older cached copy can have the wrong ABI.
        guard let bundled = Bundle.main.url(forResource: "GalaxyContinuityWiFiMenuHook", withExtension: "dylib") else { return nil }
        do {
            try FileManager.default.createDirectory(at: support.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            if FileManager.default.fileExists(atPath: support.path) { try FileManager.default.removeItem(at: support) }
            try FileManager.default.copyItem(at: bundled, to: support)
            return support
        } catch { return nil }
    }
    private nonisolated static let jobs = ["com.apple.wifi.WiFiAgent", "com.apple.controlcenter"]
    private nonisolated static var jobDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Galaxy Continuity Lab/HookLaunchAgents", isDirectory: true)
    }
    @discardableResult private nonisolated static func run(_ executable: String, _ args: [String]) -> (Int32, String) {
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable); process.arguments = args
        process.standardOutput = pipe; process.standardError = pipe
        do { try process.run() } catch { return (-1, "Could not run system helper.") }
        // launchctl can wait indefinitely for a crashed process; never hang the app UI.
        let deadline = Date().addingTimeInterval(5)
        while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
        if process.isRunning { process.terminate(); return (-1, "System helper timed out.") }
        let bytes = pipe.fileHandleForReading.readDataToEndOfFile()
        return (process.terminationStatus, String(decoding: bytes.prefix(32768), as: UTF8.self))
    }
    @discardableResult private nonisolated static func clearLegacyGlobalInjection() -> Bool {
        let old = run("/bin/launchctl", ["getenv", "DYLD_INSERT_LIBRARIES"]).1.trimmingCharacters(in: .whitespacesAndNewlines)
        if old.contains("GalaxyContinuityWiFiMenuHook") {
            _ = run("/bin/launchctl", ["unsetenv", "DYLD_INSERT_LIBRARIES"])
            return true
        }
        return false
    }
    private nonisolated static func installScopedTargets(_ dylib: URL) throws {
        #if arch(arm64)
        let required = "arm64e"
        #else
        let required = "x86_64"
        #endif
        guard run("/usr/bin/lipo", ["-verify_arch", required, dylib.path]).0 == 0 else {
            throw ContinuityError.message("The bundled hook lacks the system process architecture (" + required + ").")
        }
        try FileManager.default.createDirectory(at: jobDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try Data().write(to: directory.appendingPathComponent("hook.log"), options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: directory.appendingPathComponent("hook.log").path)
        let domain = "gui/" + String(getuid())
        for job in jobs {
            let original = URL(fileURLWithPath: "/System/Library/LaunchAgents/" + job + ".plist")
            guard var plist = try PropertyListSerialization.propertyList(from: Data(contentsOf: original), format: nil) as? [String: Any] else {
                throw ContinuityError.message("Could not read the stock menu launch agent.")
            }
            var environment = plist["EnvironmentVariables"] as? [String: String] ?? [:]
            environment["DYLD_INSERT_LIBRARIES"] = dylib.path
            plist["EnvironmentVariables"] = environment
            let local = jobDirectory.appendingPathComponent(job + ".plist")
            try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0).write(to: local, options: .atomic)
            _ = run("/bin/launchctl", ["bootout", domain + "/" + job])
            Thread.sleep(forTimeInterval: 0.5)
            guard bootstrap(domain: domain, path: local.path) else {
                _ = bootstrap(domain: domain, path: original.path)
                throw ContinuityError.message("The menu agent rejected the scoped loader.")
            }
        }
        Thread.sleep(forTimeInterval: 1)
        for job in jobs {
            let result = run("/bin/launchctl", ["print", domain + "/" + job])
            guard result.0 == 0, result.1.contains("state = running"), result.1.contains("pid = ") else {
                throw ContinuityError.message("A menu agent failed its startup check.")
            }
        }
        let log = (try? String(contentsOf: directory.appendingPathComponent("hook.log"), encoding: .utf8)) ?? ""
        guard log.contains("[WiFiAgent] hook install complete"), log.contains("[ControlCenter] hook install complete") else {
            throw ContinuityError.message("The menu agents did not confirm loading the hook.")
        }
        UserDefaults.standard.set("scoped-v1", forKey: "hotspot.wifiMenu.loader")
    }
    private nonisolated static func bootstrap(domain: String, path: String) -> Bool {
        for _ in 0..<4 {
            if run("/bin/launchctl", ["bootstrap", domain, path]).0 == 0 { return true }
            Thread.sleep(forTimeInterval: 0.25)
        }
        return false
    }
    @discardableResult private nonisolated static func restoreTargets(force: Bool = false) -> Bool {
        var restored = true
        let domain = "gui/" + String(getuid())
        for job in jobs {
            let loaded = run("/bin/launchctl", ["print", domain + "/" + job]).1
            guard force || loaded.contains(jobDirectory.path) else { continue }
            _ = run("/bin/launchctl", ["bootout", domain + "/" + job])
            Thread.sleep(forTimeInterval: 0.5)
            if !bootstrap(domain: domain, path: "/System/Library/LaunchAgents/" + job + ".plist") { restored = false }
        }
        return restored
    }
    private func removeFile(_ url: URL) { try? FileManager.default.removeItem(at: url) }
}

struct WiFiMenuHotspotCard: View {
    @ObservedObject var wifiMenu: WiFiMenuHotspot
    var body: some View {
        OneUICard {
            VStack(alignment: .leading, spacing: 12) {
                Label("macOS Wi-Fi menu", systemImage: "wifi").font(.headline)
                Text("Show the connected Galaxy as a native Personal Hotspot in the macOS Wi-Fi menu. Experimental: needs SIP disabled and restarts the menu apps once. Status checks do not enable tethering. Only the two Wi-Fi menu agents are injected, while a Galaxy session is live.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Toggle("Integrate with the Wi-Fi menu", isOn: $wifiMenu.enabled).toggleStyle(OneUIAlignedSwitchStyle()).disabled(wifiMenu.installing)
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
