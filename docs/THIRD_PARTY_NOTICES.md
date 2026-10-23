# Third-party notices

The native Samsung browser bootstrap and encryption envelope were adapted from this owner's Samsung Cloud Notes implementation, which adapted the MIT-licensed [samsung-re-health](https://github.com/charlesbel/samsung-re-health), Copyright (c) 2026 Charles Bel. Its complete license is included in `third-party/samsung-re-health-LICENSE.txt` and in the Mac app's Resources/Notices directory.

Continuity cloud registration, certificate enrollment, peer discovery, clipboard and AutoHotspotMDE interoperability were implemented separately using observed Samsung Windows/Android protocol behavior. No Samsung binary or SDK is bundled. Samsung trademarks belong to Samsung; this client is unofficial and unaffiliated.

Native calling groundwork statically links Cisco libSRTP 2.6.0 (BSD-style license), OpenCORE AMR 0.1.6 and VisualOn AMR-WB encoder 0.1.3 (Apache License 2.0). Complete upstream licenses are in `third-party/calling-*-LICENSE.txt` and the Mac app's Resources/Notices directory. `scripts/bootstrap-calling.py` records the upstream archive URLs and SHA-256 checksums and builds these in an isolated `.build` directory. No Samsung codec DLL is included.

The project uses Apple's system frameworks and has no bundled third-party Swift runtime dependencies. The authored client source is licensed under the repository's MIT LICENSE.

Hotspot system-menu feasibility was informed by the MIT-licensed [Tetherbug](https://github.com/xav-ie/Tetherbug) project (Xavier Ruiz). No Tetherbug code, Android app or Shizuku component is bundled. Its Apple Wi-Fi beacon-marker technique is separate from Samsung account hotspot activation and cannot provide Apple's BLE/Apple Account device section.
