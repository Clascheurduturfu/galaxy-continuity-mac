import XCTest
@testable import ContinuityCore

final class ClipboardPoolTests: XCTestCase {
    @MainActor private final class Wire: MCFConnection {
        var sends = 0, cancellations = 0
        func connect() async throws { throw CancellationError() }
        func cancel() { cancellations += 1 }
        func send(_ packet: MCFPacket) async throws { sends += 1 }
        func receive() async throws -> MCFPacket { throw CancellationError() }
    }
    @MainActor func testMasterOffBlocksClipboardButKeepsControlReplies() async throws {
        let wire = Wire(), session = ClipboardSession(connection: wire, profile: try WireTests().profile())
        let clip = ClipboardText(text: "new copy", source: "00:11:22:33:44:55")
        let metadata = try ClipboardCompression.gzip(clip.encoded())
        var received = 0, controlReplies = 0
        session.received = { _ in received += 1 }
        session.clipboardEnabled = false
        try await session.handleIncoming(handler: 2, command: MCFCommand(id: 7, type: 3, payload: metadata), context: Data())
        try await session.publish("private copy")
        try await session.publishImage(Data())
        try await session.handleIncoming(handler: 100, command: MCFCommand(id: 9, type: 1), context: Data()) { _, command in
            XCTAssertEqual(command.type, 2); controlReplies += 1
        }
        XCTAssertEqual(received, 0); XCTAssertEqual(wire.sends, 0); XCTAssertEqual(controlReplies, 1)
        session.clipboardEnabled = true
        try await session.handleIncoming(handler: 2, command: MCFCommand(id: 7, type: 3, payload: metadata), context: Data())
        XCTAssertEqual(received, 1)
    }
    @MainActor func testImagesStillTransferAfterMasterSwitchOffThenOn() async throws {
        let session = ClipboardSession(connection: Wire(), profile: try WireTests().profile())
        try await session.start(key: Data(repeating: 0x42, count: 32), peer: "Test phone", address: "10:11:22:33:44:55")
        session.clipboardEnabled = false; session.clipboardEnabled = true
        let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+a3ioAAAAASUVORK5CYII=")!
        try await session.publishImage(png)
        // Probe the bounded sequence space: only the actual published clip can be returned.
        var delivered = 0
        for sequence in UInt8(1)...UInt8(254) {
            try await session.handleIncoming(handler: 2, command: MCFCommand(id: 1, type: 1, payload: Data([sequence])), context: Data()) { _, response in
                if response.payload.dropFirst().first == 1 { delivered += 1 }
            }
        }
        XCTAssertEqual(delivered, 1)
        session.stop()
    }
    @MainActor func testNearbyPoolDeduplicatesAndExcludesPrimaryAndNonadvertisedPeers() throws {
        let profile = try WireTests().profile()
        let addresses = ["10:11:22:33:44:55", "20:11:22:33:44:55", "30:11:22:33:44:55", "40:11:22:33:44:55"]
        var target = profile
        target.peers = addresses.enumerated().map { .init(address: $0.element, name: "Test \($0.offset)", deviceType: $0.offset == 3 ? "pc" : "tablet") }
        func peer(_ index: Int, advertised: Bool = true) -> NearbyPeer {
            NearbyPeer(id: addresses[index], address: addresses[index], name: "Test", deviceType: index == 3 ? "pc" : "tablet", bluetoothNearby: advertised, bluetoothConnectable: advertised, network: nil, connected: false)
        }
        var opened: [String] = [], wires: [Wire] = []
        let pool = NearbyClipboardPool { value in
            opened.append(value.preferredPeerAddress!); let wire = Wire(); wires.append(wire)
            return ClipboardSession(connection: wire, profile: value)
        }
        let peers = [peer(0), peer(1), peer(1), peer(2, advertised: false), peer(3)]
        pool.update(profile: target, peers: peers, excluding: ["101122334455"], enabled: true)
        pool.update(profile: target, peers: peers, excluding: [addresses[0]], enabled: true)
        XCTAssertEqual(opened, [addresses[1]])
        pool.update(profile: target, peers: peers, excluding: [addresses[0]], enabled: true, sharing: false)
        XCTAssertEqual(opened.count, 1)
        XCTAssertTrue(wires.allSatisfy { $0.cancellations == 0 }, "Turning clipboard off must preserve feature control links")
        pool.update(profile: target, peers: peers, excluding: [], enabled: false)
        XCTAssertTrue(pool.sessions.isEmpty); XCTAssertTrue(wires.allSatisfy { $0.cancellations > 0 })
        pool.stop()
    }

    @MainActor func testHotspotStatusWaiterReceivesImmediateReplyBeforeSendReturns() async throws {
        let wire = ImmediateHotspotWire()
        let session = ClipboardSession(connection: wire, profile: try WireTests().profile()); wire.session = session
        try await session.start(key: wire.key, peer: "Test phone", address: "10:11:22:33:44:55")
        let info = try await session.requestHotspotInformation(timeout: 0.1)
        XCTAssertEqual(info.batteryPercent, 73)
        XCTAssertEqual(wire.requestTypes, [1], "Status must not activate the hotspot")
        session.stop()
    }
    @MainActor private final class ImmediateHotspotWire: MCFConnection {
        let key = Data(repeating: 0x42, count: 32)
        weak var session: ClipboardSession?
        var requestTypes: [Int] = []
        func connect() async throws {}
        func cancel() {}
        func receive() async throws -> MCFPacket { throw CancellationError() }
        func send(_ packet: MCFPacket) async throws {
            guard packet.handler == 6 else { return }
            let command = try MCFCommand(data: MCFCrypto.cbc(packet.payload, key: key, encrypt: false))
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: command.payload.dropFirst(2)) as? [String: Int])
            requestTypes.append(try XCTUnwrap(json["messagetype"]))
            let bytes = try JSONSerialization.data(withJSONObject: ["messagetype": 2, "batteryLevel": 73])
            try await session?.handleIncoming(handler: 6, command: MCFCommand(id: 3, type: 3, payload: Data([4,0]) + bytes), context: Data())
        }
    }

    @MainActor func testHotspotStatusDeadlineCoversAStalledSend() async throws {
        let wire = StalledHotspotWire()
        let session = ClipboardSession(connection: wire, profile: try WireTests().profile())
        try await session.start(key: Data(repeating: 0x42, count: 32), peer: "Test phone", address: "10:11:22:33:44:55")
        let finished = expectation(description: "Status deadline returns while send is stalled")
        let request = Task {
            do { _ = try await session.requestHotspotInformation(timeout: 0.05); XCTFail("Expected a bounded timeout") }
            catch { finished.fulfill() }
        }
        await fulfillment(of: [finished], timeout: 3)
        request.cancel(); session.stop()
        await request.value
    }
    @MainActor private final class StalledHotspotWire: MCFConnection {
        func connect() async throws {}
        func cancel() {}
        func receive() async throws -> MCFPacket { throw CancellationError() }
        func send(_ packet: MCFPacket) async throws {
            if packet.handler == 6 { try await Task.sleep(nanoseconds: 60_000_000_000) }
        }
    }
}
