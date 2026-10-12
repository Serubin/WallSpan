#!/bin/bash
# Submits a zip to Apple's notary service, waits for the verdict, and optionally staples.
#
# usage: Scripts/notarize.sh (--key P8 --key-id ID --issuer UUID | --keychain-profile NAME)
#                            [--staple APP] ZIP
set -euo pipefail

KEY="" KEY_ID="" ISSUER="" PROFILE="" STAPLE=""

die() { echo "notarize.sh: $*" >&2; exit 2; }

while [ $# -gt 0 ]; do
    case "$1" in
        --key) KEY="${2-}"; shift 2 ;;
        --key-id) KEY_ID="${2-}"; shift 2 ;;
        --issuer) ISSUER="${2-}"; shift 2 ;;
        --keychain-profile) PROFILE="${2-}"; shift 2 ;;
        --staple) STAPLE="${2-}"; shift 2 ;;
        -h|--help) sed -n '2,5p' "$0"; exit 0 ;;
        -*) die "unknown option: $1" ;;
        *) break ;;
    esac
done
[ $# -eq 1 ] || die "expected one ZIP, got $#"
ZIP="$1"
[ -f "$ZIP" ] || die "no such file: $ZIP"

if [ -n "$PROFILE" ]; then
    [ -z "$KEY$KEY_ID$ISSUER" ] || die "pass the API key flags or --keychain-profile, not both"
    AUTH=(--keychain-profile "$PROFILE")
else
    [ -n "$KEY" ] && [ -n "$KEY_ID" ] && [ -n "$ISSUER" ] \
        || die "--key, --key-id and --issuer are all required without --keychain-profile"
    [ -f "$KEY" ] || die "no such key file: $KEY"
    AUTH=(--key "$KEY" --key-id "$KEY_ID" --issuer "$ISSUER")
fi
[ -z "$STAPLE" ] || [ -d "$STAPLE" ] || die "not a bundle: $STAPLE"

field() { python3 -c 'import sys,json;print(json.load(sys.stdin).get(sys.argv[1],""))' "$1"; }

# The timeout bounds an Apple outage; without it --wait would hold the job for hours.
RESULT="$(xcrun notarytool submit "$ZIP" "${AUTH[@]}" \
    --wait --timeout 30m --output-format json)" || true
ID="$(field id <<<"$RESULT" 2>/dev/null)" || ID=""
STATUS="$(field status <<<"$RESULT" 2>/dev/null)" || STATUS=""
echo "notarytool: $(basename "$ZIP") -> ${STATUS:-no verdict}${ID:+ (submission $ID)}"

if [ "$STATUS" != Accepted ]; then
    printf '%s\n' "$RESULT" >&2
    if [ -n "$ID" ]; then
        xcrun notarytool log "$ID" "${AUTH[@]}" >&2 || true
    fi
    exit 1
fi

[ -n "$STAPLE" ] || exit 0

# The ticket can take a few minutes to reach the CDN stapler fetches it from.
retry() {
    local delay
    for delay in 0 15 30 60 120; do
        sleep "$delay"
        "$@" && return 0
    done
    return 1
}
retry xcrun stapler staple "$STAPLE"
retry xcrun stapler validate "$STAPLE"
