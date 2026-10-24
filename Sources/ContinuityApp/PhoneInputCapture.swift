import AppKit
import ApplicationServices
import ContinuityCore

/// Output for the pointer worker thread: movements leave over UDP with a
/// direct `sendto`, and everything else (keys, clicks, wheels, TCP-fallback
/// movements) is written synchronously onto the reliable channel. The whole
/// input path stays on the worker thread with no main-actor hops.
final class PhoneInputOutput: @unchecked Sendable, PointerOutput {
    private let udp: PointerSender?
    let reliable: ReliableInputSender
    init(udp: PointerSender?, reliable: ReliableInputSender) { self.udp = udp; self.reliable = reliable }
    var isControlling: Bool { reliable.isControlling }
    func sendPointer(x: Int, y: Int, elapsed: UInt8) -> PointerSendOutcome {
        udp?.send(MultiControlWire.motion(x: x, y: y, elapsed: elapsed)) ?? .unavailable
    }
    func enqueue(_ input: PhoneInput) -> Int { reliable.send(input) }
}

/// Owns the CGEvent tap, the pacer timers and the pipeline on ONE thread: a
/// dedicated user-interactive worker (default) or the main run loop (legacy
/// placement, for A/B). Nothing here touches MainActor state.
final class PointerCaptureEngine: @unchecked Sendable {
    let options: PointerOptions
    let telemetry: PointerTelemetry
    private let output: PointerOutput
    private let pipeline: PointerPipeline
    private var wheelPacer = WheelPacer()
    private let running = AtomicFlag()
    private let stateLock = NSLock()
    private var tornDown = false, started = false
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var runLoop: CFRunLoop?
    private var repeating: CFRunLoopTimer?
    private var oneShot: CFRunLoopTimer?
    private var armedFor: TimeInterval?
    private var thread: Thread?
    private let finished = DispatchSemaphore(value: 0)
    private var flags: CGEventFlags = []
    /// Called once, from any thread, when the engine ends by itself (Escape, tap loss, pipeline failure).
    var onEnded: (@Sendable (String?) -> Void)?
    private static let scans: [Int64: UInt16] = [
        0:0x1e,1:0x1f,2:0x20,3:0x21,4:0x23,5:0x22,6:0x2c,7:0x2d,8:0x2e,9:0x2f,11:0x30,
        12:0x10,13:0x11,14:0x12,15:0x13,16:0x15,17:0x14,18:0x02,19:0x03,20:0x04,21:0x05,22:0x07,23:0x06,
        24:0x0d,25:0x0a,26:0x08,27:0x0c,28:0x09,29:0x0b,30:0x1b,31:0x18,32:0x16,33:0x1a,34:0x17,35:0x19,
        36:0x1c,37:0x26,38:0x24,39:0x28,40:0x25,41:0x27,42:0x2b,43:0x33,44:0x35,45:0x31,46:0x32,47:0x34,
        48:0x0f,49:0x39,50:0x29,51:0x0e,65:0x53,67:0x37,69:0x4e,75:0xe035,76:0xe01c,78:0x4a,
        82:0x52,83:0x4f,84:0x50,85:0x51,86:0x4b,87:0x4c,88:0x4d,89:0x47,91:0x48,92:0x49,
        96:0x3f,97:0x40,98:0x41,99:0x3d,100:0x42,101:0x43,103:0x57,109:0x44,111:0x58,115:0xe047,
        116:0xe049,117:0xe053,118:0x3e,119:0xe04f,120:0x3c,121:0xe051,122:0x3b,123:0xe04b,124:0xe04d,125:0xe050,126:0xe048]

    init(options: PointerOptions, output: PointerOutput, telemetry: PointerTelemetry) {
        self.options = options; self.output = output; self.telemetry = telemetry
        pipeline = PointerPipeline(output: output, telemetry: telemetry)
        pipeline.onFailure = { [weak self] message in self?.end(message) }
    }

    func start() throws {
        let types: [CGEventType] = [.keyDown,.keyUp,.flagsChanged,.mouseMoved,.leftMouseDragged,.rightMouseDragged,.otherMouseDragged,.leftMouseDown,.leftMouseUp,.rightMouseDown,.rightMouseUp,.otherMouseDown,.otherMouseUp,.scrollWheel]
        let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
        let callback: CGEventTapCallBack = { _, type, event, context in
            guard let context else { return Unmanaged.passUnretained(event) }
            return Unmanaged<PointerCaptureEngine>.fromOpaque(context).takeUnretainedValue().handle(type, event)
        }
        // The retain taken here keeps the engine alive for the tap's lifetime; teardown releases it.
        let retained = Unmanaged.passRetained(self)
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap, eventsOfInterest: mask, callback: callback, userInfo: retained.toOpaque()), let source = CFMachPortCreateRunLoopSource(nil, tap, 0) else {
            retained.release()
            throw ContinuityError.message("macOS did not allow input capture. Check Accessibility and Input Monitoring permissions.")
        }
        self.tap = tap; self.source = source; flags = []
        running.value = true; started = true
        switch options.placement {
        case .main:
            runLoop = CFRunLoopGetMain(); install()
        case .worker:
            let ready = DispatchSemaphore(value: 0)
            let worker = Thread { [self] in
                pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0)
                runLoop = CFRunLoopGetCurrent(); install()
                ready.signal()
                CFRunLoopRun()
                finished.signal()
            }
            worker.name = "continuity.pointer"; worker.qualityOfService = .userInteractive; worker.stackSize = 1 << 20
            thread = worker; worker.start()
            ready.wait()
        }
        CGEvent.tapEnable(tap: tap, enable: true)
    }
    private func install() {
        guard let runLoop, let source else { return }
        CFRunLoopAddSource(runLoop, source, .commonModes)
        switch options.pacing {
        case .timer:
            let interval = PointerPacer.interval
            let timer = CFRunLoopTimerCreateWithHandler(nil, CFAbsoluteTimeGetCurrent() + interval, interval, 0, 0) { [unowned self] timer in
                guard self.running.value, let timer else { return }
                // The handler runs before CF advances the fire date, so it still names the slot that just fired.
                let late = CFAbsoluteTimeGetCurrent() - CFRunLoopTimerGetNextFireDate(timer)
                self.pipeline.tick(scheduledFor: self.pipeline.now - late)
            }
            repeating = timer; CFRunLoopAddTimer(runLoop, timer, .commonModes)
        case .event:
            let timer = CFRunLoopTimerCreateWithHandler(nil, CFAbsoluteTimeGetCurrent() + 1_000_000, 1_000_000, 0, 0) { [unowned self] _ in
                guard self.running.value else { return }
                let scheduled = self.armedFor; self.armedFor = nil
                self.pipeline.tick(scheduledFor: scheduled)
                self.rearm()
            }
            oneShot = timer; CFRunLoopAddTimer(runLoop, timer, .commonModes)
        }
    }
    /// Event-driven path: arm a single wake-up for a movement that is still inside its 6 ms window.
    private func rearm() {
        guard options.pacing == .event, let oneShot, let deadline = pipeline.pendingDeadline else { return }
        let now = pipeline.now
        if let armedFor, armedFor > now { return }
        let target = max(deadline, now + 0.000_1)
        armedFor = target
        CFRunLoopTimerSetNextFireDate(oneShot, CFAbsoluteTimeGetCurrent() + (target - now))
    }

    /// Stops capture. From another thread it waits (briefly) until the final delta is flushed and the tap is gone.
    func stop() {
        running.value = false
        guard started else { return }
        schedule { [self] in teardown() }
        if Thread.current !== thread, options.placement == .worker { _ = finished.wait(timeout: .now() + 0.5) }
    }
    private func schedule(_ block: @escaping () -> Void) {
        switch options.placement {
        case .main:
            if Thread.isMainThread { block() } else { DispatchQueue.main.async(execute: block) }
        case .worker:
            guard let runLoop else { return }
            CFRunLoopPerformBlock(runLoop, CFRunLoopMode.commonModes.rawValue, block); CFRunLoopWakeUp(runLoop)
        }
    }
    /// Runs on the owning thread, once. The final delta leaves while control is still held.
    private func teardown() {
        stateLock.lock(); let already = tornDown; tornDown = true; stateLock.unlock()
        guard !already else { return }
        pipeline.finish()
        if let tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        if let runLoop {
            if let source { CFRunLoopRemoveSource(runLoop, source, .commonModes) }
            if let repeating { CFRunLoopRemoveTimer(runLoop, repeating, .commonModes) }
            if let oneShot { CFRunLoopRemoveTimer(runLoop, oneShot, .commonModes) }
        }
        if let repeating { CFRunLoopTimerInvalidate(repeating) }
        if let oneShot { CFRunLoopTimerInvalidate(oneShot) }
        tap = nil; source = nil; repeating = nil; oneShot = nil
        if options.placement == .worker, let runLoop { CFRunLoopStop(runLoop) }
        Unmanaged.passUnretained(self).release()
    }
    /// Engine-initiated end (Escape, tap disabled, pipeline or channel failure).
    /// Called from the capture worker or the main actor; events pass through to
    /// the Mac immediately.
    func end(_ reason: String?) {
        guard running.value else { return }
        running.value = false
        schedule { [self] in teardown() }
        onEnded?(reason)
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        guard running.value else { return Unmanaged.passUnretained(event) }
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput { end(nil); return Unmanaged.passUnretained(event) }
        let code = event.getIntegerValueField(.keyboardEventKeycode)
        if type == .keyDown, code == 53 { end(nil); return Unmanaged.passUnretained(event) }
        switch type {
        case .keyDown, .keyUp: if let scan = Self.scans[code] { pipeline.input(.key(scan, type == .keyDown)) }
        case .flagsChanged:
            for (flag, scan) in [(CGEventFlags.maskShift, UInt16(0x2a)), (.maskControl, 0x1d), (.maskAlternate, 0x38), (.maskCommand, 0xe05b), (.maskAlphaShift, 0x3a)] {
                if flags.contains(flag) != event.flags.contains(flag) { pipeline.input(.key(scan, event.flags.contains(flag))) }
            }
            flags = event.flags
        case .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            pipeline.move(dx: Int(event.getIntegerValueField(.mouseEventDeltaX)), dy: Int(event.getIntegerValueField(.mouseEventDeltaY)), osTime: Double(event.timestamp) / 1_000_000_000)
            rearm()
        case .leftMouseDown,.leftMouseUp: pipeline.input(.click(1, type == .leftMouseDown))
        case .rightMouseDown,.rightMouseUp: pipeline.input(.click(2, type == .rightMouseDown))
        case .otherMouseDown,.otherMouseUp: pipeline.input(.click(3, type == .otherMouseDown))
        case .scrollWheel:
            // Trackpad streams are decimated 1-in-12 like the Book's touchpad
            // handling (with accumulation, so distance is kept); discrete
            // mouse-wheel notches pass straight through. Scroll phase 4/5 is
            // ended/cancelled, momentum phase 3 is ended.
            let vertical = Int(event.getIntegerValueField(.scrollWheelEventDeltaAxis2))
            let horizontal = Int(event.getIntegerValueField(.scrollWheelEventDeltaAxis1))
            let phase = event.getIntegerValueField(.scrollWheelEventScrollPhase)
            let momentum = event.getIntegerValueField(.scrollWheelEventMomentumPhase)
            let ended = phase >= 4 || momentum == 3
            if let wheel = wheelPacer.add(x: vertical * 120, y: horizontal * 120, continuous: phase != 0 || momentum != 0, ended: ended) {
                pipeline.input(.wheel(wheel.x, wheel.y))
            }
        default: break
        }
        return nil
    }
}

/// Explicit keyboard/mouse capture. Escape, sleep and tap failure release it.
/// UI state only; capture, pacing, encryption, UDP sends and the reliable
/// channel writes all run on the engine's worker thread.
@MainActor final class PhoneInputCapture {
    private var engine: PointerCaptureEngine?
    private var output: PhoneInputOutput?
    private var sleepObserver: NSObjectProtocol?
    private weak var controller: MultiControl?
    private(set) var active = false
    var failed: ((String) -> Void)?
    var summary: ((String) -> Void)?
    var ended: (() -> Void)?
    func start(_ controller: MultiControl) throws {
        guard !active else { return }
        guard AXIsProcessTrusted() else {
            _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
            throw ContinuityError.message("Allow Galaxy Continuity Lab in Mac Accessibility settings, then choose Control phone again.")
        }
        guard let udp = controller.pointerSender else { throw ContinuityError.message("Multi Control is not connected.") }
        let reliable = controller.makeInputSender()
        let output = PhoneInputOutput(udp: udp, reliable: reliable)
        let engine = PointerCaptureEngine(options: PointerOptions.load(), output: output, telemetry: PointerTelemetry())
        reliable.onUnavailable = { [weak engine] message in engine?.end(message) }
        engine.onEnded = { [weak self] reason in Task { @MainActor in self?.engineEnded(reason) } }
        try engine.start()
        self.controller = controller; self.engine = engine; self.output = output; active = true
        _ = CGAssociateMouseAndMouseCursorPosition(0); _ = CGDisplayHideCursor(CGMainDisplayID())
        sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.stop() } }
    }
    private func engineEnded(_ reason: String?) {
        guard active else { return }
        stop()
        if let reason { failed?(reason) }
    }
    func stop() {
        guard active else { return }; active = false
        engine?.stop()   // flushes the final delta while control is still held
        output?.reliable.releaseHeld()   // release any held key or button before focus returns
        if let engine {
            let snapshot = engine.telemetry.snapshot()
            if snapshot.udpSent + snapshot.fallbacks > 0 {
                summary?("Mouse: \(controller?.pointerTransportSummary ?? "disconnected") [\(engine.options.description)]\n" + snapshot.text)
            }
        }
        output = nil
        if let sleepObserver { NSWorkspace.shared.notificationCenter.removeObserver(sleepObserver) }; sleepObserver = nil
        _ = CGAssociateMouseAndMouseCursorPosition(1); _ = CGDisplayShowCursor(CGMainDisplayID())
        ended?()
        let controller = controller; self.controller = nil
        Task { await controller?.release() }
    }
}
