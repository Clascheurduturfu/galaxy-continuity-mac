# Security Policy

## Credential & Data Handling

Galaxy Continuity is designed with strict local security boundaries:
- **Account & Session Keys:** Samsung OAuth tokens, RSA private keys, and account continuity keys are stored locally in `~/Library/Application Support/Galaxy Continuity Lab/Credentials` with mode `0700` (directory) and `0600` (files), rejecting symlinks and hardlinks, or optionally in the macOS Keychain (the `continuity-use-keychain` preference).
- **Bounded Wire Parsing:** Protobuf varint frames, gzip clipboard metadata, SIP messages, SDP bodies, and TWU Bluetooth packets enforce strict byte and dimension caps before allocation.
- **No Sensitive Payload Logging:** Clipboard text/images, hotspot passwords, temporary SMB credentials, phone numbers, and SRTP keys are held in memory only and excluded from diagnostic logs.

## Reporting a Vulnerability

If you discover a security issue (such as an unbounded parser allocation, authentication bypass, or credential permission weakness), please report it privately via GitHub Security Advisories on this repository rather than opening a public issue with exploit details.

## Beta 2 data boundaries

- Mac Contacts is read only after Load Contacts and the OS consent. Only accessible contacts with numbers are displayed, kept in memory for that page. Selecting one fills the dialer; it never initiates a call.
- The GitHub update token is separate from Samsung credentials, saved as a 0600 local file. Any process running as that Mac user may read file-based development credentials. The token is attached only to GitHub API requests; cross-host redirects remove Authorization. No token is embedded in the app or release artifacts.
- Updates require a compatible release from the chosen branch, the GitHub-provided SHA-256 digest, bounded archive paths/size, correct bundle identifier/version and valid code signature. The local ad-hoc signature is not an independently pinned publisher identity; releases trust this GitHub repository and its maintainers. Install only from that trusted repository.
- Developer-only explicit capture flags may store clipboard archives in the app's private cache; ordinary launches do not do so. Test call diagnostics use an isolated build directory and never dial real numbers.
- The stock app has no telemetry service and never uploads contacts, clipboard history or hotspot passwords.

The updater probes releases without credentials first. Once public access succeeds, it removes any legacy private-repository token. The temporary token-entry UI was removed in v1.0. Revocation in GitHub remains an account action. No CLI credential or shared access token is distributed. Clipboard Sync now gates receipt as well as sending; authenticated command sessions can remain connected for independent features.
