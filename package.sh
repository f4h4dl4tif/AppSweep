#!/bin/bash
# Builds a universal AppSweep.app and wraps it in an installer package: dist/AppSweep-<version>.pkg
set -euo pipefail
cd "$(dirname "$0")"

UNIVERSAL=1 ./build.sh

VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Resources/Info.plist)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/root/Applications" dist
cp -R build/AppSweep.app "$WORK/root/Applications/"

# Always install into /Applications, even if another copy of AppSweep exists elsewhere on the Mac.
pkgbuild --analyze --root "$WORK/root" "$WORK/components.plist" >/dev/null
/usr/libexec/PlistBuddy -c "Add :0:BundleIsRelocatable bool false" "$WORK/components.plist"

pkgbuild --root "$WORK/root" \
  --component-plist "$WORK/components.plist" \
  --identifier local.appsweep.AppSweep.pkg \
  --version "$VERSION" \
  --install-location / \
  "$WORK/AppSweep-component.pkg" >/dev/null

cat > "$WORK/distribution.xml" <<XML
<?xml version="1.0" encoding="utf-8"?>
<installer-gui-script minSpecVersion="2">
    <title>AppSweep</title>
    <welcome file="welcome.html" mime-type="text/html"/>
    <conclusion file="conclusion.html" mime-type="text/html"/>
    <options customize="never" require-scripts="false" hostArchitectures="arm64,x86_64"/>
    <domains enable_localSystem="true"/>
    <volume-check>
        <allowed-os-versions><os-version min="14.0"/></allowed-os-versions>
    </volume-check>
    <choices-outline><line choice="default"><line choice="app"/></line></choices-outline>
    <choice id="default"/>
    <choice id="app" visible="false"><pkg-ref id="local.appsweep.AppSweep.pkg"/></choice>
    <pkg-ref id="local.appsweep.AppSweep.pkg" version="$VERSION" onConclusion="none">AppSweep-component.pkg</pkg-ref>
</installer-gui-script>
XML

OUT="dist/AppSweep-$VERSION.pkg"
productbuild --distribution "$WORK/distribution.xml" \
  --resources Installer/resources \
  --package-path "$WORK" \
  "$OUT" >/dev/null

echo "Created $(pwd)/$OUT ($(du -h "$OUT" | cut -f1))"
