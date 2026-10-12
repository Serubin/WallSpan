#!/bin/bash
# Checks resolve-version.sh's rules offline, against fake tag lists.
#
# usage: Scripts/test-resolve-version.sh
set -uo pipefail

SCRIPT="$(cd "$(dirname "$0")" && pwd)/resolve-version.sh"
SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH"' EXIT
fails=0

# expect TAGS WANT ARGS...: WANT is the version printed, or `refuse`.
expect() {
    local tags="$1" want="$2"; shift 2
    printf '%b' "$tags" > "$SCRATCH/tags"
    local got
    if got="$("$SCRIPT" --tags-file "$SCRATCH/tags" "$@" 2>/dev/null)"; then :; else got=refuse; fi
    if [ "$got" = "$want" ]; then
        echo "  ok    $* -> $got"
    else
        echo "  FAIL  $* -> $got, expected $want"
        fails=$((fails + 1))
    fi
}

STABLE='v0.1.0\n'
# The draft's tag exists only as a release, which the real script reads alongside git's.
BETAS='v0.1.0\nv0.2.0-beta.1\nv0.2.0-beta.2\nv0.2.0-unsigned.7\nv0.3.0-beta.9\n'
RC='v0.1.0\nv0.2.0-beta.4\nv0.2.0-rc.1\n'
# Tags that are not a version this script may count, beside one that is.
NOISE='v0.1.0\nbackup/v9.0.0\nsquashed/x\nv1.0\nv01.2.3\nv1234567.0.0\nv0.9.0-alpha.1\n'

# Release: the next patch, minor or major, and nothing that is not newer.
expect "$STABLE" 0.1.1  --kind release --base 0.1.1
expect "$STABLE" 0.2.0  --kind release --base 0.2.0
expect "$STABLE" 1.0.0  --kind release --base 1.0.0
expect "$STABLE" refuse --kind release --base 0.1.0
expect "$STABLE" refuse --kind release --base 0.0.9
expect 'v1.0.0\nv0.9.0\n' refuse --kind release --base 0.9.1
expect "$BETAS"  0.2.0  --kind release --base 0.2.0

# A jump needs --allow-jump, unless that version already has prereleases.
expect "$STABLE" refuse --kind release --base 0.3.0
expect "$STABLE" refuse --kind beta    --base 2.0.0
expect "$STABLE" 2.0.0-beta.1 --kind beta --base 2.0.0 --allow-jump
expect "$BETAS"  0.3.0-beta.10 --kind beta --base 0.3.0
expect "$BETAS"  0.3.0  --kind release --base 0.3.0

# Nothing released yet.
expect ''        1.0.0-beta.1 --kind beta --base 1.0.0
expect ''        refuse        --kind beta --base 1.1.0

# Numbering, with drafts counted and an rc closing the betas.
expect "$STABLE" refuse        --kind beta --base 0.1.0
expect "$STABLE" 0.2.0-beta.1  --kind beta --base 0.2.0
expect "$STABLE" 0.2.0-rc.1    --kind rc   --base 0.2.0
expect "$BETAS"  0.2.0-beta.3  --kind beta --base 0.2.0
expect "$BETAS"  0.2.0-rc.1    --kind rc   --base 0.2.0
expect "$RC"     refuse        --kind beta --base 0.2.0
expect "$RC"     0.2.0-rc.2    --kind rc   --base 0.2.0
expect 'v0.1.0\nv0.2.0-beta.9\nv0.2.0-beta.10\n' 0.2.0-beta.11 --kind beta --base 0.2.0

# Unsigned keeps its own count, and an rc does not close it.
expect "$BETAS"  0.2.0-unsigned.8 --kind unsigned --base 0.2.0
expect "$RC"     0.2.0-unsigned.1 --kind unsigned --base 0.2.0
expect "$STABLE" refuse           --kind unsigned --base 0.1.0

# A newer stable blocks going backwards, whether it is a tag or still a draft.
expect 'v0.1.0\nv0.2.0\n' refuse --kind release --base 0.2.0
expect 'v0.1.0\nv0.2.0\n' refuse --kind beta    --base 0.1.1

# Malformed tags neither count as the latest stable nor make a jump look normal.
expect "$NOISE"  0.1.1         --kind release --base 0.1.1
expect "$NOISE"  refuse        --kind release --base 0.9.0

for bad in 0.2 0.2.0-beta.1 v0.2.0 01.2.3 1.02.0 1234567.0.0 "0.2.0 x" '0.2.0"$(id)' ''; do
    expect "$STABLE" refuse --kind beta --base "$bad"
done
expect "$STABLE" refuse --kind alpha --base 0.2.0
expect "$STABLE" refuse --base 0.2.0

if [ "$fails" -gt 0 ]; then
    echo "$fails resolve-version check(s) failed" >&2
    exit 1
fi
echo "resolve-version ok"
