> **Beta 2 (51):** Nearby Devices, separate device arrangement/edge switching, per-device hotspot picker, local Mac Contacts, account label, GitHub release-channel updater, Buds deduplication/event-driven watching, original icon and window lifecycle fixes are implemented. See [changes and live acceptance](docs/BETA_2.md). Existing dated checkpoints below are historical.

# Galaxy Continuity — Engineering Roadmap & Checklist

Current stable release: **v1.0 (build 55)**.

Completed verification boundaries are documented in [docs/research/validation.md](docs/research/validation.md), and the architecture and protocol reference index is in [docs/README.md](docs/README.md). Unchecked items below represent open hardening, multi-device edge cases, or unverified protocol surfaces.

---

## 1. Galaxy Buds Auto Switch — Benchmarking & Reliability

### Establish Benefit Over Stock Multipoint
- [x] Implement TWU (`0xFC..0xCC`) RFCOMM framing, feature discovery (`44`), host info (`73`), MDE Auto Switch V3 (`43`), takeover request (`71`), and multipoint status TLV (`0x0117` / `0x0502`).
- [x] Implement opt-in CoreAudio playback watcher that reconnects initially disconnected paired Buds and switches macOS default output.
- [x] Persist selected Buds device and automatic-switching preference across app launches (`UserDefaults`) and expose quick actions in the macOS menu bar (`v1.0 Beta 1`).
- [ ] Compare app fully closed versus app enabled using identical paired devices and initial connection state; record automatic connection, takeover, pause/resume, return behavior, and timing.
- [ ] Isolate plain Bluetooth connection/output selection from Samsung takeover and playback-state commands so stock firmware behavior is distinguished from app-driven switching.
- [ ] Determine what pauses phone playback during takeover (normal Bluetooth/AVRCP behavior vs. Samsung takeover command) without ADB media commands in the loop.
- [ ] Add a third device (Galaxy Tab) to the phone + Mac + Buds setup; test three-device priority, initially disconnected devices, simultaneous playback, phone calls, and return to the previous device.
- [ ] Document user-facing boundaries clearly: what the app adds, what is already stock, what requires prior macOS Bluetooth pairing, and which features require Samsung sign-in.

### Buds Reliability & Lifecycle Hardening
- [ ] Reduce the initial ~1–2 second speaker-audio interval while RFCOMM reconnects on playback start; measure latency before selecting a mitigation.
- [ ] Distinguish sustained media playback from brief notification/system alert sounds so short alerts do not steal Buds audio from the phone.
- [ ] Harden recovery for RFCOMM connection failure, missing/uncached SDP services, interrupted channels, stale callbacks, and out-of-range retry/backoff.
- [ ] Test sleep/wake, Bluetooth off/on, app restart, Buds case open/close, renamed Buds, and additional Galaxy Buds models/firmware.
- [ ] Define switching policy when the phone is actively in a call or playing media; test manual overrides and competing devices.
- [ ] Measure long-session stability, power consumption, and Activity Monitor audio wakeups.
- [ ] Investigate Samsung account/cloud Bluetooth pairing-key synchronization (`SamsungCloudPlatformManager` / `BTDeviceList.txt`) separately for zero-touch first pairing.

---

## 2. Smart Auto-Connect, Account & Auto Hotspot Hardening

- [x] Implement Native Samsung Account sign-in, Continuity OAuth (`boz0m1awhe`), cloud registration, RSA-2048 PKCS#10 CSR enrollment, and token renewal.
- [x] Implement Smart Auto-Connect coordinator (`v1.0 Beta 1`): automatic connection on app launch, passive BLE proximity advertisement trigger, `NSWorkspace.didWakeNotification` wake reconnect, `NWPathMonitor` network recovery, and exponential backoff (`[2, 5, 10, 20, 45, 60]s`) with Pause/Resume.
- [x] Combine account peers, passive multi-peer BLE observations, and `_mcfds._tcp` Bonjour discoveries into a single `NearbyPeerRegistry` with dynamic Galaxy PC port refresh.
- [ ] Validate multi-peer simultaneous discovery and reconnect across sleep/wake, network/range transitions, VPN toggles, and phone restart with Phone + Tablet + Galaxy Book active together.
- [ ] Test certificate/account-key expiry, device-list changes, account revocation, clock skew, canceled login, and refresh rejection while preserving any working profile on failure.
- [ ] Exercise account-region/policy and secondary verification variants; verify sign-out/cancellation cannot be undone by in-flight startup or refresh tasks.
- [ ] Validate Auto Hotspot internet reachability after association, activation rejection codes, 5 GHz/6 GHz/WPA3 band compatibility, Location Services denial handling, and fallback to the previous Wi-Fi network.
- [ ] Implement remote hotspot disconnect/turn-off behavior from the Mac.

---

## 3. Clipboard Continuity (Text, HTML, Images & Files)

- [x] Implement bidirectional Unicode text and HTML clipboard sync over Handler 2 (`Command 4`).
- [x] Implement Wi-Fi command handover (`100/1`), internal AppId `102` `ProtoData` chunked transfer, and Samsung Keyboard `SemImageClipData` archive generation (`KeyboardClipArchive.swift`).
- [x] Verify bidirectional PNG/JPEG image clipboard transfers between Mac, Galaxy S26 Ultra, Galaxy Tab S9+, and Galaxy Book4 Edge over Wi-Fi and phone hotspot.
- [ ] Test HEIC image transfers, repeated large multi-megabyte copies, cancellation mid-transfer, and stale clipboard replacement under lossy Wi-Fi.
- [ ] Evaluate deferred-paste placeholder support (similar to Windows `~ClipboardTransferring.tmp`) so large phone photos only transfer over Wi-Fi when the user presses `⌘V` on the Mac.
- [ ] Investigate general file and multi-file clipboard URI lists (`GET_URI_LIST = 8`, `SET_FILE_URI = 5`) and bounded temporary staging.
- [ ] Re-test reported overseas/remote clipboard scenarios with full transport and writer attribution (separating Samsung Continuity from Phone Link and third-party clipboard tools).

---

## 4. Phone Calls (Samsung CMC over Wi-Fi / Internet)

- [x] Reconstruct ACS/entitlement discovery, reversible Mac `pc_` enrollment with cleanup journal, and SIP/TLS registration to Samsung IMS P-CSCF servers.
- [x] Implement `reg` and `dialog` SIP `SUBSCRIBE` refresh, compact SIP header normalization, UAC/UAS `INVITE` dialogs, `100rel` `PRACK`, and RFC 3311 early `UPDATE` SDP answer negotiation.
- [x] Implement RFC 4867 bandwidth-efficient AMR-WB (16 kHz) + SDES SRTP (`AES_CM_128_HMAC_SHA1_80/32`), early-media encrypted silence NAT keepalive, and macOS `AVAudioEngine` `VoiceProcessingIO` capture/playback.
- [x] Owner-verify incoming and outgoing two-way call audio and hang-up on Galaxy S26 Ultra + Mac, and native overseas CMC call on Galaxy Tab S9+.
- [ ] Live-test incoming and outgoing two-way call audio on the Mac while the phone and Mac are on completely separate Internet connections (e.g., phone on 5G cellular, Mac on home/campus Wi-Fi).
- [ ] Test local call decline (`603`), repeated back-to-back calls, simultaneous ringing/answering with Galaxy Book or tablet, call hold/resume (`re-INVITE`), and audio route switching (Mac speakers ↔ Galaxy Buds) mid-call.
- [ ] Investigate receive-side late packet counters and jitter-buffer tuning over high-latency mobile links.

---

## 5. SMS & MMS Messaging (Samsung NMS)

- [x] Recover `packages/nmsclient` API routes, headers (`x-device-id`, `Access-Token`, `Auth-Server-Url`), message serializers, and subscription handlers from Samsung Phone reference sources.
- [ ] Complete NMS authorization, independent Mac device registration, message-store queries, and token refresh/revocation handling.
- [ ] Build read-only conversation and message browsing in the Mac app first, validating pagination and deduplication.
- [ ] Add explicit user-initiated SMS sending with delivery/error state tracking and MMS attachment support.

---

## 6. Storage Share (Wireless Finder Mount)

- [x] Complete authenticated MCF SDK AppId `10` session negotiation, keepalive (`sessionKeepAliveReq`), on-phone consent, and temporary `ksmbd` credential exchange.
- [x] Implement native macOS `NetFS` mounting at `/Volumes` with a reversible, host-scoped SMB 2 compatibility lease (`SMBCompatibility.swift`) and verify read/write/SHA-256/delete on Galaxy S26 Ultra.
- [ ] Validate handling of pending, denied, and mid-session revoked phone storage permissions, as well as large multi-gigabyte file transfers and sleep/disconnect unmount recovery.
- [ ] Test Mac-to-Galaxy Book Storage Share (mounting a Galaxy Book's advertised SMB share from the Mac).
- [ ] Evaluate exporting a controlled Mac folder to Galaxy phones/Books (acting as an AppId `10` storage server).
- [ ] Add optional storage capacity indicators (`smbStorageCapacityReq/Resp`), thumbnails, and file-change notifications.

---

## 7. Multi Control (Shared Mouse & Keyboard)

- [x] Implement MCF SDK AppId `1` session setup, newline JSON control plane, display layout exchange, and binary `M`/`W`/`C`/`K` input framing over UDP and TCP.
- [x] Move `CGEvent` capture, 6 ms event-driven pacing, AES-CBC encryption, and UDP `sendto` onto a dedicated `.userInteractive` worker thread (`PointerPipeline.swift` / `PointerSender.swift`) with bounded latency telemetry and `(-100, -100)` reserved-vector splitting.
- [x] Implement automatic screen-edge cursor handoff (crossing the Mac display boundary to enter/leave the phone or tablet without clicking "Control Phone").
- [ ] Negotiate Mac-to-Android keyboard layout mapping so non-US keyboard layouts produce matching characters without manual phone layout switching.
- [ ] Compare same-mouse hardware latency and receiver `InputOptimizeHelper` behavior between Galaxy Book and Mac to close the remaining perceived smoothness gap.
- [ ] Investigate cross-device drag-and-drop and file transfer over Multi Control.

---

## 8. Additional Continuity Surfaces & Packaging

- [ ] Triage remaining MCF handler IDs—App Handoff (`3`), Keyboard (`4`), Context (`5`), Resource (`9`), Remote Media (`10`), and My Device (`11`)—to identify which services expose usable cross-device features vs. internal stubs.
- [ ] Evaluate **Second Screen** (`1.16.7.0`) wireless display extension feasibility on macOS (virtual display + video stream).
- [ ] Validate Intel Mac and older macOS (macOS 13–15) runtime compatibility alongside Apple Silicon.
- [ ] Evaluate Developer ID signing, notarization, and sparkle/release distribution for users outside local source builds.

---

## Retired Experiments

- **Bluetooth Hands-Free Profile (HFP) Call Prototype (Retired in v1.0 Beta 1):**
  An early spike (`HandsFree.swift`, `IOBluetoothHandsFreeDevice`) explored routing phone calls over classic Bluetooth HFP/SCO. Because macOS does not expose a reliable public HFP Hands-Free Unit audio path for modern Galaxy phones—and because native **Samsung CMC over Wi-Fi/Internet** (`Calling*.swift`) is now fully implemented and live-validated with two-way AMR-WB/SRTP audio—the Bluetooth HFP experiment has been retired and removed from the codebase.

## v1.0 Beta 3 (53) preview

Automatic nearby account clipboard peers replace manual phone/tablet selection; Clipboard Sync gates both directions while retaining command links for independent features. Buds controls simplified with hover explanations. Private updater token is cleared and its UI hidden after successful public anonymous access. Preview commits, pushes and preview releases are owner-authorized; main/public visibility remain separate. See docs/BETA_3.md for validation and remaining live acceptance.

- [x] Add an optional macOS 14.2+ process-activity filter for system/UI sounds in Buds automatic switching, without audio capture or polling. Browser media versus notifications from the same process remains a separate classification problem.

## v1.0 RC 1 (54)

System-sound exclusion, consistent switch alignment, disabled-control styling, light sidebar contrast and clearer clipboard/connection wording. All eight pages received detailed screenshot review. See [RC 1 validation and remaining acceptance](docs/RC_1.md).


## v1.0 (55) first stable release

Removed the Apple Personal Hotspot research disclosure and temporary private-repository access controls. New installations default to Stable; saved channel preferences remain respected. Promoted the tested RC1 feature set to main. See [v1.0 release notes](docs/V1_0.md) for validation and remaining platform acceptance.
