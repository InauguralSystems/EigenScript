#!/bin/bash
# Per-round mutation train for the observer-arming-sets oracle (#1145).
#
# NOT wired into tests/run_all_tests.sh: it copies the tree, rebuilds `make`
# in a scratch dir under build/arming_mt_mutants/, and runs
# tests/test_arming_mt.sh against that binary. A gate that rebuilds does not
# belong in the incrementally-read suite runner.
#
# For each named mutant: apply it to a fresh copy, rebuild, run the live
# oracle ten times, and require a named FAIL line every time. Prints
#   MUTANT <name>: KILLED by <check>+<check> (10/10)
# or
#   MUTANT <name>: SURVIVED on run <i>
# and exits nonzero if any mutant survived.
#
# PER-MUTANT ACCOUNTING — which lane actually sees each one (§21/§42).
# "structural" means a construction row in tests/test_arming_mt.sh; the
# behavioural column is what would go red if every construction row were
# deleted (§100).
#
#   mutant                     structural row               behavioural lane
#   -------------------------  ---------------------------  -------------------------
#   fix-reverted               construction_unconditional   two-state harness (release)
#   occ-tier-not-widened       construction_armlocked       two-state harness (release),
#                                                           INTERMITTENT — it named the
#                                                           kill in one train run and not
#                                                           the next, which is why the
#                                                           structural row is the gate
#   two-state-guard-removed    construction_unconditional   arming_mt_occ/hist/st AND
#                                                           the two-state harness
#   reader-lock-removed        construction_armlocked       NONE on this box*
#   hist-writer-unlocked       NONE                         tsan:two-state
#   reader-lock-deadcoded      construction_?? — see below  tsan:two-state
#
#   `reader-lock-deadcoded` is the one that proves the point: the reader's
#   lock is still THERE, wrapped in `if (0)`. Every textual row passes, and
#   the release lane is green. Only the runtime witness separates presence
#   from execution — which is why no row in tests/test_arming_mt.sh tries to
#   become execution-aware by getting cleverer about grep.
#
#   * `reader-lock-removed` is a critic's round-1 mutant: it deletes the
#     lock/unlock pair inside `arm_set_has` — the READER, the site the whole
#     guard exists for — and leaves every other site locked. Against the OLD
#     file-wide floor row (`arm_lock` call sites >= 6) it took the count
#     7 -> 6 and SURVIVED 10/10, with `ARMING_MT: 9 passed, 0 failed` every
#     run: the release oracle never reaches the interleaving, and a floor
#     derived from the mechanism it guards cannot tell a missing lock from a
#     missing line (§122/§43). The row is now PER SITE with found ==
#     declared, and names the site it caught.
#
# Removing a mutex reinstates a real use-after-free, but whether a release
# run on this box OBSERVES it depends on a realloc landing inside another
# thread's strcmp — so the release oracle is not the kill for those, the
# construction rows are, and the HARM is gated separately by
# tests/test_tsan.sh (arming_mt_occ and the two-state C row, which reported
# 6/14/9 warnings on the pre-#1145 tree).
#
# The ORACLE here is the LIVE arm only (§21). The selftest is gated by suite
# section [42k], which pins both totals.
#
# --selftest applies tests/arming_mt_mutants/comment-only-equivalent.sed and
# requires SURVIVED + nonzero exit, and oracle-abort.sed requiring
# KILLED-by-crash.
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MUTDIR="$ROOT/tests/arming_mt_mutants"
SCRATCH_ROOT="$ROOT/build/arming_mt_mutants"

MUTANTS='
fix-reverted
occ-tier-not-widened
two-state-guard-removed
reader-lock-removed
reader-lock-deadcoded
hist-writer-unlocked
'


# ---- ThreadSanitizer-lane witnesses (#1145 round 3) ---------------------
#
# A grep proves PRESENCE, not EXECUTION. A critic dead-coded this guard's
# READER as `if (0) { arm_lock(); }`: the per-site textual row found the text
# and the release lane was green 10/10. So EVERY lock-site mutant here
# declares a runtime witness — the two-state harness under ThreadSanitizer,
# which is the shape with no `spawn` where the per-state flags are all 0 —
# and the train prints BOTH lanes, saying STRUCTURAL-ONLY out loud when the
# TSan lane did not fire (mechanical-gates §21).
#
#   mutant                     tsan witness   MEASURED result
#   -------------------------  -------------  ------------------------------
#   fix-reverted               two-state      3/3  (release lane also kills)
#   occ-tier-not-widened       two-state      3/3  (release lane also kills)
#   reader-lock-removed        two-state      3/3  (release lane also kills)
#   reader-lock-deadcoded      two-state      3/3  — AND the release lane
#                                             SURVIVED 0/10. This is the
#                                             mutant the column exists for.
#   hist-writer-unlocked       two-state      3/3  (the per-site row now
#                                             catches it too, see below)
#
#   `reader-lock-deadcoded` is a critic's oracle-breaker: the reader's lock
#   is still THERE, wrapped in `if (0)`. Every textual row passes and the
#   release oracle is green 10/10 — measured, not predicted. Only the
#   runtime witness separates PRESENCE from EXECUTION, which is why no row
#   in tests/test_arming_mt.sh tries to become execution-aware by getting
#   cleverer about grep: that road has no end.
#
#   `hist-writer-unlocked` was TSan-only in the previous round. It is not any
#   more, and the reason is the per-site rewrite: `construction_armlocked`
#   now checks `trace_arm_history_name`'s OWN body for its hold, and that is
#   exactly what this mutant strips. A row that got stricter turned a
#   sanitizer-only defect into a release-lane one.
#
#   `two-state-guard-removed` declares NO TSan witness on purpose: its
#   runtime witness is the two-state harness on the RELEASE lane, where it
#   fails the harness's own conserved-quantity assertions (plus all three
#   .eigs rows). A sanitizer run would add a slower copy of a kill already
#   in hand.
TSAN_WITNESS_MUTANTS='
fix-reverted two-state
occ-tier-not-widened two-state
reader-lock-removed two-state
reader-lock-deadcoded two-state
hist-writer-unlocked two-state
'

# Per-mutant TSan run bound. `hist-writer-unlocked` LIVELOCKS the harness
# (the unguarded realloc leaves the arming set in a state the other state
# spins on), and waiting out a 600 s default cost 24 minutes of train time
# for information the first 60 s already carried: past 60 s with no exit IS
# the kill. Everything else keeps the default.
tsan_run_timeout_for() {
    case "$1" in
        hist-writer-unlocked) echo "${MUTANT_TSAN_TIMEOUT_LIVELOCK:-60}" ;;
        *)                    echo "${MUTANT_TSAN_TIMEOUT:-600}" ;;
    esac
}

tsan_witness_for() {
    printf '%s\n' "$TSAN_WITNESS_MUTANTS" | awk -v m="$1" '$1 == m { print $2; exit }'
}

# Build the TSan variant in the mutant tree, link the two-state harness
# against its objects, and run it three times. Echoes the number of runs that
# reported at least one warning (or died / timed out — a livelock is evidence
# too, and its reason is printed by the caller).
run_tsan_witness() {   # $1 = dest tree, $2 = mutant, $3 = witness stem
    local dest="$1" spec="$2" stem="$3"
    if ! make -C "$dest" tsan >"$SCRATCH_ROOT/$spec.tsanbuild.log" 2>&1; then
        echo 0
        return 0
    fi
    local objs bin bound hits=0 i out rc w
    objs=$(ls "$dest"/build/tsan/*.o 2>/dev/null | grep -v '/main.o$' || true)
    bin="$dest/build/tsan/test_arming_two_states"
    [ -n "$objs" ] || { echo 0; return 0; }
    [ -f "$dest/tests/test_arming_two_states.c" ] || { echo 0; return 0; }
    if ! gcc -Werror=switch -Werror=comment -Werror=misleading-indentation \
            -fsanitize=thread -g -O1 -o "$bin" \
            "$dest/tests/test_arming_two_states.c" $objs -lm -lpthread \
            -I"$dest/src" -I"$dest/build" >"$SCRATCH_ROOT/$spec.tsanlink.log" 2>&1; then
        echo 0
        return 0
    fi
    bound=$(tsan_run_timeout_for "$spec")
    for i in 1 2 3; do
        if [ -n "$TMO_CMD" ]; then
            out=$(TSAN_OPTIONS="halt_on_error=0 exitcode=0" "$TMO_CMD" "$bound" setarch -R "$bin" 2>&1)
        else
            out=$(TSAN_OPTIONS="halt_on_error=0 exitcode=0" setarch -R "$bin" 2>&1)
        fi
        rc=$?
        w=$(printf '%s\n' "$out" | grep -c "WARNING: ThreadSanitizer" || true)
        printf '%s\n' "$out" > "$SCRATCH_ROOT/$spec.tsan.$i.log"
        if [ "$w" -gt 0 ] || [ "$rc" -ne 0 ]; then hits=$((hits + 1)); fi
    done
    echo "$hits"
}

copy_tree() {
    local dest="$1"
    rm -rf "$dest"
    mkdir -p "$dest"
    rsync -a \
        --exclude '.git' \
        --exclude 'build' \
        --exclude '.build-evidence' \
        --exclude 'tests/__pycache__' \
        --exclude '.grok' \
        "$ROOT"/ "$dest"/
    mkdir -p "$dest/build/release"
    cp -a "$ROOT"/build/release/*.o "$ROOT"/build/release/*.d "$dest/build/release/" 2>/dev/null || true
}

apply_mutant() {
    local dest="$1" spec="$2"
    local patch="$MUTDIR/${spec}.patch"
    local sedf="$MUTDIR/${spec}.sed"
    if [ -f "$patch" ]; then
        ( cd "$dest" && patch -p1 --forward --batch < "$patch" >/dev/null )
    elif [ -f "$sedf" ]; then
        # Each mutant names the file it edits on line 1 as `# file: path`.
        local target
        target=$(sed -n 's/^# file: //p' "$sedf" | head -1)
        if [ -z "$target" ]; then
            echo "mutant $spec has no # file: header" >&2
            return 1
        fi
        sed -f "$sedf" "$dest/$target" > "$dest/$target.mut"
        mv "$dest/$target.mut" "$dest/$target"
        # An inert mutation reads as CAUGHT if anything else reds; require the
        # bytes to have actually moved (mechanical-gates §19/§82).
        if cmp -s "$ROOT/$target" "$dest/$target"; then
            echo "mutant $spec did not change $target" >&2
            return 1
        fi
    else
        echo "no mutant file for $spec" >&2
        return 1
    fi
}

# A crashed oracle (nonzero/signal, no FAIL line) is a KILL, not a SURVIVE.
# The oracle itself is BOUNDED, and rc 124 is a KILL with reason `hang` — a
# mutant that holds a lock across a return deadlocks the oracle instead of
# failing it, and would otherwise hang this train (see the loader train's
# note for the case that bought this).
ORACLE_TIMEOUT=${MUTANT_ORACLE_TIMEOUT:-600}
TMO_CMD=""
if command -v timeout >/dev/null 2>&1; then TMO_CMD="timeout"
elif command -v gtimeout >/dev/null 2>&1; then TMO_CMD="gtimeout"; fi

run_oracle() {
    local dest="$1" log="$2"
    local rc=0
    if [ -n "$TMO_CMD" ]; then
        "$TMO_CMD" "$ORACLE_TIMEOUT" bash "$dest/tests/test_arming_mt.sh" >"$log" 2>&1 || rc=$?
    else
        bash "$dest/tests/test_arming_mt.sh" >"$log" 2>&1 || rc=$?
    fi
    echo "$rc"
}

# EVERY distinct named FAIL, not just the first. A mutant is often killed by
# more than one row, and reporting only the earliest one hides the rest —
# which reads as "the dedicated row does not catch this" (mechanical-gates
# §21). Derived from the log, so it cannot drift from the checks.
fail_checks() {
    # LC_ALL=C is load-bearing: a killed run's FAIL detail quotes the freed
    # KEY BYTES, which are not valid UTF-8, and in a UTF-8 locale GNU sed's
    # `.` will not match them — the trailing `.*` then stops at the first bad
    # byte, the substitution keeps the unmatched tail, and the check NAME
    # comes back with binary glued to it. Bytes are bytes here.
    LC_ALL=C sed -n 's/^  FAIL: \([^:]*\):.*/\1/p' "$1" | sort -u | paste -sd+ -
}

classify_kill() {
    local log="$1" rc="$2"
    local killed
    killed="$(fail_checks "$log")"
    if [ -n "$killed" ]; then
        echo "$killed"
        return 0
    fi
    if [ "$rc" -eq 124 ]; then
        echo "hang(no exit in ${ORACLE_TIMEOUT}s)"
        return 0
    fi
    if [ "$rc" -ne 0 ]; then
        echo "crash(rc=$rc)"
        return 0
    fi
    echo ""
    return 1
}

# §19: an unstartable mutant is an invalid probe and must be reported BROKEN,
# not as a survivor. The only reading that can mean "the oracle ran and found
# nothing" is one that carries the oracle's own completion marker with a
# non-zero pass count; a silent rc-0 log is a harness fault.
oracle_completed() {
    local log="$1"
    local n
    n=$(sed -n 's/^ARMING_MT: \([0-9][0-9]*\) passed.*/\1/p' "$log" | tail -1)
    [ -n "$n" ] && [ "$n" -gt 0 ]
}

build_dest() {
    local dest="$1"
    rm -f "$dest/src/eigenscript" "$dest/build/release/eigenscript"
    make -C "$dest" >/dev/null
}

run_one() {
    local spec="$1"
    local dest="$SCRATCH_ROOT/$spec"
    copy_tree "$dest"
    apply_mutant "$dest" "$spec"
    build_dest "$dest"
    local bin="$dest/src/eigenscript"
    if [ ! -x "$bin" ]; then
        echo "MUTANT $spec: SURVIVED (no binary)"
        return 1
    fi

    # ---- lane 1: the release oracle, ten times.
    # A survival here is NOT a verdict on its own any more: two enrolled
    # mutants are release-invisible by construction and carry a TSan witness
    # instead (see the header). So record the lane and keep going.
    local rel_k=0 reason="" i rc killed rel_broken=0 rel_survived=0
    for i in 1 2 3 4 5 6 7 8 9 10; do
        local log="$SCRATCH_ROOT/${spec}.$i.log"
        rc="$(run_oracle "$dest" "$log")"
        if killed="$(classify_kill "$log" "$rc")"; then
            rel_k=$((rel_k + 1))
            reason="$killed"
        elif ! oracle_completed "$log"; then
            echo "MUTANT $spec: BROKEN on run $i — oracle rc=$rc with no FAIL line and no completion marker"
            return 1
        else
            rel_survived=1
            break
        fi
    done
    [ "$rel_broken" -eq 0 ] || return 1

    # ---- lane 2: the runtime witness, when one is declared.
    local stem tsan_hits=0
    stem=$(tsan_witness_for "$spec")
    if [ -n "$stem" ]; then
        tsan_hits=$(run_tsan_witness "$dest" "$spec" "$stem")
    fi

    # ---- verdict, naming BOTH lanes (mechanical-gates §21).
    local rel_note tsan_note
    if [ "$rel_survived" -eq 0 ]; then
        rel_note="$reason ($rel_k/10)"
    else
        rel_note="release lane SURVIVED ($rel_k/10 before run $i)"
    fi
    if [ -z "$stem" ]; then
        tsan_note="[no tsan witness declared — see the header]"
    elif [ "$tsan_hits" -ge 3 ]; then
        tsan_note="tsan:$stem (3/3)"
    else
        tsan_note="tsan:$stem $tsan_hits/3 — STRUCTURAL-ONLY on that lane"
    fi
    if [ "$rel_survived" -eq 0 ] || [ "$tsan_hits" -ge 3 ]; then
        echo "MUTANT $spec: KILLED by $rel_note + $tsan_note"
        return 0
    fi
    echo "MUTANT $spec: SURVIVED — $rel_note + $tsan_note"
    return 1
}

selftest() {
    # Abort-control: a mutant that crashes the oracle must be KILLED-by-crash,
    # not silently reported as a survivor (mechanical-gates §18).
    local spec=oracle-abort
    local dest="$SCRATCH_ROOT/$spec"
    local log="$SCRATCH_ROOT/$spec.log"
    copy_tree "$dest"
    apply_mutant "$dest" "$spec"
    build_dest "$dest"
    local rc killed
    rc="$(run_oracle "$dest" "$log")"
    killed="$(classify_kill "$log" "$rc" || true)"
    case "$killed" in
        crash\(rc=*)
            echo "MUTANT $spec: KILLED by $killed"
            ;;
        *)
            echo "SELFTEST FAILED: oracle-abort was not KILLED-by-crash (got '${killed:-SURVIVED}' rc=$rc)"
            exit 2
            ;;
    esac

    spec=comment-only-equivalent
    dest="$SCRATCH_ROOT/$spec"
    log="$SCRATCH_ROOT/$spec.log"
    copy_tree "$dest"
    apply_mutant "$dest" "$spec"
    build_dest "$dest"
    rc="$(run_oracle "$dest" "$log")"
    if killed="$(classify_kill "$log" "$rc")"; then
        echo "SELFTEST FAILED: comment-only mutant was KILLED by $killed (must SURVIVE)"
        exit 2
    fi
    if ! oracle_completed "$log"; then
        echo "SELFTEST FAILED: comment-only mutant's oracle never completed — a silent"
        echo "  pass is not a survivor (§19: an unstartable mutant is BROKEN, not CAUGHT)"
        exit 2
    fi
    echo "MUTANT $spec: SURVIVED (oracle completed, no FAIL line)"
    echo "ARMING_MT_MUTANTS_SELFTEST: comment-only equivalent SURVIVED as required"
    exit 1
}

mkdir -p "$SCRATCH_ROOT"

if [ "${1:-}" = "--selftest" ]; then
    selftest
    exit $?
fi

if [ "${1:-}" != "" ]; then
    echo "usage: $0 [--selftest]" >&2
    exit 2
fi

# Membership in BOTH directions (mechanical-gates §2): a mutant file with no
# train entry never runs, and a train entry with no file is a phantom. The
# two control mutants are excluded by name and by reason — comment-only must
# SURVIVE and oracle-abort must crash, so neither belongs in the kill loop.
disk=$(cd "$MUTDIR" && ls *.patch *.sed 2>/dev/null | sed 's/\.\(patch\|sed\)$//' | grep -vE '^(comment-only-equivalent|oracle-abort)$' | sort)
train=$(printf '%s\n' $MUTANTS | grep -v '^$' | sort)
if [ "$disk" != "$train" ]; then
    echo "mutant list does not match $MUTDIR (minus the two controls):" >&2
    echo "disk:" >&2; echo "$disk" >&2
    echo "train:" >&2; echo "$train" >&2
    exit 2
fi
n_disk=$(printf '%s\n' "$disk" | grep -c .)
if [ "$n_disk" -eq 0 ]; then
    echo "mutant directory empty after excluding the controls" >&2
    exit 2
fi

missing=0
for spec in $MUTANTS; do
    if [ ! -f "$MUTDIR/${spec}.patch" ] && [ ! -f "$MUTDIR/${spec}.sed" ]; then
        echo "missing mutant file: $spec" >&2
        missing=1
    fi
done
if [ "$missing" -ne 0 ]; then
    exit 2
fi

fail=0
examined=0
for spec in $MUTANTS; do
    run_one "$spec" || fail=1
    examined=$((examined + 1))
done
# §121: "some mutant ran" is vacuous — the loop must have covered the table.
if [ "$examined" -ne "$n_disk" ] || [ "$examined" -eq 0 ]; then
    echo "examined $examined of $n_disk mutant files" >&2
    exit 1
fi
if [ "$fail" -ne 0 ]; then
    echo "ARMING_MT_MUTANTS: survivors remain"
    exit 1
fi
echo "ARMING_MT_MUTANTS: all killed ($examined/$n_disk)"
exit 0
