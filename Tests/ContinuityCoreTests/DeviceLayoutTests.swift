import XCTest
@testable import ContinuityCore

final class DeviceLayoutTests: XCTestCase {
    func testEverySideHasTouchingGeometryAndCorrectEntryEdge() {
        let width = 100, height = 200
        for side in DeviceSide.allCases {
            let p = DevicePlacement(side: side)
            let o = p.remoteOrigin(hostWidth: 1440, hostHeight: 900, remoteWidth: width, remoteHeight: height)
            let entry = p.remoteEntry(width: width, height: height, fraction: 0.25)
            switch side {
            case .left: XCTAssertEqual(o.x + width, 0); XCTAssertEqual(entry.x, 97)
            case .right: XCTAssertEqual(o.x, 1440); XCTAssertEqual(entry.x, 2)
            case .above: XCTAssertEqual(o.y + height, 0); XCTAssertEqual(entry.y, 197)
            case .below: XCTAssertEqual(o.y, 900); XCTAssertEqual(entry.y, 2)
            }
        }
    }
    func testPortalsAvoidCornersAndClampInvalidPlacement() {
        let center = DevicePlacement()
        XCTAssertTrue(center.containsPortal(0.5))
        XCTAssertFalse(center.containsPortal(0.01))
        XCTAssertFalse(center.containsPortal(.nan))
        XCTAssertEqual(DevicePlacement(offset: .nan).offset, 0)
        XCTAssertEqual(DevicePlacement(offset: 12).offset, 0.65)
    }
    func testBudsAliasesDeduplicateByAddressAndKeepDifferentHeadsets() {
        let values = [PairedBuds(id: "aa:bb:cc:11:22:33", name: "Buds"),
                      PairedBuds(id: "AA-BB-CC-11-22-33", name: "Buds"),
                      PairedBuds(id: "AA-BB-CC-11-22-44", name: "Buds")]
        XCTAssertEqual(PairedBuds.unique(values).count, 2)
        XCTAssertEqual(values[0].id, values[1].id)
    }
}
