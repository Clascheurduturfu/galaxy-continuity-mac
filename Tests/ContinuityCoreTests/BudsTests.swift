import XCTest
@testable import ContinuityCore

final class BudsTests: XCTestCase {
    func testSamsungForegroundReferenceAndCRC() throws {
        // Literal foreground packet retained in Samsung EasyConnect2.Buds.SetForegroundAsync.
        let reference = Data([0xfc, 5, 0x10, 1, 0x71, 1, 0x79, 0x1c, 0xcc])
        XCTAssertEqual(try BudsPacket(id: 0x71, payload: Data([1]), response: true).encoded(), reference)
        var decoder = BudsPacketDecoder()
        XCTAssertEqual(decoder.append(reference), [.init(id: 0x71, payload: Data([1]), response: true)])
    }
    func testFragmentedReadsCorruptionAndCoalescedFrames() throws {
        let first = try BudsPacket.features.encoded(), second = try BudsPacket.takeAudio.encoded()
        var corrupt = first; corrupt[corrupt.count - 3] ^= 1
        var decoder = BudsPacketDecoder()
        XCTAssertTrue(decoder.append(Data([0, 0xcc]) + corrupt + first.prefix(4)).isEmpty)
        XCTAssertEqual(decoder.append(Data(first.dropFirst(4)) + second), [.features, .takeAudio])
    }
    func testStrictTLVBoundaries() {
        let packet = BudsPacket(id: 0x45, payload: Data([4, 3, 2, 0, 1]))
        XCTAssertEqual(packet.tlvs?.count, 1)
        XCTAssertEqual(packet.tlvs?.first?.0, 0x0304)
        XCTAssertEqual(packet.tlvs?.first?.1, Data([0, 1]))
        XCTAssertNil(BudsPacket(id: 0x45, payload: Data([4, 3, 20, 0])).tlvs)
        XCTAssertNil(BudsPacket(id: 0x44, payload: Data([0])).tlvs)
    }
    func testBoundsAndAppleIdentity() throws {
        XCTAssertThrowsError(try BudsPacket(id: 1, payload: Data(count: 1020)).encoded())
        XCTAssertEqual(BudsPacket.computerInfo.payload[5], 0x4c)
        var decoder = BudsPacketDecoder()
        XCTAssertTrue(decoder.append(Data(count: 65_537)).isEmpty)
        XCTAssertEqual(decoder.append(try BudsPacket.features.encoded()), [.features])
    }
    func testMultipointStatusBoundsAndIdentityOmission() {
        // Samsung callback: tag 0502, length >=18, discriminator 0B;
        // state/reason/stream at offsets 1/2/7. Remaining bytes are not exposed.
        var status = Data(repeating: 0xaa, count: 18)
        status[0] = 0x0b; status[1] = 1; status[2] = 3; status[7] = 0x80
        let packet = BudsPacket(id: 0x45, payload: Data([2, 5, 18]) + status)
        XCTAssertEqual(packet.multipointStatus?.background, true)
        XCTAssertEqual(packet.multipointStatus?.stream, 0x80)
        XCTAssertEqual(packet.multipointStatus?.reason, 3)
        XCTAssertNil(BudsPacket(id: 0x45, payload: Data([2, 5, 17]) + status.prefix(17)).multipointStatus)
        status[1] = 2
        XCTAssertNil(BudsPacket(id: 0x45, payload: Data([2, 5, 18]) + status).multipointStatus)
    }
}
