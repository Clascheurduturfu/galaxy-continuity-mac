import Foundation

// MARK: - Message helpers

extension CallingSIPMessage {
    var isRequest: Bool { !startLine.hasPrefix("SIP/2.0") }
    var method: String? { isRequest ? startLine.split(separator: " ").first.map(String.init) : cseqParts?.1 }
    var requestURI: String? { let p = startLine.split(separator: " "); return isRequest && p.count >= 3 ? String(p[1]) : nil }
    var reason: String { let p = startLine.split(separator: " ", maxSplits: 2); return !isRequest && p.count == 3 ? String(p[2]) : "" }
    var cseqParts: (Int, String)? {
        guard let value = header("cseq") else { return nil }
        let p = value.split(separator: " ").map(String.init)
        guard p.count == 2, let n = Int(p[0]) else { return nil }
        return (n, p[1].uppercased())
    }
    /// Comma separated list headers are flattened; other headers are returned as sent.
    func values(_ name: String, splitCommas: Bool = false) -> [String] {
        let raw = headers.filter { $0.0.caseInsensitiveCompare(name) == .orderedSame }.map(\.1)
        guard splitCommas else { return raw }
        return raw.flatMap { Self.splitList($0) }
    }
    static func splitList(_ value: String) -> [String] {
        var items: [String] = [], current = "", angle = false, quote = false
        for ch in value {
            if ch == "\"" { quote.toggle() } else if !quote, ch == "<" { angle = true } else if !quote, ch == ">" { angle = false }
            if ch == ",", !angle, !quote { items.append(current.trimmingCharacters(in: .whitespaces)); current = "" } else { current.append(ch) }
        }
        if !current.trimmingCharacters(in: .whitespaces).isEmpty { items.append(current.trimmingCharacters(in: .whitespaces)) }
        return items
    }
    var topVia: String? { values("via", splitCommas: true).first }
    var branch: String? { Self.parameter("branch", in: topVia ?? "") }
    var callID: String? { header("call-id") }
    var bodyText: String? { body.isEmpty ? nil : String(data: body, encoding: .utf8) }
    static func parameter(_ name: String, in header: String) -> String? {
        let tail = header.split(separator: ">", maxSplits: 1, omittingEmptySubsequences: false).last.map(String.init) ?? header
        for part in tail.split(separator: ";").dropFirst(tail.hasPrefix(";") ? 0 : 1) {
            let pair = part.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if pair[0].lowercased() == name.lowercased() { return pair.count == 2 ? pair[1].trimmingCharacters(in: CharacterSet(charactersIn: "\"")) : "" }
        }
        return nil
    }
    /// URI inside <...>, or the bare value before parameters.
    static func uri(of header: String) -> String? {
        if let open = header.firstIndex(of: "<"), let close = header[open...].firstIndex(of: ">") { return String(header[header.index(after: open)..<close]) }
        let bare = header.split(separator: ";").first.map(String.init)?.trimmingCharacters(in: .whitespaces)
        return bare?.isEmpty == false ? bare : nil
    }
    func tag(of name: String) -> String? { header(name).flatMap { Self.parameter("tag", in: $0) } }
}

enum CallingSIPBuild {
    static func token(_ count: Int = 10) -> String { String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(count)).lowercased() }
    static func newBranch() -> String { "z9hG4bK" + token(20) }
    static func stripTag(_ header: String) -> String {
        guard let range = header.range(of: ";tag=") else { return header }
        let after = header[range.upperBound...]
        let end = after.firstIndex(where: { $0 == ";" || $0 == ">" }) ?? after.endIndex
        return String(header[..<range.lowerBound]) + String(after[end...])
    }
    static func quoted(_ text: String) -> String {
        "\"" + text.filter { $0 != "\r" && $0 != "\n" }.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
    /// Builds a response that copies Via/From/To/Call-ID/CSeq from the request.
    static func response(to request: CallingSIPMessage, code: Int, reason: String, toTag: String? = nil, extra: [(String, String)] = [], body: String? = nil) throws -> Data {
        var headers: [(String, String)] = request.values("via").map { ("Via", $0) }
        headers.append(("From", request.header("from") ?? ""))
        var to = request.header("to") ?? ""
        if let toTag, !to.contains(";tag=") { to += ";tag=" + toTag }
        headers.append(("To", to))
        headers.append(("Call-ID", request.callID ?? ""))
        headers.append(("CSeq", request.header("cseq") ?? ""))
        headers += extra
        return try CallingSIPMessage.encode("SIP/2.0 \(code) \(reason)", headers: headers, body: Data((body ?? "").utf8))
    }
}

// MARK: - Trace (opt-in)

/// `CMC_CALL_TRACE=1` prints a one-line summary per SIP message to stderr: direction, method or status code,
/// CSeq method and header names. Never URIs, numbers, tokens, tags or SDP.
enum CallingTrace {
    static let enabled = ProcessInfo.processInfo.environment["CMC_CALL_TRACE"] == "1"
    static func log(_ direction: String, firstLine: String, headers: [String], cseqMethod: String? = nil) {
        if firstLine.isEmpty { return }
        let first = firstLine.split(separator: " ")
        let methods: Set<String> = ["REGISTER", "INVITE", "ACK", "BYE", "CANCEL", "OPTIONS", "PRACK", "UPDATE", "INFO", "SUBSCRIBE", "NOTIFY", "MESSAGE", "REFER", "PUBLISH"]
        let method = first.first.map(String.init) ?? "?"
        let status = first.count > 1 ? Int(first[1]) : nil
        let summary = firstLine.hasPrefix("SIP/2.0") ? "status \(status.map(String.init) ?? "?")" : "method \(methods.contains(method) ? method : "OTHER")"
        let detail = cseqMethod.flatMap { methods.contains($0) ? " cseqMethod=" + $0 : nil } ?? ""
        if !(summary == "method REGISTER" || (summary == "status 200" && headers.contains("service-route"))) { CallingDiagnostics.shared.log("sip \(direction) \(summary)\(detail)") }
        guard enabled else { return }
        FileHandle.standardError.write(Data("[cmc-trace] \(direction) \(summary) headers=\(headers.joined(separator: ","))\n".utf8))
    }
}

// MARK: - Dispatcher

/// One receive loop and one ordered send queue per SIP connection.
/// - Responses are matched to client transactions by Via branch + CSeq method.
/// - Messages whose Call-ID belongs to a registered dialog go to that dialog (so duplicate 2xx,
///   BYE, CANCEL, INFO and so on are never dropped).
/// - OPTIONS is answered here; any other new request (INVITE, NOTIFY, MESSAGE) goes to `onRequest`.
/// Nothing is silently consumed while waiting for a reply, which is what made the old register probe unsafe long-term.
@MainActor final class CallingSIPDispatcher {
    private struct Pending { var provisional: ((CallingSIPMessage) -> Void)?; var continuation: CheckedContinuation<CallingSIPMessage, Error>; var timeout: Task<Void, Never>? }
    private var pending: [String: Pending] = [:]
    private var dialogs: [String: CallingDialog] = [:]
    private var outbox: AsyncStream<Data>.Continuation?
    private var pump: Task<Void, Never>?
    private(set) var closed = false
    var onRequest: ((CallingSIPMessage) -> Void)?
    var onClosed: ((Error?) -> Void)?
    private(set) var stats = (requests: 0, responses: 0, unmatched: 0)
    /// Method names of server requests seen outside dialogs (diagnostics only, never content).
    private(set) var seenRequestMethods: [String] = []

    init(transport: @escaping (Data) async throws -> Void) {
        let (stream, continuation) = AsyncStream<Data>.makeStream(bufferingPolicy: .unbounded)
        outbox = continuation
        pump = Task { [weak self] in
            for await data in stream {
                do { try await transport(data) } catch { self?.shutdown(error); return }
            }
        }
    }

    func send(_ data: Data) {
        guard !closed else { return }
        if let text = String(data: data.prefix(2048), encoding: .utf8) {
            let lines = text.components(separatedBy: "\r\n")
            CallingTrace.log("out", firstLine: lines.first ?? "", headers: lines.dropFirst().compactMap { $0.split(separator: ":").first.map(String.init) })
        }
        outbox?.yield(data)
    }

    func register(dialog: CallingDialog) { dialogs[dialog.callID] = dialog }
    func unregister(dialog: CallingDialog) { if dialogs[dialog.callID] === dialog { dialogs[dialog.callID] = nil } }
    var activeDialogCount: Int { dialogs.count }

    /// Non-INVITE client transaction with a final response or a timeout.
    func request(_ start: String, headers: [(String, String)], branch: String, method: String, body: Data = Data(), timeout: TimeInterval = 20,
                 provisional: ((CallingSIPMessage) -> Void)? = nil) async throws -> CallingSIPMessage {
        guard !closed else { throw ContinuityError.message("The calling connection is closed.") }
        let data = try CallingSIPMessage.encode(start, headers: headers, body: body)
        let key = branch + "|" + method
        return try await withCheckedThrowingContinuation { continuation in
            let waiter = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                if !Task.isCancelled { self?.finish(key, .failure(ContinuityError.message("No \(method) response from the calling server."))) }
            }
            pending[key] = Pending(provisional: provisional, continuation: continuation, timeout: waiter)
            send(data)
        }
    }

    private func finish(_ key: String, _ result: Result<CallingSIPMessage, Error>) {
        guard let entry = pending.removeValue(forKey: key) else { return }
        entry.timeout?.cancel()
        entry.continuation.resume(with: result)
    }

    func handle(_ message: CallingSIPMessage) {
        CallingTrace.log("in", firstLine: message.startLine, headers: message.headers.map { $0.0 }, cseqMethod: message.cseqParts?.1)
        if !message.isRequest {
            stats.responses += 1
            if let id = message.callID, let dialog = dialogs[id] { dialog.handle(message); return }
            guard let branch = message.branch, let method = message.cseqParts?.1, let code = message.status else { stats.unmatched += 1; return }
            let key = branch + "|" + method
            guard let entry = pending[key] else { stats.unmatched += 1; return }
            if code < 200 { entry.provisional?(message) } else { finish(key, .success(message)) }
            return
        }
        stats.requests += 1
        if let id = message.callID, let dialog = dialogs[id] { dialog.handle(message); return }
        guard let method = message.method else { return }
        if seenRequestMethods.count < 64 { seenRequestMethods.append(method) }
        switch method {
        case "OPTIONS":
            reply(message, 200, "OK", extra: [("Allow", "INVITE, ACK, CANCEL, BYE, OPTIONS, UPDATE, INFO, NOTIFY, PRACK"), ("Accept", "application/sdp")])
        case "ACK": break
        case "CANCEL", "BYE":
            reply(message, 481, "Call/Transaction Does Not Exist")
        default:
            if let onRequest { onRequest(message) } else if method != "INVITE" { reply(message, 200, "OK") } else { reply(message, 486, "Busy Here", toTag: CallingSIPBuild.token(8)) }
        }
    }

    func reply(_ request: CallingSIPMessage, _ code: Int, _ reason: String, toTag: String? = nil, extra: [(String, String)] = []) {
        if let data = try? CallingSIPBuild.response(to: request, code: code, reason: reason, toTag: toTag, extra: extra) { send(data) }
    }

    func shutdown(_ error: Error? = nil) {
        guard !closed else { return }
        closed = true
        outbox?.finish(); outbox = nil; pump?.cancel()
        for key in Array(pending.keys) { finish(key, .failure(error ?? ContinuityError.message("The calling connection closed."))) }
        let active = dialogs.values; dialogs = [:]
        for dialog in active { dialog.transportLost() }
        onClosed?(error)
    }
}
