#!/usr/bin/env bash
set -u

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
fail=0

make -C "$ROOT" SIGPIPE_VARIANT=release sigpipe-contract-test >/dev/null || exit 1
if "$ROOT/build/release/test_sigpipe_contract" proc; then
    echo "PASS: proc_spawn preserves the host SIGPIPE handler"
else
    echo "FAIL: proc_spawn changed the host SIGPIPE handler"; fail=1
fi

make -C "$ROOT" build/http/eigenscript SIGPIPE_VARIANT=http sigpipe-contract-test >/dev/null || exit 1
for mode in early serve; do
    if "$ROOT/build/http/test_sigpipe_contract" "$mode" >/dev/null; then
        echo "PASS: http_$mode preserves the host SIGPIPE handler"
    else
        echo "FAIL: http_$mode changed the host SIGPIPE handler"; fail=1
    fi
done

repro=$(mktemp "${TMPDIR:-/tmp}/eigs-sigpipe.XXXXXX") || exit 1
trap 'rm -f "$repro"' EXIT HUP INT TERM
cat >"$repro" <<'EOF'
p is proc_spawn of (["true"])
i is 0
loop while i < 200000:
    print of f"line {i}"
    i is i + 1
EOF
set -o pipefail
"$ROOT/src/eigenscript" "$repro" 2>/dev/null | head -1 >/dev/null
rc=$?
set +o pipefail
if [ "$rc" -ne 0 ]; then
    echo "PASS: spawn+print pipeline reports its closed output (rc=$rc)"
else
    echo "FAIL: spawn+print pipeline silently exited 0"; fail=1
fi

exit "$fail"
