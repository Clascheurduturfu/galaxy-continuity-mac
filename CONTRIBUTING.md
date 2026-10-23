# Contributing to Galaxy Continuity for macOS

Thank you for your interest in contributing to **Galaxy Continuity**!

## Development Requirements

- **macOS 13.0+** (Apple Silicon or Intel)
- **Xcode 16+ / Command Line Tools** (`swift 6.0+` and `clang`)
- **Python 3** (used by `scripts/bootstrap-calling.py` to fetch and verify pinned static C libraries for SRTP and AMR-WB)

## Building & Running Tests

```bash
# 1. Fetch and compile the hash-pinned calling libraries (libsrtp, opencore-amr, vo-amrwbenc)
python3 scripts/bootstrap-calling.py

# 2. Run the full 100-test suite (runs completely offline, no Samsung hardware needed)
swift test

# 3. Build the signed macOS app bundle and CLI in dist/
bash scripts/build-macos.sh
```

## Contribution Guidelines

1. **Clean-Room & Hygiene Rules:**
   - Never commit proprietary Samsung binaries (`.dll`, `.exe`, `.apk`, `.asar`, `.so`, `.node`) or raw decompiler dumps.
   - Never include real Bluetooth MAC addresses, serial numbers, account keys, bearer tokens, phone numbers, or personal LAN/VPN IP addresses in code, tests, or documentation. Use RFC 5737 / RFC 1918 documentation addresses (`192.0.2.x`, `198.51.100.x`, `192.168.1.50`) and synthetic MACs (`AA:BB:CC:11:22:33`).
2. **Protocol & Security Boundaries:**
   - Keep all network and Bluetooth parsers strictly bounded (`Wire.swift`, `CallingSIP.swift`, `BudsProtocol.swift`).
   - Do not log clipboard payloads, hotspot passwords, SMB credentials, or SIP/OAuth tokens.
3. **Testing:**
   - Add deterministic unit tests under `Tests/ContinuityCoreTests/` for any new wire framing, cryptographic helper, or state machine logic, and ensure `swift test` passes with zero failures.
