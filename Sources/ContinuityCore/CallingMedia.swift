import Foundation
#if canImport(CallingMediaC)
import CallingMediaC

/// Serial-use AMR-WB codec. Each frame represents 20 ms of mono 16 kHz PCM.
public final class CallingCodec {
    private let codec: cmc_codec_ref
    public init() throws {
        guard let value = cmc_codec_create() else { throw ContinuityError.message("Could not initialize call audio.") }
        codec = value
    }
    deinit { cmc_codec_destroy(codec) }
    public func encode(_ samples: [Int16], mode: Int = 2, octetAligned: Bool = false) throws -> Data {
        guard samples.count == 320, (0...8).contains(mode) else { throw ContinuityError.message("Invalid call audio frame.") }
        var frame = [UInt8](repeating: 0, count: 64)
        let count = cmc_amrwb_encode(codec, samples, &frame, frame.count, Int32(mode))
        guard count > 0, count <= frame.count else { throw ContinuityError.message("Call audio encoding failed.") }
        return try CallingAMRPayload.pack(Data(frame.prefix(Int(count))), octetAligned: octetAligned)
    }
    public func decode(_ payload: Data, octetAligned: Bool = false) throws -> [Int16] {
        let frames = try CallingAMRPayload.unpack(payload, octetAligned: octetAligned)
        return try frames.flatMap { try decodeFrame($0) }
    }
    private func decodeFrame(_ frame: Data) throws -> [Int16] {
        var result = [Int16](repeating: 0, count: 320)
        guard cmc_amrwb_decode(codec, [UInt8](frame), frame.count, &result) == 320 else {
            throw ContinuityError.message("Invalid AMR-WB audio payload.")
        }
        return result
    }
}

/// Each call owns its keys, replay window and packet counters. Never log this object.
public final class CallingSRTP {
    private let session: cmc_srtp_ref
    public init(outboundKey: Data, inboundKey: Data, ssrc: UInt32, tagBytes: Int) throws {
        guard outboundKey.count == 30, inboundKey.count == 30, [4, 10].contains(tagBytes) else {
            throw ContinuityError.message("Unsupported call encryption parameters.")
        }
        let value = outboundKey.withUnsafeBytes { out in inboundKey.withUnsafeBytes { input in
            cmc_srtp_create(out.bindMemory(to: UInt8.self).baseAddress, input.bindMemory(to: UInt8.self).baseAddress, ssrc, Int32(tagBytes))
        } }
        guard let value else { throw ContinuityError.message("Could not initialize encrypted call audio.") }
        session = value
    }
    deinit { cmc_srtp_destroy(session) }
    public func protect(_ data: Data) throws -> Data {
        guard (12...4096).contains(data.count) else { throw ContinuityError.message("Invalid call packet length.") }
        var bytes = [UInt8](data) + [UInt8](repeating: 0, count: Int(cmc_srtp_trailer_size()))
        var count = Int32(data.count)
        guard cmc_srtp_protect(session, &bytes, &count) == 0 else { throw ContinuityError.message("Call packet encryption failed.") }
        return Data(bytes.prefix(Int(count)))
    }
    public func unprotect(_ data: Data) throws -> Data {
        guard (16...4096).contains(data.count) else { throw ContinuityError.message("Invalid encrypted call packet length.") }
        var bytes = [UInt8](data); var count = Int32(bytes.count)
        guard cmc_srtp_unprotect(session, &bytes, &count) == 0 else {
            throw ContinuityError.message("Rejected an unauthenticated or replayed call packet.")
        }
        return Data(bytes.prefix(Int(count)))
    }
}
#endif

/// RFC 4867: Samsung's captured SDP omits octet-align, selecting bandwidth-efficient mode.
public enum CallingAMRPayload {
    static let speechBits = [132,177,253,285,317,365,397,461,477,40,-1,-1,-1,-1,0,0]
    public static func pack(_ storageFrame: Data, octetAligned: Bool) throws -> Data {
        let bytes = [UInt8](storageFrame)
        guard let header = bytes.first else { throw ContinuityError.message("Empty AMR frame.") }
        let bits = speechBits[Int((header >> 3) & 15)]
        guard bits >= 0, bytes.count == 1 + (bits + 7) / 8 else { throw ContinuityError.message("Invalid AMR frame size.") }
        if octetAligned { return Data([0xf0, header & 0x7c]) + storageFrame.dropFirst() }
        var packed = [UInt8](repeating: 0, count: (10 + bits + 7) / 8)
        func set(_ position: Int, _ value: UInt8) { packed[position / 8] |= value << (7 - position % 8) }
        for i in 0..<4 { set(i, 1) }
        for i in 0..<6 { set(4 + i, (header >> (7 - i)) & 1) }
        for i in 0..<bits { set(10 + i, (bytes[1 + i / 8] >> (7 - i % 8)) & 1) }
        return Data(packed)
    }
    public static func unpack(_ payload: Data, octetAligned: Bool) throws -> [Data] {
        let bytes = [UInt8](payload)
        var cursor = octetAligned ? 8 : 4
        func read(_ count: Int) throws -> UInt8 {
            guard cursor + count <= bytes.count * 8 else { throw ContinuityError.message("Truncated AMR payload.") }
            var value: UInt8 = 0
            for _ in 0..<count { value = (value << 1) | ((bytes[cursor / 8] >> (7 - cursor % 8)) & 1); cursor += 1 }
            return value
        }
        guard bytes.count >= 2 else { throw ContinuityError.message("Truncated AMR payload header.") }
        var headers: [UInt8] = []
        repeat {
            let toc = try read(6) << 2
            if octetAligned { _ = try read(2) }
            guard headers.count < 10, speechBits[Int((toc >> 3) & 15)] >= 0 else { throw ContinuityError.message("Unsupported AMR frame list.") }
            headers.append(toc)
        } while headers.last! & 0x80 != 0
        var result: [Data] = []
        for header in headers {
            let count = speechBits[Int((header >> 3) & 15)]
            var frame = [UInt8](repeating: 0, count: 1 + (count + 7) / 8); frame[0] = header & 0x7c
            for i in 0..<count { frame[1 + i / 8] |= try read(1) << (7 - i % 8) }
            if octetAligned, cursor % 8 != 0 { _ = try read(8 - cursor % 8) }
            result.append(Data(frame))
        }
        guard (bytes.count * 8 - cursor) < 8 else { throw ContinuityError.message("Unexpected AMR payload data.") }
        return result
    }
}

public struct CallingRTP {
    public var payloadType: UInt8
    public var marker: Bool
    public var sequence: UInt16
    public var timestamp: UInt32
    public var ssrc: UInt32
    public var payload: Data
    public init(payloadType: UInt8 = 116, marker: Bool = false, sequence: UInt16, timestamp: UInt32, ssrc: UInt32, payload: Data) {
        self.payloadType = payloadType; self.marker = marker; self.sequence = sequence
        self.timestamp = timestamp; self.ssrc = ssrc; self.payload = payload
    }
    public func encoded() -> Data {
        var bytes: [UInt8] = [0x80, (payloadType & 0x7f) | (marker ? 0x80 : 0)]
        func append(_ value: UInt32, count: Int) { for i in (0..<count).reversed() { bytes.append(UInt8(truncatingIfNeeded: value >> (i * 8))) } }
        append(UInt32(sequence), count: 2); append(timestamp, count: 4); append(ssrc, count: 4)
        return Data(bytes) + payload
    }
    public init(packet: Data) throws {
        let b = [UInt8](packet)
        guard b.count >= 12, b[0] >> 6 == 2 else { throw ContinuityError.message("Invalid RTP header.") }
        func uint(_ offset: Int, _ count: Int) -> UInt32 { b[offset..<(offset + count)].reduce(0) { ($0 << 8) | UInt32($1) } }
        var offset = 12 + Int(b[0] & 15) * 4
        guard offset <= b.count else { throw ContinuityError.message("Truncated RTP sources.") }
        if b[0] & 0x10 != 0 {
            guard offset + 4 <= b.count else { throw ContinuityError.message("Truncated RTP extension.") }
            offset += 4 + Int(uint(offset + 2, 2)) * 4
        }
        let padding = b[0] & 0x20 != 0 ? Int(b.last!) : 0
        guard offset <= b.count, padding <= b.count - offset, b[0] & 0x20 == 0 || padding > 0 else {
            throw ContinuityError.message("Invalid RTP payload bounds.")
        }
        payloadType = b[1] & 0x7f; marker = b[1] & 0x80 != 0
        sequence = UInt16(uint(2, 2)); timestamp = uint(4, 4); ssrc = uint(8, 4)
        payload = Data(b[offset..<(b.count - padding)])
    }
}
