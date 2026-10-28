#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
python3 scripts/bootstrap-calling.py
CONTINUITY_CALL_DIAGNOSTICS_DIR="$PWD/.build/test-diagnostics" swift test
swift build -c release
APP="dist/Galaxy Continuity Lab.app"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/GalaxyContinuityLab "$APP/Contents/MacOS/GalaxyContinuityLab"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>GalaxyContinuityLab</string>
<key>CFBundleIdentifier</key><string>local.galaxy-continuity-lab</string>
<key>CFBundleName</key><string>Galaxy Continuity</string>
<key>CFBundleDisplayName</key><string>Galaxy Continuity</string>
<key>CFBundleShortVersionString</key><string>1.1-beta.4</string>
<key>CFBundleVersion</key><string>1.1-beta.4</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>NSLocalNetworkUsageDescription</key><string>Discover and connect to your Samsung continuity devices on this network.</string>
<key>NSBonjourServices</key><array><string>_mcfds._tcp</string></array>
<key>NSBluetoothAlwaysUsageDescription</key><string>Connect to your Galaxy phone for continuity and to your paired Galaxy Buds for audio handoff.</string>
<key>NSMicrophoneUsageDescription</key><string>Use your Mac microphone when you choose to make or answer a phone call.</string>
<key>NSContactsUsageDescription</key><string>Show your Mac contacts locally when you choose Load Contacts. Selecting a number fills the dialer; contacts are never uploaded.</string>
<key>NSLocationUsageDescription</key><string>macOS requires location permission to find and join your phone's Wi-Fi hotspot.</string>
<key>NSLocationWhenInUseUsageDescription</key><string>Find your Galaxy phone's Wi-Fi hotspot when you choose Connect using phone.</string>
</dict></plist>
PLIST
mkdir -p "$APP/Contents/Resources/Notices"
swift scripts/make-icon.swift .build/AppIcon.iconset
iconutil -c icns -o "$APP/Contents/Resources/AppIcon.icns" .build/AppIcon.iconset
cp docs/THIRD_PARTY_NOTICES.md docs/third-party/samsung-re-health-LICENSE.txt "$APP/Contents/Resources/Notices/"
cp docs/third-party/calling-*-LICENSE.txt "$APP/Contents/Resources/Notices/"
bash scripts/build-wifiagent-hook.sh
codesign --force --sign - --requirements '=designated => identifier "local.galaxy-continuity-lab"' "$APP"
cp .build/release/continuity dist/continuity
