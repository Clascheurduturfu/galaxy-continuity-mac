# Hardware & Synthetic Validation Matrix

This document summarizes the unit-test and live hardware validation completed across the Galaxy Continuity macOS client through **v1.0 Beta 1 (build 50)**.

---

## 1. Test Environment

- **Mac:** Apple Silicon MacBook (macOS, Apple Swift 6.4).
- **Phone:** Samsung Galaxy S26 Ultra (`SM-S948B`, One UI 9 / Android 17, `MCFDs 4.6.12.16`, `Samsung Keyboard 5.9.40.75`).
- **Tablet:** Samsung Galaxy Tab S9+ (`SM-X810`, One UI / Android 16, `MCFDs 4.6.12.16`).
- **PC:** Samsung Galaxy Book4 Edge (`Snapdragon X Elite ARM64`, `Galaxy Connect 4.6.1217.0`).
- **Earbuds:** Samsung Galaxy Buds3 Pro.

---

## 2. Automated Test Suite (`swift test`)

All **100 XCTest unit and integration tests** pass with zero network or hardware dependencies:

| Test Suite | Tests | Coverage |
|---|---|---|
| `ContinuityCoreTests` | 30 | Bounded protobuf varint/frame parsing, 3-message AES-GCM + P-256 ECDH handshake, inbound account responder proof, PKCS#10 CSR proof-of-possession & tamper rejection, OAuth callback validation, gzip/JSON clipboard metadata, BLE advertisement de-obfuscation, TWU Buds CRC-16/XMODEM framing & multipoint TLV parsing, MCF SDK 3/4/5 key derivation, Storage Share message parsing, scoped SMB 2 compatibility lease & journal recovery, and `0700`/`0600` credential file permissions. |
| `ClipboardTransferTests` | 15 | `ProtoData` chunk encryption/decryption, directly attached subnet verification (RFC 1918, CGNAT, link-local, and public campus LANs), PNG/JPEG/HEIC bounds & megapixel validation, `SemImageClipData` ZIP archive generation, large metadata (`> 20 KiB`), and Wi-Fi command handover (`100/1`) routing. |
| `NearbyPeersTests` | 6 | Account-only vs. radio-nearby state separation, concurrent phone/tablet/PC observations, wrong-account/truncated/ambiguous BLE packet rejection, 40-second observation expiry while preserving active connections, and dynamic PC port updates. |
| `PointerPipelineTests` | 14 | `(-100, -100)` reserved focus-release vector splitting (`PointerVector.safeParts`), 5,000-event 6 ms pacing accuracy, forced flush before click/wheel/key events, TCP fallback ordering, queue overflow bounds, bounded telemetry histograms (`p50`/`p95`/`p99`/`max`), and UDP loopback with `SO_NET_SERVICE_TYPE` readback. |
| `CallingSDPTests` | 10 | AMR-WB/16000 & `telephone-event/16000` SDP offer/answer generation, mode-set intersection, RFC 4867 bandwidth-efficient default, SDES `AES_CM_128_HMAC_SHA1_80/32` key validation, and rejection of insecure or malformed SDP offers. |
| `CallingDialogTests` | 14 | Compact SIP header normalization (`i`, `v`, `f`, `t`, `m`, `c`, `l`, `k`), `CallingSIPDispatcher` transaction correlation, UAC/UAS `INVITE`, reliable `183` + `PRACK` (`RAck`), RFC 3311 early `UPDATE` SDP offer/answer, `CANCEL` after `100 Trying`, `CANCEL` crossing `200 OK`, and `BYE` completion. |
| `CallingSessionTests` | 11 | `CallingPCMRing` and `CallingJitterBuffer` reordering/loss concealment, multi-channel (`1`/`2`/`5`/`9` ch) `Float32`/`Int16` microphone resampling to 16 kHz mono, encrypted two-session SRTP/AMR-WB loopback over `127.0.0.1` at 20 ms cadence, tamper/replay rejection, and early-media silence gating. |

---

## 3. Live Hardware Validation Summary

| Subsystem | Live Verification Result | Known Boundaries |
|---|---|---|
| **Native Samsung Sign-In & Enrollment** | Browser login, `boz0m1awhe` PKCE, cloud registration, RSA-2048 CSR enrollment, exact Bluetooth address verification, restart persistence, and forced OAuth + cloud token renewal all passed. | Uses Samsung's private Continuity APIs; account revocation and hardware replacement edge cases remain to be tested. |
| **BLE Discovery & Smart Auto-Connect** | Direct BLE CoC discovery (PSM `128`) and 3-message account authentication with Galaxy S26 Ultra passed repeatedly; idle connection stays open with keep-connection `100/3`. | Multi-peer simultaneous phone + tablet + Galaxy Book roaming and long sleep/wake cycles continue to be hardened. |
| **Text & HTML Clipboard** | Bidirectional Unicode text (`Galaxy Continuity test: café 日本語 🚀`) verified between Mac, Galaxy S26 Ultra, Galaxy Tab S9+, and Galaxy Book4 Edge simultaneously. | Text metadata capped at 64 KiB (decompression capped at 1 MiB). |
| **Image Clipboard** | Bidirectional PNG and JPEG transfers (up to 14 MB) verified byte-exact between Mac, Galaxy S26 Ultra, Galaxy Tab S9+, and Galaxy Book4 Edge over home Wi-Fi and phone hotspot. | Requires shared local Wi-Fi or phone hotspot (macOS does not support Samsung Wi-Fi Direct). General non-image files/folders are out of scope. |
| **Auto Hotspot** | Activation request over MCF returned SSID/password from Galaxy S26 Ultra; macOS CoreWLAN associated automatically after Location Services permission; disabled tablet returned expected code `-6`. | Hotspot auto-disconnect / remote turn-off UI is planned. |
| **Samsung CMC Phone Calls** | Reversible Mac `pc_` enrollment, SIP `REGISTER` 200, `reg`/`dialog` `SUBSCRIBE` 200, incoming call answer with two-way audio, outgoing call with early `183`/`PRACK`/SDP `UPDATE`/`200 OK` and two-way audio, and clean hang-up/unregister all owner-confirmed on Galaxy S26 Ultra + Mac. | Overseas native tablet call confirmed; overseas Mac call across separate networks and call hold/transfer remain to be tested. |
| **Galaxy Buds Auto Switch** | Paired Galaxy Buds3 Pro RFCOMM TWU handshake, multipoint status TLV (`0x0502`), manual takeover, and automatic Mac playback watcher takeover (including from a disconnected Mac start) passed audibly in phone → Mac → phone tests. | Initial ~1–2 s audio plays on Mac speakers while RFCOMM reconnects; brief system alert filtering is on the roadmap. |
| **Storage Share** | MCF AppId 10 session, on-phone consent prompt, temporary `ksmbd` credentials, scoped SMB 2 compatibility lease, `/Volumes/media` Finder mount, and file create/read/SHA-256/delete passed on Galaxy S26 Ultra. | Mounting a Galaxy Book share from Mac and exporting Mac storage to phone/Book are not yet implemented. |
| **Multi Control** | MCF AppId 1 session, display layout, focus handoff, worker-thread 6 ms UDP mouse movement (`0` callback stalls > 20 ms), mouse clicks, typing, shortcuts, and `Escape` release verified on Galaxy S26 Ultra and Galaxy Tab S9+. | Comparative smoothness vs. Galaxy Book, automatic screen-edge crossing, keyboard layout negotiation, and drag-and-drop remain open roadmap items. |
