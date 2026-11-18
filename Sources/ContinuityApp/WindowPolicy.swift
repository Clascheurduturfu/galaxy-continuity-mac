import SwiftUI
import AppKit
import ContinuityCore

@MainActor final class AppWindowPolicy {
    static let shared = AppWindowPolicy()
    var createWindow: (() -> Void)?
    var selectSection: ((SidebarSection) -> Void)?
    private var observers: [Int: NSObjectProtocol] = [:]
    private var pendingSection: SidebarSection?
    var displayedSection: SidebarSection = .home
    func takePendingSection() -> SidebarSection? { defer { pendingSection = nil }; return pendingSection }
    func attach(_ window: NSWindow) {
        let number = window.windowNumber
        guard !AppVersion.isRenderingDemo, observers[number] == nil else { return }
        window.identifier = NSUserInterfaceItemIdentifier("GalaxyContinuityMain")
        observers[number] = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                if let token = self?.observers.removeValue(forKey: number) { NotificationCenter.default.removeObserver(token) }
            }
            DispatchQueue.main.async { MainActor.assumeIsolated {
                guard self != nil else { return }
                if !NSApp.windows.contains(where: { $0.identifier?.rawValue == "GalaxyContinuityMain" && $0.isVisible }) {
                    self?.selectSection = nil; NSApp.setActivationPolicy(.accessory)
                }
            } }
        }
        NSApp.setActivationPolicy(.regular)
    }
    func show(_ section: SidebarSection? = nil) {
        NSApp.setActivationPolicy(.regular)
        if let window = NSApp.windows.first(where: { $0.identifier?.rawValue == "GalaxyContinuityMain" && ($0.isVisible || $0.isMiniaturized) }) {
            if let section { selectSection?(section) }
            window.deminiaturize(nil); window.makeKeyAndOrderFront(nil)
        } else { pendingSection = section; createWindow?() }
        NSApp.activate(ignoringOtherApps: true)
    }
}

final class ContinuityAppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        MainActor.assumeIsolated { AppWindowPolicy.shared.show() }; return true
    }
    func application(_ application: NSApplication, open urls: [URL]) {
        MainActor.assumeIsolated {
            for url in urls where url.scheme?.lowercased() == "tel" {
                let abs = url.absoluteString
                let raw = abs.firstIndex(of: ":").map { String(abs[abs.index(after: $0)...]) } ?? abs
                let beforeQuery = raw.split(separator: "?", maxSplits: 1).first.map(String.init) ?? raw
                let beforeParams = beforeQuery.split(separator: ";", maxSplits: 1).first.map(String.init) ?? beforeQuery
                let digits = CallingEmergencyGuard.sanitizeDigits(beforeParams)
                guard !digits.isEmpty else { continue }
                if CallingEmergencyGuard.isEmergencyNumber(digits) {
                    PhoneAppBridge.shared.note?("Emergency calls cannot be routed through Samsung Continuity.")
                    continue
                }
                PhoneAppBridge.shared.pendingDialerNumber = digits
                AppWindowPolicy.shared.show(.calls)
                break
            }
        }
    }
}

struct MainWindowAttachment: NSViewRepresentable {
    final class Coordinator { var attachedWindowNumber: Int? }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            guard let window = nsView.window, context.coordinator.attachedWindowNumber != window.windowNumber else { return }
            context.coordinator.attachedWindowNumber = window.windowNumber
            AppWindowPolicy.shared.attach(window)
        }
    }
}
