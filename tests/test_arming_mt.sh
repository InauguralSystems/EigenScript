#!/bin/bash
# #1145: the observer ARMING SETS under concurrency.
#
# Two shapes, and they need DIFFERENT coverage — which is the whole point of
# the issue (mechanical-gates §51):
#
#   (a) ONE state, spawn. A worker compiling `what is q when 1` reallocs the
#       OCCURRENCE set (g_occ_names) while other workers' assignments walk it
#       (prev_record_assign -> occ_set_has). `spawn` widens only the HISTORY
#       tier (#827 trace_arm_history_all_mt), and the occurrence tier has no
#       wildcard by design (#868), so a spawn-time escape alone cannot cover
#       it. Rows: arming_mt_occ (the shape) and arming_mt_hist (the #827
#       control that was already clean — without it, a quiet occurrence row
#       could just mean the whole file went quiet, §23/§64).
#
#   (b) TWO embed STATES, no spawn. `multithreaded` is PER STATE, so it is 0
#       on both and nothing widens anything. No .eigs program can express
#       this, so it is a C row: tests/test_arming_two_states.c, built through
#       the `arming-mt-test` Makefile target against the SAME variant the
#       suite is running (so the ASan lane sanitizes it too).
#
# Probe-gated. Cwd is src/ when the suite invokes this. Prints PASS:/FAIL:
# lines; exit 0 iff FAIL=0. The suite pins BOTH totals.
#
# Every pinned number is a CONSERVED quantity (§131) — compile counts,
# assignment counts, an accumulator total, and the temporal ANSWER each query
# must give. Never an interleaving.
#
# CONSTRUCTION rows pin that the guard is ONE leaf mutex taken
# UNCONDITIONALLY. That last part is load-bearing and no live row can see it:
# a guard gated on `g_vm_multithreaded` (or on a thread count) would pass
# every row here and still be 0 on both threads of shape (b) — the exact
# defect. Residual (§6): text checks over C source; they pin the shape, not
# the atomicity of pthread_mutex_lock.
#
# --selftest drives the SAME verify_capture() the live rows drive (§99) with
# captured bad output, and pins the EXACT SET of check names each fixture
# fires (§16/§38).
set -u

TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$TESTS_DIR/.." && pwd)"
SRC_DIR="$(cd "$TESTS_DIR/../src" && pwd)"
EIGS="$SRC_DIR/eigenscript"
FIX_DIR="$TESTS_DIR/arming_mt_fixtures"

PASS=0
FAIL=0
TMPDIR=$(mktemp -d -t eigs_arming_mt.XXXXXX)
trap 'rm -rf "$TMPDIR"' EXIT

ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
# The trailing colon is load-bearing: tools/mutants.sh arming_mt derives WHICH
# check killed a mutant with `s/^  FAIL: \([^:]*\):.*/\1/`, so a row whose
# name is not colon-terminated is invisible in the kill reason (§21). Every
# row name above is therefore a single token before its first colon.
fail() { echo "  FAIL: $1${2:+: ($2)}"; FAIL=$((FAIL+1)); }

# Checks, and what each one ALONE can see:
#   rc          the probe exited nonzero
#   nonempty    the capture has no bytes at all
#   population  the capture's line count differs from the expectation's, or
#               either is 0 (§121)
#   sanitizer   an ASan/TSan/UBSan diagnostic rode along in the capture — the
#               shape this issue's defect takes on the ASan lane
#               (heap-use-after-free in arm_set_has)
#   exact       the capture differs from the hand-written expected file
VERIFY_FIRED=""
verify_capture() {   # verify_capture <expected_file> <actual_file> <rc>
    local expected=$1 actual=$2 rc=$3
    local fired=""
    [ "$rc" -eq 0 ] || fired="$fired rc"
    [ -s "$actual" ] || fired="$fired nonempty"
    local a_lines e_lines
    # awk, not `grep -c .`: grep exits 1 on an empty file and `|| echo 0`
    # then yields TWO words, which makes [ -ne ] a syntax error and leaves
    # the population check silently unevaluated (§7).
    a_lines=$(awk 'NF{n++} END{print n+0}' "$actual" 2>/dev/null)
    e_lines=$(awk 'NF{n++} END{print n+0}' "$expected" 2>/dev/null)
    if [ "$a_lines" -ne "$e_lines" ] || [ "$a_lines" -eq 0 ]; then
        fired="$fired population"
    fi
    if grep -qE 'AddressSanitizer|ThreadSanitizer|LeakSanitizer|runtime error:' "$actual"; then
        fired="$fired sanitizer"
    fi
    if ! diff -q "$expected" "$actual" >/dev/null 2>&1; then
        fired="$fired exact"
    fi
    VERIFY_FIRED=$(printf '%s\n' $fired | sort -u | paste -sd+ -)
}


# ---- every live row is BOUNDED (#1144 round 3) --------------------------
#
# A missing unlock on ONE exit path of a locked function passes every
# construction row here — unlocks are counted per FUNCTION, and making the
# grep exit-path-aware would be another text trick, not an execution witness
# (the dead-coded `if (0) { arm_lock(); }` mutant passes a per-site grep
# too). The runtime witness is the CLOCK: a critic's mutant that dropped the
# unlock on `eigs_module_cache_put`'s lost-race return left this script
# HUNG with only its first PASS line printed, so [42j] and CI would have sat
# until the job timeout instead of failing. Every row now runs under a bound
# and rc 124 is a named FAIL.
#
# NOT a bare `timeout`: the macOS CI runners do not ship coreutils' timeout
# and a child that calls it dies rc 127 there on its first bounded run
# (.claude/rules/test-suite.md). Probe exactly as run_all_tests.sh does, and
# if NEITHER is present say so in the row rather than pretending it is bound
# — an unbounded row is the hang this exists to catch.
ROW_TMO_CMD=""
if command -v timeout >/dev/null 2>&1; then ROW_TMO_CMD="timeout"
elif command -v gtimeout >/dev/null 2>&1; then ROW_TMO_CMD="gtimeout"; fi
# The bound is a claim about the MACHINE, so it is a MEASURED multiple, not a
# round number (mechanical-gates §120). Slowest row on this box, release /
# ASan: loader_mt_loadfile 1.11 s / 4.77 s, arming_mt_occ 0.26 s / 2.85 s,
# lm_nsread 0.14 s / 1.27 s. 60 s is ~12x the slowest ASan row, which leaves
# room for a CI runner several times slower than this box while still turning
# a deadlock around in a minute instead of sitting on it. Override with
# EIGS_MT_ROW_TIMEOUT if a lane ever needs more.
ROW_TIMEOUT=${EIGS_MT_ROW_TIMEOUT:-60}

RUN_RC=0
RUN_BOUNDED=0          # 1 when this run was actually under a bound
run_bounded() {        # run_bounded <outfile> <cmd> [args...]
    local out=$1; shift
    if [ -n "$ROW_TMO_CMD" ]; then
        RUN_BOUNDED=1
        "$ROW_TMO_CMD" "$ROW_TIMEOUT" "$@" >"$out" 2>&1
    else
        RUN_BOUNDED=0
        "$@" >"$out" 2>&1
    fi
    RUN_RC=$?
}

SELFTEST_ONLY=0
[ "${1:-}" = "--selftest" ] && SELFTEST_ONLY=1

if [ "$SELFTEST_ONLY" -eq 0 ]; then

# ---- (a) spawn shape: DECLARED probes, never globbed (§121) -------------
PROBES="arming_mt_occ arming_mt_hist arming_mt_st"
PROBES_DECLARED=3
EXAMINED=0
for name in $PROBES; do
    EXAMINED=$((EXAMINED + 1))
    probe="$TESTS_DIR/$name.eigs"
    exp="$FIX_DIR/$name.expected"
    if [ ! -f "$probe" ]; then fail "$name" "probe missing"; continue; fi
    if [ ! -f "$exp" ];   then fail "$name" "expected missing"; continue; fi
    out="$TMPDIR/$name.out"
    run_bounded "$out" "$EIGS" "$probe"
    rc=$RUN_RC
    if [ "$rc" -eq 124 ] && [ "$RUN_BOUNDED" -eq 1 ]; then
        fail "$name" "HUNG — no exit after ${ROW_TIMEOUT}s (a lock held across a return?)"
        continue
    fi
    verify_capture "$exp" "$out" "$rc"
    if [ -z "$VERIFY_FIRED" ]; then
        ok "$name"
    else
        fail "$name" "$VERIFY_FIRED"
        diff "$exp" "$out" | head -8
    fi
done
if [ "$EXAMINED" -eq "$PROBES_DECLARED" ] && [ "$EXAMINED" -gt 0 ]; then
    if [ -n "$ROW_TMO_CMD" ]; then
        ok "population: probes examined == declared ($EXAMINED), each bounded at ${ROW_TIMEOUT}s by $ROW_TMO_CMD"
    else
        ok "population: probes examined == declared ($EXAMINED) — NOTE: no timeout/gtimeout on this host, rows are UNBOUNDED"
    fi
else
    fail "population" "examined=$EXAMINED declared=$PROBES_DECLARED"
fi

# ---- (b) two-state shape: the C row -------------------------------------
# Build the aux target only (never relinks the CLI alias), against the
# variant src/eigenscript is hard-linked to — same discipline as
# tests/test_embed_observer.sh, so the ASan lane sanitizes this row too.
variant=
for candidate in "$ROOT"/build/*/eigenscript; do
    if [ "$SRC_DIR/eigenscript" -ef "$candidate" ]; then
        variant=$(basename "$(dirname "$candidate")")
        break
    fi
done
[ -n "$variant" ] || variant=release
TS_BUILD=$(make --no-print-directory -C "$ROOT" arming-mt-test "ARMING_MT_VARIANT=$variant" 2>&1)
TS_BUILD_RC=$?
TS_BIN="$ROOT/build/$variant/test_arming_two_states"
if [ "$TS_BUILD_RC" -ne 0 ] || [ ! -x "$TS_BIN" ]; then
    fail "two-state build" "rc=$TS_BUILD_RC variant=$variant"
    echo "$TS_BUILD" | tail -6
else
    TS_OUT="$TMPDIR/two_states.out"
    run_bounded "$TS_OUT" "$TS_BIN"
    TS_RC=$RUN_RC
    TS_PASS=$(grep -c '^  PASS:' "$TS_OUT" || true)
    TS_FAIL=$(grep -c '^  FAIL:' "$TS_OUT" || true)
    # The harness's own declared total. Pinned here so a harness that
    # silently stops emitting rows is a FAIL, not a quieter pass (§37).
    TS_EXPECTED=7
    if [ "$TS_RC" -eq 124 ] && [ "$RUN_BOUNDED" -eq 1 ]; then
        fail "two-state arming ($variant)" "HUNG — no exit after ${ROW_TIMEOUT}s"
    elif [ "$TS_RC" -eq 0 ] && [ "$TS_FAIL" -eq 0 ] && [ "$TS_PASS" -eq "$TS_EXPECTED" ] \
       && ! grep -qE 'AddressSanitizer|ThreadSanitizer|LeakSanitizer|runtime error:' "$TS_OUT"; then
        ok "two-state arming ($variant): all $TS_PASS checks"
    else
        fail "two-state arming ($variant)" "rc=$TS_RC pass=$TS_PASS/$TS_EXPECTED fail=$TS_FAIL"
        sed -n '1,12p' "$TS_OUT"
    fi
fi

# ---- CONSTRUCTION rows --------------------------------------------------
TRACE_C="$SRC_DIR/trace.c"

# 1. EVERY site the design says holds g_arm_mu holds it, checked PER SITE,
#    and the total equals the declared count.
#
#    This row used to be a file-wide FLOOR (`arm_lock` call sites >= 6). A
#    critic's mutant deleted the lock/unlock pair inside `arm_set_has` — the
#    READER, the site the whole guard exists for — taking the count 7 -> 6.
#    The floor still passed, the release oracle never reached the
#    interleaving, and the mutant SURVIVED 10/10 with `ARMING_MT: 9 passed,
#    0 failed` every run. A floor derived from the mechanism it guards is not
#    a floor (mechanical-gates §122/§43): it cannot tell "one site lost its
#    lock" from "the file has one fewer line".
#
#    So: the sites are ENUMERATED BY NAME from the design (the two readers,
#    the two insert paths, the snapshot/restore pair, and the shutdown free),
#    each must contain its own lock AND unlock, and `found == declared` in
#    BOTH directions (§2) — a new unlisted lock site fails too, because it is
#    a site nobody reviewed.
ARM_LOCK_SITES="arm_set_has occ_set_has trace_arm_history_name \
trace_arm_occurrences_name trace_arm_snapshot trace_arm_restore trace_shutdown"
ARM_LOCK_DECLARED=7

# Body of function $2 in file $1: from its opening line to the first
# column-0 `}`. Every function checked here is written that way.
fn_body() {
    awk -v name="$2" '
        $0 ~ ("^[A-Za-z_].*[ *]" name "\\(") { f = 1 }
        f { print }
        f && /^\}$/ { exit }
    ' "$1"
}

arm_examined=0
arm_bad=""
for fn in $ARM_LOCK_SITES; do
    arm_examined=$((arm_examined + 1))
    body=$(fn_body "$TRACE_C" "$fn")
    b_lock=$(printf '%s\n' "$body" | grep -c 'arm_lock();' || true)
    b_unlock=$(printf '%s\n' "$body" | grep -c 'arm_unlock();' || true)
    if [ -z "$body" ]; then
        arm_bad="$arm_bad $fn(missing)"
    elif [ "$b_lock" -lt 1 ] || [ "$b_unlock" -lt 1 ]; then
        arm_bad="$arm_bad $fn(lock=$b_lock,unlock=$b_unlock)"
    fi
done
arm_total=$(grep -c '^\s*arm_lock();' "$TRACE_C" || true)
arm_unlock_total=$(grep -c 'arm_unlock();' "$TRACE_C" || true)
# EXACT, in both directions. The two `_locked` helpers are each DEFINED once
# and CALLED twice (from their public wrapper and from the tier's insert
# path), so the declared mention count is 6. A floor would stay green if a
# call site were deleted — which is exactly the shape that lets a tier lose
# its check-then-insert atomicity.
ARM_HELPER_DECLARED=6
has_locked=$(grep -c 'arm_set_has_locked\|occ_set_has_locked' "$TRACE_C" || true)
# Unlocks are counted PER SITE above. The total is exact too: the two insert
# paths each release on three exits (already-present, OOM x2) plus the tail,
# the rest release once. A lock held across a return that still balances
# textually is caught by the row bound (rc 124 -> HUNG), not by counting.
ARM_UNLOCK_DECLARED=13
if [ -z "$arm_bad" ] && [ "$arm_examined" -eq "$ARM_LOCK_DECLARED" ] \
   && [ "$arm_total" -eq "$ARM_LOCK_DECLARED" ] \
   && [ "$arm_unlock_total" -eq "$ARM_UNLOCK_DECLARED" ] \
   && [ "$has_locked" -eq "$ARM_HELPER_DECLARED" ]; then
    ok "construction_armlocked: all $ARM_LOCK_DECLARED declared sites hold g_arm_mu (found == declared)"
else
    fail "construction_armlocked: per-site hold" "unheld:${arm_bad:- none} examined=$arm_examined/$ARM_LOCK_DECLARED lock=$arm_total/$ARM_LOCK_DECLARED unlock=$arm_unlock_total/$ARM_UNLOCK_DECLARED helpers=$has_locked/$ARM_HELPER_DECLARED"
fi

# 2. The guard is UNCONDITIONAL. A predicate here (g_vm_multithreaded, or a
#    thread count) is exactly the #1145(b) defect: per-state flags are 0 on
#    both threads of a two-state host, so the lock would never be taken and
#    every row above would still pass. This is the row that cannot be
#    satisfied by a narrower spelling.
arm_body=$(awk '/^static inline void arm_lock\(void\)/{print; exit}' "$TRACE_C")
if [ -n "$arm_body" ] \
   && printf '%s\n' "$arm_body" | grep -q 'pthread_mutex_lock(&g_arm_mu)' \
   && ! printf '%s\n' "$arm_body" | grep -q 'if\|multithreaded\|thread_count'; then
    ok "construction_unconditional: arm_lock really locks, and unconditionally"
else
    fail "construction_unconditional: arm_lock predicate" "body='${arm_body:-MISSING}'"
fi

# 3. Both name arrays grow in exactly one place each, and the shrinking
#    writer (trace_arm_restore) and the freeing writer (trace_shutdown) are
#    inside the same hold. Membership in BOTH directions (§2).
grow_arm=$(grep -c 'realloc(g_arm_names' "$TRACE_C" || true)
grow_occ=$(grep -c 'realloc(g_occ_names' "$TRACE_C" || true)
restore_locked=$(awk '/^void trace_arm_restore/{f=1} f{print} f&&/^\}/{exit}' "$TRACE_C" | grep -c 'arm_lock();' || true)
if [ "$grow_arm" -eq 1 ] && [ "$grow_occ" -eq 1 ] && [ "$restore_locked" -eq 1 ]; then
    ok "construction_writers: one grow site per tier; shrinking writer holds the lock"
else
    fail "construction_writers: writers enumerated" "arm=$grow_arm occ=$grow_occ restore=$restore_locked"
fi

# 4. The occurrence tier's window is memoised LAZILY on a per-assignment
#    path, so the plain read-then-write was itself a two-state data race
#    (found by this file's own TSan arm: read at trace_occ_window <-
#    occ_record <- prev_record_assign on one state against the write on the
#    other). Pinned structurally: the resolver publishes with an atomic.
occw=$(awk '/^int trace_occ_window\(void\) \{/{f=1} f{print} f&&/^\}/{exit}' "$TRACE_C")
# EXACT: the resolver acquire-LOADS the memo once and release-STORES it
# once. A floor would stay green with the load removed (the store alone is
# not a memo) or with a third atomic added that nobody reviewed.
OCCW_ATOMIC_DECLARED=2
occw_at=$(printf '%s\n' "$occw" | grep -c '__atomic_' || true)
occw_load=$(printf '%s\n' "$occw" | grep -c '__atomic_load_n(&g_occ_window_storage' || true)
occw_store=$(printf '%s\n' "$occw" | grep -c '__atomic_store_n(&g_occ_window_storage' || true)
if [ -n "$occw" ] && [ "$occw_at" -eq "$OCCW_ATOMIC_DECLARED" ] \
   && [ "$occw_load" -eq 1 ] && [ "$occw_store" -eq 1 ]; then
    ok "construction_occwindow: trace_occ_window memoises atomically (1 acquire load + 1 release store)"
else
    fail "construction_occwindow: memo atomic" "atomics=$occw_at/$OCCW_ATOMIC_DECLARED load=$occw_load store=$occw_store"
fi

fi   # end of the live+construction rows

# ---- selftest -----------------------------------------------------------
selftest() {
    local st_pass=0 st_fail=0 examined=0
    local CASES="bad_occ_lostassign.cap:arming_mt_occ.expected:0:exact \
bad_occ_sanitizer.cap:arming_mt_occ.expected:0:sanitizer+population+exact \
bad_empty.cap:arming_mt_occ.expected:0:nonempty+population+exact \
good_occ.cap:arming_mt_occ.expected:0:"
    for c in $CASES; do
        local capf=${c%%:*}; local rest=${c#*:}
        local expf=${rest%%:*}; rest=${rest#*:}
        local rc=${rest%%:*}; local want=${rest#*:}
        examined=$((examined + 1))
        if [ ! -f "$FIX_DIR/$capf" ]; then
            echo "  FAIL: selftest fixture missing: $capf"; st_fail=$((st_fail+1)); continue
        fi
        verify_capture "$FIX_DIR/$expf" "$FIX_DIR/$capf" "$rc"
        local got="$VERIFY_FIRED" want_sorted
        want_sorted=$(printf '%s\n' ${want//+/ } | grep -v '^$' | sort -u | paste -sd+ -)
        if [ "$got" = "$want_sorted" ]; then
            echo "  PASS: selftest $capf fired [${got:-none}]"; st_pass=$((st_pass+1))
        else
            echo "  FAIL: selftest $capf fired [${got:-none}], want [${want_sorted:-none}]"
            st_fail=$((st_fail+1))
        fi
    done
    if [ "$examined" -eq 4 ] && [ "$examined" -gt 0 ]; then
        echo "  PASS: selftest cases examined == declared ($examined)"; st_pass=$((st_pass+1))
    else
        echo "  FAIL: selftest population: examined=$examined declared=4"; st_fail=$((st_fail+1))
    fi
    echo "ARMING_MT_SELFTEST: $st_pass passed, $st_fail failed"
    [ "$st_fail" -eq 0 ]
    return $?
}

if [ "$SELFTEST_ONLY" -eq 1 ]; then
    selftest
    exit $?
fi

echo "ARMING_MT: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
