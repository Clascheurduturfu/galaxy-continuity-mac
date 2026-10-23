import Foundation
import Network

struct CallingSIPMessage {
    let startLine: String
    let headers: [(String, String)]
    let body: Data
    func header(_ name: String) -> String? { headers.first { $0.0.caseInsensitiveCompare(name) == .orderedSame }?.1 }
    var status: Int? { let parts = startLine.split(separator: " "); return parts.first == "SIP/2.0" && parts.count > 1 ? Int(parts[1]) : nil }
    static func encode(_ start: String, headers: [(String, String)], body: Data = Data()) throws -> Data {
        // Validate bytes: Swift treats CRLF as a single grapheme, so searching
        // for Character("\r") alone would miss an injected CRLF pair.
        guard start.utf8.allSatisfy({ $0 >= 32 && $0 != 127 }), body.count <= 262144,
              headers.allSatisfy({ !$0.0.isEmpty && $0.0.utf8.allSatisfy { (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95 } && $0.1.utf8.allSatisfy { $0 >= 32 && $0 != 127 } }) else {
            throw ContinuityError.message("Invalid SIP message fields.")
        }
        let lines = [start] + headers.filter { !["content-length", "l"].contains($0.0.lowercased()) }.map { $0.0 + ": " + $0.1 } + ["Content-Length: \(body.count)", "", ""]
        return Data(lines.joined(separator: "\r\n").utf8) + body
    }
}

struct CallingSIPStream {
    /// RFC 3261 compact header names, normalized so every lookup works for either spelling.
    static let compactForms = ["i": "call-id", "v": "via", "f": "from", "t": "to", "m": "contact", "c": "content-type", "l": "content-length",
                               "k": "supported", "e": "content-encoding", "o": "event", "u": "allow-events", "r": "refer-to", "b": "referred-by", "x": "session-expires", "s": "subject"]
    private var buffer = Data()
    mutating func append(_ data: Data) throws {
        guard buffer.count + data.count <= 524288 else { throw ContinuityError.message("Calling signaling exceeded its size limit.") }
        buffer += data
    }
    mutating func next() throws -> CallingSIPMessage? {
        // RFC 5626 keepalive CRLFs can precede SIP messages on the TLS stream.
        while buffer.starts(with: [13, 10]) { buffer = Data(buffer.dropFirst(2)) }
        guard let end = buffer.range(of: Data([13,10,13,10])) else {
            guard buffer.count <= 65536 else { throw ContinuityError.message("Calling headers exceeded their size limit.") }; return nil
        }
        guard end.lowerBound <= 65536, let text = String(data: buffer[..<end.lowerBound], encoding: .utf8) else {
            throw ContinuityError.message("Invalid calling signaling header.")
        }
        var lines = text.components(separatedBy: "\r\n")
        guard let start = lines.first, !start.isEmpty else { throw ContinuityError.message("Missing SIP start line.") }
        lines.removeFirst()
        var headers: [(String, String)] = []
        for line in lines {
            if line.hasPrefix(" ") || line.hasPrefix("\t") {
                guard let last = headers.popLast() else { throw ContinuityError.message("Invalid folded SIP header.") }
                headers.append((last.0, last.1 + " " + line.trimmingCharacters(in: .whitespaces)))
            } else {
                guard let colon = line.firstIndex(of: ":") else { throw ContinuityError.message("Invalid SIP header.") }
                let rawName = String(line[..<colon]).trimmingCharacters(in: .whitespaces).lowercased()
                headers.append((Self.compactForms[rawName] ?? rawName, String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)))
            }
        }
        let lengths = headers.filter { ["content-length", "l"].contains($0.0) }
        guard lengths.count == 1, let length = Int(lengths[0].1), length >= 0, length <= 262144 else {
            throw ContinuityError.message("Missing or ambiguous SIP content length.")
        }
        let startBody = end.upperBound
        guard buffer.count >= startBody + length else { return nil }
        let body = Data(buffer[startBody..<(startBody + length)])
        buffer = Data(buffer.dropFirst(startBody + length))
        return CallingSIPMessage(startLine: start, headers: headers, body: body)
    }
}

@MainActor final class CallingSIPConnection {
    private let connection: NWConnection
    private var stream = CallingSIPStream()
    init(server: String) throws {
        guard let endpoint = URLComponents(string: "tls://" + server), let host = endpoint.host,
              let raw = endpoint.port, let port = UInt16(exactly: raw), port > 0,
              endpoint.user == nil, endpoint.password == nil, endpoint.path.isEmpty, endpoint.query == nil, endpoint.fragment == nil else {
            throw ContinuityError.message("Invalid SIP TLS endpoint.")
        }
        let tcp = NWProtocolTCP.Options(); tcp.noDelay = true
        connection = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!, using: NWParameters(tls: NWProtocolTLS.Options(), tcp: tcp))
    }
    func close() { connection.cancel() }
    func connect() async throws {
        try await withCheckedThrowingContinuation { (pending: CheckedContinuation<Void, Error>) in
            var finished = false
            connection.stateUpdateHandler = { state in Task { @MainActor in
                guard !finished else { return }
                switch state {
                case .ready: finished = true; pending.resume()
                case .failed(let error): finished = true; pending.resume(throwing: error)
                case .cancelled: finished = true; pending.resume(throwing: ContinuityError.message("Calling connection closed."))
                default: break
                }
            } }
            connection.start(queue: .main)
        }
    }
    func send(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (pending: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { pending.resume(throwing: error) } else { pending.resume() }
            })
        }
    }
    func receive() async throws -> CallingSIPMessage {
        while true {
            if let message = try stream.next() { return message }
            let data: Data = try await withCheckedThrowingContinuation { pending in
                connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, _, error in
                    if let error { pending.resume(throwing: error) }
                    else if let data, !data.isEmpty { pending.resume(returning: data) }
                    else { pending.resume(throwing: ContinuityError.message("The calling server closed the connection.")) }
                }
            }
            try stream.append(data)
        }
    }
    func register(context: CallingAccountContext, callID: String, fromTag: String, cseq: Int, contact: String, expires: Int) async throws -> Int {
        let uri = "sip:" + context.lineID + "@samsungims.com"
        let token = context.headers["Access-Token"] ?? ""
        let auth = "https://" + (context.headers["Auth-Server-Url"] ?? "")
        let bssid = try FeatureProtocol.localNetworks().first { $0["TYPE"] as? String == "wlan" }?["ID"] as? String ?? "00:00:00:00:00:00"
        let wlan = bssid.replacingOccurrences(of: ":", with: "")
        let params = ";reg-id=1;+sip.instance=\"urn:duid:\(context.deviceID)\";pc-client=1;i-wlan-node-id=\(wlan);cmc-version=2.0"
        let message = try CallingSIPMessage.encode("REGISTER sip:samsungims.com SIP/2.0", headers: [
            ("Via", "SIP/2.0/WS \(contact).invalid;branch=z9hG4bK\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"),
            ("Max-Forwards", "70"), ("To", "<\(uri)>"), ("From", "<\(uri)>;tag=\(fromTag)"),
            ("Call-ID", callID), ("CSeq", "\(cseq) REGISTER"), ("Contact", "<sip:\(contact)@\(contact).invalid;transport=ws>" + params),
            ("Expires", String(expires)), ("Supported", "path, gruu, outbound"), ("User-Agent", "browserCall"),
            ("Auth-Server-Url", auth), ("Access_Token", token),
            ("P-Access-Network-Info", "IEEE-802.11;i-wlan-node-id=" + wlan)])
        try await send(message)
        for _ in 0..<20 {
            let response = try await receive()
            guard response.header("call-id") == callID, response.header("cseq") == "\(cseq) REGISTER", let code = response.status else { continue }
            if code >= 200 { return code }
        }
        throw ContinuityError.message("No final calling registration response.")
    }
}
