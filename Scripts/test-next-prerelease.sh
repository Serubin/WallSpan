#!/bin/bash
# Checks next-prerelease.sh's numbering rules offline, against fake tag lists.
#
# usage: Scripts/test-next-prerelease.sh
set -uo pipefail

SCRIPT="$(cd "$(dirname "$0")" && pwd)/next-prerelease.sh"
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

expect "$STABLE" refuse        --kind beta --base 0.1.0
expect "$STABLE" 0.2.0-beta.1  --kind beta --base 0.2.0
expect "$STABLE" 0.2.0-rc.1    --kind rc   --base 0.2.0
expect "$BETAS"  0.2.0-beta.3  --kind beta --base 0.2.0
expect "$BETAS"  0.2.0-rc.1    --kind rc   --base 0.2.0
expect "$RC"     refuse        --kind beta --base 0.2.0
expect "$RC"     0.2.0-rc.2    --kind rc   --base 0.2.0

expect "$BETAS"  0.2.0-beta.3  --check 0.2.0-beta.3
expect "$BETAS"  0.2.0-beta.10 --check 0.2.0-beta.10
expect "$BETAS"  refuse        --check 0.2.0-beta.2
expect "$RC"     refuse        --check 0.2.0-beta.5
expect "$RC"     0.2.0-rc.2    --check 0.2.0-rc.2
expect "$STABLE" refuse        --check 0.1.0-beta.1

for bad in 0.2.0 0.2.0-beta.0 0.2.0-beta.01 0.2.0-unsigned.1 "0.2.0-beta.1 x"; do
    expect "$STABLE" refuse --check "$bad"
done
expect "$STABLE" refuse --kind alpha --base 0.2.0
expect "$STABLE" refuse --kind beta --base '0.2.0"$(id)'

if [ "$fails" -gt 0 ]; then
    echo "$fails next-prerelease check(s) failed" >&2
    exit 1
fi
echo "next-prerelease ok"
