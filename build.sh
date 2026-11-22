#!/bin/bash
# Builds AppSweep.app into ./build
set -euo pipefail
cd "$(dirname "$0")"

# UNIVERSAL=1 builds one app that runs on both Apple Silicon and Intel Macs.
if [ "${UNIVERSAL:-0}" = "1" ]; then
  swift build -c release --arch arm64 --arch x86_64
  BIN=$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/AppSweep
else
  swift build -c release
  BIN=.build/release/AppSweep
fi

ICON=Resources/AppIcon.icns
if [ ! -f "$ICON" ]; then
  TMP=$(mktemp -d)
  swift Scripts/make-icon.swift "$TMP/icon.png"
  SET="$TMP/AppIcon.iconset"; mkdir "$SET"
  for s in 16 32 128 256 512; do
    sips -z $s $s "$TMP/icon.png" --out "$SET/icon_${s}x${s}.png" >/dev/null
    sips -z $((s*2)) $((s*2)) "$TMP/icon.png" --out "$SET/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns "$SET" -o "$ICON"
  rm -rf "$TMP"
fi

APP=build/AppSweep.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/AppSweep"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp "$ICON" "$APP/Contents/Resources/AppIcon.icns"
# Sign with the local AppSweep certificate so macOS permissions (Full Disk Access, App Management)
# survive rebuilds. Falls back to ad-hoc signing if the signing keychain isn't set up.
KC="$(pwd)/signing/appsweep.keychain-db"
if [ -f "$KC" ] && [ -f signing/keychain-password.txt ]; then
  security unlock-keychain -p "$(cat signing/keychain-password.txt)" "$KC"
  ID=$(security find-identity "$KC" | awk '/AppSweep Local Signing/ {print $2; exit}')
  codesign --force --deep --keychain "$KC" --sign "$ID" -i local.appsweep.AppSweep "$APP"
  echo "Signed with AppSweep Local Signing ($ID)"
else
  codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || true
  echo "Warning: ad-hoc signed; permissions will reset on every rebuild"
fi

echo "Built $(pwd)/$APP"
echo "To install: cp -R \"$APP\" /Applications/"
