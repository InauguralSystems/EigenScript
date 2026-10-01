#!/usr/bin/env bash
# Deterministic O(1) `len of string` gate (#1192).
#
# This is deliberately a release-lane cachegrind test, not part of the runtime
# suite: EIGS_STR_LEN_CHECK builds re-run strlen(3) to verify the cached length
# and are therefore O(n) by design.  The CI bench lane passes its ordinary
# release binary explicitly and cachegrind supplies an instruction count (Ir),
# so CPU load cannot change the verdict.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
EIGS="${EIGS:-$ROOT/src/eigenscript}"
MAX_RATIO="${MAX_RATIO:-1.25}"
SHORT_LEN=1000
LONG_LEN=8000
CALLS=50000

fail() { echo "string-len-complexity: FAIL: $*" >&2; exit 2; }
[ -x "$EIGS" ] || fail "no runtime at $EIGS (set EIGS to a release build)"
command -v valgrind >/dev/null 2>&1 || fail "valgrind is required"
awk -v r="$MAX_RATIO" 'BEGIN { exit !(r+0 > 1.0 && r+0 < 2.0) }' \
    || fail "MAX_RATIO must be between 1.0 and 2.0, got '$MAX_RATIO'"

mkdir -p "$ROOT/build" || fail "cannot create build directory"
WORK=$(mktemp -d "$ROOT/build/strlen-complexity.XXXXXX") || fail "cannot create scratch directory"
trap 'rm -rf "$WORK"' EXIT

make_probe() { # length, output path
    awk -v n="$1" -v calls="$CALLS" 'BEGIN {
        printf "s is \""; for (i=0; i<n; i++) printf "a"; print "\""
        print "i is 0"
        print "total is 0"
        print "loop while i < " calls ":"
        print "    total is total + (len of s)"
        print "    i is i + 1"
        print "print of total"
    }' > "$2"
}

ir_of() { # program, expected stdout
    local out err rc ir
    out="$WORK/out"; err="$WORK/err"
    EIGS_JIT_OFF=1 valgrind --tool=cachegrind --cachegrind-out-file=/dev/null \
        "$EIGS" "$1" >"$out" 2>"$err"; rc=$?
    [ "$rc" -eq 0 ] || fail "probe $(basename "$1") exited $rc: $(cat "$err")"
    [ "$(cat "$out")" = "$2" ] || fail "probe $(basename "$1") returned '$(cat "$out")', expected '$2'"
    # POSIX awk extraction, rather than GNU-only grep -o.
    ir=$(awk '/I[ ]*refs:/ {
        line=$0; sub(/^.*I[ ]*refs:[ ]*/, "", line); gsub(/,/, "", line)
        if (line ~ /^[0-9]+$/) { n++; value=line }
    } END { if (n == 1) print value }' "$err")
    [ -n "$ir" ] || fail "cachegrind produced no unique Ir reading for $(basename "$1")"
    printf '%s\n' "$ir"
}

make_probe "$SHORT_LEN" "$WORK/short.eigs"
make_probe "$LONG_LEN" "$WORK/long.eigs"
# `ir_of` runs in a command-substitution subshell.  Propagate its status
# explicitly: without these guards, `fail` only exits that subshell and an
# empty reading can be mistaken for a zero ratio by awk.
short_ir=$(ir_of "$WORK/short.eigs" "$((SHORT_LEN * CALLS))") || exit $?
long_ir=$(ir_of "$WORK/long.eigs" "$((LONG_LEN * CALLS))") || exit $?
ratio=$(awk -v a="$long_ir" -v b="$short_ir" 'BEGIN { printf "%.3f", a/b }')

echo "string-len-complexity: short(${SHORT_LEN}) Ir=$short_ir long(${LONG_LEN}) Ir=$long_ir ratio=$ratio max=$MAX_RATIO"
if awk -v r="$ratio" -v m="$MAX_RATIO" 'BEGIN { exit !(r <= m) }'; then
    echo "PASS: len of string has constant instruction cost"
    exit 0
fi
echo "RED: len of string instruction cost grows with string length (ratio $ratio > $MAX_RATIO)"
exit 1
