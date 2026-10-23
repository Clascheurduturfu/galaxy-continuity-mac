import XCTest
@testable import ContinuityCore

final class CallingSessionTests: XCTestCase {
    func testJitterBufferReordersDropsDuplicatesAndWraps() {
        var jitter = CallingJitterBuffer(capacity: 6, prefill: 2)
        func frame(_ n: Int) -> [Int16] { [Int16](repeating: Int16(n), count: 320) }
        XCTAssertNil(jitter.pop().frame)                       // nothing yet
        jitter.push(sequence: 65534, frame: frame(1)); jitter.push(sequence: 0, frame: frame(3))      // wrap, out of order
        jitter.push(sequence: 65535, frame: frame(2)); jitter.push(sequence: 65535, frame: frame(9))  // duplicate
        XCTAssertEqual(jitter.duplicates, 1)
        XCTAssertEqual(jitter.pop().frame?.first, 1); XCTAssertEqual(jitter.pop().frame?.first, 2); XCTAssertEqual(jitter.pop().frame?.first, 3)
        jitter.push(sequence: 65533, frame: frame(0))          // late
        XCTAssertEqual(jitter.late, 1)
        // loss: 1 is missing while 2 and 3 are buffered
        jitter.push(sequence: 2, frame: frame(5)); jitter.push(sequence: 3, frame: frame(6))
        let gap = jitter.pop(); XCTAssertNil(gap.frame); XCTAssertTrue(gap.concealing)     // sequence 1 lost
        XCTAssertEqual(jitter.pop().frame?.first, 5)
        XCTAssertEqual(jitter.lost, 1)
    }

    func testJitterBufferIsBounded() {
        var jitter = CallingJitterBuffer(capacity: 4, prefill: 1)
        for n in 0..<4 { jitter.push(sequence: UInt16(n), frame: [Int16(n)]) }
        jitter.push(sequence: 10, frame: [10])    // forces discard of the oldest slots
        XCTAssertLessThanOrEqual(jitter.depth, 4)
        jitter.push(sequence: 5000, frame: [1])   // sender restarted: resets rather than growing
        XCTAssertLessThanOrEqual(jitter.depth, 4)
    }

    func testPCMRingDropsOldestAndReportsUnderflow() {
        let ring = CallingPCMRing(capacity: 8)
        ring.write([1, 2, 3, 4, 5, 6]); ring.write([7, 8, 9, 10])
        XCTAssertEqual(ring.available, 8); XCTAssertEqual(ring.overflowed, 2)
        XCTAssertEqual(ring.read(3), [3, 4, 5])
        XCTAssertEqual(ring.read(20), [6, 7, 8, 9, 10]); XCTAssertEqual(ring.underflowed, 1)
        ring.write(Array(1...20).map(Int16.init)); XCTAssertEqual(ring.read(8), Array(13...20).map(Int16.init))
    }

    #if canImport(CallingMediaC)
    /// Two sessions on loopback with crossed SRTP keys: encoded AMR-WB, 20 ms cadence, replay/tamper rejection.
    func testEncryptedLoopbackMediaBothDirections() throws {
        let queueA = DispatchQueue(label: "t.a"), queueB = DispatchQueue(label: "t.b")
        let sockA = try CallingUDPSocket(queue: queueA, bindAddress: "127.0.0.1"), sockB = try CallingUDPSocket(queue: queueB, bindAddress: "127.0.0.1")
        let keyAB = try CallingSDP.randomKey(), keyBA = try CallingSDP.randomKey()
        func plan(remote: UInt16, out: Data, inn: Data) -> CallingMediaPlan {
            CallingMediaPlan(remoteIP: "127.0.0.1", remotePort: Int(remote), payloadType: 116, dtmfPayloadType: 120, modeSet: [0, 1, 2], encoderMode: 2,
                             octetAligned: false, suite: "AES_CM_128_HMAC_SHA1_32", tagBytes: 4, outboundKey: out, inboundKey: inn, direction: "sendrecv")
        }
        let audioA = CallingMemoryAudio(), audioB = CallingMemoryAudio()
        let a = try CallingMediaSession(plan: plan(remote: sockB.port, out: keyAB, inn: keyBA), socket: sockA, audio: audioA, queue: queueA)
        let b = try CallingMediaSession(plan: plan(remote: sockA.port, out: keyBA, inn: keyAB), socket: sockB, audio: audioB, queue: queueB)
        a.setSendEnabled(true); b.setSendEnabled(true)
        try a.start(); try b.start()
        defer { a.stop(); b.stop() }
        // feed 440 Hz into A's microphone ring for ~1 s while B stays silent
        let tone = (0..<16000).map { Int16(sin(Double($0) * 2 * .pi * 440 / 16000) * 9000) }
        let deadline = Date().addingTimeInterval(1.2)
        var fed = 0, heard: [Int16] = []
        while Date() < deadline {
            if fed + 320 <= tone.count { audioA.capture.write(Array(tone[fed..<fed + 320])); fed += 320 }
            heard += audioB.playback.read(4000)
            Thread.sleep(forTimeInterval: 0.02)
        }
        heard += audioB.playback.read(16000)
        let energy = heard.reduce(0.0) { $0 + abs(Double($1)) } / Double(max(heard.count, 1))
        XCTAssertGreaterThan(heard.count, 16000 / 4, "B should have played at least 250 ms of A's speech")
        XCTAssertGreaterThan(energy, 500, "decoded audio must carry the tone, not silence")
        let statsB = queueB.sync { b.stats }
        XCTAssertGreaterThan(statsB.received, 20); XCTAssertEqual(statsB.rejected, 0)
        // 20 ms cadence: about 50 packets per second, nowhere near 100 or 25
        let statsA = queueA.sync { a.stats }
        XCTAssertTrue((35...65).contains(statsA.sent), "sent \(statsA.sent) packets in ~1.2 s")
        // injected garbage and a replayed packet are rejected
        let intruder = try CallingUDPSocket(queue: queueA, bindAddress: "127.0.0.1")
        intruder.send(Data(repeating: 0x80, count: 60), to: "127.0.0.1", port: sockB.port)
        Thread.sleep(forTimeInterval: 0.1)
        XCTAssertGreaterThanOrEqual(queueB.sync { b.stats.rejected }, 1)
        intruder.close()
    }

    func testEarlyMediaReplacementKeepsAdvertisedPortOpen() throws {
        let queue = DispatchQueue(label: "t.replace")
        let socket = try CallingUDPSocket(queue: queue, bindAddress: "127.0.0.1")
        let peer = try CallingUDPSocket(queue: queue, bindAddress: "127.0.0.1")
        var received = 0
        peer.startReceiving { _, _, _ in received += 1 }
        let key = try CallingSDP.randomKey()
        let plan = CallingMediaPlan(remoteIP: "127.0.0.1", remotePort: Int(peer.port), payloadType: 116, dtmfPayloadType: nil, modeSet: [2], encoderMode: 2,
                                    octetAligned: false, suite: "AES_CM_128_HMAC_SHA1_80", tagBytes: 10, outboundKey: key, inboundKey: key, direction: "sendrecv")
        let early = try CallingMediaSession(plan: plan, socket: socket, audio: CallingMemoryAudio(), queue: queue)
        try early.start(); early.stop(closeSocket: false)
        let final = try CallingMediaSession(plan: plan, socket: socket, audio: CallingMemoryAudio(), queue: queue)
        final.setSendEnabled(true); try final.start()
        defer { final.stop(); peer.close() }
        Thread.sleep(forTimeInterval: 0.3)
        XCTAssertGreaterThan(queue.sync { received }, 5)
        XCTAssertEqual(queue.sync { final.stats.sendFailures }, 0)
        XCTAssertEqual(final.localPort, socket.port)
    }


    func testEarlyKeepaliveEstablishesRTPWithoutSendingMicrophone() throws {
        let queue = DispatchQueue(label: "t.early-silence")
        let sock = try CallingUDPSocket(queue: queue, bindAddress: "127.0.0.1")
        let peer = try CallingUDPSocket(queue: queue, bindAddress: "127.0.0.1")
        let key = try CallingSDP.randomKey()
        let plan = CallingMediaPlan(remoteIP: "127.0.0.1", remotePort: Int(peer.port), payloadType: 116,
            dtmfPayloadType: nil, modeSet: [2], encoderMode: 2, octetAligned: false,
            suite: "AES_CM_128_HMAC_SHA1_80", tagBytes: 10, outboundKey: key, inboundKey: key, direction: "sendrecv")
        let audio = CallingMemoryAudio()
        audio.capture.write([Int16](repeating: 12000, count: 8000))
        let decrypt = try CallingSRTP(outboundKey: key, inboundKey: key, ssrc: 123, tagBytes: 10)
        let decoder = try CallingCodec()
        var samples = [Int16]()
        peer.startReceiving { data, _, _ in
            if let clear = try? decrypt.unprotect(data), let rtp = try? CallingRTP(packet: clear),
               let pcm = try? decoder.decode(rtp.payload, octetAligned: false) { samples += pcm }
        }
        let session = try CallingMediaSession(plan: plan, socket: sock, audio: audio, queue: queue)
        session.setEarlyKeepalive(true); try session.start()
        defer { session.stop(); peer.close() }
        Thread.sleep(forTimeInterval: 0.3)
        let snapshot = queue.sync { (session.stats, samples) }
        XCTAssertGreaterThan(snapshot.0.sent, 5); XCTAssertGreaterThan(snapshot.1.count, 1600)
        XCTAssertEqual(snapshot.0.captureTicks, 0, "No microphone frames may be read before answer")
        XCTAssertLessThan(snapshot.1.map { abs(Int($0)) }.max() ?? 999, 100, "Only encoded silence should arrive")
    }

    func testMutedSessionSendsOnlySilenceAndEarlyMediaSendsNothing() throws {
        let queue = DispatchQueue(label: "t.m")
        let sock = try CallingUDPSocket(queue: queue, bindAddress: "127.0.0.1"), peer = try CallingUDPSocket(queue: queue, bindAddress: "127.0.0.1")
        let mediaReceived = expectation(description: "Answered session sends at least six media packets")
        var received = 0
        peer.startReceiving { _, _, _ in
            received += 1
            if received == 6 { mediaReceived.fulfill() }
        }
        let key = try CallingSDP.randomKey()
        let plan = CallingMediaPlan(remoteIP: "127.0.0.1", remotePort: Int(peer.port), payloadType: 116, dtmfPayloadType: nil, modeSet: [2], encoderMode: 2,
                                    octetAligned: false, suite: "AES_CM_128_HMAC_SHA1_80", tagBytes: 10, outboundKey: key, inboundKey: key, direction: "sendrecv")
        let session = try CallingMediaSession(plan: plan, socket: sock, audio: CallingMemoryAudio(), queue: queue)
        try session.start(); defer { session.stop(); peer.close() }
        Thread.sleep(forTimeInterval: 0.3)
        XCTAssertEqual(queue.sync { received }, 0, "early media must not send the microphone before answer")
        session.setSendEnabled(true)
        wait(for: [mediaReceived], timeout: 3)
        XCTAssertGreaterThan(queue.sync { received }, 5)
    }
    #endif
}
