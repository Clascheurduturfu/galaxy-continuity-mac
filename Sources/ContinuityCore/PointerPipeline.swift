import Foundation

public enum PhoneInput: Sendable, Equatable {
    case key(UInt16, Bool), click(UInt8, Bool), move(Int, Int, UInt8), wheel(Int, Int)
}

/// Destination of the pipeline. Implemented by the app's capture engine; fakes in tests.
public protocol PointerOutput: AnyObject {
    var isControlling: Bool { get }
    func sendPointer(x: Int, y: Int, elapsed: UInt8) -> PointerSendOutcome
    /// Appends to the ordered reliable-channel queue and returns its depth.
    func enqueue(_ input: PhoneInput) -> Int
}

/// Capture-thread state machine: pacing, forced flush before keys/clicks, UDP
/// send with reliable fallback, telemetry. Not thread-safe: the owner calls it
/// from one thread (the capture worker, or main for the legacy placement).
public final class PointerPipeline {
    public static let maxQueueDepth = 128
    private var pacer = PointerPacer()
    private let output: PointerOutput
    public let telemetry: PointerTelemetry
    private let clock: () -> TimeInterval
    private var lastOS: TimeInterval?, lastCallback: TimeInterval?, lastDecision: TimeInterval?, lastSendEnd: TimeInterval?
    public private(set) var failure: String?
    public var onFailure: ((String) -> Void)?
    public init(output: PointerOutput, telemetry: PointerTelemetry = PointerTelemetry(), clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.output = output; self.telemetry = telemetry; self.clock = clock
    }
    /// Time the next pending movement may be sent; the event-driven path arms a one-shot timer for it.
    public var pendingDeadline: TimeInterval? { pacer.pendingDeadline }
    public var now: TimeInterval { clock() }

    /// A relative movement from the OS at `osTime` (uptime seconds).
    public func move(dx: Int, dy: Int, osTime: TimeInterval) {
        guard failure == nil else { return }
        let now = clock()
        if let lastOS { telemetry.record(.osInterval, osTime - lastOS) }
        if let lastCallback { telemetry.record(.callbackInterval, now - lastCallback) }
        telemetry.record(.osToCallback, now - osTime)
        lastOS = osTime; lastCallback = now
        pacer.add(x: dx, y: dy, at: osTime)
        flush(force: false, now: now)
    }
    /// Timer or one-shot expiry. `scheduledFor` (uptime seconds) feeds the timer-lateness series.
    public func tick(scheduledFor: TimeInterval? = nil) {
        guard failure == nil else { return }
        let now = clock()
        if let scheduledFor { telemetry.record(.timerLateness, max(0, now - scheduledFor)) }
        flush(force: false, now: now)
    }
    /// Keys, buttons and wheel: pending movement leaves first, then the input joins the ordered queue.
    public func input(_ input: PhoneInput) {
        guard failure == nil else { return }
        flush(force: true, now: clock())
        guard failure == nil else { return }
        let depth = output.enqueue(input)
        telemetry.noteQueueDepth(depth)
        if depth >= Self.maxQueueDepth { fail("Input transfer fell behind; control released.") }
    }
    /// One-shot final delta at the end of a capture session.
    public func finish() { guard failure == nil else { return }; flush(force: true, now: clock()) }

    private func fail(_ message: String) {
        guard failure == nil else { return }
        failure = message; onFailure?(message)
    }
    private func flush(force: Bool, now: TimeInterval) {
        guard let sample = pacer.take(at: now, force: force) else { return }
        if let lastDecision { telemetry.record(.decisionInterval, now - lastDecision) }
        lastDecision = now
        if force { telemetry.noteForcedFlush() }
        let parts = sample.parts
        if parts.count > 1 { telemetry.noteSplit() }
        guard output.isControlling else { return }
        for (index, part) in parts.enumerated() {
            let elapsed: UInt8 = index == 0 ? sample.elapsed : 0
            let before = clock()
            let outcome = output.sendPointer(x: part.x, y: part.y, elapsed: elapsed)
            let after = clock()
            switch outcome {
            case .sent:
                telemetry.noteUDP()
                telemetry.record(.sendCall, after - before)
                if let lastSendEnd { telemetry.record(.sendInterval, after - lastSendEnd) }
                lastSendEnd = after
            case .unavailable, .failed:
                var code: Int32?
                if case let .failed(value) = outcome { code = value }
                telemetry.noteFallback(errno: code)
                let depth = output.enqueue(.move(part.x, part.y, elapsed))
                telemetry.noteQueueDepth(depth)
                if depth >= Self.maxQueueDepth { fail("Input transfer fell behind; control released."); return }
            case .closed:
                fail("The feature is not connected."); return
            }
        }
        telemetry.record(.eventAge, max(0, clock() - sample.oldestEvent))
    }
}

/// A/B switches. Read from launch arguments (`-PointerPacing event`), the app's
/// defaults domain, or `CONTINUITY_POINTER_*` environment variables.
public struct PointerOptions: Equatable, Sendable {
    public enum Pacing: String, Sendable { case timer, event }
    public enum Placement: String, Sendable { case worker, main }
    public var pacing: Pacing = .event
    public var placement: Placement = .worker
    /// Explicit IP_TOS byte for the UDP socket (for example 0x10 low-delay); nil leaves only the service class.
    public var ipTOS: Int?
    /// Send the (-100,-100) focus-release marker when control returns to the Mac.
    public var releaseMarker = false
    public init() {}
    public var description: String { "pacing=\(pacing.rawValue) placement=\(placement.rawValue) iptos=\(ipTOS.map { String($0, radix: 16) } ?? "off") release-marker=\(releaseMarker)" }
    /// `values` holds raw strings by option name (Pacing, Placement, IPTOS, ReleaseMarker).
    public static func parse(_ values: [String: String]) -> PointerOptions {
        var options = PointerOptions()
        if let v = values["Pacing"]?.lowercased(), let p = Pacing(rawValue: v) { options.pacing = p }
        if let v = values["Placement"]?.lowercased(), let p = Placement(rawValue: v) { options.placement = p }
        if let v = values["IPTOS"] {
            let text = v.lowercased().hasPrefix("0x") ? String(v.dropFirst(2)) : v
            if let n = Int(text, radix: v.lowercased().hasPrefix("0x") ? 16 : 10), (0...255).contains(n) { options.ipTOS = n }
        }
        if let v = values["ReleaseMarker"]?.lowercased() { options.releaseMarker = ["1", "true", "yes", "on"].contains(v) }
        return options
    }
    public static func load(defaults: UserDefaults = .standard, environment: [String: String] = ProcessInfo.processInfo.environment) -> PointerOptions {
        var values: [String: String] = [:]
        for name in ["Pacing", "Placement", "IPTOS", "ReleaseMarker"] {
            if let v = environment["CONTINUITY_POINTER_" + name.uppercased()] { values[name] = v }
            if let v = defaults.object(forKey: "Pointer" + name) { values[name] = "\(v)" }
        }
        return parse(values)
    }
}
