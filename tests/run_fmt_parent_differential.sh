#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"
SELFTEST=0
if [ "${1:-}" = "--selftest" ]; then SELFTEST=1; PARENT=; else PARENT=${1:-}; fi
TEMP=
cleanup() { [ -z "$TEMP" ] || rm -rf "$TEMP"; }
trap cleanup EXIT
if [ -z "$PARENT" ]; then
    PARENT_REF=$(git -C "$ROOT" merge-base HEAD origin/main 2>/dev/null) || {
        echo "formatter differential: the parent commit is not in this clone; fetch history (cannot merge-base HEAD origin/main)" >&2
        exit 1
    }
    git -C "$ROOT" cat-file -e "$PARENT_REF^{commit}" 2>/dev/null || {
        echo "formatter differential: the parent commit is not in this clone; fetch history ($PARENT_REF)" >&2
        exit 1
    }
    TEMP=$(mktemp -d "$(dirname "$ROOT")/.eigs-fmt-parent-XXXXXX")
    git -C "$ROOT" archive "$PARENT_REF" | tar -x -C "$TEMP" || {
        echo "formatter differential: could not obtain incumbent $PARENT_REF" >&2
        exit 1
    }
    # This binary is a formatter oracle, not a performance result.  Avoid the
    # release build's expensive optimisation so the <=60s source-gate row
    # spends its budget comparing output rather than optimizing the VM/JIT.
    # Overriding CFLAGS replaces the Makefile's own, so carry the -Werror trio
    # from the incumbent's tools/werror_flags.txt (CI's cc-guard rejects a
    # compile without it) and size -j to the machine, not to a CI runner.
    werror=$(cat "$TEMP/tools/werror_flags.txt") && [ -n "$werror" ] || {
        echo "formatter differential: incumbent $PARENT_REF has no tools/werror_flags.txt" >&2
        exit 1
    }
    make -C "$TEMP" -j"$(nproc 2>/dev/null || echo 2)" \
        CFLAGS="-Wall -Wextra -Werror=implicit-function-declaration $werror -O0 -fPIE" >/dev/null || {
        echo "formatter differential: could not build incumbent $PARENT_REF" >&2
        exit 1
    }
    PARENT="$TEMP/src/eigenscript"
fi
python3 tests/fmt_parent_differential.py "$PARENT" "$ROOT/src/eigenscript" "$ROOT"

if [ "$SELFTEST" -eq 1 ]; then
    if FMT_DIFFERENTIAL_PLANT_NORMALIZATION=1 FMT_DIFFERENTIAL_PROBE_ONLY=1 \
        python3 tests/fmt_parent_differential.py "$PARENT" "$ROOT/src/eigenscript" "$ROOT" >/dev/null 2>&1; then
        echo "FAIL: formatter differential missed normalization regression" >&2
        exit 1
    fi
    echo "formatter differential selftest: live comparison passed; normalization plant caught"
fi
