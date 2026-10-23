import XCTest
@testable import ContinuityCore

/// All fixtures are synthetic: documentation addresses (192.0.2.x / 198.51.100.x), fixed fake keys, no real numbers.
final class CallingSDPTests: XCTestCase {
    static func fixtureKey(_ base: Int) -> Data { var bytes = [UInt8](); for i in 0..<30 { bytes.append(UInt8(base + i)) }; return Data(bytes) }
    let keyA = CallingSDPTests.fixtureKey(0), keyB = CallingSDPTests.fixtureKey(100)

    func answerSDP(tag: Int = 1, suite: String = "AES_CM_128_HMAC_SHA1_80", codecs: String = "116 120", extra: String = "", ip: String = "198.51.100.7", port: Int = 40000, key: Data? = nil, crypto: String? = nil, direction: String = "sendrecv") -> String {
        "v=0\r\no=- 1 1 IN IP4 \(ip)\r\ns=SS VOIP\r\nc=IN IP4 \(ip)\r\nt=0 0\r\nm=audio \(port) RTP/SAVP \(codecs)\r\n"
        + "a=rtpmap:116 AMR-WB/16000/1\r\na=fmtp:116 mode-set=0,1,2; mode-change-capability=2; max-red=0\r\n"
        + "a=rtpmap:120 telephone-event/16000\r\na=fmtp:120 0-15\r\n" + extra
        + (crypto ?? "a=crypto:\(tag) \(suite) inline:\((key ?? keyB).base64EncodedString())\r\n") + "a=\(direction)\r\na=ptime:20\r\na=maxptime:240\r\n"
    }

    func testOfferParsesBackAndMatchesStockShape() throws {
        let cryptos = try CallingSDP.makeLocalCryptos()
        XCTAssertEqual(cryptos.count, 2); XCTAssertNotEqual(cryptos[0].key, cryptos[1].key)
        let offer = CallingSDP.makeOffer(localIP: "192.0.2.10", port: 50000, cryptos: cryptos, id: "42")
        XCTAssertTrue(offer.contains("m=audio 50000 RTP/SAVP 116 120\r\n"))
        XCTAssertTrue(offer.contains("a=rtpmap:116 AMR-WB/16000/1\r\n"))
        XCTAssertFalse(offer.contains("octet-align"))
        let parsed = try CallingSDP.parse(offer)
        XCTAssertEqual(parsed.ip, "192.0.2.10"); XCTAssertEqual(parsed.port, 50000)
        XCTAssertEqual(parsed.cryptos, cryptos)
        XCTAssertEqual(parsed.codecs.map(\.payloadType), [116, 120])
    }

    func testAnswerPlanUsesOfferedKeyForOutboundAndAnswerKeyForInbound() throws {
        let offered = [CallingSDPCrypto(tag: 1, suite: "AES_CM_128_HMAC_SHA1_80", key: keyA), CallingSDPCrypto(tag: 2, suite: "AES_CM_128_HMAC_SHA1_32", key: keyA)]
        let plan = try CallingSDP.plan(offered: offered, answer: answerSDP(tag: 2, suite: "AES_CM_128_HMAC_SHA1_32"))
        XCTAssertEqual(plan.remoteIP, "198.51.100.7"); XCTAssertEqual(plan.remotePort, 40000)
        XCTAssertEqual(plan.payloadType, 116); XCTAssertEqual(plan.dtmfPayloadType, 120)
        XCTAssertEqual(plan.modeSet, [0, 1, 2]); XCTAssertEqual(plan.encoderMode, 2)
        XCTAssertFalse(plan.octetAligned)           // octet-align omitted => bandwidth-efficient
        XCTAssertEqual(plan.tagBytes, 4); XCTAssertEqual(plan.outboundKey, keyA); XCTAssertEqual(plan.inboundKey, keyB)
        XCTAssertTrue(plan.sendsAudio && plan.receivesAudio)
        let eighty = try CallingSDP.plan(offered: offered, answer: answerSDP(tag: 1))
        XCTAssertEqual(eighty.tagBytes, 10)
    }

    func testModeSetIntersectionAndPayloadNumbersAreNegotiated() throws {
        let offered = [CallingSDPCrypto(tag: 1, suite: "AES_CM_128_HMAC_SHA1_80", key: keyA)]
        var sdp = answerSDP().replacingOccurrences(of: "116", with: "98").replacingOccurrences(of: "120", with: "101")
        sdp = sdp.replacingOccurrences(of: "mode-set=0,1,2", with: "mode-set=4,5")
        let plan = try CallingSDP.plan(offered: offered, answer: sdp)
        XCTAssertEqual(plan.payloadType, 98); XCTAssertEqual(plan.dtmfPayloadType, 101)
        XCTAssertEqual(plan.encoderMode, 4)   // mode 2 not allowed: lowest permitted
        let none = answerSDP().replacingOccurrences(of: "mode-set=0,1,2", with: "mode-set=9")
        XCTAssertThrowsError(try CallingSDP.plan(offered: offered, answer: none))
    }

    func testOutgoingRemoteDirectionIsMirroredForLocalMedia() throws {
        let offered = [CallingSDPCrypto(tag: 1, suite: "AES_CM_128_HMAC_SHA1_80", key: keyA)]
        let receive = try CallingSDP.plan(offered: offered, answer: answerSDP(direction: "sendonly"))
        XCTAssertTrue(receive.receivesAudio); XCTAssertFalse(receive.sendsAudio)
        let send = try CallingSDP.plan(offered: offered, answer: answerSDP(direction: "recvonly"))
        XCTAssertTrue(send.sendsAudio); XCTAssertFalse(send.receivesAudio)
    }

    func testRejectsUnsupportedCombinations() throws {
        let offered = [CallingSDPCrypto(tag: 1, suite: "AES_CM_128_HMAC_SHA1_80", key: keyA)]
        XCTAssertThrowsError(try CallingSDP.plan(offered: offered, answer: answerSDP(tag: 3)))                       // tag not offered
        XCTAssertThrowsError(try CallingSDP.plan(offered: offered, answer: answerSDP(suite: "AES_CM_128_HMAC_SHA1_32"))) // suite differs from tag
        XCTAssertThrowsError(try CallingSDP.plan(offered: offered, answer: answerSDP(suite: "AEAD_AES_256_GCM")))        // unsupported suite
        XCTAssertThrowsError(try CallingSDP.plan(offered: offered, answer: answerSDP(crypto: "a=crypto:1 AES_CM_128_HMAC_SHA1_80 inline:\(keyB.base64EncodedString())|1000|1:4\r\n"))) // MKI
        XCTAssertThrowsError(try CallingSDP.plan(offered: offered, answer: answerSDP(crypto: "a=crypto:1 AES_CM_128_HMAC_SHA1_80 inline:\(keyB.base64EncodedString())|2^20\r\n"))) // short lifetime
        XCTAssertNoThrow(try CallingSDP.plan(offered: offered, answer: answerSDP(crypto: "a=crypto:1 AES_CM_128_HMAC_SHA1_80 inline:\(keyB.base64EncodedString())|2^31\r\n")))
        XCTAssertThrowsError(try CallingSDP.plan(offered: offered, answer: answerSDP(crypto: "a=crypto:1 AES_CM_128_HMAC_SHA1_80 inline:AAAA\r\n")))   // short key
        XCTAssertThrowsError(try CallingSDP.plan(offered: offered, answer: answerSDP(port: 0)))                       // rejected media
        XCTAssertThrowsError(try CallingSDP.plan(offered: offered, answer: answerSDP().replacingOccurrences(of: "IN IP4", with: "IN IP6")))
        XCTAssertThrowsError(try CallingSDP.plan(offered: offered, answer: answerSDP().replacingOccurrences(of: "AMR-WB/16000", with: "AMR/8000")))
        XCTAssertThrowsError(try CallingSDP.plan(offered: offered, answer: answerSDP().replacingOccurrences(of: "RTP/SAVP", with: "RTP/AVP")))
        XCTAssertThrowsError(try CallingSDP.plan(offered: offered, answer: answerSDP().replacingOccurrences(of: "ptime:20", with: "ptime:40")))
        XCTAssertThrowsError(try CallingSDP.plan(offered: offered, answer: ""))
    }

    func testIncomingOfferSelectionAndAnswer() throws {
        let offer = "v=0\r\no=- 9 9 IN IP4 203.0.113.5\r\ns=-\r\nc=IN IP4 203.0.113.5\r\nt=0 0\r\nm=audio 30000 RTP/SAVP 116 118 96 120 110\r\n"
            + "a=rtpmap:116 AMR-WB/16000/1\r\na=fmtp:116 mode-set=0,1,2,3,4,5,6,7,8; mode-change-capability=2; max-red=0\r\n"
            + "a=rtpmap:118 AMR/8000/1\r\na=rtpmap:96 AMR/8000/1\r\na=rtpmap:120 telephone-event/16000\r\na=fmtp:120 0-15\r\na=rtpmap:110 telephone-event/8000\r\n"
            + "a=crypto:1 AES_CM_128_HMAC_SHA1_80 inline:\(keyA.base64EncodedString())\r\na=crypto:2 AES_CM_128_HMAC_SHA1_32 inline:\(keyB.base64EncodedString())\r\n"
            + "a=sendrecv\r\na=ptime:20\r\na=maxptime:240\r\n"
        let result = try CallingSDP.answer(offer: offer, localIP: "192.0.2.10", port: 51000, id: "7")
        XCTAssertEqual(result.plan.payloadType, 116); XCTAssertEqual(result.plan.dtmfPayloadType, 120)
        XCTAssertEqual(result.plan.encoderMode, 2); XCTAssertEqual(result.plan.remoteIP, "203.0.113.5")
        XCTAssertEqual(result.plan.inboundKey, keyA); XCTAssertNotEqual(result.plan.outboundKey, keyA)
        let parsed = try CallingSDP.parse(result.sdp)
        XCTAssertEqual(parsed.port, 51000); XCTAssertEqual(parsed.cryptos.count, 1)
        XCTAssertEqual(parsed.cryptos[0].tag, 1); XCTAssertEqual(parsed.cryptos[0].key, result.plan.outboundKey)
        XCTAssertEqual(parsed.codecs.map(\.payloadType), [116, 120])
        XCTAssertEqual(parsed.direction, "sendrecv")
        // hold offers flip direction; recvonly offers make us sendonly
        let held = try CallingSDP.answer(offer: offer.replacingOccurrences(of: "a=sendrecv", with: "a=sendonly"), localIP: "192.0.2.10", port: 51000)
        XCTAssertEqual(try CallingSDP.parse(held.sdp).direction, "recvonly"); XCTAssertFalse(held.plan.sendsAudio)
        // octet-align is echoed; mode-set is intersected
        let aligned = try CallingSDP.answer(offer: offer.replacingOccurrences(of: "mode-set=0,1,2,3,4,5,6,7,8;", with: "mode-set=1,3; octet-align=1;"), localIP: "192.0.2.10", port: 51000)
        XCTAssertTrue(aligned.plan.octetAligned); XCTAssertEqual(aligned.plan.modeSet, [1, 3]); XCTAssertEqual(aligned.plan.encoderMode, 1)
        XCTAssertTrue(aligned.sdp.contains("octet-align=1"))
        // AMR narrowband only is rejected rather than half-supported
        XCTAssertThrowsError(try CallingSDP.answer(offer: offer.replacingOccurrences(of: "AMR-WB/16000", with: "EVS/16000"), localIP: "192.0.2.10", port: 51000))
        XCTAssertThrowsError(try CallingSDP.answer(offer: offer.replacingOccurrences(of: "RTP/SAVP", with: "RTP/AVP"), localIP: "192.0.2.10", port: 51000))
    }

    func testReinviteHoldMirrorsDirectionAndRejectsChanges() throws {
        let offered = [CallingSDPCrypto(tag: 1, suite: "AES_CM_128_HMAC_SHA1_80", key: keyA)]
        let plan = try CallingSDP.plan(offered: offered, answer: answerSDP())
        let hold = answerSDP(direction: "sendonly")
        let reply = try CallingSDP.reinviteAnswer(offer: hold, plan: plan, localIP: "192.0.2.10", port: 50000, version: 3)
        XCTAssertEqual(reply.direction, "recvonly")
        let parsed = try CallingSDP.parse(reply.sdp)
        XCTAssertEqual(parsed.sessionVersion, 3); XCTAssertEqual(parsed.cryptos[0].key, keyA); XCTAssertEqual(parsed.cryptos[0].tag, 1)
        XCTAssertEqual(try CallingSDP.reinviteAnswer(offer: answerSDP(), plan: plan, localIP: "192.0.2.10", port: 50000, version: 4).direction, "sendrecv")
        XCTAssertThrowsError(try CallingSDP.reinviteAnswer(offer: answerSDP(key: keyA), plan: plan, localIP: "192.0.2.10", port: 50000, version: 5))   // key changed (offer carries keyA, plan inbound is keyB)
        XCTAssertThrowsError(try CallingSDP.reinviteAnswer(offer: answerSDP().replacingOccurrences(of: "AMR-WB", with: "EVS"), plan: plan, localIP: "192.0.2.10", port: 50000, version: 6))
    }

    func testSizeAndMalformedInputFailClosed() {
        XCTAssertThrowsError(try CallingSDP.parse(String(repeating: "a=x\r\n", count: 5000)))
        XCTAssertThrowsError(try CallingSDP.parse("v=0\r\nm=audio abc RTP/SAVP 116\r\nc=IN IP4 192.0.2.1\r\n"))
        XCTAssertThrowsError(try CallingSDP.parse("v=0\r\nc=IN IP4 999.0.0.1\r\nm=audio 4000 RTP/SAVP 116\r\n"))
    }
    func testUpdateNegotiatesMediaButRetainsOurAdvertisedSendKey() throws {
        let local = CallingSDPCrypto(tag: 1, suite: "AES_CM_128_HMAC_SHA1_80", key: keyA)
        let initial = try CallingSDP.plan(offered: [local], answer: answerSDP())
        let changed = answerSDP(ip: "198.51.100.9", port: 41000, key: keyA, direction: "sendonly")
            .replacingOccurrences(of: "mode-set=0,1,2;", with: "mode-set=1; octet-align=1;")
        let reply = try CallingSDP.updateAnswer(offer: changed, plan: initial, localIP: "192.0.2.10", port: 51000, version: 3, id: "42")
        let parsed = try CallingSDP.parse(reply.sdp)
        XCTAssertEqual(parsed.port, 51000); XCTAssertEqual(parsed.sessionVersion, 3); XCTAssertEqual(parsed.sessionID, "42")
        XCTAssertEqual(parsed.cryptos.first?.key, initial.outboundKey)
        XCTAssertEqual(reply.plan.outboundKey, initial.outboundKey)
        XCTAssertEqual(reply.plan.inboundKey, keyA); XCTAssertEqual(reply.plan.remotePort, 41000)
        XCTAssertEqual(reply.plan.remoteIP, "198.51.100.9"); XCTAssertEqual(reply.plan.direction, "recvonly")
        XCTAssertEqual(reply.plan.encoderMode, 1); XCTAssertTrue(reply.plan.octetAligned)
        XCTAssertThrowsError(try CallingSDP.updateAnswer(offer: changed.replacingOccurrences(of: "RTP/SAVP", with: "RTP/AVP"), plan: initial, localIP: "192.0.2.10", port: 51000, version: 4))
    }

}
