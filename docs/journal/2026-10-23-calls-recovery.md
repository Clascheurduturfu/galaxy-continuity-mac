# 2026-10-23 — Calls Recovery, Early UPDATE SDP & Two-Way Audio Verification

## Issues Diagnosed & Fixed

1. **Compact SIP Header Normalization (`CallingSIP.swift`):**
   - Samsung's IMS servers return compact SIP headers (`i` for `Call-ID`, `v` for `Via`, `f` for `From`, `t` for `To`, `m` for `Contact`, `c` for `Content-Type`, `l` for `Content-Length`). Normalizing compact headers ensured final `200 OK` responses were routed to the active dialog.
2. **Core Audio `-10875` on Multi-Channel Mac Microphones (`CallingAudio.swift`):**
   - MacBook microphone arrays expose 9 capture channels, causing `VoiceProcessingIO` startup to fail with `-10875` when client input/output formats were mismatched.
   - Explicitly requesting a mono processed microphone stream at the hardware output sample rate and resampling channel 0 (`CallingCaptureConverter.swift`) resolved the error with voice processing confirmed active.
3. **RFC 3311 Early `UPDATE` SDP Answer (`CallingDialog.swift` & `CallingService.swift`):**
   - During outgoing call setup, the network sent an in-dialog `UPDATE` carrying a new SDP offer after `183 Session Progress` / `PRACK`. Replying with an empty `200 OK` left the outgoing call stuck in ringing.
   - Generating and returning a negotiated SDP answer in the `200 OK (UPDATE)` response (while keeping the local UDP socket and send key stable) resolved outgoing call completion.
4. **Early Media Encrypted Silence Keepalive (`CallingMediaSession.swift`):**
   - Sending encrypted AMR-WB silence frames during early media opens the NAT/gateway UDP return path without reading from the microphone before the call is answered.
5. **`CANCEL` After `100 Trying`:**
   - Allowed clean `CANCEL` after `100 Trying` even when `180 Ringing` has not yet arrived.

---

## Hardware Verification

- **Incoming Call:** Answering on the Mac, microphone uplink, speaker downlink, and hang-up were all confirmed working on Galaxy S26 Ultra + MacBook.
- **Outgoing Call:** `INVITE` → `183` → `PRACK` → encrypted early media → `UPDATE` with SDP → `200 OK` with SDP → `200 OK (INVITE)` → `ACK` → bidirectional encrypted AMR-WB audio → `BYE` (`200 OK`). Both parties heard each other clearly.
