# v1.0 Beta 2 (51)

## Changes

- Normalize Bluetooth address aliases and deduplicate paired Buds by address, keeping distinct headsets with the same name. Event-driven Core Audio listeners replace the previous two polling loops. Optional pause-on-takeover sends an explicit pause, not a toggle; it never resumes playback. Player/macOS command support still needs live acceptance.
- Nearby Devices lists only detected/connected peers. Storage Share, clipboard connection and Multi Control are per-device actions; unrelated peers never borrow the selected clipboard device's command session.
- Multi Control has a separate arrangement page with drag placement, four sides, edge offset and Mac screen selection. A passive event monitor can take control when the pointer crosses the configured portal. Native layout/focus messages handle return; Escape remains the fallback. No video mirroring, drag/drop or simultaneous multi-peer input is claimed.
- Auto Hotspot has its own nearby phone/tablet picker and menu-bar choices. Availability is checked when requesting; an account entry is not proof of cellular capability. Cancelled/old operations cannot overwrite a newer request.
- Settings shows the signed-in Samsung account label. Mac Contacts is opt-in, read-only and local; choosing a number fills the dialer without calling.
- GitHub Stable/Preview release channels use main/preview respectively. Optional private-repository read access is separate from Samsung sign-in. Updates check hashes, size/path/link bounds and app identity/signature before replacement. The manual release workflow publishes only when dispatched on the matching branch. No release is published automatically by these edits.
- Original vector app icon generated at build time; balanced sidebar layout; persistent menu-bar operation, Dock hiding when the last main window closes, and window recreation on reopen. Screenshot fixtures no longer change real user preferences.

## Apple hotspot menu research

[Tetherbug](https://github.com/xav-ie/Tetherbug) demonstrates an Android Wi-Fi beacon marker that gives macOS the Personal Hotspot link icon and metered behavior. It needs a separate phone helper and Shizuku/ADB privileges. Apple's separate battery/status device section uses BLE and Apple Account continuity and has no public insertion API for this client. No phone helper or beacon modification is included or installed. Samsung's native activation and the new picker remain helper-free.

## Validation / delivery

- Native arm64 build: all 106 tests passed; final UI changes compiled successfully.
- Installed `/Applications/Galaxy Continuity Lab.app`, version `1.0-beta.2`, build `51`. Strict signature verification passed with the existing designated requirement; four private credential files were preserved and remain owner-only.
- Native lifecycle self-test passed all five checks: visible initial window, Dock hidden after closing, recreated window, restored requested section, and Dock restored while open.
- Normal launch succeeded and received four fresh successful SIP service replies. No real call or hotspot activation was performed by the build or UI smoke tests.
- Owner reports the arranged screen-edge Multi Control switch works remarkably well. This is live acceptance of that path, not a claim that every device/display combination has been tested.
- Buds pause in actual media players, Contacts permission/enumeration and a downloaded-release installation still need live acceptance.
- Both delivery ZIPs passed scoped confidentiality checks. Source is on the local `preview` branch; no commit, push or release was performed.
- The exact temporary Mac source/build/render folder was removed after artifact retrieval and installed-app verification. The installed app stays running.

The Quick Access clipboard tile controls automatic sending over established sessions. The Nearby Devices Clipboard action selects the active phone/tablet connection; it does not enable simultaneous connections to every nearby Android device. Connected Galaxy PCs participate through existing LAN sessions. Incoming clipboard delivery currently remains active when automatic sending is off.

Demo screenshots use fictional fixtures. After rendering, run `swift scripts/stamp-demo-images.swift <output-directory>` so every PNG carries a visible bitmap provenance label; offscreen SwiftUI overlays alone can fail to paint.
