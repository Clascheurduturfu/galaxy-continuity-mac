# 2026-10-23 — Clipboard Windows Architecture & Cellular Experiment

## Windows Clipboard Architecture (`WindowsMCFCore` & `MCFClipBoard`)

| Entry Point | Observed Behavior |
|---|---|
| `CopyPasteUtils.ProcessCopyEvent` (`WindowsMCFCore`) | Short text/HTML requests metadata directly (`Command 4`). Image copies are represented as URI/file clipboard items and prepare a remote-file placeholder after checking Wi-Fi/session state. |
| `PrepareClipboardRemoteFileCopy` (`MCFClipBoard`) | Places a `~ClipboardTransferring.tmp` placeholder file on the Windows clipboard and registers a paste watcher. |
| `ProcessRemoteFilePaste` (`MCFClipBoard`) | Defers the actual image byte download (`RequestFileList`) until the user pastes on Windows. |
| `CopyPasteUtils.IsDevicesAreInSameNetwork` (`WindowsMCFCore`) | Accepts a matching Wi-Fi BSSID hash or an already-established session. |
| `MCFClipboardManager.OnClipboardUpdated` (`WindowsMCFCore`) | Compresses metadata with gzip, sets the large-metadata flag above `20,480` bytes, advertises a BLE copy event, and announces on any active command channel. |

---

## Cellular-Only (Radios-Off) Experiment

- Tested whether Samsung Continuity relays clipboard items over cellular data when both phone Wi-Fi and Bluetooth are turned off (`wifi_on=0`, `bluetooth_on=0`, `mobile_data=1`).
- With Wi-Fi and Bluetooth disabled on the phone, no clipboard change arrived on the Galaxy Book. As soon as Wi-Fi and Bluetooth were re-enabled, the queued text and file-drop formats arrived within 1–3 seconds.
- **Conclusion:** In this tested configuration, Samsung Continuity clipboard sync requires local radio reachability (BLE and/or shared Wi-Fi / hotspot) and does not use a cloud clipboard payload relay.
