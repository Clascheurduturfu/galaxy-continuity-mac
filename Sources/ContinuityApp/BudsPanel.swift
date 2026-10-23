import SwiftUI
import AppKit
import ContinuityCore

@MainActor final class BudsModel: ObservableObject {
    @Published var devices: [PairedBuds] = []
    @Published var selection: String = UserDefaults.standard.string(forKey: "buds.selectedDevice") ?? "" {
        didSet {
            if !AppVersion.isRenderingDemo, !selection.isEmpty {
                UserDefaults.standard.set(selection, forKey: "buds.selectedDevice")
            }
        }
    }
    @Published var status = "Pair your Galaxy Buds with this Mac, then refresh the list."
    @Published var busy = false
    @Published var connected = false
    @Published var peerStatus = ""
    @Published var automaticSwitching: Bool = UserDefaults.standard.bool(forKey: "buds.automaticSwitching")
    @Published var pauseOnTakeover = UserDefaults.standard.object(forKey: "buds.pauseOnTakeover") as? Bool ?? true {
        didSet { if !AppVersion.isRenderingDemo { UserDefaults.standard.set(pauseOnTakeover, forKey: "buds.pauseOnTakeover") }; if started { updatePlaybackObservation() } }
    }
    private let connection = BudsConnection()
    private var operation: Task<Void, Never>?
    private let playback = BudsPlaybackObserver()
    private var lastDefaultPlaying = false
    private var lastBudsPlayingAt = Date.distantPast
    private var otherDeviceActive = false
    private var stoppedSinceTakeover = true
    private var previousAudioState: BudsAudio.State?
    private var takeoverPauseSent = false
    private var started = false
    var trace: ((String) -> Void)?

    private func note(_ value: String) {
        status = value
        trace?("Buds: " + value)
    }

    func start() {
        guard !started else { return }; started = true
        selection = PairedBuds.canonicalID(selection)
        connection.status = { [weak self] in self?.note($0) }
        connection.closed = { [weak self] in self?.connected = false; self?.updatePlaybackObservation() }
        connection.diagnostic = { [weak self] in self?.trace?("Buds: " + $0) }
        connection.received = { [weak self] packet in
            self?.trace?(String(format: "Buds: Received message 0x%02x, %d bytes.", packet.id, packet.payload.count))
            if let supported = packet.supportsMultipoint { self?.trace?("Buds: Multipoint supported: \(supported).") }
            if let state = packet.multipointStatus {
                if let self {
                    if state.background, !self.otherDeviceActive, self.pauseOnTakeover,
                       ((self.previousAudioState?.selected == true && self.previousAudioState?.playing == true) || Date().timeIntervalSince(self.lastBudsPlayingAt) < 3) {
                        self.pauseForTakeover()
                    }
                    self.otherDeviceActive = state.background
                }
                let text = "Buds report: \(state.background ? "background" : "foreground"), stream \(state.stream), reason \(state.reason)."
                self?.trace?("Buds: " + text)
                if state.stream & 0x80 != 0 { self?.peerStatus = state.background ? "Another device is requesting audio." : "Mac audio switch in progress." }
                else if state.stream != 0 { self?.peerStatus = state.background ? "Audio is active on the other device." : "Audio is active on the Mac." }
                else { self?.peerStatus = state.background ? "Buds connected · other device active" : "Buds connected · Mac active" }
            }
        }
        refresh()
        if CommandLine.arguments.contains("--buds-disconnect-test") { releaseBuds() }
        if CommandLine.arguments.contains("--buds-auto-switch-test") { setAutomaticSwitching(true) }
        else if CommandLine.arguments.contains("--buds-probe") { connect(takeAfter: CommandLine.arguments.contains("--buds-take-audio-test")) }
        else if automaticSwitching, !selection.isEmpty { setAutomaticSwitching(true, persist: false) }
        updatePlaybackObservation()
    }

    func refresh() {
        guard !busy, !connected else { return }
        devices = BudsConnection.pairedDevices()
        let saved = PairedBuds.canonicalID(UserDefaults.standard.string(forKey: "buds.selectedDevice") ?? "")
        if !saved.isEmpty, devices.contains(where: { $0.id == saved }) {
            selection = saved
        } else if !devices.contains(where: { $0.id == selection }) {
            selection = devices.first?.id ?? ""
        }
        note(devices.isEmpty ? "No paired Galaxy Buds found. Pair them in macOS Bluetooth settings, then refresh." : "Ready for Galaxy Buds audio handoff.")
        if started { updatePlaybackObservation() }
    }

    func connect(takeAfter: Bool = false) {
        guard !busy, !connected, devices.contains(where: { $0.id == selection }) else { return }
        busy = true
        operation = Task {
            defer { busy = false }
            do {
                try await connection.connect(address: selection)
                try Task.checkCancellation()
                connected = true
                monitorAudio()
                if takeAfter { try await requestAudio() }
            } catch {
                connection.disconnect()
                connected = false
                note(error.localizedDescription)
            }
        }
    }

    func takeAudio() {
        guard !busy else { return }
        if !connected {
            connect(takeAfter: true)
            return
        }
        busy = true
        operation = Task {
            defer { busy = false }
            do { try await requestAudio() } catch { note(error.localizedDescription) }
        }
    }

    private func requestAudio() async throws {
        guard let chosen = devices.first(where: { $0.id == selection }) else { return }
        try connection.takeAudio()
        note("Requested the Buds audio switch. Waiting for the Mac output…")
        for _ in 0..<20 {
            try Task.checkCancellation()
            if try BudsAudio.selectOutput(address: chosen.id, name: chosen.name) {
                note("macOS selected \(chosen.name) as its audio output.")
                return
            }
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        note("The switch request was sent, but no matching Mac audio output appeared. Check the Buds connection in Bluetooth settings.")
    }

    private func monitorAudio() { previousAudioState = nil; updatePlaybackObservation() }
    private func updatePlaybackObservation() {
        playback.changed = { [weak self] in self?.audioChanged() }
        if connected || automaticSwitching || (pauseOnTakeover && !selection.isEmpty) { playback.start() } else { playback.stop() }
    }
    private func pauseForTakeover() {
        guard pauseOnTakeover, !takeoverPauseSent else { return }
        takeoverPauseSent = true; stoppedSinceTakeover = false; otherDeviceActive = true
        note(MacMediaPause.request() ? "Requested pause in the Mac's active media player." : "macOS did not accept the media pause command; pause your player manually.")
    }
    private func audioChanged() {
        if previousAudioState?.selected == true && previousAudioState?.playing == true { lastBudsPlayingAt = Date() }
        let playing = BudsAudio.defaultOutputIsPlaying()
        if !playing { stoppedSinceTakeover = true }
        if let chosen = devices.first(where: { $0.id == selection }),
           let state = try? BudsAudio.state(address: chosen.id, name: chosen.name) {
            if previousAudioState?.selected == true && previousAudioState?.playing == true && !state.selected { pauseForTakeover() }
            if state.selected && state.playing { lastBudsPlayingAt = Date(); takeoverPauseSent = false }
            if state != previousAudioState {
                if connected {
                    try? connection.send(.output(selected: state.selected))
                    try? connection.send(.playback(playing: state.playing))
                }
                previousAudioState = state
            }
        }
        let beganPlaying = playing && !lastDefaultPlaying
        lastDefaultPlaying = playing
        if automaticSwitching, beganPlaying, !busy, !selection.isEmpty,
           !otherDeviceActive || stoppedSinceTakeover {
            if connected { takeAudio() } else { connect(takeAfter: true) }
        }
    }

    func setAutomaticSwitching(_ enabled: Bool, persist: Bool = true) {
        automaticSwitching = enabled
        if persist { UserDefaults.standard.set(enabled, forKey: "buds.automaticSwitching") }
        if enabled { note("Auto Switch active: listening for Mac playback changes.") }
        updatePlaybackObservation()
    }

    func releaseBuds() {
        stop(clearAutoSwitch: false)
        do {
            try BudsConnection.disconnectPairedDevice(address: selection)
            peerStatus = ""
            note("Disconnected the Buds from the Mac. Phone pairing is retained.")
        } catch { note(error.localizedDescription) }
    }

    func stop(clearAutoSwitch: Bool = false) {
        if clearAutoSwitch {
            setAutomaticSwitching(false, persist: true)
        }
        playback.stop()
        operation?.cancel()
        operation = nil
        connection.disconnect()
        connected = false
        busy = false
        if !clearAutoSwitch { updatePlaybackObservation() }
    }

    var selectedName: String {
        devices.first(where: { $0.id == selection })?.name ?? "Galaxy Buds"
    }
}

struct BudsPanel: View {
    @ObservedObject var model: BudsModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                OneUIPageHeader("Galaxy Buds", subtitle: "Switch audio between your Galaxy devices and Mac") {
                    OneUIStatusPill(
                        model.connected ? "Connected" : (model.automaticSwitching ? "Auto Switch On" : "Standby"),
                        tone: model.connected ? .connected : (model.automaticSwitching ? .active : .neutral)
                    )
                }

                OneUICard {
                    VStack(alignment: .leading, spacing: 16) {
                        HStack(spacing: 16) {
                            ZStack {
                                Circle()
                                    .fill(LinearGradient(colors: [OneUI.blue, OneUI.deepBlue], startPoint: .topLeading, endPoint: .bottomTrailing))
                                    .frame(width: 54, height: 54)
                                Image(systemName: "earbuds")
                                    .font(.system(size: 24, weight: .semibold))
                                    .foregroundStyle(.white)
                            }
                            VStack(alignment: .leading, spacing: 4) {
                                Text(model.devices.isEmpty ? "No Paired Galaxy Buds" : model.selectedName)
                                    .font(.system(size: 18, weight: .bold, design: .rounded))
                                Text(model.peerStatus.isEmpty ? model.status : model.peerStatus)
                                    .font(.system(size: 13))
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                            }
                            Spacer()
                            if model.busy {
                                ProgressView().controlSize(.small)
                            }
                        }

                        Divider()

                        HStack(spacing: 12) {
                            Picker("Paired Buds", selection: $model.selection) {
                                if model.devices.isEmpty { Text("Pair Buds in Bluetooth settings first").tag("") }
                                ForEach(model.devices) { Text($0.name).tag($0.id) }
                            }
                            .frame(maxWidth: 320)
                            .disabled(model.busy || model.connected)

                            Button("Refresh") { model.refresh() }
                                .help("Reload the Galaxy Buds already paired in macOS Bluetooth settings.")
                                .buttonStyle(OneUISecondaryButtonStyle())
                                .disabled(model.busy || model.connected)

                            Button("Bluetooth Settings…") {
                                if let url = URL(string: "x-apple.systempreferences:com.apple.Bluetooth") {
                                    NSWorkspace.shared.open(url)
                                }
                            }
                            .buttonStyle(OneUISecondaryButtonStyle())
                            .help("Open macOS Bluetooth settings to pair Buds, reconnect them, or remove an old pairing.")
                        }

                        HStack(spacing: 10) {
                            Button(model.busy ? "Working…" : "Take Audio on Mac") {
                                model.takeAudio()
                            }
                            .buttonStyle(OneUIPrimaryButtonStyle())
                            .disabled(model.selection.isEmpty || model.busy)
                            .help("Connect the selected Buds if needed, ask them to switch to this Mac, then select them as the Mac audio output.")

                            Button("Disconnect Buds") { model.releaseBuds() }
                                .help("Disconnect the Buds from this Mac without forgetting their pairing or changing the phone's connection. Auto Switch can reconnect on later Mac playback.")
                                .buttonStyle(OneUISecondaryButtonStyle())
                                .disabled(model.selection.isEmpty || model.busy)
                        }
                    }
                }

                OneUICard {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Auto Switch on Mac Playback")
                                    .font(.system(size: 15, weight: .semibold))
                                Text("Automatically connects and pulls audio to this Mac when media starts playing, even if the Buds are currently connected only to your phone.")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer()
                            Toggle("", isOn: Binding(get: { model.automaticSwitching }, set: { model.setAutomaticSwitching($0) }))
                                .toggleStyle(.switch)
                                .labelsHidden()
                                .disabled(model.selection.isEmpty)
                        }
                        Divider()
                        Toggle("Pause Mac playback when another device takes the Buds", isOn: $model.pauseOnTakeover)
                            .toggleStyle(.switch)
                        Text("Also pauses if the Mac loses the Buds audio route. Uses the active player's system pause command; support depends on the player and macOS. Never resumes playback automatically.")
                            .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        Divider()
                        Label("Pair your Buds with this Mac once. If first pairing disconnected your phone, reconnect them once in the phone's Bluetooth settings so both links coexist.", systemImage: "info.circle")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(28)
        }
    }
}
