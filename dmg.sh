#!/bin/bash
# Builds an Apple Silicon-only AppSweep.app and packs it into dist/AppSweep-<version>-AppleSilicon.dmg
set -euo pipefail
cd "$(dirname "$0")"

./build.sh   # native arm64 build on Apple Silicon
ARCHS=$(lipo -archs build/AppSweep.app/Contents/MacOS/AppSweep)
[ "$ARCHS" = "arm64" ] || { echo "Expected arm64-only binary, got: $ARCHS"; exit 1; }

VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Resources/Info.plist)
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
cp -R build/AppSweep.app "$STAGE/"
ln -s /Applications "$STAGE/Applications"
cp "Installer/How to Install.txt" "$STAGE/"

mkdir -p dist
OUT="dist/AppSweep-$VERSION-AppleSilicon.dmg"
rm -f "$OUT"
hdiutil create -volname "AppSweep" -srcfolder "$STAGE" -fs HFS+ -format UDZO -imagekey zlib-level=9 -ov "$OUT" >/dev/null
echo "Created $(pwd)/$OUT ($(du -h "$OUT" | cut -f1))"
