#!/bin/bash
# Per-round mutation train for the tape-MT oracle (#1142/#1143).
#
# NOT wired into tests/run_all_tests.sh: it copies the tree, rebuilds
# `make` in a scratch dir under build/trace_mt_mutants/, and runs
# tests/test_trace_mt.sh plus a linked embed_concurrent against that
# binary. A gate that rebuilds does not belong in the incrementally-read
# suite runner.
#
# For each named behavioural mutant: apply it to a fresh copy, rebuild,
# run the live oracle, and require a named FAIL line. Prints
#   MUTANT <name>: KILLED by <check>
# or
#   MUTANT <name>: SURVIVED
# and exits nonzero if any mutant survived.
#
# TWO of the enrolled mutants are killed by STRUCTURAL rows in
# tests/test_trace_mt.sh rather than by torn tape bytes, and that is
# deliberate:
#
#   close-toctou — the #1143 decide-then-decrement window (read the live
#     state count, then release, decide on the stale read) is UNOBSERVABLE
#     from a harness on this box. Measured by the round-3 critic: killed
#     0/10 by this whole train and 0/2000 by a barrier'd double-close
#     stress, on the FIXED tree and on the planted bug ALIKE. So the class
#     is closed BY CONSTRUCTION — eigs_process_state_release() decides and
#     decrements in one step under g_attached_lock and hands back whether
#     the caller was last, so the bug cannot be written without ADDING a
#     count read — and the `close-count-toctou` rows in test_trace_mt.sh
#     fail on exactly that addition, 10/10. A mutant with no behavioural
#     kill and a structural one is honest; a mutant with neither would be
#     a survivor.
#
#   sink-flush-outside-lock — its behavioural kill depended on a ~100 ns
#     scheduler window (SURVIVED 3 of 10 train runs on this box). The sink
#     case in src/embed_concurrent.c now makes the property structural
#     instead: the sink callback fires under the tape mutex, so two sink
#     callbacks can never overlap, and a gated rendezvous in the callback
#     turns that into a deterministic verdict on any schedule.
#
#   replay-take-unlocked — round 5. Its kill used to be a ThreadSanitizer
#     report, which meant a TSan BUILD of the whole tree per train run and,
#     worse, a probabilistic verdict: a critic measured it SURVIVING 1 of 10
#     train runs. The property is not probabilistic — the take holds the same
#     mutex the emit path holds — so the `replay-take-lock` case in
#     src/embed_concurrent.c measures the property: a sink callback blocks
#     for a bounded window while the other thread attempts a take, and a take
#     that COMPLETES inside that window is an overlap. Measured on this box:
#     0 overlaps of 80 on this tree, 80 of 80 on the mutant, every run.
#     With that, no mutant here needs a sanitizer build, and the train's TSan
#     branch is gone with it (a build path no mutant exercises rots silently).
#     The TSan claim about the tape is gated where it belongs, by
#     tests/test_tsan.sh, which runs embed_concurrent under TSan on the real
#     tree and requires 0 src/trace.c reports.
#
# --selftest applies tests/trace_mt_mutants/comment-only-equivalent.sed
# (a comment edit, behaviour-preserving) and requires this script to report
# SURVIVED and exit nonzero — proving the train can express a survivor.
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MUTDIR="$ROOT/tests/trace_mt_mutants"
SCRATCH_ROOT="$ROOT/build/trace_mt_mutants"

MUTANTS='
tape-mutex-removed
sink-flush-outside-lock
replay-take-unlocked
ocfg-global-diff
close-shuts-tape-always
replay-worker-allowed
owner-state-bypass
hand-rolled-take-bypass
shutdown-outside-lock
close-never-shuts
sink-multi-record-call
close-toctou
sink-only-no-drop
set-sink-header-unlocked
'

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
        if cmp -s "$ROOT/$target" "$dest/$target"; then
            echo "mutant $spec did not change $target" >&2
            return 1
        fi
    else
        echo "no mutant file for $spec" >&2
        return 1
    fi
}

# Combined oracle: test_trace_mt.sh then embed-concurrent, both against the
# mutated tree's own release build. A crashed oracle (nonzero/signal, no FAIL
# line) is a KILL, not a SURVIVE.
#
# Round 5 removed the sanitizer arm of this function along with the last TSan
# mutant (see replay-take-unlocked above). It is not "temporarily unused": a
# build path no mutant drives is never run, so a break in it would be found
# by whoever next needed it, at the worst moment. tests/test_tsan.sh is where
# the tape's TSan claim is gated, on the real tree.
run_oracle() {
    local dest="$1" log="$2"
    local rc=0
    local tmt_rc=0 ec_rc=0
    (
        bash "$dest/tests/test_trace_mt.sh"
        tmt_rc=$?
        echo "---- embed-concurrent ----"
        if [ -x "$dest/src/embed_concurrent_bin" ]; then
            "$dest/src/embed_concurrent_bin"
            ec_rc=$?
        else
            echo "  FAIL: embed-concurrent: binary missing"
            ec_rc=1
        fi
        if [ "$tmt_rc" -ne 0 ]; then exit "$tmt_rc"; fi
        exit "$ec_rc"
    ) >"$log" 2>&1 || rc=$?
    echo "$rc"
}

# EVERY distinct named FAIL, not just the first. A mutant is often killed by
# more than one case, and reporting only the earliest one hides the rest —
# which reads as "the dedicated case does not catch this" (mechanical-gates
# §21: verify WHICH check caught the fault, and record it where the next
# reader looks). Derived from the log, so it cannot drift from the checks.
fail_checks() {
    sed -n 's/^  FAIL: \([^:]*\):.*/\1/p' "$1" | sort -u | paste -sd+ -
}

classify_kill() {
    local log="$1" rc="$2"
    local killed
    killed="$(fail_checks "$log")"
    # A sanitizer clause used to sit here for the TSan mutants. Round 5
    # retired the last of them (replay-take-unlocked is killed by a named
    # check now), and the oracle builds are plain release builds, so a
    # sanitizer report is no longer a verdict this train can reach. The
    # named FAIL below, and a crash, are.
    if [ -n "$killed" ]; then
        echo "$killed"
        return 0
    fi
    if [ "$rc" -ne 0 ]; then
        echo "crash(rc=$rc)"
        return 0
    fi
    echo ""
    return 1
}

build_dest() {
    local dest="$1"
    rm -f "$dest/src/eigenscript" "$dest/build/release/eigenscript"
    make -C "$dest" >/dev/null
    local objs
    objs=$(ls "$dest"/build/release/*.o 2>/dev/null | grep -v '/main.o$' || true)
    gcc -O2 -o "$dest/src/embed_concurrent_bin" \
        "$dest/src/embed_concurrent.c" $objs -lm -lpthread \
        -I"$dest/src" -I"$dest/build" >/dev/null 2>&1 || \
        gcc -O2 -o "$dest/src/embed_concurrent_bin" \
            "$dest/src/embed_concurrent.c" $objs -lm -lpthread \
            -I"$dest/src"
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
    local k=0 reason="" i rc killed
    for i in 1 2 3 4 5 6 7 8 9 10; do
        local log="$SCRATCH_ROOT/${spec}.$i.log"
        rc="$(run_oracle "$dest" "$log")"
        if killed="$(classify_kill "$log" "$rc")"; then
            k=$((k + 1))
            reason="$killed"
        else
            echo "MUTANT $spec: SURVIVED on run $i (oracle rc=$rc, no FAIL line)"
            return 1
        fi
    done
    echo "MUTANT $spec: KILLED by $reason (10/10)"
    return 0
}

selftest() {
    # Abort-control: a mutant that crashes the oracle must be KILLED-by-crash.
    local spec=oracle-abort
    local dest="$SCRATCH_ROOT/$spec"
    local log="$SCRATCH_ROOT/$spec.log"
    copy_tree "$dest"
    apply_mutant "$dest" "$spec"
    build_dest "$dest"
    local rc
    rc="$(run_oracle "$dest" "$log")"
    local killed
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
    echo "MUTANT $spec: SURVIVED (no FAIL line)"
    echo "TRACE_MT_MUTANTS_SELFTEST: comment-only equivalent SURVIVED as required"
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

disk=$(cd "$MUTDIR" && ls *.patch *.sed 2>/dev/null | sed 's/\.\(patch\|sed\)$//' | grep -vE '^(comment-only-equivalent|oracle-abort)$' | sort)
train=$(printf '%s\n' $MUTANTS | grep -v '^$' | sort)
if [ "$disk" != "$train" ]; then
    echo "mutant list does not match $MUTDIR (minus comment-only-equivalent):" >&2
    echo "disk:" >&2; echo "$disk" >&2
    echo "train:" >&2; echo "$train" >&2
    exit 2
fi
n_disk=$(printf '%s\n' "$disk" | grep -c .)
if [ "$n_disk" -eq 0 ]; then
    echo "mutant directory empty after excluding equivalent" >&2
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
    if ! run_one "$spec"; then
        fail=1
    fi
    examined=$((examined + 1))
done
if [ "$examined" -ne "$n_disk" ] || [ "$examined" -eq 0 ]; then
    echo "examined $examined of $n_disk mutant files" >&2
    exit 1
fi
if [ "$fail" -ne 0 ]; then
    echo "TRACE_MT_MUTANTS: survivors remain"
    exit 1
fi
echo "TRACE_MT_MUTANTS: all killed ($examined/$n_disk)"
exit 0
