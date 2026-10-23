# 2026-10-22 — Samsung CMC SIP/SDP/SRTP Implementation & Registration

## Modules Delivered

- `CallingSIPDispatcher.swift`: Ordered send queue, Via branch + CSeq transaction correlation, Call-ID dialog routing, automatic `200 OK` to `OPTIONS`, and sanitized trace mode (`CMC_CALL_TRACE=1`).
- `CallingRegistration.swift`: TLS connection across P-CSCF candidates, stock unregister-then-register sequence, `reg` (`application/reginfo+xml`) and `dialog` (`application/dialog-info+xml`) `SUBSCRIBE` refresh, negotiated expiry re-REGISTER at 60% lifetime, and 120-second CRLF keepalives.
- `CallingDialog.swift`: UAC and UAS dialog state machine (`INVITE`, `100rel` `PRACK` + `RAck`, `2xx` `ACK`, `CANCEL`, `BYE`, `603 Decline`, and DTMF `INFO`).
- `CallingSDP.swift`: Offer/answer negotiation for `AMR-WB/16000` (`116`) + `telephone-event/16000` (`120`) over `RTP/SAVP` with SDES key validation.
- `CallingMediaSession.swift`: BSD UDP socket, bounded `CallingPCMRing`, `CallingJitterBuffer` (reordering, wrap, duplicate suppression, loss concealment), and 20 ms AMR-WB + SRTP cadence.
- `CallingAudio.swift`: `AVAudioEngine` microphone capture and `AVAudioSourceNode` playback with `VoiceProcessingIO`.
- `CallingPresence.swift`: Floating macOS incoming-call banner across Spaces and automatic unregistration on app quit.

---

## Live Registration Verification

- Enrolled deterministic Mac `pc_` device, connected over TLS to the primary P-CSCF, completed unregister-first (`200 OK`) followed by `REGISTER` (`200 OK`, `Expires: 3600`), and verified `SUBSCRIBE` (`reg` and `dialog`) both returned `200 OK` followed by `NOTIFY` events.
- Verified mid-session re-REGISTER and clean unregister + journaled device removal on stop.
