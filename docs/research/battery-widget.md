# Galaxy batteries and the macOS Batteries widget

Research date: 2026-10-28. Tested on Apple Silicon, macOS 27.0.1.

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
The probe used a test state solely to validate registration. A production
bridge must not invent charging status from the percentage. It also needs
stable per-device identity, change-only updates, and removal on disconnect,
stale data and quit. Only accessory sources should be published; the Galaxy
must never be registered as the Mac's internal battery or UPS.

The independent BatteryCenter reader instantiated the modern controller and
registered an observer, but returned no connected devices. Thus accessory
registry publication is **demonstrated**, whereas visibility in the stock
Batteries widget remains **unverified**. This is a credible private-API route,
not a completed feature or evidence that a phone category renders correctly.
Next: inspect the actual widget while a temporary source exists and compare
accepted category/identity fields with a genuine accessory. No permanent
publisher is enabled in this release.

If Apple filters this source, a dedicated Galaxy Continuity WidgetKit
extension can read the application's cached reports. That would be our own
widget, with packaging/signing and refresh-budget work, rather than an
extension point into Apple's widget. No additional phone polling is needed
just to render already cached values.
