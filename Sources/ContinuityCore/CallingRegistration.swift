import Foundation

/// Foreground SIP registration of this Mac's own CMC device identity over one persistent TLS connection.
/// Owns: connect, unregister-then-register (as the stock client does), negotiated-expiry refresh,
/// CRLF keepalive and clean unregister. All traffic goes through `CallingSIPDispatcher`, so server requests
/// (an INVITE during re-REGISTER, OPTIONS, NOTIFY) are never swallowed by a waiting registration.
@MainActor final class CallingRegistrar {
    enum RegistrarError: Error, LocalizedError {
        case rejected(Int), tokenRejected
        var errorDescription: String? {
            switch self {
            case .rejected(let code): return "Samsung's calling server refused registration (\(code))."
            case .tokenRejected: return "Samsung's calling server rejected the access token (403)."
            }
        }
    }

    private let contextProvider: () async throws -> CallingAccountContext
    private(set) var context: CallingAccountContext
    private var connection: CallingSIPConnection?
    private var readTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var keepAliveTask: Task<Void, Never>?
    private(set) var dispatcher: CallingSIPDispatcher?
    private var callID = "", fromTag = "", cseq = 0
    let contactToken = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12)).lowercased()
    private(set) var expires = 3600
    private(set) var registered = false
    private(set) var serviceRoute: [String] = []
    private(set) var publicGruu: String?
    private(set) var registerCount = 0
    /// Sanitized shape of the last REGISTER 200 (header names and booleans only, never values).
    private(set) var lastRegisterShape = ""
    var onClosed: ((Error?) -> Void)?
    var onRequest: ((CallingSIPMessage) -> Void)?
    /// Diagnostics only (statuses, counts and state words; never URIs, numbers or bodies).
    private(set) var subscribeStatus: [String: Int] = [:]
    private(set) var notifyCounts: [String: Int] = [:]
    private(set) var dialogInfoStates: [String] = []
    private var subscriptions: [String: Subscription] = [:]
    private var subscriptionTasks: [Task<Void, Never>] = []
    private struct Subscription { var callID: String; var tag: String; var cseq: Int; var remoteTag: String?; var accept: String; var expires: Int }
    var requestedExpires = 3600
    var viaHost: String { contactToken + ".invalid" }
    var plainContact: String { "sip:\(contactToken)@\(contactToken).invalid;transport=ws" }
    /// Contact URI for dialogs: the public GRUU from the registration when the server issued one.
    var dialogContact: String { publicGruu ?? plainContact }

    init(context: CallingAccountContext, contextProvider: @escaping () async throws -> CallingAccountContext) {
        self.context = context; self.contextProvider = contextProvider
    }

    func connectAndRegister(serverIndex: Int = 0, status: (String) -> Void = { _ in }) async throws {
        guard !context.servers.isEmpty else { throw ContinuityError.message("No Samsung calling server.") }
        var failures = 0
        var lastError: Error = ContinuityError.message("No calling server reachable.")
        for offset in 0..<min(3, context.servers.count) {
            let server = context.servers[(serverIndex + offset) % context.servers.count]
            do {
                let connection = try CallingSIPConnection(server: server)
                let timeout = Task { try? await Task.sleep(nanoseconds: 12_000_000_000); if !Task.isCancelled { connection.close() } }
                defer { timeout.cancel() }
                status("Connecting to Samsung calling server \((serverIndex + offset) % context.servers.count + 1)…")
                try await connection.connect()
                self.connection = connection
                let dispatcher = CallingSIPDispatcher { try await connection.send($0) }
                dispatcher.onRequest = { [weak self] in self?.routeRequest($0) }
                dispatcher.onClosed = { [weak self] error in self?.transportClosed(error) }
                self.dispatcher = dispatcher
                readTask = Task { [weak dispatcher] in
                    do { while !Task.isCancelled { let message = try await connection.receive(); dispatcher?.handle(message) } }
                    catch { dispatcher?.shutdown(error) }
                }
                callID = UUID().uuidString; fromTag = CallingSIPBuild.token(8); cseq = 0
                // The stock client unregisters first and waits a second: the CMC server ignores an
                // unregister that arrives together with a register.
                status("Clearing any stale registration…")
                _ = try? await send(expires: 0, timeout: 6)
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                status("Registering this Mac…")
                try await register(expires: requestedExpires)
                startKeepAlive(); startRefresh()
                startSubscriptions()
                return
            } catch {
                lastError = error; failures += 1
                await teardownConnection()
                if case RegistrarError.tokenRejected = error { throw error }
            }
        }
        throw lastError
    }

    private func send(expires value: Int, timeout: TimeInterval = 20) async throws -> CallingSIPMessage {
        guard let dispatcher else { throw ContinuityError.message("Calling connection is not open.") }
        cseq += 1
        let uri = "sip:" + context.lineID + "@samsungims.com"
        let token = context.headers["Access-Token"] ?? ""
        let auth = "https://" + (context.headers["Auth-Server-Url"] ?? "")
        let bssid = ((try? FeatureProtocol.localNetworks())?.first { $0["TYPE"] as? String == "wlan" }?["ID"] as? String) ?? "00:00:00:00:00:00"
        let wlan = bssid.replacingOccurrences(of: ":", with: "")
        let params = ";reg-id=1;+sip.instance=\"urn:duid:\(context.deviceID)\";pc-client=1;i-wlan-node-id=\(wlan);cmc-version=2.0"
        let branch = CallingSIPBuild.newBranch()
        return try await dispatcher.request("REGISTER sip:samsungims.com SIP/2.0", headers: [
            ("Via", "SIP/2.0/WS \(viaHost);branch=\(branch)"), ("Max-Forwards", "70"), ("To", "<\(uri)>"), ("From", "<\(uri)>;tag=\(fromTag)"),
            ("Call-ID", callID), ("CSeq", "\(cseq) REGISTER"), ("Contact", "<\(plainContact)>" + params),
            ("Expires", String(value)), ("Supported", "path, gruu, outbound"), ("User-Agent", "browserCall"),
            ("Auth-Server-Url", auth), ("Access_Token", token), ("P-Access-Network-Info", "IEEE-802.11;i-wlan-node-id=" + wlan)],
            branch: branch, method: "REGISTER", timeout: timeout)
    }

    private func register(expires value: Int) async throws {
        let response = try await send(expires: value)
        guard let code = response.status else { throw ContinuityError.message("Unreadable registration response.") }
        if code == 403 { throw RegistrarError.tokenRejected }
        guard code == 200 else { throw RegistrarError.rejected(code) }
        applyRegistration(response, requested: value)
        registered = true; registerCount += 1
    }

    /// Reads the negotiated expiry, Service-Route and public GRUU from a 200 OK. Never logs their values.
    func applyRegistration(_ response: CallingSIPMessage, requested: Int) {
        var granted = Int(response.header("expires") ?? "") ?? requested
        for contact in response.values("contact", splitCommas: true) where contact.contains("urn:duid:\(context.deviceID)") {
            if let value = CallingSIPMessage.parameter("expires", in: contact), let n = Int(value) { granted = n }
            if let range = contact.range(of: "pub-gruu=\""), let end = contact[range.upperBound...].firstIndex(of: "\"") {
                publicGruu = String(contact[range.upperBound..<end])
            }
        }
        expires = max(60, min(granted, requested))
        let names = Array(Set(response.headers.map { $0.0 })).sorted().joined(separator: ",")
        let contactParams = response.values("contact", splitCommas: true).map { c in
            c.split(separator: ";").dropFirst().map { String($0.split(separator: "=").first ?? "") }.sorted().joined(separator: "+") }.joined(separator: " | ")
        lastRegisterShape = "headers[\(names)] contactParams[\(contactParams)] granted=\(granted) gruu=\(publicGruu != nil) serviceRoute=\(!response.values("service-route").isEmpty) path=\(!response.values("path").isEmpty)"
        let routes = response.values("service-route", splitCommas: true)
        if !routes.isEmpty { serviceRoute = routes }
    }

    // MARK: Event subscriptions (the stock client subscribes to `reg` for 3600 s and `dialog` for 600000 s)

    private func startSubscriptions() {
        for (event, accept, requested) in [("reg", "application/reginfo+xml", 3600), ("dialog", "application/dialog-info+xml", 600000)] {
            let task = Task { [weak self] in
                guard let self else { return }
                var expires = requested
                var first = true
                while !Task.isCancelled, self.registered {
                    do {
                        let granted = try await self.subscribe(event: event, accept: accept, expires: expires, initial: first)
                        first = false
                        let wait = max(30, Double(min(granted, 86400)) * 0.6)
                        try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
                    } catch {
                        self.subscribeStatus[event] = -1
                        first = true; expires = min(expires, 3600)
                        try? await Task.sleep(nanoseconds: 60_000_000_000)   // quiet retry; never fatal for registration
                    }
                }
            }
            subscriptionTasks.append(task)
        }
    }

    /// SUBSCRIBE (initial or refresh). Returns the granted expiry. Non-2xx throws.
    private func subscribe(event: String, accept: String, expires: Int, initial: Bool) async throws -> Int {
        guard let dispatcher else { throw ContinuityError.message("Calling connection is not open.") }
        let aor = "sip:" + context.lineID + "@samsungims.com"
        var sub = initial ? Subscription(callID: UUID().uuidString, tag: CallingSIPBuild.token(8), cseq: 0, remoteTag: nil, accept: accept, expires: expires) : (subscriptions[event] ?? Subscription(callID: UUID().uuidString, tag: CallingSIPBuild.token(8), cseq: 0, remoteTag: nil, accept: accept, expires: expires))
        sub.cseq += 1
        let branch = CallingSIPBuild.newBranch()
        let token = context.headers["Access-Token"] ?? ""
        let auth = "https://" + (context.headers["Auth-Server-Url"] ?? "")
        var headers: [(String, String)] = [("Via", "SIP/2.0/WS \(viaHost);branch=\(branch)"), ("Max-Forwards", "70")]
        if sub.remoteTag == nil { headers += serviceRoute.map { ("Route", $0) } }
        headers += [("To", "<\(aor)>" + (sub.remoteTag.map { ";tag=" + $0 } ?? "")), ("From", "<\(aor)>;tag=\(sub.tag)"),
                    ("Call-ID", sub.callID), ("CSeq", "\(sub.cseq) SUBSCRIBE"), ("Contact", "<\(dialogContact)>"),
                    ("Event", event), ("Expires", String(expires)), ("Accept", accept), ("User-Agent", "browserCall"),
                    ("Auth-Server-Url", auth), ("Access_Token", token)]
        let response = try await dispatcher.request("SUBSCRIBE \(aor) SIP/2.0", headers: headers, branch: branch, method: "SUBSCRIBE", timeout: 20)
        let code = response.status ?? 0
        subscribeStatus[event] = code
        guard (200..<300).contains(code) else { subscriptions[event] = nil; throw ContinuityError.message("SUBSCRIBE \(event) returned \(code).") }
        sub.remoteTag = response.tag(of: "to") ?? sub.remoteTag
        subscriptions[event] = sub
        return Int(response.header("expires") ?? "") ?? min(expires, 3600)
    }

    /// NOTIFYs for our subscriptions are acknowledged here; everything else goes to the controller.
    private func routeRequest(_ request: CallingSIPMessage) {
        guard request.method == "NOTIFY", let event = request.header("event")?.split(separator: ";").first.map({ String($0).trimmingCharacters(in: .whitespaces).lowercased() }) else {
            onRequest?(request); return
        }
        notifyCounts[event, default: 0] += 1
        dispatcher?.reply(request, 200, "OK")
        if event == "dialog", let body = request.bodyText {
            // State words only (trying/early/confirmed/terminated) so a ringing phone dialog can be seen without any numbers.
            let states = body.components(separatedBy: "<state").dropFirst().compactMap { $0.split(separator: ">").dropFirst().first?.split(separator: "<").first.map(String.init) }
            dialogInfoStates = Array((dialogInfoStates + states).suffix(40))
        }
        if request.header("subscription-state")?.lowercased().hasPrefix("terminated") == true { subscriptions[event] = nil }
        onNotify?(event)
    }
    var onNotify: ((String) -> Void)?

    private func startKeepAlive() {
        keepAliveTask?.cancel()
        keepAliveTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 120_000_000_000)
                if Task.isCancelled { break }
                self?.dispatcher?.send(Data("\r\n\r\n".utf8))
            }
        }
    }

    private func startRefresh() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let delay = max(30, Double(self.expires) * 0.6)
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                if Task.isCancelled { break }
                do { try await self.reregister() }
                catch { self.transportClosed(error); return }
            }
        }
    }

    /// Re-REGISTER on the same connection and Call-ID with a freshly validated token. Incoming INVITEs keep flowing meanwhile.
    func reregister() async throws {
        if let fresh = try? await contextProvider() { context = fresh }
        try await register(expires: requestedExpires)
    }

    private func transportClosed(_ error: Error?) {
        guard registered || connection != nil else { return }
        registered = false
        let callback = onClosed
        Task { await teardownConnection(); callback?(error) }
    }

    private func teardownConnection() async {
        subscriptionTasks.forEach { $0.cancel() }; subscriptionTasks = []; subscriptions = [:]
        refreshTask?.cancel(); keepAliveTask?.cancel(); readTask?.cancel()
        refreshTask = nil; keepAliveTask = nil; readTask = nil
        dispatcher?.shutdown(); dispatcher = nil
        connection?.close(); connection = nil
        registered = false
    }

    /// Unregisters (Expires: 0) and closes. Returns the unregister status code if one arrived.
    @discardableResult func stop() async -> Int? {
        refreshTask?.cancel(); keepAliveTask?.cancel(); subscriptionTasks.forEach { $0.cancel() }
        var code: Int?
        if registered, dispatcher != nil {
            code = (try? await send(expires: 0, timeout: 8))?.status
        }
        onClosed = nil
        await teardownConnection()
        return code
    }
}
