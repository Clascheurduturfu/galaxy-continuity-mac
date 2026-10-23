import XCTest
import Security
@testable import ContinuityCore

final class EnrollmentTests: XCTestCase {
    func testCertificateRequiresOwnIdentityAndCurrentAccountKey() throws {
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let object: [String: Any] = ["userFingerprint": String(repeating: "01", count: 32), "revision": 9,
            "thisDevice": ["btAddress": "01:02:03:04:05:06"],
            "userAesKeys": [["aes256Key": Data(repeating: 7, count: 32).base64EncodedString(), "expireTime": now+60000]],
            "devices": [["btAddress": "01:02:03:04:05:06", "deviceName": "Synthetic Mac"], ["btAddress": "11:12:13:14:15:16", "deviceName": "Synthetic phone", "deviceType": "phone"]]]
        let value = try JSONDecoder().decode(ContinuityCertificateBundle.self, from: JSONSerialization.data(withJSONObject: object))
        let profile = try value.profile(expectedAddress: "01:02:03:04:05:06", now: now)
        XCTAssertFalse(profile.borrowedIdentity); XCTAssertEqual(profile.peers.count, 1)
        XCTAssertEqual(profile.accountFingerprint, Data(repeating: 1, count: 32))
        XCTAssertThrowsError(try value.profile(expectedAddress: "21:22:23:24:25:26", now: now))
        XCTAssertThrowsError(try value.profile(expectedAddress: "01:02:03:04:05:06", now: now+120000))
    }
    func testGeneratedCSRHasValidRSAProofOfPossession() throws {
        let result = try ContinuityCSR.make(deviceID: "synthetic-registration")
        // Independent DER reader retains complete signed elements. Verify with
        // Security.framework, rather than just comparing our encoder's output.
        func element(_ bytes: Data, at cursor: inout Int) throws -> (UInt8, Data, Data) {
            let start = cursor
            guard cursor+2 <= bytes.count else { throw ContinuityError.message("Truncated fixture.") }
            let tag = bytes[cursor]; cursor += 1; var size = Int(bytes[cursor]); cursor += 1
            if size & 128 != 0 {
                let count = size & 127; size = 0
                guard count > 0, count <= 4, cursor+count <= bytes.count else { throw ContinuityError.message("Invalid fixture length.") }
                for _ in 0..<count { size = size*256+Int(bytes[cursor]); cursor += 1 }
            }
            guard cursor+size <= bytes.count else { throw ContinuityError.message("Invalid fixture boundary.") }
            let body = bytes.subdata(in: cursor..<cursor+size); cursor += size
            return (tag, body, bytes.subdata(in: start..<cursor))
        }
        var offset = 0; let outer = try element(result.request, at: &offset)
        XCTAssertEqual(outer.0, 0x30); XCTAssertEqual(offset, result.request.count)
        offset = 0; let info = try element(outer.1, at: &offset); _ = try element(outer.1, at: &offset)
        let signature = try element(outer.1, at: &offset)
        XCTAssertEqual(signature.0, 3); XCTAssertEqual(signature.1.first, 0)
        var error: Unmanaged<CFError>?
        let key = try XCTUnwrap(SecKeyCreateWithData(result.privateKey as CFData, [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeyClass: kSecAttrKeyClassPrivate] as CFDictionary, &error))
        let publicKey = try XCTUnwrap(SecKeyCopyPublicKey(key))
        XCTAssertTrue(SecKeyVerifySignature(publicKey, .rsaSignatureMessagePKCS1v15SHA256, info.2 as CFData, Data(signature.1.dropFirst()) as CFData, &error))
        var corrupted = info.2; corrupted[corrupted.startIndex+5] ^= 1
        XCTAssertFalse(SecKeyVerifySignature(publicKey, .rsaSignatureMessagePKCS1v15SHA256, corrupted as CFData, Data(signature.1.dropFirst()) as CFData, &error))
        XCTAssertThrowsError(try ContinuityCSR.make(deviceID: ""))
    }
    func testMalformedBrowserCallbacksFailClosed() {
        XCTAssertThrowsError(try ContinuityAuthCrypto.callback("123", key: "synthetic"))
        XCTAssertThrowsError(try ContinuityAuthCrypto.callback("zz", key: "synthetic"))
        XCTAssertThrowsError(try ContinuityAuthCrypto.callback(String(repeating: "00", count: 20000), key: "synthetic"))
    }
}
