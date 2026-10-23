# 2026-10-21 — Live Evidence Capture (Calls, Storage Share & Multi Control)

## Overview

A bounded 12-minute live observation window captured PID-scoped Android `logcat` tails (`mcfds`, `mcfserver`, `imsservice`, `mdecservice`, `inputshare`, `hwresourceshare.storage`) and Galaxy Book service log tails across three stock workflows:
1. User-initiated outgoing call from Samsung Phone on the Galaxy Book with two-way audio and hang-up.
2. Storage Share toggle, on-phone consent, and SMB mount in both directions.
3. Multi Control toggle, pointer screen-edge crossing, mouse clicks, and keyboard input.

---

## Key Findings

### 1. Storage Share (MCF AppId 10 + `ksmbd`)
- **Wire Message Set:** `sessionKeepAliveReq/Resp` (every 10 s), `smbServerStatusReq/Resp#{running|stopping|stopped}`, `smbGetCredentialsReq#<device-name>`, `smbGetCredentialsResp#{permissionStatus | resource, ip, credentials{user,password}}`, `smbClientConnectionStatus#<bool>`, `smbStorageCapacityReq/Resp#{used,total}`, `smbUnmountReq/Res`, `smbDeleteCredentialsReq/Resp#<user>`.
- **Stock Timer Race Identified:** When re-enabling Storage Share on the Galaxy Book, a leftover `SmbServerStatusTimer` from a prior attempt continued counting (attempts 1–8) while waiting for the user to tap **Allow** on the phone, causing the Book to abort the session just as `running` arrived.
- **Mac Design Lesson:** Use a per-session status poll without a short retry cutoff while on-device user consent is pending.
- **Security Hygiene:** Stock Storage Share and Call Gateway logs write temporary per-session SMB credentials and SRTP keys in plaintext on Windows/Android; the macOS implementation never writes credentials, keys, or clipboard content to logs.

### 2. Multi Control (MCF AppId 1)
- **Reconnect Sequence:** `DEVICE_INFORMATION`, `NETWORK_INFORMATION`, `WALLPAPER_INFORMATION` out → `DEVICE_LAYOUT_CHANGED` in → virtual keyboard and mouse registered.
- **Focus Crossings:** Five pointer crossings from the Galaxy Book into the phone across the left screen edge (`FOCUS_DEVICE_CHANGED`), accompanied by `handleClickData` click packets and user-confirmed typed text.

### 3. Samsung Phone Calls (CMC)
- **Signaling & Media:** Outgoing `INVITE` → `active` → `disconnectCall` / `EndCall`.
- **Gateway (`cwmglog.txt`):** Bidirectional SRTP/RTP packets confirmed with active AMR-WB transcoding in both directions; user confirmed clear two-way audio.
