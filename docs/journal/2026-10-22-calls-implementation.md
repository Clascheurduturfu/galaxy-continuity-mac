# 2026-10-22 — Direct Samsung CMC Calling Architecture Brief

## Gateway Reconstruction (`Samsung Phone 1.1.15.0`)

Analysis of Samsung Phone's renderer bundle and native media gateway established how Windows bridges WebRTC to Samsung's IMS network:
- `CwmgNodeMediagateway.createPdChannel` creates a public IPv4 channel using **SDES SRTP** and **AMR-WB** by default.
- `createSdChannel` creates a private IPv4 channel using **DTLS** and **Opus** to bridge audio to the local Electron renderer (`webRtcMediaSession`).
- `networkSendOfferModifier` stores the browser's WebRTC offer locally and returns **`cmcLocalSdp`** (built from the PD channel's AMR-WB/SDES parameters) as the actual SIP offer sent to the P-CSCF.

### Architectural Decision for macOS
Because the Mac app captures and plays audio natively via `AVAudioEngine` rather than inside an Electron WebRTC renderer, it speaks the **AMR-WB/16000 over RTP/SAVP (SDES)** network leg directly without needing an internal Opus/DTLS loopback bridge.

---

## Signaling & Media Contract

- **Dial Target:** `sip:<lineID>@samsungims.com;gr=urn:duid:<primary-device-id>`, with the recipient number placed in the `From` display name (`User-Agent: browserCall`, `P-Early-Media: supported`, `Supported: 100rel`).
- **Registration Headers:** `Auth-Server-Url`, `Access_Token`, `+sip.instance="<urn:duid:...>"`, `pc-client=1`, `i-wlan-node-id`, and `cmc-version=2.0`.
- **AMR-WB Framing:** 20 ms frames (`320` PCM samples at 16 kHz mono), RFC 4867 bandwidth-efficient packing by default when `octet-align` is omitted from SDP `fmtp`.
- **SRTP Suites:** `AES_CM_128_HMAC_SHA1_80` and `AES_CM_128_HMAC_SHA1_32` with independent 30-byte master key + salt per direction.
