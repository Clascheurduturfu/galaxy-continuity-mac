# Samsung CMC Calling (SIP/TLS, SDP, AMR-WB & SRTP)

Galaxy Continuity implements a native macOS client for **Samsung Call & Text on Other Devices (CMC)** across 17 dedicated source files in `Sources/ContinuityCore/Calling*.swift`. Calls work over Wi-Fi and the Internet through Samsung's IMS infrastructure without relying on Bluetooth Hands-Free Profile (HFP).

---

## 1. Account Discovery & Reversible Secondary Enrollment

Extracted from Samsung Phone (`1.1.15.0`) `profilegate` and `sipjs-wrapper`:

1. **Phone OAuth Token:** Uses the Samsung account session to request an access token for the Samsung Phone service client (omitting `offline.access`, which Samsung's Phone OAuth configuration rejects).
2. **ACS & Entitlement Discovery:**
   - `GET /1.0/users/{user}/localacsaddress`
   - `GET /1.0/defaultentitlementserveraddress`
   - `GET /1.0/users/{user}/lines/{line}/deviceconfiguration` (identifying the primary `Phone` device to retrieve the active `lineID` and `pcscf_address_list`).
3. **Deterministic, Journaled `pc_` Enrollment (`CallingService.swift`):**
   - Derives a deterministic `pc_` UUIDv5 device ID specific to the Mac.
   - Enrolls under `/1.0/users/{user}/lines/{line}/devices` and records a private cleanup journal (`cmc-pending-cleanup.json`, mode `0600`) so the Mac's temporary calling registration is cleanly removed when calling is turned off, when the app quits, or on the next launch after an unexpected exit.
   - Never modifies or removes the primary phone or any Galaxy Book registration.

---

## 2. SIP/TLS Signaling & Subscriptions

```mermaid
sequenceDiagram
    participant Mac as Mac (CallingRegistrar / Dialog)
    participant PCSCF as Samsung IMS P-CSCF (TLS)
    participant Phone as Primary Galaxy Phone

    Mac->>PCSCF: TLS Connect + Unregister stale contact (Expires: 0)
    PCSCF-->>Mac: 200 OK
    Mac->>PCSCF: REGISTER (Access_Token, Auth-Server-Url, +sip.instance urn:duid, pc-client=1, cmc-version=2.0)
    PCSCF-->>Mac: 200 OK (Service-Route, pub-gruu, Expires: 3600)
    Mac->>PCSCF: SUBSCRIBE (Event: reg) & SUBSCRIBE (Event: dialog)
    PCSCF-->>Mac: 200 OK + NOTIFY (reginfo / dialog-info)
    Note over Mac,PCSCF: Outgoing Call Flow
    Mac->>PCSCF: INVITE sip:<line>@samsungims.com;gr=urn:duid:<primary-duid><br/>(From displayName = dialed number, P-Early-Media: supported, SDP AMR-WB/SDES)
    PCSCF-->>Mac: 100 Trying / 183 Session Progress (100rel)
    Mac->>PCSCF: PRACK (with RAck)
    PCSCF-->>Mac: 200 OK (PRACK)
    Note over Mac,PCSCF: Early Media Silence Keepalive (AMR-WB encrypted silence)
    PCSCF->>Mac: UPDATE (with updated SDP offer)
    Mac-->>PCSCF: 200 OK (with negotiated SDP answer, RFC 3311 §5.2)
    PCSCF-->>Mac: 200 OK (INVITE)
    Mac->>PCSCF: ACK
    Note over Mac,Phone: Bidirectional SRTP (AMR-WB 16 kHz, 20 ms frames)
```

### Key Wire Details
- **Transport:** TLS connection to the configured P-CSCF `host:port` (whereas the Electron app on Galaxy Book uses a local `ws://127.0.0.1` bridge to TLS, the Mac speaks TLS directly while preserving the `SIP/2.0/WS` Via/Contact compatibility tokens expected by Samsung's IMS proxy).
- **Compact SIP Headers:** Samsung's IMS servers use compact SIP headers (`i` for `Call-ID`, `v` for `Via`, `f` for `From`, `t` for `To`, `c` for `Content-Type`, `l` for `Content-Length`, `m` for `Contact`, `k` for `Supported`). `CallingSIP.swift` normalizes all compact headers before transaction and dialog correlation.
- **Dial Target:** Outgoing `INVITE` sets Request-URI and `To` to `sip:<line>@samsungims.com;gr=urn:duid:<primary-device-id>` and places the normalized recipient phone number in the `From` display name (`User-Agent: browserCall`).
- **RFC 3311 Early `UPDATE`:** During outgoing call setup, Samsung's network sends an in-dialog `UPDATE` carrying a fresh SDP offer before the final `200 OK (INVITE)`. Replying with an empty `200 OK` causes the call to stay stuck in ringing. `CallingDialog` and `CallingSDP` generate a full negotiated SDP answer in the `200 OK (UPDATE)` while keeping the advertised local UDP socket and send key stable.

---

## 3. Media Path: SDP, AMR-WB, SRTP & Core Audio

- **Why AMR-WB/SDES Instead of Opus/DTLS:** In Samsung Phone on Windows, `CwmgNodeMediagateway` creates both a `pd` channel (AMR-WB over SDES SRTP) and an `sd` channel (Opus over DTLS), bridging WebRTC in Electron to the native gateway. `networkSendOfferModifier` replaces the browser's WebRTC offer with `cmcLocalSdp` (AMR-WB/SDES). By targeting the AMR-WB/SDES network leg directly, the Mac avoids the internal Electron loopback bridge.
- **SDP & RFC 4867 Bandwidth-Efficient Framing:**
  - Negotiates `AMR-WB/16000` (typically payload type `116`) and `telephone-event/16000` (payload type `120`) over `RTP/SAVP` with `ptime: 20`.
  - Because Samsung's SDP omits `octet-align=1`, RFC 4867 defaults to **bandwidth-efficient** bit packing. `CallingMedia.swift` supports both bandwidth-efficient and octet-aligned AMR-WB framing.
- **SDES SRTP:** Supports `AES_CM_128_HMAC_SHA1_80` and `AES_CM_128_HMAC_SHA1_32` via Cisco `libsrtp 2.6.0` with independent 30-byte master key + salt per direction.
- **Early Media NAT Keepalive:** During early media (`183 Session Progress`), the Mac sends encrypted AMR-WB silence frames every 20 ms to open the UDP return path without reading from the microphone until the `INVITE` is answered.
- **macOS `VoiceProcessingIO` (`CallingAudio.swift`):** Configures `AVAudioEngine` with echo cancellation (`setVoiceProcessingEnabled(true)`), explicitly matching client input/output stream formats to avoid Core Audio error `-10875` on multi-channel MacBook microphone arrays, and resamples channel 0 to 16 kHz mono `Int16` (`320` samples per 20 ms frame).
