import XCTest
import CryptoKit
@testable import ContinuityCore

final class NearbyPeersTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let fingerprint = Data(0..<32)
    let phone = ContinuityProfile.Peer(address: "01:02:03:04:05:06", name: "Phone", deviceType: "phone", model: nil)
    let tab = ContinuityProfile.Peer(address: "11:22:33:44:55:66", name: "Tab", deviceType: "tablet", model: nil)
    let book = ContinuityProfile.Peer(address: "AA:BB:CC:DD:EE:FF", name: "Book", deviceType: "pc", model: nil)
    func advertisement() -> Data {
        // Same independently checked Samsung-format fixture as WireTests. Its
        // mobile address hint is 04:05; it belongs to the phone, not the tablet.
        let table = Array(SHA256.hash(data: fingerprint)), rotation = Int(now.timeIntervalSince1970 * 1000) / 43_200_000
        let check = (0..<10).reduce(UInt8(0)) { $0 ^ table[(($1 - rotation) % 32 + 32) % 32] }
        var raw = [UInt8]([2, 24, check, 0, 0x61]) + [UInt8](repeating: 0, count: 8) + [0x21, 16, 11, 0x61, 0, 128, 10, 7, 5, 0, 0x34, 1, 4, 5]
        for i in 16..<raw.count { raw[i] ^= table[i % 32] }
        return Data([0x75, 0] + raw)
    }
    func endpoint(port: Int = 1234) -> ContinuityDevice {
        ContinuityDevice(id: "nonce.local", name: "Book", host: "book.local.", port: port, instance: "nonce", encryptedIdentity: "", address: book.address)
    }
    func testAccountMembershipDoesNotClaimPhysicalPresence() {
        var registry = NearbyPeerRegistry(); registry.setPeers([phone, tab, book])
        let rows = registry.rows(now: now)
        XCTAssertEqual(rows.count, 3)
        XCTAssertTrue(rows.allSatisfy { !$0.nearby && !$0.connected && $0.network == nil })
        XCTAssertEqual(rows.first { $0.address == book.address }?.symbol, "laptopcomputer")
        XCTAssertEqual(rows.first { $0.address == tab.address }?.symbol, "ipad")
    }
    func testBluetoothAndNetworkDevicesMergeWithoutHidingOtherPeers() {
        var registry = NearbyPeerRegistry(); registry.setPeers([phone, tab, book])
        XCTAssertTrue(registry.observeBluetooth(advertisement(), fingerprint: fingerprint, now: now))
        registry.setNetwork([endpoint()])
        let rows = registry.rows(now: now)
        XCTAssertEqual(rows.count, 3)
        XCTAssertEqual(rows.filter(\.nearby).count, 2)
        XCTAssertTrue(rows.first { $0.address == phone.address }!.bluetoothConnectable)
        XCTAssertFalse(rows.first { $0.address == tab.address }!.nearby)
        XCTAssertEqual(rows.first { $0.address == book.address }!.network?.port, 1234)
    }
    func testWrongAccountMalformedAndAmbiguousHintsDoNotMarkPeersNearby() {
        var registry = NearbyPeerRegistry(); registry.setPeers([phone])
        XCTAssertFalse(registry.observeBluetooth(advertisement(), fingerprint: Data(repeating: 0xaa, count: 32), now: now))
        XCTAssertFalse(registry.observeBluetooth(Data([0x75, 0, 2]), fingerprint: fingerprint, now: now))
        let collision = ContinuityProfile.Peer(address: "99:88:77:04:05:09", name: "Collision", deviceType: "phone", model: nil)
        registry.setPeers([phone, collision])
        XCTAssertFalse(registry.observeBluetooth(advertisement(), fingerprint: fingerprint, now: now))
        XCTAssertTrue(registry.rows(now: now).allSatisfy { !$0.nearby })
    }
    func testExpiredAdvertisementDoesNotDropAuthenticatedConnection() {
        var registry = NearbyPeerRegistry(); registry.setPeers([phone])
        registry.observeBluetooth(advertisement(), fingerprint: fingerprint, now: now)
        let later = now.addingTimeInterval(NearbyPeerRegistry.bluetoothLifetime + 1)
        XCTAssertFalse(registry.rows(now: later)[0].nearby)
        registry.setConnected(["010203040506"])
        XCTAssertTrue(registry.rows(now: later)[0].connected)
        XCTAssertFalse(registry.rows(now: later)[0].bluetoothNearby)
        registry.setConnected([])
        XCTAssertFalse(registry.rows(now: later)[0].nearby)
    }
    func testNetworkEndpointRefreshAndRemovalNeverKeepOldPort() {
        var registry = NearbyPeerRegistry(); registry.setPeers([book])
        registry.setNetwork([endpoint()]); XCTAssertEqual(registry.rows(now: now)[0].network?.port, 1234)
        registry.setNetwork([endpoint(port: 2345)]); XCTAssertEqual(registry.rows(now: now)[0].network?.port, 2345)
        registry.setNetwork([endpoint(port: 0)]); XCTAssertNil(registry.rows(now: now)[0].network)
        registry.setNetwork([endpoint()]); registry.setNetwork([])
        XCTAssertFalse(registry.rows(now: now)[0].nearby)
    }
    func testAccountRemovalAndResetDiscardOldObservations() {
        var registry = NearbyPeerRegistry(); registry.setPeers([phone, tab])
        registry.observeBluetooth(advertisement(), fingerprint: fingerprint, now: now)
        registry.setPeers([tab]); XCTAssertEqual(registry.rows(now: now).map(\.address), [tab.address])
        registry.setPeers([phone]); XCTAssertFalse(registry.rows(now: now)[0].nearby)
        let duplicate = ContinuityProfile.Peer(address: "010203040506", name: "Duplicate", deviceType: "phone", model: nil)
        registry.setPeers([phone, duplicate])
        XCTAssertEqual(registry.rows(now: now).count, 1)
        XCTAssertTrue(registry.observeBluetooth(advertisement(), fingerprint: fingerprint, now: now))
        registry.setConnected([phone.address]); registry.resetObservations()
        XCTAssertFalse(registry.rows(now: now)[0].connected)
    }
}
