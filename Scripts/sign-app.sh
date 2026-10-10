#!/bin/bash
# Signs Wallspan.app inside out, with the hardened runtime: the bundled CLI, then the bundle.
#
# usage: Scripts/sign-app.sh [--identity ID|-] [--keychain KEYCHAIN] APP
set -euo pipefail

IDENTITY=-
KEYCHAIN=""

die() { echo "sign-app.sh: $*" >&2; exit 2; }

while [ $# -gt 0 ]; do
    case "$1" in
        --identity) IDENTITY="${2-}"; shift 2 ;;
        --keychain) KEYCHAIN="${2-}"; shift 2 ;;
        -h|--help) sed -n '2,4p' "$0"; exit 0 ;;
        -*) die "unknown option: $1" ;;
        *) break ;;
    esac
done
[ $# -eq 1 ] || die "expected one APP, got $#"
APP="$1"
[ -n "$IDENTITY" ] || die "--identity is empty"
[ -d "$APP/Contents" ] || die "not a bundle: $APP"
HELPER="$APP/Contents/Helpers/wallspan"
[ -f "$HELPER" ] || die "no bundled CLI at $HELPER"

# --force replaces the linker's signature, and with it any get-task-allow the build left.
ARGS=(--force --sign "$IDENTITY" --options runtime)
if [ "$IDENTITY" = - ]; then
    ARGS+=(--timestamp=none)
else
    ARGS+=(--timestamp)
fi
[ -z "$KEYCHAIN" ] || ARGS+=(--keychain "$KEYCHAIN")

sign() {
    codesign "${ARGS[@]}" "$@" && return 0
    # Only a Developer ID signature reaches the network, for Apple's timestamp server.
    [ "$IDENTITY" != - ] || return 1
    echo "sign-app.sh: codesign failed, retrying once" >&2
    sleep 10
    codesign "${ARGS[@]}" "$@"
}

# The LaunchAgent label, so the CLI keeps one identity whether bundled or installed alone.
sign --identifier net.serubin.wallspan "$HELPER"
sign "$APP"
