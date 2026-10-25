#!/bin/bash
# Builds the experimental Wi-Fi menu hook dylib and places it inside the app
# bundle's Resources, where the in-app option finds it. Compile-checked on CI;
# actual injection only happens on a SIP-disabled Mac when the user enables it.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p dist
clang -dynamiclib -O2 -fobjc-arc -Wall \
  -framework Foundation -framework CoreWLAN \
  -o dist/GalaxyContinuityWiFiMenuHook.dylib \
  scripts/wifiagent-hook/GalaxyContinuityWiFiMenuHook.m
codesign --force --sign - dist/GalaxyContinuityWiFiMenuHook.dylib
cp dist/GalaxyContinuityWiFiMenuHook.dylib "dist/Galaxy Continuity Lab.app/Contents/Resources/"
