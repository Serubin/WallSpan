#!/bin/bash
# Computes the version this build should call itself, and optionally stamps it in.
#
# One place holds the scheme, because three consumers have to agree on it: the binary
# (BuildInfo.swift), the app bundle's Info.plist, and the artifact filenames. When they
# disagree you get a download whose name promises one build and whose `version` reports
# another.
#
#   release   0.2.0
#   snapshot  0.2.0-snapshot.7+g1a2b3c4     7 = commits since the last v* tag
#   dev       0.2.0-dev.pr42+g1a2b3c4
#   local     0.1.0                         an unstamped working tree
#
# usage: Scripts/version.sh --channel release|snapshot|dev|local
#                           [--version X.Y.Z] [--pr N] [--sha REF] [--stamp]
#
# Prints `key=value` lines, appendable straight to $GITHUB_OUTPUT.
set -euo pipefail

cd "$(dirname "$0")/.."

CHANNEL=""
VERSION=""
PR=""
REF="HEAD"
STAMP=0

die() { echo "version.sh: $*" >&2; exit 2; }

while [ $# -gt 0 ]; do
    case "$1" in
        --channel) CHANNEL="${2-}"; shift 2 ;;
        --version) VERSION="${2-}"; shift 2 ;;
        --pr)      PR="${2-}"; shift 2 ;;
        --sha|--ref) REF="${2-}"; shift 2 ;;
        --stamp)   STAMP=1; shift ;;
        -h|--help) sed -n '2,17p' "$0"; exit 0 ;;
        *) die "unknown option: $1" ;;
    esac
done

VERSION_SWIFT=Sources/WallspanCore/Version.swift
BUILDINFO_SWIFT=Sources/WallspanCore/BuildInfo.swift

# The one hand-edited constant. Everything below is derived from it.
BASE="$(sed -n 's/.*baseVersion = "\([^"]*\)".*/\1/p' "$VERSION_SWIFT")"
[ -n "$BASE" ] || die "could not read baseVersion from $VERSION_SWIFT"

SHA="$(git rev-parse "$REF")"
SHORT="$(git rev-parse --short=7 "$SHA")"
# Total commits, not commits-since-tag: CFBundleVersion has to increase forever, and a
# count that resets at each tag would go backwards.
TOTAL="$(git rev-list --count "$SHA")"

# --match, because the repo carries backup/*, spr-backup/* and squashed/* tags that are
# not releases and must never be mistaken for one.
LAST_TAG="$(git describe --tags --abbrev=0 --match 'v[0-9]*' "$SHA" 2>/dev/null || true)"
if [ -n "$LAST_TAG" ]; then
    SINCE="$(git rev-list --count "$LAST_TAG..$SHA")"
else
    SINCE="$TOTAL"
fi

case "$CHANNEL" in
    release)
        FULL="${VERSION:-$BASE}"
        ;;
    snapshot)
        FULL="$BASE-snapshot.$SINCE+g$SHORT"
        ;;
    dev)
        [ -n "$PR" ] || die "--channel dev needs --pr N"
        FULL="$BASE-dev.pr$PR+g$SHORT"
        ;;
    local)
        # Deliberately identical to the checked-in BuildInfo.swift, so `--channel local
        # --stamp` is how you undo a stamp.
        FULL="$BASE"
        SHORT=""
        ;;
    "") die "--channel is required" ;;
    *)  die "unknown channel: $CHANNEL" ;;
esac

# `+` is legal in semver but not worth trusting in a filename: GitHub rewrites some
# characters in release asset names, and a renamed asset breaks the checksum file.
SLUG="${FULL//+/.}"

# CFBundleVersion must be dot-separated integers, so it gets the numeric core plus the
# commit count rather than the honest string, which goes in CFBundleShortVersionString.
CORE="${FULL%%-*}"; CORE="${CORE%%+*}"

cat <<OUT
version=$FULL
slug=$SLUG
channel=$CHANNEL
commit=$SHORT
base=$BASE
bundle_version=$CORE.$TOTAL
sha=$SHA
OUT

[ "$STAMP" -eq 1 ] || exit 0

STAMPED="$FULL"
# An unstamped tree reports baseVersion through the fallback in Version.swift; leaving the
# constant empty is what makes `local` round-trip back to the checked-in file exactly.
[ "$CHANNEL" = local ] && STAMPED=""

cat > "$BUILDINFO_SWIFT" <<STAMPED_FILE
// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Solomon <serubin@serubin.net>

// Overwritten in place by \`Scripts/version.sh --stamp\`; the values below are what an
// unstamped working tree reports. Checked in rather than generated so that a bare
// \`swift build\` still compiles — hand-edit \`baseVersion\` in Version.swift, not this file.
extension Wallspan {
    /// Empty in a working tree, so \`version\` falls back to \`baseVersion\`.
    static let stampedVersion = "$STAMPED"

    /// How this build was produced: \`release\`, \`snapshot\`, \`dev\`, or \`local\`.
    public static let channel = "$CHANNEL"

    /// Short commit the build came from; empty when it was not stamped.
    public static let commit = "$SHORT"
}
STAMPED_FILE
