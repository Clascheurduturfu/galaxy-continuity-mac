# Galaxy Book & Android Component Reference Map

This page catalogs the Samsung Windows (ARM64 Galaxy Book) and Android (One UI) software components analyzed to design and verify Galaxy Continuity for macOS.

> **Note:** No proprietary binaries, ASAR bundles, APKs, or decompiled vendor files are stored in this repository.

---

## 1. Windows Components (Galaxy Book ARM64)

| Component | Version Analyzed | Key Assemblies / Modules | Protocol Surface |
|---|---|---|---|
| **Galaxy Connect / Continuity** | `4.6.1217.0` | `WindowsMCFCore.dll`, `Commons.dll`, `MCFClipBoard.dll`, `SCCloudService.dll` | MCF BLE discovery, 3-message AES-GCM + P-256 ECDH handshake, Handler 2 clipboard, AppId 102 data channels, PKCS#10 CSR enrollment |
| **Multi Control** | `2.7.1300.0` | `SamsungMultiControl.dll`, `Samsung.MultiControl.Protocol.dll`, `ProtocolMCF.dll` | MCF SDK AppId 1, JSON layout/focus control plane, binary `M`/`W`/`C`/`K` input packets, 6 ms `SendMouseMessageM` pacer |
| **Samsung Settings** | `8.0.13.0` | `EasyConnect2.dll`, `DllBudsMsgFmt.dll`, `BudsMsgFmtDynamic.dll`, `NDBudsManager.dll` | Galaxy Buds Auto Switch coordinator, TWU (`0xFC..0xCC`) packet framing, MDE V3 commands (`44`, `73`, `43`, `71`), multipoint TLV (`0x0117`, `0x0502`) |
| **Settings Runtime** | `7.0.6.0` | `SamsungSettingsRuntime` | `BTDeviceList.txt` publisher cache and per-device Auto Switch configuration |
| **Nearby Devices** | `3.0.22.0` | `SamsungMyDevices.dll`, `NearbyDevicesSdk.dll` | `MCFSdkManager`, `DiscoveryHelper`, `DiscoveryManager` multi-transport presence and capability model |
| **Storage Share** | `1.3.21.0` | `StorageShareLibrary.dll`, `StorageShareCommon.dll`, `StorageShareServiceLibrary.dll` | MCF SDK AppId 10 `#`-delimited messages, `smbGetCredentialsReq/Resp`, SMB mount orchestration |
| **Samsung Phone** | `1.1.15.0` | `samsungphone.asar` (`profilegate`, `sipjs-wrapper`, `nmsclient`), `@cmc/mediagateway`, `cwmgjsnapi.node` | Samsung CMC OAuth, ACS/entitlement discovery, `pc_` secondary enrollment, SIP/TLS signaling, `cmcLocalSdp` AMR-WB/SDES media |
| **Second Screen** | `1.16.7.0` | `SecondScreen` | Wireless display extension (cataloged for future research) |
| **Samsung Account** | `1.26.6021.0` | `SamsungAccount` | OAuth/PKCE broker parameters |
| **Samsung Cloud Assistant** | `2.2.5.0` | `SamsungCloudPlatformManager` | Cloud device and Bluetooth/Wi-Fi sync |
| **System Support Engine** | `7.1.7.1` | `SamsungSystemSupportService` | `ModuleAutoSwitch` and hardware support gates |

---

## 2. Android Components (One UI)

| Component | Package / Version | Key Classes / Modules | Protocol Surface |
|---|---|---|---|
| **Samsung Continuity Service** | `com.samsung.android.mcfds` (`4.6.12.16`) | `pa.a`, `qa.a`, `ic.b0`, `ic.s`, `ic.q`, `ic.i0`, `ic.g`, `m9.e` | BLE advertisement rotation, L2CAP CoC server, clipboard metadata & file channels, RichcontentProvider bridge |
| **MCF Server** | `com.samsung.android.mcfserver` (`4.6.12.12`) | Core transport daemon | Underlying BLE/Wi-Fi transport and SDK session multiplex |
| **Samsung Keyboard** | `5.9.40.75` | `Q1.e`, `ClipMeta`, `SemImageClipData` | Gzip/JSON clipboard metadata and serialized image clip archive (`clip` + image) |
| **Auto Hotspot MDE** | `AutoHotspotMDE` | `v0.C0094b`, `v0.C0104l`, `v0.w`, `E0.b`, `E0.u` | Handler 6 / AppId 4 simple-message JSON (`messagetype: 3/4`) and `wifi_ap_smart_tethering_settings` |
| **Storage Share (Android)** | `com.samsung.android.hwresourceshare.storage` (`1.9.00.15`) | `r3.k`, `r3.q`, `q3.c` | AppId 10 session handler, permission dialog, and `ksmbd` per-session SMB server |
| **Hardware Resource Share** | `1.9.00.13` | Resource capability provider | Advertises Storage Share roles and context availability |
| **Multi Control (Android)** | `com.samsung.android.inputshare` (`2.8.02.1`) | `inputinject.e`, `inputinject.f`, `InputOptimizeHelper` | AppId 1 receiver, `(-100, -100)` queue reset sentinel, and input injection |
| **Call & Text (MDEC)** | `com.samsung.android.mdecservice` (`9.1.00.15`) | Primary CMC service | Line registration, call forking, and `SecondConnectionService` |
| **Galaxy Buds Managers** | `9.0.10.1724` / `8.5.26070351` | Buds Unite & Buds3 Pro Manager | Earbud firmware feature tags and multipoint control |
