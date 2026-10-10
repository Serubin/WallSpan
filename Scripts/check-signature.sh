#!/bin/bash
# Asserts how shipped code is signed: always the hardened runtime, then ad-hoc or Developer ID.
#
# usage: Scripts/check-signature.sh [--developer-id TEAMID] [--notarized] PATH...
set -uo pipefail

TEAM=""
NOTARIZED=0

die() { echo "check-signature.sh: $*" >&2; exit 2; }

while [ $# -gt 0 ]; do
    case "$1" in
        --developer-id) [ $# -ge 2 ] || die "--developer-id needs a value"; TEAM="$2"; shift 2 ;;
        --notarized) NOTARIZED=1; shift ;;
        -h|--help) sed -n '2,4p' "$0"; exit 0 ;;
        --) shift; break ;;
        -*) die "unknown option: $1" ;;
        *) break ;;
    esac
done
[ $# -gt 0 ] || die "no PATH given"
if [ -n "$TEAM" ] && ! [[ "$TEAM" =~ ^[A-Z0-9]{10}$ ]]; then
    die "not a team ID: $TEAM"
fi
[ "$NOTARIZED" -eq 0 ] || [ -n "$TEAM" ] || die "--notarized needs --developer-id"

# Apple's Developer ID requirement, narrowed to one team.
DEVID_REQ="anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists \
and certificate leaf[field.1.2.840.113635.100.6.1.13] exists \
and certificate leaf[subject.OU] = \"$TEAM\""

fails=0
ok()      { echo "  ok        $1"; }
fail()    { echo "  FAIL      $1"; fails=$((fails + 1)); }
indent()  { sed 's/^/            /'; }

# A ticket can lag an Accepted answer by minutes, so the online checks back off before failing.
retry() {
    local delay out
    for delay in 0 15 30 60 120; do
        sleep "$delay"
        out="$("$@" 2>&1)" && return 0
    done
    printf '%s\n' "$out" | indent
    return 1
}

skipped() {
    echo "  SKIPPED   $1"
    if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
        echo "> **SKIPPED:** $1" >> "$GITHUB_STEP_SUMMARY"
    fi
    if [ -n "${GITHUB_ACTIONS:-}" ]; then echo "::warning::SKIPPED: $1"; fi
}

check() {
    local path="$1" out info exe archs arch flags missing="" authority
    if ! out="$(codesign --verify --deep --strict --verbose=2 "$path" 2>&1)"; then
        fail "$path: signature does not verify"
        printf '%s\n' "$out" | indent
        return
    fi
    ok "$path: verifies (strict)"

    info="$(codesign -dvvv "$path" 2>&1)"
    # Per slice: a universal binary is signed once per architecture, and -d shows only one.
    exe="$(sed -n 's/^Executable=//p' <<<"$info")"
    archs="$(lipo -archs "$exe" 2>/dev/null)" || archs=""
    for arch in ${archs:-native}; do
        if [ "$arch" = native ]; then
            flags="$(codesign -dv "$path" 2>&1)"
        else
            flags="$(codesign -dv --arch "$arch" "$path" 2>&1)"
        fi
        flags="$(sed -n 's/^CodeDirectory .*flags=0x[0-9a-f]*(\([^)]*\)).*/\1/p' <<<"$flags")"
        case ",$flags," in *,runtime,*) ;; *) missing="$missing $arch" ;; esac
    done
    if [ -z "$missing" ]; then
        ok "$path: hardened runtime (${archs:-native})"
    else
        fail "$path: hardened runtime off for$missing"
    fi

    if [ -z "$TEAM" ]; then
        if grep -qx 'Signature=adhoc' <<<"$info"; then
            ok "$path: ad-hoc"
        else
            fail "$path: expected an ad-hoc signature"
        fi
        return
    fi

    authority="$(sed -n 's/^Authority=//p' <<<"$info" | head -1)"
    case "$authority" in
        "Developer ID Application: "*"($TEAM)") ok "$path: $authority" ;;
        *) fail "$path: signed by '${authority:-nobody}', not a Developer ID Application of $TEAM" ;;
    esac
    if grep -qx "TeamIdentifier=$TEAM" <<<"$info"; then
        ok "$path: team $TEAM"
    else
        fail "$path: TeamIdentifier is not $TEAM"
    fi
    # `Signed Time` instead means no secure timestamp, which notarisation rejects.
    if grep -q '^Timestamp=' <<<"$info"; then
        ok "$path: secure timestamp"
    else
        fail "$path: no secure timestamp"
    fi
    if out="$(codesign --verify --strict -R="$DEVID_REQ" "$path" 2>&1)"; then
        ok "$path: meets the Developer ID requirement for $TEAM"
    else
        fail "$path: does not meet the Developer ID requirement for $TEAM"
        printf '%s\n' "$out" | indent
    fi

    [ "$NOTARIZED" -eq 1 ] || return
    if retry codesign --verify --strict --check-notarization -R=notarized "$path"; then
        ok "$path: notarised"
    else
        fail "$path: Apple has no notarisation ticket for it"
    fi
    case "$path" in *.app|*.app/) ;; *) return ;; esac
    if retry xcrun stapler validate "$path"; then
        ok "$path: stapled ticket valid"
    else
        fail "$path: no valid stapled ticket"
    fi
    # Runners may have assessments off; stapler and --check-notarization are the hard gates.
    if spctl --status 2>/dev/null | grep -q 'assessments enabled'; then
        if out="$(spctl -a -t exec -vvv "$path" 2>&1)" \
            && grep -q '^source=Notarized Developer ID$' <<<"$out"; then
            ok "$path: Gatekeeper accepts it (Notarized Developer ID)"
        else
            fail "$path: Gatekeeper does not accept it as Notarized Developer ID"
            printf '%s\n' "$out" | indent
        fi
    else
        skipped "$path: Gatekeeper assessment, because assessments are disabled on this host"
    fi
}

for path in "$@"; do
    check "$path"
done

if [ "$fails" -gt 0 ]; then
    echo "$fails signature check(s) failed" >&2
    exit 1
fi
echo "signatures ok"
