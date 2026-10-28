import XCTest
@testable import ContinuityCore

@MainActor final class HotspotPolicyTests: XCTestCase {
    func testCenterReturnsStoredAnswerUntilInvalidated() throws {
        let center = HotspotCenter()
        let credentials = HotspotCredentials(messagetype: 4, isSuccess: true, ssid: "Example hotspot", password: "pw", mhsfailed_reason: nil)
        center.store(address: "AA", credentials: credentials)
        XCTAssertEqual(center.cached(address: "AA")?.ssid, "Example hotspot")
        XCTAssertNil(center.cached(address: "BB"), "another device never shares the cache")
        center.invalidate(address: "AA")
        XCTAssertNil(center.cached(address: "AA"))
        center.store(address: "BB", credentials: credentials)
        center.invalidate()
        XCTAssertNil(center.cached(address: "BB"), "wake/disconnect drops every cached answer")
    }

    func testCapabilityMemoryExcludesDecliningDevicesUntilCleared() throws {
        let suite = "HotspotPolicyTests"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let memory = HotspotCapabilityMemory(defaults: defaults)
        XCTAssertFalse(memory.unavailable("AA"))
        memory.markUnavailable("AA", reason: 3)
        XCTAssertTrue(memory.unavailable("AA"))
        XCTAssertTrue(memory.unavailable("AA"), "the verdict persists across reads")
        memory.markAvailable("AA")
        XCTAssertFalse(memory.unavailable("AA"))
    }

    func testStatusDiscoveryReturnsPreciseBatteryWithoutActivation() throws {
        let query = try XCTUnwrap(JSONSerialization.jsonObject(with: HotspotInformation.request()) as? [String: Int])
        XCTAssertEqual(query["messagetype"], 1)
        XCTAssertNotEqual(query["messagetype"], 3)
        for percent in [0, 4, 15, 81, 100] {
            let value = try JSONDecoder().decode(HotspotInformation.self, from: JSONSerialization.data(withJSONObject: ["messagetype": 2, "batteryLevel": percent]))
            XCTAssertEqual(value.batteryPercent, percent)
            let center = HotspotCenter(); center.storeInformation(address: "AA", value: value)
            XCTAssertEqual(center.information(address: "AA")?.batteryPercent, percent)
            center.invalidate(); XCTAssertNil(center.information(address: "AA"))
        }
        let unknown = try JSONDecoder().decode(HotspotInformation.self, from: Data("{\"messagetype\":2,\"batteryLevel\":255}".utf8))
        XCTAssertNil(unknown.batteryPercent)
        XCTAssertLessThanOrEqual(HotspotCapabilityMemory.trustWindow, 120, "-6 means Auto Hotspot is disabled, not unsupported hardware")
    }
}
