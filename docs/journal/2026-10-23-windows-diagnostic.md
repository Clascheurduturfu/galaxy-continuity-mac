# 2026-10-23 — Windows Hardware Gate & Diagnostic Findings

## Overview

Investigated how Galaxy Connect (`4.6.1217.0`) and ` GalaxyConnectedExperience` gate startup on non-Samsung Windows PCs:

1. **System Model Registry Check:**
   - `Commons.dll` (`MCFCommons.Helpers.DriverHelper.DeviceSupportHelper.IsSupportedDevice()`) and `CommonsNet.dll` check BIOS system manufacturer/product strings against Samsung Galaxy Book model identifiers.
2. **Extended BLE Advertising Check:**
   - Even when system model strings match a Galaxy Book, `WindowsMCFCore.exe` checks whether the Windows Bluetooth adapter supports extended BLE advertising at startup and exits if the adapter/driver rejects it.
3. **Clipboard Handler Activation Switch:**
   - `WindowsMCFCore` reads `HKLM\SOFTWARE\Samsung\SamsungSettings\ModuleContinueApps` (`OnOff`) before starting the Windows clipboard handler.
4. **macOS Implication:**
   - On macOS, Galaxy Continuity implements the MCF wire protocol directly over CoreBluetooth and Network.framework without running any Windows binaries or hardware model gates.
