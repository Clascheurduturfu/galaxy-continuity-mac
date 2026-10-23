import Foundation

struct CallingDialogContext {
    var scheme = "sip"
    var userID: String            // line id (the IMPU user part)
    var userHost = "samsungims.com"
    var viaHost: String           // same style as the REGISTER Via ("<token>.invalid")
    var contactURI: String        // without angle brackets
    var userAgent = "browserCall"
    var serviceRoute: [String] = []
    var ownURI: String { "\(scheme):\(userID)@\(userHost)" }
    /// Stock dial target: scheme:userID@userHost;gr=urn:duid:<primary-device-id>.
    /// The stock config field is called pdImei but holds the primary device's duid.
    func dialTarget(primaryDeviceID: String) -> String { "\(ownURI);gr=urn:duid:\(primaryDeviceID)" }
}

enum CallingEndReason: Equatable {
    case localHangup, remoteHangup, cancelledByCaller, remoteCancelled, declined
    case failed(Int, String)
    case timeout, transportLost
}

enum CallingDialogEvent {
    case provisional(code: Int, sdp: String?, earlyMedia: String?)
    case answered(sdp: String?)
    case reinvite(sdp: String?)
    case update(sdp: String?)
    case info(contentType: String?, body: String?)
    case ended(CallingEndReason)
}

/// Explicit SIP call dialog (UAC or UAS). The transport is reliable TLS, so no request retransmission timers
/// are needed; duplicate final responses and crossing requests are still handled.
@MainActor final class CallingDialog {
    enum State: Equatable { case idle, calling, early, incomingRinging, incomingAccepted, confirmed, ending, terminated }
    enum Role { case caller, callee }

    let role: Role
    let callID: String
    private(set) var state: State = .idle {
        didSet { if state != oldValue { CallingDiagnostics.shared.log("dialog \(role) \(oldValue) -> \(state)") } }
    }
    private(set) var remoteTag: String?
    private(set) var localTag = CallingSIPBuild.token(10)
    var onEvent: (CallingDialogEvent) -> Void = { _ in }
    var onFinished: () -> Void = {}
    private(set) var endReason: CallingEndReason?

    private let ctx: CallingDialogContext
    private let transmit: (Data) -> Void
    private var localSeq = 1
    private var routeSet: [String] = []
    private var remoteTarget = ""
    private var localHeader = ""      // From (caller) / To (callee), without tag
    private var remoteHeader = ""
    // UAC INVITE data
    private var inviteBranch = ""
    private var inviteURI = ""
    private var inviteRoutes: [String] = []
    private var cancelRequested = false, cancelSent = false, gotProvisional = false
    private var seenRSeq = Set<String>()
    private var discardedForks = Set<String>()
    private var lastAck: Data?
    // UAS data
    private var invite: CallingSIPMessage?
    private var lastFinal: Data?
    private var ackWatchdog: Task<Void, Never>?
    private var byeWatchdog: Task<Void, Never>?
    private(set) var remoteSDP: String?
    var displayName: String { invite.flatMap { Self.displayName(of: $0.header("from") ?? "") } ?? "" }

    init(role: Role, context: CallingDialogContext, callID: String = CallingSIPBuild.token(24) + "@calls", transmit: @escaping (Data) -> Void) {
        self.role = role; self.ctx = context; self.callID = callID; self.transmit = transmit
    }

    static func displayName(of header: String) -> String? {
        let trimmed = header.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("\"") , let end = trimmed.dropFirst().firstIndex(of: "\"") { return String(trimmed[trimmed.index(after: trimmed.startIndex)..<end]) }
        if let open = trimmed.firstIndex(of: "<") { let name = trimmed[..<open].trimmingCharacters(in: .whitespaces); return name.isEmpty ? nil : name }
        return nil
    }

    // MARK: Outgoing

    /// Sends the INVITE. `number` goes in the From display name exactly as the stock client does
    /// (spaces and dashes removed); `slot` adds `Cmc-Mno: ;call-slot=<slot>`.
    func startOutgoing(target: String, number: String, offer: String, slot: String? = nil, earlyMedia: Bool = true) throws {
        precondition(role == .caller && state == .idle)
        let digits = number.replacingOccurrences(of: "-", with: "").replacingOccurrences(of: " ", with: "")
        guard !digits.isEmpty, digits.count <= 64, digits.allSatisfy({ $0.isNumber || "+*#".contains($0) }) else {
            throw ContinuityError.message("Enter a valid phone number.")
        }
        if let slot { guard slot == "0" || slot == "1" else { throw ContinuityError.message("Invalid SIM slot.") } }
        inviteURI = target; inviteBranch = CallingSIPBuild.newBranch(); inviteRoutes = ctx.serviceRoute
        localHeader = "\(CallingSIPBuild.quoted(digits)) <\(ctx.ownURI)>"; remoteHeader = "<\(target)>"
        var headers: [(String, String)] = [
            ("Via", "SIP/2.0/WS \(ctx.viaHost);branch=\(inviteBranch)"), ("Max-Forwards", "70")]
        headers += inviteRoutes.map { ("Route", $0) }
        headers += [("To", remoteHeader), ("From", localHeader + ";tag=" + localTag), ("Call-ID", callID), ("CSeq", "1 INVITE"),
                    ("Contact", "<\(ctx.contactURI)>"), ("Allow", "INVITE, ACK, CANCEL, BYE, OPTIONS, UPDATE, INFO, NOTIFY, PRACK"),
                    ("Supported", "100rel"), ("User-Agent", ctx.userAgent)]
        if earlyMedia { headers.append(("P-Early-Media", "supported")) }
        if let slot { headers.append(("Cmc-Mno", ";call-slot=" + slot)) }
        headers.append(("Content-Type", "application/sdp"))
        state = .calling
        transmit(try CallingSIPMessage.encode("INVITE \(target) SIP/2.0", headers: headers, body: Data(offer.utf8)))
    }

    /// Caller hang-up before the call is answered. CANCEL must not be sent before any provisional response.
    func cancel() {
        guard role == .caller, state == .calling || state == .early else { return }
        cancelRequested = true
        if gotProvisional { sendCancel() }
    }

    private func sendCancel() {
        guard !cancelSent else { return }
        cancelSent = true
        var headers: [(String, String)] = [("Via", "SIP/2.0/WS \(ctx.viaHost);branch=\(inviteBranch)"), ("Max-Forwards", "70")]
        headers += inviteRoutes.map { ("Route", $0) }
        headers += [("To", remoteHeader), ("From", localHeader + ";tag=" + localTag), ("Call-ID", callID), ("CSeq", "1 CANCEL"), ("User-Agent", ctx.userAgent)]
        if let data = try? CallingSIPMessage.encode("CANCEL \(inviteURI) SIP/2.0", headers: headers) { transmit(data) }
    }

    // MARK: Incoming

    /// Accepts an incoming INVITE (already routed to this dialog) and records dialog state.
    func receiveInvite(_ message: CallingSIPMessage) {
        precondition(role == .callee && state == .idle)
        invite = message
        remoteSDP = message.bodyText
        remoteTag = message.tag(of: "from")
        remoteSeq = message.cseqParts?.0 ?? 0
        remoteTarget = message.header("contact").flatMap { CallingSIPMessage.uri(of: $0) } ?? ""
        routeSet = message.values("record-route", splitCommas: true)
        localHeader = CallingSIPBuild.stripTag(message.header("to") ?? "")
        remoteHeader = CallingSIPBuild.stripTag(message.header("from") ?? "")
        state = .incomingRinging
    }
    private var remoteSeq = 0

    private func calleeResponse(_ code: Int, _ reason: String, body: String? = nil, contact: Bool = true) {
        guard let invite else { return }
        var extra: [(String, String)] = invite.values("record-route").map { ("Record-Route", $0) }
        if contact { extra.append(("Contact", "<\(ctx.contactURI)>")) }
        extra.append(("User-Agent", ctx.userAgent))
        if body != nil { extra.append(("Content-Type", "application/sdp")) }
        guard let data = try? CallingSIPBuild.response(to: invite, code: code, reason: reason, toTag: localTag, extra: extra, body: body) else { return }
        if code >= 200 { lastFinal = data }
        transmit(data)
    }

    func sendRinging() { if state == .incomingRinging { calleeResponse(180, "Ringing") } }

    func accept(answerSDP: String) {
        guard state == .incomingRinging else { return }
        calleeResponse(200, "OK", body: answerSDP)
        state = .incomingAccepted
        // No ACK within 32 s (64*T1): the caller is gone.
        ackWatchdog = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 32_000_000_000)
            if !Task.isCancelled { self?.ackTimedOut() }
        }
    }
    private func ackTimedOut() { guard state == .incomingAccepted else { return }; sendBye(); finish(.timeout) }

    func decline(code: Int = 603, reason: String = "Decline") {
        guard state == .incomingRinging else { return }
        calleeResponse(code, reason, contact: false)
        finish(.declined)
    }

    // MARK: Common

    /// Ends whatever state the call is in.
    func hangUp() {
        switch state {
        case .calling, .early: cancel()
        case .incomingRinging: decline()
        case .confirmed, .incomingAccepted: sendBye(); state = .ending; endReason = .localHangup
            byeWatchdog = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 8_000_000_000)
                if !Task.isCancelled { self?.finish(.localHangup) }
            }
        default: break
        }
    }

    func sendInfoDTMF(_ digit: Character) {
        guard state == .confirmed, "0123456789*#ABCD".contains(digit) else { return }
        sendInDialog("INFO", extra: [("Content-Type", "application/dtmf-relay")], body: "Signal=\(digit)\r\nDuration=160\r\n")
    }

    private func sendBye() { sendInDialog("BYE") }

    private func sendInDialog(_ method: String, extra: [(String, String)] = [], body: String? = nil, cseq: Int? = nil) {
        let number: Int
        if let cseq { number = cseq } else { localSeq += 1; number = localSeq }
        var headers: [(String, String)] = [("Via", "SIP/2.0/WS \(ctx.viaHost);branch=\(CallingSIPBuild.newBranch())"), ("Max-Forwards", "70")]
        headers += routeSet.map { ("Route", $0) }
        headers += [("To", remoteHeader + (remoteTag.map { ";tag=" + $0 } ?? "")), ("From", localHeader + ";tag=" + localTag),
                    ("Call-ID", callID), ("CSeq", "\(number) \(method)"), ("User-Agent", ctx.userAgent)]
        headers += extra
        let target = remoteTarget.isEmpty ? inviteURI : remoteTarget
        if let data = try? CallingSIPMessage.encode("\(method) \(target) SIP/2.0", headers: headers, body: Data((body ?? "").utf8)) { transmit(data) }
    }

    func transportLost() { finish(.transportLost) }

    private func finish(_ reason: CallingEndReason) {
        guard state != .terminated else { return }
        state = .terminated
        endReason = reason
        ackWatchdog?.cancel(); byeWatchdog?.cancel()
        CallingDiagnostics.shared.log("dialog ended \(reason.diagnosticLabel)")
        onEvent(.ended(reason))
        onFinished()
    }

    // MARK: Inbound routing

    func handle(_ message: CallingSIPMessage) {
        if message.isRequest { handleRequest(message) } else { handleResponse(message) }
    }

    private func updateDialog(from response: CallingSIPMessage, confirmed: Bool) {
        remoteTag = response.tag(of: "to") ?? remoteTag
        if let contact = response.header("contact"), let uri = CallingSIPMessage.uri(of: contact) { remoteTarget = uri }
        let record = response.values("record-route", splitCommas: true)
        if !record.isEmpty { routeSet = Array(record.reversed()) }
        else if confirmed || routeSet.isEmpty { routeSet = ctx.serviceRoute }
    }

    private func handleResponse(_ response: CallingSIPMessage) {
        guard let code = response.status, let (cseq, method) = response.cseqParts else { return }
        // Both dialog roles originate BYE. A callee must also stop media on its final response.
        if method == "BYE", code >= 200, state == .ending, response.tag(of: "to") == remoteTag {
            finish(endReason ?? .localHangup); return
        }
        guard role == .caller else { return }
        switch method {
        case "INVITE":
            guard cseq == 1 else { return }
            if (100..<200).contains(code) { provisional(response, code) }
            else if (200..<300).contains(code) { success(response) }
            else if code >= 300 { failure(response, code) }
        case "CANCEL": break  // 200 to CANCEL; the INVITE's 487 (or a crossing 200) finishes the call
        case "BYE": if state == .ending, response.tag(of: "to") == remoteTag { finish(endReason ?? .localHangup) }
        default: break
        }
    }

    private func provisional(_ response: CallingSIPMessage, _ code: Int) {
        guard state == .calling || state == .early else { return }
        gotProvisional = true
        if code == 100 {
            if cancelRequested { sendCancel() }
            else { onEvent(.provisional(code: code, sdp: nil, earlyMedia: nil)) }
            return
        }
        if response.tag(of: "to") != nil { updateDialog(from: response, confirmed: false); state = .early }
        if cancelRequested { sendCancel(); return }
        let reliable = response.values("require", splitCommas: true).contains { $0.lowercased() == "100rel" }
        if reliable, let rseqText = response.header("rseq"), let rseq = Int(rseqText.split(separator: " ").first ?? ""), response.tag(of: "to") != nil {
            if seenRSeq.insert("\(response.tag(of: "to") ?? "")|\(rseq)").inserted {
                sendInDialog("PRACK", extra: [("RAck", "\(rseq) 1 INVITE")])
            } else { return }  // retransmitted reliable provisional: already acknowledged
        }
        if let sdp = response.bodyText { remoteSDP = sdp }
        onEvent(.provisional(code: code, sdp: response.bodyText, earlyMedia: response.header("p-early-media")))
    }

    private func success(_ response: CallingSIPMessage) {
        switch state {
        case .calling, .early:
            updateDialog(from: response, confirmed: true)
            sendAck(response)
            if cancelRequested {
                // CANCEL crossed the 200: complete the dialog, then end it.
                state = .confirmed
                sendBye(); state = .ending; endReason = .cancelledByCaller
                byeWatchdog = Task { [weak self] in
                    try? await Task.sleep(nanoseconds: 8_000_000_000)
                    if !Task.isCancelled { self?.finish(.cancelledByCaller) }
                }
                return
            }
            state = .confirmed
            if let sdp = response.bodyText { remoteSDP = sdp }
            onEvent(.answered(sdp: response.bodyText ?? remoteSDP))
        case .confirmed, .ending:
            if let tag = response.tag(of: "to"), tag != remoteTag {
                // A second fork answered. ACK and terminate that leg without
                // replacing the selected dialog or restarting its media.
                let routes = response.values("record-route", splitCommas: true).reversed().map { $0 }
                let target = response.header("contact").flatMap { CallingSIPMessage.uri(of: $0) } ?? inviteURI
                func sendFork(_ method: String, sequence: Int) {
                    var headers = [("Via", "SIP/2.0/WS \(ctx.viaHost);branch=\(CallingSIPBuild.newBranch())"), ("Max-Forwards", "70")]
                    headers += (routes.isEmpty ? ctx.serviceRoute : routes).map { ("Route", $0) }
                    headers += [("To", response.header("to") ?? ""), ("From", localHeader + ";tag=" + localTag), ("Call-ID", callID), ("CSeq", "\(sequence) \(method)")]
                    if let packet = try? CallingSIPMessage.encode("\(method) \(target) SIP/2.0", headers: headers) { transmit(packet) }
                }
                sendFork("ACK", sequence: 1)
                if discardedForks.insert(tag).inserted { sendFork("BYE", sequence: 2) }
            } else if let lastAck { transmit(lastAck) }   // duplicate 200: re-ACK
        default: break
        }
    }

    private func sendAck(_ response: CallingSIPMessage) {
        var headers: [(String, String)] = [("Via", "SIP/2.0/WS \(ctx.viaHost);branch=\(CallingSIPBuild.newBranch())"), ("Max-Forwards", "70")]
        headers += routeSet.map { ("Route", $0) }
        headers += [("To", remoteHeader + (remoteTag.map { ";tag=" + $0 } ?? "")), ("From", localHeader + ";tag=" + localTag),
                    ("Call-ID", callID), ("CSeq", "1 ACK"), ("User-Agent", ctx.userAgent)]
        let target = remoteTarget.isEmpty ? inviteURI : remoteTarget
        guard let data = try? CallingSIPMessage.encode("ACK \(target) SIP/2.0", headers: headers) else { return }
        lastAck = data; transmit(data)
    }

    private func failure(_ response: CallingSIPMessage, _ code: Int) {
        guard state != .terminated, state != .confirmed else { return }
        // ACK for non-2xx belongs to the INVITE transaction: same branch, request-URI and routes.
        var headers: [(String, String)] = [("Via", "SIP/2.0/WS \(ctx.viaHost);branch=\(inviteBranch)"), ("Max-Forwards", "70")]
        headers += inviteRoutes.map { ("Route", $0) }
        headers += [("To", response.header("to") ?? remoteHeader), ("From", localHeader + ";tag=" + localTag), ("Call-ID", callID), ("CSeq", "1 ACK")]
        if let data = try? CallingSIPMessage.encode("ACK \(inviteURI) SIP/2.0", headers: headers) { transmit(data) }
        if cancelRequested && code == 487 { finish(.cancelledByCaller) }
        else { finish(.failed(code, response.reason)) }
    }

    private func handleRequest(_ request: CallingSIPMessage) {
        guard let method = request.method else { return }
        func ok(_ extra: [(String, String)] = [], body: String? = nil) {
            if let data = try? CallingSIPBuild.response(to: request, code: 200, reason: "OK", toTag: localTag, extra: extra, body: body) { transmit(data) }
        }
        if method == "INVITE", role == .callee, state == .incomingRinging { calleeResponse(180, "Ringing"); return }  // retransmitted INVITE
        if method != "ACK", method != "CANCEL", let n = request.cseqParts?.0 {
            if remoteSeq != 0, n <= remoteSeq {
                if let data = try? CallingSIPBuild.response(to: request, code: 500, reason: "Server Internal Error", toTag: localTag) { transmit(data) }
                return
            }
            remoteSeq = n
        }
        switch method {
        case "ACK":
            if state == .incomingAccepted { ackWatchdog?.cancel(); state = .confirmed; onEvent(.answered(sdp: remoteSDP)) }
        case "BYE":
            ok(); finish(state == .ending ? (endReason ?? .localHangup) : .remoteHangup)
        case "CANCEL":
            guard role == .callee, state == .incomingRinging, let invite else {
                if let data = try? CallingSIPBuild.response(to: request, code: 481, reason: "Call/Transaction Does Not Exist") { transmit(data) }
                return
            }
            if let data = try? CallingSIPBuild.response(to: request, code: 200, reason: "OK", toTag: localTag) { transmit(data) }
            if let data = try? CallingSIPBuild.response(to: invite, code: 487, reason: "Request Terminated", toTag: localTag) { transmit(data) }
            finish(.remoteCancelled)
        case "INFO":
            ok(); onEvent(.info(contentType: request.header("content-type"), body: request.bodyText))
        case "NOTIFY", "MESSAGE":
            ok()
        case "PRACK":
            ok()
        case "UPDATE":
            // An UPDATE offer must receive its SDP answer in the 2xx (RFC 3311 section 5.2).
            // An empty 200 leaves the network's offer unanswered and can stall the initial INVITE.
            if request.bodyText != nil {
                if pendingUpdate != nil || pendingReinvite != nil {
                    if let data = try? CallingSIPBuild.response(to: request, code: 491, reason: "Request Pending", toTag: localTag) { transmit(data) }
                } else {
                    pendingUpdate = request
                    onEvent(.update(sdp: request.bodyText))
                }
            } else { refreshTarget(from: request); ok() }
        case "INVITE":
            // re-INVITE (hold/resume/refresh). The service layer must answer via `answerReinvite`.
            if state == .confirmed { pendingReinvite = request; remoteSDP = request.bodyText ?? remoteSDP; onEvent(.reinvite(sdp: request.bodyText)) }
            else if role == .callee, state == .incomingRinging, let data = lastFinal { transmit(data) }
            else if let data = try? CallingSIPBuild.response(to: request, code: 491, reason: "Request Pending", toTag: localTag) { transmit(data) }
        default:
            if let data = try? CallingSIPBuild.response(to: request, code: 405, reason: "Method Not Allowed", toTag: localTag, extra: [("Allow", "INVITE, ACK, CANCEL, BYE, UPDATE, INFO, NOTIFY, PRACK")]) { transmit(data) }
        }
    }
    private var pendingReinvite: CallingSIPMessage?
    private var pendingUpdate: CallingSIPMessage?

    private func refreshTarget(from request: CallingSIPMessage) {
        if let contact = request.header("contact"), let uri = CallingSIPMessage.uri(of: contact) { remoteTarget = uri }
    }

    func answerUpdate(sdp: String?) {
        guard let request = pendingUpdate else { return }
        pendingUpdate = nil
        if sdp != nil { remoteSDP = request.bodyText ?? remoteSDP; refreshTarget(from: request) }
        let extra = [("Contact", "<\(ctx.contactURI)>")] + (sdp != nil ? [("Content-Type", "application/sdp")] : [])
        if let data = try? CallingSIPBuild.response(to: request, code: sdp != nil ? 200 : 488,
                reason: sdp != nil ? "OK" : "Not Acceptable Here", toTag: localTag, extra: extra, body: sdp) { transmit(data) }
    }

    func answerReinvite(sdp: String?) {
        guard let request = pendingReinvite else { return }
        pendingReinvite = nil
        let extra: [(String, String)] = [("Contact", "<\(ctx.contactURI)>")] + (sdp != nil ? [("Content-Type", "application/sdp")] : [])
        let code = sdp != nil ? 200 : 488
        if let data = try? CallingSIPBuild.response(to: request, code: code, reason: code == 200 ? "OK" : "Not Acceptable Here", toTag: localTag, extra: extra, body: sdp) { transmit(data) }
    }
}
