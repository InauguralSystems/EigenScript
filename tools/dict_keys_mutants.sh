#!/bin/bash
# Per-round mutation train for the dict-keys-across-threads oracle (#1141).
#
# NOT wired into tests/run_all_tests.sh: it copies the tree, rebuilds `make`
# in a scratch dir under build/dict_keys_mutants/, and runs
# tests/test_dict_keys_mt.sh against that binary. A gate that rebuilds does
# not belong in the incrementally-read suite runner.
#
# For each named behavioural mutant: apply it to a fresh copy, rebuild, run
# the live oracle ten times, and require a named FAIL line every time. Prints
#   MUTANT <name>: KILLED by <check>+<check> (10/10)
# or
#   MUTANT <name>: SURVIVED on run <i>
# and exits nonzero if any mutant survived.
#
# TWO enrolled mutants are killed by STRUCTURAL rows rather than by a wrong
# answer, and that is deliberate and stated rather than hidden:
#
#   intern-not-under-lock — removing the process-global table's mutex loses
#     and duplicates LIST NODES. It does not produce a wrong answer: every
#     lookup falls back to strcmp (env_hash_find) and nothing walks the
#     buckets outside the lock, so the damage is a leaked/duplicated entry.
#     There is no output a release run can be wrong about, and a kill that
#     depended on two workers colliding inside a few instructions would be
#     luck, not a gate. The class is closed BY CONSTRUCTION instead — one
#     lock, one unlock per exit, exactly one writer of the bucket array — and
#     the `construction:` rows in tests/test_dict_keys_mt.sh fail on the
#     mutant deterministically. Same shape, same reasoning as close-toctou in
#     tools/trace_mt_mutants.sh. A mutant with no behavioural kill and a
#     structural one is honest; a mutant with neither would be a survivor.
#
#   env-name-not-rehomed — narrowing the module-namespace guard leaves a real
#     heap-use-after-free (measured under ASan: module_ns_public <-
#     eigs_module_ns_sync <- builtin_keys, freed by the worker in
#     env_intern_table_unref) that the RELEASE binary does not surface:
#     `keys of M` reads the DICT's key array, which is re-homed either way, so
#     the stale env name is read and thrown away without reaching stdout.
#     Measured on the mutant build: dict_keys_mt_module printed the correct
#     keys 5 of 5 times. The HARM is gated by tests/test_tsan.sh (which runs
#     dict_keys_mt_module under the sanitizer on the real tree); the DECISION
#     is gated here, by the `construction: the binding-name guard is
#     env_mt_shared alone` row. This train stays on plain release builds on
#     purpose — a sanitizer build per mutant is minutes each, and the
#     trace_mt train retired its own sanitizer arm for the same reason.
#
# The ORACLE here is the LIVE arm only. --selftest runs against frozen
# captures and never touches the binary, so including it would add rows no
# mutant can move and would let a kill be attributed to a check the mutant
# did not reach (mechanical-gates §21). The selftest is gated by the suite
# section [42i], which pins both totals.
#
# --selftest applies tests/dict_keys_mutants/comment-only-equivalent.sed (a
# comment edit, behaviour-preserving) and requires this script to report
# SURVIVED and exit nonzero — proving the train can express a survivor — and
# oracle-abort.sed, requiring KILLED-by-crash.
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MUTDIR="$ROOT/tests/dict_keys_mutants"
SCRATCH_ROOT="$ROOT/build/dict_keys_mutants"

MUTANTS='
fix-reverted
mt-flag-ignored
env-name-not-rehomed
intern-not-under-lock
drain-frees-shared-keys
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
run_oracle() {
    local dest="$1" log="$2"
    local rc=0
    bash "$dest/tests/test_dict_keys_mt.sh" >"$log" 2>&1 || rc=$?
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
    n=$(sed -n 's/^DICT_KEYS_MT: \([0-9][0-9]*\) passed.*/\1/p' "$log" | tail -1)
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
    local k=0 reason="" i rc killed
    for i in 1 2 3 4 5 6 7 8 9 10; do
        local log="$SCRATCH_ROOT/${spec}.$i.log"
        rc="$(run_oracle "$dest" "$log")"
        if killed="$(classify_kill "$log" "$rc")"; then
            k=$((k + 1))
            reason="$killed"
        elif ! oracle_completed "$log"; then
            echo "MUTANT $spec: BROKEN on run $i — oracle rc=$rc with no FAIL line and no completion marker"
            return 1
        else
            echo "MUTANT $spec: SURVIVED on run $i (oracle rc=$rc, no FAIL line)"
            return 1
        fi
    done
    echo "MUTANT $spec: KILLED by $reason ($k/10)"
    return 0
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
    echo "DICT_KEYS_MUTANTS_SELFTEST: comment-only equivalent SURVIVED as required"
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
    if ! run_one "$spec"; then
        fail=1
    fi
    examined=$((examined + 1))
done
# §121: "some mutant ran" is vacuous — the loop must have covered the table.
if [ "$examined" -ne "$n_disk" ] || [ "$examined" -eq 0 ]; then
    echo "examined $examined of $n_disk mutant files" >&2
    exit 1
fi
if [ "$fail" -ne 0 ]; then
    echo "DICT_KEYS_MUTANTS: survivors remain"
    exit 1
fi
echo "DICT_KEYS_MUTANTS: all killed ($examined/$n_disk)"
exit 0
