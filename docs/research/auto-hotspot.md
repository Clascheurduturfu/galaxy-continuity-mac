# Auto Hotspot: native macOS Wi-Fi menu integration

Status: Beta 3 repair, 2026-10-28. The private research checkout retains both
`AUTO_HOTSPOT_RESEARCH.md` and the original v4 Objective-C source. They were
not lost; temporary copies disappearing from `/tmp` did not remove these files.

## 1. Original proof of concept

The v4 proof of concept was user-tested: a Galaxy appeared under Personal
Hotspots, a click enabled tethering, and the Mac joined it. Its battery,
signal and cellular-network labels were hard-coded demonstration values,
not measurements. That successful test did not validate the rewritten Beta 2 loader.

WiFiAgent obtains private `SFRemoteHotspotDevice` objects and converts them
with `__tetherDevicesForRemoteHotspots:` to `CWTetherDevice` objects. The
conversion/cache methods return sets. The click reaches
`CWInterface.connectToTetherDevice:remember:error:`; the hook requests Samsung
credentials through the running app and associates with CoreWLAN.

These are private macOS interfaces. Their presence is checked at runtime;
compatibility still requires testing on the actual OS version.

## 2. Beta 2 failure and Beta 3 design

Actual Beta 2 crash reports on the tested Apple Silicon Mac showed DYLD
termination before the hook constructor: the library had only an `arm64`
slice while the system processes required `arm64e`. Exporting
`DYLD_INSERT_LIBRARIES` into the whole GUI launchd environment also affected
new processes such as System Settings. Compiling the library alone did not
exercise this failure.

Beta 3:

- Builds both `arm64` and `arm64e` slices on Apple Silicon, and verifies the
  required architecture before enabling integration.
- Removes the legacy global injection and opts out of automatically retaining
  the Beta 2 enabled preference. Migration restarts the affected menu agents.
- Uses copies of just the WiFiAgent and ControlCenter launch-agent definitions,
  adding the library to their individual environments. System Settings and
  unrelated processes are not injected. Disabling restores the stock agents.
- Bounds helper execution, waits for launchd restart races, checks that both
  agents are running and requires confirmation from both hook constructors.
  Installation and rollback run off the app's main thread.
- Preserves set return types and separate original implementations for the
  two cached-device selectors. It does not return an SFRemoteHotspotDevice
  where a CWTetherDevice is required.
- Uses an owner-only IPC directory and files (0700/0600), rejects symlinks,
  bounds the hook log, and removes credentials after consumption.
- Hides the injected entry without a live account-authenticated session and
  fresh positive hotspot-service status. A currently joined hotspot is not
  also appended as a second available device.

The IPC remains `/tmp/gcl-wifi-menu`: `status.json`, a short-lived `available`
heartbeat, `menu_opened`, `trigger`, and one-shot `creds.json`. Credentials
never go into the log or repository. The hook has no fallback SSID/password.

### Samsung status versus activation

Retained Android `AutoHotspotMDE` code distinguishes these messages:

| Request | Reply | Effect |
|---|---|---|
| type 1, same-account member type 1 | type 2 | Reports service status and exact `batteryLevel`; does not enable tethering |
| type 3 | type 4 | Enables tethering and returns credentials or an activation failure |

The app checks status after an authenticated connection is ready and when the
Hotspot page is opened, reusing answers for five minutes. Menu opening can
refresh status over an existing session. Only an explicit Connect action
requests type 3. Activation answers are cached for 20 seconds and invalidated
on wake/disconnect. No request is sent on every advertisement/scan tick.

Battery is displayed only if Samsung reports a valid percentage (including
zero). Signal bars and cellular technology are not invented. No status reply
means unknown: the Auto Hotspot setting or account policy may prevent a reply.
In particular activation failure **-6 means Auto Hotspot is disabled**, not
that the hardware cannot tether. Activation failures suppress automatic
attempts briefly (two minutes); Retry clears the failure and status backoff.
A 24-hour/week-long negative capability verdict would incorrectly hide a
phone after changing its setting, so it is deliberately not used here.

## Phone discovery and clipboard context

A live capture on the tested Mac contained a 76-byte Samsung manufacturer
value: the company identifier, a 33-byte legacy frame and a 41-byte extended
frame concatenated together. The previous parser assumed a single extended
frame at offset zero and rejected this phone, while accepting the tablet's
standalone extended advertisement. Samsung's retained Android and Windows
implementations confirm that these layouts use different account-filter and
obfuscation offsets.

The parser now validates each bounded candidate frame independently, supports
the legacy account Bloom filter/bit-flip mask and normalizes legacy context
LTVs. Matching an account advertisement remains a candidate check: the
registered-device/account handshake still authenticates every connection.
No phone address, fingerprint or captured advertisement is included in source.
This also lets a connected phone's clipboard-context updates reach the
clipboard reader when they arrive in either advertisement layout.

Discovery retains the last CoC connectability fact for its normal 40-second
freshness window when a context-only advertisement arrives; it no longer
immediately downgrades a connectable peer on that one frame. Updating the same
account profile also no longer erases all proximity observations. Home's
phone preference is separate from per-device service/clipboard routing;
automatic fallback does not silently replace the saved preferred peer.

## Validation log

- Beta 3 status, exact-battery parsing, fast-reply waiter race, device preference
  and interleaved advertisement tests added to the core suite.
- On the tested macOS 27.0.1 Mac, a scoped probe loaded both hook constructors,
  both agents remained running, and System Settings opened while injected.
  The probe restored the stock agents afterward. This checks real loading;
  a full native-menu activation/join still needs a live click test.

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
