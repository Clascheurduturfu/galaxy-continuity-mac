# 2026-10-22 — Multi Control Pointer Stutter Research

## Overview

Compared the Galaxy Book's stock Multi Control pointer pipeline against the initial macOS implementation to isolate the causes of cursor stutter and design controlled experiments.

---

## Architectural Comparison

| Stage | Galaxy Book (`SamsungMultiControl`) | Initial macOS Prototype | Finding |
|---|---|---|---|
| **Capture** | `RawInputHook` (`WM_INPUT`, relative `RAWMOUSE` `LastX`/`LastY`) | `CGEvent.tapCreate` on the main run loop | Main run-loop callbacks can stall behind SwiftUI layout passes. |
| **Pacing** | `MCFMessage.SendMouseMessageM` sends on an arriving input event once `elapsed >= 6 ms`, accumulating earlier deltas | Repeating 6 ms main-queue timer | A repeating timer out of phase with 125 Hz input adds up to 6 ms of extra age jitter. |
| **Sentinel Vector** | Emits `(-100, -100)` when returning focus to the PC | No guard on accumulated deltas | Android `inputinject/e.java` treats `(-100, -100)` as a command to clear its pending mouse queue rather than move the cursor. |
| **Transport & QoS** | UDP for `M` movement, TCP for `C`/`K`/`W`; requests UDP `LowDelay` / DSCP `48` | UDP for `M`, TCP for `C`/`K`/`W`; `SO_NET_SERVICE_TYPE = NET_SERVICE_TYPE_RD` | Local UDP fallback was 0%, indicating scheduling jitter rather than TCP fallback. |
| **Phone Receiver** | `InputOptimizeHelper` sleeps up to 5 ms when sender `elapsed` exceeds arrival interval | Same phone receiver | Bursty main-thread delivery triggers extra receiver smoothing sleeps. |
