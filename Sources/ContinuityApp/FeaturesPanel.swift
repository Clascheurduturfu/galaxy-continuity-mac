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
    var trace: ((String) -> Void)?
    private var operation: Task<Void, Never>?
    private func note(_ text: String) { status = text; trace?(text) }
    func start() {
        storage.status = { [weak self] in self?.note($0) }
        storage.changed = { [weak self] in self?.objectWillChange.send() }
        multi.status = { [weak self] in self?.note($0) }
        multi.changed = { [weak self] in self?.objectWillChange.send() }
        multi.released = { [weak self] in self?.input.stop(); self?.objectWillChange.send() }
        input.failed = { [weak self] in self?.note($0) }
        input.summary = { [weak self] in self?.pointerSummary = $0; self?.trace?($0) }
    }
    func connectStorage(profile: ContinuityProfile, device: ContinuityDevice?) {
        guard !busy else { return }; busy = true
        operation = Task {
            defer { busy = false }
            do {
                await multi.disconnect(); multiConnected = false
                try await storage.connect(profile: profile, host: device?.host, port: device.flatMap { UInt16(exactly: $0.port) }, sharing: sharedCommand)
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
                let size = NSScreen.main?.frame.size ?? NSSize(width: 1440, height: 900)
                try await multi.connect(profile: profile, width: Int(size.width), height: Int(size.height), host: device?.host, port: device.flatMap { UInt16(exactly: $0.port) }, sharing: sharedCommand)
                multiConnected = true
                autoControlIfRequested()
            } catch { multiConnected = false; note(error.localizedDescription) }
        }
    }
    func control() {
        do {
            try input.start(multi)
            Task {
                do { try await multi.takeControl(); if !input.active { await multi.release() } }
                catch { input.stop(); note(error.localizedDescription) }
                objectWillChange.send()
            }
        } catch { note(error.localizedDescription) }
    }
    /// Test hooks: `--multi-autocontrol` takes control once the phone is ready; with
    /// `--pointer-selftest <hz> <seconds>` it then drives a synthetic stream, stops and
    /// logs the summary (`--pointer-selftest-quit` also quits the app).
    private func autoControlIfRequested() {
        let args = CommandLine.arguments
        guard args.contains("--multi-autocontrol") else { return }
        Task {
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
    func stop() { input.stop(); operation?.cancel(); multiConnected = false; Task { await multi.disconnect(); await storage.disconnect() } }
}

struct FeaturesPanel: View {
    @ObservedObject var model: FeaturesModel
    let profile: ContinuityProfile
    let device: ContinuityDevice?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                OneUIPageHeader("Storage & Multi Control", subtitle: "Browse your Galaxy phone in Finder or control it with this Mac's keyboard and trackpad") {
                    HStack(spacing: 8) {
                        if model.busy { ProgressView().controlSize(.small) }
                        OneUIStatusPill(
                            model.storage.mountURL != nil ? "Storage Mounted" : (model.multi.controlling ? "Controlling Phone" : (model.multiConnected ? "Multi Control Ready" : "Idle")),
                            tone: (model.storage.mountURL != nil || model.multi.controlling) ? .connected : (model.multiConnected ? .active : .neutral)
                        )
                    }
                }

                OneUICard {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack(spacing: 14) {
                            ZStack {
                                Circle()
                                    .fill(LinearGradient(colors: [OneUI.blue, OneUI.deepBlue], startPoint: .topLeading, endPoint: .bottomTrailing))
                                    .frame(width: 48, height: 48)
                                Image(systemName: "externaldrive.fill.badge.wifi")
                                    .font(.system(size: 20, weight: .semibold))
                                    .foregroundStyle(.white)
                            }
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Storage Share")
                                    .font(.system(size: 17, weight: .bold, design: .rounded))
                                Text("Mounts your phone's storage in Finder over Wi-Fi using temporary per-session SMB 2 credentials.")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            OneUIStatusPill(model.storage.mountURL != nil ? "Mounted" : "Disconnected", tone: model.storage.mountURL != nil ? .connected : .neutral)
                        }

                        Divider()

                        HStack(spacing: 10) {
                            Button("Connect Phone Storage") {
                                model.connectStorage(profile: profile, device: device)
                            }
                            .buttonStyle(OneUIPrimaryButtonStyle())
                            .disabled(model.busy || model.storage.mountURL != nil)

                            if let url = model.storage.mountURL {
                                Button("Open in Finder") {
                                    NSWorkspace.shared.open(url)
                                }
                                .buttonStyle(OneUISecondaryButtonStyle())
                            }

                            Button("Disconnect Storage") {
                                Task { await model.storage.disconnect() }
                            }
                            .buttonStyle(OneUISecondaryButtonStyle())
                            .disabled(model.busy || model.storage.mountURL == nil)
                        }
                    }
                }

                OneUICard {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack(spacing: 14) {
                            ZStack {
                                Circle()
                                    .fill(LinearGradient(colors: [OneUI.blue, OneUI.deepBlue], startPoint: .topLeading, endPoint: .bottomTrailing))
                                    .frame(width: 48, height: 48)
                                Image(systemName: "CursorArrow")
                                    .font(.system(size: 20, weight: .semibold))
                                    .foregroundStyle(.white)
                                    .overlay {
                                        Image(systemName: "rectangle.connected.to.line.below")
                                            .font(.system(size: 20, weight: .semibold))
                                            .foregroundStyle(.white)
                                    }
                            }
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Multi Control")
                                    .font(.system(size: 17, weight: .bold, design: .rounded))
                                Text("Use your Mac's mouse, trackpad and keyboard directly on your Galaxy phone or tablet. Press Escape at any time to return input to your Mac.")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            OneUIStatusPill(
                                model.multi.controlling ? "Controlling" : (model.multiConnected ? "Connected" : "Disconnected"),
                                tone: model.multi.controlling ? .connected : (model.multiConnected ? .active : .neutral)
                            )
                        }

                        Divider()

                        HStack(spacing: 10) {
                            Button("Connect Multi Control") {
                                model.connectMulti(profile: profile, device: device)
                            }
                            .buttonStyle(OneUIPrimaryButtonStyle())
                            .disabled(model.busy || model.multiConnected)

                            if model.multiConnected {
                                Button("Control Phone Now") {
                                    model.control()
                                }
                                .buttonStyle(OneUIPrimaryButtonStyle(tint: OneUI.green))
                                .disabled(model.multi.controlling)

                                Button("Release Input (Esc)") {
                                    Task { await model.multi.release() }
                                }
                                .buttonStyle(OneUISecondaryButtonStyle())
                                .disabled(!model.multi.controlling)
                            }

                            Button("Disconnect") {
                                Task { await model.multi.disconnect(); model.multiConnected = false }
                            }
                            .buttonStyle(OneUISecondaryButtonStyle())
                            .disabled(!model.multiConnected)
                        }

                        if !model.pointerSummary.isEmpty {
                            DisclosureGroup("Pointer & UDP Telemetry") {
                                Text(model.pointerSummary)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                                    .padding(.top, 4)
                            }
                            .font(.system(size: 12, weight: .medium))
                        }
                    }
                }

                OneUICard(padding: 16) {
                    HStack(spacing: 10) {
                        Image(systemName: "wave.3.right")
                            .foregroundStyle(OneUI.blue)
                        Text(model.status)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
            }
            .padding(28)
        }
    }
}
