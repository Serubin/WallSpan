#!/bin/bash
# Packages a built Wallspan.app into the release assets, taking the CLI from inside the bundle.
#
# usage: Scripts/package.sh --slug SLUG [--out DIR] [--docs DIR] APP
#
# Prints `key=value` lines, appendable straight to $GITHUB_OUTPUT.
set -euo pipefail

SLUG=""
OUT=dist
DOCS="$(cd "$(dirname "$0")/.." && pwd)"

die() { echo "package.sh: $*" >&2; exit 2; }

while [ $# -gt 0 ]; do
    case "$1" in
        --slug) SLUG="${2-}"; shift 2 ;;
        --out) OUT="${2-}"; shift 2 ;;
        --docs) DOCS="${2-}"; shift 2 ;;
        -h|--help) sed -n '2,6p' "$0"; exit 0 ;;
        -*) die "unknown option: $1" ;;
        *) break ;;
    esac
done
[ $# -eq 1 ] || die "expected one APP, got $#"
APP="$1"
case "$SLUG" in ''|.*|*/*) die "bad --slug: '$SLUG'" ;; esac
CLI="$APP/Contents/Helpers/wallspan"
[ -x "$CLI" ] || die "no bundled CLI at $CLI"

NAME="wallspan-$SLUG-universal"
ZIP="Wallspan-$SLUG.zip"
mkdir -p "$OUT"

# Staged apart so the tarball's root directory and the bare binary can share a name.
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
mkdir "$STAGE/$NAME"
cp "$CLI" "$STAGE/$NAME/wallspan"
for doc in "$DOCS/README.md" "$DOCS/LICENSE"; do
    [ -f "$doc" ] && [ ! -L "$doc" ] || die "not a regular file: $doc"
done
cp "$DOCS/README.md" "$DOCS/LICENSE" "$STAGE/$NAME/"
# The README's banner is a repo-relative path, so it dangles without this.
cp -R "$DOCS/brand" "$STAGE/$NAME/"
# tar, not a bare binary: neither GitHub's artifact upload nor a browser download
# preserves the executable bit, so an unpacked binary arrives chmod 644.
tar -C "$STAGE" -czf "$OUT/$NAME.tar.gz" "$NAME"
# Shipped alongside anyway, for an install script or a Homebrew formula that would rather
# not unpack a tarball. It needs a chmod, and the release notes say so.
cp "$CLI" "$OUT/$NAME"

# ditto, not zip: zip mangles a signed bundle's symlinks and metadata, and the signature
# then fails to verify on the machine that unpacks it.
rm -f "$OUT/$ZIP"
ditto -c -k --keepParent "$APP" "$OUT/$ZIP"

# Bare filenames, so `shasum -c SHA256SUMS.txt` works in whatever directory the assets
# were downloaded into.
( cd "$OUT" && shasum -a 256 "$NAME.tar.gz" "$NAME" "$ZIP" > SHA256SUMS.txt )
cat "$OUT/SHA256SUMS.txt" >&2

echo "name=$NAME"
echo "tarball=$OUT/$NAME.tar.gz"
echo "binary=$OUT/$NAME"
echo "app-zip=$OUT/$ZIP"
echo "checksums=$OUT/SHA256SUMS.txt"
