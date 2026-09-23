#!/bin/bash
# #1144: `load_file` / `import` from a spawned worker.
#
# Probe-gated. Cwd is src/ when the suite invokes this (tests/run_all_tests.sh
# does `cd .../src`), so every path here is derived from $0 and absolute.
# Prints PASS:/FAIL: lines. Exit 0 iff FAIL=0. The suite pins BOTH totals.
#
# Two kinds of row, with different blind spots (mechanical-gates §51):
#
#   LIVE rows run a probe and compare its capture against a HAND-WRITTEN
#   expected file — never against the binary's own output (§4). Every pinned
#   number is a CONSERVED quantity (§131): a count of loads that returned, a
#   sum that does not depend on interleaving. Measured discriminating against
#   the pre-fix tree (a6333bb): loader_mt_loadfile's shape exits 1 with
#   "load_file: circular dependency — '...' is already being loaded" and a
#   null worker result (and SIGSEGV on 1 of 3 runs), which is the `falsecycle`
#   and `exact` checks; loader_mt_cycle is GREEN on both trees and is the
#   vacuity control (§23) — without it "no false circular dependency" is
#   satisfied by deleting the #496 guard outright.
#
#   CONSTRUCTION rows pin the SHAPE of the fix in src/. They exist for the
#   properties no release run on this box can witness: that the in-flight
#   load stack is per-THREAD, that the module cache is under its mutex, and
#   that the `M.field` read path takes NO lock (a lock there would be
#   invisible to every correctness row and would only show as T3 time).
#   Residual (§6): these are TEXT checks over C source — they pin the shape,
#   not the atomicity of pthread_mutex_lock, and a second module table added
#   under a different name is outside their population.
#
# --selftest drives the SAME verify_capture() the live rows drive (§99) with
# captures taken from a real pre-fix binary, plus a zero-population capture,
# plus a positive control that must stay GREEN. Each fixture pins the EXACT
# SET of check names that fire, not a count — that is what witnesses each
# individual check (§16, §38): delete `falsecycle` and the pre-fix fixture's
# set changes; delete `exact` and the wrong-sum fixture goes green.
set -u

TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC_DIR="$(cd "$TESTS_DIR/../src" && pwd)"
EIGS="$SRC_DIR/eigenscript"
FIX_DIR="$TESTS_DIR/loader_mt_fixtures"
MOD_DIR="$TESTS_DIR/loader_mt_modules"

PASS=0
FAIL=0
TMPDIR=$(mktemp -d -t eigs_loader_mt.XXXXXX)
trap 'rm -rf "$TMPDIR"' EXIT

ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
# The trailing colon is load-bearing: tools/mutants.sh loader_mt derives WHICH
# check killed a mutant with `s/^  FAIL: \([^:]*\):.*/\1/`, so a row whose
# name is not colon-terminated is invisible in the kill reason (§21). Every
# row name above is therefore a single token before its first colon.
fail() { echo "  FAIL: $1${2:+: ($2)}"; FAIL=$((FAIL+1)); }

# ---- the gate -----------------------------------------------------------
#
# Sets VERIFY_FIRED to a "+"-joined, sorted list of the CHECK NAMES that fired
# (empty = the capture is good). Deliberately NOT echo-and-capture: `v=$(fn)`
# runs fn in a subshell and the caller never sees the global (the same trap
# tests/test_tsan.sh records for tsan_warnings).
#
# Checks, and what each one ALONE can see:
#   rc          the probe exited nonzero — the pre-fix false-cycle raise
#   nonempty    the capture has no bytes at all
#   population  the capture's line count differs from the expected file's, or
#               either is 0 (§121: a row that examined nothing is a FAIL)
#   falsecycle  the capture says "circular dependency" where the expectation
#               does not — the release-binary witness for #1144, and the one
#               check that needs no expected file
#   sanitizer   an ASan/TSan/UBSan diagnostic rode along in the capture
#   exact       the capture differs from the hand-written expected file
VERIFY_FIRED=""
verify_capture() {   # verify_capture <expected_file> <actual_file> <rc>
    local expected=$1 actual=$2 rc=$3
    local fired=""
    [ "$rc" -eq 0 ] || fired="$fired rc"
    if [ ! -s "$actual" ]; then
        fired="$fired nonempty"
    fi
    local a_lines e_lines
    # awk, not `grep -c .`: grep exits 1 on an empty file and `|| echo 0`
    # then yields TWO words, which makes the [ -ne ] below a syntax error and
    # the population check silently unevaluated (§7 shell mechanics).
    a_lines=$(awk 'NF{n++} END{print n+0}' "$actual" 2>/dev/null)
    e_lines=$(awk 'NF{n++} END{print n+0}' "$expected" 2>/dev/null)
    if [ "$a_lines" -ne "$e_lines" ] || [ "$a_lines" -eq 0 ]; then
        fired="$fired population"
    fi
    if grep -q 'circular dependency' "$actual" && \
       ! grep -q 'circular dependency' "$expected"; then
        fired="$fired falsecycle"
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

# ---- LIVE rows ----------------------------------------------------------
if [ "$SELFTEST_ONLY" -eq 0 ]; then
#
# DECLARED, not globbed: a missing probe is a FAIL, never a silent shrink
# (§121). Column 2 is the probe path relative to tests/.
PROBES="loader_mt_loadfile:loader_mt_loadfile.eigs \
loader_mt_import:loader_mt_import.eigs \
loader_mt_nsread:loader_mt_modules/lm_nsread.eigs \
loader_mt_cycle:loader_mt_cycle.eigs \
loader_mt_outlive:loader_mt_outlive.eigs \
loader_mt_same_import:loader_mt_modules/lm_same_import.eigs"
PROBES_DECLARED=6
EXAMINED=0

for entry in $PROBES; do
    name=${entry%%:*}
    rel=${entry#*:}
    EXAMINED=$((EXAMINED + 1))
    probe="$TESTS_DIR/$rel"
    exp="$FIX_DIR/$name.expected"
    if [ ! -f "$probe" ]; then fail "$name" "probe missing: $probe"; continue; fi
    if [ ! -f "$exp" ];   then fail "$name" "expected missing: $exp";  continue; fi
    out="$TMPDIR/$name.out"
    run_bounded "$out" "$EIGS" "$probe"
    rc=$RUN_RC
    if [ "$rc" -eq 124 ] && [ "$RUN_BOUNDED" -eq 1 ]; then
        # Not verify_capture's business: a hung run's capture is truncated,
        # so `rc`+`exact` would fire and bury the real reason.
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

# ---- CONSTRUCTION rows --------------------------------------------------
ES_C="$SRC_DIR/eigenscript.c"
ES_H="$SRC_DIR/eigenscript.h"
VM_C="$SRC_DIR/vm.c"

# A shared helper: the body of function $2 in file $1, from its opening line
# to the first column-0 `}`. Every function checked below is written that way.
fn_body() {
    awk -v name="$2" '
        $0 ~ ("^[A-Za-z_].*[ *]" name "\\(") { f = 1 }
        f { print }
        f && /^\}$/ { exit }
    ' "$1"
}

# Rows 1, 2 and 5 pin PER SITE with an exact total, never a floor over a grep
# count. A sibling gate's file-wide floor (`arm_lock` sites >= 6) let a mutant
# that deleted the lock inside the READER survive 10/10 by taking the count
# 7 -> 6: a floor derived from the mechanism it guards cannot tell "one site
# lost its lock" from "the file has one fewer line" (mechanical-gates
# §122/§43). Enumerate the sites by NAME from the design, check each one, and
# assert found == declared in BOTH directions (§2) — an unlisted new site is
# a site nobody reviewed.

# 1. The in-flight load stack is per THREAD, at every site that touches it.
LOAD_STACK_SITES="eigs_loading_active eigs_loading_enter eigs_loading_leave"
LOAD_STACK_DECLARED=3
ls_examined=0
ls_bad=""
for fn in $LOAD_STACK_SITES; do
    ls_examined=$((ls_examined + 1))
    body=$(fn_body "$ES_C" "$fn")
    b_th=$(printf '%s\n' "$body" | grep -c 'th->loading_' || true)
    b_st=$(printf '%s\n' "$body" | grep -c 'st->loading_' || true)
    b_fresh=$(printf '%s\n' "$body" | grep -c '^    EigsThread \*th = eigs_current;$' || true)
    if [ -z "$body" ]; then
        ls_bad="$ls_bad $fn(missing)"
    elif [ "$b_th" -lt 1 ] || [ "$b_st" -ne 0 ] || [ "$b_fresh" -ne 1 ]; then
        ls_bad="$ls_bad $fn(th=$b_th,st=$b_st,fresh=$b_fresh)"
    fi
done
# ... and `th` is the CALLING thread, not a cached one. A static shadow
# (`static EigsThread *first; if (!first) first = eigs_current;`) restores the
# shared-stack behaviour while leaving every `th->` spelling in place, so the
# per-site presence check alone is not enough.
st_hits=$(grep -c 'st->loading_stack\|st->loading_count\|st->loading_cap' "$ES_C" || true)
# EXACT, not a floor: EigsThread declares the stack pointer and its two
# size_t fields and nothing else mentions the name in the header, so the
# declared value is 1 (the `char **loading_stack;` line). A floor here would
# stay green if the field were re-added to EigsState as well.
LOAD_STACK_HDR_DECLARED=1
hdr_hits=$(grep -c 'loading_stack' "$ES_H" || true)
st_hdr_hits=$(grep -c 'char \+\*\*loading_stack;' "$ES_H" || true)
th_cached=$(grep -c 'static EigsThread \*' "$ES_C" || true)
if [ -z "$ls_bad" ] && [ "$ls_examined" -eq "$LOAD_STACK_DECLARED" ] \
   && [ "$st_hits" -eq 0 ] && [ "$hdr_hits" -eq "$LOAD_STACK_HDR_DECLARED" ] \
   && [ "$st_hdr_hits" -eq "$LOAD_STACK_HDR_DECLARED" ] && [ "$th_cached" -eq 0 ]; then
    ok "construction_loadstack: all $LOAD_STACK_DECLARED sites read the CALLING thread's stack (found == declared)"
else
    fail "construction_loadstack: per-site" "bad:${ls_bad:- none} examined=$ls_examined/$LOAD_STACK_DECLARED st=$st_hits hdr=$hdr_hits/$LOAD_STACK_HDR_DECLARED decl=$st_hdr_hits cached=$th_cached"
fi

# 2. Every module-cache entry point takes st->module_lock, per site, and the
#    file-wide total equals the declared site count.
MODCACHE_SITES="eigs_module_cache_get eigs_module_cache_put eigs_module_cache_clear"
MODCACHE_DECLARED=3
mc_examined=0
mc_bad=""
for fn in $MODCACHE_SITES; do
    mc_examined=$((mc_examined + 1))
    body=$(fn_body "$ES_C" "$fn")
    b_l=$(printf '%s\n' "$body" | grep -c 'pthread_mutex_lock(&st->module_lock)' || true)
    b_u=$(printf '%s\n' "$body" | grep -c 'pthread_mutex_unlock(&st->module_lock)' || true)
    # EXACT per site, in both directions. `put` has two exits under the lock
    # (the lost-race return and the tail) and so declares 2; the others
    # declare 1. A floor (`unlock >= lock`) let a critic's mutant delete the
    # unlock from `put`'s lost-race exit and stay green — the row counted
    # unlocks per FUNCTION, not per EXIT PATH. The exact count catches THAT
    # deletion; a lock held across a return that the count still balances is
    # caught by the row bound above (rc 124 -> HUNG), because text cannot
    # witness execution.
    case "$fn" in
        eigs_module_cache_put) b_u_want=2 ;;
        *)                     b_u_want=1 ;;
    esac
    if [ -z "$body" ]; then
        mc_bad="$mc_bad $fn(missing)"
    elif [ "$b_l" -ne 1 ] || [ "$b_u" -ne "$b_u_want" ]; then
        mc_bad="$mc_bad $fn(lock=$b_l,unlock=$b_u/want$b_u_want)"
    fi
done
mc_lock=$(grep -c 'pthread_mutex_lock(&st->module_lock)' "$ES_C" || true)
mc_unlock=$(grep -c 'pthread_mutex_unlock(&st->module_lock)' "$ES_C" || true)
MODCACHE_UNLOCK_DECLARED=4      # get 1 + put 2 (two exits) + clear 1
if [ -z "$mc_bad" ] && [ "$mc_examined" -eq "$MODCACHE_DECLARED" ] \
   && [ "$mc_lock" -eq "$MODCACHE_DECLARED" ] \
   && [ "$mc_unlock" -eq "$MODCACHE_UNLOCK_DECLARED" ]; then
    ok "construction_modcache: all $MODCACHE_DECLARED entry points hold st->module_lock ($mc_lock lock/$mc_unlock unlock)"
else
    fail "construction_modcache: per-site" "bad:${mc_bad:- none} examined=$mc_examined/$MODCACHE_DECLARED lock=$mc_lock/$MODCACHE_DECLARED unlock=$mc_unlock/$MODCACHE_UNLOCK_DECLARED"
fi

# 3. The `M.field` READ path takes no lock in either mode. A lock here is
#    invisible to every correctness row above and shows up only as T3 time,
#    so it is pinned structurally: the body of eigs_module_ns_env between its
#    signature and the closing brace must contain no mutex call.
ns_body=$(awk '/^Env \*eigs_module_ns_env\(Value \*dict\) \{/{f=1} f{print} f&&/^\}/{exit}' "$ES_C")
ns_lines=$(printf '%s\n' "$ns_body" | grep -c . || true)
ns_locks=$(printf '%s\n' "$ns_body" | grep -c 'pthread_mutex_lock\|env_shared_lock' || true)
if [ "$ns_lines" -gt 0 ] && [ "$ns_locks" -eq 0 ]; then
    ok "construction_nsread: eigs_module_ns_env is lock-free ($ns_lines lines, 0 mutex calls)"
else
    fail "construction_nsread: lock-free" "lines=$ns_lines locks=$ns_locks"
fi

# 4. The module-env `env->count` read at vm_execute's slot-promotion guard
#    goes through the #607 lock, and the retired-table publication is atomic.
vm_cnt=$(grep -c 'env_count_shared(env)' "$VM_C" || true)
ns_pub=$(grep -c '__atomic_store_n(&g_module_ns_pub' "$ES_C" || true)
if [ "$vm_cnt" -eq 1 ] && [ "$ns_pub" -eq 1 ]; then
    ok "construction_count: env->count under the lock; ns table published atomically"
else
    fail "construction_count: count/publish" "env_count_shared=$vm_cnt atomic_publish=$ns_pub"
fi

# 5. The module-namespace WRITERS serialize on their own mutex — per site,
#    with an exact total. No release run on this box can witness this
#    (removing it loses or duplicates an entry under a scheduler window, it
#    does not produce a wrong answer on demand), so it is pinned
#    structurally — same reasoning as the intern-not-under-lock row in
#    tests/test_dict_keys_mt.sh.
NSWRITE_SITES="eigs_module_ns_attach eigs_module_ns_detach"
NSWRITE_DECLARED=2
nw_examined=0
nw_bad=""
for fn in $NSWRITE_SITES; do
    nw_examined=$((nw_examined + 1))
    body=$(fn_body "$ES_C" "$fn")
    b_l=$(printf '%s\n' "$body" | grep -c 'pthread_mutex_lock(&g_module_ns_mu)' || true)
    b_u=$(printf '%s\n' "$body" | grep -c 'pthread_mutex_unlock(&g_module_ns_mu)' || true)
    # Exact per site: `attach` has two exits under the lock (the
    # already-a-namespace early return and the tail), `detach` one.
    case "$fn" in
        eigs_module_ns_attach) b_u_want=2 ;;
        *)                     b_u_want=1 ;;
    esac
    if [ -z "$body" ]; then
        nw_bad="$nw_bad $fn(missing)"
    elif [ "$b_l" -ne 1 ] || [ "$b_u" -ne "$b_u_want" ]; then
        nw_bad="$nw_bad $fn(lock=$b_l,unlock=$b_u/want$b_u_want)"
    fi
done
ns_lock=$(grep -c 'pthread_mutex_lock(&g_module_ns_mu)' "$ES_C" || true)
ns_unlock=$(grep -c 'pthread_mutex_unlock(&g_module_ns_mu)' "$ES_C" || true)
NSWRITE_UNLOCK_DECLARED=3       # attach 2 (two exits) + detach 1
if [ -z "$nw_bad" ] && [ "$nw_examined" -eq "$NSWRITE_DECLARED" ] \
   && [ "$ns_lock" -eq "$NSWRITE_DECLARED" ] \
   && [ "$ns_unlock" -eq "$NSWRITE_UNLOCK_DECLARED" ]; then
    ok "construction_nswrite: both ns writers hold g_module_ns_mu ($ns_lock lock/$ns_unlock unlock)"
else
    fail "construction_nswrite: per-site" "bad:${nw_bad:- none} examined=$nw_examined/$NSWRITE_DECLARED lock=$ns_lock/$NSWRITE_DECLARED unlock=$ns_unlock/$NSWRITE_UNLOCK_DECLARED"
fi

# 6. The retire/drain decision asks the PROCESS-wide question, not the
#    per-STATE `multithreaded` flag. That flag is 0 on every thread of a
#    two-state embed host (#915), so a narrower spelling would free a table
#    a sibling state is still probing — invisible to every row above.
mt_fn=$(fn_body "$ES_C" "module_ns_mt")
mt_proc=$(printf '%s
' "$mt_fn" | grep -c 'eigs_process_thread_count' || true)
mt_state=$(printf '%s
' "$mt_fn" | grep -c 'multithreaded' || true)
if [ "$mt_proc" -eq 1 ] && [ "$mt_state" -eq 1 ]; then
    ok "construction_nsmt: module_ns_mt asks the process question"
else
    fail "construction_nsmt: predicate" "thread_count=$mt_proc state_flag=$mt_state"
fi

# 7. A binding NAME created while the process is multithreaded is re-homed
#    into the process-global intern table AT INSERTION. This is the #1141
#    rule on the loader's write path: without it the name stays in the
#    WRITING thread's table, which eigs_thread_detach frees, and the shared
#    root env is left holding a dangling pointer.
#    Structural on purpose. The release binary usually gets away with the
#    use-after-free — glibc leaves a small freed block's bytes intact, so the
#    strcmp still matches: the `fix-reverted` mutant kills only 7/10 through
#    loader_mt_loadfile, and a 7/10 kill is not a gate (§131). The DECISION
#    is gated here; the HARM is gated by the ASAN lane, where the same revert
#    reports heap-use-after-free READ in strcmp <- env_hash_find <-
#    env_set_local_pre_interned_slot <- builtin_load_file <- thread_entry,
#    freed by the sibling worker in env_intern_table_unref.
rehome=$(awk '/^void env_set_local_pre_interned_slot/{f=1} f{print} f&&/^\}$/{exit}' "$ES_C" \
         | grep -c 'shared_intern_key(interned)' || true)
if [ "$rehome" -eq 1 ]; then
    ok "construction_rehome: binding name re-homed at insertion"
else
    fail "construction_rehome: re-home" "shared_intern_key(interned)=$rehome"
fi

# 8. A LOST module-cache put adopts the winner's instance. Structural as
#    well as behavioural because the loss is a race: the release row above
#    (loader_mt_same_import) reds on the defect every run today, but nothing
#    guarantees the scheduler keeps obliging, and the property is a two-line
#    control-flow shape that a refactor can drop silently.
put_rc=$(grep -c 'if (!eigs_module_cache_put(abs_path, mod_dict, mod_env))' "$VM_C" || true)
put_adopt=$(grep -c 'eigs_module_cache_get(abs_path, &winner)' "$VM_C" || true)
put_sig=$(grep -c '^int  eigs_module_cache_put' "$ES_H" || true)
if [ "$put_rc" -eq 1 ] && [ "$put_adopt" -eq 1 ] && [ "$put_sig" -eq 1 ]; then
    ok "construction_lostput: a lost cache put adopts the winner's module instance"
else
    fail "construction_lostput: lost-put adoption" "branch=$put_rc adopt=$put_adopt decl=$put_sig"
fi

fi   # end of the live+construction rows

# ---- selftest -----------------------------------------------------------
selftest() {
    local st_pass=0 st_fail=0 examined=0
    # fixture : expected-to-compare-against : rc : EXACT set of names that must fire
    local CASES="bad_falsecycle.cap:loader_mt_loadfile.expected:1:exact+falsecycle+population+rc \
bad_wrongsum.cap:loader_mt_nsread.expected:0:exact \
bad_empty.cap:loader_mt_loadfile.expected:0:nonempty+population+exact \
bad_outlive_undef.cap:loader_mt_outlive.expected:1:exact+rc+population \
good_loadfile.cap:loader_mt_loadfile.expected:0:"
    for c in $CASES; do
        local capf=${c%%:*}; local rest=${c#*:}
        local expf=${rest%%:*}; rest=${rest#*:}
        local rc=${rest%%:*}; local want=${rest#*:}
        examined=$((examined + 1))
        if [ ! -f "$FIX_DIR/$capf" ]; then
            echo "  FAIL: selftest fixture missing: $capf"; st_fail=$((st_fail+1)); continue
        fi
        verify_capture "$FIX_DIR/$expf" "$FIX_DIR/$capf" "$rc"
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
    if [ "$examined" -eq 5 ] && [ "$examined" -gt 0 ]; then
        echo "  PASS: selftest cases examined == declared ($examined)"; st_pass=$((st_pass+1))
    else
        echo "  FAIL: selftest population: examined=$examined declared=5"; st_fail=$((st_fail+1))
    fi
    echo "LOADER_MT_SELFTEST: $st_pass passed, $st_fail failed"
    [ "$st_fail" -eq 0 ]
    return $?
}

if [ "${1:-}" = "--selftest" ]; then
    selftest
    exit $?
fi

echo "LOADER_MT: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
