import XCTest
@testable import ContinuityCore

@MainActor final class HotspotPolicyTests: XCTestCase {
    func testCenterReturnsStoredAnswerUntilInvalidated() throws {
        let center = HotspotCenter()
        let credentials = HotspotCredentials(messagetype: 4, isSuccess: true, ssid: "Le réseau de la hess", password: "pw", mhsfailed_reason: nil)
        center.store(address: "AA", credentials: credentials)
        XCTAssertEqual(center.cached(address: "AA")?.ssid, "Le réseau de la hess")
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
}
