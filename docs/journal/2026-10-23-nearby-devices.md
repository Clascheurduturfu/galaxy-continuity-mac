# 2026-10-23 — Nearby Devices SDK Analysis & Unified Presence

## Overview

Analyzed Samsung Nearby Devices (`SamsungMyDevices 3.0.22.0` and `NearbyDevicesSdk.dll`) and implemented `NearbyPeerRegistry` and `NearbyBluetoothScanner` in `Sources/ContinuityCore/NearbyPeers.swift`.

---

## Key Design Decisions

1. **Separating Account Membership from Physical Proximity:**
   - Previously, the Bonjour `_mcfds._tcp` list and the Samsung account `peers` picker were separate UI surfaces.
   - `NearbyPeerRegistry` unifies them into a single sorted list of `NearbyPeer` entries with explicit state labels (`Connected`, `Nearby over Bluetooth and local network`, `Nearby over Bluetooth`, `Found on the local network`, or `Samsung account device · not detected nearby`).
2. **Continuous Passive BLE Observation:**
   - `NearbyBluetoothScanner` continues listening for account-obfuscated BLE advertisements even after the primary phone connects, expiring stale radio observations after 40 seconds while keeping actively connected peers visible.
   - Short address hints must match a single unambiguous peer in the account profile before marking a device nearby.
3. **Dynamic Galaxy PC Port Updates:**
   - When a registered Galaxy Book advertises a new dynamic TCP port over `_mcfds._tcp`, `LANPresence.noteDiscoveredEndpoint` updates its saved endpoint and triggers an immediate connection attempt.
