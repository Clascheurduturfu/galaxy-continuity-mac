import XCTest
@testable import ContinuityCore

final class CallingMediaTests: XCTestCase {
    func testBandwidthEfficientAndOctetAlignedPayloads() throws {
        let frame = Data([0x14] + [UInt8](repeating: 0, count: 32))
        let packed = try CallingAMRPayload.pack(frame, octetAligned: false)
        XCTAssertEqual(Array(packed.prefix(2)), [0xf1, 0x40])
        XCTAssertEqual(packed.count, 33)
        XCTAssertEqual(try CallingAMRPayload.unpack(packed, octetAligned: false), [frame])
        XCTAssertEqual(try CallingAMRPayload.unpack(Data([0xf0]) + frame, octetAligned: true), [frame])
        XCTAssertThrowsError(try CallingAMRPayload.unpack(Data(packed.prefix(31)), octetAligned: false))
        XCTAssertThrowsError(try CallingAMRPayload.unpack(Data([0xf5, 0x40]), octetAligned: false))
    }
    func testRTPBoundsAndExtensions() throws {
        let packet = CallingRTP(sequence: 65535, timestamp: 0xffffff00, ssrc: 0x10203040, payload: Data([1, 2, 3])).encoded()
        let read = try CallingRTP(packet: packet)
        XCTAssertEqual(read.sequence, 65535); XCTAssertEqual(read.timestamp, 0xffffff00)
        XCTAssertEqual(read.payload, Data([1, 2, 3]))
        var extensionPacket = [UInt8](packet.prefix(12)); extensionPacket[0] = 0xb0
        extensionPacket += [0xbe, 0xde, 0, 1, 10, 20, 30, 40, 5, 6, 0, 2]
        XCTAssertEqual(try CallingRTP(packet: Data(extensionPacket)).payload, Data([5, 6]))
        extensionPacket[15] = 255
        XCTAssertThrowsError(try CallingRTP(packet: Data(extensionPacket)))
        XCTAssertThrowsError(try CallingRTP(packet: Data(packet.prefix(11))))
    }
    #if canImport(CallingMediaC)
    func testCodecAndAuthenticatedTransport() throws {
        let encoder = try CallingCodec(), decoder = try CallingCodec()
        let pcm = (0..<320).map { Int16(sin(Double($0) * 2 * .pi * 440 / 16000) * 8000) }
        let encoded = try encoder.encode(pcm)
        XCTAssertEqual(encoded.count, 33)
        XCTAssertEqual(try decoder.decode(encoded).count, 320)
        XCTAssertThrowsError(try decoder.decode(Data([0xf0, 0x94])))
        let keyA = Data((0..<30).map(UInt8.init)), keyB = Data((30..<60).map(UInt8.init))
        for tag in [4, 10] {
            let a = try CallingSRTP(outboundKey: keyA, inboundKey: keyB, ssrc: 123, tagBytes: tag)
            let b = try CallingSRTP(outboundKey: keyB, inboundKey: keyA, ssrc: 456, tagBytes: tag)
            let raw = CallingRTP(sequence: 1, timestamp: 320, ssrc: 123, payload: encoded).encoded()
            let encrypted = try a.protect(raw)
            XCTAssertEqual(encrypted.count, raw.count + tag)
            var tampered = encrypted; tampered[tampered.count - 1] ^= 1
            XCTAssertThrowsError(try b.unprotect(tampered))
            XCTAssertEqual(try b.unprotect(encrypted), raw)
            XCTAssertThrowsError(try b.unprotect(encrypted))
            let response = CallingRTP(sequence: 500, timestamp: 3200, ssrc: 456, payload: encoded).encoded()
            XCTAssertEqual(try a.unprotect(b.protect(response)), response)
        }
    }
    #endif
}
