#!/bin/bash
# Per-round mutation train for the thread-handle + module-env oracle
# (#1146, #1161).
#
# NOT wired into tests/run_all_tests.sh: it copies the tree, rebuilds `make`
# in a scratch dir under build/handles_mt_mutants/, and runs
# tests/test_handles_mt.sh against that binary. A gate that rebuilds does not
# belong in the incrementally-read suite runner.
#
# For each named behavioural mutant: apply it to a fresh copy, rebuild, run
# the live oracle ten times, and require a named FAIL line every time. Prints
#   MUTANT <name>: KILLED by <check>+<check> (10/10) + <tsan note>
# or
#   MUTANT <name>: SURVIVED ...
# and exits nonzero if any mutant survived.
#
# ROUND 2 enrolled two more, both from blind critics who EXECUTED the gap:
# `store-get-null-on-stale` (the generation check fires and store_get swallows
# the NULL back into a silent null) and `channel-gen-ignored` (the critic's own
# mutant, which SURVIVED round 1 10/10).
#
# THE HANG IS THE KILL. Two of the enrolled mutants do not produce a wrong
# answer at all — they produce a process that never returns (two joiners, one
# pthread_join). So the oracle is BOUNDED and rc 124 is a KILL with reason
# `hang` (mechanical-gates §136); waiting out a livelock N times is not a
# gate, it is a stalled CI job.
#
# PER-MUTANT ACCOUNTING — which lane actually sees each one, stated rather
# than left to the word "KILLED" (§21). "structural" means a grep-shaped
# construction row in tests/test_handles_mt.sh; the behavioural column is the
# lane that would go red if every construction row were deleted (§100).
#
#   mutant                      structural row          behavioural lane
#   --------------------------  ----------------------  -----------------------
#   claim-step-removed          construction_claim      handles_double_join HUNG
#   lock-released-before-join   construction_claim      handles_double_join HUNG
#   generation-ignored          NONE*                   handles_reuse
#   full-table-returns-null     NONE**                  handles_full
#   modenv-predicate-reverted   construction_modenv     handles_modenv (SIGSEGV)
#   mirror-lock-removed         construction_mirror     tsan:hm_modenv
#   store-get-null-on-stale     construction_storeraise handles_store_stale     (round 2)
#   channel-gen-ignored         NONE***                 handles_channel_stale   (round 2)
#
# *** channel-gen-ignored is a BLIND CRITIC'S OWN mutant, enrolled because it
#     SURVIVED the round-1 oracle 10/10 — that is the whole reason it is here.
#     No construction row can see it: the generation compare lives inside
#     handle_lookup, and a grep for `sl->gen != gen` is one text trick away from
#     useless (§135). The live row is the witness, and it is the row that did
#     not exist in round 1.
#
#   * The construction rows check the CALL SITES present a generation, not
#     that handle_claim compares it — deliberately: comparing it is what the
#     live ABA row witnesses, and a grep for `sl->gen != gen` would be one
#     more text trick away from useless (§135).
#  ** construction_full greps for `rt_error(EK_LIMIT` inside each registration
#     site; this mutant leaves that text in place behind `if (0)`, which is
#     exactly the dead-coding trick §135 says a grep always loses to. The
#     behavioural row is the witness, and saying so is the point of the column.
#
# The three lock-site mutants each carry a RUNTIME witness as well as (or
# instead of) a structural row, because a grep proves PRESENCE, never
# EXECUTION. For the two claim mutants that witness is the CLOCK; for
# mirror-lock-removed it is ThreadSanitizer.
#
# The ORACLE here is the LIVE arm only. --selftest runs against frozen
# captures and never touches the binary, so including it would add rows no
# mutant can move.
#
# --selftest applies tests/handles_mt_mutants/comment-only-equivalent.sed (a
# comment edit, behaviour-preserving) and requires this script to report
# SURVIVED and exit nonzero — proving the train can express a survivor — and
# oracle-abort.sed, requiring KILLED-by-crash.
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MUTDIR="$ROOT/tests/handles_mt_mutants"
SCRATCH_ROOT="$ROOT/build/handles_mt_mutants"

MUTANTS='
claim-step-removed
lock-released-before-join
generation-ignored
full-table-returns-null
modenv-predicate-reverted
mirror-lock-removed
store-get-null-on-stale
channel-gen-ignored
'

# ---- ThreadSanitizer-lane witnesses -------------------------------------
#
#   mutant                 tsan fixture   MEASURED result (see the report)
#   ---------------------  -------------  -------------------------------
#   mirror-lock-removed    hm_modenv      see the run; the release lane on
#                                         this mutant is the one that may be
#                                         quiet, because losing the mirror
#                                         lock corrupts a dict only when two
#                                         workers land inside the same few
#                                         instructions.
TSAN_WITNESS_MUTANTS='
mirror-lock-removed hm_modenv
'

tsan_fixture_path() {   # $1 = fixture stem -> path relative to the tree
    case "$1" in
        hm_modenv) echo "tests/handles_mt_modules/hm_modenv.eigs" ;;
        *)         echo "tests/$1.eigs" ;;
    esac
}

tsan_witness_for() {
    printf '%s\n' "$TSAN_WITNESS_MUTANTS" | awk -v m="$1" '$1 == m { print $2; exit }'
}

# Per-mutant TSan run bound. A livelocked harness past this is the kill.
tsan_run_timeout_for() {
    case "$1" in
        *) echo "${MUTANT_TSAN_TIMEOUT:-600}" ;;
    esac
}

ORACLE_TIMEOUT=${MUTANT_ORACLE_TIMEOUT:-900}
TMO_CMD=""
if command -v timeout >/dev/null 2>&1; then TMO_CMD="timeout"
elif command -v gtimeout >/dev/null 2>&1; then TMO_CMD="gtimeout"; fi

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
        # `rc=0; out=$(...) || rc=$?` — NOT `out=$(...)` then a bare `$?` on a
        # later line, and not `|| true` either: the first form is what carries
        # the substitution's status out, and `|| true` would swallow it.
        rc=0
        if [ -n "$TMO_CMD" ]; then
            out=$(cd "$dest/src" && TSAN_OPTIONS="halt_on_error=0 exitcode=0" \
                  "$TMO_CMD" "$bound" setarch -R ./eigenscript "$dest/$fixture" 2>&1) || rc=$?
        else
            out=$(cd "$dest/src" && TSAN_OPTIONS="halt_on_error=0 exitcode=0" \
                  setarch -R ./eigenscript "$dest/$fixture" 2>&1) || rc=$?
        fi
        w=$(printf '%s\n' "$out" | grep -c "WARNING: ThreadSanitizer" || true)
        printf '%s\n' "$out" > "$SCRATCH_ROOT/$spec.tsan.$i.log"
        if [ "$w" -gt 0 ] || [ "$rc" -ne 0 ]; then hits=$((hits + 1)); fi
    done
    echo "$hits"
    # The TSan build re-points dest/src/eigenscript at the sanitizer binary;
    # put the release one back so a later release run measures what it says.
    make -C "$dest" >/dev/null 2>&1 || true
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

# The oracle's OWN per-row bound is generous (120 s) because CI runners vary.
# The train does not need that: a livelock past a short bound IS the kill, and
# waiting the full budget x 10 runs x 2 hang-shaped mutants is 40 minutes of
# sitting on a defect we already know about (mechanical-gates §136). 20 s is
# ~90x the slowest release row on this box (handles_reuse, 0.22 s).
ROW_TIMEOUT_FOR_TRAIN=${MUTANT_ROW_TIMEOUT:-20}

run_oracle() {
    local dest="$1" log="$2"
    local rc=0
    if [ -n "$TMO_CMD" ]; then
        EIGS_MT_ROW_TIMEOUT="$ROW_TIMEOUT_FOR_TRAIN" \
            "$TMO_CMD" "$ORACLE_TIMEOUT" bash "$dest/tests/test_handles_mt.sh" >"$log" 2>&1 || rc=$?
    else
        EIGS_MT_ROW_TIMEOUT="$ROW_TIMEOUT_FOR_TRAIN" \
            bash "$dest/tests/test_handles_mt.sh" >"$log" 2>&1 || rc=$?
    fi
    echo "$rc"
}

# EVERY distinct named FAIL, not just the first: a mutant is often killed by
# more than one row, and reporting only the earliest hides the rest — which
# reads as "the dedicated row does not catch this" (§21).
fail_checks() {
    # LC_ALL=C is load-bearing: a killed run's FAIL detail can quote bytes
    # that are not valid UTF-8, and in a UTF-8 locale GNU sed's `.` will not
    # match them — the check NAME then comes back with binary glued to it.
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
# non-zero pass count.
oracle_completed() {
    local log="$1"
    local n
    n=$(sed -n 's/^HANDLES_MT: \([0-9][0-9]*\) passed.*/\1/p' "$log" | tail -1)
    [ -n "$n" ] && [ "$n" -gt 0 ]
}

# ROUND 2: KEEP THE BUILD LOG, and report a build failure as BROKEN.
# `make -C "$dest" >/dev/null` threw the compiler's diagnostics away, and the
# caller then saw only a missing binary and printed
# "MUTANT <name>: SURVIVED (no binary)" — which is the §19 misreading this
# train's own header warns about, said out loud by the train itself. It cost a
# whole train run: `lock-released-before-join` still called the 3-argument
# handle_lookup after round 2 gave it a 4th parameter, and the run reported a
# SURVIVOR instead of a broken probe. An unbuildable mutant is neither caught
# nor survived; it is an invalid experiment and must say so, with the log.
build_dest() {
    local dest="$1" spec="${2:-build}"
    rm -f "$dest/src/eigenscript" "$dest/build/release/eigenscript"
    make -C "$dest" >"$SCRATCH_ROOT/$spec.build.log" 2>&1
}

run_one() {
    local spec="$1"
    local dest="$SCRATCH_ROOT/$spec"
    copy_tree "$dest"
    apply_mutant "$dest" "$spec"
    local build_rc=0
    build_dest "$dest" "$spec" || build_rc=$?
    local bin="$dest/src/eigenscript"
    if [ "$build_rc" -ne 0 ] || [ ! -x "$bin" ]; then
        echo "MUTANT $spec: BROKEN — the mutant tree does not build (make rc=$build_rc);"
        echo "  this is an INVALID probe, not a survivor and not a kill. First error:"
        grep -m2 -E 'error:|Error [0-9]' "$SCRATCH_ROOT/$spec.build.log" 2>/dev/null | sed 's/^/    /'
        return 1
    fi

    # ---- lane 1: the release oracle, ten times.
    local rel_k=0 reason="" i rc killed rel_survived=0
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

    # ---- lane 2: the runtime witness, when one is declared.
    local stem tsan_hits=0
    stem=$(tsan_witness_for "$spec")
    if [ -n "$stem" ]; then
        tsan_hits=$(run_tsan_witness "$dest" "$spec" "$stem")
    fi

    # ---- verdict, naming BOTH lanes (§21).
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
    # not silently reported as a survivor (§18).
    local spec=oracle-abort
    local dest="$SCRATCH_ROOT/$spec"
    local log="$SCRATCH_ROOT/$spec.log"
    copy_tree "$dest"
    apply_mutant "$dest" "$spec"
    build_dest "$dest" "$spec"
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
    build_dest "$dest" "$spec"
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
    echo "HANDLES_MT_MUTANTS_SELFTEST: comment-only equivalent SURVIVED as required"
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

# Membership in BOTH directions (§2): a mutant file with no train entry never
# runs, and a train entry with no file is a phantom. The two control mutants
# are excluded by name and by reason — comment-only must SURVIVE and
# oracle-abort must crash, so neither belongs in the kill loop.
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
    echo "HANDLES_MT_MUTANTS: survivors remain"
    exit 1
fi
echo "HANDLES_MT_MUTANTS: all killed ($examined/$n_disk)"
exit 0
