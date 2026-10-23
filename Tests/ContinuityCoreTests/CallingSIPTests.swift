import XCTest
@testable import ContinuityCore

final class CallingSIPTests: XCTestCase {
    func testPartialAndCoalescedSignalingWithKeepalive() throws {
        let packet = Data("SIP/2.0 200 OK\r\nCall-ID: synthetic\r\nCSeq: 1 REGISTER\r\nContent-Length: 3\r\n\r\nabc".utf8)
        var stream = CallingSIPStream()
        try stream.append(Data([13,10,13,10]) + packet.prefix(20))
        XCTAssertNil(try stream.next())
        try stream.append(packet.dropFirst(20) + packet)
        XCTAssertEqual(try stream.next()?.body, Data("abc".utf8))
        XCTAssertEqual(try stream.next()?.status, 200)
        XCTAssertNil(try stream.next())
    }
    func testAmbiguousLengthsAndHeaderInjectionFailClosed() throws {
        var stream = CallingSIPStream()
        try stream.append(Data("SIP/2.0 200 OK\r\nContent-Length: 0\r\nl: 3\r\n\r\nabc".utf8))
        XCTAssertThrowsError(try stream.next())
        XCTAssertThrowsError(try CallingSIPMessage.encode("REGISTER sip:example SIP/2.0", headers: [("From", "a\r\nInjected: b")]))
        XCTAssertEqual(CallingAccountContext.uuid5("synthetic"), "5823306d-9ce4-5166-9e15-261d24aa1430")
    }
}
