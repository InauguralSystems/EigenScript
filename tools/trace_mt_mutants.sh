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

# Combined oracle: test_trace_mt.sh then embed-concurrent. Named FAIL lines
# come from either. Residual: this train does not rebuild the TSan binary.
run_oracle() {
    local dest="$1" log="$2"
    local rc=0
    {
        bash "$dest/tests/test_trace_mt.sh" || true
        echo "---- embed-concurrent ----"
        if [ -x "$dest/src/embed_concurrent_bin" ]; then
            "$dest/src/embed_concurrent_bin" || true
        else
            echo "  FAIL: embed-concurrent: binary missing"
        fi
    } >"$log" 2>&1 || rc=$?
    echo "$rc"
}

first_fail() {
    sed -n 's/^  FAIL: \([^:]*\):.*/\1/p' "$1" | head -1
}

build_dest() {
    local dest="$1"
    rm -f "$dest/src/eigenscript" "$dest/build/release/eigenscript"
    make -C "$dest" >/dev/null
    # Link embed_concurrent against the dest objects (minus main.o) so the
    # mutant is in the artifact the oracle actually runs.
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
    local log="$SCRATCH_ROOT/$spec.log"
    copy_tree "$dest"
    apply_mutant "$dest" "$spec"
    build_dest "$dest"
    local bin="$dest/src/eigenscript"
    if [ ! -x "$bin" ]; then
        echo "MUTANT $spec: SURVIVED (no binary)"
        return 1
    fi
    run_oracle "$dest" "$log" >/dev/null
    local killed
    killed="$(first_fail "$log")"
    if [ -n "$killed" ]; then
        echo "MUTANT $spec: KILLED by $killed"
        return 0
    fi
    echo "MUTANT $spec: SURVIVED (no FAIL line)"
    return 1
}

selftest() {
    local spec=comment-only-equivalent
    local dest="$SCRATCH_ROOT/$spec"
    local log="$SCRATCH_ROOT/$spec.log"
    copy_tree "$dest"
    apply_mutant "$dest" "$spec"
    build_dest "$dest"
    run_oracle "$dest" "$log" >/dev/null
    local killed
    killed="$(first_fail "$log")"
    if [ -n "$killed" ]; then
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

disk=$(cd "$MUTDIR" && ls *.patch *.sed 2>/dev/null | sed 's/\.\(patch\|sed\)$//' | grep -v '^comment-only-equivalent$' | sort)
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
