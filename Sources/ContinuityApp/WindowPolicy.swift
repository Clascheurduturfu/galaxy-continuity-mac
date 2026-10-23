import SwiftUI
import AppKit

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
}

struct MainWindowAttachment: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { if let window = nsView.window { AppWindowPolicy.shared.attach(window) } }
    }
}
