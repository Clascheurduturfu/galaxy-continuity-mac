import SwiftUI
import AppKit
import Combine
import ContinuityCore

@MainActor final class CallsModel: ObservableObject {
    let calls = CallingController.shared
    @Published var samsungStatus = "Samsung Call & Text on Other Devices (CMC) registers this Mac over Wi-Fi and the Internet."
    @Published var callNumber = ""
    @Published var checkingSamsung = false
    private var bag = Set<AnyCancellable>()

    func start() {
        calls.objectWillChange
            .sink { [weak self] _ in DispatchQueue.main.async { self?.objectWillChange.send() } }
            .store(in: &bag)
    }

    func checkSamsung(transport: Bool = false) {
        guard !checkingSamsung else { return }
        checkingSamsung = true
        Task {
            defer { checkingSamsung = false }
            do {
                if transport {
                    samsungStatus = try await ContinuitySignIn.shared.checkCallingTransport(status: { self.samsungStatus = $0 })
                } else {
                    samsungStatus = try await ContinuitySignIn.shared.checkCallingAccount(status: { self.samsungStatus = $0 })
                }
            } catch {
                samsungStatus = error.localizedDescription
            }
        }
    }

    func tapKey(_ digit: Character) {
        if calls.callState == .active {
            calls.sendDigit(digit)
        } else {
            callNumber.append(digit)
        }
    }

    var phaseLabel: String {
        switch calls.phase {
        case .registered: return "Registered"
        case .stopped: return "Off"
        case .enrolling: return "Enrolling…"
        case .connecting: return "Connecting…"
        case .reconnecting: return "Reconnecting…"
        case .failed: return "Error"
        }
    }

    var phaseTone: StatusTone {
        switch calls.phase {
        case .registered: return .connected
        case .stopped: return .neutral
        case .enrolling, .connecting, .reconnecting: return .warning
        case .failed: return .error
        }
    }
}

struct CallsPanel: View {
    @StateObject private var model = CallsModel()
    private let keypadRows: [[Character]] = [
        ["1", "2", "3"],
        ["4", "5", "6"],
        ["7", "8", "9"],
        ["*", "0", "#"]
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                OneUIPageHeader("Phone Calls", subtitle: "Place and answer calls through Samsung Call & Text on Other Devices (CMC)") {
                    OneUIStatusPill(model.phaseLabel, tone: model.phaseTone)
                }

                OneUICard {
                    HStack(spacing: 16) {
                        ZStack {
                            Circle()
                                .fill(
                                    model.calls.phase == .registered
                                        ? LinearGradient(colors: [OneUI.green, OneUI.green.opacity(0.8)], startPoint: .topLeading, endPoint: .bottomTrailing)
                                        : LinearGradient(colors: [OneUI.blue, OneUI.deepBlue], startPoint: .topLeading, endPoint: .bottomTrailing)
                                )
                                .frame(width: 52, height: 52)
                            Image(systemName: model.calls.phase == .registered ? "phone.badge.checkmark" : "phone.fill")
                                .font(.system(size: 22, weight: .semibold))
                                .foregroundStyle(.white)
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Samsung Wi-Fi & Cloud Calling")
                                .font(.system(size: 17, weight: .bold, design: .rounded))
                            Text(model.calls.status)
                                .font(.system(size: 13))
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                        Spacer()
                        Button(model.calls.phase == .stopped ? "Turn On Calling" : "Turn Off") {
                            if model.calls.phase == .stopped { model.calls.start() } else { model.calls.stop() }
                        }
                        .buttonStyle(OneUIPrimaryButtonStyle(tint: model.calls.phase == .stopped ? OneUI.blue : OneUI.red))
                        .disabled(model.calls.phase == .enrolling || model.calls.phase == .connecting)
                    }
                }

                if case .incoming(let who) = model.calls.callState {
                    OneUICard {
                        HStack(spacing: 16) {
                            Image(systemName: "phone.down.waves.left.and.right")
                                .font(.system(size: 28, weight: .semibold))
                                .foregroundStyle(OneUI.green)
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Incoming Call")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(OneUI.green)
                                Text(who)
                                    .font(.system(size: 20, weight: .bold, design: .rounded))
                                    .textSelection(.enabled)
                            }
                            Spacer()
                            Button("Decline") { model.calls.decline() }
                                .buttonStyle(OneUIPrimaryButtonStyle(tint: OneUI.red))
                            Button("Answer") { model.calls.answer() }
                                .buttonStyle(OneUIPrimaryButtonStyle(tint: OneUI.green))
                        }
                    }
                }

                HStack(alignment: .top, spacing: 20) {
                    OneUICard {
                        VStack(alignment: .leading, spacing: 14) {
                            Text("Keypad & Dialer")
                                .font(.system(size: 15, weight: .semibold))

                            HStack(spacing: 8) {
                                TextField("Enter phone number…", text: $model.callNumber)
                                    .textFieldStyle(.plain)
                                    .font(.system(size: 20, weight: .semibold, design: .rounded))
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 10)
                                    .background(
                                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                                            .fill(Color.primary.opacity(0.05))
                                    )
                                if !model.callNumber.isEmpty {
                                    Button {
                                        _ = model.callNumber.popLast()
                                    } label: {
                                        Image(systemName: "delete.left.fill")
                                            .font(.system(size: 16))
                                            .foregroundStyle(.secondary)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }

                            VStack(spacing: 8) {
                                ForEach(keypadRows, id: \.self) { row in
                                    HStack(spacing: 10) {
                                        ForEach(row, id: \.self) { digit in
                                            Button {
                                                model.tapKey(digit)
                                            } label: {
                                                Text(String(digit))
                                                    .font(.system(size: 18, weight: .semibold, design: .rounded))
                                                    .frame(maxWidth: .infinity)
                                                    .padding(.vertical, 10)
                                                    .background(
                                                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                                                            .fill(Color.primary.opacity(0.05))
                                                    )
                                            }
                                            .buttonStyle(.plain)
                                        }
                                    }
                                }
                            }

                            HStack(spacing: 12) {
                                if model.calls.callState == .idle {
                                    Button {
                                        model.calls.dial(number: model.callNumber)
                                    } label: {
                                        Label("Call", systemImage: "phone.fill")
                                            .frame(maxWidth: .infinity)
                                    }
                                    .buttonStyle(OneUIPrimaryButtonStyle(tint: OneUI.green))
                                    .disabled(model.calls.phase != .registered || model.callNumber.trimmingCharacters(in: .whitespaces).isEmpty)
                                } else {
                                    Button {
                                        model.calls.hangUp()
                                    } label: {
                                        Label("End Call", systemImage: "phone.down.fill")
                                            .frame(maxWidth: .infinity)
                                    }
                                    .buttonStyle(OneUIPrimaryButtonStyle(tint: OneUI.red))

                                    Toggle("Mute Mic", isOn: Binding(get: { model.calls.muted }, set: { model.calls.setMuted($0) }))
                                        .toggleStyle(.switch)
                                }
                            }
                        }
                    }
                    .frame(maxWidth: 340)

                    OneUICard {
                        VStack(alignment: .leading, spacing: 14) {
                            Text("Connection & Account Diagnostics")
                                .font(.system(size: 15, weight: .semibold))
                            Text("Calling uses your Samsung account and IMS/SIP over TLS with encrypted AMR-WB/SRTP audio. Your phone does not need to be paired over Bluetooth or on the same Wi-Fi network.")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)

                            HStack(spacing: 10) {
                                Button(model.checkingSamsung ? "Checking…" : "Verify Calling Account") {
                                    model.checkSamsung()
                                }
                                .buttonStyle(OneUISecondaryButtonStyle())
                                .disabled(model.checkingSamsung)

                                Button("Verify SIP Server Reachability") {
                                    model.checkSamsung(transport: true)
                                }
                                .buttonStyle(OneUISecondaryButtonStyle())
                                .disabled(model.checkingSamsung)
                            }

                            Divider()

                            Text(model.samsungStatus)
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    }
                }
            }
            .padding(28)
        }
        .task { model.start() }
    }
}
