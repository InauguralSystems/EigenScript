#!/bin/bash
# Per-round mutation train for the loader-under-concurrency oracle (#1144).
#
# NOT wired into tests/run_all_tests.sh: it copies the tree, rebuilds `make`
# in a scratch dir under build/loader_mt_mutants/, and runs
# tests/test_loader_mt.sh against that binary. A gate that rebuilds does not
# belong in the incrementally-read suite runner.
#
# For each named behavioural mutant: apply it to a fresh copy, rebuild, run
# the live oracle ten times, and require a named FAIL line every time. Prints
#   MUTANT <name>: KILLED by <check>+<check> (10/10)
# or
#   MUTANT <name>: SURVIVED on run <i>
# and exits nonzero if any mutant survived.
#
# PER-MUTANT ACCOUNTING — which lane actually sees each one, stated rather
# than left to the word "KILLED" (mechanical-gates §21/§42). "structural"
# means a grep-shaped construction row in tests/test_loader_mt.sh; the
# behavioural column is the lane that would go red if every construction row
# were deleted, which is the transverse question (§100).
#
#   mutant                        structural row        behavioural lane
#   ----------------------------  --------------------  ------------------------
#   fix-reverted                  construction_rehome   ASan lane 5/5 (below)
#   loading-stack-shared-again    construction_loadstack loader_mt_loadfile 10/10
#   lost-put-pushes-private       construction_lostput  loader_mt_same_import
#   lock-removed                  construction_modcache NONE on this box*
#   ns-rebuild-unlocked           construction_nswrite  NONE on this box*
#   mt-flag-ignored               construction_nsmt     NONE by definition**
#   ns-retire-frees-immediately   NONE                  tsan:lm_nsread
#   put-lostrace-no-unlock        construction_modcache HANG — the oracle's bounded
#                                 (exact per-exit       rows return rc 124 and print
#                                  unlock count)        `HUNG`, on loader_mt_import and
#                                                       loader_mt_same_import. Before the
#                                                       bound this mutant did not FAIL the
#                                                       oracle, it STOPPED it: only the
#                                                       first PASS line ever printed and
#                                                       CI would have sat until the job
#                                                       timeout.
#
#   * Removing the module-cache mutex or the module-namespace writer mutex
#     LOSES or DUPLICATES an entry under a scheduler window. It does not
#     produce a wrong answer on demand: the cache is a linear scan that falls
#     back to re-loading, and the namespace falls back to the dict's own
#     entry. There is no output a release run can be reliably wrong about,
#     and a kill that depended on two workers colliding inside a few
#     instructions would be luck, not a gate (§131). The class is closed BY
#     CONSTRUCTION — one lock, one unlock per exit, checked PER SITE with
#     found == declared — and those rows fail on these mutants
#     deterministically.
#   `fix-reverted` is the one whose behavioural witness is a SANITIZER lane
#   rather than this train's release lane, and that was measured, not
#   assumed. On the RELEASE binary it is 0/10 behaviourally: glibc leaves a
#   small freed block's bytes intact, so the strcmp against the dead intern
#   table still matches and no value comes out wrong. Built with `make asan`
#   in the mutant tree and run against the same oracle it is 5/5, through the
#   `sanitizer` check on BOTH loader_mt_loadfile and loader_mt_same_import:
#     FAIL: loader_mt_loadfile: (exact+population+rc+sanitizer)
#     FAIL: loader_mt_same_import: (exact+population+rc+sanitizer)
#   The suite runs that lane (`make asan && ASAN_OPTIONS=detect_leaks=1`), so
#   the harm is gated there and the DECISION is gated here.
#
#  ** Narrowing the retire/drain predicate to the per-STATE `multithreaded`
#     flag is invisible to a single-state run by definition (that flag is
#     correct there); its harm is a two-state embed host freeing a table a
#     sibling is probing.
#
# The construction rows are PER-SITE with exact totals, not floors over a
# grep count. A sibling gate's file-wide floor let a mutant that removed the
# lock from the one site the guard exists for survive 10/10 by taking the
# count 7 -> 6 (§122/§43); every row here now enumerates its sites by name
# and asserts found == declared in both directions.
#
# The ORACLE here is the LIVE arm only. --selftest runs against frozen
# captures and never touches the binary, so including it would add rows no
# mutant can move and would let a kill be attributed to a check the mutant
# did not reach (§21). The selftest is gated by suite section [42j], which
# pins both totals.
#
# --selftest applies tests/loader_mt_mutants/comment-only-equivalent.sed (a
# comment edit, behaviour-preserving) and requires this script to report
# SURVIVED and exit nonzero — proving the train can express a survivor — and
# oracle-abort.sed, requiring KILLED-by-crash.
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MUTDIR="$ROOT/tests/loader_mt_mutants"
SCRATCH_ROOT="$ROOT/build/loader_mt_mutants"

MUTANTS='
fix-reverted
loading-stack-shared-again
lock-removed
ns-rebuild-unlocked
mt-flag-ignored
lost-put-pushes-private
ns-retire-frees-immediately
put-lostrace-no-unlock
'


tsan_fixture_path() {   # $1 = fixture stem -> path relative to the tree
    case "$1" in
        lm_nsread) echo "tests/loader_mt_modules/lm_nsread.eigs" ;;
        *)         echo "tests/$1.eigs" ;;
    esac
}

# ---- ThreadSanitizer-lane witnesses (#1144 round 3) ---------------------
#
# A grep proves PRESENCE, not EXECUTION: a critic dead-coded a lock as
# `if (0) { arm_lock(); }` and every per-site textual row still passed. So
# every LOCK-SITE mutant declares a runtime witness here in addition to its
# construction row, and the train prints the result of BOTH lanes — including
# when the TSan lane did not fire, which is reported as STRUCTURAL-ONLY
# rather than left to the word "KILLED" (mechanical-gates §21).
#
#   mutant                        tsan fixture   MEASURED result
#   ----------------------------  -------------  --------------------------------
#   lock-removed                  lm_same_import 0/3 — STRUCTURAL-ONLY
#   ns-rebuild-unlocked           lm_nsread      0/3 — STRUCTURAL-ONLY
#   ns-retire-frees-immediately   lm_nsread      3/3 (and the release lane 0/10)
#
# The first two are recorded as measured, not as intended. Dropping a mutex
# around the module cache or the namespace writers loses or duplicates an
# ENTRY; on these fixtures the two threads do not in fact overlap inside
# those few instructions, so ThreadSanitizer has nothing to report and the
# construction row is the only witness. Saying "STRUCTURAL-ONLY on that lane"
# out loud is the point of the column (§21) — widening a fixture until a race
# happens to land would be a kill by luck, which is exactly what §131
# forbids.
#
# `put-lostrace-no-unlock` deliberately declares NO TSan witness: its defect
# is a DEADLOCK, so its runtime witness is the clock (the bounded rows inside
# the oracle, and this train's bounded run_oracle), not a race report. Under
# TSan it would simply hang more slowly.
TSAN_WITNESS_MUTANTS='
lock-removed lm_same_import
ns-rebuild-unlocked lm_nsread
ns-retire-frees-immediately lm_nsread
'

# Per-mutant TSan run bound. A livelocked harness past this is the kill; there
# is no reason to wait out a long default.
tsan_run_timeout_for() {
    case "$1" in
        *) echo "${MUTANT_TSAN_TIMEOUT:-600}" ;;
    esac
}

tsan_witness_for() {
    printf '%s\n' "$TSAN_WITNESS_MUTANTS" | awk -v m="$1" '$1 == m { print $2; exit }'
}

# Build the TSan variant in the mutant tree and run the witness fixture three
# times. Echoes the number of runs that reported at least one warning (or
# died / timed out, which is also evidence the mutant is not benign).
run_tsan_witness() {   # $1 = dest tree, $2 = mutant, $3 = fixture stem
    local dest="$1" spec="$2" stem="$3"
    if ! make -C "$dest" tsan >"$SCRATCH_ROOT/$spec.tsanbuild.log" 2>&1; then
        echo 0
        return 0
    fi
    local fixture bound hits=0 i out rc w
    fixture=$(tsan_fixture_path "$stem")
    bound=$(tsan_run_timeout_for "$spec")
    [ -f "$dest/$fixture" ] || { echo 0; return 0; }
    for i in 1 2 3; do
        if [ -n "$TMO_CMD" ]; then
            out=$(cd "$dest/src" && TSAN_OPTIONS="halt_on_error=0 exitcode=0" \
                  "$TMO_CMD" "$bound" setarch -R ./eigenscript "$dest/$fixture" 2>&1)
        else
            out=$(cd "$dest/src" && TSAN_OPTIONS="halt_on_error=0 exitcode=0" \
                  setarch -R ./eigenscript "$dest/$fixture" 2>&1)
        fi
        rc=$?
        w=$(printf '%s\n' "$out" | grep -c "WARNING: ThreadSanitizer" || true)
        printf '%s\n' "$out" > "$SCRATCH_ROOT/$spec.tsan.$i.log"
        if [ "$w" -gt 0 ] || [ "$rc" -ne 0 ]; then hits=$((hits + 1)); fi
    done
    echo "$hits"
}

tsan_fixture_path() {   # $1 = fixture stem -> path relative to the tree
    case "$1" in
        lm_nsread)       echo "tests/loader_mt_modules/lm_nsread.eigs" ;;
        lm_same_import)  echo "tests/loader_mt_modules/lm_same_import.eigs" ;;
        *)               echo "tests/$1.eigs" ;;
    esac
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
# The oracle itself is BOUNDED, and rc 124 is a KILL with reason `hang`.
# A critic's mutant dropped the unlock on one exit path of a locked function:
# every construction row passed (unlocks were counted per FUNCTION, not per
# EXIT PATH), the losing thread self-deadlocked, and the oracle NEVER
# RETURNED — so enrolling that mutant would have hung this train, and the
# suite section would have sat until the CI job timeout. The rows inside the
# oracle now carry their own bound too; this one catches a hang in the
# oracle's own shell. Text cannot witness execution (a dead-coded
# `if (0) { lock(); }` passes any grep); the clock can.
ORACLE_TIMEOUT=${MUTANT_ORACLE_TIMEOUT:-900}
TMO_CMD=""
if command -v timeout >/dev/null 2>&1; then TMO_CMD="timeout"
elif command -v gtimeout >/dev/null 2>&1; then TMO_CMD="gtimeout"; fi

run_oracle() {
    local dest="$1" log="$2"
    local rc=0
    if [ -n "$TMO_CMD" ]; then
        "$TMO_CMD" "$ORACLE_TIMEOUT" bash "$dest/tests/test_loader_mt.sh" >"$log" 2>&1 || rc=$?
    else
        bash "$dest/tests/test_loader_mt.sh" >"$log" 2>&1 || rc=$?
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
        # A deadlocked oracle prints nothing useful; the CLOCK is the witness.
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
    n=$(sed -n 's/^LOADER_MT: \([0-9][0-9]*\) passed.*/\1/p' "$log" | tail -1)
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
    echo "LOADER_MT_MUTANTS_SELFTEST: comment-only equivalent SURVIVED as required"
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
    echo "LOADER_MT_MUTANTS: survivors remain"
    exit 1
fi
echo "LOADER_MT_MUTANTS: all killed ($examined/$n_disk)"
exit 0
