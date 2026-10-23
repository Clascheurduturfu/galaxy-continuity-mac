import Foundation
import Security

/// SDP offer/answer for the Samsung CMC network leg: AMR-WB/16000 over RTP/SAVP with SDES keys.
/// Reconstructed from the retained Samsung Phone bundle (cmcLocalSdp template) and sanitized captures.
/// Only IPv4 audio is supported; anything else is rejected rather than guessed.
struct CallingSDPCodec: Equatable {
    var payloadType: Int
    var name: String
    var rate: Int
    var channels: Int
    var fmtp: String
    func parameter(_ key: String) -> String? {
        for item in fmtp.split(separator: ";") {
            let pair = item.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if pair.count == 2, pair[0].lowercased() == key { return pair[1] }
        }
        return nil
    }
    var modeSet: [Int] {
        guard let raw = parameter("mode-set") else { return Array(0...8) }
        let modes = raw.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }.filter { (0...8).contains($0) }
        return modes.isEmpty ? [] : modes
    }
    var octetAligned: Bool { parameter("octet-align") == "1" }
}

struct CallingSDPCrypto: Equatable {
    static let suites: [String: Int] = ["AES_CM_128_HMAC_SHA1_32": 4, "AES_CM_128_HMAC_SHA1_80": 10]
    var tag: Int
    var suite: String
    var key: Data   // 16-byte master key + 14-byte master salt
    var tagBytes: Int { Self.suites[suite] ?? 0 }
    var line: String { "a=crypto:\(tag) \(suite) inline:\(key.base64EncodedString())" }
    /// Rejects MKI and short lifetimes. A `2^N` lifetime with N >= 31 is harmless for a phone call.
    static func parse(_ value: String) throws -> CallingSDPCrypto? {
        let parts = value.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard parts.count >= 3, let tag = Int(parts[0]), tag > 0, tag < 1_000_000_000 else { throw ContinuityError.message("Invalid SDP crypto line.") }
        guard suites[parts[1]] != nil, parts[2].hasPrefix("inline:") else { return nil } // unsupported suite or key method: ignore this offer
        guard parts.count == 3 else { return nil } // session parameters (KDR, FEC_ORDER, ...) are not implemented
        let pieces = parts[2].dropFirst(7).split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        guard let encoded = pieces.first, let key = Data(base64Encoded: encoded), key.count == 30 else { throw ContinuityError.message("Unsupported SDP key material.") }
        for extra in pieces.dropFirst() {
            if extra.hasPrefix("2^"), let exponent = Int(extra.dropFirst(2)), exponent >= 31 { continue }
            throw ContinuityError.message("Unsupported SDP key lifetime or MKI.")
        }
        return CallingSDPCrypto(tag: tag, suite: parts[1], key: key)
    }
}

struct CallingSDPMedia: Equatable {
    var ip = ""
    var port = 0
    var proto = ""
    var payloads: [Int] = []
    var codecs: [CallingSDPCodec] = []
    var ptime = 20
    var maxptime = 240
    var direction = "sendrecv"
    var cryptos: [CallingSDPCrypto] = []
    var sessionID = "0"
    var sessionVersion = 0
    var rejected: Bool { port == 0 }
}

/// The result of a completed offer/answer exchange: everything the media session needs.
struct CallingMediaPlan: Equatable {
    var remoteIP: String
    var remotePort: Int
    var payloadType: Int
    var dtmfPayloadType: Int?
    var modeSet: [Int]
    var encoderMode: Int
    var octetAligned: Bool
    var suite: String
    var tagBytes: Int
    var outboundKey: Data
    var inboundKey: Data
    var direction: String
    var cryptoTag = 1
    var sendsAudio: Bool { direction == "sendrecv" || direction == "sendonly" }
    var receivesAudio: Bool { direction == "sendrecv" || direction == "recvonly" }
}

enum CallingSDP {
    static func isIPv4(_ text: String) -> Bool {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 4 && parts.allSatisfy { !$0.isEmpty && $0.count <= 3 && $0.allSatisfy(\.isNumber) && Int($0)! <= 255 }
    }

    static func parse(_ sdp: String) throws -> CallingSDPMedia {
        guard sdp.utf8.count <= 16384 else { throw ContinuityError.message("SDP is too large.") }
        var media = CallingSDPMedia(), sessionIP: String?, mediaIP: String?, sawOrigin = false, inAudio = false, haveAudio = false
        var maps: [Int: CallingSDPCodec] = [:], fmtps: [Int: String] = [:]
        for raw in sdp.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard line.count >= 2, line.dropFirst().first == "=" else { continue }
            let kind = line.first!, value = String(line.dropFirst(2))
            switch kind {
            case "o":
                let parts = value.split(separator: " ").map(String.init)
                if !sawOrigin, parts.count >= 3 { sawOrigin = true; media.sessionID = parts[1]; media.sessionVersion = Int(parts[2]) ?? 0 }
            case "c":
                let parts = value.split(separator: " ").map(String.init)
                guard parts.count >= 3 else { throw ContinuityError.message("Invalid SDP connection line.") }
                guard parts[0] == "IN", parts[1] == "IP4", isIPv4(parts[2].components(separatedBy: "/")[0]) else {
                    throw ContinuityError.message("Only IPv4 call media is supported.")
                }
                if inAudio { mediaIP = parts[2].components(separatedBy: "/")[0] } else if !haveAudio { sessionIP = parts[2].components(separatedBy: "/")[0] }
            case "m":
                let parts = value.split(separator: " ").map(String.init)
                if haveAudio { inAudio = false; continue }
                if parts.first == "audio" {
                    guard parts.count >= 4, let port = Int(parts[1]), (0...65535).contains(port) else { throw ContinuityError.message("Invalid SDP media line.") }
                    media.port = port; media.proto = parts[2]
                    media.payloads = parts[3...].compactMap { Int($0) }.filter { (0...127).contains($0) }
                    inAudio = true; haveAudio = true
                }
            case "a" where inAudio:
                if value.hasPrefix("rtpmap:") {
                    let parts = value.dropFirst(7).split(separator: " ", maxSplits: 1).map(String.init)
                    guard parts.count == 2, let pt = Int(parts[0]) else { continue }
                    let enc = parts[1].split(separator: "/").map(String.init)
                    guard enc.count >= 2, let rate = Int(enc[1]) else { continue }
                    maps[pt] = CallingSDPCodec(payloadType: pt, name: enc[0], rate: rate, channels: enc.count > 2 ? Int(enc[2]) ?? 1 : 1, fmtp: "")
                } else if value.hasPrefix("fmtp:") {
                    let parts = value.dropFirst(5).split(separator: " ", maxSplits: 1).map(String.init)
                    if parts.count == 2, let pt = Int(parts[0]) { fmtps[pt] = parts[1] }
                } else if value.hasPrefix("ptime:"), let v = Int(value.dropFirst(6)), (10...200).contains(v) { media.ptime = v }
                else if value.hasPrefix("maxptime:"), let v = Int(value.dropFirst(9)), (10...1000).contains(v) { media.maxptime = v }
                else if ["sendrecv", "sendonly", "recvonly", "inactive"].contains(value) { media.direction = value }
                else if value.hasPrefix("crypto:"), let crypto = try CallingSDPCrypto.parse(String(value.dropFirst(7))) { media.cryptos.append(crypto) }
            default: break
            }
        }
        guard haveAudio else { throw ContinuityError.message("SDP has no audio media.") }
        guard let ip = mediaIP ?? sessionIP else { throw ContinuityError.message("SDP has no media address.") }
        media.ip = ip
        for pt in media.payloads {
            if var codec = maps[pt] { codec.fmtp = fmtps[pt] ?? ""; media.codecs.append(codec) }
        }
        return media
    }

    static func randomKey() throws -> Data {
        var bytes = [UInt8](repeating: 0, count: 30)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw ContinuityError.message("Could not generate call keys.") }
        return Data(bytes)
    }

    /// Fresh independent keys per offered suite. Tag 1 is the stronger 80-bit tag.
    static func makeLocalCryptos() throws -> [CallingSDPCrypto] {
        [CallingSDPCrypto(tag: 1, suite: "AES_CM_128_HMAC_SHA1_80", key: try randomKey()),
         CallingSDPCrypto(tag: 2, suite: "AES_CM_128_HMAC_SHA1_32", key: try randomKey())]
    }

    private static func sessionID() -> String { String(UInt32.random(in: 1...UInt32.max)) }

    private static func body(ip: String, port: Int, id: String, version: Int, codecPT: Int, dtmfPT: Int?, fmtp: String?, cryptos: [CallingSDPCrypto], direction: String, offer: Bool) -> String {
        var lines = ["v=0", "o=- \(id) \(version) IN IP4 \(ip)", "s=SS VOIP", "c=IN IP4 \(ip)", "t=0 0"]
        lines.append("m=audio \(port) RTP/SAVP \(codecPT)" + (dtmfPT.map { " \($0)" } ?? ""))
        lines.append("a=rtpmap:\(codecPT) AMR-WB/16000/1")
        if let fmtp { lines.append("a=fmtp:\(codecPT) \(fmtp)") }
        if let dtmfPT { lines.append("a=rtpmap:\(dtmfPT) telephone-event/16000"); lines.append("a=fmtp:\(dtmfPT) 0-15") }
        lines += cryptos.map(\.line)
        lines += ["a=\(direction)", "a=ptime:20", "a=maxptime:240"]
        return lines.joined(separator: "\r\n") + "\r\n"
    }

    /// Outgoing offer. Mirrors Samsung's template, narrowed to AMR-WB (the only codec this client decodes).
    static func makeOffer(localIP: String, port: Int, cryptos: [CallingSDPCrypto], id: String = sessionID()) -> String {
        body(ip: localIP, port: port, id: id, version: 2, codecPT: 116, dtmfPT: 120, fmtp: nil, cryptos: cryptos, direction: "sendrecv", offer: true)
    }

    /// Evaluates the network's answer to our offer.
    static func plan(offered: [CallingSDPCrypto], answer sdp: String) throws -> CallingMediaPlan {
        let answer = try parse(sdp)
        guard !answer.rejected else { throw ContinuityError.message("The call network rejected audio.") }
        guard answer.proto == "RTP/SAVP" else { throw ContinuityError.message("The call network did not use encrypted audio.") }
        guard answer.cryptos.count >= 1, let remote = answer.cryptos.first(where: { c in offered.contains { $0.tag == c.tag && $0.suite == c.suite } }),
              let local = offered.first(where: { $0.tag == remote.tag }) else {
            throw ContinuityError.message("The call network chose no offered encryption suite.")
        }
        guard let codec = answer.codecs.first(where: { $0.name.uppercased() == "AMR-WB" && $0.rate == 16000 }) else {
            throw ContinuityError.message("The call network chose an unsupported audio codec.")
        }
        let dtmf = answer.codecs.first { $0.name.lowercased() == "telephone-event" && $0.rate == 16000 }?.payloadType
        let direction: String
        switch answer.direction { case "sendonly": direction = "recvonly"; case "recvonly": direction = "sendonly"; default: direction = answer.direction }
        var plan = try finish(media: answer, codec: codec, dtmf: dtmf, outbound: local.key, inbound: remote.key, suite: remote.suite, direction: direction)
        plan.cryptoTag = remote.tag
        return plan
    }

    /// Chooses codec, mode and crypto from an incoming offer and writes our answer.
    static func answer(offer sdp: String, localIP: String, port: Int, id: String = sessionID()) throws -> (sdp: String, plan: CallingMediaPlan) {
        let offer = try parse(sdp)
        guard !offer.rejected, offer.proto == "RTP/SAVP" else { throw ContinuityError.message("The incoming call offered unencrypted or no audio.") }
        guard let codec = offer.codecs.first(where: { $0.name.uppercased() == "AMR-WB" && $0.rate == 16000 }) else {
            throw ContinuityError.message("The incoming call offered no AMR-WB audio.")
        }
        guard let remote = offer.cryptos.first else { throw ContinuityError.message("The incoming call offered no supported encryption.") }
        let dtmf = offer.codecs.first { $0.name.lowercased() == "telephone-event" && $0.rate == 16000 }?.payloadType
        let direction: String
        switch offer.direction { case "sendonly": direction = "recvonly"; case "recvonly": direction = "sendonly"; case "inactive": direction = "inactive"; default: direction = "sendrecv" }
        let ours = CallingSDPCrypto(tag: remote.tag, suite: remote.suite, key: try randomKey())
        let modes = codec.modeSet
        let fmtp = (codec.parameter("mode-set") != nil ? "mode-set=" + modes.map(String.init).joined(separator: ",") + "; " : "")
            + (codec.octetAligned ? "octet-align=1; " : "") + "mode-change-capability=2; max-red=0"
        var plan = try finish(media: offer, codec: codec, dtmf: dtmf, outbound: ours.key, inbound: remote.key, suite: remote.suite, direction: direction)
        plan.cryptoTag = remote.tag
        let text = body(ip: localIP, port: port, id: id, version: 1, codecPT: codec.payloadType, dtmfPT: dtmf, fmtp: fmtp, cryptos: [ours], direction: direction, offer: false)
        return (text, plan)
    }

    /// UPDATE is a new offer/answer exchange, including in an early dialog. Keep the local
    /// send key already advertised and validate the new remote endpoint, codec and receive key.
    static func updateAnswer(offer sdp: String, plan: CallingMediaPlan, localIP: String, port: Int,
                             version: Int, id: String = "1") throws -> (sdp: String, plan: CallingMediaPlan) {
        let offer = try parse(sdp)
        guard !offer.rejected, offer.proto == "RTP/SAVP",
              let codec = offer.codecs.first(where: { $0.name.uppercased() == "AMR-WB" && $0.rate == 16000 && $0.channels == 1 }),
              let remote = offer.cryptos.first(where: { $0.suite == plan.suite }) else {
            throw ContinuityError.message("The network UPDATE offered unsupported call audio.")
        }
        let direction: String
        switch offer.direction { case "sendonly": direction = "recvonly"; case "recvonly": direction = "sendonly"; default: direction = offer.direction }
        let dtmf = offer.codecs.first { $0.name.lowercased() == "telephone-event" && $0.rate == 16000 }?.payloadType
        var updated = try finish(media: offer, codec: codec, dtmf: dtmf, outbound: plan.outboundKey,
                                 inbound: remote.key, suite: remote.suite, direction: direction)
        updated.cryptoTag = remote.tag
        let local = CallingSDPCrypto(tag: remote.tag, suite: remote.suite, key: plan.outboundKey)
        let fmtp = "mode-set=" + updated.modeSet.map(String.init).joined(separator: ",") + "; "
            + (codec.octetAligned ? "octet-align=1; " : "") + "mode-change-capability=2; max-red=0"
        let reply = body(ip: localIP, port: port, id: id, version: version, codecPT: codec.payloadType,
                         dtmfPT: dtmf, fmtp: fmtp, cryptos: [local], direction: direction, offer: false)
        return (reply, updated)
    }

    /// Answer to a re-INVITE (hold, resume, refresh): same codec, address and keys as the established call, direction mirrored.
    /// A changed codec, suite or key is rejected rather than silently renegotiated; a changed remote address is not followed.
    static func reinviteAnswer(offer sdp: String, plan: CallingMediaPlan, localIP: String, port: Int, version: Int, id: String = "1") throws -> (sdp: String, direction: String) {
        let offer = try parse(sdp)
        guard !offer.rejected, offer.proto == "RTP/SAVP", offer.codecs.contains(where: { $0.payloadType == plan.payloadType && $0.name.uppercased() == "AMR-WB" }) else {
            throw ContinuityError.message("The call network asked to change the audio codec.")
        }
        if !offer.cryptos.isEmpty,
           !offer.cryptos.contains(where: { $0.tag == plan.cryptoTag && $0.suite == plan.suite && $0.key == plan.inboundKey }) {
            throw ContinuityError.message("The call network asked to change the audio keys.")
        }
        let direction: String
        switch offer.direction { case "sendonly": direction = "recvonly"; case "recvonly": direction = "sendonly"; case "inactive": direction = "inactive"; default: direction = "sendrecv" }
        let ours = CallingSDPCrypto(tag: plan.cryptoTag, suite: plan.suite, key: plan.outboundKey)
        let fmtp = "mode-set=" + plan.modeSet.map(String.init).joined(separator: ",") + "; " + (plan.octetAligned ? "octet-align=1; " : "") + "mode-change-capability=2; max-red=0"
        return (body(ip: localIP, port: port, id: id, version: version, codecPT: plan.payloadType, dtmfPT: plan.dtmfPayloadType, fmtp: fmtp, cryptos: [ours], direction: direction, offer: false), direction)
    }

    private static func finish(media: CallingSDPMedia, codec: CallingSDPCodec, dtmf: Int?, outbound: Data, inbound: Data, suite: String, direction: String) throws -> CallingMediaPlan {
        let modes = codec.modeSet
        guard !modes.isEmpty else { throw ContinuityError.message("The call network allowed no AMR-WB mode.") }
        guard media.ptime == 20 else { throw ContinuityError.message("Only 20 ms audio packets are supported.") }
        guard isIPv4(media.ip), media.port > 0 else { throw ContinuityError.message("Invalid call media address.") }
        let mode = modes.contains(2) ? 2 : modes.min()!
        return CallingMediaPlan(remoteIP: media.ip, remotePort: media.port, payloadType: codec.payloadType, dtmfPayloadType: dtmf, modeSet: modes,
                                encoderMode: mode, octetAligned: codec.octetAligned, suite: suite, tagBytes: CallingSDPCrypto.suites[suite] ?? 0,
                                outboundKey: outbound, inboundKey: inbound, direction: direction)
    }
}
