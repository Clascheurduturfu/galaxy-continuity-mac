import XCTest
@testable import ContinuityCore

final class MultiControlTests: XCTestCase {
    func testAppDeviceIDMatchesJavaStringHash() {
        XCTAssertEqual(MultiControlWire.deviceID(address: "01:02:03:04:05:06"), "564055901")
        XCTAssertEqual(MultiControlWire.deviceID(address: " AA:BB:CC:DD:EE:FF "), MultiControlWire.deviceID(address: "aa:bb:cc:dd:ee:ff"))
    }
    func testRetainedInputPacketLayoutAndBounds() throws {
        XCTAssertEqual(MultiControlWire.key(scanCode: 0xe04b, down: true), Data([75, 0, 224, 75]))
        XCTAssertEqual(MultiControlWire.key(scanCode: 0x1e, down: false), Data([75, 1, 0, 30]))
        XCTAssertEqual(MultiControlWire.click(button: 2, down: true), Data([67, 0, 2]))
        XCTAssertEqual(MultiControlWire.motion(x: -1, y: 256), Data([77, 255, 255, 1, 0, 0]))
        XCTAssertEqual(MultiControlWire.motion(x: 90000, y: -90000, wheel: true), Data([87, 127, 255, 128, 0, 0]))
        XCTAssertEqual(MultiControlWire.motion(x: 1, y: -1, elapsed: 6), Data([77, 0, 1, 255, 255, 6]))
    }
    func testPointerCadenceKeepsTailAndAccumulatesMovement() throws {
        var pacer = PointerPacer()
        pacer.add(x: 1, y: -2, at: 100)
        XCTAssertEqual(pacer.take(at: 100)?.elapsed, 0)
        pacer.add(x: 3, y: 2, at: 100.001)
        pacer.add(x: -1, y: 4, at: 100.003)
        XCTAssertNil(pacer.take(at: 100.005))
        // Timer flushes this final movement even without another input event.
        let tail = try XCTUnwrap(pacer.take(at: 100.007))
        XCTAssertEqual(tail.x, 2); XCTAssertEqual(tail.y, 6)
        XCTAssertEqual(tail.events, 2); XCTAssertEqual(tail.elapsed, 7)
        XCTAssertEqual(tail.oldestEvent, 100.001)
        XCTAssertNil(pacer.take(at: 100.020))
        pacer.add(x: 5, y: 1, at: 102)
        XCTAssertEqual(pacer.take(at: 102)?.elapsed, 0)
    }
    func testPointerFlushBeforeClickPreservesShortMovement() throws {
        var pacer = PointerPacer()
        pacer.add(x: 1, y: 1, at: 10); _ = pacer.take(at: 10)
        pacer.add(x: 2, y: 3, at: 10.002)
        let forced = try XCTUnwrap(pacer.take(at: 10.003, force: true))
        XCTAssertEqual(forced.x, 2); XCTAssertEqual(forced.y, 3)
        XCTAssertNil(pacer.take(at: 10.004))
    }
    func testJSONKeepsParametersAsObjectAndTerminatesFrame() throws {
        let data = try MultiControlWire.message("FOCUS_DEVICE_CHANGED", parameters: ["TARGET": "synthetic", "X": 12, "Y": 34, "SEQ": 1], from: "Mac")
        XCTAssertEqual(data.last, 10)
        let object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual((object["PARAM"] as? [String: Any])?["X"] as? Int, 12)
        XCTAssertEqual(object["FROM"] as? String, "Mac")
    }
}
