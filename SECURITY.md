# Security Policy

## Credential & Data Handling

Galaxy Continuity is designed with strict local security boundaries:
- **Account & Session Keys:** Samsung OAuth tokens, PKCS#10 private keys, and account continuity keys are stored locally in `~/Library/Application Support/Galaxy Continuity Lab/Credentials` with mode `0700` (directory) and `0600` (files), rejecting symlinks and hardlinks, or optionally in the macOS Keychain (`CONTINUITY_USE_KEYCHAIN=1`).
- **Bounded Wire Parsing:** Protobuf varint frames, gzip clipboard metadata, SIP messages, SDP bodies, and TWU Bluetooth packets enforce strict byte and dimension caps before allocation.
- **No Sensitive Payload Logging:** Clipboard text/images, hotspot passwords, temporary SMB credentials, phone numbers, and SRTP keys are held in memory only and excluded from diagnostic logs.

## Reporting a Vulnerability

If you discover a security issue (such as an unbounded parser allocation, authentication bypass, or credential permission weakness), please report it privately via GitHub Security Advisories on this repository rather than opening a public issue with exploit details.
