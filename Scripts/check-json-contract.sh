#!/bin/bash
# Every --json command must emit one parseable envelope; every other must refuse the flag.
# An `error` envelope passes — a runner has no display, so shape is what is asserted.
#
# usage: Scripts/check-json-contract.sh [path-to-wallspan]
set -uo pipefail

BIN="${1:-.build/debug/wallspan}"
[ -x "$BIN" ] || { echo "not executable: $BIN" >&2; exit 1; }
BIN="$(cd "$(dirname "$BIN")" && pwd)/$(basename "$BIN")"

SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH"' EXIT
export CFFIXED_USER_HOME="$SCRATCH" HOME="$SCRATCH"

fails=0

# One envelope, carrying `schema` and either the expected key or `error`.
expect_envelope() {
    local key="$1"; shift
    local out rc
    out="$("$BIN" "$@" --json 2>/dev/null)"; rc=$?
    if printf '%s' "$out" | python3 -c '
import sys, json
d = json.load(sys.stdin)
assert isinstance(d, dict), "not an object"
assert d.get("schema", 0) >= 1, "missing or bad schema"
key = sys.argv[1]
assert key in d or "error" in d, f"neither {key!r} nor error present: {sorted(d)}"
if "error" in d:
    assert set(d["error"]) >= {"code", "message"}, "malformed error"
' "$key" 2>/dev/null; then
        local kind
        kind=$(printf '%s' "$out" | python3 -c 'import sys,json;d=json.load(sys.stdin);print("error:"+d["error"]["code"] if "error" in d else "ok")')
        echo "  ok        $* --json  -> $kind"
    else
        echo "  FAIL      $* --json  (exit $rc)"
        printf '%s\n' "$out" | head -5 | sed 's/^/            /'
        fails=$((fails + 1))
    fi
}

# A payload's keys, checked by name. Removing one is a breaking change the schema integer
# is supposed to announce, so it has to fail here rather than in someone's front-end.
expect_fields() {
    local key="$1"; shift
    local cmd="$1"; shift
    local out
    out="$("$BIN" $cmd --json 2>/dev/null)"
    if printf '%s' "$out" | python3 -c '
import sys, json
d = json.load(sys.stdin)[sys.argv[1]]
missing = [f for f in sys.argv[2:] if f not in d]
assert not missing, f"missing {missing}"
' "$key" "$@" 2>/dev/null; then
        echo "  ok        $cmd --json  -> has $*"
    else
        echo "  FAIL      $cmd --json  should carry: $*"
        fails=$((fails + 1))
    fi
}

# Refused, but still as an envelope.
expect_refused() {
    local out rc
    out="$("$BIN" "$@" --json 2>/dev/null)"; rc=$?
    if [ "$rc" -ne 0 ] && printf '%s' "$out" \
        | python3 -c 'import sys,json;assert json.load(sys.stdin)["error"]["code"]' 2>/dev/null; then
        echo "  ok        $* --json  -> refused"
    else
        echo "  FAIL      $* --json  should have been refused (exit $rc)"
        fails=$((fails + 1))
    fi
}

echo "read-only:"
expect_envelope version   version
# `version` is the probe every front-end runs first, and the only payload guaranteed to
# come back fully populated on a machine with no display — so it is the one whose fields
# are worth naming outright.
expect_fields version "version" version channel commit schema commands
expect_envelope layout    info
expect_envelope layout    layout show
expect_envelope sets      layout list
expect_envelope config    config show
expect_envelope agent     agent status
expect_envelope status    status
expect_envelope arrange   layout arrange --dry-run
expect_envelope applied   apply /nonexistent.jpg
# Nothing is cycling here, so this exercises the agent_not_running path.
expect_envelope next      next
# Error paths too: a caller cannot branch on a code it cannot parse.
expect_envelope layout    layout nudge nosuchdisplay --dx 1px
expect_envelope layout    layout nudge 0 --dx 20in

# `calibrate` is absent on purpose: the redirect does not cover the desktop, so it would
# put a test pattern on the real screens.

echo "refused:"
expect_refused cycle
expect_refused selftest
expect_refused preview
expect_refused verify-mapping
expect_refused bogus-subcommand

# Only once the redirect is proven, never assumed.
reported="$("$BIN" config show --json 2>/dev/null \
    | python3 -c 'import sys,json;print(json.load(sys.stdin).get("config",{}).get("configPath",""))' 2>/dev/null)"

case "$reported" in
    "$SCRATCH"/*)
        echo "mutating (isolated in $SCRATCH):"
        expect_envelope layout    layout reset
        # Every mutating layout verb, because each prints its own prose before emitting and
        # a stray line ahead of the object makes the whole reply unparseable.
        # Every mutating verb: two of these once leaked prose ahead of the object.
        expect_envelope layout    layout nudge 0 --dx 1px
        expect_envelope layout    layout nudge 0 --dy -1px
        expect_envelope layout    layout set 0 --origin-x 0mm
        expect_envelope layout    layout size 0 --scale 100.1
        expect_envelope layout    layout size 0 --ppi 109.5
        expect_envelope layout    layout size 0 --width 800mm
        # Zero deltas on a fresh seed, so this reports rather than moves.
        expect_envelope arrange   layout arrange
        expect_envelope arrange   layout arrange --revert
        expect_envelope config    config set --interval 30m
        expect_envelope config    pause
        expect_envelope config    resume
        expect_envelope restored  restore
        ;;
    *)
        echo "mutating: SKIPPED — no redirect (reported '${reported:-unknown}'); these" >&2
        echo "          would rewrite the real config and wallpaper." >&2
        ;;
esac

if [ "$fails" -gt 0 ]; then
    echo "$fails contract check(s) failed" >&2
    exit 1
fi
echo "json contract ok"
