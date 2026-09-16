#!/bin/bash
# #1146 (thread handles: claim step, generation, full table) + #1161 (the
# module-env lock predicate).
#
# Probe-gated. Cwd is src/ when the suite invokes this (tests/run_all_tests.sh
# does `cd .../src`), so every path here is derived from $0 and absolute.
# Prints PASS:/FAIL: lines. Exit 0 iff FAIL=0. The suite pins BOTH totals.
#
# THE HANG IS THE WITNESS. Every defect this file gates is, at its worst, a
# process that stops: the double `pthread_join` of #1146 (1) never returns on
# glibc (measured on the pre-fix binary at f532c8d: rc 124 at a 30 s bound,
# 3/3 runs, main + one joiner parked in futex_wait_queue). So EVERY live row
# runs under a bound and rc 124 is a NAMED FAIL, never a silent wait to the CI
# job timeout (mechanical-gates §136). Removing the claim step is killed by
# that row and by nothing else.
#
# Two kinds of row, with different blind spots:
#
#   LIVE rows run a probe and compare its capture against a HAND-WRITTEN
#   expected file — never against the binary's own output. Every pinned number
#   is a CONSERVED quantity (§131): "exactly one joiner wins and exactly one
#   is refused" holds under every interleaving, and so does "4,000 distinct
#   new fields plus the module's own two". Nothing here asserts who ran when.
#   Measured discriminating against the pre-fix tree (f532c8d):
#     handles_double_join  HUNG 3/3 at 30 s      -> `HUNG`
#     handles_join_twice   first=2 second=VALUE:null   -> `silentnull`+`exact`
#     handles_reuse        stale=VALUE:FRESH fresh=null -> `silentnull`+`exact`
#     handles_full         raises=0 silent=45           -> `exact`
#     handles_modenv       SIGSEGV / "double free or corruption" 5/5 -> `rc`
#   and, against ROUND 1 (which two blind critics executed):
#     handles_store_stale  get=NO-RAISE(returned null)  -> `exact`+`staleword`
#     handles_channel_stale forged recv returned the message -> `exact`
#
#   CONSTRUCTION rows pin the SHAPE of the fix in src/. They exist for the
#   properties no release run on this box can witness: that the claim and the
#   detach happen under ONE hold of handle_mutex, that EVERY handle resolve a
#   program can reach presents a generation, and that the "shared env" question
#   has exactly ONE answer in the tree. Residual (§6): these are TEXT checks —
#   a grep proves PRESENCE, never EXECUTION (§135), which is why each one names
#   the runtime lane that would go red without it, and why the live rows above
#   are bounded.
#
# --selftest drives the SAME verify_capture() the live rows drive with captures
# taken from the real pre-fix binary, plus a zero-population capture, plus a
# positive control that must stay GREEN. Each fixture pins the EXACT SET of
# check names that fire, not a count — that is what witnesses each individual
# check: delete `silentnull` and the pre-fix fixtures' sets change; delete
# `population` and the empty capture goes green.
set -u

TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC_DIR="$(cd "$TESTS_DIR/../src" && pwd)"
EIGS="$SRC_DIR/eigenscript"
FIX_DIR="$TESTS_DIR/handles_mt_fixtures"

PASS=0
FAIL=0
TMPDIR=$(mktemp -d -t eigs_handles_mt.XXXXXX)
trap 'rm -rf "$TMPDIR"' EXIT

ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
# The trailing colon is load-bearing: tools/*_mt_mutants.sh derives WHICH
# check killed a mutant with `s/^  FAIL: \([^:]*\):.*/\1/`, so a row whose
# name is not colon-terminated is invisible in the kill reason. Every row name
# below is therefore a single token before its first colon.
fail() { echo "  FAIL: $1${2:+: ($2)}"; FAIL=$((FAIL+1)); }

# ---- the gate -----------------------------------------------------------
#
# Sets VERIFY_FIRED to a "+"-joined, sorted list of the CHECK NAMES that fired
# (empty = the capture is good). Deliberately NOT echo-and-capture: `v=$(fn)`
# runs fn in a subshell and the caller never sees the global.
#
# Checks, and what each one ALONE can see:
#   rc          the probe exited nonzero — the #1161 crash, or an uncaught raise
#   nonempty    the capture has no bytes at all
#   population  the capture's line count differs from the expected file's, or
#               either is 0 (§121: a row that examined nothing is a FAIL)
#   silentnull  the capture carries a `null` the expectation does not — the
#               pre-fix signature of BOTH silent-failure modes (a second join
#               returning null, and an ABA'd fresh handle returning null). The
#               one check that needs no expected file to be meaningful.
#   sanitizer   an ASan/TSan/UBSan/LSan diagnostic rode along in the capture
#   staleword   (rows that declare it) the capture does not contain the word
#               "stale". ROUND 2 / G2: a stale channel handle used to be refused
#               with "send: invalid channel" — a refusal, which was the bar, but
#               a user cannot tell a recycled handle from one that was never
#               valid. The probes print the RUNTIME's own message, so this check
#               reads the runtime's vocabulary and not the probe's tag; it goes
#               red if the wording ever drifts back to generic.
#   exact       the capture differs from the hand-written expected file
VERIFY_FIRED=""
verify_capture() {   # verify_capture <expected_file> <actual_file> <rc> [wantstale]
    local expected=$1 actual=$2 rc=$3 wantstale=${4:-0}
    local fired=""
    [ "$rc" -eq 0 ] || fired="$fired rc"
    if [ ! -s "$actual" ]; then
        fired="$fired nonempty"
    fi
    local a_lines e_lines
    # awk, not `grep -c .`: grep exits 1 on an empty file and `|| echo 0` then
    # yields TWO words, which makes the [ -ne ] below a syntax error and the
    # population check silently unevaluated.
    a_lines=$(awk 'NF{n++} END{print n+0}' "$actual" 2>/dev/null)
    e_lines=$(awk 'NF{n++} END{print n+0}' "$expected" 2>/dev/null)
    if [ "$a_lines" -ne "$e_lines" ] || [ "$a_lines" -eq 0 ]; then
        fired="$fired population"
    fi
    if grep -q 'null' "$actual" && ! grep -q 'null' "$expected"; then
        fired="$fired silentnull"
    fi
    if grep -qE 'AddressSanitizer|ThreadSanitizer|LeakSanitizer|runtime error:' "$actual"; then
        fired="$fired sanitizer"
    fi
    if [ "$wantstale" -eq 1 ] && ! grep -qE 'stale|reused' "$actual"; then
        fired="$fired staleword"
    fi
    if ! diff -q "$expected" "$actual" >/dev/null 2>&1; then
        fired="$fired exact"
    fi
    VERIFY_FIRED=$(printf '%s\n' $fired | sort -u | paste -sd+ -)
}

# ---- every live row is BOUNDED ------------------------------------------
#
# NOT a bare `timeout`: the macOS CI runners do not ship coreutils' timeout and
# a child that calls it dies rc 127 there on its first bounded run
# (.claude/rules/test-suite.md). Probe exactly as run_all_tests.sh does, and if
# NEITHER is present say so in the row rather than pretending it is bound — an
# unbounded row is precisely the hang this file exists to catch.
ROW_TMO_CMD=""
if command -v timeout >/dev/null 2>&1; then ROW_TMO_CMD="timeout"
elif command -v gtimeout >/dev/null 2>&1; then ROW_TMO_CMD="gtimeout"; fi
# The bound is a claim about the MACHINE, so it is a MEASURED multiple, not a
# round number (mechanical-gates §120). Measured on this box (median of 3),
# release / ASan+UBSan with detect_leaks=1:
#   handles_reuse         0.22 s / 1.05 s   <- slowest
#   handles_full          0.13 s / 0.83 s
#   handles_double_join   0.12 s / 0.61 s
#   handles_store_stale   0.10 s / 0.13 s   (round 2)
#   handles_channel_stale 0.01 s / 0.09 s   (round 2)
#   hm_modenv             0.04 s / 0.35 s
#   handles_join_twice    0.01 s / 0.09 s
# 120 s is ~115x the slowest ASan row, which leaves a very slow CI runner all
# the room it needs while still turning a deadlock around in two minutes
# instead of sitting on it until the job timeout. Override with
# EIGS_MT_ROW_TIMEOUT.
ROW_TIMEOUT=${EIGS_MT_ROW_TIMEOUT:-120}

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

# ---- LIVE rows ----------------------------------------------------------
if [ "$SELFTEST_ONLY" -eq 0 ]; then
#
# DECLARED, not globbed: a missing probe is a FAIL, never a silent shrink
# (§121). Column 2 is the probe path relative to tests/.
# Column 3 is 1 when the row demands the runtime SAY "stale"/"reused" (G2).
PROBES="handles_double_join:handles_double_join.eigs:0 \
handles_join_twice:handles_join_twice.eigs:0 \
handles_reuse:handles_reuse.eigs:0 \
handles_full:handles_full.eigs:0 \
handles_modenv:handles_mt_modules/hm_modenv.eigs:0 \
handles_store_stale:handles_store_stale.eigs:1 \
handles_channel_stale:handles_channel_stale.eigs:1"
PROBES_DECLARED=7
STALEWORD_DECLARED=2
staleword_rows=0
EXAMINED=0

for entry in $PROBES; do
    name=${entry%%:*}
    rest=${entry#*:}
    rel=${rest%%:*}
    wantstale=${rest#*:}
    [ "$wantstale" -eq 1 ] && staleword_rows=$((staleword_rows + 1))
    EXAMINED=$((EXAMINED + 1))
    probe="$TESTS_DIR/$rel"
    exp="$FIX_DIR/$name.expected"
    if [ ! -f "$probe" ]; then fail "$name" "probe missing: $probe"; continue; fi
    if [ ! -f "$exp" ];   then fail "$name" "expected missing: $exp";  continue; fi
    out="$TMPDIR/$name.out"
    run_bounded "$out" "$EIGS" "$probe"
    rc=$RUN_RC
    if [ "$rc" -eq 124 ] && [ "$RUN_BOUNDED" -eq 1 ]; then
        # Not verify_capture's business: a hung run's capture is truncated, so
        # `rc`+`exact` would fire and bury the real reason. THIS is the row
        # that kills `claim-step-removed`.
        fail "$name" "HUNG — no exit after ${ROW_TIMEOUT}s (two joiners on one pthread_join?)"
        continue
    fi
    verify_capture "$exp" "$out" "$rc" "$wantstale"
    if [ -z "$VERIFY_FIRED" ]; then
        ok "$name"
    else
        fail "$name" "$VERIFY_FIRED"
        diff "$exp" "$out" | head -8
    fi
done

# §121 in both directions, and the staleword population too: a row that
# silently stopped demanding the word would otherwise be invisible.
if [ "$EXAMINED" -eq "$PROBES_DECLARED" ] && [ "$EXAMINED" -gt 0 ] \
   && [ "$staleword_rows" -eq "$STALEWORD_DECLARED" ]; then
    if [ -n "$ROW_TMO_CMD" ]; then
        ok "population: probes examined == declared ($EXAMINED, $staleword_rows demanding the stale wording), each bounded at ${ROW_TIMEOUT}s by $ROW_TMO_CMD"
    else
        ok "population: probes examined == declared ($EXAMINED) — NOTE: no timeout/gtimeout on this host, rows are UNBOUNDED"
    fi
else
    fail "population" "examined=$EXAMINED declared=$PROBES_DECLARED staleword=$staleword_rows/$STALEWORD_DECLARED"
fi

# ---- CONSTRUCTION rows --------------------------------------------------
ES_C="$SRC_DIR/eigenscript.c"
BI_C="$SRC_DIR/builtins.c"

# A shared helper: the body of function $2 in file $1, from its opening line
# to the first column-0 `}`. Every function checked below is written that way.
fn_body() {
    awk -v name="$2" '
        $0 ~ ("^[A-Za-z_].*[ *]" name "\\(") { f = 1 }
        f { print }
        f && /^\}$/ { exit }
    ' "$1"
}
# 1. THE CLAIM STEP. handle_claim resolves AND detaches under ONE hold of
#    handle_mutex, and thread_join goes through it rather than handle_lookup.
#    Pinned PER SITE with exact counts (§134): a file-wide floor over
#    "handle_mutex appears N times" cannot tell "the detach moved out of the
#    hold" from "the file has one fewer line".
#    Runtime lane: handles_double_join's HUNG row (§135) — removing the claim
#    is a hang, not a wrong answer, and no grep witnesses execution.
claim_body=$(fn_body "$ES_C" "handle_claim")
cl_lock=$(printf '%s\n' "$claim_body" | grep -c 'pthread_mutex_lock(&st->handle_mutex)' || true)
cl_unlock=$(printf '%s\n' "$claim_body" | grep -c 'pthread_mutex_unlock(&st->handle_mutex)' || true)
cl_detach=$(printf '%s\n' "$claim_body" | grep -c '^        sl->ptr = NULL;' || true)
join_body=$(fn_body "$BI_C" "builtin_thread_join")
tj_claim=$(printf '%s\n' "$join_body" | grep -c 'handle_claim(hid, hgen, HANDLE_THREAD, &why)' || true)
tj_lookup=$(printf '%s\n' "$join_body" | grep -c 'handle_lookup(' || true)
# The detach must precede the join in PROGRAM order, not merely coexist with
# it: "same function" is not "before" (§126). handle_claim returns before
# pthread_join is called at all, so the order is pinned by there being no
# pthread_join inside handle_claim and exactly one after the claim in
# builtin_thread_join.
tj_pjoin=$(printf '%s\n' "$join_body" | grep -c 'pthread_join(h->tid, NULL)' || true)
cl_pjoin=$(printf '%s\n' "$claim_body" | grep -c 'pthread_join' || true)
if [ "$cl_lock" -eq 1 ] && [ "$cl_unlock" -eq 1 ] && [ "$cl_detach" -eq 1 ] \
   && [ "$tj_claim" -eq 1 ] && [ "$tj_lookup" -eq 0 ] \
   && [ "$tj_pjoin" -eq 1 ] && [ "$cl_pjoin" -eq 0 ]; then
    ok "construction_claim: handle_claim detaches under one handle_mutex hold; thread_join claims before pthread_join"
else
    fail "construction_claim: claim-before-join" "claim(lock=$cl_lock,unlock=$cl_unlock,detach=$cl_detach,pjoin=$cl_pjoin) join(claim=$tj_claim,lookup=$tj_lookup,pjoin=$tj_pjoin)"
fi

# 2. THE GENERATION, enumerated over the WHOLE handle population. Every resolve
#    a program's handle value can reach presents a generation; the only
#    exception is the raw-index scan, which is named, counted, and confined to
#    the two task builtins plus task.c's table walks.
#    §122: the population is produced by a SECOND route — a grep for the call
#    spellings across src/*.c — and compared against a table declared by name
#    here. A site added in a new file is a FAIL, not a silent omission.
GEN_SITES="builtins.c:get_channel_why \
builtins.c:builtin_thread_join \
ext_store.c:get_store_why \
ext_net.c:net_unpack"
GEN_DECLARED=4
# The raw-slot scans, declared by name (a count alone would not say WHICH):
#   builtins.c  builtin_task_join, builtin_task_alive   (a task id is a plain
#               number with nowhere to carry a generation — the ONE declared
#               exception in this population; see docs/CONCURRENCY.md)
#   task.c      sched_lookup, task_any_unobserved_error,
#               sched_wake_sleepers (x2), task_do_kill, sched_finish
SLOT_DECLARED=8
gen_found=0
slot_found=0
for f in "$SRC_DIR"/*.c; do
    case "$f" in *"/eigenscript.c") continue ;; esac   # the definitions live here
    n=$(grep -c 'handle_lookup(\|handle_claim(' "$f" || true)
    gen_found=$((gen_found + n))
    n=$(grep -c 'handle_lookup_slot(' "$f" || true)
    slot_found=$((slot_found + n))
done
# Every generation-checked resolve takes THREE arguments (id, gen, type) or
# four (claim). A two-argument call would be a resolve that ignores the
# generation, which is the `generation-ignored` mutant.
gen_two_arg=$(grep -rn 'handle_lookup([^,)]*, *HANDLE_' "$SRC_DIR"/*.c | grep -c . || true)
# The handle VALUES carry it: one publication per dict-handle producer.
pub_thread=$(grep -c '"_handle_gen", make_num((double)hgen)' "$BI_C" || true)
pub_chan=$(grep -c '"_channel_gen", make_num((double)cgen)' "$BI_C" || true)
pub_store=$(grep -c '"_store_gen", make_num((double)sgen)' "$SRC_DIR/ext_store.c" || true)
# ... and the slot bumps it on every hand-out.
reg_bump=$(printf '%s\n' "$(fn_body "$ES_C" "handle_register")" \
           | grep -c 'st->handle_table\[idx\].gen  = g;' || true)
if [ "$gen_found" -eq "$GEN_DECLARED" ] && [ "$slot_found" -eq "$SLOT_DECLARED" ] \
   && [ "$slot_found" -gt 0 ] && [ "$gen_two_arg" -eq 0 ] \
   && [ "$pub_thread" -eq 1 ] && [ "$pub_chan" -eq 1 ] && [ "$pub_store" -eq 1 ] \
   && [ "$reg_bump" -eq 1 ]; then
    ok "construction_gen: $gen_found generation-checked resolves == declared, $slot_found raw-slot scans == declared, 0 ungenerationed resolves"
else
    fail "construction_gen: population" "gen=$gen_found/$GEN_DECLARED slot=$slot_found/$SLOT_DECLARED twoarg=$gen_two_arg pub(thread=$pub_thread,chan=$pub_chan,store=$pub_store) bump=$reg_bump"
fi

# 3. THE FULL TABLE RAISES, at every registration site, and handle_register
#    itself prints nothing. Enumerated by name; found == declared both ways.
FULL_SITES="builtins.c:builtin_spawn builtins.c:builtin_channel \
builtins.c:builtin_task_spawn ext_store.c:builtin_store_open \
ext_net.c:net_register_sock"
FULL_DECLARED=5
full_examined=0
full_bad=""
for entry in $FULL_SITES; do
    file=${entry%%:*}; fn=${entry#*:}
    full_examined=$((full_examined + 1))
    body=$(fn_body "$SRC_DIR/$file" "$fn")
    b_reg=$(printf '%s\n' "$body" | grep -c 'handle_register(' || true)
    b_raise=$(printf '%s\n' "$body" | grep -c 'rt_error(EK_LIMIT' || true)
    if [ -z "$body" ]; then
        full_bad="$full_bad $fn(missing)"
    elif [ "$b_reg" -ne 1 ] || [ "$b_raise" -lt 1 ]; then
        full_bad="$full_bad $fn(register=$b_reg,raise=$b_raise)"
    fi
done
reg_body=$(fn_body "$ES_C" "handle_register")
reg_print=$(printf '%s\n' "$reg_body" | grep -c 'fprintf' || true)
reg_total=$(grep -c 'handle_register(' "$SRC_DIR"/*.c 2>/dev/null | awk -F: '{n+=$2} END{print n+0}')
# 5 call sites + 1 definition line = 6.
REG_TOTAL_DECLARED=6
if [ -z "$full_bad" ] && [ "$full_examined" -eq "$FULL_DECLARED" ] \
   && [ "$reg_print" -eq 0 ] && [ "$reg_total" -eq "$REG_TOTAL_DECLARED" ]; then
    ok "construction_full: all $FULL_DECLARED registration sites raise EK_LIMIT; handle_register prints nothing"
else
    fail "construction_full: per-site" "bad:${full_bad:- none} examined=$full_examined/$FULL_DECLARED fprintf=$reg_print total=$reg_total/$REG_TOTAL_DECLARED"
fi

# 4. #1161: ONE answer to "is this env shared under MT". The predicate reads a
#    flag the env carries; the flag is set in exactly two places (a root env at
#    creation, a module namespace at attach). The old spelling — `parent ==
#    NULL` — must not survive anywhere in the predicate, because it is TRUE of
#    the sealed roots and FALSE of every module namespace, i.e. it silently
#    excluded the exact envs the issue is about.
#    Runtime lane: the handles_modenv row above (release: SIGSEGV 5/5 pre-fix)
#    and the TSan row in tests/test_tsan.sh (61 reports -> 0).
pred_body=$(awk '/^static inline int env_mt_shared\(const Env \*e\) \{/{f=1} f{print} f&&/^\}$/{exit}' "$ES_C")
pred_flag=$(printf '%s\n' "$pred_body" | grep -c 'e->mt_shared' || true)
pred_parent=$(printf '%s\n' "$pred_body" | grep -c 'parent == NULL' || true)
pred_mt=$(printf '%s\n' "$pred_body" | grep -c 'g_vm_multithreaded' || true)
mark_new=$(printf '%s\n' "$(fn_body "$ES_C" "env_new")" | grep -c 'e->mt_shared = (parent == NULL);' || true)
mark_attach=$(printf '%s\n' "$(fn_body "$ES_C" "eigs_module_ns_attach")" | grep -c 'env_mark_shared(env);' || true)
# found == declared in both directions: exactly two marking sites exist.
mark_total=$(grep -c 'env_mark_shared(' "$SRC_DIR"/*.c "$SRC_DIR"/*.h 2>/dev/null | awk -F: '{n+=$2} END{print n+0}')
MARK_TOTAL_DECLARED=3   # attach call site + definition + header declaration
if [ "$pred_flag" -eq 1 ] && [ "$pred_parent" -eq 0 ] && [ "$pred_mt" -eq 1 ] \
   && [ "$mark_new" -eq 1 ] && [ "$mark_attach" -eq 1 ] \
   && [ "$mark_total" -eq "$MARK_TOTAL_DECLARED" ]; then
    ok "construction_modenv: env_mt_shared reads Env::mt_shared (no parent==NULL); marked at env_new + eigs_module_ns_attach only"
else
    fail "construction_modenv: predicate" "flag=$pred_flag parent=$pred_parent mt=$pred_mt new=$mark_new attach=$mark_attach total=$mark_total/$MARK_TOTAL_DECLARED"
fi

# 5. #1161, the MIRROR half. A module namespace is two structures; the dict
#    mirror takes the same lock in its own hold. Without this the repro is
#    still TSan-dirty (64 stack frames across the 61 pre-fix reports named
#    dict_set_hashed_raw) even with the env correctly locked — so this row and
#    row 4 are NOT redundant.
ns_set=$(printf '%s\n' "$(fn_body "$ES_C" "dict_set_hashed")" \
         | grep -c 'env_shared_lock(me);' || true)
ns_set_u=$(printf '%s\n' "$(fn_body "$ES_C" "dict_set_hashed")" \
           | grep -c 'env_shared_unlock(me);' || true)
proj_body=$(awk '/^static Value \*module_ns_project\(/{f=1} f{print} f&&/^\}$/{exit}' "$ES_C")
proj_lock=$(printf '%s\n' "$proj_body" | grep -c 'env_shared_lock(e);' || true)
proj_unlock=$(printf '%s\n' "$proj_body" | grep -c 'env_shared_unlock(e);' || true)
# EXACT, not a floor: project takes two holds (the env read, then the mirror),
# and the mirror hold has FOUR exits — the miss return, the shared-pointer
# return, the in-place-number return, and the tail. An unlock count that
# balances but sits on the wrong side of a return is caught by the bounded
# live rows, not by this text (§136).
PROJ_LOCK_DECLARED=2
PROJ_UNLOCK_DECLARED=5
if [ "$ns_set" -eq 1 ] && [ "$ns_set_u" -eq 1 ] \
   && [ "$proj_lock" -eq "$PROJ_LOCK_DECLARED" ] \
   && [ "$proj_unlock" -eq "$PROJ_UNLOCK_DECLARED" ]; then
    ok "construction_mirror: the namespace mirror store and every projection exit are inside a hold ($proj_lock lock/$proj_unlock unlock)"
else
    fail "construction_mirror: per-exit" "set(lock=$ns_set,unlock=$ns_set_u) project(lock=$proj_lock/$PROJ_LOCK_DECLARED,unlock=$proj_unlock/$PROJ_UNLOCK_DECLARED)"
fi

# 6. ROUND 2 / G1: EVERY store builtin that resolves a handle goes through the
#    RAISING resolver. The critic's finding was not "a check is missing" — the
#    generation check was there and fired; it was that ONE consumer swallowed
#    the NULL. So the property to pin is a CHOKEPOINT, not a count of checks:
#    the only caller of the resolving primitive is the raising wrapper, so a
#    tenth store builtin cannot re-open the hole by forgetting to raise.
STORE_C="$SRC_DIR/ext_store.c"
STORE_SITES="builtin_store_close builtin_store_put builtin_store_get \
builtin_store_delete builtin_store_query builtin_store_count \
builtin_store_update builtin_store_collections builtin_store_drop"
STORE_DECLARED=9
st_examined=0
st_bad=""
for fn in $STORE_SITES; do
    st_examined=$((st_examined + 1))
    body=$(fn_body "$STORE_C" "$fn")
    b_arg=$(printf '%s\n' "$body" | grep -c 'store_arg(' || true)
    b_raw=$(printf '%s\n' "$body" | grep -c 'get_store_why(' || true)
    if [ -z "$body" ]; then
        st_bad="$st_bad $fn(missing)"
    elif [ "$b_arg" -ne 1 ] || [ "$b_raw" -ne 0 ]; then
        st_bad="$st_bad $fn(store_arg=$b_arg,raw=$b_raw)"
    fi
done
# The chokepoint, in both directions: the resolving primitive is named exactly
# twice in the file (its definition and the ONE call inside store_arg), and
# store_arg is named exactly 10 times (its definition + the 9 sites above).
st_raw_total=$(grep -c 'get_store_why(' "$STORE_C" || true)
st_arg_total=$(grep -c 'store_arg(' "$STORE_C" || true)
STORE_RAW_DECLARED=2
STORE_ARG_DECLARED=10
if [ -z "$st_bad" ] && [ "$st_examined" -eq "$STORE_DECLARED" ] && [ "$st_examined" -gt 0 ] \
   && [ "$st_raw_total" -eq "$STORE_RAW_DECLARED" ] \
   && [ "$st_arg_total" -eq "$STORE_ARG_DECLARED" ]; then
    ok "construction_storeraise: all $STORE_DECLARED store builtins resolve through the raising wrapper (get_store_why has $st_raw_total names == declared)"
else
    fail "construction_storeraise: chokepoint" "bad:${st_bad:- none} examined=$st_examined/$STORE_DECLARED raw=$st_raw_total/$STORE_RAW_DECLARED arg=$st_arg_total/$STORE_ARG_DECLARED"
fi

# 7. ROUND 2 / G3: the same chokepoint for CHANNELS, plus the ONE declared
#    non-raising consumer. `channel_closed`'s documented ANSWER for an unknown
#    or reclaimed channel is 1 (#971 Phase D), so it is the single caller of
#    the non-raising form — named here, not left as a hole.
CHAN_SITES="builtin_send builtin_recv builtin_try_recv builtin_recv_timeout \
builtin_close_channel"
CHAN_DECLARED=5
ch_examined=0
ch_bad=""
for fn in $CHAN_SITES; do
    ch_examined=$((ch_examined + 1))
    body=$(fn_body "$BI_C" "$fn")
    b_arg=$(printf '%s\n' "$body" | grep -c 'channel_arg(' || true)
    if [ -z "$body" ]; then
        ch_bad="$ch_bad $fn(missing)"
    elif [ "$b_arg" -ne 1 ]; then
        ch_bad="$ch_bad $fn(channel_arg=$b_arg)"
    fi
done
ch_why_total=$(grep -c 'get_channel_why(' "$BI_C" || true)
ch_plain_total=$(grep -c 'get_channel(' "$BI_C" || true)
ch_arg_total=$(grep -c 'channel_arg(' "$BI_C" || true)
ch_closed_uses=$(printf '%s\n' "$(fn_body "$BI_C" "builtin_channel_closed")" \
                 | grep -c 'get_channel(arg)' || true)
CHAN_WHY_DECLARED=3      # definition + get_channel + channel_arg
CHAN_PLAIN_DECLARED=2    # definition + channel_closed, the declared ANSWER site
CHAN_ARG_DECLARED=6      # definition + the 5 sites above
if [ -z "$ch_bad" ] && [ "$ch_examined" -eq "$CHAN_DECLARED" ] && [ "$ch_examined" -gt 0 ] \
   && [ "$ch_why_total" -eq "$CHAN_WHY_DECLARED" ] \
   && [ "$ch_plain_total" -eq "$CHAN_PLAIN_DECLARED" ] \
   && [ "$ch_arg_total" -eq "$CHAN_ARG_DECLARED" ] \
   && [ "$ch_closed_uses" -eq 1 ]; then
    ok "construction_chanraise: all $CHAN_DECLARED channel builtins resolve through the raising wrapper; channel_closed is the 1 declared ANSWER site"
else
    fail "construction_chanraise: chokepoint" "bad:${ch_bad:- none} examined=$ch_examined/$CHAN_DECLARED why=$ch_why_total/$CHAN_WHY_DECLARED plain=$ch_plain_total/$CHAN_PLAIN_DECLARED arg=$ch_arg_total/$CHAN_ARG_DECLARED closed=$ch_closed_uses"
fi

# 8. ROUND 2 / G2: ONE formatter for the refusal, so the vocabulary cannot
#    drift between kinds. Pinned three ways: the formatter exists once, every
#    kind routes to it (found == declared), and the word "stale" appears in
#    exactly ONE rt_error in the whole tree — a second copy is how two
#    wordings for one condition start.
raise_def=$(grep -c '^void handle_raise_unresolved(' "$ES_C" || true)
raise_calls=$(grep -c 'handle_raise_unresolved(' "$BI_C" "$STORE_C" 2>/dev/null | awk -F: '{n+=$2} END{print n+0}')
RAISE_CALLS_DECLARED=3   # thread_join, channel_arg, store_arg
# The format STRING, not the rt_error line: the call spans several lines, so a
# line-anchored grep for `rt_error(.*stale` counts zero and the row would pass
# vacuously (caught here, on this row's first run).
stale_texts=$(grep -c '"%s: stale %s handle' "$SRC_DIR"/*.c 2>/dev/null | awk -F: '{n+=$2} END{print n+0}')
stale_any=$(grep -rc 'stale' "$SRC_DIR"/*.c 2>/dev/null | awk -F: '{n+=$2} END{print n+0}')
generic_chan=$(grep -c '": invalid channel"' "$BI_C" || true)
if [ "$raise_def" -eq 1 ] && [ "$raise_calls" -eq "$RAISE_CALLS_DECLARED" ] \
   && [ "$stale_texts" -eq 1 ] && [ "$stale_any" -gt 0 ] && [ "$generic_chan" -eq 0 ]; then
    ok "construction_reason: one refusal formatter, $raise_calls kinds routed to it, exactly $stale_texts diagnostic carrying \"stale\""
else
    fail "construction_reason: one-formatter" "def=$raise_def calls=$raise_calls/$RAISE_CALLS_DECLARED staletexts=$stale_texts staleany=$stale_any generic_channel_copies=$generic_chan"
fi

fi   # end of the live+construction rows

# ---- selftest -----------------------------------------------------------
selftest() {
    local st_pass=0 st_fail=0 examined=0
    # fixture : expected-to-compare-against : rc : EXACT set of names that fire
    # fixture : expected : rc : wantstale : EXACT set of names that must fire.
    # The three round-2 fixtures are captures of REAL binaries: the round-1 HEAD
    # (bad_store_silentnull), the round-1 wording (bad_chan_generic), and the
    # critic's surviving mutant (bad_chan_served).
    local CASES="bad_silentnull.cap:handles_join_twice.expected:0:0:exact+silentnull \
bad_aba.cap:handles_reuse.expected:0:0:exact+silentnull \
bad_silentfull.cap:handles_full.expected:0:0:exact \
bad_empty.cap:handles_join_twice.expected:0:0:nonempty+population+exact \
bad_modenv_short.cap:handles_modenv.expected:0:0:exact \
bad_modenv_crash.cap:handles_modenv.expected:139:0:exact+rc \
bad_store_silentnull.cap:handles_store_stale.expected:0:1:exact+silentnull \
bad_chan_generic.cap:handles_channel_stale.expected:0:1:exact+staleword \
bad_chan_served.cap:handles_channel_stale.expected:0:1:exact+staleword \
good_join_twice.cap:handles_join_twice.expected:0:0:"
    for c in $CASES; do
        local capf=${c%%:*}; local rest=${c#*:}
        local expf=${rest%%:*}; rest=${rest#*:}
        local rc=${rest%%:*}; rest=${rest#*:}
        local ws=${rest%%:*}; local want=${rest#*:}
        examined=$((examined + 1))
        if [ ! -f "$FIX_DIR/$capf" ]; then
            echo "  FAIL: selftest fixture missing: $capf"; st_fail=$((st_fail+1)); continue
        fi
        verify_capture "$FIX_DIR/$expf" "$FIX_DIR/$capf" "$rc" "$ws"
        local got="$VERIFY_FIRED"
        local want_sorted
        want_sorted=$(printf '%s\n' ${want//+/ } | grep -v '^$' | sort -u | paste -sd+ -)
        if [ "$got" = "$want_sorted" ]; then
            echo "  PASS: selftest $capf fired [${got:-none}]"; st_pass=$((st_pass+1))
        else
            echo "  FAIL: selftest $capf fired [${got:-none}], want [${want_sorted:-none}]"
            st_fail=$((st_fail+1))
        fi
    done
    # §121: the case table must have been walked in full and be non-empty.
    if [ "$examined" -eq 10 ] && [ "$examined" -gt 0 ]; then
        echo "  PASS: selftest cases examined == declared ($examined)"; st_pass=$((st_pass+1))
    else
        echo "  FAIL: selftest population: examined=$examined declared=10"; st_fail=$((st_fail+1))
    fi
    echo "HANDLES_MT_SELFTEST: $st_pass passed, $st_fail failed"
    [ "$st_fail" -eq 0 ]
    return $?
}

if [ "${1:-}" = "--selftest" ]; then
    selftest
    exit $?
fi

echo "HANDLES_MT: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
