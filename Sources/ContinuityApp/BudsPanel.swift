import SwiftUI
import AppKit
import ContinuityCore

@MainActor final class BudsModel: ObservableObject {
    @Published var devices: [PairedBuds] = []
    @Published var selection: String = UserDefaults.standard.string(forKey: "buds.selectedDevice") ?? "" {
        didSet {
            if !selection.isEmpty {
                UserDefaults.standard.set(selection, forKey: "buds.selectedDevice")
            }
        }
    }
    @Published var status = "Pair your Galaxy Buds with this Mac, then refresh the list."
    @Published var busy = false
    @Published var connected = false
    @Published var peerStatus = ""
    @Published var automaticSwitching: Bool = UserDefaults.standard.bool(forKey: "buds.automaticSwitching")
    private let connection = BudsConnection()
    private var operation: Task<Void, Never>?
    private var audioMonitor: Task<Void, Never>?
    private var switchMonitor: Task<Void, Never>?
    var trace: ((String) -> Void)?

    private func note(_ value: String) {
        status = value
        trace?("Buds: " + value)
    }

    func start() {
        connection.status = { [weak self] in self?.note($0) }
        connection.closed = { [weak self] in self?.connected = false; self?.audioMonitor?.cancel() }
        connection.diagnostic = { [weak self] in self?.trace?("Buds: " + $0) }
        connection.received = { [weak self] packet in
            self?.trace?(String(format: "Buds: Received message 0x%02x, %d bytes.", packet.id, packet.payload.count))
            if let supported = packet.supportsMultipoint { self?.trace?("Buds: Multipoint supported: \(supported).") }
            if let state = packet.multipointStatus {
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
    }

    func refresh() {
        guard !busy, !connected else { return }
        devices = BudsConnection.pairedDevices()
        let saved = UserDefaults.standard.string(forKey: "buds.selectedDevice") ?? ""
        if !saved.isEmpty, devices.contains(where: { $0.id == saved }) {
            selection = saved
        } else if !devices.contains(where: { $0.id == selection }) {
            selection = devices.first?.id ?? ""
        }
        note(devices.isEmpty ? "No paired Galaxy Buds found. Pair them in macOS Bluetooth settings, then refresh." : "Ready for Galaxy Buds audio handoff.")
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

    private func monitorAudio() {
        audioMonitor?.cancel()
        guard let chosen = devices.first(where: { $0.id == selection }) else { return }
        audioMonitor = Task {
            var previous: BudsAudio.State?
            while !Task.isCancelled, connected {
                do {
                    let state = try BudsAudio.state(address: chosen.id, name: chosen.name)
                    if state != previous {
                        try connection.send(.output(selected: state.selected))
                        try connection.send(.playback(playing: state.playing))
                        trace?("Buds: Mac output selected: \(state.selected); playback running: \(state.playing).")
                        previous = state
                    }
                    try await Task.sleep(nanoseconds: 500_000_000)
                } catch {
                    if !Task.isCancelled { trace?("Buds: Audio-state reporting stopped: " + error.localizedDescription) }
                    break
                }
            }
        }
    }

    func setAutomaticSwitching(_ enabled: Bool, persist: Bool = true) {
        automaticSwitching = enabled
        if persist { UserDefaults.standard.set(enabled, forKey: "buds.automaticSwitching") }
        switchMonitor?.cancel()
        switchMonitor = nil
        guard enabled else { return }
        note("Auto Switch active: watching Mac audio playback.")
        switchMonitor = Task {
            var wasPlaying = false
            while !Task.isCancelled, automaticSwitching {
                let playing = BudsAudio.defaultOutputIsPlaying()
                if playing && !wasPlaying, !busy, !selection.isEmpty {
                    trace?("Buds: Mac playback started; requesting audio (control connected: \(connected)).")
                    if connected { takeAudio() } else { connect(takeAfter: true) }
                }
                wasPlaying = playing
                do { try await Task.sleep(nanoseconds: 300_000_000) } catch { break }
            }
        }
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
        } else {
            switchMonitor?.cancel()
            switchMonitor = nil
        }
        audioMonitor?.cancel()
        audioMonitor = nil
        operation?.cancel()
        operation = nil
        connection.disconnect()
        connected = false
        busy = false
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
                OneUIPageHeader("Galaxy Buds", subtitle: "Seamless MDE V3 audio handoff between your Galaxy phone and Mac") {
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
                                .buttonStyle(OneUISecondaryButtonStyle())
                                .disabled(model.busy || model.connected)

                            Button("Bluetooth Settings…") {
                                if let url = URL(string: "x-apple.systempreferences:com.apple.Bluetooth") {
                                    NSWorkspace.shared.open(url)
                                }
                            }
                            .buttonStyle(OneUISecondaryButtonStyle())
                        }

                        HStack(spacing: 10) {
                            Button(model.busy ? "Working…" : (model.connected ? "Take Audio on Mac" : "Connect & Take Audio")) {
                                model.takeAudio()
                            }
                            .buttonStyle(OneUIPrimaryButtonStyle())
                            .disabled(model.selection.isEmpty || model.busy)

                            if !model.connected {
                                Button("Open Control Channel") { model.connect() }
                                    .buttonStyle(OneUISecondaryButtonStyle())
                                    .disabled(model.selection.isEmpty || model.busy)
                            } else {
                                Button("Close Control") { model.stop() }
                                    .buttonStyle(OneUISecondaryButtonStyle())
                                    .disabled(model.busy)
                            }

                            Button("Disconnect Buds") { model.releaseBuds() }
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
                            }
                            Spacer()
                            Toggle("", isOn: Binding(get: { model.automaticSwitching }, set: { model.setAutomaticSwitching($0) }))
                                .toggleStyle(.switch)
                                .labelsHidden()
                                .disabled(model.selection.isEmpty)
                        }
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
