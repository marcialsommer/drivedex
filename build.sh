#!/bin/bash
# Builds DriveDex.app and DriveDex.dmg. Runs on macOS (used by the GitHub Actions workflow).
set -euo pipefail
cd "$(dirname "$0")"
trap 'echo "::error title=build.sh failed::line $LINENO: $BASH_COMMAND"' ERR
VERSION="${VERSION:-1.0}"
BUILD="${BUILD:-1}"
OUT=build
APP="$OUT/DriveDex.app"
rm -rf "$OUT" && mkdir -p "$OUT"

SDK="$(xcrun --show-sdk-path)"
swift --version
for ARCH in arm64 x86_64; do
  # Errors are also re-emitted as GitHub annotations so they show up on the run page.
  if ! swiftc -O -target "$ARCH-apple-macos13.0" -sdk "$SDK" Sources/*.swift -o "$OUT/DriveDex-$ARCH" \
      -framework AppKit -framework WebKit -framework DiskArbitration -framework ServiceManagement \
      -framework UserNotifications -lsqlite3 2>&1 | tee "$OUT/swiftc-$ARCH.log"; then :; fi
  if [ ! -f "$OUT/DriveDex-$ARCH" ]; then
    grep -E "error" "$OUT/swiftc-$ARCH.log" | sort -u | head -45 | \
      sed -E -e 's#^.*/(Sources/[^:]+):([0-9]+):([0-9]+): error: (.*)$#::error file=\1,line=\2,col=\3::\4#' \
             -e '/^::error/!s#^(.*)$#::error title=swiftc::\1#'
    tail -5 "$OUT/swiftc-$ARCH.log" | sed 's#^#::warning title=swiftc tail::#'
    exit 1
  fi
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
