#!/bin/bash
# Builds DriveDex.app and DriveDex.dmg. Runs on macOS (used by the GitHub Actions workflow).
set -euo pipefail
cd "$(dirname "$0")"
VERSION="${VERSION:-1.0}"
BUILD="${BUILD:-1}"
OUT=build
APP="$OUT/DriveDex.app"
rm -rf "$OUT" && mkdir -p "$OUT"

SDK="$(xcrun --show-sdk-path)"
for ARCH in arm64 x86_64; do
  swiftc -O -target "$ARCH-apple-macos13.0" -sdk "$SDK" Sources/*.swift -o "$OUT/DriveDex-$ARCH" \
    -framework AppKit -framework WebKit -framework DiskArbitration -framework ServiceManagement \
    -framework UserNotifications -lsqlite3
done
lipo -create "$OUT/DriveDex-arm64" "$OUT/DriveDex-x86_64" -output "$OUT/DriveDex"

mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$OUT/DriveDex" "$APP/Contents/MacOS/DriveDex"
sed -e "s/VERSION_PLACEHOLDER/$VERSION/" -e "s/BUILD_PLACEHOLDER/$BUILD/" Resources/Info.plist > "$APP/Contents/Info.plist"
cp Resources/index.html "$APP/Contents/Resources/"

ICONSET="$OUT/AppIcon.iconset"
mkdir -p "$ICONSET"
for S in 16 32 128 256 512; do
  sips -z $S $S Resources/icon.png --out "$ICONSET/icon_${S}x${S}.png" >/dev/null
  sips -z $((S*2)) $((S*2)) Resources/icon.png --out "$ICONSET/icon_${S}x${S}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

codesign --force --deep --sign - "$APP"

STAGE="$OUT/dmg"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "DriveDex" -srcfolder "$STAGE" -ov -format UDZO "$OUT/DriveDex.dmg"
echo "Built $OUT/DriveDex.dmg"
