import Foundation
import Darwin

/// Bounded PCM ring (16 kHz mono Int16). Locked with a tiny critical section; storage is preallocated so the
/// audio callbacks never allocate. Overflow drops the oldest samples; underflow returns fewer samples.
final class CallingPCMRing {
    private var storage: [Int16]
    private var head = 0, count = 0
    private let lock = NSLock()
    private(set) var overflowed = 0, underflowed = 0
    let capacity: Int
    init(capacity: Int) { self.capacity = capacity; storage = [Int16](repeating: 0, count: capacity) }
    var available: Int { lock.lock(); defer { lock.unlock() }; return count }
    func write(_ samples: UnsafeBufferPointer<Int16>) {
        lock.lock(); defer { lock.unlock() }
        var input = samples
        if input.count > capacity { overflowed += input.count - capacity; input = UnsafeBufferPointer(rebasing: input[(input.count - capacity)...]) }
        let free = capacity - count
        if input.count > free { let drop = input.count - free; head = (head + drop) % capacity; count -= drop; overflowed += drop }
        var tail = (head + count) % capacity
        for sample in input { storage[tail] = sample; tail += 1; if tail == capacity { tail = 0 } }
        count += input.count
    }
    func write(_ samples: [Int16]) { samples.withUnsafeBufferPointer { write($0) } }
    /// Reads up to `output.count` samples; returns the number delivered.
    @discardableResult func read(into output: UnsafeMutableBufferPointer<Int16>) -> Int {
        lock.lock(); defer { lock.unlock() }
        let n = min(output.count, count)
        var index = head
        for i in 0..<n { output[i] = storage[index]; index += 1; if index == capacity { index = 0 } }
        head = (head + n) % capacity; count -= n
        if n < output.count { underflowed += 1 }
        return n
    }
    func read(_ n: Int) -> [Int16] {
        var out = [Int16](repeating: 0, count: n)
        let got = out.withUnsafeMutableBufferPointer { read(into: $0) }
        return Array(out.prefix(got))
    }
    func clear() { lock.lock(); head = 0; count = 0; lock.unlock() }
}

/// Receive-side reordering buffer, one frame per packet, bounded. Handles 16-bit sequence wrap.
struct CallingJitterBuffer {
    let capacity: Int, prefill: Int
    private var frames: [UInt16: [Int16]] = [:]
    private var next: UInt16?
    private var started = false
    private var consecutiveUnderruns = 0
    private(set) var late = 0, duplicates = 0, lost = 0, dropped = 0
    init(capacity: Int = 10, prefill: Int = 3) { self.capacity = capacity; self.prefill = min(prefill, capacity) }
    var depth: Int { frames.count }

    mutating func push(sequence: UInt16, frame: [Int16]) {
        guard let expected = next else { next = sequence; frames[sequence] = frame; return }
        let delta = Int(Int16(bitPattern: sequence &- expected))
        if delta < 0 { late += 1; return }
        if delta > capacity * 4 { frames = [:]; next = sequence; started = false; dropped += 1 } // sender restarted or long gap
        if frames[sequence] != nil { duplicates += 1; return }
        frames[sequence] = frame
        while frames.count > capacity, var cursor = next {   // bound: discard oldest slot(s)
            if frames.removeValue(forKey: cursor) == nil { lost += 1 } else { dropped += 1 }
            cursor &+= 1; next = cursor
        }
    }

    /// Called every 20 ms. nil + `concealing == true` means "a frame was lost, play silence/concealment".
    mutating func pop() -> (frame: [Int16]?, concealing: Bool) {
        guard var cursor = next else { return (nil, false) }
        if !started {
            guard frames.count >= prefill else { return (nil, false) }
            started = true
        }
        if let frame = frames.removeValue(forKey: cursor) {
            cursor &+= 1; next = cursor; consecutiveUnderruns = 0
            return (frame, false)
        }
        if frames.isEmpty {
            consecutiveUnderruns += 1
            if consecutiveUnderruns > 10 { started = false }   // rebuffer after a long gap
            return (nil, false)
        }
        lost += 1; cursor &+= 1; next = cursor     // later frames exist: this one is lost
        return (nil, true)
    }
}

/// Minimal IPv4 UDP socket with a dispatch read source. Binds to an ephemeral port.
final class CallingUDPSocket {
    let port: UInt16
    private var fd: Int32
    private var source: DispatchSourceRead?
    private let queue: DispatchQueue
    init(queue: DispatchQueue, bindAddress: String = "0.0.0.0", port requested: UInt16 = 0) throws {
        self.queue = queue
        let descriptor = socket(AF_INET, SOCK_DGRAM, 0)
        guard descriptor >= 0 else { throw ContinuityError.message("Could not open call audio port.") }
        var yes: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in(); address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); address.sin_family = sa_family_t(AF_INET)
        address.sin_port = requested.bigEndian
        guard inet_pton(AF_INET, bindAddress, &address.sin_addr) == 1 else { Darwin.close(descriptor); throw ContinuityError.message("Invalid call audio address.") }
        let bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard bound == 0 else { Darwin.close(descriptor); throw ContinuityError.message("Could not bind a call audio port.") }
        var actual = sockaddr_in(); var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &actual) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &length) } }
        port = UInt16(bigEndian: actual.sin_port)
        _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK)
        fd = descriptor
    }
    func startReceiving(_ handler: @escaping (Data, String, UInt16) -> Void) {
        stopReceiving()
        let descriptor = fd
        let read = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
        read.setEventHandler {
            var buffer = [UInt8](repeating: 0, count: 2048)
            for _ in 0..<32 {
                var from = sockaddr_in(); var length = socklen_t(MemoryLayout<sockaddr_in>.size)
                let n = withUnsafeMutablePointer(to: &from) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(descriptor, &buffer, buffer.count, 0, $0, &length) } }
                if n <= 0 { break }
                var text = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                inet_ntop(AF_INET, &from.sin_addr, &text, socklen_t(INET_ADDRSTRLEN))
                handler(Data(buffer.prefix(n)), String(cString: text), UInt16(bigEndian: from.sin_port))
            }
        }
        read.resume(); source = read
    }
    @discardableResult func send(_ data: Data, to ip: String, port: UInt16) -> Bool {
        var address = sockaddr_in(); address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); address.sin_family = sa_family_t(AF_INET); address.sin_port = port.bigEndian
        guard fd >= 0, inet_pton(AF_INET, ip, &address.sin_addr) == 1 else { return false }
        return data.withUnsafeBytes { raw in withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            sendto(fd, raw.baseAddress, data.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == data.count } } }
    }
    func stopReceiving() {
        source?.cancel(); source = nil
    }
    func close() {
        stopReceiving()
        if fd >= 0 { Darwin.close(fd); fd = -1 }
    }
    deinit { close() }
}

/// Audio source/sink used by the media session: capture is read at 20 ms cadence, playback is fed 20 ms frames.
protocol CallingAudioIO: AnyObject {
    var capture: CallingPCMRing { get }
    var playback: CallingPCMRing { get }
    func start() throws
    func stop()
    /// One-line capture/playback state for the diagnostics log (no audio content).
    var diagnostics: String { get }
}
extension CallingAudioIO { var diagnostics: String { "" } }

#if canImport(CallingMediaC)
import CallingMediaC

struct CallingMediaStats: Equatable {
    var sent = 0, received = 0, rejected = 0, decodeErrors = 0, lost = 0, late = 0, duplicates = 0
    var latchedToSource = false
    var encoded = 0, encodeFailures = 0, protectFailures = 0, sendFailures = 0, captureTicks = 0, captureShort = 0, silentTicks = 0
}

/// UDP + AMR-WB + SRTP session. All state lives on `queue`. 20 ms cadence, RTP timestamp += 320 per frame.
/// SRTCP is deliberately not implemented: no RTCP is sent and inbound RTCP (if any) is ignored.
/// This is an unverified-on-network choice, see docs/CALLS_PROGRESS_2026-10-22.md.
final class CallingMediaSession {
    private let plan: CallingMediaPlan
    private let socket: CallingUDPSocket
    private let audio: CallingAudioIO
    private let codec: CallingCodec
    private let srtp: CallingSRTP
    let queue: DispatchQueue
    private var sendTimer: DispatchSourceTimer?, playTimer: DispatchSourceTimer?
    private var sequence = UInt16.random(in: 0...UInt16.max)
    private var timestamp = UInt32.random(in: 0...UInt32.max)
    private let ssrc = UInt32.random(in: 1...UInt32.max)
    private var first = true
    private var jitter = CallingJitterBuffer()
    private var remoteIP: String
    private var remotePort: UInt16
    private var sourceLatched = false
    private(set) var stats = CallingMediaStats()
    private var mutedFlag = false
    private var sendEnabled = false
    private var earlyKeepalive = false
    private var diagTimer: DispatchSourceTimer?
    private var rmsSum = 0.0, rmsCount = 0, lastLogged = CallingMediaStats()
    var onStats: ((CallingMediaStats) -> Void)?
    var localPort: UInt16 { socket.port }

    init(plan: CallingMediaPlan, socket: CallingUDPSocket, audio: CallingAudioIO, queue: DispatchQueue) throws {
        self.plan = plan; self.socket = socket; self.audio = audio; self.queue = queue
        codec = try CallingCodec()
        srtp = try CallingSRTP(outboundKey: plan.outboundKey, inboundKey: plan.inboundKey, ssrc: ssrc, tagBytes: plan.tagBytes)
        remoteIP = plan.remoteIP; remotePort = UInt16(plan.remotePort)
    }

    func setMuted(_ muted: Bool) { queue.async { self.mutedFlag = muted } }
    /// Early media is receive-only: the microphone is not sent until the call is answered.
    func setSendEnabled(_ enabled: Bool) { queue.async { self.sendEnabled = enabled } }

    /// Outgoing early media needs a return path through NAT. Send encrypted silence only,
    /// never microphone samples, until the INVITE is answered.
    func setEarlyKeepalive(_ enabled: Bool) { queue.async { self.earlyKeepalive = enabled } }

    func start() throws {
        try audio.start()
        socket.startReceiving { [weak self] data, ip, port in self?.receive(data, from: ip, port: port) }
        let send = DispatchSource.makeTimerSource(queue: queue)
        send.schedule(deadline: .now() + .milliseconds(20), repeating: .milliseconds(20), leeway: .milliseconds(1))
        send.setEventHandler { [weak self] in self?.sendTick() }
        send.resume(); sendTimer = send
        let play = DispatchSource.makeTimerSource(queue: queue)
        play.schedule(deadline: .now() + .milliseconds(20), repeating: .milliseconds(20), leeway: .milliseconds(1))
        play.setEventHandler { [weak self] in self?.playTick() }
        play.resume(); playTimer = play
        CallingDiagnostics.shared.log("media start remote=\(plan.remoteIP):\(plan.remotePort) local=\(socket.port) pt=\(plan.payloadType) mode=\(plan.encoderMode) octet=\(plan.octetAligned) suite=\(plan.suite) tag=\(plan.cryptoTag) tagBytes=\(plan.tagBytes) dir=\(plan.direction) dtmf=\(plan.dtmfPayloadType.map(String.init) ?? "-") ssrc-set")
        let diag = DispatchSource.makeTimerSource(queue: queue)
        diag.schedule(deadline: .now() + 1, repeating: 1)
        diag.setEventHandler { [weak self] in self?.logSecond() }
        diag.resume(); diagTimer = diag
    }

    private func logSecond() {
        let s = stats, p = lastLogged
        let rms = rmsCount > 0 ? Int((rmsSum / Double(rmsCount)).squareRoot()) : 0
        CallingDiagnostics.shared.log("media/s capFrames=\(s.captureTicks - p.captureTicks) capShort=\(s.captureShort - p.captureShort) capSilent=\(s.silentTicks - p.silentTicks) rms=\(rms) enc=\(s.encoded - p.encoded) encodeFail=\(s.encodeFailures - p.encodeFailures) rtpOut=\(s.sent - p.sent) protectFail=\(s.protectFailures - p.protectFailures) sockFail=\(s.sendFailures - p.sendFailures) rtpIn=\(s.received - p.received) unprotectFail=\(s.rejected - p.rejected) decodeErr=\(s.decodeErrors - p.decodeErrors) lost=\(s.lost - p.lost) late=\(s.late - p.late) jitter=\(jitter.depth) play=\(audio.playback.available) sendEn=\(sendEnabled) muted=\(mutedFlag) latched=\(s.latchedToSource) \(audio.diagnostics)")
        rmsSum = 0; rmsCount = 0; lastLogged = s
    }

    func stop(closeSocket: Bool = true) {
        sendTimer?.cancel(); playTimer?.cancel(); diagTimer?.cancel(); sendTimer = nil; playTimer = nil; diagTimer = nil
        CallingDiagnostics.shared.log("media stop sent=\(stats.sent) received=\(stats.received) rejected=\(stats.rejected)")
        audio.stop()
        if closeSocket { socket.close() } else { socket.stopReceiving() }
    }

    private func sendTick() {
        guard plan.sendsAudio, sendEnabled || earlyKeepalive else { audio.capture.clear(); return }
        var pcm = [Int16](repeating: 0, count: 320)
        if sendEnabled && !mutedFlag {
            let got = pcm.withUnsafeMutableBufferPointer { audio.capture.read(into: $0) }
            stats.captureTicks += 1
            if got < 320 { stats.captureShort += 1 }
            if got == 0 { stats.silentTicks += 1 }
            for i in 0..<got { let v = Double(pcm[i]); rmsSum += v * v }
            rmsCount += got
        } else { audio.capture.clear() }
        guard let payload = try? codec.encode(pcm, mode: plan.encoderMode, octetAligned: plan.octetAligned) else { stats.encodeFailures += 1; return }
        stats.encoded += 1
        transmit(CallingRTP(payloadType: UInt8(plan.payloadType), marker: first, sequence: sequence, timestamp: timestamp, ssrc: ssrc, payload: payload))
        first = false; sequence &+= 1; timestamp &+= 320
    }

    private func transmit(_ packet: CallingRTP) {
        guard let protected = try? srtp.protect(packet.encoded()) else { stats.protectFailures += 1; return }
        if socket.send(protected, to: remoteIP, port: remotePort) { stats.sent += 1; onStats?(stats) } else { stats.sendFailures += 1 }
    }

    /// RFC 4733 telephone-event, three updates plus three end packets. Timestamp stays at the event start.
    func sendDTMF(_ digit: Character) {
        guard let pt = plan.dtmfPayloadType, let event = "0123456789*#ABCD".firstIndex(of: digit).map({ "0123456789*#ABCD".distance(from: "0123456789*#ABCD".startIndex, to: $0) }) else { return }
        queue.async {
            let start = self.timestamp
            for step in 1...6 {
                let end = step > 3
                let duration = UInt16(min(step, 3) * 320)
                let payload = Data([UInt8(event), (end ? 0x80 : 0) | 10, UInt8(duration >> 8), UInt8(duration & 0xff)])
                self.transmit(CallingRTP(payloadType: UInt8(pt), marker: step == 1, sequence: self.sequence, timestamp: start, ssrc: self.ssrc, payload: payload))
                self.sequence &+= 1
            }
        }
    }

    func receive(_ data: Data, from ip: String, port: UInt16) {
        queue.async { [self] in
            guard let clear = try? srtp.unprotect(data), let packet = try? CallingRTP(packet: clear) else { stats.rejected += 1; return }
            // Authenticated: latch the return path to the real source (symmetric RTP behind NAT).
            if !sourceLatched, ip != remoteIP || port != remotePort { remoteIP = ip; remotePort = port; stats.latchedToSource = true }
            sourceLatched = true
            guard Int(packet.payloadType) == plan.payloadType, plan.receivesAudio else { return }
            guard let samples = try? codec.decode(packet.payload, octetAligned: plan.octetAligned), samples.count == 320 else { stats.decodeErrors += 1; return }
            stats.received += 1
            jitter.push(sequence: packet.sequence, frame: samples)
            stats.lost = jitter.lost; stats.late = jitter.late; stats.duplicates = jitter.duplicates
        }
    }

    private func playTick() {
        let result = jitter.pop()
        if let frame = result.frame { audio.playback.write(frame) }
        else if result.concealing { audio.playback.write([Int16](repeating: 0, count: 320)) }
    }
}
#endif
