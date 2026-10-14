#!/bin/bash
# #1746 Phase 1 EXPERIMENT gate: the IEEE-754 build's named rows.
#
#   bash tools/ieee_rows.sh [ieee-binary]      (default build/ieee/eigenscript)
#
# Every row runs under `timeout` (rc 124/137 is a named FAIL) and prints
#   PASS <row> | FAIL <row>: <why>
# then one verdict line `IEEE_ROWS: <pass> passed, <fail> failed of <declared>`.
# The declared row count is pinned: a row that never ran is a FAIL, not a skip.
# Sanitizer text on stderr (ASan/UBSan/LSan) fails the row at any exit code.
# Linux-only (uses coreutils timeout), like tools/jit_diff.sh.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="${1:-$ROOT/build/ieee/eigenscript}"
T="$ROOT/tests/ieee"
TMO="${IEEE_ROWS_TIMEOUT:-120}"
DECLARED=10
W="$(mktemp -d "${TMPDIR:-/tmp}/ieee_rows.XXXXXX")" || { echo "FAIL setup: mktemp"; exit 2; }
trap 'rm -rf "$W"' EXIT
PASS=0; FAIL=0; RAN=""
pass() { PASS=$((PASS+1)); RAN="$RAN $1"; echo "PASS $1"; }
fail() { FAIL=$((FAIL+1)); RAN="$RAN $1"; echo "FAIL $1: $2"; }
[ -x "$BIN" ] || { echo "FAIL setup: no binary at $BIN"; echo "IEEE_ROWS: 0 passed, 1 failed of $DECLARED"; exit 1; }

# run <tag> <cmd...>: stdout -> $W/<tag>.out, stderr -> $W/<tag>.err, rc -> $W/<tag>.rc
run() {
    local tag="$1"; shift
    timeout "$TMO" "$@" > "$W/$tag.out" 2> "$W/$tag.err"
    echo $? > "$W/$tag.rc"
}
# clean <tag>: rc 0, no timeout, no sanitizer text. Prints the reason on failure.
clean() {
    local rc; rc=$(cat "$W/$1.rc")
    case "$rc" in 124|137) echo "timeout (rc $rc)"; return 1 ;; 0) ;; *) echo "rc $rc: $(tail -3 "$W/$1.err" | tr '\n' ' ')"; return 1 ;; esac
    if grep -qE 'AddressSanitizer|LeakSanitizer|runtime error:|SUMMARY: ' "$W/$1.err"; then
        echo "sanitizer: $(grep -m1 -E 'ERROR|runtime error|SUMMARY' "$W/$1.err")"; return 1
    fi
    return 0
}
# checks <tag>: a `CHECKS n` header and exactly n `CHECK <name> ok` lines (n > 0).
checks() {
    local n got bad
    n=$(awk '$1=="CHECKS"{print $2; exit}' "$W/$1.out")
    got=$(grep -c '^CHECK ' "$W/$1.out")
    bad=$(grep '^CHECK ' "$W/$1.out" | awk '$3!="ok"' | head -3 | tr '\n' ';')
    if [ -z "$n" ] || [ "$n" -le 0 ] || [ "$got" != "$n" ]; then echo "declared ${n:-none} checks, ran $got"; return 1; fi
    if [ -n "$bad" ]; then echo "$bad"; return 1; fi
    return 0
}

# 1-2. NaN payloads through every slot-write site (interpreter tier).
run payload "$BIN" "$T/nan_payload.eigs"
if why=$(clean payload); then
    p=$(awk '$1=="PATTERNS"{print $2; exit}' "$W/payload.out")
    s=$(awk '$1=="PATTERNS"{print $4; exit}' "$W/payload.out")
    rows=$(grep -c '^ROW ' "$W/payload.out")
    badr=$(grep '^ROW ' "$W/payload.out" | awk '!($4=="num" && $5=="nan" && NF==5)' | head -3 | tr '\n' ';')
    if [ -z "$p" ] || [ -z "$s" ] || [ "$p" -le 0 ] || [ "$rows" != "$((p * s))" ]; then
        fail payload_rows "declared ${p:-?}x${s:-?}, ran $rows rows"
    else pass payload_rows; fi
    if [ -n "$badr" ]; then fail payload_canonical "$badr"; else pass payload_canonical; fi
else fail payload_rows "$why"; fail payload_canonical "did not run"; fi

# 3-4. The same class hot: JIT entry + OSR forced, then the interpreter control.
hot_ok() {   # <tag>: 6 HOT counters all 0 and the text row
    local n bad
    n=$(grep -c '^HOT [a-z]* [0-9]*$' "$W/$1.out")
    bad=$(grep '^HOT [a-z]* [0-9]*$' "$W/$1.out" | awk '$3!="0"' | tr '\n' ';')
    [ "$n" = 6 ] || { echo "declared 6 HOT counters, ran $n"; return 1; }
    [ -z "$bad" ] || { echo "$bad"; return 1; }
    grep -qx 'HOT text nan nan inf' "$W/$1.out" || { echo "text row: $(grep '^HOT text' "$W/$1.out")"; return 1; }
}
run jit env EIGS_JIT_STATS=1 EIGS_JIT_ENTRY_THRESHOLD=1 EIGS_JIT_OSR_THRESHOLD=1 "$BIN" "$T/nan_jit.eigs"
if why=$(clean jit) && why=$(hot_ok jit); then
    c=$(sed -n 's/.*\[jit\] scanned=[0-9]* compiled=\([0-9]*\).*/\1/p' "$W/jit.err" | head -1)
    if [ -n "$c" ] && [ "$c" -gt 0 ]; then pass payload_jit; else fail payload_jit "JIT compiled ${c:-no} chunks (not a JIT witness)"; fi
else fail payload_jit "$why"; fi
run jitoff env EIGS_JIT_OFF=1 "$BIN" "$T/nan_jit.eigs"
if why=$(clean jitoff) && why=$(hot_ok jitoff); then pass payload_jit_off_control; else fail payload_jit_off_control "$why"; fi

# 5. Semantics + print/str/f-string/REPL agreement.
run sem "$BIN" "$T/semantics.eigs"
if why=$(clean sem) && why=$(checks sem); then
    want=$'PRINTS 4\ninf\n-inf\nnan\n[inf, -inf, nan]'
    got=$(sed -n '/^PRINTS 4$/,$p' "$W/sem.out")
    printf 'p is 1e308 * 10\np\n-p\n0 / 0\n' > "$W/repl.in"
    timeout "$TMO" "$BIN" < "$W/repl.in" > "$W/repl.out" 2>&1
    rv=$(grep -o '=> [-a-z]*' "$W/repl.out" | tr '\n' ' ')
    if [ "$got" != "$want" ]; then fail semantics "print block: $(echo "$got" | tr '\n' '|')"
    elif [ "$rv" != "=> inf => inf => -inf => nan " ]; then fail semantics "REPL echo: '$rv'"
    else pass semantics; fi
else fail semantics "$why"; fi

# 6. Observer graded against mathematics (constant 1e308 converged, inf diverging, NaN rule).
run obs "$BIN" "$T/observer.eigs"
if why=$(clean obs) && why=$(checks obs); then pass observer; else fail observer "$why"; fi

# 7-9. Tape: same-seed record twice -> identical bytes; replay -> identical
# stdout+stderr and a re-record identical again; NaN spelled canonically.
run rec1 env EIGS_TRACE="$W/t1.tape" "$BIN" "$T/tape.eigs"
run rec2 env EIGS_TRACE="$W/t2.tape" "$BIN" "$T/tape.eigs"
run rep  env EIGS_REPLAY="$W/t1.tape" EIGS_REPLAY_STRICT=1 "$BIN" "$T/tape.eigs"
if ! why=$(clean rec1) || ! why=$(clean rec2); then fail tape_record_twice "$why"
elif ! [ -s "$W/t1.tape" ] || ! cmp -s "$W/t1.tape" "$W/t2.tape"; then fail tape_record_twice "tapes differ: $(diff "$W/t1.tape" "$W/t2.tape" | head -3 | tr '\n' ' ')"
else pass tape_record_twice; fi
if ! why=$(clean rep); then fail tape_replay "$why"
elif ! cmp -s "$W/rec1.out" "$W/rep.out" || ! cmp -s "$W/rec1.err" "$W/rep.err"; then fail tape_replay "replay transcript differs: $(diff "$W/rec1.out" "$W/rep.out" | head -3 | tr '\n' ' ')"
elif ! grep -q 'inf, -inf, nan' "$W/rec1.out"; then fail tape_replay "program did not produce inf/-inf/nan: $(head -1 "$W/rec1.out")"
else pass tape_replay; fi
# The tape's numeric tokens: z and w are NaN, pinf/ninf infinite; any other NaN spelling is a FAIL.
if grep -qx 'A 0 z=nan' "$W/t1.tape" && grep -qx 'A 0 w=nan' "$W/t1.tape" \
   && grep -qx 'A 0 pinf=inf' "$W/t1.tape" && grep -qx 'A 0 ninf=-inf' "$W/t1.tape" \
   && ! grep -qiE '(^|[=, []|b\[)-nan|nan\(' "$W/t1.tape"; then pass tape_canonical_nan
else fail tape_canonical_nan "tape NaN/inf tokens: $(grep -E '^A 0 (z|w|pinf|ninf)=' "$W/t1.tape" | tr '\n' ' ')"; fi

# 10. Replay injection: a tape whose N record says nan/-nan/inf/-inf (hostile
# or hand-edited) must reach the program as a num, canonical NaN bytes.
run inj0 env EIGS_TRACE="$W/i.tape" "$BIN" "$T/tape_inject.eigs"
injbad=""
if ! grep -q '^N 0 random=' "$W/i.tape"; then injbad="no random N record on the probe tape"; fi
for v in nan -nan inf -inf; do
    [ -n "$injbad" ] && break
    sed "s/^\(N 0 random=\).*/\1$v/" "$W/i.tape" > "$W/i_$v.tape"
    run "inj_$v" env EIGS_REPLAY="$W/i_$v.tape" "$BIN" "$T/tape_inject.eigs"
    case "$v" in nan|-nan) want='["num", nan, [127, 248, 0, 0, 0, 0, 0, 0]]' ;;
                 inf) want='["num", inf, [127, 240, 0, 0, 0, 0, 0, 0]]' ;;
                 -inf) want='["num", -inf, [255, 240, 0, 0, 0, 0, 0, 0]]' ;; esac
    if ! why=$(clean "inj_$v"); then injbad="$v: $why"
    elif [ "$(cat "$W/inj_$v.out")" != "$want" ]; then injbad="$v: got $(cat "$W/inj_$v.out")"; fi
done
if [ -z "$injbad" ]; then pass tape_inject; else fail tape_inject "$injbad"; fi

ran=$(echo $RAN | wc -w)
[ "$ran" = "$DECLARED" ] || { echo "FAIL rows: declared $DECLARED, ran $ran ($RAN)"; FAIL=$((FAIL+1)); }
echo "IEEE_ROWS: $PASS passed, $FAIL failed of $DECLARED"
[ "$FAIL" = 0 ]
