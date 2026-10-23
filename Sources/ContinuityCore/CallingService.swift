import Foundation

// MARK: - Own-device enrollment lease (reversible, journaled)

extension ContinuitySignIn {
    static let callingJournal = "cmc-pending-cleanup.json"

    /// Enrolls this Mac's own `pc_` device for the lifetime of a foreground calling session.
    /// A private journal (same file the registration test uses) lets a later run remove the entry after a crash.
    /// Only this Mac's own device id is ever added or removed.
    func acquireCallingLease(status: (String) -> Void) async throws -> CallingAccountContext {
        let context = try await callingContext(status: status)
        let collection = context.entitlement.appendingPathComponent("1.0/users/\(context.userID)/lines/\(context.lineID)/devices")
        let ownURL = collection.appendingPathComponent(context.deviceID)
        var removeHeaders = context.headers; removeHeaders["Auth-Device-Id"] = context.deviceID
        var present = context.devices.contains { $0["device_id"] as? String == context.deviceID }
        if let data = try CredentialFiles.load(Self.callingJournal),
           let entry = try? JSONSerialization.jsonObject(with: data) as? [String: Any], entry["device"] as? String == context.deviceID {
            status("Removing a leftover Mac calling enrollment from an earlier run…")
            do { _ = try await request(ownURL, headers: removeHeaders, method: "DELETE") }
            catch let error as SamsungHTTPError where error.status == 404 {}
            try CredentialFiles.delete(Self.callingJournal)
            present = false
        }
        if present {
            // Present without a journal: it is this Mac's own deterministic id, so reuse it and own its removal.
            status("Reusing this Mac's existing calling enrollment.")
        } else {
            status("Registering this Mac as a calling device…")
            let added = try await request(collection, json: context.enrollment, headers: context.headers)
            guard (added["response"] as? [String: Any])?["result"] as? Bool == true else {
                throw ContinuityError.message("Samsung did not accept the Mac calling enrollment.")
            }
        }
        let journal = try JSONSerialization.data(withJSONObject: ["device": context.deviceID, "url": ownURL.absoluteString])
        try CredentialFiles.save(journal, name: Self.callingJournal)
        return context
    }

    /// Removes only this Mac's own calling device. Throws if Samsung has not confirmed the removal (journal is kept).
    func releaseCallingLease(context: CallingAccountContext) async throws {
        let ownURL = context.entitlement.appendingPathComponent("1.0/users/\(context.userID)/lines/\(context.lineID)/devices/\(context.deviceID)")
        var headers = context.headers; headers["Auth-Device-Id"] = context.deviceID
        do {
            let removed = try await request(ownURL, headers: headers, method: "DELETE")
            guard removed.isEmpty || (removed["response"] as? [String: Any])?["result"] as? Bool == true else {
                throw ContinuityError.message("Samsung has not confirmed removal of the Mac calling enrollment.")
            }
        } catch let error as SamsungHTTPError where error.status == 404 {}
        try CredentialFiles.delete(Self.callingJournal)
    }

    /// Fresh token/server view, used by re-REGISTER.
    func freshCallingContext() async throws -> CallingAccountContext { try await callingContext(status: { _ in }) }
}

// MARK: - Controller

public enum CallingPhase: Equatable {
    case stopped, enrolling, connecting, registered, reconnecting
    case failed(String)
}

public enum CallingCallState: Equatable {
    case idle, dialing, ringing, incoming(String), connecting, active, ending
}

public enum CallingIncomingPolicy {
    /// Ring the UI and let the user answer or decline.
    case interactive
    /// Record that an INVITE arrived but send no response at all (safe for unattended live tests).
    case observeOnly
}

/// The Mac's Samsung CMC calling client: registration, dial, answer, decline, hang up, mute.
/// Real calls only ever start from an explicit `dial` or `answer` call made by the user's action.
@MainActor public final class CallingController: ObservableObject {
    @Published public private(set) var phase: CallingPhase = .stopped
    @Published public private(set) var callState: CallingCallState = .idle
    @Published public private(set) var status = "Calling is off."
    @Published public private(set) var muted = false
    @Published public private(set) var callStart: Date?
    public var incomingPolicy: CallingIncomingPolicy = .interactive
    /// Counts, never content: (REGISTER 200s, server requests seen outside dialogs, incoming INVITEs).
    public private(set) var registerCount = 0
    public private(set) var incomingInviteCount = 0
    public private(set) var requestMethods: [String] = []
    public private(set) var unregisterCode: Int?
    public var registrationShape: String { registrar?.lastRegisterShape ?? lastShape }
    private var lastShape = ""
    /// Statuses, counts and state words only.
    public var subscriptionReport: String {
        guard let r = registrar else { return lastSubscriptionReport }
        return "SUBSCRIBE status \(r.subscribeStatus.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ",")); NOTIFY counts \(r.notifyCounts.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ",")); dialog states \(r.dialogInfoStates.joined(separator: ","))"
    }
    private var lastSubscriptionReport = ""
    static let enabledKey = "calling-enabled"
    /// True when the user last left calling turned on; the app restarts it at launch.
    public static var wantsAutostart: Bool { UserDefaults.standard.bool(forKey: enabledKey) }
    private var activity: NSObjectProtocol?

    private var context: CallingAccountContext?
    private var registrar: CallingRegistrar?
    private var dialog: CallingDialog?
    private var offeredCryptos: [CallingSDPCrypto] = []
    private var stopping = false
    private var reconnectTask: Task<Void, Never>?
    private var userSetMuted = false
    private let mediaQueue = DispatchQueue(label: "calling.media", qos: .userInteractive)
    #if canImport(CallingMediaC)
    private var media: CallingMediaSession?
    #endif
    private var audio: CallingAudioIO?

    public static let shared = CallingController()
    public init() {}

    public var isRegistered: Bool { phase == .registered }
    public var hasIncomingCall: Bool { if case .incoming = callState { return true }; return false }
    public var negotiatedExpiry: Int { registrar?.expires ?? 0 }

    // MARK: Lifecycle

    public func start() {
        if case .failed = phase {} else if phase != .stopped { return }
        UserDefaults.standard.set(true, forKey: Self.enabledKey)
        stopping = false
        Task { await bringUp() }
    }

    /// Starts and waits until registered or failed. Used by the CLI.
    public func startAndWait() async throws {
        stopping = false
        await bringUp()
        if case .failed(let message) = phase { throw ContinuityError.message(message) }
    }

    private func bringUp() async {
        do {
            phase = .enrolling; status = "Preparing this Mac for Samsung calling…"
            let context = try await ContinuitySignIn.shared.acquireCallingLease { self.status = $0 }
            self.context = context
            let registrar = CallingRegistrar(context: context) { try await ContinuitySignIn.shared.freshCallingContext() }
            registrar.onRequest = { [weak self] in self?.serverRequest($0) }
            registrar.onClosed = { [weak self] error in self?.connectionLost(error) }
            registrar.onNotify = { [weak self] _ in self?.objectWillChange.send() }
            self.registrar = registrar
            phase = .connecting
            try await registrar.connectAndRegister { self.status = $0 }
            registerCount = registrar.registerCount
            phase = .registered; status = "Ready for calls on this Mac."
            holdActivity()
        } catch {
            status = error.localizedDescription
            phase = .failed(error.localizedDescription)
            await tearDown(removeEnrollment: true)
        }
    }

    /// Forces a re-REGISTER now (same connection, same Call-ID, fresh token) and reports the new expiry.
    public func refreshRegistration() async throws -> Int {
        guard let registrar, phase == .registered else { throw ContinuityError.message("Calling is not registered.") }
        try await registrar.reregister()
        registerCount = registrar.registerCount
        return registrar.expires
    }

    public func stop() {
        UserDefaults.standard.set(false, forKey: Self.enabledKey)
        Task { await stopAndWait() }
    }

    /// Hangs up, unregisters (Expires: 0) and removes this Mac's calling enrollment.
    public func stopAndWait() async {
        stopping = true; reconnectTask?.cancel()
        dialog?.hangUp()
        try? await Task.sleep(nanoseconds: 300_000_000)
        endMedia()
        await tearDown(removeEnrollment: true)
        releaseActivity()
        phase = .stopped; callState = .idle; status = "Calling is off."
    }

    /// App Nap would throttle the keepalive and the idle TLS read while the window is hidden: hold an activity while registered.
    private func holdActivity() { if activity == nil { activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiatedAllowingIdleSystemSleep], reason: "Samsung calling registration") } }
    private func releaseActivity() { if let activity { ProcessInfo.processInfo.endActivity(activity) }; activity = nil }

    /// Quit path: unregister and remove the enrollment but keep the user's on/off preference.
    public func shutdownForQuit() async { await stopAndWait() }

    private func tearDown(removeEnrollment: Bool) async {
        if let registrar {
            registrar.onClosed = nil
            lastShape = registrar.lastRegisterShape; lastSubscriptionReport = subscriptionReport
            unregisterCode = await registrar.stop()
            requestMethods = registrar.dispatcher?.seenRequestMethods ?? requestMethods
        }
        registrar = nil
        if removeEnrollment, let context {
            do { try await ContinuitySignIn.shared.releaseCallingLease(context: context) }
            catch { status = "Calling stopped, but the Mac calling entry still needs removal: \(error.localizedDescription)" }
        }
        if removeEnrollment { self.context = nil }
    }

    private func connectionLost(_ error: Error?) {
        guard !stopping else { return }
        endMedia()
        if let dialog, dialog.state != .terminated { dialog.transportLost() }
        callState = .idle
        phase = .reconnecting; status = "Calling connection lost. Reconnecting…"
        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            var delay: UInt64 = 1
            for attempt in 0..<20 {
                try? await Task.sleep(nanoseconds: delay * 1_000_000_000)
                guard let self, !Task.isCancelled, !self.stopping, let context = self.context else { return }
                do {
                    let registrar = CallingRegistrar(context: (try? await ContinuitySignIn.shared.freshCallingContext()) ?? context) { try await ContinuitySignIn.shared.freshCallingContext() }
                    registrar.onRequest = { [weak self] in self?.serverRequest($0) }
                    registrar.onClosed = { [weak self] error in self?.connectionLost(error) }
                    try await registrar.connectAndRegister(serverIndex: attempt)
                    self.registrar = registrar; self.registerCount += 1
                    self.phase = .registered; self.status = "Ready for calls on this Mac."
                    return
                } catch { delay = min(delay * 2, 10) }
            }
            self?.phase = .failed("Could not reconnect to Samsung calling.")
        }
    }

    // MARK: Local network

    static func localIPv4() throws -> String {
        let networks = try FeatureProtocol.localNetworks()
        guard let ip = (networks.first { $0["TYPE"] as? String == "wlan" } ?? networks.first)?["IP"] as? String else {
            throw ContinuityError.message("No local network address for call audio.")
        }
        return ip
    }

    // MARK: Outgoing

    /// Places a real call. Only call this from an explicit user action.
    public func dial(number: String, slot: Int? = nil) {
        guard phase == .registered, callState == .idle, let registrar, let context, let dispatcher = registrar.dispatcher else {
            status = "Calling is not ready."; return
        }
        #if canImport(CallingMediaC)
        callState = .dialing; status = "Starting the call…"
        Task {
            do {
                guard await CallingAudioEngine.requestMicrophone() else { throw ContinuityError.message("Allow microphone access in System Settings to place calls.") }
                let ip = try Self.localIPv4()
                let socket = try CallingUDPSocket(queue: mediaQueue)
                offeredCryptos = try CallingSDP.makeLocalCryptos()
                localSDPSessionID = String(UInt32.random(in: 1...UInt32.max))
                let offer = CallingSDP.makeOffer(localIP: ip, port: Int(socket.port), cryptos: offeredCryptos, id: localSDPSessionID)
                let ctx = dialogContext(registrar: registrar, context: context)
                let dialog = CallingDialog(role: .caller, context: ctx) { dispatcher.send($0) }
                dispatcher.register(dialog: dialog)
                attach(dialog, dispatcher: dispatcher, socket: socket)
                self.dialog = dialog
                try dialog.startOutgoing(target: ctx.dialTarget(primaryDeviceID: context.primaryID), number: number, offer: offer, slot: slot.map(String.init))
            } catch {
                status = error.localizedDescription; callState = .idle; endMedia()
            }
        }
        #else
        status = "Call audio libraries are not built into this copy."
        #endif
    }

    private func dialogContext(registrar: CallingRegistrar, context: CallingAccountContext) -> CallingDialogContext {
        CallingDialogContext(userID: context.lineID, viaHost: registrar.viaHost, contactURI: registrar.dialogContact, serviceRoute: registrar.serviceRoute)
    }

    private var pendingSocket: CallingUDPSocket?
    private var earlyPlan: CallingMediaPlan?

    private func attach(_ dialog: CallingDialog, dispatcher: CallingSIPDispatcher, socket: CallingUDPSocket) {
        pendingSocket = socket; earlyPlan = nil
        dialog.onFinished = { [weak dispatcher, weak dialog] in if let dispatcher, let dialog { dispatcher.unregister(dialog: dialog) } }
        dialog.onEvent = { [weak self] event in self?.dialogEvent(event) }
    }

    private func dialogEvent(_ event: CallingDialogEvent) {
        switch event {
        case .provisional(let code, let sdp, _): CallingDiagnostics.shared.log("event provisional \(code) sdp=\(sdp != nil)")
        case .answered(let sdp): CallingDiagnostics.shared.log("event answered sdp=\(sdp != nil)")
        case .reinvite(let sdp): CallingDiagnostics.shared.log("event reinvite sdp=\(sdp != nil)")
        case .update(let sdp): CallingDiagnostics.shared.log("event update sdp=\(sdp != nil)")
        case .info: CallingDiagnostics.shared.log("event info")
        case .ended(let reason): CallingDiagnostics.shared.log("event ended \(reason.diagnosticLabel)")
        }
        switch event {
        case .provisional(let code, let sdp, let early):
            if code == 100 { status = "Waiting for your phone to start the call…"; return }
            if callState == .dialing { callState = .ringing; status = "Ringing…" }
            _ = (code, early)
            if let sdp { startMediaIfPossible(answerSDP: sdp, sending: false) }   // early media: play ringback, send nothing yet
        case .answered(let sdp):
            callState = .active; callStart = Date(); status = "Call connected."
            if dialog?.role == .caller { if let sdp { startMediaIfPossible(answerSDP: sdp, sending: true) } }
            #if canImport(CallingMediaC)
            media?.setSendEnabled(true)
            #endif
        case .reinvite(let sdp):
            answerReinvite(sdp)
        case .update(let sdp): answerUpdate(sdp)
        case .info: break
        case .ended(let reason):
            endMedia()
            callState = .idle; callStart = nil
            switch reason {
            case .failed(let code, let text): status = "Call failed (\(code) \(text))."
            case .remoteHangup: status = "Call ended."
            case .declined: status = "Call declined."
            case .remoteCancelled: status = "Missed call."
            case .transportLost: status = "Call lost with the connection."
            default: status = "Call ended."
            }
            dialog = nil
        }
    }

    private var currentPlan: CallingMediaPlan?
    private var localMediaPort = 0
    private var sdpVersion = 2
    private var localSDPSessionID = "1"

    /// Hold/resume/refresh from the network: same codec and keys, direction mirrored; a change we cannot honor gets 488.
    private func answerReinvite(_ sdp: String?) {
        guard let sdp, let plan = currentPlan, let ip = try? Self.localIPv4() else { dialog?.answerReinvite(sdp: nil); return }
        do {
            sdpVersion += 1
            let reply = try CallingSDP.reinviteAnswer(offer: sdp, plan: plan, localIP: ip, port: localMediaPort, version: sdpVersion, id: localSDPSessionID)
            dialog?.answerReinvite(sdp: reply.sdp)
            #if canImport(CallingMediaC)
            media?.setSendEnabled(reply.direction == "sendrecv" || reply.direction == "sendonly")
            #endif
            status = reply.direction == "sendrecv" ? "Call resumed." : "Call on hold."
        } catch { dialog?.answerReinvite(sdp: nil); status = error.localizedDescription }
    }

    /// Respond to network offers even before the initial INVITE has a final answer.
    /// Keep the microphone gated until that answer; UPDATE itself does not connect a call.
    private func answerUpdate(_ sdp: String?) {
        guard let sdp, let plan = currentPlan, let socket = pendingSocket else { dialog?.answerUpdate(sdp: nil); return }
        do {
            sdpVersion += 1
            let reply = try CallingSDP.updateAnswer(offer: sdp, plan: plan, localIP: Self.localIPv4(),
                                                   port: Int(socket.port), version: sdpVersion, id: localSDPSessionID)
            #if canImport(CallingMediaC)
            if reply.plan != currentPlan {
                media?.stop(closeSocket: false); media = nil
                let session = try CallingMediaSession(plan: reply.plan, socket: socket, audio: CallingAudioEngine(), queue: mediaQueue)
                session.setMuted(userSetMuted); session.setSendEnabled(callState == .active)
                session.setEarlyKeepalive(callState != .active)
                media = session; try session.start()
            }
            #endif
            currentPlan = reply.plan; earlyPlan = reply.plan
            dialog?.answerUpdate(sdp: reply.sdp)
            CallingDiagnostics.shared.log("event update answered mediaChanged=\(reply.plan != plan) active=\(callState == .active)")
        } catch {
            CallingDiagnostics.shared.log("event update rejected code=\((error as NSError).code)")
            dialog?.answerUpdate(sdp: nil)
        }
    }

    // MARK: Incoming

    private func serverRequest(_ request: CallingSIPMessage) {
        guard let method = request.method, let registrar, let dispatcher = registrar.dispatcher else { return }
        guard method == "INVITE" else { dispatcher.reply(request, 200, "OK"); return }
        incomingInviteCount += 1
        if incomingPolicy == .observeOnly { return }
        guard callState == .idle, let context else { dispatcher.reply(request, 486, "Busy Here", toTag: CallingSIPBuild.token(8)); return }
        guard let id = request.callID else { return }
        let ctx = dialogContext(registrar: registrar, context: context)
        let dialog = CallingDialog(role: .callee, context: ctx, callID: id) { dispatcher.send($0) }
        dispatcher.register(dialog: dialog)
        dialog.onFinished = { [weak dispatcher, weak dialog] in if let dispatcher, let dialog { dispatcher.unregister(dialog: dialog) } }
        dialog.onEvent = { [weak self] event in self?.dialogEvent(event) }
        dialog.receiveInvite(request)
        self.dialog = dialog
        dialog.sendRinging()
        let name = dialog.displayName
        callState = .incoming(name.isEmpty ? "Unknown caller" : name)
        status = "Incoming call."
    }

    public func answer() {
        guard case .incoming = callState, let dialog else { return }
        #if canImport(CallingMediaC)
        callState = .connecting
        Task {
            do {
                guard await CallingAudioEngine.requestMicrophone() else { throw ContinuityError.message("Allow microphone access to answer calls.") }
                guard let offer = dialog.remoteSDP else { throw ContinuityError.message("The incoming call has no audio offer.") }
                let socket = try CallingUDPSocket(queue: mediaQueue)
                localSDPSessionID = String(UInt32.random(in: 1...UInt32.max)); sdpVersion = 1
                let result = try CallingSDP.answer(offer: offer, localIP: try Self.localIPv4(), port: Int(socket.port), id: localSDPSessionID)
                pendingSocket = socket; currentPlan = result.plan; localMediaPort = Int(socket.port)
                let session = try CallingMediaSession(plan: result.plan, socket: socket, audio: CallingAudioEngine(), queue: mediaQueue)
                session.setMuted(userSetMuted)
                media = session
                dialog.accept(answerSDP: result.sdp)
                try session.start()
                session.setSendEnabled(true)
            } catch {
                status = error.localizedDescription
                dialog.decline(code: 488, reason: "Not Acceptable Here")
                endMedia(); callState = .idle
            }
        }
        #else
        status = "Call audio libraries are not built into this copy."
        #endif
    }

    public func decline() { if case .incoming = callState { dialog?.decline() } }

    public func hangUp() {
        guard callState != .idle else { return }
        if callState == .active || callState == .connecting || callState == .dialing || callState == .ringing { callState = .ending }
        dialog?.hangUp()
    }

    public func setMuted(_ value: Bool) {
        userSetMuted = value; muted = value
        #if canImport(CallingMediaC)
        media?.setMuted(value)
        #endif
    }

    public func sendDigit(_ digit: Character) {
        #if canImport(CallingMediaC)
        media?.sendDTMF(digit)
        #endif
    }

    // MARK: Media

    private func startMediaIfPossible(answerSDP: String, sending: Bool) {
        #if canImport(CallingMediaC)
        guard let socket = pendingSocket, !offeredCryptos.isEmpty else { return }
        do {
            let plan = try CallingSDP.plan(offered: offeredCryptos, answer: answerSDP)
            if media != nil, plan == earlyPlan { return }
            // The advertised port belongs to pendingSocket. A changed final
            // answer must not close it while replacing receive-only early media.
            if media != nil { media?.stop(closeSocket: false); media = nil }
            earlyPlan = plan; currentPlan = plan; localMediaPort = Int(socket.port)
            let session = try CallingMediaSession(plan: plan, socket: socket, audio: CallingAudioEngine(), queue: mediaQueue)
            session.setMuted(userSetMuted); session.setSendEnabled(sending)
            session.setEarlyKeepalive(!sending)
            media = session
            try session.start()
        } catch {
            CallingDiagnostics.shared.log("media start failed code=\((error as NSError).code)")
            status = "Call audio could not start: \(error.localizedDescription)"
        }
        #endif
    }

    private func endMedia() {
        #if canImport(CallingMediaC)
        media?.stop(); media = nil
        #endif
        pendingSocket?.close(); pendingSocket = nil
        offeredCryptos = []; earlyPlan = nil; currentPlan = nil; sdpVersion = 2
        muted = false; userSetMuted = false
    }
}
