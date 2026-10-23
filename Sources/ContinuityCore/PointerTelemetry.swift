import Foundation

/// Bounded interval recorder. Only durations enter it: never coordinates or
/// keystrokes. Percentiles come from the last `capacity` samples; maximum and
/// gap counters are all-time for the capture session.
public struct IntervalSeries {
    public static let capacity = 4096
    /// Longer intervals are idle time (mouse stopped), not jitter.
    public static let idleCutoff: TimeInterval = 1.0
    public struct Stats: Equatable {
        public var count = 0
        public var p50 = 0.0, p95 = 0.0, p99 = 0.0, max = 0.0   // milliseconds
        public var over20 = 0, over50 = 0, idle = 0, negative = 0
    }
    private var ring = [UInt32](repeating: 0, count: IntervalSeries.capacity)
    private var next = 0, stored = 0
    private var count = 0, over20 = 0, over50 = 0, idle = 0, negative = 0
    private var maxMicros: UInt32 = 0
    public init() {}
    public mutating func record(_ seconds: TimeInterval) {
        guard seconds.isFinite else { return }
        if seconds < 0 { negative += 1; return }
        if seconds > Self.idleCutoff { idle += 1; return }
        let micros = UInt32(seconds * 1_000_000)
        ring[next] = micros; next = (next + 1) % Self.capacity; stored = min(stored + 1, Self.capacity)
        count += 1; maxMicros = max(maxMicros, micros)
        if micros > 20_000 { over20 += 1 }
        if micros > 50_000 { over50 += 1 }
    }
    public func stats() -> Stats {
        var result = Stats(count: count, over20: over20, over50: over50, idle: idle, negative: negative)
        result.max = Double(maxMicros) / 1000
        guard stored > 0 else { return result }
        let sorted = ring[0..<stored].sorted()
        func rank(_ p: Double) -> Double { Double(sorted[min(stored - 1, max(0, Int((p * Double(stored)).rounded(.up)) - 1))]) / 1000 }
        result.p50 = rank(0.50); result.p95 = rank(0.95); result.p99 = rank(0.99)
        return result
    }
}

/// Thread-safe collection of the pointer pipeline's timing series.
public final class PointerTelemetry: @unchecked Sendable {
    public enum Series: Int, CaseIterable {
        case osInterval, callbackInterval, osToCallback, decisionInterval, sendInterval, sendCall, eventAge, timerLateness
        public var label: String {
            switch self {
            case .osInterval: return "os-ts"
            case .callbackInterval: return "callback"
            case .osToCallback: return "os>callback"
            case .decisionInterval: return "decide"
            case .sendInterval: return "send"
            case .sendCall: return "sendcall"
            case .eventAge: return "age"
            case .timerLateness: return "timer-late"
            }
        }
    }
    public struct Snapshot {
        public var series: [Series: IntervalSeries.Stats] = [:]
        public var udpSent = 0, fallbacks = 0, forcedFlushes = 0, splitVectors = 0, queueDepthMax = 0
        public var failures: [Int32: Int] = [:]
        public var failureTotal: Int { failures.values.reduce(0, +) }
        /// Compact multi-line diagnostic text; milliseconds p50/p95/p99/max (gaps >20 ms / >50 ms).
        public var text: String {
            var lines = ["Pointer timing (ms p50/p95/p99/max, gaps>20/>50):"]
            for s in Series.allCases {
                guard let v = series[s], v.count > 0 else { continue }
                lines.append(String(format: "  %@ n=%d %.2f/%.2f/%.2f/%.2f (%d/%d)", s.label, v.count, v.p50, v.p95, v.p99, v.max, v.over20, v.over50))
            }
            let errors = failures.sorted { $0.key < $1.key }.map { "errno\($0.key)=\($0.value)" }.joined(separator: ",")
            lines.append("  udp=\(udpSent) tcp-fallback=\(fallbacks) send-failures=\(failureTotal)\(errors.isEmpty ? "" : " [" + errors + "]") forced-flush=\(forcedFlushes) split-vectors=\(splitVectors) queue-depth-max=\(queueDepthMax)")
            return lines.joined(separator: "\n")
        }
    }
    private let lock = NSLock()
    private var series = [IntervalSeries](repeating: IntervalSeries(), count: Series.allCases.count)
    private var snapshotCounters = Snapshot()
    public init() {}
    public func record(_ which: Series, _ seconds: TimeInterval) { lock.lock(); series[which.rawValue].record(seconds); lock.unlock() }
    public func noteUDP() { lock.lock(); snapshotCounters.udpSent += 1; lock.unlock() }
    public func noteFallback(errno code: Int32?) {
        lock.lock(); snapshotCounters.fallbacks += 1
        if let code { snapshotCounters.failures[code, default: 0] += 1 }
        lock.unlock()
    }
    public func noteForcedFlush() { lock.lock(); snapshotCounters.forcedFlushes += 1; lock.unlock() }
    public func noteSplit() { lock.lock(); snapshotCounters.splitVectors += 1; lock.unlock() }
    public func noteQueueDepth(_ depth: Int) { lock.lock(); snapshotCounters.queueDepthMax = max(snapshotCounters.queueDepthMax, depth); lock.unlock() }
    public func snapshot() -> Snapshot {
        lock.lock(); defer { lock.unlock() }
        var result = snapshotCounters
        for s in Series.allCases { result.series[s] = series[s.rawValue].stats() }
        return result
    }
}
