import SwiftUI
import AppKit
import ContinuityCore

@MainActor final class FeaturesModel: ObservableObject {
    let storage = StorageShare()
    let multi = MultiControl()
    private let input = PhoneInputCapture()
    @Published var status = "Connect this Mac and your Galaxy phone to the same Wi-Fi network, then select a feature."
    @Published var busy = false
    @Published var multiConnected = false
    @Published var pointerSummary = ""
    weak var sharedCommand: ClipboardSession?
    var sharedCommandPeerAddress: String?
    @Published var storagePeerAddress = ""
    @Published var multiPeerAddress = ""
    @Published var edgeSwitching = UserDefaults.standard.bool(forKey: "multi.edgeSwitching") {
        didSet { if !AppVersion.isRenderingDemo { UserDefaults.standard.set(edgeSwitching, forKey: "multi.edgeSwitching") }; updateEdgeSwitch() }
    }
    @Published var placements: [String: DevicePlacement] = {
        guard let data = UserDefaults.standard.data(forKey: "multi.devicePlacements") else { return [:] }
        return (try? JSONDecoder().decode([String: DevicePlacement].self, from: data)) ?? [:]
    }()
    private let edge = EdgeSwitch()
    private var started = false
    private var takingControl = false
    var trace: ((String) -> Void)?
    private var operation: Task<Void, Never>?
    private func note(_ text: String) { status = text; trace?(text) }
    func start() {
        guard !started else { return }; started = true
        storage.status = { [weak self] in self?.note($0) }
        storage.changed = { [weak self] in self?.objectWillChange.send() }
        multi.status = { [weak self] in self?.note($0) }
        multi.changed = { [weak self] in
            guard let self else { return }
            self.multiConnected = self.multi.connected
            self.updateEdgeSwitch(); self.objectWillChange.send()
        }
        multi.released = { [weak self] in self?.input.stop(); self?.objectWillChange.send() }
        input.failed = { [weak self] in self?.note($0) }
        input.summary = { [weak self] in self?.pointerSummary = $0; self?.trace?($0) }
        input.ended = { [weak self] in self?.edge.returnToMac() }
        edge.canEnter = { [weak self] in
            guard let self else { return false }
            return self.multi.isReadyForControl && !self.multi.controlling && !self.input.active && !self.takingControl && !self.busy
        }
        edge.enter = { [weak self] fraction in self?.control(entryFraction: fraction) }
    }
    func placement(for address: String) -> DevicePlacement { placements[address] ?? DevicePlacement() }
    func ensurePlacements(_ addresses: [String]) {
        for (index, address) in addresses.enumerated() where placements[address] == nil {
            place(address, DevicePlacement(side: DeviceSide.allCases[index % 4], offset: index >= 4 ? 0.5 : 0))
        }
    }
    func place(_ address: String, _ value: DevicePlacement) {
        placements[address] = value
        if !AppVersion.isRenderingDemo, let data = try? JSONEncoder().encode(placements) { UserDefaults.standard.set(data, forKey: "multi.devicePlacements") }
        if address == multiPeerAddress {
            Task { do { try await multi.configurePlacement(value) } catch { note(error.localizedDescription) } }
            updateEdgeSwitch()
        }
    }
    private func updateEdgeSwitch() {
        guard edgeSwitching, multi.isReadyForControl else { edge.stop(); return }
        do { try edge.start(placement(for: multiPeerAddress)) }
        catch { edgeSwitching = false; note(error.localizedDescription) }
    }
    private func command(for profile: ContinuityProfile) -> ClipboardSession? {
        guard profile.preferredPeerAddress?.caseInsensitiveCompare(sharedCommandPeerAddress ?? "") == .orderedSame else { return nil }
        return sharedCommand
    }
    func connectStorage(profile: ContinuityProfile, device: ContinuityDevice?) {
        guard !busy else { return }; busy = true
        operation = Task {
            defer { busy = false }
            do {
                input.stop(); edge.stop(); await multi.disconnect(); multiConnected = false
                storagePeerAddress = profile.preferredPeerAddress ?? ""
                try await storage.connect(profile: profile, host: device?.host, port: device.flatMap { UInt16(exactly: $0.port) }, sharing: command(for: profile))
            }
            catch { note(error.localizedDescription) }
        }
    }
    func connectMulti(profile base: ContinuityProfile, device: ContinuityDevice?) {
        guard !busy else { return }; busy = true
        var profile = base
        // Test hook: `--peer <bluetooth address>` targets one peer (for example the tablet) without changing the saved profile.
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--peer"), i + 1 < args.count { profile.preferredPeerAddress = args[i + 1] }
        operation = Task {
            defer { busy = false }
            do {
                await storage.disconnect()
                guard storage.mountURL == nil else { throw ContinuityError.message("Close files on the phone drive and disconnect storage before starting Multi Control.") }
                input.stop(); edge.stop()
                multiPeerAddress = profile.preferredPeerAddress ?? ""
                let placement = placement(for: multiPeerAddress)
                let screen = NSScreen.screens.first { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == placement.screenID } ?? NSScreen.main
                let size = screen?.frame.size ?? NSSize(width: 1440, height: 900)
                try await multi.configurePlacement(placement)
                try await multi.connect(profile: profile, width: Int(size.width), height: Int(size.height), host: device?.host, port: device.flatMap { UInt16(exactly: $0.port) }, sharing: command(for: profile))
                multiConnected = true
                autoControlIfRequested()
            } catch { multiConnected = false; note(error.localizedDescription) }
        }
    }
    func control(entryFraction: Double? = nil) {
        guard !takingControl, !input.active, multi.isReadyForControl else { return }
        takingControl = true
        do {
            try input.start(multi)
            Task {
                defer { takingControl = false }
                do { try await multi.takeControl(entryFraction: entryFraction); if !input.active { await multi.release() } }
                catch { input.stop(); note(error.localizedDescription) }
                objectWillChange.send()
            }
        } catch { takingControl = false; note(error.localizedDescription) }
    }
    /// Test hooks: `--multi-autocontrol` takes control once the phone is ready; with
    /// `--pointer-selftest <hz> <seconds>` it then drives a synthetic stream, stops and
    /// logs the summary (`--pointer-selftest-quit` also quits the app).
    private func autoControlIfRequested() {
        let args = CommandLine.arguments
        guard args.contains("--multi-autocontrol") else { return }
        Task { [self] in
            for _ in 0..<300 where !multi.isReadyForControl { try? await Task.sleep(nanoseconds: 100_000_000) }
            guard multi.isReadyForControl else { note("Autocontrol: phone display information never arrived."); return }
            control()
            for _ in 0..<100 where !multi.controlling { try? await Task.sleep(nanoseconds: 100_000_000) }
            guard multi.controlling, let test = PointerSelfTest.arguments() else { return }
            note("Selftest: controlling; \(PointerOptions.load().description)")
            try? await Task.sleep(nanoseconds: 500_000_000)
            PointerSelfTest.run(hz: test.hz, seconds: test.seconds) { [weak self] text in
                Task { @MainActor in
                    guard let self else { return }
                    self.note(text)
                    try? await Task.sleep(nanoseconds: 300_000_000)
                    self.input.stop()
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    if args.contains("--pointer-selftest-quit") { NSApp.terminate(nil) }
                }
            }
        }
    }
    func disconnectMulti() { input.stop(); edge.stop(); Task { await multi.disconnect() }; multiConnected = false }
    func stop() { input.stop(); edge.stop(); operation?.cancel(); multiConnected = false; Task { await multi.disconnect(); await storage.disconnect() } }
}
