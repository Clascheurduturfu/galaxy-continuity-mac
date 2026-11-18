import SwiftUI
import AppKit
import Combine
import ContinuityCore
import Darwin

/// Native macOS Phone.app bridge (experimental; requires SIP disabled for daemon adapter).
///
/// Manages a scoped LaunchAgent configuration for `callservicesd` that loads
/// `GalaxyContinuityPhoneHook.dylib` while Samsung CMC calling is registered,
/// relaying dial, answer, hang-up, mute, and DTMF events over owner-only IPC files
/// in `/tmp/gcl-phone-app`. Also holds `tel:` URL prefill state, which works
/// with SIP enabled when Galaxy Continuity is chosen as the default calling app.
@MainActor final class PhoneAppBridge: ObservableObject {
    static let shared = PhoneAppBridge()

    nonisolated static let directory = URL(fileURLWithPath: "/tmp/gcl-phone-app")
    nonisolated static let availableFile = directory.appendingPathComponent("available")
    nonisolated static let disabledFile = directory.appendingPathComponent("disabled")
    nonisolated static let startupsFile = directory.appendingPathComponent("startups")
    nonisolated static let statusFile = directory.appendingPathComponent("status.json")
    nonisolated static let appCommandsFile = directory.appendingPathComponent("app_commands.jsonl")
    nonisolated static let daemonEventsFile = directory.appendingPathComponent("daemon_events.jsonl")
    nonisolated static let hookLogFile = directory.appendingPathComponent("hook.log")
    nonisolated static let pokeFile = directory.appendingPathComponent(".poke")

    @Published var enabled = false {
        didSet {
            UserDefaults.standard.set(enabled, forKey: "calls.phoneApp.enabled")
            if !internalChange { applyEnabled() }
        }
    }
    private var internalChange = false

    @Published var sipDisabled: Bool?
    @Published private(set) var installing = false
    @Published var status = "Not set up."
    @Published var daemonHealthy = false
    @Published var crashGuardTripped = false
    @Published var pendingDialerNumber: String?

    var isHandlingCallsNatively: Bool {
        enabled && daemonHealthy && !crashGuardTripped && !FileManager.default.fileExists(atPath: Self.disabledFile.path)
    }

    var deviceNameProvider: (() -> String)?
    var note: ((String) -> Void)?

    private let calls = CallingController.shared
    private var bag = Set<AnyCancellable>()
    private var started = false
    private var installation: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?
    private var vnodeSource: DispatchSourceFileSystemObject?
    private var dirFD: Int32 = -1
    private var sessionID = UUID().uuidString
    private var cmdSeq: UInt64 = 0
    private var lastEventSeq: UInt64 = 0
    private var bridgedUPI: String?
    private var lastObservedCallState: CallingCallState = .idle
    private var lastAvailablePublished = false

    private init() {}

    func start() {
        guard !started, !AppVersion.isRenderingDemo, !AppVersion.isWindowSelfTest else { return }
        started = true
        observeCallingController()
        let wasEnabled = UserDefaults.standard.bool(forKey: "calls.phoneApp.enabled")
        let isScoped = UserDefaults.standard.string(forKey: "calls.phoneApp.loader") == "scoped-v1"
        if isScoped && wasEnabled {
            internalChange = true
            enabled = true
            internalChange = false
            applyEnabled()
        } else {
            UserDefaults.standard.set(false, forKey: "calls.phoneApp.enabled")
            Task {
                let restored = await Task.detached { Self.restoreStockDaemon(force: wasEnabled && !isScoped) }.value
                self.status = restored ? "Off. Using Galaxy Continuity's built-in call window." : "Off. Could not restore stock callservicesd; log out and back in."
            }
        }
    }

    func refreshSIP() {
        sipDisabled = WiFiMenuHotspot.systemIntegrityProtectionDisabled()
    }

    func resetCrashGuard() {
        try? FileManager.default.removeItem(at: Self.disabledFile)
        try? FileManager.default.removeItem(at: Self.startupsFile)
        crashGuardTripped = false
        if enabled { applyEnabled() }
        else { status = "Crash guard reset. Toggle on to enable Phone app integration." }
    }

    func shutdownForQuit() {
        heartbeatTask?.cancel(); heartbeatTask = nil
        stopWatcher()
        if let upi = bridgedUPI {
            sendCommand(["cmd": "disconnected", "upi": upi, "reason": 0])
            bridgedUPI = nil
        }
        removeFile(Self.availableFile)
        sendCommand(["cmd": "refresh_caps"])
    }

    // MARK: Enable / Disable

    private func applyEnabled() {
        guard !installing else { return }
        heartbeatTask?.cancel(); heartbeatTask = nil
        stopWatcher()
        let requested = enabled
        if !requested {
            if let upi = bridgedUPI {
                sendCommand(["cmd": "disconnected", "upi": upi, "reason": 0])
                bridgedUPI = nil
            }
            removeFile(Self.availableFile)
            sendCommand(["cmd": "refresh_caps"])
            daemonHealthy = false
        } else {
            refreshSIP()
            guard sipDisabled == true else {
                disableInternally("System Integrity Protection blocks Phone app integration.")
                return
            }
            guard Bundle.main.url(forResource: "GalaxyContinuityPhoneHook", withExtension: "dylib") != nil else {
                disableInternally("The Phone app hook library is missing from this build.")
                return
            }
        }

        installing = true
        status = requested ? "Enabling native macOS Phone app integration…" : "Restoring stock callservicesd…"
        installation = Task { [weak self] in
            let failure = await Task.detached(priority: .userInitiated) { () -> String? in
                guard requested else {
                    return Self.restoreStockDaemon() ? nil : "Could not restart stock callservicesd. Log out and back in."
                }
                do {
                    guard let dylib = Self.installedHookPath() else {
                        throw ContinuityError.message("Could not install the bundled Phone hook library.")
                    }
                    try Self.prepareIPC(clearHistory: true)
                    try Self.installScopedTarget(dylib)
                    return nil
                } catch {
                    let restored = Self.restoreStockDaemon()
                    return error.localizedDescription + (restored ? " Stock callservicesd restored." : " Log out and back in to restore callservicesd.")
                }
            }.value
            guard let self else { return }
            self.installing = false
            self.installation = nil
            if let failure {
                self.crashGuardTripped = FileManager.default.fileExists(atPath: Self.disabledFile.path)
                self.disableInternally("Phone app integration is off. " + failure)
                return
            }
            guard requested else {
                self.daemonHealthy = false
                self.status = "Off. Stock callservicesd restored."
                return
            }
            self.sessionID = UUID().uuidString
            self.cmdSeq = 0
            self.lastEventSeq = 0
            self.daemonHealthy = true
            self.crashGuardTripped = false
            self.status = self.calls.isRegistered
                ? "Active — calls route through macOS Phone.app."
                : "Ready — turn on Samsung Calling to expose Phone.app calling."
            self.startWatcher()
            self.publishAvailability(forceRefresh: true)
            self.heartbeatTask = Task { [weak self] in
                while !Task.isCancelled {
                    self?.publishAvailability(forceRefresh: false)
                    self?.pollDaemonEvents()
                    do { try await Task.sleep(nanoseconds: 4_000_000_000) } catch { return }
                }
            }
        }
    }

    private func disableInternally(_ message: String) {
        internalChange = true
        enabled = false
        internalChange = false
        daemonHealthy = false
        status = message
    }

    // MARK: Availability & IPC loop

    private func publishAvailability(forceRefresh: Bool) {
        guard enabled else { return }
        if FileManager.default.fileExists(atPath: Self.disabledFile.path) {
            crashGuardTripped = true
            daemonHealthy = false
            disableInternally("Phone app hook disabled by crash-loop guard.")
            return
        }
        let deviceName = deviceNameProvider?() ?? "Galaxy Phone"
        if let data = try? JSONSerialization.data(withJSONObject: ["deviceName": deviceName]) {
            try? data.write(to: Self.statusFile, options: .atomic)
            _ = chmod(Self.statusFile.path, 0o600)
        }
        let shouldExpose = calls.isRegistered
        if shouldExpose {
            FileManager.default.createFile(atPath: Self.availableFile.path, contents: nil, attributes: [.modificationDate: Date(), .posixPermissions: 0o600])
        } else {
            removeFile(Self.availableFile)
        }
        if forceRefresh || shouldExpose != lastAvailablePublished {
            lastAvailablePublished = shouldExpose
            sendCommand(["cmd": "refresh_caps"])
        }
    }

    private func startWatcher() {
        stopWatcher()
        let fd = open(Self.directory.path, O_EVTONLY)
        guard fd >= 0 else { return }
        dirFD = fd
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .extend, .attrib], queue: .main)
        source.setEventHandler { [weak self] in self?.pollDaemonEvents() }
        source.setCancelHandler { [fd] in close(fd) }
        vnodeSource = source
        source.resume()
    }

    private func stopWatcher() {
        vnodeSource?.cancel()
        vnodeSource = nil
        dirFD = -1
    }

    private func pollDaemonEvents() {
        guard enabled else { return }
        if FileManager.default.fileExists(atPath: Self.disabledFile.path) {
            crashGuardTripped = true
            daemonHealthy = false
            disableInternally("Phone app hook disabled by crash-loop guard.")
            return
        }
        var info = stat()
        guard lstat(Self.daemonEventsFile.path, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFREG, info.st_uid == getuid(), info.st_nlink == 1,
              info.st_size > 0, info.st_size <= 262_144,
              let data = try? Data(contentsOf: Self.daemonEventsFile),
              let text = String(data: data, encoding: .utf8) else { return }

        for line in text.split(whereSeparator: \.isNewline) {
            guard let lineData = String(line).data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let seq = (obj["seq"] as? NSNumber)?.uint64Value, seq > lastEventSeq else { continue }
            lastEventSeq = seq
            handleDaemonEvent(obj)
        }
    }

    private func handleDaemonEvent(_ event: [String: Any]) {
        guard let type = event["type"] as? String else { return }
        let upi = event["upi"] as? String ?? ""
        switch type {
        case "dial":
            let number = event["number"] as? String ?? ""
            guard !number.isEmpty else { return }
            if CallingEmergencyGuard.isEmergencyNumber(number) {
                note?("Emergency calls cannot be routed through Samsung Continuity.")
                if !upi.isEmpty { sendCommand(["cmd": "disconnected", "upi": upi, "reason": 1]) }
                return
            }
            guard calls.phase == .registered, calls.callState == .idle else {
                note?("Phone.app dial ignored because Samsung Calling is busy or offline.")
                if !upi.isEmpty { sendCommand(["cmd": "disconnected", "upi": upi, "reason": 1]) }
                return
            }
            bridgedUPI = upi
            calls.dial(number: number)
            if calls.callState == .idle {
                // Immediate synchronous guard refusal (e.g. invalid characters).
                sendCommand(["cmd": "disconnected", "upi": upi, "reason": 1])
                bridgedUPI = nil
            }
        case "answer":
            guard upi == bridgedUPI || calls.hasIncomingCall else { return }
            calls.answer()
        case "disconnect":
            guard bridgedUPI == nil || upi == bridgedUPI else { return }
            bridgedUPI = nil
            if calls.hasIncomingCall { calls.decline() }
            else if calls.callState != .idle { calls.hangUp() }
        case "mute":
            guard upi.isEmpty || upi == bridgedUPI else { return }
            let muted = (event["muted"] as? NSNumber)?.boolValue ?? false
            calls.setMuted(muted)
        case "dtmf":
            guard upi.isEmpty || upi == bridgedUPI,
                  let digitStr = event["digit"] as? String, let ch = digitStr.first else { return }
            calls.sendDigit(ch)
        default:
            break
        }
    }

    private func observeCallingController() {
        calls.$phase
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self, self.enabled else { return }
                self.status = self.calls.isRegistered
                    ? "Active — calls route through macOS Phone.app."
                    : "Ready — turn on Samsung Calling to expose Phone.app calling."
                self.publishAvailability(forceRefresh: true)
            }
            .store(in: &bag)

        calls.$callState
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in self?.handleCallingStateChange(state) }
            .store(in: &bag)

        calls.$muted
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] muted in
                guard let self, self.enabled, let upi = self.bridgedUPI else { return }
                self.sendCommand(["cmd": "mute", "upi": upi, "muted": muted])
            }
            .store(in: &bag)
    }

    private func handleCallingStateChange(_ state: CallingCallState) {
        guard state != lastObservedCallState else { return }
        lastObservedCallState = state
        guard isHandlingCallsNatively else {
            if state == .idle { bridgedUPI = nil }
            return
        }
        switch state {
        case .incoming:
            let upi = UUID().uuidString
            bridgedUPI = upi
            sendCommand(["cmd": "incoming", "upi": upi, "number": calls.activeRemoteNumber, "callerName": calls.activeCallerName])
        case .dialing:
            if bridgedUPI == nil {
                let upi = UUID().uuidString
                bridgedUPI = upi
                sendCommand(["cmd": "outgoing_mirror", "upi": upi, "number": calls.activeRemoteNumber, "callerName": calls.activeCallerName])
            }
        case .ringing:
            if let upi = bridgedUPI { sendCommand(["cmd": "ringing", "upi": upi]) }
        case .connecting:
            if let upi = bridgedUPI { sendCommand(["cmd": "connecting", "upi": upi]) }
        case .active:
            if let upi = bridgedUPI { sendCommand(["cmd": "connected", "upi": upi]) }
        case .ending:
            break
        case .idle:
            if let upi = bridgedUPI {
                sendCommand(["cmd": "disconnected", "upi": upi, "reason": calls.lastDisconnectReasonCode])
                bridgedUPI = nil
            }
        }
    }

    private func sendCommand(_ fields: [String: Any]) {
        guard FileManager.default.fileExists(atPath: Self.directory.path) else { return }
        cmdSeq += 1
        var payload = fields
        payload["session"] = sessionID
        payload["seq"] = cmdSeq
        guard var data = try? JSONSerialization.data(withJSONObject: payload) else { return }
        data.append(0x0A)
        let path = Self.appCommandsFile.path
        var info = stat()
        if lstat(path, &info) == 0 {
            guard (info.st_mode & S_IFMT) == S_IFREG, info.st_uid == getuid(), info.st_nlink == 1 else { return }
            if info.st_size > 131_072 && bridgedUPI == nil {
                try? data.write(to: Self.appCommandsFile, options: .atomic)
                _ = chmod(path, 0o600)
            } else if let fh = try? FileHandle(forWritingTo: Self.appCommandsFile) {
                defer { try? fh.close() }
                _ = try? fh.seekToEnd()
                try? fh.write(contentsOf: data)
            }
        } else {
            try? data.write(to: Self.appCommandsFile, options: .atomic)
            _ = chmod(path, 0o600)
        }
        // Trigger directory VNODE write notification immediately.
        FileManager.default.createFile(atPath: Self.pokeFile.path, contents: nil, attributes: [.posixPermissions: 0o600])
        try? FileManager.default.removeItem(at: Self.pokeFile)
    }

    // MARK: Scoped LaunchAgent plumbing

    private nonisolated static let jobName = "com.apple.telephonyutilities.callservicesd"
    private nonisolated static var jobDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Galaxy Continuity Lab/HookLaunchAgents", isDirectory: true)
    }

    private nonisolated static func prepareIPC(clearHistory: Bool) throws {
        var info = stat()
        if lstat(directory.path, &info) != 0 {
            guard errno == ENOENT, mkdir(directory.path, 0o700) == 0, lstat(directory.path, &info) == 0 else {
                throw ContinuityError.message("Could not create private Phone bridge storage.")
            }
        }
        guard (info.st_mode & S_IFMT) == S_IFDIR, info.st_uid == getuid(), chmod(directory.path, 0o700) == 0 else {
            throw ContinuityError.message("Phone bridge storage is not an owned directory.")
        }
        if clearHistory {
            for stale in ["daemon_events.jsonl", "app_commands.jsonl", "disabled", "startups"] {
                try? FileManager.default.removeItem(at: directory.appendingPathComponent(stale))
            }
        }
        for name in ["available", "disabled", "startups", "status.json", "app_commands.jsonl", "daemon_events.jsonl", "hook.log", ".poke"] {
            let path = directory.appendingPathComponent(name).path
            if lstat(path, &info) == 0 {
                guard (info.st_mode & S_IFMT) == S_IFREG, info.st_uid == getuid(), info.st_nlink == 1 else {
                    throw ContinuityError.message("Unexpected entry in Phone bridge storage.")
                }
                _ = chmod(path, 0o600)
            }
        }
    }

    nonisolated static func installedHookPath() -> URL? {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Galaxy Continuity Lab/GalaxyContinuityPhoneHook.dylib", isDirectory: false)
        guard let bundled = Bundle.main.url(forResource: "GalaxyContinuityPhoneHook", withExtension: "dylib") else { return nil }
        do {
            try FileManager.default.createDirectory(at: support.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            if FileManager.default.fileExists(atPath: support.path) { try FileManager.default.removeItem(at: support) }
            try FileManager.default.copyItem(at: bundled, to: support)
            return support
        } catch { return nil }
    }

    @discardableResult private nonisolated static func run(_ executable: String, _ args: [String]) -> (Int32, String) {
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = args
        process.standardOutput = pipe
        process.standardError = pipe
        do { try process.run() } catch { return (-1, "Could not run system helper.") }
        let deadline = Date().addingTimeInterval(5)
        while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
        if process.isRunning { process.terminate(); return (-1, "System helper timed out.") }
        let bytes = pipe.fileHandleForReading.readDataToEndOfFile()
        return (process.terminationStatus, String(decoding: bytes.prefix(32768), as: UTF8.self))
    }

    private nonisolated static func installScopedTarget(_ dylib: URL) throws {
        #if arch(arm64)
        let required = "arm64e"
        #else
        let required = "x86_64"
        #endif
        guard run("/usr/bin/lipo", ["-verify_arch", required, dylib.path]).0 == 0 else {
            throw ContinuityError.message("The bundled Phone hook lacks the system architecture (" + required + ").")
        }
        try FileManager.default.createDirectory(at: jobDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try Data().write(to: hookLogFile, options: .atomic)
        _ = chmod(hookLogFile.path, 0o600)
        let domain = "gui/" + String(getuid())
        let original = URL(fileURLWithPath: "/System/Library/LaunchAgents/" + jobName + ".plist")
        guard var plist = try PropertyListSerialization.propertyList(from: Data(contentsOf: original), format: nil) as? [String: Any] else {
            throw ContinuityError.message("Could not read the stock callservicesd launch agent.")
        }
        var environment = plist["EnvironmentVariables"] as? [String: String] ?? [:]
        environment["DYLD_INSERT_LIBRARIES"] = dylib.path
        plist["EnvironmentVariables"] = environment
        let local = jobDirectory.appendingPathComponent(jobName + ".plist")
        try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0).write(to: local, options: .atomic)
        _ = run("/bin/launchctl", ["bootout", domain + "/" + jobName])
        Thread.sleep(forTimeInterval: 0.5)
        guard bootstrap(domain: domain, path: local.path) else {
            _ = bootstrap(domain: domain, path: original.path)
            throw ContinuityError.message("callservicesd rejected the scoped loader.")
        }
        _ = run("/bin/launchctl", ["kickstart", domain + "/" + jobName])
        var hookConfirmed = false
        var lastRunning = false
        let waitDeadline = Date().addingTimeInterval(4.5)
        while Date() < waitDeadline {
            if FileManager.default.fileExists(atPath: disabledFile.path) {
                throw ContinuityError.message("Crash-loop guard disabled the Phone hook.")
            }
            let log = (try? String(contentsOf: hookLogFile, encoding: .utf8)) ?? ""
            let statusResult = run("/bin/launchctl", ["print", domain + "/" + jobName])
            lastRunning = (statusResult.0 == 0 && statusResult.1.contains("state = running") && statusResult.1.contains("pid = "))
            if log.contains("[callservicesd] hook install complete") && lastRunning {
                hookConfirmed = true
                break
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        guard lastRunning else {
            throw ContinuityError.message("callservicesd failed its startup check.")
        }
        guard hookConfirmed else {
            throw ContinuityError.message("callservicesd did not confirm loading the Phone hook.")
        }
        UserDefaults.standard.set("scoped-v1", forKey: "calls.phoneApp.loader")
    }

    private nonisolated static func bootstrap(domain: String, path: String) -> Bool {
        for _ in 0..<4 {
            if run("/bin/launchctl", ["bootstrap", domain, path]).0 == 0 { return true }
            Thread.sleep(forTimeInterval: 0.25)
        }
        return false
    }

    @discardableResult nonisolated static func restoreStockDaemon(force: Bool = false) -> Bool {
        let domain = "gui/" + String(getuid())
        let loaded = run("/bin/launchctl", ["print", domain + "/" + jobName]).1
        guard force || loaded.contains(jobDirectory.path) else { return true }
        _ = run("/bin/launchctl", ["bootout", domain + "/" + jobName])
        Thread.sleep(forTimeInterval: 0.5)
        let ok = bootstrap(domain: domain, path: "/System/Library/LaunchAgents/" + jobName + ".plist")
        if ok { _ = run("/bin/launchctl", ["kickstart", "-k", domain + "/" + jobName]) }
        return ok
    }

    private func removeFile(_ url: URL) { try? FileManager.default.removeItem(at: url) }
}

struct PhoneAppIntegrationSection: View {
    @ObservedObject var bridge: PhoneAppBridge

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("macOS Phone app", systemImage: "phone.connection.fill").font(.headline)
                Spacer()
                Button("Open Phone.app") {
                    NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Phone.app"))
                }
                .buttonStyle(OneUISecondaryButtonStyle())
            }
            Text("Place and answer Galaxy calls directly in Apple's native Phone app instead of a separate window. Experimental: needs SIP disabled and restarts callservicesd once. Emergency numbers and FaceTime calls always pass through untouched. With SIP enabled, you can still choose Galaxy Continuity for tel: links in FaceTime settings.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Toggle("Use macOS Phone app for Galaxy calls", isOn: $bridge.enabled)
                .toggleStyle(OneUIAlignedSwitchStyle())
                .disabled(bridge.installing)
            if let sip = bridge.sipDisabled {
                Label(sip ? "SIP is disabled — Phone app hook allowed." : "SIP is enabled — macOS will block the Phone hook.",
                      systemImage: sip ? "checkmark.shield" : "lock.shield")
                    .font(.caption)
                    .foregroundStyle(sip ? Color.green : Color.orange)
            }
            if bridge.crashGuardTripped {
                HStack {
                    Label("Crash-loop protection paused the hook.", systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(OneUI.amber)
                    Spacer()
                    Button("Reset Crash Guard") { bridge.resetCrashGuard() }
                        .buttonStyle(OneUISecondaryButtonStyle())
                }
            }
            Text(bridge.status)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
