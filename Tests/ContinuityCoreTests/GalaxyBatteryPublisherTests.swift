import XCTest
@testable import ContinuityCore

private final class BatteryBackend: AccessoryPowerSourceBackend {
    var available = true
    var createCode: Int32 = 0
    var updateCode: Int32 = 0
    var releaseFailures = 0
    var creates = 0
    var updates: [[String: Any]] = []
    var releases = 0
    var released: (() -> Void)?
    var updated: (() -> Void)?
    func create() -> (UnsafeMutableRawPointer?, Int32) {
        creates += 1
        return createCode == 0 ? (UnsafeMutableRawPointer(bitPattern: creates + 100), 0) : (nil, createCode)
    }
    func update(_ handle: UnsafeMutableRawPointer, details: [String: Any]) -> Int32 { updates.append(details); if updateCode == 0 { updated?() }; return updateCode }
    func release(_ handle: UnsafeMutableRawPointer) -> Int32 {
        releases += 1
        if releaseFailures > 0 { releaseFailures -= 1; return -1 }
        released?(); return 0
    }
}

@MainActor final class GalaxyBatteryPublisherTests: XCTestCase {
    private func sample(_ percent: Int = 72, address: String = "AA:BB:CC:11:22:01", at: Date = Date()) -> GalaxyBatterySample {
        .init(address: address, name: "Test Galaxy", percent: percent, receivedAt: at)
    }
    func testAccessoryIdentityAndUpdatesNeverClaimMacPowerOrCharging() {
        let backend = BatteryBackend()
        let subject = GalaxyBatteryPublisher(backend: backend, freshness: 300), now = Date()
        subject.synchronize([sample(at: now)], now: now)
        subject.synchronize([sample(address: "aabbcc112201", at: now.addingTimeInterval(1))], now: now.addingTimeInterval(1))
        XCTAssertEqual(backend.creates, 1); XCTAssertEqual(backend.updates.count, 1)
        let details = backend.updates[0]
        XCTAssertEqual(details["Type"] as? String, "Accessory Source")
        XCTAssertEqual(details["Accessory Category"] as? String, "Unknown")
        XCTAssertEqual(details["Power Source State"] as? String, "Unknown")
        XCTAssertNil(details["Is Charging"])
        XCTAssertFalse((details["Accessory Identifier"] as? String ?? "").contains("aabbcc112201"))
        let phone = GalaxyBatterySample(address: "AA:BB:CC:11:22:01", name: "Test Galaxy", percent: 72, receivedAt: now, deviceType: "phone")
        let phoneDetails = phone.details
        XCTAssertEqual(phoneDetails["Type"] as? String, "Accessory Source")
        XCTAssertEqual(phoneDetails["Power Source State"] as? String, "Unknown")
        XCTAssertNil(phoneDetails["Is Charging"])
        XCTAssertEqual(phone.identifier, sample(at: now).identifier)
        XCTAssertEqual(phoneDetails["Accessory Category"] as? String, "Battery Case")
        XCTAssertEqual(phoneDetails["Name"] as? String, "Test Galaxy")
        subject.synchronize([phone], now: now.addingTimeInterval(1))
        XCTAssertEqual(backend.creates, 1, "Changing the glyph must not duplicate the device")
        XCTAssertEqual(backend.updates.count, 2, "A glyph-only change updates the existing OS entry")
        subject.synchronize([sample(71, at: now.addingTimeInterval(2))], now: now.addingTimeInterval(2))
        XCTAssertEqual(backend.creates, 1); XCTAssertEqual(backend.updates.count, 3)
        subject.synchronize([], now: now.addingTimeInterval(3))
        XCTAssertEqual(backend.releases, 1); XCTAssertEqual(subject.publishedCount, 0)
    }
    func testInvalidOrStaleReadingsAreNeverPublished() {
        let backend = BatteryBackend()
        let publisher = GalaxyBatteryPublisher(backend: backend, freshness: 300), now = Date()
        publisher.synchronize([sample(-1), sample(101), sample(address: "invalid"), sample(at: now.addingTimeInterval(-300)), sample(at: now.addingTimeInterval(60))], now: now)
        XCTAssertEqual(backend.creates, 0)
        publisher.synchronize([sample(0, at: now)], now: now)
        XCTAssertEqual(publisher.publishedCount, 1)
        publisher.clear(); XCTAssertEqual(backend.releases, 1)
    }
    func testRejectedUpdateReleasesHandleAndThrottlesRetries() {
        let backend = BatteryBackend(), now = Date()
        backend.updateCode = -1
        let publisher = GalaxyBatteryPublisher(backend: backend, freshness: 300)
        publisher.synchronize([sample(at: now)], now: now)
        publisher.synchronize([sample(at: now)], now: now.addingTimeInterval(1))
        XCTAssertEqual(backend.creates, 1); XCTAssertEqual(backend.releases, 1)
        XCTAssertEqual(publisher.publishedCount, 0); XCTAssertNotNil(publisher.lastError)
        backend.updateCode = 0
        publisher.synchronize([sample(at: now.addingTimeInterval(61))], now: now.addingTimeInterval(61))
        XCTAssertEqual(publisher.publishedCount, 1); XCTAssertNil(publisher.lastError)
        publisher.clear()
    }
    func testExpiryRemovesEntryAndRequestsFreshStatus() async {
        let backend = BatteryBackend(), removed = expectation(description: "Stale OS battery entry removed")
        backend.released = { removed.fulfill() }
        let publisher = GalaxyBatteryPublisher(backend: backend, freshness: 0.05)
        var refreshes = 0
        publisher.expired = { addresses in
            XCTAssertEqual(addresses, ["AA:BB:CC:11:22:01"])
            refreshes += 1
        }
        publisher.synchronize([sample()])
        await fulfillment(of: [removed], timeout: 3)
        XCTAssertEqual(publisher.publishedCount, 0); XCTAssertEqual(refreshes, 1)
        publisher.clear()
    }
    func testInitialFailureRetriesWithoutAnotherDeviceQuery() async {
        let backend = BatteryBackend(), recovered = expectation(description: "OS publication retried from cached battery")
        backend.updateCode = -1
        let publisher = GalaxyBatteryPublisher(backend: backend, freshness: 3, retryDelay: 0.04)
        publisher.synchronize([sample()])
        backend.updated = { recovered.fulfill() }; backend.updateCode = 0
        await fulfillment(of: [recovered], timeout: 2)
        XCTAssertEqual(publisher.publishedCount, 1); XCTAssertNil(publisher.lastError)
        XCTAssertEqual(backend.creates, 2)
        publisher.clear()
    }
    func testFailedRemovalIsRetainedAndRetriedAfterDisable() async {
        let backend = BatteryBackend(), removed = expectation(description: "Rejected removal retried")
        let publisher = GalaxyBatteryPublisher(backend: backend, freshness: 300, cleanupDelay: 0.04)
        publisher.synchronize([sample()])
        backend.releaseFailures = 1; backend.released = { removed.fulfill() }
        publisher.clear()
        XCTAssertNotNil(publisher.lastError)
        await fulfillment(of: [removed], timeout: 2)
        XCTAssertEqual(backend.releases, 2); XCTAssertNil(publisher.lastError)
        XCTAssertEqual(publisher.publishedCount, 0)
    }
}
