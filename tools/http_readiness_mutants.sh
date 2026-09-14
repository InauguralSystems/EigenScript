#!/bin/bash
# Per-round mutation train for the HTTP readiness oracle (#1128/#1129/#1134).
#
# NOT wired into tests/run_all_tests.sh: it copies the tree, rebuilds
# `make http` in a scratch dir under build/http_readiness_mutants/, and
# runs tests/http_readiness.py against that binary. A builder round (or a
# human) runs it by hand. A gate that rebuilds does not belong in the
# incrementally-read suite runner.
#
# For each named behavioural mutant: apply it to a fresh copy, rebuild,
# run the live oracle, and require a named FAIL line. Prints
#   MUTANT <name>: KILLED by <check>
# or
#   MUTANT <name>: SURVIVED
# and exits nonzero if any mutant survived.
#
# --selftest applies tests/http_readiness_mutants/comment-only-equivalent.sed
# (a comment edit, behaviour-preserving) and requires this script to report
# SURVIVED and exit nonzero — proving the train can express a survivor.
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MUTDIR="$ROOT/tests/http_readiness_mutants"
SCRATCH_ROOT="$ROOT/build/http_readiness_mutants"
ORACLE="$ROOT/tests/http_readiness.py"

MUTANTS='
init-200-for-everything
liveness-any-path
header-omitted-on-static
header-omitted-on-options
header-omitted-on-global-cap
header-omitted-on-per-ip-cap
header-omitted-in-init-window
serial-init-responder
client-deadline-off
capacity-shed-off
teardown-drain-off
handoff-drain-off
validation-accepts-crlf
owned-name-accepted
name-check-colon-only
header-omitted-on-403
capacity-doubled
empty-value-rejected
serial-handling
shed-body-on-head
sigpipe-default-in-init
name-check-allows-delims
rejected-flag-ignored-by-early-bind
runtime-emitted-name-accepted
serving-shed-body
shed-write-blocking
init-reply-write-blocking
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
    mkdir -p "$dest/build/http"
    cp -a "$ROOT"/build/http/*.o "$ROOT"/build/http/*.d "$dest/build/http/" 2>/dev/null || true
}

apply_mutant() {
    local dest="$1" spec="$2"
    local patch="$MUTDIR/${spec}.patch"
    local sedf="$MUTDIR/${spec}.sed"
    if [ -f "$patch" ]; then
        # patch(1), not git apply: dest lives inside this worktree, and
        # git apply resolves paths against the repo root rather than cwd.
        ( cd "$dest" && patch -p1 --forward --batch < "$patch" >/dev/null )
    elif [ -f "$sedf" ]; then
        sed -f "$sedf" "$dest/src/ext_http.c" > "$dest/src/ext_http.c.mut"
        mv "$dest/src/ext_http.c.mut" "$dest/src/ext_http.c"
    else
        echo "no mutant file for $spec" >&2
        return 1
    fi
    if cmp -s "$ROOT/src/ext_http.c" "$dest/src/ext_http.c"; then
        echo "mutant $spec did not change src/ext_http.c" >&2
        return 1
    fi
}

run_oracle() {
    local bin="$1" log="$2"
    local rc=0
    EIGS_BIN="$bin" python3 "$ORACLE" >"$log" 2>&1 &
    local pid=$!
    local i=0
    while [ "$i" -lt 120 ]; do
        if ! kill -0 "$pid" 2>/dev/null; then
            wait "$pid" || rc=$?
            echo "$rc"
            return 0
        fi
        i=$((i + 1))
        sleep 1
    done
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    echo 124
}

first_fail() {
    # Named live check: "  FAIL: <name>: ..."
    sed -n 's/^  FAIL: \([^:]*\):.*/\1/p' "$1" | head -1
}

run_one() {
    local spec="$1"
    local dest="$SCRATCH_ROOT/$spec"
    local log="$SCRATCH_ROOT/$spec.log"
    copy_tree "$dest"
    apply_mutant "$dest" "$spec"
    rm -f "$dest/src/eigenscript" "$dest/build/http/eigenscript"
    make -C "$dest" http >/dev/null
    local bin="$dest/src/eigenscript"
    if [ ! -x "$bin" ]; then
        echo "MUTANT $spec: SURVIVED (no binary)"
        return 1
    fi
    local rc
    rc="$(run_oracle "$bin" "$log")"
    local killed
    killed="$(first_fail "$log")"
    if [ -n "$killed" ]; then
        echo "MUTANT $spec: KILLED by $killed"
        return 0
    fi
    echo "MUTANT $spec: SURVIVED (oracle rc=$rc, no FAIL line)"
    return 1
}

selftest() {
    local spec=comment-only-equivalent
    local dest="$SCRATCH_ROOT/$spec"
    local log="$SCRATCH_ROOT/$spec.log"
    copy_tree "$dest"
    apply_mutant "$dest" "$spec"
    make -C "$dest" http >/dev/null
    local rc
    rc="$(run_oracle "$dest/src/eigenscript" "$log")"
    local killed
    killed="$(first_fail "$log")"
    if [ -n "$killed" ]; then
        echo "SELFTEST FAILED: comment-only mutant was KILLED by $killed (must SURVIVE)"
        exit 2
    fi
    echo "MUTANT $spec: SURVIVED (oracle rc=$rc, no FAIL line)"
    echo "HTTP_READINESS_MUTANTS_SELFTEST: comment-only equivalent SURVIVED as required"
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

disk=$(cd "$MUTDIR" && ls *.patch *.sed | sed 's/\.\(patch\|sed\)$//' | grep -v '^comment-only-equivalent$' | sort)
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
    echo "HTTP_READINESS_MUTANTS: survivors remain"
    exit 1
fi
echo "HTTP_READINESS_MUTANTS: all killed ($examined/$n_disk)"
exit 0
