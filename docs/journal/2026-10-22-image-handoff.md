# 2026-10-22 — Wi-Fi Command Handover & Image Clipboard Handoff

## Overview

Captured the live phone-to-Mac clipboard image signaling sequence and implemented authenticated Wi-Fi command handover (`CommandHandover.swift`) alongside internal AppId `102` session routing.

---

## Live Signaling Sequence Observed

When an image was copied on the Galaxy S26 Ultra:
1. Phone sent **Handler 2** copy event (`sequence 4, kind 4, flags 3`).
2. Phone sent `OPEN_CHANNEL` (`Handler 2 / Command 6`) and inbound `Handler 6 / Command 1` (AppId `102`).
3. Phone sent two **Handler 100 / Command 1** Wi-Fi command handover offers, followed by `OPEN_CHANNEL` success and a **Handler 100 / Command 2** data-channel reply.
4. When the Mac previously declined the `100/1` command handovers (`RC: 2`) and waited for an external SDK `3/4/5` socket, no data socket followed because AppId `102` is internal to the MCF core service.

---

## Implementation (`CommandHandover.swift` & `ClipboardTransfer.swift`)

- **`CommandHandover.swift`:** Accepts a same-subnet `100/1` handover offer, validates the optional channel name, opens an outbound TCP connection to the phone's advertised LAN endpoint, completes the 3-message account handshake to derive a fresh per-socket key, and routes subsequent commands over Wi-Fi while retaining BLE fallback on disconnect.
- **Internal AppId `102` Routing (`FeatureSession.swift`):** Uses the core command session for AppId `102` rather than waiting for an external SDK `3/4/5` socket, while preserving external SDK sessions for Multi Control (`AppId 1`) and Storage Share (`AppId 10`).
- **Samsung Keyboard Archive (`KeyboardClipArchive.swift`):** Subsequent testing confirmed that Mac → Phone image transfers use `GET_CLIP` (`Command 1`) serving Samsung Keyboard's `SemImageClipData` archive, achieving bidirectional byte-exact PNG and JPEG transfers up to 14 MB.
