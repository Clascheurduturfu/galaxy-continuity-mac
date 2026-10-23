import XCTest
import CryptoKit
@testable import ContinuityCore

final class FeatureSessionTests: XCTestCase {
    func testInboundHandshakeMatchesExistingClientAndRejectsWrongPeer() throws {
        let clientProfile = try WireTests().profile()
        let data: [String: Any] = ["format": "galaxy-continuity-profile-v1", "accountKey": clientProfile.accountKey.base64EncodedString(), "localBluetoothAddress": clientProfile.peers[0].address, "peers": [["address": clientProfile.localBluetoothAddress, "name": "Synthetic Mac"]], "revision": 7, "expiresAt": Int64(Date().timeIntervalSince1970 * 1000) + 3600000, "borrowedIdentity": false]
        let serverProfile = try JSONDecoder().decode(ContinuityProfile.self, from: JSONSerialization.data(withJSONObject: data))
        let client = try MCFHandshake(profile: clientProfile), server = try MCFResponder(profile: serverProfile)
        let initial = try client.initiate(channel: "clipboard_test"), reply = try server.reply(to: initial)
        XCTAssertEqual(server.requestedChannel, "clipboard_test")
        XCTAssertThrowsError(try MCFResponder(profile: serverProfile).reply(to: client.initiate(channel: "../escape")))
        XCTAssertNil(server.sessionKey)
        let finish = try client.finish(reply); try server.finish(finish)
        XCTAssertEqual(server.sessionKey, client.sessionKey)
        var bad = finish; bad.payload[bad.payload.startIndex] ^= 1
        XCTAssertThrowsError(try server.finish(bad))
        XCTAssertThrowsError(try MCFResponder(profile: clientProfile).reply(to: initial))
    }
    func testApplicationKeysWrapAndStayDistinct() throws {
        var source = Data(repeating: 0, count: 32); source[0] = 255
        var input = source; input[0] = 9
        XCTAssertEqual(try FeatureProtocol.applicationKey(sessionKey: source, appID: 10), Data(SHA256.hash(data: input)))
        XCTAssertNotEqual(try FeatureProtocol.applicationKey(sessionKey: source, appID: 1), try FeatureProtocol.applicationKey(sessionKey: source, appID: 10))
        XCTAssertThrowsError(try FeatureProtocol.applicationKey(sessionKey: Data(), appID: 10))
    }
    func testRequestKeepsPhoneConsentAndResponseRejectsBadEndpoint() throws {
        let payload = try FeatureProtocol.connectionRequest(appID: 10, address: "AA:BB:CC:DD:EE:FF", port: 12345, networks: [])
        XCTAssertEqual(payload.prefix(4), Data([10, 12, 30, 21]))
        let json = try JSONSerialization.jsonObject(with: Data(payload.dropFirst(4))) as! [String: Any]
        XCTAssertEqual(json["SKCF"] as? Bool, false)
        let good = Data([10, 12, 1]) + Data(#"{"IP":"192.168.1.10","PT":12345}"#.utf8)
        let endpoint = try FeatureProtocol.endpoint(good, appID: 10)
        XCTAssertEqual(endpoint.0, "192.168.1.10"); XCTAssertEqual(endpoint.1, 12345)
        XCTAssertThrowsError(try FeatureProtocol.endpoint(Data([10, 12, 3]), appID: 10))
        XCTAssertThrowsError(try FeatureProtocol.endpoint(good, appID: 1))
        XCTAssertThrowsError(try FeatureProtocol.endpoint(Data([10, 12, 1]) + Data(#"{"IP":"example.com","PT":0}"#.utf8), appID: 10))
    }
    func testSDKCBCUsesNegotiatedIVWithoutPrefix() throws {
        let key = Data(repeating: 3, count: 32), iv = Data(repeating: 4, count: 16)
        let plain = Data("sessionKeepAliveReq".utf8)
        let sealed = try MCFCrypto.cbcFixed(plain, key: key, iv: iv)
        XCTAssertEqual(sealed.count, 32)
        XCTAssertEqual(try MCFCrypto.cbc(iv + sealed, key: key, encrypt: false), plain)
    }
}
