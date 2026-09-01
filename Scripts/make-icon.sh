#!/bin/bash
# Regenerates brand/AppIcon.icns from brand/wallspan-icon.svg.
#
# Committed rather than built by make-app.sh, since CI has no librsvg. Output is
# byte-unstable across librsvg builds (2.62.3 / cairo 1.18.4 here), so run it only when
# the SVG changes.
#
# usage: Scripts/make-icon.sh
set -euo pipefail

cd "$(dirname "$0")/.."

command -v rsvg-convert > /dev/null || {
    echo "rsvg-convert not found — brew install librsvg" >&2
    exit 1
}

SRC=brand/wallspan-icon.svg
OUT=brand/AppIcon.icns

SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH"' EXIT
SET="$SCRATCH/AppIcon.iconset"
mkdir -p "$SET"

# The macOS icon grid puts the body in 824 of 1024px; edge to edge it looks oversized
# beside other Dock icons. The inset is subtracted from both sides rather than scaling the
# body independently, because two truncating divisions leave it 2px off-centre at 16px.
#
# --page-* is load-bearing: iconutil checks each PNG's pixel size against its filename.
render() {
    local size="$1" name="$2" off body
    off=$(( (size * 100 + 512) / 1024 ))
    body=$(( size - 2 * off ))
    rsvg-convert --page-width "$size" --page-height "$size" \
                 --width "$body" --height "$body" --top "$off" --left "$off" \
                 -o "$SET/$name.png" "$SRC"
}

# Pairs, not a size list: 32, 256 and 512 each fill two differently named slots.
for spec in 16:icon_16x16 32:icon_16x16@2x 32:icon_32x32 64:icon_32x32@2x \
            128:icon_128x128 256:icon_128x128@2x 256:icon_256x256 \
            512:icon_256x256@2x 512:icon_512x512 1024:icon_512x512@2x; do
    render "${spec%%:*}" "${spec##*:}"
done

iconutil --convert icns --output "$OUT" "$SET"

echo "wrote $OUT ($(du -h "$OUT" | cut -f1))"
