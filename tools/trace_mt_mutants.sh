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
'

# Mutants whose kill is a data race: run their oracle under TSan objects.
TSAN_MUTANTS='
replay-take-unlocked
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
    if [ -d "$ROOT/build/tsan" ]; then
        mkdir -p "$dest/build/tsan"
        cp -a "$ROOT"/build/tsan/*.o "$ROOT"/build/tsan/*.d "$dest/build/tsan/" 2>/dev/null || true
    fi
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

# Combined oracle: test_trace_mt.sh then embed-concurrent.
# A crashed oracle (nonzero/signal, no FAIL line) is a KILL, not a SURVIVE.
is_tsan_mutant() {
    printf '%s\n' $TSAN_MUTANTS | grep -qx "$1"
}

run_oracle() {
    local dest="$1" log="$2" use_tsan="$3"
    local rc=0
    local tmt_rc=0 ec_rc=0
    (
        if [ "$use_tsan" = "1" ]; then
            # Skip test_trace_mt.sh under TSan: 2×2000 workers hang the
            # train. The TSan mutants are killed by the take-path race
            # in embed_concurrent. halt_on_error=1 so the first race
            # exits instead of spinning in an unlocked take that never
            # reaches EOF. EMBED_CONCURRENT_ONLY=replay-take skips the
            # thresh_worker compile_ast race (compiler.c) that would
            # otherwise fire first.
            export TSAN_OPTIONS="halt_on_error=1 exitcode=66"
            export EMBED_CONCURRENT_ONLY=replay-take
            echo "---- embed-concurrent (TSan, replay-take only) ----"
            if [ -x "$dest/src/embed_concurrent_bin" ]; then
                tmo=""
                if command -v timeout >/dev/null 2>&1; then tmo="timeout 60"; fi
                $tmo setarch -R "$dest/src/embed_concurrent_bin"
                ec_rc=$?
            else
                echo "  FAIL: embed-concurrent: binary missing"
                ec_rc=1
            fi
            exit "$ec_rc"
        else
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
        fi
    ) >"$log" 2>&1 || rc=$?
    echo "$rc"
}

first_fail() {
    sed -n 's/^  FAIL: \([^:]*\):.*/\1/p' "$1" | head -1
}

classify_kill() {
    local log="$1" rc="$2"
    local killed
    killed="$(first_fail "$log")"
    # Pre-existing races in compiler.c (verify_self) fire on any TSan
    # embed_concurrent run. A tape-MT mutant is killed by a sanitizer
    # report only when the report names src/trace.c.
    if grep -q 'src/trace.c' "$log" 2>/dev/null \
       && grep -qE 'WARNING: ThreadSanitizer|ERROR: AddressSanitizer|ERROR: ThreadSanitizer' "$log" 2>/dev/null; then
        echo "sanitizer"
        return 0
    fi
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
    local dest="$1" use_tsan="$2"
    if [ "$use_tsan" = "1" ]; then
        rm -f "$dest/src/eigenscript" "$dest/build/tsan/eigenscript"
        make -C "$dest" tsan >/dev/null
        local objs
        objs=$(ls "$dest"/build/tsan/*.o 2>/dev/null | grep -v '/main.o$' || true)
        gcc -fsanitize=thread -g -O1 -o "$dest/src/embed_concurrent_bin" \
            "$dest/src/embed_concurrent.c" $objs -lm -lpthread \
            -I"$dest/src" -I"$dest/build"
    else
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
    fi
}

run_one() {
    local spec="$1"
    local dest="$SCRATCH_ROOT/$spec"
    local use_tsan=0
    is_tsan_mutant "$spec" && use_tsan=1
    copy_tree "$dest"
    apply_mutant "$dest" "$spec"
    build_dest "$dest" "$use_tsan"
    local bin="$dest/src/eigenscript"
    if [ ! -x "$bin" ]; then
        echo "MUTANT $spec: SURVIVED (no binary)"
        return 1
    fi
    local k=0 reason="" i rc killed
    for i in 1 2 3; do
        local log="$SCRATCH_ROOT/${spec}.$i.log"
        rc="$(run_oracle "$dest" "$log" "$use_tsan")"
        if killed="$(classify_kill "$log" "$rc")"; then
            k=$((k + 1))
            reason="$killed"
        else
            echo "MUTANT $spec: SURVIVED on run $i (oracle rc=$rc, no FAIL line)"
            return 1
        fi
    done
    echo "MUTANT $spec: KILLED by $reason (3/3)"
    return 0
}

selftest() {
    # Abort-control: a mutant that crashes the oracle must be KILLED-by-crash.
    local spec=oracle-abort
    local dest="$SCRATCH_ROOT/$spec"
    local log="$SCRATCH_ROOT/$spec.log"
    copy_tree "$dest"
    apply_mutant "$dest" "$spec"
    build_dest "$dest" 0
    local rc
    rc="$(run_oracle "$dest" "$log" 0)"
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
    build_dest "$dest" 0
    rc="$(run_oracle "$dest" "$log" 0)"
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
