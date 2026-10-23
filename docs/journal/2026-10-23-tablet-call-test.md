# 2026-10-23 — Native Tablet CMC Overseas Call Verification

## Overview

Verified native Samsung call-continuity (`com.samsung.android.secondconnection.SecondConnectionService`) on a Wi-Fi Galaxy Tab S9+ (`SM-X810`) and confirmed that the macOS CMC calling implementation remains completely independent of local Bluetooth/LAN proximity discovery.

---

## Observations

1. **Tablet Call Sequence:**
   - Initiated an authorized `ACTION_CALL` through Android Telecom on `SM-X810`.
   - Observed `DIALING` (+2 s) → `ACTIVE` (+13 s) → clean disconnect via `SecondConnectionService`.
   - Confirmed remote/overseas operation across separate networks.
2. **Mac Independence from Nearby Discovery:**
   - Because Galaxy Continuity on macOS registers directly with Samsung's cloud entitlement and IMS P-CSCF over TLS, placing and receiving calls does not require the primary phone to be nearby over Bluetooth or on the same Wi-Fi subnet.
