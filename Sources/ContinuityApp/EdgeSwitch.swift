import AppKit
import ApplicationServices
import ContinuityCore

/// Event-driven: no sampling timer and no input interception until the owner crosses a configured edge.
@MainActor final class EdgeSwitch {
    var enter: ((Double) -> Void)?
    var canEnter: (() -> Bool)?
    private var global: Any?
    private var local: Any?
    private var sleep: NSObjectProtocol?
    private var placement = DevicePlacement()
    private var lastPoint: NSPoint?
    private var lastEntry: TimeInterval = 0
    private var latched = false
    private var screen: NSScreen? {
        NSScreen.screens.first { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == placement.screenID } ?? NSScreen.main ?? NSScreen.screens.first
    }
    func start(_ placement: DevicePlacement) throws {
        self.placement = placement
        guard global == nil else { return }
        guard AXIsProcessTrusted() else {
            _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
            throw ContinuityError.message("Allow Accessibility, then enable screen-edge switching again.")
        }
        global = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { [weak self] event in
            MainActor.assumeIsolated { self?.moved(event) }
        }
        local = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved) { [weak self] event in
            MainActor.assumeIsolated { self?.moved(event) }; return event
        }
        sleep = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.stop() }
        }
    }
    private func moved(_ event: NSEvent) {
        let point = NSEvent.mouseLocation
        defer { lastPoint = point }
        guard let screen, screen.frame.contains(point), let lastPoint else { return }
        let frame = screen.frame
        let distance: CGFloat
        let outward: Bool
        let fraction: Double
        let beyond: NSPoint
        switch placement.side {
        case .left:
            distance = point.x - frame.minX; outward = point.x < lastPoint.x
            fraction = (frame.maxY - point.y) / frame.height; beyond = .init(x: frame.minX - 2, y: point.y)
        case .right:
            distance = frame.maxX - point.x; outward = point.x > lastPoint.x
            fraction = (frame.maxY - point.y) / frame.height; beyond = .init(x: frame.maxX + 2, y: point.y)
        case .above:
            distance = frame.maxY - point.y; outward = point.y > lastPoint.y
            fraction = (point.x - frame.minX) / frame.width; beyond = .init(x: point.x, y: frame.maxY + 2)
        case .below:
            distance = point.y - frame.minY; outward = point.y < lastPoint.y
            fraction = (point.x - frame.minX) / frame.width; beyond = .init(x: point.x, y: frame.minY - 2)
        }
        if distance > 18 { latched = false }
        guard !latched, distance <= 2, outward, placement.containsPortal(fraction),
              !event.modifierFlags.contains(.command), NSEvent.pressedMouseButtons == 0,
              ProcessInfo.processInfo.systemUptime - lastEntry > 1, canEnter?() == true,
              !NSScreen.screens.contains(where: { $0 !== screen && $0.frame.contains(beyond) }) else { return }
        latched = true; lastEntry = ProcessInfo.processInfo.systemUptime
        enter?(fraction)
    }
    func returnToMac() {
        lastEntry = ProcessInfo.processInfo.systemUptime; latched = true
        guard let screen else { return }
        let f = screen.frame, t = 0.5 + placement.offset * 0.5
        var point: NSPoint
        switch placement.side {
        case .left: point = .init(x: f.minX + 24, y: f.maxY - f.height * t)
        case .right: point = .init(x: f.maxX - 24, y: f.maxY - f.height * t)
        case .above: point = .init(x: f.minX + f.width * t, y: f.maxY - 24)
        case .below: point = .init(x: f.minX + f.width * t, y: f.minY + 24)
        }
        let primaryTop = NSScreen.screens.first?.frame.maxY ?? f.maxY
        CGWarpMouseCursorPosition(.init(x: point.x, y: primaryTop - point.y))
        lastPoint = point
    }
    func stop() {
        if let global { NSEvent.removeMonitor(global) }; global = nil
        if let local { NSEvent.removeMonitor(local) }; local = nil
        if let sleep { NSWorkspace.shared.notificationCenter.removeObserver(sleep) }; sleep = nil
        lastPoint = nil; latched = false
    }
}
