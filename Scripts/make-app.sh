#!/bin/bash
# Assembles Wallspan.app from the SwiftPM products.
#
# SwiftPM cannot emit a bundle, so this builds both executables and lays them out by hand.
# Ad-hoc signed with the hardened runtime; the release workflow re-signs the same layout
# with a Developer ID.
#
# usage: Scripts/make-app.sh [--universal] [--out DIR]
#                            [--version STRING] [--build-version N.N.N]
set -euo pipefail

cd "$(dirname "$0")/.."

CONFIG=release
OUT=dist
VERSION=""
SHORT=""
ARCH_FLAGS=()
while [ $# -gt 0 ]; do
    case "$1" in
        --universal) ARCH_FLAGS=(--arch arm64 --arch x86_64); shift ;;
        --out) OUT="$2"; shift 2 ;;
        --version) VERSION="$2"; shift 2 ;;
        --build-version) SHORT="$2"; shift 2 ;;
        *) echo "unknown option: $1" >&2; exit 2 ;;
    esac
done

# Scripts/version.sh is the authority when it has run — CI stamps BuildInfo.swift before
# building, which leaves the tree dirty, so `describe --dirty` would brand every CI build
# `-dirty`. The describe stays as the answer for a hand build that passed no version.
if [ -z "$VERSION" ]; then
    VERSION="$(git describe --tags --always --dirty --match 'v[0-9]*' --exclude 'v*-*' \
        2>/dev/null || echo 0.0.0)"
fi
if [ -z "$SHORT" ]; then
    # CFBundleVersion must be a dot-separated number; a describe like v0.1.0-3-gabc1234
    # is not.
    SHORT="$(printf '%s' "$VERSION" | sed 's/^v//; s/[-+].*//')"
    case "$SHORT" in ''|*[!0-9.]*) SHORT=0.0.0 ;; esac
fi

# `+` is fine in a version string but not in a filename anyone has to type or checksum.
SLUG="${VERSION//+/.}"

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

# The bundled CLI is the fallback for a PATH CLI outside the app's schema range, so a bundle
# whose own CLI is outside it would have nothing to fall back to.
refuse_bundle() {
    rm -rf "$APP"
    echo "error: $1" >&2
    echo "  A schema bump must raise Contract.maximumSchema (Sources/WallspanApp/Contract.swift)" >&2
    echo "  and update the app's mirrors in the same change; see \"When the integer moves\" in" >&2
    echo "  docs/cli-json-contract.md." >&2
    exit 1
}
SUPPORTED="$("$APP/Contents/MacOS/Wallspan" --supported-schemas 2>/dev/null)" || SUPPORTED=""
MIN_SCHEMA="" MAX_SCHEMA="" EXTRA=""
read -r MIN_SCHEMA MAX_SCHEMA EXTRA <<<"$SUPPORTED" || true
[ -z "$EXTRA" ] || MAX_SCHEMA=""
CLI_SCHEMA="$("$APP/Contents/Helpers/wallspan" version --json 2>/dev/null \
    | python3 -c 'import sys,json;print(json.load(sys.stdin)["schema"])' 2>/dev/null)" \
    || CLI_SCHEMA=""
for value in "$MIN_SCHEMA" "$MAX_SCHEMA" "$CLI_SCHEMA"; do
    case "$value" in
        ''|*[!0-9]*) refuse_bundle "could not read the schemas (app '$SUPPORTED', CLI '$CLI_SCHEMA')" ;;
    esac
done
if [ "$CLI_SCHEMA" -lt "$MIN_SCHEMA" ] || [ "$CLI_SCHEMA" -gt "$MAX_SCHEMA" ]; then
    RANGE="schema ${MIN_SCHEMA}"
    [ "$MIN_SCHEMA" -eq "$MAX_SCHEMA" ] || RANGE="schemas ${MIN_SCHEMA}–${MAX_SCHEMA}"
    refuse_bundle "the bundled CLI speaks schema ${CLI_SCHEMA}; the app understands ${RANGE}"
fi

# The hardened runtime here too, so a local or PR build breaks the way a release would.
Scripts/sign-app.sh --identity - "$APP"
Scripts/check-signature.sh "$APP" "$APP/Contents/Helpers/wallspan"

# ditto, not zip: zip mangles a signed bundle's symlinks and metadata, and the signature
# then fails to verify on the machine that unpacks it.
ZIP="$OUT/Wallspan-$SLUG.zip"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

echo "built   $APP  ($VERSION)"
echo "        $(lipo -archs "$APP/Contents/MacOS/Wallspan" 2>/dev/null || echo '?')"
echo "zipped  $ZIP"
