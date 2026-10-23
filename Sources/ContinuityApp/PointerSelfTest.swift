import AppKit
import ContinuityCore

/// Diagnostic only (`--pointer-selftest <hz> <seconds>`): posts a steady rotating
/// relative-motion stream through the HID tap so the capture pipeline can be
/// measured without a human hand. It records only its own post-interval timing.
enum PointerSelfTest {
    static func arguments() -> (hz: Double, seconds: Double)? {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--pointer-selftest"), i + 2 < args.count, let hz = Double(args[i + 1]), let seconds = Double(args[i + 2]), hz > 0, seconds > 0 else { return nil }
        return (min(hz, 2000), min(seconds, 600))
    }
    static func run(hz: Double, seconds: Double, speed: Double = 1500, radius: Double = 120, completion: @escaping @Sendable (String) -> Void) {
        let thread = Thread {
            pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0)
            var timebase = mach_timebase_info_data_t(); mach_timebase_info(&timebase)
            func ticks(_ s: Double) -> UInt64 { UInt64(s * 1e9) * UInt64(timebase.denom) / UInt64(timebase.numer) }
            let period = ticks(1 / hz)
            let source = CGEventSource(stateID: .hidSystemState)
            let origin = CGEvent(source: nil)?.location ?? .zero
            guard let event = CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: origin, mouseButton: .left) else { completion("selftest: could not create events"); return }
            var series = IntervalSeries()
            let total = Int(hz * seconds)
            var next = mach_absolute_time() + ticks(0.2), last: UInt64 = 0
            var carryX = 0.0, carryY = 0.0
            let magnitude = speed / hz
            for n in 0..<total {
                mach_wait_until(next)
                let angle = (speed / radius) * Double(n) / hz   // small circle: the pointer must not reach a screen edge
                carryX += cos(angle) * magnitude; carryY += sin(angle) * magnitude
                let dx = carryX.rounded(), dy = carryY.rounded(); carryX -= dx; carryY -= dy
                event.setIntegerValueField(.mouseEventDeltaX, value: Int64(dx))
                event.setIntegerValueField(.mouseEventDeltaY, value: Int64(dy))
                event.post(tap: .cghidEventTap)
                let now = mach_absolute_time()
                if last != 0 { series.record(Double((now - last) * UInt64(timebase.numer) / UInt64(timebase.denom)) / 1e9) }
                last = now; next += period
            }
            let s = series.stats()
            completion(String(format: "selftest generator: %d events at %.0f Hz; post interval ms p50/p95/p99/max %.2f/%.2f/%.2f/%.2f (gaps>20 %d, >50 %d)", total, hz, s.p50, s.p95, s.p99, s.max, s.over20, s.over50))
        }
        thread.name = "continuity.pointer.selftest"; thread.start()
    }
}
