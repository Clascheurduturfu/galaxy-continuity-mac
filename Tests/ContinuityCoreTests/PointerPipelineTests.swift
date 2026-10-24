import XCTest
@testable import ContinuityCore

private final class FakeOutput: PointerOutput {
    enum Event: Equatable { case udp(Int, Int, UInt8), queued(PhoneInput) }
    var events: [Event] = []
    var controlling = true
    var outcome: PointerSendOutcome = .sent
    var depth = 0
    var isControlling: Bool { controlling }
    func sendPointer(x: Int, y: Int, elapsed: UInt8) -> PointerSendOutcome {
        if outcome == .sent { events.append(.udp(x, y, elapsed)) }
        return outcome
    }
    func enqueue(_ input: PhoneInput) -> Int { events.append(.queued(input)); depth += 1; return depth }
    /// Events with elapsed bytes zeroed: timing arithmetic is asserted separately.
    var shape: [Event] {
        events.map { e in
            switch e {
            case let .udp(x, y, _): return .udp(x, y, 0)
            case let .queued(.move(x, y, _)): return .queued(.move(x, y, 0))
            default: return e
            }
        }
    }
    var udpSum: (Int, Int) {
        events.reduce((0, 0)) { if case let .udp(x, y, _) = $1 { return ($0.0 + x, $0.1 + y) }; return $0 }
    }
}

final class PointerPipelineTests: XCTestCase {
    private func make(_ output: FakeOutput, clock: @escaping () -> TimeInterval) -> PointerPipeline {
        PointerPipeline(output: output, clock: clock)
    }

    func testReservedVectorIsSplitWithoutLosingDisplacement() throws {
        let parts = PointerVector.safeParts(x: -100, y: -100)
        XCTAssertEqual(parts.count, 2)
        XCTAssertEqual(parts.reduce(0) { $0 + $1.x }, -100); XCTAssertEqual(parts.reduce(0) { $0 + $1.y }, -100)
        XCTAssertFalse(parts.contains(.reserved))
        XCTAssertEqual(PointerVector.safeParts(x: -100, y: -99), [PointerVector(-100, -99)])
        XCTAssertEqual(PointerVector.safeParts(x: 5, y: -100), [PointerVector(5, -100)])
        // Wire level: neither packet is the marker, the first carries elapsed, totals match.
        let packets = MultiControlWire.pointerPackets(x: -100, y: -100, elapsed: 7)
        XCTAssertEqual(packets.count, 2)
        XCTAssertFalse(packets.contains(MultiControlWire.focusReleaseMarker))
        XCTAssertEqual(packets[0].last, 7); XCTAssertEqual(packets[1].last, 0)
        XCTAssertEqual(MultiControlWire.focusReleaseMarker, MultiControlWire.motion(x: -100, y: -100))
        XCTAssertEqual(MultiControlWire.pointerPackets(x: 3, y: 4, elapsed: 2), [MultiControlWire.motion(x: 3, y: 4, elapsed: 2)])
    }

    func testPipelineNeverEmitsMarkerAndKeepsNetDisplacement() throws {
        let out = FakeOutput(); var t = 100.0
        let pipe = make(out) { t }
        // Accumulates exactly (-100,-100) inside one 6 ms window.
        pipe.move(dx: 1, dy: 1, osTime: t); t += 0.001          // leaves at once
        pipe.move(dx: -60, dy: -30, osTime: t); t += 0.001      // held in the window
        pipe.move(dx: -40, dy: -70, osTime: t)                  // window total is exactly (-100,-100)
        pipe.finish()
        XCTAssertEqual(out.udpSum.0, -99); XCTAssertEqual(out.udpSum.1, -99)
        for case let .udp(x, y, _) in out.events { XCTAssertFalse(x == -100 && y == -100) }
        XCTAssertEqual(out.events.count, 3)
        XCTAssertEqual(pipe.telemetry.snapshot().splitVectors, 1)
    }

    func testNetDisplacementOverLongSteadyStream() throws {
        let out = FakeOutput(); var t = 10.0
        let pipe = make(out) { t }
        var expected = (0, 0)
        for i in 0..<5000 {
            let dx = (i * 7) % 11 - 5, dy = (i * 13) % 9 - 4
            expected.0 += dx; expected.1 += dy
            t += 0.001
            pipe.move(dx: dx, dy: dy, osTime: t)
        }
        pipe.finish()
        XCTAssertEqual(out.udpSum.0, expected.0); XCTAssertEqual(out.udpSum.1, expected.1)
        // 5 s of 1 kHz input leaves at about one packet per 6 ms, not per event.
        let packets = out.events.count
        XCTAssertLessThan(packets, 1100); XCTAssertGreaterThan(packets, 700)
    }

    func testClickIsPrecededByPendingMovement() throws {
        let out = FakeOutput(); var t = 5.0
        let pipe = make(out) { t }
        pipe.move(dx: 1, dy: 1, osTime: t)               // sent at once (first)
        t += 0.002
        pipe.move(dx: 2, dy: 3, osTime: t)               // held by the 6 ms window
        t += 0.001
        pipe.input(.click(1, true))                       // forces the held movement out first
        t += 0.001
        pipe.move(dx: 4, dy: 5, osTime: t)
        pipe.input(.click(1, false))
        XCTAssertEqual(out.shape, [
            .udp(1, 1, 0), .udp(2, 3, 0), .queued(.click(1, true)),
            .udp(4, 5, 0), .queued(.click(1, false))])
        // Keys follow the same rule.
        t += 0.002; pipe.move(dx: 9, dy: 9, osTime: t); pipe.input(.key(0x1e, true))
        if case .udp(9, 9, _)? = out.events.dropLast().last {} else { XCTFail("movement must precede key") }
    }

    func testFallbackWhenUDPUnavailableQueuesMovementInOrder() throws {
        let out = FakeOutput(); out.outcome = .unavailable; var t = 1.0
        let pipe = make(out) { t }
        pipe.move(dx: 3, dy: 3, osTime: t); t += 0.007
        pipe.move(dx: 1, dy: 2, osTime: t)
        pipe.input(.click(1, true))
        XCTAssertEqual(out.shape, [.queued(.move(3, 3, 0)), .queued(.move(1, 2, 0)), .queued(.click(1, true))])
        XCTAssertEqual(pipe.telemetry.snapshot().fallbacks, 2)
    }

    func testSendFailureRecordsErrnoAndFallsBack() throws {
        let out = FakeOutput(); out.outcome = .failed(EAGAIN); var t = 1.0
        let pipe = make(out) { t }
        pipe.move(dx: 1, dy: 1, osTime: t); t += 0.01; pipe.move(dx: 1, dy: 1, osTime: t)
        let snap = pipe.telemetry.snapshot()
        XCTAssertEqual(snap.failures[EAGAIN], 2); XCTAssertEqual(snap.failureTotal, 2)
        XCTAssertTrue(snap.text.contains("errno\(EAGAIN)=2"))
    }

    func testQueueOverflowFailsAndClosedChannelFails() throws {
        let out = FakeOutput(); var t = 1.0
        let pipe = make(out) { t }
        var message: String?
        pipe.onFailure = { message = $0 }
        for _ in 0..<PointerPipeline.maxQueueDepth { pipe.input(.key(0x1e, true)); t += 0.001 }
        XCTAssertEqual(message, "Input transfer fell behind; control released.")
        let closed = FakeOutput(); closed.outcome = .closed
        let second = make(closed) { 2.0 }
        var closedMessage: String?
        second.onFailure = { closedMessage = $0 }
        second.move(dx: 1, dy: 1, osTime: 2.0)
        XCTAssertEqual(closedMessage, "The feature is not connected.")
        second.move(dx: 1, dy: 1, osTime: 3.0)   // inert after failure
    }

    func testReleasedControlDropsMovementSilently() throws {
        let out = FakeOutput(); out.controlling = false
        let pipe = make(out) { 1.0 }
        pipe.move(dx: 5, dy: 5, osTime: 1.0)
        XCTAssertTrue(out.events.isEmpty)
    }

    func testEventDrivenDeadlineAndFinalDeltaFlush() throws {
        var pacer = PointerPacer()
        XCTAssertNil(pacer.pendingDeadline)
        pacer.add(x: 1, y: 0, at: 0); XCTAssertEqual(pacer.pendingDeadline, 0)
        _ = pacer.take(at: 50)
        pacer.add(x: 2, y: 0, at: 50.002)
        XCTAssertEqual(try XCTUnwrap(pacer.pendingDeadline), 50.006, accuracy: 1e-9)
        XCTAssertNil(pacer.take(at: 50.004))
        XCTAssertEqual(pacer.take(at: 50.006)?.x, 2)       // one-shot final delta
        XCTAssertNil(pacer.pendingDeadline)
    }

    func testTelemetryBoundsAndGapCounts() throws {
        var series = IntervalSeries()
        for _ in 0..<(IntervalSeries.capacity * 3) { series.record(0.006) }
        series.record(0.025); series.record(0.060); series.record(5)     // 5 s is idle, excluded
        series.record(-1)
        let stats = series.stats()
        XCTAssertEqual(stats.count, IntervalSeries.capacity * 3 + 2)
        XCTAssertEqual(stats.over20, 2); XCTAssertEqual(stats.over50, 1)
        XCTAssertEqual(stats.idle, 1); XCTAssertEqual(stats.negative, 1)
        XCTAssertEqual(stats.max, 60, accuracy: 0.01)
        XCTAssertEqual(stats.p50, 6, accuracy: 0.01)
        XCTAssertEqual(stats.p99, 6, accuracy: 0.01)
        var ramp = IntervalSeries()
        for i in 1...100 { ramp.record(Double(i) / 1000) }
        let r = ramp.stats()
        XCTAssertEqual(r.p50, 50, accuracy: 0.01); XCTAssertEqual(r.p95, 95, accuracy: 0.01); XCTAssertEqual(r.p99, 99, accuracy: 0.01)
    }

    func testTelemetryTextContainsNoMotionData() throws {
        let out = FakeOutput(); var t = 1.0
        let pipe = make(out) { t }
        for _ in 0..<50 { t += 0.007; pipe.move(dx: 123, dy: -456, osTime: t) }
        let text = pipe.telemetry.snapshot().text
        XCTAssertTrue(text.contains("os-ts")); XCTAssertTrue(text.contains("send")); XCTAssertTrue(text.contains("queue-depth-max"))
        XCTAssertFalse(text.contains("123")); XCTAssertFalse(text.contains("456"))
    }

    func testOptionsParsing() throws {
        XCTAssertEqual(PointerOptions.parse([:]), PointerOptions())
        let o = PointerOptions.parse(["Pacing": "EVENT", "Placement": "main", "IPTOS": "0x10", "ReleaseMarker": "true"])
        XCTAssertEqual(o.pacing, .event); XCTAssertEqual(o.placement, .main); XCTAssertEqual(o.ipTOS, 16); XCTAssertTrue(o.releaseMarker)
        XCTAssertEqual(PointerOptions.parse(["IPTOS": "184"]).ipTOS, 184)
        // Out-of-range values keep the CS6 default rather than clearing it.
        XCTAssertEqual(PointerOptions.parse(["IPTOS": "999"]).ipTOS, 0xC0)
        XCTAssertEqual(PointerOptions.parse(["Pacing": "bogus"]).pacing, PointerOptions().pacing)
        // The Book's UDP QoS policy is the default; 0 downgrades to best effort.
        XCTAssertEqual(PointerOptions().ipTOS, 0xC0)
        XCTAssertEqual(PointerOptions.parse(["IPTOS": "0"]).ipTOS, 0)
    }

    func testWheelPacerDecimatesContinuousAndPassesDiscrete() throws {
        var pacer = WheelPacer()
        // A continuous trackpad stream releases one accumulated packet per 12 events.
        for i in 1...11 { XCTAssertNil(pacer.add(x: i, y: 0, continuous: true, ended: false)) }
        XCTAssertEqual(pacer.add(x: 12, y: 0, continuous: true, ended: false), PointerVector(78, 0))
        // The end of a gesture or momentum run flushes the partial tail.
        XCTAssertNil(pacer.add(x: 2, y: 1, continuous: true, ended: false))
        XCTAssertEqual(pacer.add(x: 0, y: 0, continuous: true, ended: true), PointerVector(2, 1))
        // Discrete mouse-wheel notches pass straight through.
        XCTAssertEqual(pacer.add(x: 3, y: 4, continuous: false, ended: false), PointerVector(3, 4))
        // A discrete notch after a partial trackpad stream flushes both together.
        XCTAssertNil(pacer.add(x: 5, y: 0, continuous: true, ended: false))
        XCTAssertEqual(pacer.add(x: 1, y: 2, continuous: false, ended: false), PointerVector(6, 2))
    }

    func testSenderWithoutSocketDeclinesAndCountsFallback() throws {
        let sender = PointerSender()
        XCTAssertEqual(sender.send(Data([77, 0, 1, 0, 1, 0])), .unavailable)
        XCTAssertEqual(sender.summary, "0 UDP packets, 1 TCP fallbacks")
        sender.close()
        XCTAssertEqual(sender.send(Data([1])), .closed)
    }

    func testSenderLoopbackSendsEncryptedDatagramAndSharesSequence() throws {
        let receiver = socket(AF_INET, SOCK_DGRAM, 0); defer { Darwin.close(receiver) }
        var addr = sockaddr_in(); addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        _ = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(receiver, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        var size = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(receiver, $0, &size) } }
        var tv = timeval(tv_sec: 1, tv_usec: 0); setsockopt(receiver, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        let sender = PointerSender()
        XCTAssertNotNil(sender.open(ipTOS: 0x10))
        XCTAssertTrue(sender.setupSummary.contains("service class RD set ok"), sender.setupSummary)
        XCTAssertTrue(sender.setupSummary.contains("IP_TOS 0x10 ok"), sender.setupSummary)
        sender.connect(remote: addr, key: Data(repeating: 7, count: 32), iv: Data(repeating: 9, count: 16))
        XCTAssertEqual(sender.nextSequence(), 1)
        XCTAssertEqual(sender.send(MultiControlWire.motion(x: 3, y: -4, elapsed: 6)), .sent)
        var buffer = [UInt8](repeating: 0, count: 2048)
        let n = recv(receiver, &buffer, buffer.count, 0)
        XCTAssertGreaterThan(n, 0)
        XCTAssertEqual(sender.summary, "1 UDP packets, 0 TCP fallbacks")
        XCTAssertEqual(sender.nextSequence(), 3)   // UDP consumed sequence 2
    }
}
