# MCF Protocol, BLE Discovery, Framing & Auto Hotspot

Observed on Galaxy Connect `4.6.1217.0`, Android MCFDs `4.6.12.16`, and AutoHotspotMDE on Samsung Galaxy flagship hardware running One UI. These are version-specific interoperability findings, not a published Samsung API. All examples use synthetic identities.

---

## 1. Architecture and BLE Discovery

The Mac connects directly to the Galaxy phone over CoreBluetooth BLE credit-based L2CAP Connection-Oriented Channels (CoC) and local Wi-Fi sockets. Native Samsung sign-in obtains an independent Mac continuity certificate and account key bundle (an encrypted Windows Galaxy Connect profile import is also supported as a fallback). No Windows relay, ADB bridge, or phone helper app is used at runtime.

### BLE Advertisement Structure & Obfuscation
1. **Header:** Samsung manufacturer data starts with company ID `75 00`, followed by the MCF header `02 18`.
2. **Obfuscation Table:** The account fingerprint's decoded bytes are hashed with SHA-256 to derive a 32-byte obfuscation table.
3. **12-Hour Checksum Rotation:** Account checksum candidates are computed using the current and previous 12-hour rotation windows.
4. **LTV Decryption:** Personal Length-Type-Value (LTV) data is XOR-obfuscated with the SHA-256 table and a seed derived from header bytes `5..12`. Matching the checksum recognizes same-account candidate advertisements without authenticating them.
5. **CoC PSM Hint:** The phone advertises an insecure BLE L2CAP CoC PSM (typically observed as `128`), encoded in big-endian order on Android. Mobile additional-info LTV carries the two middle Bluetooth address bytes; PC additional-info carries the final three bytes.
6. **Continuous Observation:** The subsequent 3-message account handshake verifies the full authenticated Bluetooth address against the account's registered peer list. Passive BLE scanning stays active while connected so the Mac can observe fresh clipboard copy contexts and multi-peer proximity.

### Local Network (`_mcfds._tcp`)
Bonjour `_mcfds._tcp` discovery and advertisement are also implemented. Its TXT record `DEVICE_ID` carries an account-encrypted 6-byte Bluetooth identity (AES-GCM sealed using the 12-byte hex service instance name as nonce). Phones primarily advertise over BLE, while Galaxy Books advertise `_mcfds._tcp` over LAN Wi-Fi.

---

## 2. Stream Framing and Account Authentication

### `CommandPacket` Protobuf Framing
Every stream frame begins with a protobuf varint byte length followed by a `CommandPacket` message:

| Field | Wire Type | Meaning |
|---|---|---|
| `1` | varint | Handler ID (`2` = Clipboard, `6` = SDK Client, `100` = Communication) |
| `2` | varint | Packet sequence |
| `3` | bytes | Authentication body or AES-256-CBC encrypted command |
| `4` | bytes | Embedded plaintext extended context (LTV) |
| `5` | varint | Account certificate revision |
| `6` | varint | Authentication type |
| `7` | bytes | Authentication IV |

### Three-Message Same-Account Handshake
1. **Account Key & Nonce:** The three-message handshake uses the 256-bit account key (`accountKey`) with AES-GCM. Samsung's shipped protocol uses a 12-byte zero nonce in this initial exchange (reproduced strictly for wire compatibility; data channels bind channel names or fresh IVs).
2. **Ephemeral ECDH & Identity Proof:** Messages carry Bluetooth identities, DER `SubjectPublicKeyInfo` P-256 ephemeral public keys, message stage markers, and 6-byte SHA-256 public-key proofs. Both peers verify the proof and exact registered Bluetooth address before accepting the session.
3. **Session Command Key:** The raw 32-byte P-256 ECDH shared secret becomes the session command key.
4. **Command Encryption:** Authenticated commands use AES-256-CBC with PKCS#7 padding and a fresh random 16-byte IV prepended to the ciphertext. Inner protobuf command fields are `1` (command ID), `2` (command type: `1` = request, `2` = response, `3` = event), and `3` (payload bytes).

### Connection Keepalive & Wi-Fi Handover
- **Keep Connection:** Send handler `100` / command `3` / request with payload `01` to keep the BLE command channel open across idle intervals.
- **Wi-Fi Command Handover (`100/1`):** When both devices share a subnet and transfer larger items, the phone offers a TCP command handover (`100/1`) or data channel (`100/2`). The Mac can either accept the handover onto a same-subnet authenticated TCP socket (`CommandHandover.swift`) or decline with `{"RC":2,"CN":"<request CN>"}` to remain on BLE.

---

## 3. Auto Hotspot (`AutoHotspotMDE`)

Current Galaxy phones handle Auto Hotspot over the **authenticated MCF command connection** rather than legacy GATT services.

1. **Activation Request:** Send handler `6` / command `3` / event with payload prefix `04 00` (selecting SDK application ID `4` and simple-message ID `0`) followed by UTF-8 JSON:
   ```json
   {
     "version": 1,
     "messagetype": 3,
     "membertype": 1,
     "clientsupportedhighband": 5,
     "clientsupportedband": 3,
     "wpa3personalsupport": 0,
     "owesupport": 0
   }
   ```
2. **Activation Response:** The phone replies on the same route with `messagetype: 4`, `isSuccess`, `ssid`, `password`, and frequency/security metadata. Note that `wifi_ap_smart_tethering_settings` (Auto Hotspot) must be enabled on the phone; devices where it is disabled return failure reason `-6`.
3. **macOS Wi-Fi Association:** The Mac requests macOS Location Services permission (required by Apple for CoreWLAN SSID scanning), scans with retries while the phone starts beaconing, and associates with the returned SSID and passphrase in memory without writing credentials to logs.

---

## 4. Reference Components Analyzed

- **Windows (`Galaxy Connect`):** `WindowsMCFCore.dll` (account handshake builders, command encryption, clipboard metadata command 4, extended context, keep-connection builders) and `Commons.dll` (GCM helpers, advertisement parsing, handover result definitions).
- **Android (`MCFDs`):** `pa.a`, `qa.a`, `ic.b0`, `ic.s`, `ic.q`, and `m9.e` (BLE discovery, copy-state transitions, trusted provider handoff, and L2CAP CoC startup).
- **Android (`Samsung Keyboard`):** `Q1.e`, `ClipMeta`, and `SemImageClipData` (gzip/JSON metadata and rich image clip archive format).
- **Android (`AutoHotspotMDE`):** `v0.C0094b`, `v0.C0104l`, `v0.w`, `E0.b`, and `E0.u` (simple messages, SDK AppId 4, capability fields, and result JSON).
