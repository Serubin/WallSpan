#!/bin/bash
# Picks the next beta or rc number for a base version, or checks one typed by hand.
#
# usage: Scripts/next-prerelease.sh (--kind beta|rc --base X.Y.Z | --check VERSION)
#                                   [--repo OWNER/NAME] [--tags-file FILE]
#
# --tags-file replaces origin's tags and the release list, one tag per line, for testing.
set -euo pipefail

KIND=""
BASE=""
CHECK=""
REPO="${GH_REPO:-Serubin/WallSpan}"
TAGS_FILE=""

die() { echo "next-prerelease.sh: $*" >&2; exit 2; }

while [ $# -gt 0 ]; do
    case "$1" in
        --kind) KIND="${2-}"; shift 2 ;;
        --base) BASE="${2-}"; shift 2 ;;
        --check) CHECK="${2-}"; shift 2 ;;
        --repo) REPO="${2-}"; shift 2 ;;
        --tags-file) TAGS_FILE="${2-}"; shift 2 ;;
        -h|--help) sed -n '2,7p' "$0"; exit 0 ;;
        *) die "unknown option: $1" ;;
    esac
done

WANT=0
if [ -n "$CHECK" ]; then
    [ -z "$KIND$BASE" ] || die "--check takes neither --kind nor --base"
    [[ "$CHECK" =~ ^([0-9]+\.[0-9]+\.[0-9]+)-(beta|rc)\.([1-9][0-9]*)$ ]] \
        || die "not X.Y.Z-beta.N or X.Y.Z-rc.N: $CHECK"
    BASE="${BASH_REMATCH[1]}"
    KIND="${BASH_REMATCH[2]}"
    WANT="${BASH_REMATCH[3]}"
fi
case "$KIND" in
    beta|rc) ;;
    *) die "--kind must be beta or rc" ;;
esac
[[ "$BASE" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "--base must be X.Y.Z"

if [ -n "$TAGS_FILE" ]; then
    TAGS="$(cat "$TAGS_FILE")"
else
    [[ "$REPO" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || die "--repo must be OWNER/NAME"
    # Each source fails the script on its own: an unreadable list must not read as empty.
    REMOTE="$(git ls-remote --tags --refs origin | sed 's|^.*refs/tags/||')"
    # Drafts included: a draft holds its tag name before the tag exists.
    RELEASES="$(gh api --paginate "repos/$REPO/releases?per_page=100" --jq '.[].tag_name')"
    TAGS="$(printf '%s\n%s\n' "$REMOTE" "$RELEASES")"
fi

MAX_BETA=0
MAX_RC=0
while IFS= read -r tag; do
    if [ "$tag" = "v$BASE" ]; then
        die "v$BASE already exists; bump baseVersion before cutting a prerelease"
    fi
    [[ "$tag" =~ ^v([0-9]+\.[0-9]+\.[0-9]+)-(beta|rc)\.([1-9][0-9]*)$ ]] || continue
    [ "${BASH_REMATCH[1]}" = "$BASE" ] || continue
    n="${BASH_REMATCH[3]}"
    if [ "${BASH_REMATCH[2]}" = beta ]; then
        [ "$n" -le "$MAX_BETA" ] || MAX_BETA="$n"
    else
        [ "$n" -le "$MAX_RC" ] || MAX_RC="$n"
    fi
done <<<"$TAGS"

if [ "$KIND" = beta ] && [ "$MAX_RC" -gt 0 ]; then
    die "$BASE-rc.$MAX_RC exists; a beta would sort below it"
fi
if [ "$KIND" = beta ]; then NEXT=$((MAX_BETA + 1)); else NEXT=$((MAX_RC + 1)); fi

if [ "$WANT" -eq 0 ]; then
    WANT="$NEXT"
elif [ "$WANT" -lt "$NEXT" ]; then
    die "$CHECK is not newer than $BASE-$KIND.$((NEXT - 1))"
fi
echo "$BASE-$KIND.$WANT"
