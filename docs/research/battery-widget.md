# Galaxy batteries and the macOS Batteries widget

Research dates: 2026-10-28–29. Tested on Apple Silicon, macOS 27.0.1.

## RC1 implementation and current result

RC1 publishes fresh authenticated Galaxy readings to Apple's native Batteries
widget through IOKit accessory power sources. It does not install another
widget extension or inject code into the widget. The Settings switch is on
by default; turning it off removes this app's published entries.

The actual `BatteriesAvocadoWidgetExtension` process was observed receiving
a clearly named synthetic test accessory, constructing a connected device
with the supplied percentage, category `Unknown`, and power state `Unknown`.
Thus the widget's own consumer path is verified, beyond `pmset` registration.
The independent unprivileged BatteryCenter reader still returns no devices
and must not be used as the acceptance criterion. A real-phone visual test
requires the phone nearby, authenticated and reporting a fresh percentage;
the connected Wi-Fi-only tablet supplied no battery report during this run.

The implementation:

- Registers only `Accessory Source`, never `InternalBattery` or UPS.
- Uses a stable hashed Bluetooth identity and the authenticated device name;
  it does not expose the raw identity or account credentials to the registry.
- Uses the accepted generic category and unknown power state. No keyboard,
  fake charging state or fabricated battery percentage is needed.
- Rewrites macOS details only when name or percentage changes, and reuses
  the five-minute status cache. Only previously reporting connected peers
  are queried again after expiry; widget redraws never poll Bluetooth.
- Removes entries on disconnect, disabled sharing, sleep, expiry and quit.
  After wake or a system clock change it discards old samples and requests
  fresh status. A bounded cleanup retry preserves failed handle ownership;
  errors stay visible even if sharing was disabled.
- Retries transient publication failures using cached readings and a single
  scheduled task, without another phone query. There is no wake lock.

Apple controls the widget's redraw cadence and generic accessory icon. No
extra SIP setting, admin helper, phone app, ADB dependency or Keychain change
was introduced. The existing experimental Wi-Fi-menu hook is independent.

## Where the phone percentage comes from

The existing account-authenticated Samsung Bluetooth session carries an Auto
Hotspot **status** request: inner JSON message type 1, version 1, member type 1.
The device replies with inner type 2 and `batteryLevel`. This does not enable
hotspot; inner type 3 requests activation and type 4 returns its result.

In the retained Android AutoHotspot implementation, the status producer reads
the sticky `android.intent.action.BATTERY_CHANGED` broadcast and calculates
`level * 100 / scale`. The Mac validates the returned percentage in 0...100
and caches status for five minutes. ADB was used for independent verification,
not as the application's battery source. Charging state is not in that reply.

The tablet has not answered this status request. This route consequently has
no percentage for it. The retained implementation answers only while its
Auto Hotspot setting is enabled; service availability and Wi-Fi-only hardware
can also differ. A timeout alone does not establish which condition applies.
No companion app or ADB dependency has been added to obtain tablet battery.

The retained general Nearby Devices implementation exposes `IsLowBattery`.
That is a low-battery flag, not an exact percentage. Treating an unset flag as
a particular percentage would invent data.

## Cellular signal is a separate question

The original native-hotspot proof of concept supplied fixed signal bars and
a fixed network label. It demonstrated that Apple's UI could display them;
it did not measure the phone's cellular signal.

The examined AutoHotspot status producer includes battery, Internet
availability and `backhaulnetworktype`, but writes the latter as zero and
does not send a cellular signal-strength field. Its Android client creates
`mNetworkSignalStrength` with the constant 2 when translating that reply into
its internal scan-result object. Finding that field in a Java/Binder model
therefore is not evidence that a measured value crossed the Bluetooth link.

Samsung's separate legacy Smart Tethering BLE implementation does track
cellular state. That is a research lead for a different advertisement path,
not a measured value available through our current MCF status request.
Bluetooth RSSI and hotspot Wi-Fi RSSI measure different radio links and must
not be labelled as the phone's cellular reception. The app leaves unknown
bars/network generation unset.

## Existing projects and Apple source

- [keychron-macos research](https://github.com/bkovacev/keychron-macos/blob/219e5a1bc7296bcc79fb4d36f30bc001c7cf0ec3/docs/RESEARCH.md)
  and [power-source publisher](https://github.com/bkovacev/keychron-macos/blob/219e5a1bc7296bcc79fb4d36f30bc001c7cf0ec3/macos/Sources/K10ProBattery/PowerSource.swift)
  publish an accessory battery using IOKit SPI, instead of modifying a widget.
- [Apple's IOPowerSourcesPrivate.h](https://github.com/apple-oss-distributions/IOKitUser/blob/main/ps.subproj/IOPowerSourcesPrivate.h)
  declares `IOPSCreatePowerSource`, `IOPSSetPowerSourceDetails` and
  `IOPSReleasePowerSource`, and documents the process-owned lifecycle.
- [Apple's IOPSKeys.h](https://github.com/apple-oss-distributions/IOKitUser/blob/main/ps.subproj/IOPSKeys.h)
  documents capacity and required power-source state fields.
- [AirBattery](https://github.com/lihaoyun6/AirBattery) and
  [BatteryBoard](https://github.com/subhoS/BatteryBoard) implement their own
  widgets. Those are alternatives, not proof of adding a device to Apple's
  existing Batteries widget.
- [MiniWatts research](https://github.com/ResistanceTo/MiniWatts/blob/master/CLAUDE.md)
  records the modern observer-based BatteryCenter API and an iOS sandbox
  restriction. Its iOS result must not be assumed to apply identically on Mac.

## Local proof and remaining uncertainty

A bounded, separate Objective-C research process loaded the exported IOKit
functions dynamically. It registered an **Accessory Source**, using a recent
Samsung-reported percentage. Create and set-details returned success;
`pmset -g accps` contained the research entry. Releasing it returned success.
The process ran without root, new entitlements, injection or SIP changes.

The source needs `Power Source State`; leaving it out returned bad argument.
The first probe used a test state solely to validate registration. RC1 then
verified that `Unknown` is accepted, with no `Is Charging` boolean, and uses
that representation. Only accessory sources are published; the Galaxy is
never registered as the Mac's internal battery or UPS.

The independent BatteryCenter reader instantiated the modern controller and
registered an observer, but returned no connected devices. Thus accessory
registry publication was demonstrated first, while widget consumption was
initially unverified. The RC1 consumer trace described above resolves that
gap using the actual system widget process. Its real-phone visual acceptance
remains separate from the controlled fixture and lifecycle tests.

If Apple filters this source, a dedicated Galaxy Continuity WidgetKit
extension can read the application's cached reports. That would be our own
widget, with packaging/signing and refresh-budget work, rather than an
extension point into Apple's widget. No additional phone polling is needed
just to render already cached values.
