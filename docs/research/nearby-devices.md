# Nearby Devices & Unified Presence Registry

Samsung **Nearby Devices** (`SamsungMyDevices` `3.0.22.0` and `NearbyDevicesSdk.dll`) separates **account membership**, **physical radio observations**, **feature capabilities**, and **active connections**. Galaxy Continuity models this separation in `NearbyPeers.swift` and `Discovery.swift`, and pairs it with a smart auto-connect state machine in `App.swift`.

---

## 1. How Samsung Nearby Devices Works on Windows

Analysis of `NearbyDevicesSdk.decompiled.cs` shows that Nearby Devices is not merely a Bonjour browser:
- `MCFSdkManager.StartDiscovery` / `StartExtendedDiscovery` subscribes to `DiscoveryHelper.OnDeviceDiscoveredOrUpdated`.
- When a peer is observed, `DiscoveryHelper` inspects MCF context availability bytes, `StorageShareSupportedRole`, family/account membership, and One UI version before publishing the peer to `DiscoveryManager.AddDevice`.
- `DiscoveryManager.RemoveDevice` retains a device in the visible list while a connection is active or in progress, rather than dropping it on a momentary BLE advertisement gap.

---

## 2. Unified macOS Presence Model (`NearbyPeerRegistry`)

In `Sources/ContinuityCore/NearbyPeers.swift`, `NearbyPeerRegistry` acts as a pure, deterministic state reducer combining three distinct inputs:

1. **Account Peers (`ContinuityProfile.Peer`):**
   - Devices enrolled under the user's Samsung account (phones, tablets, Galaxy Books). An account entry alone is labeled `"Samsung account device · not detected nearby"`, never falsely shown as nearby.
2. **Passive Multi-Peer Bluetooth Scanner (`NearbyBluetoothScanner`):**
   - Continues observing BLE advertisements even after the primary phone connects.
   - Uses `MCFAdvertisement.context` with the account fingerprint to match short Bluetooth address hints against registered peers.
   - Ambiguous address hints (matching more than one registered peer), malformed packets, or wrong-account advertisements are ignored.
   - Recognized observations carry a 40-second freshness window (`bluetoothLifetime = 40`) and record whether an L2CAP CoC PSM is currently advertised (`bluetoothConnectable`).
3. **Bonjour Local Network Services (`_mcfds._tcp`):**
   - Decrypts the `DEVICE_ID` TXT record using the account key and merges resolved `host:port` endpoints into the matching peer row.
   - When a registered Galaxy PC advertises a fresh port on `_mcfds._tcp`, `LANPresence.noteDiscoveredEndpoint` updates its saved endpoint and reconnects automatically.

---

## 3. Smart Auto-Connect Coordinator (`LabModel`)

To deliver a Galaxy Book–like experience on macOS, `LabModel` in `Sources/ContinuityApp/App.swift` drives automatic connection from four triggers whenever **Auto-Connect** is enabled and not manually paused:

1. **App Launch:** Immediately connects to the preferred Galaxy phone once the saved Samsung profile is loaded.
2. **Proximity Advertisement:** When `NearbyBluetoothScanner` observes the preferred phone advertising a connectable BLE CoC PSM while the Mac is disconnected or waiting on a backoff timer, the Mac cancels the wait and connects immediately.
3. **Mac Wake from Sleep:** Observes `NSWorkspace.didWakeNotification` and initiates reconnection 1.5 seconds after wake.
4. **Network Path Recovery:** Uses `NWPathMonitor` to nudge both LAN Galaxy PC sessions and phone reconnection when Wi-Fi transitions to `.satisfied`.

Failed connection attempts use bounded exponential backoff (`[2, 5, 10, 20, 45, 60]` seconds) with a live countdown in the UI and one-click **Pause / Resume**.
