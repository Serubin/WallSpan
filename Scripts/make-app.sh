#!/bin/bash
# Assembles Wallspan.app from the SwiftPM products.
#
# SwiftPM cannot emit a bundle, so this builds both executables and lays them out by hand.
# Ad-hoc signed: enough to run locally and in CI, and to be re-signed with a Developer ID
# later without changing the layout.
#
# usage: Scripts/make-app.sh [--universal] [--out DIR]
set -euo pipefail

cd "$(dirname "$0")/.."

CONFIG=release
OUT=dist
ARCH_FLAGS=()
while [ $# -gt 0 ]; do
    case "$1" in
        --universal) ARCH_FLAGS=(--arch arm64 --arch x86_64); shift ;;
        --out) OUT="$2"; shift 2 ;;
        *) echo "unknown option: $1" >&2; exit 2 ;;
    esac
done

VERSION="$(git describe --tags --always --dirty 2>/dev/null || echo 0.0.0)"
# CFBundleVersion must be a dot-separated number; a describe like v0.1.0-3-gabc1234 is not.
SHORT="$(printf '%s' "$VERSION" | sed 's/^v//; s/-.*//')"
case "$SHORT" in ''|*[!0-9.]*) SHORT=0.0.0 ;; esac

swift build -c "$CONFIG" ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"}
BIN="$(swift build -c "$CONFIG" ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"} --show-bin-path)"

APP="$OUT/Wallspan.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Helpers" "$APP/Contents/Resources"

# `Wallspan` and `wallspan` cannot share a directory on a case-insensitive volume, which is
# the macOS default — cp would silently overwrite one with the other. Hence Helpers/ for the
# CLI, and hence the SwiftPM target being named WallspanApp rather than Wallspan.
cp "$BIN/WallspanApp" "$APP/Contents/MacOS/Wallspan"
cp "$BIN/wallspan" "$APP/Contents/Helpers/wallspan"

# Committed, not generated here: Scripts/make-icon.sh needs librsvg, which CI lacks.
test -f brand/AppIcon.icns || { echo "brand/AppIcon.icns missing — Scripts/make-icon.sh" >&2; exit 1; }
# Before codesign, or the resource is unsealed and --verify below fails.
cp brand/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>            <string>Wallspan</string>
    <key>CFBundleDisplayName</key>     <string>Wallspan</string>
    <key>CFBundleExecutable</key>      <string>Wallspan</string>
    <key>CFBundleIdentifier</key>      <string>net.serubin.wallspan.app</string>
    <!-- Not CFBundleIconName: that needs an Assets.car, which SwiftPM cannot produce. -->
    <key>CFBundleIconFile</key>        <string>AppIcon</string>
    <key>CFBundlePackageType</key>     <string>APPL</string>
    <key>CFBundleShortVersionString</key> <string>${VERSION#v}</string>
    <key>CFBundleVersion</key>         <string>$SHORT</string>
    <key>LSMinimumSystemVersion</key>  <string>14.0</string>
    <!-- Menu bar only: no Dock icon, no app menu. -->
    <key>LSUIElement</key>             <true/>
    <!-- Two instances would fight over pausing and resuming cycling. -->
    <key>LSMultipleInstancesProhibited</key> <true/>
    <key>NSHumanReadableCopyright</key>
    <string>Copyright (C) 2026 Solomon. GPL-3.0-or-later.</string>
</dict>
</plist>
PLIST

# --deep is deprecated for signing but still the simplest way to cover the nested helper;
# the helper is signed first so the outer signature seals an already-signed tree.
codesign --force --sign - --timestamp=none "$APP/Contents/Helpers/wallspan"
codesign --force --sign - --timestamp=none "$APP"
codesign --verify --deep --strict "$APP"

# ditto, not zip: zip mangles a signed bundle's symlinks and metadata, and the signature
# then fails to verify on the machine that unpacks it.
ZIP="$OUT/Wallspan-$VERSION.zip"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

echo "built   $APP  ($VERSION)"
echo "        $(lipo -archs "$APP/Contents/MacOS/Wallspan" 2>/dev/null || echo '?')"
echo "zipped  $ZIP"
