# Clipboard Continuity (Text, HTML, Images & Galaxy PC LAN)

Samsung Continuity clipboard sharing uses **Handler 2** over the authenticated MCF command stream for change notifications and short text/HTML metadata, and **AppId 102** over an account-authenticated Wi-Fi TCP data channel for images and large metadata (> 20 KiB).

---

## 1. Extended Context & Short Text / HTML Metadata

### Extended Context (LTV)
Every clipboard announcement attaches an extended context (`CommandPacket` field `4`) containing:
- Base LTV: `51`
- Copy-event LTV: `42 02 <clip-sequence> <kind> <flags>` (for example, `01 02` for short text metadata, `04 03` for images)
- Additional-info LTV: `44 <context-sequence> <last-three-local-address-bytes>`

Independent packet, context, and clipboard sequences are maintained across reconnects so peers never discard fresh copies as stale duplicates.

### Command 4 (Short Metadata Exchange)

| Operation | Handler / Command | Type | Payload |
|---|---|---|---|
| Announce new copy | `2 / 255` | Event (`3`) | Empty body; copy details are carried in field `4` extended context |
| Request short metadata | `2 / 4` | Request (`1`) | 1-byte `<clip-sequence>` |
| Metadata success | `2 / 4` | Response (`2`) | `<clip-sequence>` + `08` + gzip-compressed UTF-8 JSON |
| Metadata unavailable | `2 / 4` | Response (`2`) | `<clip-sequence>` + `09` |

The compressed JSON payload carries `id`, `timestamp`, `type` (`"TEXT"` or `"HTML"`), `source`, `text`, and optional `html`. On Android, `MCFDs` hands this payload to Samsung Keyboard's trusted `RichcontentProvider`, which updates the primary Android clipboard.

---

## 2. Image Clipboard & AppId 102 Data Channel

When an image is copied on either device, the bytes are transferred over a dedicated Wi-Fi TCP data socket (`ClipboardTransfer.swift` and `CommandHandover.swift`) rather than over BLE.

### Protocol Flow
1. **Wi-Fi Command Handover (`100/1`):** If the session started over BLE, the phone offers a Wi-Fi command handover (`Handler 100 / Command 1`) containing its local subnet IP and listener port (`LPT`). The Mac verifies that the IPv4 address belongs to a directly attached local subnet, connects over TCP, and runs the 3-message account handshake to derive a per-socket key.
2. **Internal AppId 102 Session (`6/1` & `2/6`):** Unlike external SDK apps (`1` and `10`), clipboard session `102` is internal to the MCF core service. It negotiates `OPEN_CHANNEL` (`Handler 2 / Command 6`) and `DATA_CHANNEL_REQUEST` (`Handler 100 / Command 2`) with `APInfo` JSON (`CN`, `HI: 2`, `ARRAY` with local IP/mask/subnet/port).
3. **`ProtoData` Framing:** Data sockets frame traffic as varint-prefixed `ProtoData` protobuf messages:
   - Field `1` (repeated): encrypted `CommandPacket` control frames (`GET_URI_LIST = 8`, `SET_FILE_URI = 5`, `DOWNLOAD = 2`, `DOWNLOAD_FINISH = 3`, `METADATA_UPDATED = 7`)
   - Field `2` (repeated): `Chunk` messages whose field `1` carries AES-256-CBC encrypted file/image bytes.
   File transfer responses begin with result code `16` (`0x10`) plus an 8-byte big-endian byte length, followed by encrypted data chunks and a terminal result code `0`.

### Samsung Keyboard `SemImageClipData` Archive (`KeyboardClipArchive.swift`)
When sending an image **from Mac to a Galaxy phone or tablet**, Android's `MCFDs` expects `GET_CLIP` (`Command 1`) to deliver Samsung Keyboard's native clip archive:
- A ZIP container holding the image file alongside a Java-serialized `com.samsung.android.content.clipboard.data.SemImageClipData` object (`clip`).
- `KeyboardClipArchive.swift` constructs this exact archive in memory for PNG, JPEG, and HEIC images (bounded to 32 MiB and 40 megapixels), allowing copied Mac screenshots and Finder image files to appear directly in the phone's clipboard and Samsung Keyboard paste bar.

---

## 3. Galaxy Book (LAN PC) Coexistence

Through `LANPresence.swift`, the Mac also advertises `_mcfds._tcp` on the local network and connects to any same-account Galaxy Book listening on LAN:
- **Mac → Galaxy Book:** A single `⌘C` on the Mac simultaneously shares text and images with the connected Galaxy phone and any connected Galaxy Book over Wi-Fi.
- **Galaxy Book → Mac:** On Windows, `MCFClipBoard` places a deferred `~ClipboardTransferring.tmp` file placeholder on the clipboard and triggers `RequestFileList` on paste; `LANPresence` serves and receives both text metadata and image data channels with Galaxy PCs.
