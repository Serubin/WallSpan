#!/bin/bash
# Computes the version this build should call itself, and optionally stamps it in.
#
# One place holds the scheme, because three consumers have to agree on it: the binary
# (BuildInfo.swift), the app bundle's Info.plist, and the artifact filenames. When they
# disagree you get a download whose name promises one build and whose `version` reports
# another.
#
#   release   0.2.0                         --version, chosen when the release is dispatched
#   beta      0.2.0-beta.3, 0.2.0-rc.1      a signed prerelease
#   unsigned  0.2.0-unsigned.1              an ad-hoc prerelease, never offered as an update
#   snapshot  0.2.1-snapshot.7+g1a2b3c4     after v0.2.0; 7 = commits since that tag
#   dev       0.2.1-dev.pr42+g1a2b3c4
#   local     0.0.0-local                   an unstamped working tree
#
# usage: Scripts/version.sh --channel release|beta|unsigned|snapshot|dev|local
#                           [--version VERSION] [--pr N] [--sha REF] [--stamp]
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
        -h|--help) sed -n '2,19p' "$0"; exit 0 ;;
        *) die "unknown option: $1" ;;
    esac
done

BUILDINFO_SWIFT=Sources/WallspanCore/BuildInfo.swift

# No leading zeros, and at most six digits, so bash arithmetic can neither misread nor wrap.
NUM='(0|[1-9][0-9]{0,5})'
CORE_RE="$NUM\.$NUM\.$NUM"

# Zero-padded, so two versions compare as strings exactly as they do as numbers.
pad() {
    [[ "$1" =~ ^$CORE_RE$ ]]
    printf '%06d%06d%06d' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}"
}

SHA="$(git rev-parse "$REF")"
SHORT="$(git rev-parse --short=7 "$SHA")"
# Total commits, not commits-since-tag: CFBundleVersion has to increase forever, and a
# count that resets at each tag would go backwards.
TOTAL="$(git rev-list --count "$SHA")"

# The highest stable and prerelease versions on this line. Only exact vX.Y.Z counts as
# stable: a beta would reset the count below, and backup/* or a stray v2.0 is no release.
STABLE=""
PRERELEASE=""
# Assigned first, so a failed listing stops the script instead of reading as "no tags".
TAGS="$(git tag --merged "$SHA" --list 'v*')"
while IFS= read -r tag; do
    if [[ "$tag" =~ ^v($CORE_RE)$ ]]; then
        core="${BASH_REMATCH[1]}"
        if [ -z "$STABLE" ] || [[ "$(pad "$core")" > "$(pad "$STABLE")" ]]; then
            STABLE="$core"
        fi
    elif [[ "$tag" =~ ^v($CORE_RE)-(beta|rc|unsigned)\.[1-9][0-9]*$ ]]; then
        core="${BASH_REMATCH[1]}"
        if [ -z "$PRERELEASE" ] || [[ "$(pad "$core")" > "$(pad "$PRERELEASE")" ]]; then
            PRERELEASE="$core"
        fi
    fi
done <<<"$TAGS"
if [ -n "$STABLE" ]; then
    SINCE="$(git rev-list --count "v$STABLE..$SHA")"
else
    SINCE="$TOTAL"
fi

unreleased_base() {
    # Without history the tags above are missing, and the base would silently fall to 0.0.1.
    [ "$(git rev-parse --is-shallow-repository)" = false ] \
        || die "--channel $CHANNEL needs full history and tags; fetch with fetch-depth: 0"
    local base=0.0.1
    if [ -n "$STABLE" ]; then
        [[ "$STABLE" =~ ^$CORE_RE$ ]]
        base="${BASH_REMATCH[1]}.${BASH_REMATCH[2]}.$((BASH_REMATCH[3] + 1))"
    fi
    # A later version that already has a prerelease here: the build has to sort above it.
    if [ -n "$PRERELEASE" ] && [[ "$(pad "$PRERELEASE")" > "$(pad "$base")" ]]; then
        base="$PRERELEASE"
    fi
    echo "$base"
}

case "$CHANNEL" in
    release)
        [[ "$VERSION" =~ ^$CORE_RE$ ]] || die "--channel release needs --version X.Y.Z"
        FULL="$VERSION"
        ;;
    beta)
        [[ "$VERSION" =~ ^$CORE_RE-(beta|rc)\.[1-9][0-9]*$ ]] \
            || die "--channel beta needs --version X.Y.Z-beta.N or X.Y.Z-rc.N"
        FULL="$VERSION"
        ;;
    unsigned)
        [[ "$VERSION" =~ ^$CORE_RE-unsigned\.[1-9][0-9]*$ ]] \
            || die "--channel unsigned needs --version X.Y.Z-unsigned.N"
        FULL="$VERSION"
        ;;
    snapshot)
        FULL="$(unreleased_base)-snapshot.$SINCE+g$SHORT"
        ;;
    dev)
        [ -n "$PR" ] || die "--channel dev needs --pr N"
        FULL="$(unreleased_base)-dev.pr$PR+g$SHORT"
        ;;
    local)
        # Deliberately identical to the checked-in BuildInfo.swift, so `--channel local
        # --stamp` is how you undo a stamp.
        FULL="0.0.0-local"
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
bundle_version=$CORE.$TOTAL
sha=$SHA
OUT

[ "$STAMP" -eq 1 ] || exit 0

STAMPED="$FULL"
# An unstamped tree reports fallbackVersion from Version.swift; leaving the constant empty
# is what makes `local` round-trip back to the checked-in file exactly.
[ "$CHANNEL" = local ] && STAMPED=""

cat > "$BUILDINFO_SWIFT" <<STAMPED_FILE
// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Solomon <serubin@serubin.net>

// Rewritten in place by \`Scripts/version.sh --stamp\`, never by hand; checked in with an
// unstamped tree's values so that a bare \`swift build\` still compiles.
extension Wallspan {
    /// Empty in a working tree, so \`version\` falls back to \`fallbackVersion\`.
    static let stampedVersion = "$STAMPED"

    /// How this build was produced: \`release\`, \`beta\`, \`unsigned\`, \`snapshot\`, \`dev\`, or
    /// \`local\`.
    public static let channel = "$CHANNEL"

    /// Short commit the build came from; empty when it was not stamped.
    public static let commit = "$SHORT"
}
STAMPED_FILE
