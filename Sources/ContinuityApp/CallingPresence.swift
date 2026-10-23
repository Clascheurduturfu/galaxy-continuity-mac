import SwiftUI
import AppKit
import Combine
import ContinuityCore

/// Keeps Samsung calling alive independent of any window: restarts it at launch when the user left it on,
/// shows a floating Answer/Decline window when a call arrives (the Calls sheet is usually closed), and
/// unregisters when the app quits. Started with one line from `LabApp.init`.
@MainActor final class CallingPresence {
    static let shared = CallingPresence()
    private let calls = CallingController.shared
    private var bag = Set<AnyCancellable>()
    private var panel: NSPanel?
    private var ring: Timer?
    private var started = false

    static func start() { shared.begin() }

    private func begin() {
        guard !started else { return }
        started = true
        calls.$callState.receive(on: DispatchQueue.main).sink { [weak self] state in self?.callStateChanged(state) }.store(in: &bag)
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.quit() }
        }
        if CommandLine.arguments.contains("--call-audio-selftest") {
            Task {
                let report = await CallingSelfTest.run()
                print(report); fflush(stdout)
                let url = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("Galaxy Continuity Lab/call-audio-selftest.txt")
                try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? Data((report + "\n").utf8).write(to: url, options: .atomic)
                chmod(url.path, 0o600)
                exit(0)
            }
            return
        }
        if CommandLine.arguments.contains("--call-test-once") {
            Task { await self.testOutgoingOnce() }
            return
        }
        if CallingController.wantsAutostart {
            Task { try? await Task.sleep(nanoseconds: 2_000_000_000); self.calls.start() }
        }
    }

    /// Explicit development command only. The owner supplies a private, one-use number file;
    /// the target is never an argument, log entry or persistent preference. No retry/loop dialing.
    private func testOutgoingOnce() async {
        let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Galaxy Continuity Lab", isDirectory: true)
        let input = directory.appendingPathComponent("call-test-number.txt")
        let output = directory.appendingPathComponent("call-test-result.txt")
        var lines = ["test: explicit single outgoing call"]
        func save() {
            try? Data((lines.joined(separator: "\n") + "\n").utf8).write(to: output, options: .atomic)
            chmod(output.path, 0o600)
        }
        func stateLabel() -> String {
            switch calls.callState {
            case .idle: return "idle"
            case .dialing: return "dialing"
            case .ringing: return "ringing"
            case .incoming: return "incoming"
            case .connecting: return "connecting"
            case .active: return "active"
            case .ending: return "ending"
            }
        }
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: input.path),
              (attrs[.type] as? FileAttributeType) == .typeRegular,
              let permissions = attrs[.posixPermissions] as? Int, permissions & 0o077 == 0,
              let bytes = try? Data(contentsOf: input), bytes.count < 128,
              let text = String(data: bytes, encoding: .utf8) else {
            lines.append("test: missing or invalid private target file"); save(); return
        }
        try? FileManager.default.removeItem(at: input)
        let number = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (3...32).contains(number.count), number.allSatisfy({ $0.isNumber || "+*#".contains($0) }) else {
            lines.append("test: invalid target"); save(); return
        }
        if !calls.isRegistered { calls.start() }
        for _ in 0..<100 {
            if calls.isRegistered { break }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        guard calls.isRegistered, calls.callState == .idle else {
            lines.append("test: calling not ready or already busy"); save(); return
        }
        lines.append("test: registered; dial once"); save()
        calls.dial(number: number)
        let start = ProcessInfo.processInfo.systemUptime
        var last = "", activeAt: Double?
        while ProcessInfo.processInfo.systemUptime - start < 35 {
            let state = stateLabel(), elapsed = ProcessInfo.processInfo.systemUptime - start
            if state != last { lines.append("test: t=\(Int(elapsed)) state=\(state)"); save(); last = state }
            if state == "active", activeAt == nil { activeAt = elapsed }
            if let activeAt, elapsed - activeAt > 10 { break }
            if state == "idle", elapsed > 1 { break }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        if calls.callState != .idle { calls.hangUp() }
        for _ in 0..<40 where calls.callState != .idle { try? await Task.sleep(nanoseconds: 250_000_000) }
        lines.append("test: complete state=\(stateLabel()) connected=\(activeAt != nil)"); save()
    }

    private func quit() {
        // Unregister before exiting, but never wait more than 4 s.
        var done = false
        Task { await calls.shutdownForQuit(); done = true }
        let deadline = Date().addingTimeInterval(4)
        while !done, Date() < deadline { RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05)) }
    }

    private func callStateChanged(_ state: CallingCallState) {
        guard case .incoming(let who) = state else { hide(); return }
        show(caller: who)
    }

    private func show(caller: String) {
        hide()
        NSApp.activate(ignoringOtherApps: true)
        let view = IncomingCallView(caller: caller, answer: { [calls] in calls.answer() }, decline: { [calls] in calls.decline() })
        let host = NSHostingController(rootView: view)
        let window = NSPanel(contentViewController: host)
        window.styleMask = [.titled, .utilityWindow, .nonactivatingPanel]
        window.title = "Galaxy Continuity · Incoming Call"
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.isFloatingPanel = true
        window.center()
        window.orderFrontRegardless()
        panel = window
        NSSound(named: "Ping")?.play()
        ring = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in NSSound(named: "Ping")?.play() }
    }

    private func hide() {
        ring?.invalidate(); ring = nil
        panel?.orderOut(nil); panel = nil
    }
}

struct IncomingCallView: View {
    let caller: String
    let answer: () -> Void
    let decline: () -> Void
    var body: some View {
        VStack(spacing: 18) {
            ZStack {
                Circle()
                    .fill(LinearGradient(colors: [OneUI.green, OneUI.blue], startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 60, height: 60)
                Image(systemName: "phone.arrow.down.left.fill")
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(.white)
            }
            VStack(spacing: 4) {
                Text("Incoming Galaxy Call")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text(caller)
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .textSelection(.enabled)
            }
            HStack(spacing: 28) {
                Button(action: decline) {
                    VStack(spacing: 6) {
                        ZStack {
                            Circle().fill(OneUI.red).frame(width: 48, height: 48)
                            Image(systemName: "phone.down.fill").font(.system(size: 18, weight: .bold)).foregroundStyle(.white)
                        }
                        Text("Decline").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)

                Button(action: answer) {
                    VStack(spacing: 6) {
                        ZStack {
                            Circle().fill(OneUI.green).frame(width: 48, height: 48)
                            Image(systemName: "phone.fill").font(.system(size: 18, weight: .bold)).foregroundStyle(.white)
                        }
                        Text("Answer").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(28)
        .frame(minWidth: 320)
    }
}
