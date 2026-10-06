#!/usr/bin/env bash
# tape_kinds_check.sh -- #1637: every taped builtin declares its return kinds.
#
# Replay refuses a recorded N value whose kind its builtin cannot return
# (src/trace.c, k_tape_kinds) -- and refuses a name that is in no table. A
# builtin that starts recording without a row would therefore fail only at
# replay, on a user's tape. This gate fails first, at build review:
#   taped    = every name src/*.c records or takes: TRACE_NONDET_TAKE/RET/
#              RECORD("x"), ARG_GUARD_TAPED/PRETAKE(..., "x", ...),
#              trace_replay_take("x"), trace_nondet_value("x")
#   declared = every {"x", ...} row of k_tape_kinds
# and requires taped == declared, both non-empty. The smoke/embedding test
# programs (embed_*.c, jit_smoke.c) record host names and declare them
# through eigs_trace_declare_kind, so they are not part of the core set.
# Prints `tape-kinds: taped=N declared=K missing=0 stale=0` and PASS/FAIL.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC_DIR="${TAPE_KINDS_SRC:-$ROOT/src}"
TMP=$(mktemp "${TMPDIR:-/tmp}/tape_kinds.XXXXXX") || exit 2
trap 'rm -f "$TMP" "$TMP.d"' EXIT

for f in "$SRC_DIR"/*.c; do
    case "$(basename "$f")" in embed_*.c|jit_smoke.c) continue ;; esac
    awk '
    # A macro invocation may span lines; join it up to its closing ");".
    function emit(s,    m) {
        while (match(s, /(TRACE_NONDET_(TAKE|RET|RECORD)|trace_replay_take|trace_nondet_value)[(]"[a-z_0-9]+"/)) {
            m = substr(s, RSTART, RLENGTH); sub(/^[^"]*"/, "", m); sub(/"$/, "", m)
            print m
            s = substr(s, RSTART + RLENGTH)
        }
    }
    /ARG_GUARD_(TAPED|PRETAKE)[(]/ && !/#define/ { acc = $0; inm = 1 }
    inm && acc != $0 { acc = acc " " $0 }
    inm && /[)];/ {
        # the first string literal in the invocation is `who`
        if (match(acc, /"[a-z_0-9]+"/)) print substr(acc, RSTART + 1, RLENGTH - 2)
        inm = 0
    }
    { emit($0) }
    ' "$f"
done | sort -u > "$TMP"

awk '/k_tape_kinds\[\] = [{]/ { on = 1; next }
     on && /^[}];/ { on = 0 }
     on && match($0, /[{]"[a-z_0-9]+"/) { print substr($0, RSTART + 2, RLENGTH - 3) }' \
    "$SRC_DIR/trace.c" | sort -u > "$TMP.d"

taped=$(grep -c . "$TMP")
declared=$(grep -c . "$TMP.d")
missing=0; stale=0
while IFS= read -r n; do
    grep -qx -- "$n" "$TMP.d" || { echo "  MISSING: '$n' records an N value but has no k_tape_kinds row"; missing=$((missing + 1)); }
done < "$TMP"
while IFS= read -r n; do
    grep -qx -- "$n" "$TMP" || { echo "  STALE: k_tape_kinds row '$n' names nothing taped"; stale=$((stale + 1)); }
done < "$TMP.d"
echo "tape-kinds: taped=$taped declared=$declared missing=$missing stale=$stale"
if [ "$taped" -gt 0 ] && [ "$declared" -gt 0 ] && [ "$missing" -eq 0 ] && [ "$stale" -eq 0 ]; then
    echo "tape-kinds: PASS"; exit 0
fi
echo "tape-kinds: FAIL"; exit 1
