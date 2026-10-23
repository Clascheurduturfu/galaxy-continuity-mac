# Multi Control (Shared Mouse, Keyboard & Pointer Pipeline)

Samsung **Multi Control** (`2.7.1300.0` on Windows, `com.samsung.android.inputshare` `2.8.02.1` on Android) uses **MCF SDK Application ID 1** to share a computer's mouse and keyboard with a nearby Galaxy phone or tablet.

---

## 1. MCF SDK Session Negotiation (AppId 1)

1. **Command-Channel Bootstrap (`Handler 6 / Command 1`):**
   - Sends `[0x01, 12, 30, 21]` followed by `APInfo` JSON advertising the local Wi-Fi interface (`ARRAY` with actual BSSID, SSID, IPv4, subnet mask, MAC, SDK listener port `PT`, and command listener port `LPT`).
   - Receives `[0x01, 12, 1]` plus the peer's endpoint JSON (`IP`, TCP port, UDP port `LUP`).
2. **Derived Application Key:**
   - Computed as `SHA-256(commandKey_with_first_byte_incremented_by_appID)`.
3. **SDK 3/4/5 Nonce Handshake (`FeatureSession.swift`):**
   - SDK TCP frames use a varint length prefix followed by protobuf fields `1 = type`, `2 = id`, `3 = payload`.
   - Authentication messages `3`, `4`, and `5` exchange IV-prefixed AES-256-CBC JSON and SHA-256 nonce proofs. The connector's nonce becomes the `ET=0` session IV.

---

## 2. Control Plane (Newline-Delimited JSON over TCP)

Control messages on the authenticated TCP channel use JSON objects with `MSG`, `PARAM`, and optional `FROM`:
- `STATUS_LIST`: Must include the Mac's own device entry (derived as a signed 32-bit Java-style hash of the lower-case colon-separated Bluetooth address); an empty list causes Android's inputshare service to throw an index exception and stall layout exchange.
- `DEVICE_INFORMATION`, `NETWORK_INFORMATION`, `WALLPAPER_INFORMATION`: Exchange screen geometry, DPI, and network metadata. On tablets (`SM-X810`), re-sending `DEVICE_INFORMATION` when the peer's `DEVICE_INFORMATION` arrives ensures layout registration completes even if the tablet's listener started slightly later.
- `DEVICE_LAYOUT_CHANGED` & `FOCUS_DEVICE_CHANGED`: Coordinate which screen holds active input focus.
- `MSG_ALIVE_CHECK` / `MSG_ACK_ALIVE_CHECK`: Periodic session keepalive.

---

## 3. Binary Input Framing (`M`, `W`, `C`, `K`)

Input events are encoded in big-endian (network byte order) inside the SDK protobuf envelope:

| Packet | ASCII Tag | Wire Layout | Transport |
|---|---|---|---|
| **Mouse Move** | `M` (`0x4D`) | `M` + signed `Int16` $\Delta X$ + signed `Int16` $\Delta Y$ + `UInt8` elapsed ms (`0` after > 255 ms idle) | UDP (`LUP`) with TCP fallback |
| **Scroll Wheel** | `W` (`0x57`) | `W` + signed `Int16` $\Delta X$ + signed `Int16` $\Delta Y$ + `UInt8` elapsed ms | TCP |
| **Mouse Button** | `C` (`0x43`) | `C` + `UInt8` motion (`0` = down, `1` = up) + `UInt8` button (`1` = left, `2` = right, `3` = middle) | TCP |
| **Keyboard Key** | `K` (`0x4B`) | `K` + `UInt8` motion (`0` = down, `1` = up) + `UInt16` Windows scan code | TCP |

### Reserved `(-100, -100)` Focus-Release Sentinel
In Android `inputinject/e.java`, a mouse move vector of `(-100, -100)` is a reserved sentinel that clears the phone's pending mouse queue rather than moving the cursor (emitted by a Galaxy Book when returning focus to the PC). `PointerPacer.swift` (`PointerVector.safeParts`) automatically splits any coincidental `(-100, -100)` user movement into two half-vectors `(-50, -50)` + `(-50, -50)` so ordinary cursor motion is never discarded.

---

## 4. Dedicated Worker-Thread Pacer & Telemetry

To prevent SwiftUI main-thread layout work from introducing 20–30 ms callback gaps:
- **`PointerCaptureEngine` & `PointerSender`:** Own the `CGEvent` tap, run-loop source, `PointerPipeline`, AES-CBC encryption, and BSD UDP `sendto` on a dedicated `.userInteractive` worker thread (`continuity.pointer`).
- **Event-Driven 6 ms Pacing:** Matches the Galaxy Book's `MCFMessage.SendMouseMessageM` behavior—sending immediately on an arriving mouse event once $\ge 6\text{ ms}$ have elapsed, accumulating sub-6 ms deltas, and arming a single one-shot timer to flush the final delta. Pending deltas are also force-flushed before any click, wheel, or key event to preserve strict ordering.
- **Measured Improvement:** Moving capture and pacing off the main run loop onto the worker thread eliminated all $>20\text{ ms}$ callback stalls in 125 Hz and 1000 Hz benchmarks on the Galaxy Tab S9+ and brought oldest-event age p99 down from `16.2–20.2 ms` to `2.6 ms` at 125 Hz.
