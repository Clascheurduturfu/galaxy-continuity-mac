# 2026-10-22 — Multi Control Worker-Thread Pointer Implementation & Telemetry

## Changes Implemented

1. **Bounded Telemetry (`PointerTelemetry.swift` & `PointerPipeline.swift`):**
   - 4,096-sample ring buffers measuring OS event timestamp interval, callback interval, OS-to-callback lag, pacer decision interval, UDP send interval, `sendto` duration, oldest-event age, and timer lateness.
   - Records only durations and counts (`p50`/`p95`/`p99`/`max` and gaps `> 20 ms` / `> 50 ms`), never coordinates or keystrokes.
2. **Dedicated `.userInteractive` Worker Thread (`PointerSender.swift` & `PointerPipeline.swift`):**
   - `PointerCaptureEngine` owns the `CGEvent` tap, run-loop source, pacer timers, and `PointerPipeline` on a dedicated `continuity.pointer` worker thread.
   - AES-CBC encryption and `sendto` run directly on the worker thread through `PointerSender`.
3. **Event-Driven 6 ms Pacing:**
   - Sends immediately on an arriving event once $\ge 6\text{ ms}$ have passed, accumulates sub-6 ms deltas, and uses a single one-shot timer to flush the final delta.
4. **Reserved `(-100, -100)` Vector Guard (`PointerPacer.swift`):**
   - Splits any coincidental `(-100, -100)` movement vector into two halves with the same sum (`PointerVector.safeParts`).
5. **Tablet Layout Handshake Fix (`MultiControl.swift`):**
   - Re-sends `DEVICE_INFORMATION` and `NETWORK_INFORMATION` (up to 5 times) when the peer's `DEVICE_INFORMATION` arrives while not yet controlling, fixing a timing race on Galaxy Tab S9+ (`SM-X810`).

---

## Live Benchmark Results (Galaxy Tab S9+, 10-Second Runs)

| Configuration | Input Rate | Send Interval `p50 / p95 / p99 / max` (ms) | Send Gaps `> 20 ms` | Callback Gaps `> 20 ms` | Oldest-Event Age `p99` (ms) | UDP Sent / TCP Fallback |
|---|---|---|---|---|---|---|
| `timer`, `worker` | 125 Hz | `8.00 / 9.09 / 11.93 / 17.7` | 0 | 0 | `8.0` | `1235 / 0` |
| **`event`, `worker` (Default)** | **125 Hz** | **`8.00 / 8.69 / 9.42 / 18.8`** | **0** | **0** | **`2.6`** | **`1246 / 0`** |
| `timer`, `main` | 125 Hz | `8.05 / 12.01 / 18.30 / 30.4` | 10 | 10 | `20.2` | `1167 / 0` |
| `event`, `main` | 125 Hz | `7.99 / 8.83 / 19.02 / 32.5` | 11 | 11 | `16.2` | `1230 / 0` |
| `timer`, `worker` | 1000 Hz | `6.32 / 7.13 / 7.38 / 20.0` | 0 | 1 | `6.9` | `1543 / 0` |
| **`event`, `worker` (Default)** | **1000 Hz** | **`6.26 / 6.88 / 7.32 / 12.8`** | **0** | **0** | **`7.2`** | **`1578 / 0`** |
| `timer`, `main` | 1000 Hz | `6.50 / 8.41 / 11.98 / 28.6` | 10 | 8 | `22.2` | `1477 / 0` |
| `event`, `main` | 1000 Hz | `6.24 / 6.86 / 10.57 / 28.2` | 9 | 7 | `22.7` | `1552 / 0` |
