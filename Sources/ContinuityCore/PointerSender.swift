import Foundation
import Darwin

public enum PointerSendOutcome: Equatable, Sendable {
    case sent
    /// No UDP path (not negotiated, or not ready): caller uses the reliable channel.
    case unavailable
    /// sendto failed or was short (errno, 0 when short): caller uses the reliable channel.
    case failed(Int32)
    /// The feature channel was closed.
    case closed
}

/// Thread-safe owner of the feature channel's UDP socket and packet sequence.
/// Encryption and sendto run on the caller's thread, so the pointer worker
/// never waits for the main actor. The sequence counter is shared with the
/// reliable channel, as in the original implementation.
public final class PointerSender: @unchecked Sendable {
    private let lock = NSLock()
    private var fd: Int32 = -1
    private var remote: sockaddr_in?
    private var key = Data(), iv = Data()
    private var sequence: UInt64 = 0
    private var closed = false
    private var sentCount = 0, declinedCount = 0
    public private(set) var setupSummary = ""
    public init() {}
    public var summary: String { lock.lock(); defer { lock.unlock() }; return "\(sentCount) UDP packets, \(declinedCount) TCP fallbacks" }

    /// Creates and binds the socket; returns the local UDP port, or nil.
    func open(ipTOS: Int?) -> UInt16? {
        lock.lock(); defer { lock.unlock() }
        let s = socket(AF_INET, SOCK_DGRAM, 0)
        guard s >= 0 else { return nil }
        _ = fcntl(s, F_SETFD, FD_CLOEXEC)
        var service = Int32(NET_SERVICE_TYPE_RD)
        let serviceResult = setsockopt(s, SOL_SOCKET, SO_NET_SERVICE_TYPE, &service, socklen_t(MemoryLayout<Int32>.size))
        let serviceErrno = serviceResult == 0 ? 0 : errno
        var report = "UDP socket: service class RD set " + (serviceResult == 0 ? "ok" : "failed errno \(serviceErrno)")
        var tosErrno: Int32 = 0
        if let ipTOS {
            var tos = Int32(ipTOS & 0xff)
            let result = setsockopt(s, IPPROTO_IP, IP_TOS, &tos, socklen_t(MemoryLayout<Int32>.size))
            tosErrno = result == 0 ? 0 : errno
            report += ", IP_TOS 0x" + String(ipTOS & 0xff, radix: 16) + (result == 0 ? " ok" : " failed errno \(tosErrno)")
        }
        var readService: Int32 = -1, readTOS: Int32 = -1, length = socklen_t(MemoryLayout<Int32>.size)
        if getsockopt(s, SOL_SOCKET, SO_NET_SERVICE_TYPE, &readService, &length) != 0 { readService = -1 }
        length = socklen_t(MemoryLayout<Int32>.size)
        if getsockopt(s, IPPROTO_IP, IP_TOS, &readTOS, &length) != 0 { readTOS = -1 }
        report += "; readback service=\(readService) ip_tos=\(readTOS)"
        var local = sockaddr_in(); local.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); local.sin_family = sa_family_t(AF_INET)
        let bound = withUnsafePointer(to: &local) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(s, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        var size = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &local) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(s, $0, &size) } }
        guard bound == 0, named == 0 else { Darwin.close(s); return nil }
        fd = s; setupSummary = report
        return UInt16(bigEndian: local.sin_port)
    }
    func connect(remote endpoint: sockaddr_in, key: Data, iv: Data) {
        lock.lock(); self.remote = endpoint; self.key = key; self.iv = iv; lock.unlock()
    }
    func nextSequence() -> UInt64 {
        lock.lock(); defer { lock.unlock() }
        sequence = sequence >= 127 ? 1 : sequence + 1
        return sequence
    }
    func close() {
        lock.lock(); closed = true
        if fd >= 0 { Darwin.close(fd); fd = -1 }
        remote = nil; lock.unlock()
    }
    /// Encrypts and sends one plaintext movement packet without blocking.
    public func send(_ data: Data) -> PointerSendOutcome {
        lock.lock(); defer { lock.unlock() }
        if closed { return .closed }
        guard fd >= 0, var endpoint = remote, iv.count == 16, data.count <= 1024 else { declinedCount += 1; return .unavailable }
        sequence = sequence >= 127 ? 1 : sequence + 1
        let packet: Data
        do { packet = MCFPacket(handler: 11, sequence: sequence, payload: try MCFCrypto.cbcFixed(data, key: key, iv: iv)).encoded }
        catch { declinedCount += 1; return .failed(EINVAL) }
        let result = packet.withUnsafeBytes { bytes in
            withUnsafePointer(to: &endpoint) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                sendto(fd, bytes.baseAddress, packet.count, MSG_DONTWAIT, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            } }
        }
        if result == packet.count { sentCount += 1; return .sent }
        declinedCount += 1
        return .failed(result < 0 ? errno : 0)
    }
}

/// Small lock-protected flag readable from the pointer worker.
public final class AtomicFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Bool
    public init(_ value: Bool = false) { stored = value }
    public var value: Bool {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }
}
