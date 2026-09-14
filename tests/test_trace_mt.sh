#!/bin/bash
# #1142/#1143: the trace tape under threads and states.
#
# Probe-gated. Cwd is src/ when the suite invokes this (tests/run_all_tests.sh
# does `cd .../src`). Prints PASS:/FAIL: lines. Exit 0 iff FAIL=0.
#
# --selftest feeds the parser a torn tape and an empty tape and requires
# both red, plus a well-formed fixture green. The suite pins the PASS count.
set -u

TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC_DIR="$(cd "$TESTS_DIR/../src" && pwd)"
EIGS="$SRC_DIR/eigenscript"

PASS=0
FAIL=0
TMPDIR=$(mktemp -d -t eigs_trace_mt.XXXXXX)
trap 'rm -rf "$TMPDIR"' EXIT

ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1${2:+ ($2)}"; FAIL=$((FAIL+1)); }

# Grammar from docs/TRACE.md. Prints: lines well malformed nrec ocfg examined
# examined == lines, and is asserted > 0 by callers. A check that examined 0
# items is a FAIL (mechanical-gates §121).
parse_tape() {
    local file=$1
    if [ ! -s "$file" ]; then
        echo "0 0 0 0 0 0"
        return
    fi
    awk '
    function ok_line(s) {
        if (s ~ /^V [0-9]+ /) return 1
        if (s ~ /^L [0-9]+$/) return 1
        if (s ~ /^S [^ ]+ [0-9]+ [0-9]+$/) return 1
        if (s ~ /^A .+=/) return 1
        if (s ~ /^N .+=/) return 1
        if (s ~ /^O cfg [^ ]+ [^ ]+ [^ ]+ [0-9]+ [^ ]+$/) return 1
        if (s ~ /^O win [^ ]+ [0-9]+$/) return 1
        return 0
    }
    {
        lines++
        if (ok_line($0)) {
            well++
            if ($0 ~ /^N /) nrec++
            if ($0 ~ /^O cfg /) ocfg++
        } else malformed++
    }
    END {
        if (lines == "") lines=0
        if (well == "") well=0
        if (malformed == "") malformed=0
        if (nrec == "") nrec=0
        if (ocfg == "") ocfg=0
        print lines+0, well+0, malformed+0, nrec+0, ocfg+0, lines+0
    }' "$file"
}

if [ ! -x "$EIGS" ]; then
    echo "  FAIL: eigenscript binary not found at $EIGS"
    echo "TRACE_MT: 0 passed, 1 failed"
    exit 1
fi

selftest() {
    local torn="$TMPDIR/torn.tape"
    local empty="$TMPDIR/empty.tape"
    local good="$TMPDIR/good.tape"
    printf '%s\n' 'V 3 0.43.0' '30257A r=570844060311' '30101653L 7' > "$torn"
    : > "$empty"
    printf '%s\n' 'V 3 0.43.0' 'L 1' 'N random=0.5' 'A x=1' > "$good"

    local t_lines t_well t_mal t_n t_o t_ex
    read -r t_lines t_well t_mal t_n t_o t_ex <<< "$(parse_tape "$torn")"
    if [ "$t_mal" -gt 0 ] && [ "$t_ex" -gt 0 ]; then
        ok "selftest: torn tape is red (malformed=$t_mal examined=$t_ex)"
    else
        fail "selftest: torn tape is red" "malformed=$t_mal examined=$t_ex"
    fi

    read -r t_lines t_well t_mal t_n t_o t_ex <<< "$(parse_tape "$empty")"
    if [ "$t_ex" -eq 0 ] && [ "$t_lines" -eq 0 ]; then
        ok "selftest: empty tape is red (examined=0)"
    else
        fail "selftest: empty tape is red" "examined=$t_ex lines=$t_lines"
    fi
    # The live checks refuse examined==0; this row proves the empty fixture
    # is the input that trips that refusal, not a parser that always says 0.
    if [ "$t_ex" -eq 0 ]; then
        ok "selftest: empty tape examined==0 is the live-check refusal"
    else
        fail "selftest: empty tape examined==0 is the live-check refusal" "examined=$t_ex"
    fi

    read -r t_lines t_well t_mal t_n t_o t_ex <<< "$(parse_tape "$good")"
    if [ "$t_mal" -eq 0 ] && [ "$t_ex" -eq 4 ] && [ "$t_n" -eq 1 ]; then
        ok "selftest: well-formed fixture is green (examined=$t_ex N=$t_n)"
    else
        fail "selftest: well-formed fixture is green" \
             "malformed=$t_mal examined=$t_ex N=$t_n"
    fi

    echo ""
    echo "TRACE_MT_SELFTEST: $PASS passed, $FAIL failed"
    [ "$FAIL" -eq 0 ]
}

if [ "${1:-}" = "--selftest" ]; then
    selftest
    exit $?
fi

# ---- live probes -------------------------------------------------------

echo "=== worker-tape (2 workers x 2000 x 3 nondet) ==="
tape="$TMPDIR/workers.tape"
EIGS_TRACE="$tape" "$EIGS" "$TESTS_DIR/trace_mt_workers.eigs" >"$TMPDIR/workers.out" 2>"$TMPDIR/workers.err"
wrc=$?
read -r lines well mal nrec ocfg examined <<< "$(parse_tape "$tape")"
if [ "$wrc" -eq 0 ]; then
    ok "worker-tape: program exited 0"
else
    fail "worker-tape: program exited 0" "rc=$wrc"
fi
if [ "$examined" -gt 0 ]; then
    ok "worker-tape: parser examined lines > 0 (examined=$examined)"
else
    fail "worker-tape: parser examined lines > 0" "examined=$examined"
fi
if [ "$examined" -eq "$lines" ] && [ "$lines" -gt 0 ]; then
    ok "worker-tape: examined == lines ($lines)"
else
    fail "worker-tape: examined == lines" "examined=$examined lines=$lines"
fi
if [ "$mal" -eq 0 ]; then
    ok "worker-tape: malformed == 0"
else
    fail "worker-tape: malformed == 0" "malformed=$mal e.g. $(grep -vE '^(V |L |S |A |N |O )' "$tape" | head -1)"
fi
if [ "$nrec" -eq 12000 ]; then
    ok "worker-tape: N == 12000"
else
    fail "worker-tape: N == 12000" "N=$nrec well=$well"
fi
if [ "$well" -eq "$lines" ]; then
    ok "worker-tape: every line well-formed"
else
    fail "worker-tape: every line well-formed" "well=$well lines=$lines"
fi

echo "=== single-worker control ==="
stape="$TMPDIR/single.tape"
EIGS_TRACE="$stape" "$EIGS" "$TESTS_DIR/trace_mt_single.eigs" >"$TMPDIR/single.out" 2>"$TMPDIR/single.err"
src=$?
read -r slines swell smal snrec socfg sexamined <<< "$(parse_tape "$stape")"
if [ "$src" -eq 0 ] && [ "$smal" -eq 0 ] && [ "$snrec" -eq 6000 ] && [ "$sexamined" -gt 0 ]; then
    ok "single-worker: N == 6000 malformed == 0 (unchanged)"
else
    fail "single-worker: N == 6000 malformed == 0" \
         "rc=$src N=$snrec malformed=$smal examined=$sexamined"
fi

echo "=== replay-workers (must fail-loud, no signal) ==="
# Build a synthetic tape with this binary's V header + 4000 N random=0.5.
hdr="$TMPDIR/hdr.tape"
printf 'print of 1\n' > "$TMPDIR/one.eigs"
EIGS_TRACE="$hdr" "$EIGS" "$TMPDIR/one.eigs" >/dev/null 2>&1
vline=$(head -1 "$hdr" 2>/dev/null || true)
rtape="$TMPDIR/replay.tape"
{
    printf '%s\n' "$vline"
    i=0
    while [ "$i" -lt 4000 ]; do
        printf 'N random=0.5\n'
        i=$((i + 1))
    done
} > "$rtape"
EIGS_REPLAY="$rtape" "$EIGS" "$TESTS_DIR/trace_mt_replay_workers.eigs" \
    >"$TMPDIR/replay.out" 2>"$TMPDIR/replay.err"
rrc=$?
diag=$(head -1 "$TMPDIR/replay.err" 2>/dev/null || true)
if [ "$rrc" -eq 1 ]; then
    ok "replay-workers: rc == 1"
else
    fail "replay-workers: rc == 1" "rc=$rrc"
fi
if printf '%s\n' "$diag" | grep -q 'not replayable under EIGS_REPLAY'; then
    ok "replay-workers: diagnostic names the recv-family refusal"
else
    fail "replay-workers: diagnostic names the recv-family refusal" "stderr=$diag"
fi
if [ "$rrc" -lt 128 ]; then
    ok "replay-workers: no signal"
else
    fail "replay-workers: no signal" "rc=$rrc (signal $((rrc - 128)))"
fi

echo "=== read_bytes_buf-worker (hand-rolled take must fail-loud) ==="
printf 'x\n' > "$TMPDIR/blob"
printf '%s\n' \
    "define worker(id) as:" \
    "    local x is read_bytes_buf of \"$TMPDIR/blob\"" \
    "    return x" \
    "h is spawn of [worker, 1]" \
    "a is thread_join of h" \
    "print of \"done\"" \
    > "$TMPDIR/rbb.eigs"
EIGS_REPLAY="$rtape" "$EIGS" "$TMPDIR/rbb.eigs" \
    >"$TMPDIR/rbb.out" 2>"$TMPDIR/rbb.err"
rbrc=$?
rbdiag=$(head -1 "$TMPDIR/rbb.err" 2>/dev/null || true)
if [ "$rbrc" -eq 1 ]; then
    ok "read_bytes_buf-worker: rc == 1"
else
    fail "read_bytes_buf-worker: rc == 1" "rc=$rbrc"
fi
if printf '%s\n' "$rbdiag" | grep -q 'not replayable under EIGS_REPLAY'; then
    ok "read_bytes_buf-worker: diagnostic names the recv-family refusal"
else
    fail "read_bytes_buf-worker: diagnostic names the recv-family refusal" "stderr=$rbdiag"
fi
if [ "$rbrc" -lt 128 ]; then
    ok "read_bytes_buf-worker: no signal"
else
    fail "read_bytes_buf-worker: no signal" "rc=$rbrc"
fi

echo ""
echo "TRACE_MT: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
