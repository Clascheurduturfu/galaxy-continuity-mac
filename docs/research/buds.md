# Galaxy Buds Auto Switch & TWU RFCOMM Protocol

Galaxy Continuity implements native macOS audio handoff and automatic playback takeover for paired **Galaxy Buds** (`BudsProtocol.swift`, `BudsConnection.swift`, `BudsAudio.swift`, and `BudsPanel.swift`).

---

## 1. Windows Coordinator Analysis (`EasyConnect2` & `BudsMsgFmtDynamic`)

On a Galaxy Book, Galaxy Buds Auto Switch is coordinated by `EasyConnect2.dll` and its native packet formatter `BudsMsgFmtDynamic.dll` (`TwuMsg_*` exports) inside Samsung Settings (`8.0.13.0`), rather than by the older Galaxy Connect service:
- **Serial Service UUIDs:** Paired Buds expose Samsung's custom serial UUID `F8620674-A1ED-41AB-A8B9-DE9AD655729D` alongside standard SPP UUIDs (`00001101-0000-1000-8000-00805F9B34FD` and `00001101-0000-1000-8000-00805F9B34FB`).
- **Cached SDP Records:** Querying fresh SDP records over Bluetooth can stall when the headset is actively streaming A2DP from a phone; preferring already-cached macOS `IOBluetoothDevice` service records connects reliably.

---

## 2. TWU Packet Framing (`0xFC .. 0xCC`)

Newer Galaxy Buds (such as Galaxy Buds3 Pro) use Samsung's **TWU** serial framing, which differs from the legacy `0xFD`/`0xDD` framing documented in older community tools:

| Offset | Field | Value / Description |
|---|---|---|
| `0` | Start Marker | `0xFC` |
| `1..2` | Header (LE UInt16) | Payload byte length in the low 11 bits (`0..2047`), flags in upper bits |
| `3` | Client ID | `0x01` |
| `4` | Message ID | Command / notification identifier |
| `5..N` | Payload | Command parameters or TLV status items |
| `N+1..N+2` | Checksum | CRC-16/XMODEM over client ID, message ID, and payload |
| `N+3` | End Marker | `0xCC` |

---

## 3. Auto Switch Command & Status Sequence

| Message ID | Hex | Direction | Purpose |
|---|---|---|---|
| `44` | `0x2C` | Host → Buds | Feature discovery request |
| `73` | `0x49` | Host → Buds | Computer host information (identifies Apple host without spoofing a Galaxy Book model) |
| `43` | `0x2B` | Host → Buds | MDE Auto Switch V3 negotiation, output-device state, and playback state (A2DP, HFP, CIS, BIS) |
| `71` | `0x47` | Host → Buds | Audio takeover request (`AutoSwitchRequestCommand`) |

### Multipoint Status TLV (`0x0117` & `0x0502`)
Incoming Buds status packets contain TLV records:
- **Tag `0x0117`:** Reports whether multipoint / Auto Switch is supported (`supportsMultipoint`).
- **Tag `0x0502`:** Minimum length 18 bytes with discriminator `0x0B`:
  - Offset `1`: foreground/background ownership (`0` = foreground on this host, nonzero = background / other device active)
  - Offset `2`: transition reason code
  - Offset `7`: active stream flags (`0x80` bit indicates switch in progress; nonzero low bits indicate active stream).
  Peer identity bytes at the tail of tag `0x0502` are omitted from logs and UI.

---

## 4. macOS Automatic Playback Takeover (`BudsAudio.swift`)

When **Automatic Buds Switching** is enabled in the app:
1. `BudsAudio` watches macOS CoreAudio (`kAudioDevicePropertyDeviceIsRunningSomewhere`) on the current default output device.
2. When Mac audio starts playing and the selected paired Buds are either disconnected or in background mode on the phone:
   - The Mac opens the RFCOMM control channel (`BudsConnection.connect`),
   - Negotiates MDE Auto Switch V3 (`44`, `73`, `43`),
   - Sends the takeover request (`71`), and
   - Selects the Galaxy Buds as the macOS default audio output device.
3. When music resumes on the Galaxy phone, the Buds transition back to phone A2DP while maintaining the dual connection.
