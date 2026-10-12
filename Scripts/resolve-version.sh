#!/bin/bash
# Turns the release workflow's version and kind into the exact version to tag, or refuses.
#
# usage: Scripts/resolve-version.sh --kind release|beta|rc|unsigned --base X.Y.Z
#                                   [--allow-jump] [--repo OWNER/NAME] [--tags-file FILE]
#
# --tags-file replaces origin's tags and the release list, one tag per line, for testing.
set -euo pipefail

KIND=""
BASE=""
ALLOW_JUMP=0
REPO="${GH_REPO:-Serubin/WallSpan}"
TAGS_FILE=""

die() { echo "resolve-version.sh: $*" >&2; exit 2; }

while [ $# -gt 0 ]; do
    case "$1" in
        --kind) KIND="${2-}"; shift 2 ;;
        --base) BASE="${2-}"; shift 2 ;;
        --allow-jump) ALLOW_JUMP=1; shift ;;
        --repo) REPO="${2-}"; shift 2 ;;
        --tags-file) TAGS_FILE="${2-}"; shift 2 ;;
        -h|--help) sed -n '2,7p' "$0"; exit 0 ;;
        *) die "unknown option: $1" ;;
    esac
done

case "$KIND" in
    release|beta|rc|unsigned) ;;
    *) die "--kind must be release, beta, rc or unsigned" ;;
esac
# No leading zeros, and at most six digits, so bash arithmetic can neither misread nor wrap.
NUM='(0|[1-9][0-9]{0,5})'
[[ "$BASE" =~ ^$NUM\.$NUM\.$NUM$ ]] || die "--base must be X.Y.Z, without leading zeros"

# Zero-padded, so two versions compare as strings exactly as they do as numbers.
pad() {
    [[ "$1" =~ ^$NUM\.$NUM\.$NUM$ ]]
    printf '%06d%06d%06d' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}"
}

if [ -n "$TAGS_FILE" ]; then
    TAGS="$(cat "$TAGS_FILE")"
    REMOTE="$TAGS"
else
    [[ "$REPO" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || die "--repo must be OWNER/NAME"
    # Each source fails the script on its own: an unreadable list must not read as empty.
    REMOTE="$(git ls-remote --tags --refs origin | sed 's|^.*refs/tags/||')"
    # Drafts included: a draft holds its tag name before the tag exists.
    RELEASES="$(gh api --paginate "repos/$REPO/releases?per_page=100" --jq '.[].tag_name')"
    TAGS="$(printf '%s\n%s\n' "$REMOTE" "$RELEASES")"
fi

STABLE=""
PRERELEASED=" "
TAKEN=0
MAX_BETA=0
MAX_RC=0
MAX_UNSIGNED=0
while IFS= read -r tag; do
    if [[ "$tag" =~ ^v($NUM\.$NUM\.$NUM)$ ]]; then
        core="${BASH_REMATCH[1]}"
        [ "$core" != "$BASE" ] || TAKEN=1
        if [ -z "$STABLE" ] || [[ "$(pad "$core")" > "$(pad "$STABLE")" ]]; then
            STABLE="$core"
        fi
    elif [[ "$tag" =~ ^v($NUM\.$NUM\.$NUM)-(beta|rc|unsigned)\.([1-9][0-9]{0,5})$ ]]; then
        core="${BASH_REMATCH[1]}"
        kind="${BASH_REMATCH[5]}"
        n="${BASH_REMATCH[6]}"
        PRERELEASED="$PRERELEASED$core "
        [ "$core" = "$BASE" ] || continue
        case "$kind" in
            beta) [ "$n" -le "$MAX_BETA" ] || MAX_BETA="$n" ;;
            rc) [ "$n" -le "$MAX_RC" ] || MAX_RC="$n" ;;
            unsigned) [ "$n" -le "$MAX_UNSIGNED" ] || MAX_UNSIGNED="$n" ;;
        esac
    fi
done <<<"$TAGS"

[ "$TAKEN" -eq 0 ] || die "v$BASE already exists, as a tag or a draft release; pick a newer version"

if [ -n "$STABLE" ]; then
    if ! [[ "$(pad "$BASE")" > "$(pad "$STABLE")" ]]; then
        where="v$STABLE"
        grep -Fxq -- "v$STABLE" <<<"$REMOTE" || where="v$STABLE (still a draft release)"
        die "$BASE is not newer than the latest stable, $where"
    fi
    [[ "$STABLE" =~ ^$NUM\.$NUM\.$NUM$ ]]
    X="${BASH_REMATCH[1]}" Y="${BASH_REMATCH[2]}" Z="${BASH_REMATCH[3]}"
    NEXT="$X.$Y.$((Z + 1)) $X.$((Y + 1)).0 $((X + 1)).0.0"
else
    NEXT="0.0.1 0.1.0 1.0.0"
fi
# Once published, the tap never moves backwards, so a typo'd version would strand it.
if [ "$ALLOW_JUMP" -eq 0 ] && [[ " $NEXT " != *" $BASE "* ]] \
        && [[ "$PRERELEASED" != *" $BASE "* ]]; then
    die "$BASE skips a version: after ${STABLE:-no release} the next is one of $NEXT; set allow_jump if that is intended"
fi

case "$KIND" in
    release) echo "$BASE" ;;
    beta)
        [ "$MAX_RC" -eq 0 ] || die "$BASE-rc.$MAX_RC exists; a beta would sort below it"
        echo "$BASE-beta.$((MAX_BETA + 1))"
        ;;
    rc) echo "$BASE-rc.$((MAX_RC + 1))" ;;
    unsigned) echo "$BASE-unsigned.$((MAX_UNSIGNED + 1))" ;;
esac
