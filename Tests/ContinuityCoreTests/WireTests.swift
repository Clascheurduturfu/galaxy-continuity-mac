import XCTest
import CryptoKit
@testable import ContinuityCore

final class WireTests: XCTestCase {
    func profile() throws -> ContinuityProfile {
        let object: [String: Any] = ["format": "galaxy-continuity-profile-v1", "accountKey": Data(0..<32).base64EncodedString(), "localBluetoothAddress": "01:02:03:04:05:06", "peers": [["address": "11:12:13:14:15:16", "name": "Synthetic phone"]], "revision": 7, "expiresAt": Int64(Date().timeIntervalSince1970 * 1000) + 3600000, "borrowedIdentity": true]
        return try JSONDecoder().decode(ContinuityProfile.self, from: JSONSerialization.data(withJSONObject: object))
    }
    func testUnknownFieldsAndMalformedFrames() throws {
        let bytes = MCFPacket(handler: 2, payload: Data([1, 2])).encoded + ProtoWire.number(120, 9)
        XCTAssertEqual(try MCFPacket(data: bytes).payload, Data([1, 2]))
        XCTAssertThrowsError(try ProtoWire.fields(Data([0x1a, 0xff, 0xff, 0xff, 0xff, 0x7f])))
        XCTAssertThrowsError(try ProtoWire.fields(Data([0x1a, 5, 1])))
        var cursor = 0
        XCTAssertThrowsError(try ProtoWire.readVarint(Data(repeating: 0xff, count: 10), cursor: &cursor))
    }
    func testAuthenticatedHandshakeAndCBC() throws {
        let p = try profile(); let client = try MCFHandshake(profile: p)
        let initial = try client.initiate(); let zero = Data(repeating: 0, count: 12)
        let fields = try ProtoWire.fields(MCFCrypto.open(initial.payload, key: p.accountKey, nonce: zero))
        let clientPublic = ProtoWire.bytes(fields, 4); let server = P256.KeyAgreement.PrivateKey()
        let shared = try server.sharedSecretFromKeyAgreement(with: P256.KeyAgreement.PublicKey(derRepresentation: clientPublic))
        let body = ProtoWire.number(1, 2) + ProtoWire.bytes(3, try ContinuityProfile.addressBytes(p.peers[0].address)) + ProtoWire.bytes(4, server.publicKey.derRepresentation) + ProtoWire.bytes(5, Data(SHA256.hash(data: clientPublic).prefix(6)))
        let reply = MCFPacket(payload: try MCFCrypto.seal(body, key: p.accountKey, nonce: zero), authType: 1, iv: zero)
        let final = try client.finish(reply)
        XCTAssertEqual(client.sessionKey, shared.withUnsafeBytes { Data($0) })
        let last = try ProtoWire.fields(MCFCrypto.open(final.payload, key: p.accountKey, nonce: zero))
        XCTAssertEqual(ProtoWire.number(last, 1), 3)
        let message = Data("café 日本語 🚀\nclipboard".utf8)
        let encrypted = try MCFCrypto.cbc(message, key: client.sessionKey!, encrypt: true)
        XCTAssertEqual(try MCFCrypto.cbc(encrypted, key: client.sessionKey!, encrypt: false), message)
        var corrupted = reply; corrupted.payload[corrupted.payload.startIndex] ^= 1
        XCTAssertThrowsError(try client.finish(corrupted))
    }
    func testClipboardLoopAndUnicode() throws {
        let clip = ClipboardText(text: "Hello 日本語 🚀\nsecond line", source: "01:02:03:04:05:06", milliseconds: 42)
        XCTAssertEqual(try JSONDecoder().decode(ClipboardText.self, from: clip.encoded()), clip)
        var guardState = ClipboardLoopGuard()
        XCTAssertTrue(guardState.received(clip)); XCTAssertFalse(guardState.received(clip))
        XCTAssertFalse(guardState.shouldPublish(clip.text)); XCTAssertTrue(guardState.shouldPublish("A deliberate new copy"))
    }
    func testGzipContextAndHotspotRequest() throws {
        let text = Data(String(repeating: "café 日本語 🚀\n", count: 500).utf8)
        let compressed = try ClipboardCompression.gzip(text)
        XCTAssertEqual(compressed.prefix(2), Data([0x1f, 0x8b]))
        XCTAssertEqual(try ClipboardCompression.gzip(compressed, decompress: true), text)
        XCTAssertThrowsError(try ClipboardCompression.gzip(Data([0, 1, 2]), decompress: true))
        let context = try ClipboardContext.make(profile: profile(), sequence: 41, contextSequence: 2)
        XCTAssertEqual(try ClipboardContext.eventSequence(context), 41)
        var truncated = context; truncated.removeLast()
        XCTAssertThrowsError(try ClipboardContext.eventSequence(truncated))
        let request = try JSONSerialization.jsonObject(with: HotspotCredentials.request()) as! [String: Int]
        XCTAssertEqual(request["messagetype"], 3); XCTAssertEqual(request["membertype"], 1)
    }
    func testAdvertisementCandidateAndWrongAccount() throws {
        let fingerprint = Data(0..<32), now = Date(timeIntervalSince1970: 1_700_000_000)
        let table = Array(SHA256.hash(data: fingerprint)), rotation = Int(now.timeIntervalSince1970 * 1000) / 43_200_000
        let check = (0..<10).reduce(UInt8(0)) { $0 ^ table[(($1 - rotation) % 32 + 32) % 32] }
        var raw = [UInt8]([2, 24, check, 0, 0x61]) + [UInt8](repeating: 0, count: 8) + [0x21, 16, 11, 0x61, 0, 128, 10, 7, 5, 0, 0x34, 1, 4, 5]
        for i in 16..<raw.count { raw[i] ^= table[i % 32] }
        let advertisement = Data([0x75, 0] + raw)
        XCTAssertEqual(MCFAdvertisement.cocPSM(manufacturer: advertisement, fingerprint: fingerprint, now: now), 128)
        XCTAssertEqual(MCFAdvertisement.cocPSM(manufacturer: advertisement, fingerprint: fingerprint, targetAddress: "01:02:03:04:05:06", now: now), 128)
        XCTAssertNil(MCFAdvertisement.cocPSM(manufacturer: advertisement, fingerprint: fingerprint, targetAddress: "11:12:13:14:15:16", now: now))
        XCTAssertNil(MCFAdvertisement.cocPSM(manufacturer: advertisement, fingerprint: Data(repeating: 0xaa, count: 32), now: now))
        XCTAssertNil(MCFAdvertisement.cocPSM(manufacturer: Data(advertisement.prefix(18)), fingerprint: fingerprint, now: now))
    }
}
