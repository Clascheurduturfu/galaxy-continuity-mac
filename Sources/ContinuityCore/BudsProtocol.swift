import Foundation

/// Samsung's TWU universal framing, recovered from the installed Settings formatter.
/// This serial control protocol is separate from MCF phone authentication.
public struct BudsPacket: Equatable, Sendable {
    public let id: UInt8
    public let payload: Data
    public let response: Bool
    public let fragmented: Bool

    public init(id: UInt8, payload: Data = Data(), response: Bool = false, fragmented: Bool = false) {
        self.id = id; self.payload = payload; self.response = response; self.fragmented = fragmented
    }
    public static func checksum(_ data: Data) -> UInt16 {
        var crc: UInt16 = 0
        for byte in data {
            crc ^= UInt16(byte) << 8
            for _ in 0..<8 { crc = crc & 0x8000 != 0 ? (crc &<< 1) ^ 0x1021 : crc &<< 1 }
        }
        return crc
    }
    public func encoded() throws -> Data {
        guard payload.count <= 1019, !fragmented else { throw ContinuityError.message("Unsupported Buds packet size or fragment.") }
        let header = UInt16(payload.count + 4) | (response ? 0x1000 : 0)
        var body = Data([1, id]); body.append(payload)
        let crc = Self.checksum(body)
        return Data([0xfc, UInt8(header & 255), UInt8(header >> 8)]) + body + Data([UInt8(crc & 255), UInt8(crc >> 8), 0xcc])
    }
    public static var features: Self { .init(id: 0x44, payload: Data([0, 1])) }
    public static var takeAudio: Self { .init(id: 0x71, payload: Data([1])) }
    public static func mdeVersion(_ version: UInt8) -> Self {
        .init(id: 0x43, payload: Data([4, 3, 7, 0, 0, 0x0b, version, 0, 0, 0]))
    }
    public static func playback(playing: Bool) -> Self {
        .init(id: 0x43, payload: Data([4, 3, 4, 0, 0, 0x0c, playing ? 1 : 2]))
    }
    public static func output(selected: Bool) -> Self { .init(id: 0x43, payload: Data([4, 3, 4, 0, 0, 0x0e, selected ? 1 : 0])) }
    public static var computerInfo: Self {
        // Computer / classic transport, unspecified product. Apple by default.
        .init(id: 0x73, payload: Data([1, 1, 4, 0, 1, 0x4c, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]))
    }

    public var tlvs: [(UInt16, Data)]? {
        guard !fragmented, id == 0x44 || id == 0x45 else { return nil }
        let raw = Array(payload); var offset = id == 0x44 ? 2 : 0
        guard raw.count >= offset else { return nil }
        var values: [(UInt16, Data)] = []
        while offset < raw.count {
            guard raw.count - offset >= 3 else { return nil }
            let tag = UInt16(raw[offset]) | UInt16(raw[offset + 1]) << 8
            let count = Int(raw[offset + 2]); offset += 3
            guard count <= raw.count - offset else { return nil }
            values.append((tag, Data(raw[offset..<(offset + count)]))); offset += count
        }
        return values
    }
    /// The installed Samsung formatter reads only these bounded status fields.
    /// Other TLV bytes can contain peer identities and are deliberately omitted.
    public var multipointStatus: (background: Bool, stream: UInt8, reason: UInt8)? {
        guard let raw = tlvs?.first(where: { $0.0 == 0x0502 })?.1,
              raw.count >= 18, raw[0] == 0x0b, raw[1] <= 1 else { return nil }
        return (raw[1] == 1, raw[7], raw[2])
    }
    public var supportsMultipoint: Bool? {
        guard let raw = tlvs?.first(where: { $0.0 == 0x0117 })?.1, let first = raw.first else { return nil }
        return first != 0
    }
}

/// RFCOMM callbacks can split/coalesce packets or deliver corrupt data.
public struct BudsPacketDecoder {
    private var buffer = Data()
    public init() {}
    public mutating func append(_ input: Data) -> [BudsPacket] {
        guard input.count <= 65_536, buffer.count + input.count <= 131_072 else { buffer.removeAll(); return [] }
        buffer.append(input); var packets: [BudsPacket] = []
        while buffer.count >= 3 {
            guard let start = buffer.firstIndex(of: 0xfc) else { buffer.removeAll(); break }
            if start != buffer.startIndex { buffer = Data(buffer[start...]) }
            guard buffer.count >= 3 else { break }
            let raw = Array(buffer.prefix(1027))
            let header = UInt16(raw[1]) | UInt16(raw[2]) << 8
            let total = Int(header & 0x3ff) + 4
            let fragmented = header & 0x2000 != 0
            guard total >= (fragmented ? 12 : 8) else { buffer.removeFirst(); continue }
            guard buffer.count >= total else { break }
            let frame = Array(buffer.prefix(total))
            let crc = UInt16(frame[total - 3]) | UInt16(frame[total - 2]) << 8
            guard frame[total - 1] == 0xcc, frame[3] == 1,
                  BudsPacket.checksum(Data(frame[3..<(total - 3)])) == crc else { buffer.removeFirst(); continue }
            let offset = fragmented ? 9 : 5
            packets.append(.init(id: frame[4], payload: Data(frame[offset..<(total - 3)]), response: header & 0x1000 != 0, fragmented: fragmented))
            buffer = Data(buffer.dropFirst(total))
        }
        return packets
    }
}
