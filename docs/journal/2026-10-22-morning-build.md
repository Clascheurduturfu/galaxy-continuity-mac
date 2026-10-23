# 2026-10-22 — Morning Build, Scoped SMB 2 Lease & Static Analysis

## Overview

Documented the transition from `0.4.9` to `0.5.3`, introducing the automatic scoped SMB 2 compatibility lease for Storage Share, initial `ProtoData` image clipboard framing, and static managed/native boundary checks for Multi Control.

---

## Key Findings

### 1. Storage Share Scoped SMB 2 Lease (`SMBCompatibility.swift`)
- Default macOS `NetFS` mounting failed with `ENOTCONN` (`57`) because the phone's `ksmbd` server closed the connection after SMB 3 negotiation.
- Scoping `protocol_vers_map=2` to the phone's IPv4 address in `~/Library/Preferences/nsmb.conf` during the `NetFSMountURLSync` call resolved the disconnect. A controlled test listed 31 root entries, wrote a test file, verified its SHA-256 readback, and deleted it cleanly.
- `SMBStorageRecovery` journals the prior `nsmb.conf` state and restores it immediately after mounting.

### 2. Clipboard Image Framing (`ProtoData`)
- Retained `WindowsMCFCore` analysis established that clipboard images use handler `2` (`OPEN_CHANNEL = 6`, `GET_URI_LIST = 8`, `SET_FILE_URI = 5`, `DOWNLOAD = 2`, `DOWNLOAD_FINISH = 3`, `METADATA_UPDATED = 7`) and communication handler `100` (`DATA_CHANNEL_REQUEST = 2`) with reserved session ID `102`.
- Data sockets use varint-framed `ProtoData` protobuf messages (`Field 1` = repeated `CommandPacket`, `Field 2` = repeated `Chunk` with AES-256-CBC encrypted payload bytes).
- Response code `16` (`0x10`) carries an 8-byte big-endian total byte length before streaming chunks, ending with response code `0`.

### 3. Static Analysis of Multi Control Assemblies
- Inspected `Samsung.MultiControl.Protocol.dll` (443 methods), `ProtocolMCF.dll` (63 methods), `Clipboard` (47 methods), and `Network` (75 methods, 6 `Wlanapi` imports).
- Observed `MCFSessionManager.ApplyUdpQoSPolicy` requesting `ApplyQoSPolicyAsync(UDP, LowDelay, 48)`, though active Windows QoS policies were empty on the reference machine.
