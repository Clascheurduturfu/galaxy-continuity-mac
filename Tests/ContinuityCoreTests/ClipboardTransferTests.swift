import XCTest
@testable import ContinuityCore

final class ClipboardTransferTests: XCTestCase {
    func testCommandHandoverBoundsAndInternalSessionResponse() throws {
        let local: [[String: Any]] = [["IP": "192.168.1.9", "MASK": "255.255.255.0"]]
        func offer(_ host: String, _ channel: Any = NSNull()) throws -> Data {
            try JSONSerialization.data(withJSONObject: ["ARRAY": [["IP": host, "LPT": 9876]], "CN": channel])
        }
        XCTAssertNil(try CommandHandover.details(offer("192.168.1.50"), networks: local).2)
        XCTAssertEqual(try CommandHandover.details(offer("192.168.1.50", "abcd"), networks: local).2, "abcd")
        XCTAssertThrowsError(try CommandHandover.details(offer("8.8.8.8"), networks: local))
        XCTAssertThrowsError(try CommandHandover.details(offer("192.168.1.50", "../bad"), networks: local))
        let coreReply = Data([102, 12, 1]) + Data(#"{"IP":"","PT":0}"#.utf8)
        XCTAssertNoThrow(try FeatureProtocol.validateResponse(coreReply, appID: 102))
        XCTAssertThrowsError(try FeatureProtocol.endpoint(coreReply, appID: 102))
        XCTAssertThrowsError(try FeatureProtocol.validateResponse(Data([102, 12, 6]), appID: 102))
    }
    @MainActor private final class NoWire: MCFConnection {
        var sends = 0
        func connect() async throws {}
        func cancel() {}
        func send(_ packet: MCFPacket) async throws { sends += 1; throw ContinuityError.message("Unexpected fallback to Bluetooth") }
        func receive() async throws -> MCFPacket { throw CancellationError() }
    }
    @MainActor func testWifiRequestsReplyOnTheirOriginalCommandSocket() async throws {
        let wire = NoWire(), session = ClipboardSession(connection: wire, profile: try WireTests().profile())
        var replies: [(UInt64, MCFCommand)] = []
        try await session.handleIncoming(handler: 100, command: MCFCommand(id: 9, type: 1), context: Data()) { replies.append(($0, $1)) }
        try await session.handleIncoming(handler: 2, command: MCFCommand(id: 4, type: 1, payload: Data([7])), context: Data()) { replies.append(($0, $1)) }
        XCTAssertEqual(wire.sends, 0)
        XCTAssertEqual(replies.count, 2)
        XCTAssertEqual(replies[0].0, 100); XCTAssertEqual(replies[0].1.id, 9); XCTAssertEqual(replies[0].1.type, 2)
        XCTAssertEqual(replies[1].0, 2); XCTAssertEqual(replies[1].1.payload, Data([7, 9]))
    }
    @MainActor func testGetClipForUnknownClipReportsInvalidClip() async throws {
        let session = ClipboardSession(connection: NoWire(), profile: try WireTests().profile())
        var replies: [(UInt64, MCFCommand)] = []
        try await session.handleIncoming(handler: 2, command: MCFCommand(id: 1, type: 1, payload: Data([9])), context: Data()) { replies.append(($0, $1)) }
        XCTAssertEqual(replies.count, 1)
        XCTAssertEqual(replies[0].0, 2); XCTAssertEqual(replies[0].1.id, 1); XCTAssertEqual(replies[0].1.type, 2)
        XCTAssertEqual(replies[0].1.payload.prefix(2), Data([9, 4]))
    }
    func testKeyboardClipArchiveMatchesPhoneLayout() throws {
        // Same file name as the captured phone object: only the timestamp differs.
        let object = KeyboardClipArchive.clipObject(fileName: "continuity-test.png", date: Date(timeIntervalSince1970: 1_792_680_387.407))
        XCTAssertEqual(object.count, 665)
        XCTAssertEqual(object.prefix(4), Data([0xac, 0xed, 0x00, 0x05]))
        XCTAssertEqual(object[0x20a..<0x212], Data([0, 0, 1, 0xa1, 0x64, 0x13, 0xe3, 0x4f]))
        XCTAssertTrue(String(decoding: object.suffix(90), as: UTF8.self).contains("remote_send/continuity-test.png"))
        let archive = KeyboardClipArchive.make(image: Data([1, 2, 3]), fileName: "image.png")
        XCTAssertEqual(archive.prefix(4), Data([0x50, 0x4b, 0x03, 0x04]))
        XCTAssertNotNil(archive.range(of: Data("image.png".utf8)))
        XCTAssertNotNil(archive.range(of: Data("clip".utf8)))
        XCTAssertEqual(archive.suffix(22).prefix(4), Data([0x50, 0x4b, 0x05, 0x06]))
    }
    func testDataSocketEnvelopesAndBounds() throws {
        let key = Data(0..<32), bytes = Data((0..<100000).map { UInt8(truncatingIfNeeded: $0) })
        let frame = try ClipboardDataWire.command(MCFCommand(id: 5, type: 2, payload: Data([16]) + ClipboardDataWire.size(bytes.count)), key: key)
            + ClipboardDataWire.chunk(bytes, key: key)
        let result = try ClipboardDataWire.decode(frame, key: key)
        XCTAssertEqual(result.count, 2)
        if case .command(let command) = result[0] { XCTAssertEqual(command.id, 5); XCTAssertEqual(try ClipboardDataWire.size(Data(command.payload.dropFirst())), bytes.count) }
        else { XCTFail("Missing file header") }
        if case .chunk(let decoded) = result[1] { XCTAssertEqual(decoded, bytes) } else { XCTFail("Missing image bytes") }
        XCTAssertThrowsError(try ClipboardDataWire.size(Data(repeating: 255, count: 8)))
        XCTAssertThrowsError(try ClipboardDataWire.size(Data([1])))
        XCTAssertThrowsError(try ClipboardDataWire.chunk(Data(count: 524289), key: key))
        XCTAssertThrowsError(try ClipboardDataWire.decode(ProtoWire.bytes(2, Data([10, 5, 1])), key: key))
    }
    func testOnlyReachableLANEndpointsAreAccepted() throws {
        let local: [[String: Any]] = [["IP": "192.168.1.9", "MASK": "255.255.255.0"]]
        func offer(_ host: String, _ port: Int = 9876) -> [String: Any] { ["ARRAY": [["IP": host, "LPT": port]]] }
        XCTAssertEqual(try ClipboardTransfer.endpoint(offer("192.168.1.50"), networks: local).0, "192.168.1.50")
        for host in ["127.0.0.1", "169.254.169.254", "8.8.8.8", "192.168.2.2", "192.168.1.9", "192.168.1.50.bad", "192.168.001.50", "192..168.1.50"] {
            XCTAssertThrowsError(try ClipboardTransfer.endpoint(offer(host), networks: local))
        }
        XCTAssertThrowsError(try ClipboardTransfer.endpoint(offer("192.168.1.50", 65536), networks: local))
        // Enterprise/campus networks can assign public addresses directly to local clients.
        let campus: [[String: Any]] = [["IP": "198.51.100.33", "MASK": "255.255.252.0"]]
        XCTAssertEqual(try ClipboardTransfer.endpoint(offer("198.51.100.10"), networks: campus).0, "198.51.100.10")
        XCTAssertThrowsError(try ClipboardTransfer.endpoint(offer("198.51.104.10"), networks: campus))
        XCTAssertThrowsError(try ClipboardTransfer.endpoint(offer("224.0.0.1"), networks: [["IP": "224.0.0.2", "MASK": "255.0.0.0"]]))
    }
    func testSubnetIsTheNetworkAddressSamsungCompares() {
        // The phone matches SUBNET against its own IP & mask, e.g. on its hotspot.
        XCTAssertEqual(FeatureProtocol.networkAddress("10.72.157.47", mask: "255.255.255.0"), "10.72.157.0")
        XCTAssertEqual(FeatureProtocol.networkAddress("192.168.219.202", mask: "255.255.252.0"), "192.168.216.0")
        XCTAssertNil(FeatureProtocol.networkAddress("10.72.157", mask: "255.255.255.0"))
    }
    func testImageMetadataAndImageValidation() throws {
        let json = Data(#"{"id":"42","type":"FILE","source":"phone","files":[{"originalUri":"content://clipboard/image","fileName":"photo.png","fileLength":1200,"needUriList":false}]}"#.utf8)
        let clip = try JSONDecoder().decode(ClipboardText.self, from: json)
        XCTAssertEqual(clip.text, ""); XCTAssertEqual(clip.files?.first?.fileLength, 1200)
        XCTAssertEqual(try JSONDecoder().decode(ClipboardText.self, from: clip.encoded()), clip)
        XCTAssertThrowsError(try ClipboardDataWire.validateImage(Data("not an image".utf8)))
        XCTAssertThrowsError(try ClipboardDataWire.validateImage(Data()))
        let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+a3ioAAAAASUVORK5CYII=")!
        XCTAssertNoThrow(try ClipboardDataWire.validateImage(png))
    }
    func testImageContextAndLargeMetadataRoundTrip() throws {
        let object: [String: Any] = ["format": "galaxy-continuity-profile-v1", "accountKey": Data(0..<32).base64EncodedString(), "localBluetoothAddress": "01:02:03:04:05:06", "peers": [["address": "11:12:13:14:15:16", "name": "Synthetic phone"]], "revision": 7, "expiresAt": Int64(Date().timeIntervalSince1970 * 1000) + 3600000, "borrowedIdentity": true]
        let profile = try JSONDecoder().decode(ContinuityProfile.self, from: JSONSerialization.data(withJSONObject: object))
        let context = try ClipboardContext.make(profile: profile, sequence: 23, contextSequence: 4, kind: 4)
        XCTAssertEqual(try ClipboardContext.event(context)?.kind, 4)
        XCTAssertEqual(try ClipboardContext.eventSequence(context), 23)
        let text = (0..<30000).map { "line \($0) café 日本語\n" }.joined()
        let compressed = try ClipboardCompression.gzip(Data(text.utf8))
        XCTAssertGreaterThan(compressed.count, 20480)
        XCTAssertEqual(try ClipboardCompression.gzip(compressed, decompress: true), Data(text.utf8))
    }
}
