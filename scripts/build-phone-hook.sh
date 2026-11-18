#!/bin/bash
# Builds the experimental macOS Phone.app (callservicesd) hook dylib and places
# it inside the app bundle's Resources. Compile- and fixture-tested on CI;
# actual injection only happens on a SIP-disabled Mac when the user enables it.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p dist
arches=()
if [[ "$(uname -m)" == arm64 ]]; then arches=(-arch arm64 -arch arm64e); fi
clang "${arches[@]}" -dynamiclib -mmacosx-version-min=13.0 -O2 -fobjc-arc -Wall \
  -framework Foundation \
  -o dist/GalaxyContinuityPhoneHook.dylib \
  scripts/phone-hook/GalaxyContinuityPhoneHook.m
codesign --force --sign - dist/GalaxyContinuityPhoneHook.dylib
mkdir -p .build
clang -mmacosx-version-min=13.0 -O2 -fobjc-arc -Wall -framework Foundation \
  -o .build/phone-hook-tests scripts/phone-hook/test.m
.build/phone-hook-tests
cp dist/GalaxyContinuityPhoneHook.dylib "dist/Galaxy Continuity Lab.app/Contents/Resources/"
