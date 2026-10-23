import AppKit
import Foundation

/// Explicit development launch only. Starts no account, clipboard, audio or phone services.
@MainActor enum WindowLifecycleTest {
    private static var started = false
    static func start() {
        guard !started else { return }; started = true
        Task { await run() }
    }
    private static func run() async {
        var result: [String: Bool] = [:]
        do {
            try await Task.sleep(nanoseconds: 1_500_000_000)
            let main = NSApp.windows.first { $0.identifier?.rawValue == "GalaxyContinuityMain" && $0.isVisible }
            result["initialWindowVisible"] = main != nil
            main?.close()
            try await Task.sleep(nanoseconds: 700_000_000)
            result["dockHiddenAfterClose"] = NSApp.activationPolicy() == .accessory
            AppWindowPolicy.shared.show(.nearby)
            try await Task.sleep(nanoseconds: 1_500_000_000)
            result["windowReopened"] = NSApp.windows.contains { $0.identifier?.rawValue == "GalaxyContinuityMain" && $0.isVisible }
            result["dockRestoredWhileOpen"] = NSApp.activationPolicy() == .regular
            result["requestedSectionRestored"] = AppWindowPolicy.shared.displayedSection == .nearby
            let args = CommandLine.arguments
            if let i = args.firstIndex(of: "--ui-test-result"), i + 1 < args.count {
                let url = URL(fileURLWithPath: args[i + 1])
                try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]).write(to: url, options: .atomic)
                chmod(url.path, 0o600)
            }
        } catch {}
        NSApp.terminate(nil)
    }
}
