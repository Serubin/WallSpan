#!/bin/bash
# Renders release notes from conventional commits, grouped by type.
#
# The history is already disciplined — `feat(app): Add the calibration window (#20)` — so
# the commit subjects are the changelog, and this only has to sort them. Nothing depends on
# PR labels, and it runs locally, so a release body can be reviewed before the release
# workflow is ever started.
#
# usage: Scripts/changelog.sh [FROM [TO]] [--from REF] [--to REF] [--repo OWNER/NAME]
#
# FROM defaults to the nearest preceding v* tag, or the root commit for a first release.
# TO defaults to HEAD.
set -euo pipefail

cd "$(dirname "$0")/.."

FROM=""
TO=""
REPO=""

while [ $# -gt 0 ]; do
    case "$1" in
        --repo) REPO="$2"; shift 2 ;;
        --from) FROM="$2"; shift 2 ;;
        --to)   TO="$2"; shift 2 ;;
        -h|--help) sed -n '2,11p' "$0"; exit 0 ;;
        -*) echo "changelog.sh: unknown option: $1" >&2; exit 2 ;;
        *)
            if   [ -z "$FROM" ]; then FROM="$1"
            elif [ -z "$TO" ];   then TO="$1"
            else echo "changelog.sh: too many arguments" >&2; exit 2
            fi
            shift ;;
    esac
done

TO="${TO:-HEAD}"
# --match, because backup/*, spr-backup/* and squashed/* tags are not releases; describing
# against one would silently truncate the notes to a handful of commits.
[ -n "$FROM" ] || FROM="$(git describe --tags --abbrev=0 --match 'v[0-9]*' "$TO^" 2>/dev/null || true)"

if [ -n "$FROM" ]; then RANGE="$FROM..$TO"; else RANGE="$TO"; fi

BREAKING="" FEAT="" FIX="" PERF="" REFACTOR="" DOCS="" MAINT="" OTHER=""

while IFS= read -r -d '' entry; do
    # git terminates each formatted commit with a newline *after* the NUL, so every entry
    # but the first arrives with it still attached and would parse as an empty subject.
    while [ "${entry:0:1}" = $'\n' ]; do entry="${entry:1}"; done
    [ -n "$entry" ] || continue

    subject="${entry%%$'\n'*}"
    body="${entry#*$'\n'}"

    if [[ "$subject" =~ ^([a-zA-Z]+)(\(([^\)]+)\))?(!)?:[[:space:]]+(.+)$ ]]; then
        type="${BASH_REMATCH[1]}"
        scope="${BASH_REMATCH[3]}"
        bang="${BASH_REMATCH[4]}"
        text="${BASH_REMATCH[5]}"
    else
        type="" scope="" bang="" text="$subject"
    fi

    if [ -n "$scope" ]; then line="- **$scope**: $text"; else line="- $text"; fi

    # Either spelling of a break wins over the type, so a breaking fix is not filed under
    # Fixes where an upgrader would never look for it.
    case "$body" in *"BREAKING CHANGE:"*|*"BREAKING-CHANGE:"*) bang="!" ;; esac

    if [ -n "$bang" ]; then
        BREAKING="$BREAKING$line"$'\n'
        continue
    fi

    case "$type" in
        feat)                       FEAT="$FEAT$line"$'\n' ;;
        fix)                        FIX="$FIX$line"$'\n' ;;
        perf)                       PERF="$PERF$line"$'\n' ;;
        refactor)                   REFACTOR="$REFACTOR$line"$'\n' ;;
        docs)                       DOCS="$DOCS$line"$'\n' ;;
        build|ci|chore|test|style)  MAINT="$MAINT$line"$'\n' ;;
        *)                          OTHER="$OTHER$line"$'\n' ;;
    esac
done < <(git log --no-merges --format='%s%n%b%x00' "$RANGE")

section() {
    [ -n "$2" ] || return 0
    printf '## %s\n\n%s\n' "$1" "$2"
}

section "Breaking changes" "$BREAKING"
section "Features"         "$FEAT"
section "Fixes"            "$FIX"
section "Performance"      "$PERF"
section "Internals"        "$REFACTOR"
section "Documentation"    "$DOCS"
section "Maintenance"      "$MAINT"
section "Other"            "$OTHER"

if [ -z "$BREAKING$FEAT$FIX$PERF$REFACTOR$DOCS$MAINT$OTHER" ]; then
    printf 'No changes in %s.\n' "$RANGE"
fi

if [ -n "$FROM" ] && [ -n "$REPO" ]; then
    printf '**Full changelog**: https://github.com/%s/compare/%s...%s\n' "$REPO" "$FROM" "$TO"
fi
