# Storage Share (Wireless Finder Mount over MCF + SMB)

Samsung **Storage Share** (`1.3.21.0` on Windows, `com.samsung.android.hwresourceshare.storage` `1.9.00.15` on Android) uses **MCF SDK Application ID 10** to negotiate on-device user consent and temporary per-session SMB credentials, then mounts the phone's `ksmbd` server over TCP port `445`.

---

## 1. MCF SDK AppId 10 Session & Message Protocol

After completing the MCF SDK 3/4/5 nonce handshake for application ID `10` (see [Multi Control — SDK Handshake](multi-control.md)), the session exchanges UTF-8 control messages delimited by `#`:

| Message | Direction | Purpose |
|---|---|---|
| `smbServerStatusReq` | Mac → Phone | Query whether the phone's kernel SMB server (`ksmbd`) is `running`, `stopping`, or `stopped` |
| `smbServerStatusResp#{state}` | Phone → Mac | Current server state |
| `smbGetCredentialsReq#{client-name}` | Mac → Phone | Trigger the on-phone permission prompt requesting storage access for `{client-name}` |
| `smbGetCredentialsResp#{json}` | Phone → Mac | Returns `permissionStatus` and, once approved, `resource`, `ip`, and temporary `credentials: { user, password }` |
| `smbClientConnectionStatus#success` | Mac → Phone | Confirm that the SMB share was mounted |
| `sessionKeepAliveReq` / `sessionKeepAliveResp` | Bidirectional | Sent every 10 seconds to keep the MCF session and temporary SMB user alive |
| `smbStorageCapacityReq` / `smbStorageCapacityResp#{json}` | Bidirectional | Query `used` and `total` byte capacity |
| `smbUnmountReq` / `smbUnmountResp` | Bidirectional | Cleanly disconnect the mounted storage |
| `smbDeleteCredentialsReq#{user}` / `Resp` | Mac → Phone | Delete the temporary per-session SMB user on the phone |

### Avoiding the Stock Timer Race
Live capture of the Windows Storage Share client revealed a timer race where an 8-attempt `SmbServerStatusTimer` could expire while the user was still reading the on-phone "Allow" prompt. Galaxy Continuity's macOS client (`StorageShare.swift`) uses a per-session poll without a premature retry cutoff while user consent is pending.

---

## 2. macOS NetFS Mounting & Scoped SMB 2 Compatibility Lease

1. **Mounting via `NetFS` at `/Volumes`:**
   - Attempting to mount under `~/Library/Application Support` is blocked by macOS AppData privacy protection.
   - `StorageShare.swift` uses Apple's native `NetFSMountURLSync` API to mount the phone's `media` share in the standard `/Volumes` location and reveals it in Finder.
2. **Why Scoped SMB 2 Is Required (`SMBCompatibility.swift`):**
   - By default, macOS negotiates SMB 3 with the phone's `ksmbd` server, which closes the socket right after negotiation with `ENOTCONN` (error `57`).
   - Scoping `protocol_vers_map=2` (SMB 2) specifically to the phone's IPv4 address in `~/Library/Preferences/nsmb.conf` during the `NetFSMountURLSync` call succeeds cleanly (verified with directory listing, file creation, SHA-256 readback, and deletion).
3. **Reversible Recovery Journal (`SMBStorageRecovery`):**
   - Before writing the scoped `[<phone-ip>]` section to `~/Library/Preferences/nsmb.conf`, `SMBCompatibility.swift` records the prior file state in a `0600` recovery journal and restores the user's original `nsmb.conf` immediately after the mount call completes (or on the next app launch if interrupted).
   - If the user already has a custom section for that host in `nsmb.conf`, the lease leaves it untouched.
