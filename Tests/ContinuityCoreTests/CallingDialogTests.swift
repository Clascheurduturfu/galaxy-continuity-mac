import XCTest
@testable import ContinuityCore

/// Offline SIP dispatcher + dialog tests. Everything is synthetic: fake line id, fake device id, number 0123456789.
@MainActor final class CallingDialogTests: XCTestCase {
    let ctx = CallingDialogContext(userID: "line1", viaHost: "abc.invalid", contactURI: "sip:abc@abc.invalid;transport=ws")
    var sent: [CallingSIPMessage] = []
    var events: [String] = []

    func transmit(_ data: Data) {
        var stream = CallingSIPStream()
        try? stream.append(data)
        if let message = try? stream.next() { sent.append(message) }
    }
    func make(_ role: CallingDialog.Role = .caller, callID: String = "call-1@x") -> CallingDialog {
        sent = []; events = []
        let dialog = CallingDialog(role: role, context: ctx, callID: callID) { [unowned self] in self.transmit($0) }
        dialog.onEvent = { [unowned self] event in
            switch event {
            case .provisional(let code, _, _): self.events.append("prov\(code)")
            case .answered: self.events.append("answered")
            case .ended(let reason): self.events.append("ended:\(reason)")
            case .reinvite: self.events.append("reinvite")
            case .update: self.events.append("update")
            case .info: self.events.append("info")
            }
        }
        return dialog
    }
    /// Server response to the INVITE we sent last.
    func serverResponse(_ code: Int, _ reason: String, toTag: String? = "srv1", extra: [(String, String)] = [], body: String? = nil, to request: CallingSIPMessage? = nil) throws -> CallingSIPMessage {
        let data = try CallingSIPBuild.response(to: request ?? sent.first { $0.method == "INVITE" }!, code: code, reason: reason, toTag: toTag,
                                                extra: [("Contact", "<sip:peer@198.51.100.1:5060>")] + extra, body: body)
        var stream = CallingSIPStream(); try stream.append(data)
        return try stream.next()!
    }
    func methods() -> [String] { sent.compactMap { $0.method } }

    func testDialTargetMatchesStockFormat() {
        XCTAssertEqual(ctx.dialTarget(primaryDeviceID: "PRIMARY1"), "sip:line1@samsungims.com;gr=urn:duid:PRIMARY1")
    }

    func testOutgoingInviteContract() throws {
        let dialog = make()
        try dialog.startOutgoing(target: ctx.dialTarget(primaryDeviceID: "PRIMARY1"), number: "01 23-45 6789", offer: "v=0\r\n", slot: "1")
        let invite = sent[0]
        XCTAssertEqual(invite.startLine, "INVITE sip:line1@samsungims.com;gr=urn:duid:PRIMARY1 SIP/2.0")
        XCTAssertEqual(invite.header("from")?.hasPrefix("\"0123456789\" <sip:line1@samsungims.com>;tag="), true)   // number in display name, spaces/dashes removed
        XCTAssertEqual(invite.header("to"), "<sip:line1@samsungims.com;gr=urn:duid:PRIMARY1>")
        XCTAssertEqual(invite.header("cseq"), "1 INVITE"); XCTAssertEqual(invite.header("p-early-media"), "supported")
        XCTAssertEqual(invite.header("cmc-mno"), ";call-slot=1"); XCTAssertEqual(invite.header("supported"), "100rel")
        XCTAssertEqual(invite.header("content-type"), "application/sdp"); XCTAssertEqual(invite.header("user-agent"), "browserCall")
        XCTAssertEqual(invite.bodyText, "v=0\r\n")
        XCTAssertThrowsError(try make().startOutgoing(target: "sip:x", number: "abc", offer: ""))
        XCTAssertThrowsError(try make().startOutgoing(target: "sip:x", number: "123", offer: "", slot: "7"))
        let plain = make()
        try plain.startOutgoing(target: "sip:x@y", number: "123", offer: "")
        XCTAssertNil(sent[0].header("cmc-mno"))
    }

    func testEarlyMediaPrackAnswerDuplicate200AndRemoteBye() throws {
        let dialog = make()
        try dialog.startOutgoing(target: "sip:line1@samsungims.com;gr=urn:duid:P", number: "0123456789", offer: "v=0\r\n")
        dialog.handle(try serverResponse(100, "Trying", toTag: nil))
        dialog.handle(try serverResponse(183, "Session Progress", extra: [("Require", "100rel"), ("RSeq", "7"), ("P-Early-Media", "sendrecv"), ("Record-Route", "<sip:rr1;lr>, <sip:rr2;lr>"), ("Content-Type", "application/sdp")], body: "v=0\r\n"))
        XCTAssertEqual(events, ["prov100", "prov183"]); XCTAssertEqual(dialog.state, .early)
        let prack = sent.last!
        XCTAssertEqual(prack.method, "PRACK"); XCTAssertEqual(prack.header("rack"), "7 1 INVITE"); XCTAssertEqual(prack.header("cseq"), "2 PRACK")
        XCTAssertEqual(prack.values("route"), ["<sip:rr2;lr>", "<sip:rr1;lr>"])        // reversed Record-Route
        // retransmitted reliable provisional: no second PRACK, no second event
        dialog.handle(try serverResponse(183, "Session Progress", extra: [("Require", "100rel"), ("RSeq", "7")]))
        XCTAssertEqual(methods().filter { $0 == "PRACK" }.count, 1); XCTAssertEqual(events, ["prov100", "prov183"])
        dialog.handle(try serverResponse(180, "Ringing"))
        XCTAssertEqual(events, ["prov100", "prov183", "prov180"])
        dialog.handle(try serverResponse(200, "OK", extra: [("Content-Type", "application/sdp")], body: "v=0\r\n"))
        XCTAssertEqual(dialog.state, .confirmed); XCTAssertEqual(events.last, "answered")
        let ack = sent.last!
        XCTAssertEqual(ack.method, "ACK"); XCTAssertEqual(ack.header("cseq"), "1 ACK"); XCTAssertEqual(ack.requestURI, "sip:peer@198.51.100.1:5060")
        XCTAssertEqual(ack.header("to")?.hasSuffix(";tag=srv1"), true)
        dialog.handle(try serverResponse(200, "OK"))   // duplicate 200
        XCTAssertEqual(methods().filter { $0 == "ACK" }.count, 2); XCTAssertEqual(events.filter { $0 == "answered" }.count, 1)
        // remote BYE
        let bye = try byeRequest(from: dialog, cseq: 1, fromTag: "srv1")
        dialog.handle(bye)
        XCTAssertEqual(sent.last?.status, 200); XCTAssertEqual(events.last, "ended:remoteHangup"); XCTAssertEqual(dialog.state, .terminated)
    }

    func byeRequest(from dialog: CallingDialog, cseq: Int, fromTag: String) throws -> CallingSIPMessage {
        let invite = sent.first { $0.method == "INVITE" }!
        let localTag = CallingSIPMessage.parameter("tag", in: invite.header("from")!) ?? ""
        let raw = try CallingSIPMessage.encode("BYE sip:abc@abc.invalid;transport=ws SIP/2.0", headers: [
            ("Via", "SIP/2.0/TLS 198.51.100.1;branch=z9hG4bKsrv"), ("From", "<sip:line1@samsungims.com>;tag=\(fromTag)"),
            ("To", "<sip:line1@samsungims.com>;tag=\(localTag)"), ("Call-ID", dialog.callID), ("CSeq", "\(cseq) BYE")])
        var stream = CallingSIPStream(); try stream.append(raw); return try stream.next()!
    }

    func testForkedProvisionalsThenFinalFromAnotherTag() throws {
        let dialog = make()
        try dialog.startOutgoing(target: "sip:t", number: "123", offer: "")
        dialog.handle(try serverResponse(180, "Ringing", toTag: "forkA", extra: [("Record-Route", "<sip:rrA;lr>")]))
        dialog.handle(try serverResponse(183, "Session Progress", toTag: "forkB", extra: [("Record-Route", "<sip:rrB;lr>")], body: "v=0\r\n"))
        dialog.handle(try serverResponse(200, "OK", toTag: "forkC", extra: [("Record-Route", "<sip:rrC;lr>"), ("Content-Type", "application/sdp")], body: "v=0\r\n"))
        XCTAssertEqual(dialog.state, .confirmed); XCTAssertEqual(dialog.remoteTag, "forkC")
        XCTAssertEqual(events.last, "answered")
        let ack = sent.last!
        XCTAssertEqual(ack.method, "ACK"); XCTAssertEqual(ack.header("to")?.hasSuffix(";tag=forkC"), true)
        XCTAssertEqual(ack.values("route"), ["<sip:rrC;lr>"])      // route set comes from the confirming 200, not the early forks
        dialog.hangUp()
        XCTAssertEqual(sent.last?.method, "BYE"); XCTAssertEqual(sent.last?.header("to")?.hasSuffix(";tag=forkC"), true)
    }

    func test200WithoutAnyProvisionalAndAfterReliable183() throws {
        let direct = make()
        try direct.startOutgoing(target: "sip:t", number: "123", offer: "")
        direct.handle(try serverResponse(200, "OK", extra: [("Content-Type", "application/sdp")], body: "v=0\r\n"))
        XCTAssertEqual(direct.state, .confirmed); XCTAssertEqual(events, ["answered"]); XCTAssertEqual(methods(), ["INVITE", "ACK"])
        let reliable = make()
        try reliable.startOutgoing(target: "sip:t", number: "123", offer: "")
        reliable.handle(try serverResponse(183, "Session Progress", toTag: "e1", extra: [("Require", "100rel"), ("RSeq", "1"), ("Content-Type", "application/sdp")], body: "v=0\r\n"))
        reliable.handle(try serverResponse(200, "OK", toTag: "e1", extra: [("Content-Type", "application/sdp")], body: "v=0\r\n"))
        XCTAssertEqual(methods(), ["INVITE", "PRACK", "ACK"]); XCTAssertEqual(events, ["prov183", "answered"])
        XCTAssertEqual(sent[1].header("cseq"), "2 PRACK"); XCTAssertEqual(sent[2].header("cseq"), "1 ACK")
        // retransmitted 200 after ACK is re-acknowledged, never surfaced twice
        reliable.handle(try serverResponse(200, "OK", toTag: "e1"))
        XCTAssertEqual(methods().suffix(1), ["ACK"]); XCTAssertEqual(events.filter { $0 == "answered" }.count, 1)
    }

    func testCompactHeaderFormsAreNormalized() throws {
        let dispatcher = CallingSIPDispatcher { _ in }
        let dialog = make()
        dispatcher.register(dialog: dialog)
        try dialog.startOutgoing(target: "sip:t", number: "123", offer: "")
        let invite = sent[0]
        let tag = "cmp1"
        let lines = ["SIP/2.0 200 OK", "v: SIP/2.0/WS abc.invalid;branch=\(invite.branch ?? "")", "f: \(invite.header("from") ?? "")",
                     "t: \(invite.header("to") ?? "");tag=\(tag)", "i: \(dialog.callID)", "CSeq: 1 INVITE", "m: <sip:peer@198.51.100.1>", "l: 0", "", ""]
        let raw = lines.joined(separator: "\r\n")
        var stream = CallingSIPStream(); try stream.append(Data(raw.utf8))
        let response = try stream.next()!
        XCTAssertEqual(response.callID, dialog.callID); XCTAssertEqual(response.tag(of: "to"), tag)
        dispatcher.handle(response)       // routed by the compact Call-ID
        XCTAssertEqual(dialog.state, .confirmed); XCTAssertEqual(events, ["answered"])
    }

    func testConfirmedForkDoesNotInheritEarlyRouteAndKeepsEarlySDP() throws {
        let dialog = make()
        var answered: String?
        dialog.onEvent = { if case .answered(let sdp) = $0 { answered = sdp } }
        try dialog.startOutgoing(target: "sip:t", number: "123", offer: "")
        dialog.handle(try serverResponse(183, "Session Progress", toTag: "early", extra: [("Record-Route", "<sip:early-proxy;lr>")], body: "v=0\r\n"))
        dialog.handle(try serverResponse(200, "OK", toTag: "winner"))
        XCTAssertEqual(dialog.remoteTag, "winner"); XCTAssertEqual(answered, "v=0\r\n")
        XCTAssertFalse(sent.last!.values("route").contains("<sip:early-proxy;lr>"))
    }

    func testAdditionalAnsweredForkIsAckedAndClosedWithoutReplacingWinner() throws {
        let dialog = make()
        try dialog.startOutgoing(target: "sip:t", number: "123", offer: "")
        dialog.handle(try serverResponse(200, "OK", toTag: "winner"))
        dialog.handle(try serverResponse(200, "OK", toTag: "other", extra: [("Record-Route", "<sip:other-proxy;lr>")]))
        XCTAssertEqual(dialog.remoteTag, "winner"); XCTAssertEqual(dialog.state, .confirmed)
        XCTAssertEqual(events.filter { $0 == "answered" }.count, 1)
        XCTAssertEqual(Array(methods().suffix(2)), ["ACK", "BYE"])
        XCTAssertEqual(sent.last?.header("to")?.hasSuffix(";tag=other"), true)
        dialog.handle(try serverResponse(200, "OK", toTag: "other"))
        XCTAssertEqual(methods().filter { $0 == "BYE" }.count, 1)
        dialog.handle(try serverResponse(200, "OK", toTag: "winner"))
        XCTAssertEqual(sent.last?.header("to")?.hasSuffix(";tag=winner"), true)
    }

    func testReliableProvisionalsAreAcknowledgedPerFork() throws {
        let dialog = make()
        try dialog.startOutgoing(target: "sip:t", number: "123", offer: "")
        for tag in ["first", "second"] {
            dialog.handle(try serverResponse(183, "Session Progress", toTag: tag, extra: [("Require", "100rel"), ("RSeq", "1")]))
            XCTAssertEqual(sent.last?.method, "PRACK")
            XCTAssertEqual(sent.last?.header("to")?.hasSuffix(";tag=" + tag), true)
        }
        XCTAssertEqual(methods().filter { $0 == "PRACK" }.count, 2)
    }

    func testBusyAndFailureAckUsesSameTransaction() throws {
        let dialog = make()
        try dialog.startOutgoing(target: "sip:t", number: "123", offer: "")
        let invite = sent[0]
        dialog.handle(try serverResponse(486, "Busy Here"))
        let ack = sent.last!
        XCTAssertEqual(ack.method, "ACK"); XCTAssertEqual(ack.branch, invite.branch); XCTAssertEqual(ack.requestURI, "sip:t")
        XCTAssertEqual(events, ["ended:failed(486, \"Busy Here\")"])
    }

    func testCancelWaitsForProvisionalThenSends() throws {
        let dialog = make()
        try dialog.startOutgoing(target: "sip:t", number: "123", offer: "")
        dialog.cancel()
        XCTAssertEqual(methods(), ["INVITE"])          // RFC 3261: never CANCEL before a provisional
        dialog.handle(try serverResponse(100, "Trying", toTag: nil))
        XCTAssertEqual(methods(), ["INVITE", "CANCEL"])
        dialog.handle(try serverResponse(180, "Ringing"))
        XCTAssertEqual(methods(), ["INVITE", "CANCEL"])
        XCTAssertEqual(sent[1].branch, sent[0].branch); XCTAssertEqual(sent[1].header("cseq"), "1 CANCEL")
        XCTAssertEqual(events, [])                      // the provisional is not surfaced after cancel
        dialog.handle(try serverResponse(487, "Request Terminated"))
        XCTAssertEqual(methods().suffix(1), ["ACK"]); XCTAssertEqual(events, ["ended:cancelledByCaller"])
    }

    func testCancelCrossing200SendsAckThenBye() throws {
        let dialog = make()
        try dialog.startOutgoing(target: "sip:t", number: "123", offer: "")
        dialog.handle(try serverResponse(180, "Ringing"))
        dialog.cancel()
        dialog.handle(try serverResponse(200, "OK"))
        XCTAssertEqual(methods(), ["INVITE", "CANCEL", "ACK", "BYE"])
        XCTAssertFalse(events.contains("answered"))
        let bye = sent.last!
        XCTAssertEqual(bye.header("cseq"), "2 BYE")
        dialog.handle(try serverResponse(200, "OK", toTag: "srv1", to: bye))
        XCTAssertEqual(events, ["prov180", "ended:cancelledByCaller"])
    }

    func testLocalHangupSendsByeAndWaitsFor200() throws {
        let dialog = make()
        try dialog.startOutgoing(target: "sip:t", number: "123", offer: "")
        dialog.handle(try serverResponse(200, "OK"))
        dialog.hangUp()
        let bye = sent.last!
        XCTAssertEqual(bye.method, "BYE"); XCTAssertEqual(bye.requestURI, "sip:peer@198.51.100.1:5060")
        XCTAssertEqual(dialog.state, .ending)
        dialog.handle(try serverResponse(200, "OK", to: bye))
        XCTAssertEqual(events.last, "ended:localHangup")
    }

    func inviteRequest(callID: String = "in-1@x") throws -> CallingSIPMessage {
        let raw = try CallingSIPMessage.encode("INVITE sip:abc@abc.invalid;transport=ws SIP/2.0", headers: [
            ("Via", "SIP/2.0/TLS 198.51.100.1;branch=z9hG4bKin"), ("Max-Forwards", "69"),
            ("From", "\"0123456789\" <sip:remote@samsungims.com>;tag=rt1"), ("To", "<sip:line1@samsungims.com>"),
            ("Call-ID", callID), ("CSeq", "1 INVITE"), ("Contact", "<sip:remote@198.51.100.1:5061>"),
            ("Record-Route", "<sip:rr1;lr>"), ("Cmc-Mno", ";call-slot=0"), ("Content-Type", "application/sdp")], body: Data("v=0\r\n".utf8))
        var stream = CallingSIPStream(); try stream.append(raw); return try stream.next()!
    }
    func inDialog(_ method: String, cseq: Int, callID: String = "in-1@x", toTag: String) throws -> CallingSIPMessage {
        let raw = try CallingSIPMessage.encode("\(method) sip:abc@abc.invalid;transport=ws SIP/2.0", headers: [
            ("Via", "SIP/2.0/TLS 198.51.100.1;branch=z9hG4bKx\(cseq)\(method)"), ("From", "\"0123456789\" <sip:remote@samsungims.com>;tag=rt1"),
            ("To", "<sip:line1@samsungims.com>;tag=\(toTag)"), ("Call-ID", callID), ("CSeq", "\(cseq) \(method)")])
        var stream = CallingSIPStream(); try stream.append(raw); return try stream.next()!
    }

    func testIncomingAcceptAckAndRemoteBye() throws {
        let dialog = make(.callee, callID: "in-1@x")
        dialog.receiveInvite(try inviteRequest())
        XCTAssertEqual(dialog.displayName, "0123456789")
        dialog.sendRinging()
        let ringing = sent.last!
        XCTAssertEqual(ringing.status, 180); XCTAssertEqual(ringing.values("record-route"), ["<sip:rr1;lr>"])
        let tag = ringing.tag(of: "to")!
        dialog.accept(answerSDP: "v=0\r\n")
        XCTAssertEqual(sent.last?.status, 200); XCTAssertEqual(sent.last?.bodyText, "v=0\r\n"); XCTAssertEqual(sent.last?.tag(of: "to"), tag)
        XCTAssertEqual(dialog.state, .incomingAccepted)
        dialog.handle(try inDialog("ACK", cseq: 1, toTag: tag))
        XCTAssertEqual(dialog.state, .confirmed); XCTAssertEqual(events, ["answered"])
        dialog.handle(try inDialog("INFO", cseq: 2, toTag: tag)); XCTAssertEqual(sent.last?.status, 200)
        dialog.handle(try inDialog("BYE", cseq: 3, toTag: tag))
        XCTAssertEqual(sent.last?.status, 200); XCTAssertEqual(events.last, "ended:remoteHangup")
    }

    func testIncomingDeclineAndRemoteCancelAndOutOfOrderCSeq() throws {
        let declined = make(.callee, callID: "in-1@x")
        declined.receiveInvite(try inviteRequest())
        declined.decline()
        XCTAssertEqual(sent.last?.status, 603); XCTAssertEqual(events, ["ended:declined"])

        let cancelled = make(.callee, callID: "in-1@x")
        cancelled.receiveInvite(try inviteRequest())
        cancelled.sendRinging()
        let tag = sent.last!.tag(of: "to")!
        cancelled.handle(try inDialog("CANCEL", cseq: 1, toTag: tag))
        XCTAssertEqual(sent.suffix(2).compactMap { $0.status }, [200, 487])
        XCTAssertEqual(sent.suffix(2).first?.cseqParts?.1, "CANCEL"); XCTAssertEqual(sent.last?.cseqParts?.1, "INVITE")
        XCTAssertEqual(events, ["ended:remoteCancelled"])

        let ordered = make(.callee, callID: "in-1@x")
        ordered.receiveInvite(try inviteRequest())
        ordered.sendRinging(); let t = sent.last!.tag(of: "to")!
        ordered.accept(answerSDP: "v=0\r\n")
        ordered.handle(try inDialog("ACK", cseq: 1, toTag: t))
        ordered.handle(try inDialog("INFO", cseq: 5, toTag: t))
        ordered.handle(try inDialog("INFO", cseq: 4, toTag: t))   // lower than the last request: rejected
        XCTAssertEqual(sent.last?.status, 500)
    }

    func testDispatcherNeverLosesInviteDuringRegisterAndRoutesByTransaction() async throws {
        var wire: [Data] = []
        let dispatcher = CallingSIPDispatcher { wire.append($0) }
        var invites: [CallingSIPMessage] = []
        dispatcher.onRequest = { invites.append($0) }
        let branch = CallingSIPBuild.newBranch()
        let pendingTask = Task { try await dispatcher.request("REGISTER sip:samsungims.com SIP/2.0", headers: [
            ("Via", "SIP/2.0/WS a.invalid;branch=\(branch)"), ("To", "<sip:l@h>"), ("From", "<sip:l@h>;tag=1"), ("Call-ID", "reg-1"), ("CSeq", "1 REGISTER")], branch: branch, method: "REGISTER", timeout: 5) }
        try await Task.sleep(nanoseconds: 50_000_000)
        // An INVITE arrives while the REGISTER is outstanding, then a wrongly-correlated 200, then the right one.
        dispatcher.handle(try inviteRequest(callID: "during-register"))
        XCTAssertEqual(invites.count, 1)
        let wrong = try CallingSIPMessage.encode("SIP/2.0 200 OK", headers: [("Via", "SIP/2.0/WS a.invalid;branch=z9hG4bKother"), ("Call-ID", "reg-1"), ("CSeq", "1 REGISTER")])
        let right = try CallingSIPMessage.encode("SIP/2.0 200 OK", headers: [("Via", "SIP/2.0/WS a.invalid;branch=\(branch)"), ("Call-ID", "reg-1"), ("CSeq", "1 REGISTER"), ("Expires", "1800")])
        var stream = CallingSIPStream(); try stream.append(wrong + right)
        dispatcher.handle(try stream.next()!)
        XCTAssertEqual(dispatcher.stats.unmatched, 1)
        dispatcher.handle(try stream.next()!)
        let response = try await pendingTask.value
        XCTAssertEqual(response.status, 200); XCTAssertEqual(response.header("expires"), "1800")
        // OPTIONS gets an automatic 200
        let options = try CallingSIPMessage.encode("OPTIONS sip:x SIP/2.0", headers: [("Via", "SIP/2.0/TLS h;branch=z9hG4bKo"), ("From", "<sip:s@h>;tag=1"), ("To", "<sip:x@h>"), ("Call-ID", "opt-1"), ("CSeq", "1 OPTIONS")])
        var os = CallingSIPStream(); try os.append(options)
        dispatcher.handle(try os.next()!)
        try await Task.sleep(nanoseconds: 50_000_000)
        var out = CallingSIPStream(); for d in wire { try out.append(d) }
        var codes: [Int] = []; while let m = try out.next() { if let c = m.status { codes.append(c) } }
        XCTAssertEqual(codes, [200])
        XCTAssertEqual(invites.count, 1)
        dispatcher.shutdown()
        XCTAssertTrue(dispatcher.closed)
    }

    func testDispatcherRoutesDialogMessagesAndCleansUpOnDisconnect() async throws {
        let dispatcher = CallingSIPDispatcher { _ in }
        let dialog = make(.callee, callID: "in-1@x")
        dispatcher.register(dialog: dialog)
        dialog.receiveInvite(try inviteRequest())
        dialog.sendRinging(); let tag = sent.last!.tag(of: "to")!
        dispatcher.handle(try inDialog("CANCEL", cseq: 1, toTag: tag))   // routed by Call-ID, not to onRequest
        XCTAssertEqual(events, ["ended:remoteCancelled"])
        let second = make(.caller)
        dispatcher.register(dialog: second)
        XCTAssertEqual(dispatcher.activeDialogCount, 2)
        dispatcher.shutdown(ContinuityError.message("test"))
        XCTAssertEqual(dispatcher.activeDialogCount, 0)
    }

    func testPendingRequestFailsWhenConnectionDrops() async throws {
        let dispatcher = CallingSIPDispatcher { _ in }
        let branch = CallingSIPBuild.newBranch()
        let pending = Task { try await dispatcher.request("REGISTER sip:h SIP/2.0", headers: [("Via", "SIP/2.0/WS a;branch=\(branch)"), ("Call-ID", "c"), ("CSeq", "1 REGISTER")], branch: branch, method: "REGISTER", timeout: 5) }
        try await Task.sleep(nanoseconds: 50_000_000)
        dispatcher.shutdown(ContinuityError.message("dropped"))
        do { _ = try await pending.value; XCTFail("must fail") } catch { XCTAssertTrue(error.localizedDescription.contains("dropped")) }
    }
    func outgoingUpdate(_ dialog: CallingDialog, cseq: Int, body: String?) throws -> CallingSIPMessage {
        let initial = sent.first { $0.method == "INVITE" }!
        let packet = try CallingSIPMessage.encode("UPDATE sip:local@192.0.2.1 SIP/2.0", headers: [
            ("Via", "SIP/2.0/TLS edge.invalid;branch=update\(cseq)"),
            ("From", "<sip:remote@198.51.100.1>;tag=srv1"),
            ("To", initial.header("from")!), ("Call-ID", dialog.callID), ("CSeq", "\(cseq) UPDATE"),
            ("Contact", "<sip:refreshed@198.51.100.8>"), ("Content-Type", "application/sdp")], body: Data((body ?? "").utf8))
        var stream = CallingSIPStream(); try stream.append(packet); return try XCTUnwrap(stream.next())
    }

    func testEarlyUpdateOfferMustBeAnsweredBeforeFinalInvite() throws {
        let dialog = make()
        try dialog.startOutgoing(target: "sip:line@host", number: "123", offer: "v=0\r\n")
        dialog.handle(try serverResponse(183, "Progress", extra: [("Require", "100rel"), ("RSeq", "1")], body: "early-sdp"))
        let n = sent.count
        dialog.handle(try outgoingUpdate(dialog, cseq: 1, body: "updated-offer"))
        XCTAssertEqual(sent.count, n, "Do not send an empty 200 to an SDP offer")
        XCTAssertEqual(events.last, "update"); XCTAssertEqual(dialog.state, .early)
        dialog.answerUpdate(sdp: "updated-answer")
        XCTAssertEqual(sent.last?.status, 200); XCTAssertEqual(sent.last?.cseqParts?.1, "UPDATE")
        XCTAssertEqual(sent.last?.header("content-type"), "application/sdp")
        XCTAssertEqual(sent.last?.bodyText, "updated-answer")
        dialog.handle(try serverResponse(200, "OK"))
        XCTAssertEqual(dialog.state, .confirmed); XCTAssertEqual(events.last, "answered")
        XCTAssertEqual(dialog.remoteSDP, "updated-offer")
        XCTAssertEqual(sent.last?.method, "ACK")
    }

    func testUpdateRefreshWithoutSDPAndRejectedOffer() throws {
        let dialog = make()
        try dialog.startOutgoing(target: "sip:line@host", number: "123", offer: "v=0\r\n")
        dialog.handle(try serverResponse(180, "Ringing"))
        dialog.handle(try outgoingUpdate(dialog, cseq: 1, body: nil))
        XCTAssertEqual(sent.last?.status, 200); XCTAssertNil(sent.last?.bodyText)
        dialog.handle(try outgoingUpdate(dialog, cseq: 2, body: "unsupported"))
        dialog.answerUpdate(sdp: nil)
        XCTAssertEqual(sent.last?.status, 488); XCTAssertEqual(dialog.state, .early)
        XCTAssertNil(dialog.remoteSDP)
    }

    func testIncomingHangupCompletesOnByeResponse() throws {
        let dialog = make(.callee, callID: "in-1@x")
        dialog.receiveInvite(try inviteRequest()); dialog.accept(answerSDP: "v=0\r\n")
        dialog.handle(try inDialog("ACK", cseq: 1, toTag: sent.last!.tag(of: "to")!))
        XCTAssertEqual(dialog.state, .confirmed)
        dialog.hangUp(); let bye = try XCTUnwrap(sent.last)
        XCTAssertEqual(bye.method, "BYE"); XCTAssertEqual(dialog.state, .ending)
        dialog.handle(try serverResponse(200, "OK", to: bye))
        XCTAssertEqual(dialog.state, .terminated); XCTAssertEqual(dialog.endReason, .localHangup)
    }

}
