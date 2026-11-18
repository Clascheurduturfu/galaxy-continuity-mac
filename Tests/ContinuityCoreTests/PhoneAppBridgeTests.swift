import XCTest
@testable import ContinuityCore

@MainActor final class PhoneAppBridgeTests: XCTestCase {
    func testEmergencyGuardBlocksKnownEmergencyShortcodesAndAllowsNormalNumbers() {
        for emergency in ["112", "911", "999", "000", "110", "111", "118", "119", "15", "17", "18", " 112 ", "1-1-2", "*911", "#911", "+112", "+911"] {
            XCTAssertTrue(CallingEmergencyGuard.isEmergencyNumber(emergency), "Expected emergency guard to match \(emergency)")
        }
        for normal in ["", "0612345678", "+33612345678", "01 23 45 67 89", "+1 (555) 123-4567", "*123#"] {
            XCTAssertFalse(CallingEmergencyGuard.isEmergencyNumber(normal), "Unexpected emergency match for \(normal)")
        }
        XCTAssertEqual(CallingEmergencyGuard.sanitizeDigits(" +33 (6) 12-34 56 78 "), "+33612345678")
    }

    func testCallingDialogExtractsRemoteNumberAndDisplayNameFromInviteHeaders() throws {
        let ctx = CallingDialogContext(userID: "line1", viaHost: "abc.invalid", contactURI: "sip:abc@abc.invalid;transport=ws")

        func parseInvite(headers: [(String, String)]) throws -> CallingSIPMessage {
            let raw = try CallingSIPMessage.encode("INVITE sip:abc@abc.invalid;transport=ws SIP/2.0", headers: [
                ("Via", "SIP/2.0/TLS 198.51.100.1;branch=z9hG4bK1"),
                ("To", "<sip:line1@samsungims.com>"),
                ("Call-ID", "call-test@x"),
                ("CSeq", "1 INVITE")
            ] + headers)
            var stream = CallingSIPStream()
            try stream.append(raw)
            return try XCTUnwrap(stream.next())
        }

        // Case 1: P-Asserted-Identity tel URI + quoted display name
        let d1 = CallingDialog(role: .callee, context: ctx, callID: "c1") { _ in }
        d1.receiveInvite(try parseInvite(headers: [
            ("From", "\"Alice\" <sip:unknown@samsungims.com>;tag=t1"),
            ("P-Asserted-Identity", "<tel:+33612345678>")
        ]))
        XCTAssertEqual(d1.displayName, "Alice")
        XCTAssertEqual(d1.remoteNumber, "+33612345678")

        // Case 2: SIP user=phone URI without display name
        let d2 = CallingDialog(role: .callee, context: ctx, callID: "c2") { _ in }
        d2.receiveInvite(try parseInvite(headers: [
            ("From", "<sip:+33698765432@samsungims.com;user=phone>;tag=t2")
        ]))
        XCTAssertEqual(d2.displayName, "")
        XCTAssertEqual(d2.remoteNumber, "+33698765432")

        // Case 3: Display name + SIP user number
        let d3 = CallingDialog(role: .callee, context: ctx, callID: "c3") { _ in }
        d3.receiveInvite(try parseInvite(headers: [
            ("From", "\"Bob\" <sip:+33611223344@samsungims.com>;tag=t3")
        ]))
        XCTAssertEqual(d3.displayName, "Bob")
        XCTAssertEqual(d3.remoteNumber, "+33611223344")
    }
}
