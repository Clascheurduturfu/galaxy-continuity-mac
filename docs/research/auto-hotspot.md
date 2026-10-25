# Auto Hotspot: native macOS Wi-Fi menu integration

Status: shipped experimentally in v1.1-beta.2 (2026-10-25). Research log and
design notes; the original PoC write-up lives in the "samsung continuity"
project folder (`AUTO_HOTSPOT_RESEARCH.md`).

## 1. What works (PoC, user-verified 2026-10-24/25)

A hook dylib injected into the processes that own the macOS Wi-Fi menu shows
the Samsung Galaxy under the native **Personal Hotspots** section — battery,
signal bars and all — and clicking it enables the phone's hotspot and joins
it. Verified on the S26 Ultra with a v4 hook: entry appeared, click enabled
the hotspot in ~1 s and joined in ~5 s, no error dialog.

Mechanics (macOS 14/15):

- `WiFiAgent.app` owns the menu's tether-device data; `ControlCenter.app`
  renders it. WiFiAgent builds the Personal Hotspots list from
  `SFRemoteHotspotDevice` objects (private `Sharing.framework`, normally fed
  by `sharingd`/Instant Hotspot) via `-[CWWiFiAgent
  __tetherDevicesForRemoteHotspots:]`.
- Feeding WiFiAgent a fake `SFRemoteHotspotDevice` is enough for the UI.
- The click path ends in `-[CWInterface connectToTetherDevice:remember:error:]`
  — the single clean interception point. Earlier attempts that hooked the
  `internal_enableTetherDevice` path showed the device but failed to connect.
- `CWNetwork`/`CWTrimmedNetwork.isPersonalHotspot` make the joined SSID
  display as a Personal Hotspot.
- Dropping the `SFRemoteHotspotDevice` path and injecting a raw
  `CWTetherDevice` makes the entry disappear (v3 lesson).

## 2. What ships in v1.1-beta.2

- **App side** (`Sources/ContinuityApp/WiFiMenuHotspot.swift`): an option on
  the Auto Hotspot page. It checks `csrutil status` (refuses politely when SIP
  is enabled), copies the bundled dylib into Application Support, exports it
  through `launchctl setenv DYLD_INSERT_LIBRARIES` and restarts
  WiFiAgent/ControlCenter. Turning it off unsets the variable and restarts
  them again.
- **Hook** (`scripts/wifiagent-hook/GalaxyContinuityWiFiMenuHook.m`, v5
  rewrite — the v4 sources lived in `/tmp` and were lost): runtime-resolved
  swizzling with logging to `/tmp/gcl-wifi-menu/hook.log`, KVC against
  several candidate property names for the fake device, and the v5
  duplicate-entry fix (while the Mac is connected to the hotspot SSID, the
  fake entry is suppressed instead of listing next to the joined network).
- **File protocol** (`/tmp/gcl-wifi-menu`):

  | File | Direction | Meaning |
  |---|---|---|
  | `status.json` | app → hook | display data: name, battery, bars, network, ssid |
  | `available` | app → hook | touched while a live session + capable device exists; stale after 10 s → the entry hides |
  | `menu_opened` | hook → app | Wi-Fi menu opened; the app may prefetch |
  | `trigger` | hook → app | entry clicked; answered via `creds.json` |
  | `creds.json` | app → hook | `{isSuccess, ssid, password, reason}` |

- **Type-3 query policy** (user-specified): queries run **on demand only**
  (page button, menu open, menu click) — never on scan ticks; answers are
  cached 20 s (`HotspotCenter`), dropped on wake, disconnect or explicit
  invalidation; only the **existing** BLE session is used (the watcher never
  opens a connection); with no live session or a hotspot-less device the
  entry is hidden via the `available` file.
- **Capability memory** (`HotspotCapabilityMemory`): devices answering the
  type-3 request with a failure are excluded from further requests for 24 h
  (grayed card with Retry on the Auto Hotspot page; excluded from the
  Wi-Fi menu availability). Wi-Fi-only tablets can't tether — now the app
  learns it instead of asking every time.

## 3. Can this be done with SIP enabled? (research, 2026-10-25)

**Verdict: no documented way.** An independent research pass over Apple
documentation, private-framework headers, and prior art concluded:

- Public CoreWLAN has no tether-list injection; `CWWiFiAgent`/`CWTetherDevice`
  are private, and the tether list lives inside the WiFiAgent XPC agent
  itself — there is no client-publishable interface.
- `SFRemoteHotspotDevice` comes from `sharingd` (Instant Hotspot), tied to
  iCloud-keychain pairing; no public XPC to publish into it.
- `NEHotspotConfigurationManager` does not exist on native macOS.
- Apple's Instant Hotspot BLE (Continuity type `0x0E`) carries a rotating auth
  tag keyed to iCloud secrets; nobody has made macOS list a non-Apple device
  via BLE emulation alone (furiousMAC/continuity, seemoo-lab
  apple-continuity-tools, USENIX'21 all stop at spoof detection/DoS).
- The strongest SIP-on partial alternative is **Tetherbug**'s trick (inject
  Apple vendor IE OUI 00:17:F2 type 6 into the hotspot's beacon): macOS then
  treats the SSID as a Personal Hotspot (icon, metered, auto-join) — but it
  never appears in the Continuity section, and it needs Android-side control
  of the beacon (Shizuku), which our no-app-on-phone constraint rules out.

So the DYLD hook is the only known way to a real Personal Hotspots entry.

## 4. Risks of the SIP-off approach (accepted)

- Full SIP disable weakens OS protections while on; the option is off by
  default and clearly labelled.
- Private selectors/property layout shift across macOS releases — the hook
  logs every hook/KVC outcome to `hook.log` so failures are diagnosable.
  `launchctl unsetenv` + restart restores stock behavior instantly.
- Library Validation/AMFI can still block injection into some system
  binaries on specific versions even with SIP off — if the entry does not
  appear, check `hook.log` for missing-method lines.
- macOS 26 (Tahoe) redesigned Control Center visually; no documented change
  to the CWWiFiAgent tether pipeline, but expect selector drift.

## 5. Known limitations

- Battery/bars/network in the fake entry are placeholder values (88/4/5G)
  until phone-context packets provide real ones.
- Single-device: the entry reflects the currently connected session target.
- The fake entry hides while already connected (dedup) instead of showing a
  connected state — fine for now, revisit with `CWDisplayedScanResult`
  filtering if needed.
