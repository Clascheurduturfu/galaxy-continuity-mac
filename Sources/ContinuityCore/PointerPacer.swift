import Foundation

public struct PointerVector: Equatable, Sendable {
    public let x: Int, y: Int
    public init(_ x: Int, _ y: Int) { self.x = x; self.y = y }
    /// The phone's inputinject clears its pending mouse queue on this vector
    /// (the Book emits it only when focus returns to the PC).
    public static let reserved = PointerVector(-100, -100)

    /// Ordinary movement must never equal the reserved marker. A coincident
    /// vector is split in two halves that add up to the same displacement.
    public static func safeParts(x: Int, y: Int) -> [PointerVector] {
        guard x == reserved.x, y == reserved.y else { return [PointerVector(x, y)] }
        return [PointerVector(x / 2, y / 2), PointerVector(x - x / 2, y - y / 2)]
    }
}

/// Wheel rate limiting copied from the Book's `SendMouseEvent`: continuous
/// (trackpad-style) scroll streams release one packet per `stride` events
/// instead of flooding the reliable channel, while discrete mouse-wheel
/// notches pass through untouched — the Book decimates only when the source
/// is a touchpad. Skipped deltas are accumulated, so the phone still scrolls
/// the full distance.
public struct WheelPacer {
    public let stride: Int
    private var x = 0, y = 0, events = 0
    public init(stride: Int = 12) { self.stride = max(1, stride) }
    /// Returns the vector to send now, or nil while still accumulating.
    /// `ended` marks the end of a trackpad gesture or momentum run and flushes.
    public mutating func add(x: Int, y: Int, continuous: Bool, ended: Bool) -> PointerVector? {
        guard continuous else {
            guard events > 0 else { return PointerVector(x, y) }
            // A discrete notch after a trackpad stream is a boundary: flush both.
            let merged = PointerVector(self.x + x, self.y + y)
            reset(); return merged
        }
        self.x += x; self.y += y; events += 1
        guard events >= stride || ended else { return nil }
        let flush = PointerVector(self.x, self.y)
        reset(); return flush
    }
    public mutating func reset() { x = 0; y = 0; events = 0 }
}

/// Match the Book's 6 ms movement cadence while retaining the final movement
/// even when no subsequent OS event arrives. Times use a monotonic clock.
public struct PointerPacer {
    public struct Sample {
        public let x: Int
        public let y: Int
        public let elapsed: UInt8
        public let oldestEvent: TimeInterval
        public let events: Int
        /// One or two wire vectors; the sum equals (x, y) and neither is the reserved marker.
        public var parts: [PointerVector] { PointerVector.safeParts(x: x, y: y) }
    }
    public static let interval: TimeInterval = 0.006
    private var x = 0, y = 0, events = 0
    private var oldest: TimeInterval = 0
    private var lastSent: TimeInterval?
    public init() {}
    public var hasPending: Bool { events > 0 }
    /// Earliest time a pending movement may leave without being forced, or nil when nothing waits.
    public var pendingDeadline: TimeInterval? {
        guard events > 0 else { return nil }
        return lastSent.map { $0 + Self.interval } ?? 0
    }
    public mutating func add(x: Int, y: Int, at time: TimeInterval) {
        guard x != 0 || y != 0 else { return }
        if events == 0 { oldest = time }
        self.x += max(-1_000_000, min(1_000_000, x))
        self.y += max(-1_000_000, min(1_000_000, y)); events += 1
    }
    public mutating func take(at time: TimeInterval, force: Bool = false) -> Sample? {
        guard events > 0 else { return nil }
        let gap = lastSent.map { max(0, time - $0) }
        guard force || gap == nil || gap! + 0.000_001 >= Self.interval else { return nil }
        let elapsed = gap.map { $0 > 0.255 ? UInt8(0) : UInt8(clamping: Int($0 * 1000)) } ?? 0
        let sample = Sample(x: x, y: y, elapsed: elapsed, oldestEvent: oldest, events: events)
        x = 0; y = 0; events = 0; lastSent = time
        return sample
    }
}
