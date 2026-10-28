#!/usr/bin/env bash
set -u
EIGS=${EIGS:-$(cd "$(dirname "$0")/.." && pwd)/src/eigenscript}
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
pass=0; fail=0
check_reject() {
    label=$1; literal=$2; mode=${3:-run}
    printf 'print of %s\n' "$literal" > "$T/case.eigs"
    if [ "$mode" = lint ]; then out=$($EIGS --lint "$T/case.eigs" 2>&1); rc=$?; else out=$($EIGS "$T/case.eigs" 2>&1); rc=$?; fi
    if [ "$rc" -ne 0 ] && printf '%s\n' "$out" | grep -q "unknown escape" && printf '%s\n' "$out" | grep -Eq 'line 1:[0-9]+'; then
        echo "PASS: $label rejected with line and column"; pass=$((pass + 1))
    else
        echo "FAIL: $label was not rejected with line and column (rc=$rc)"; printf '%s\n' "$out" | sed 's/^/  /'; fail=$((fail + 1))
    fi
}
check_accept() {
    printf 'print of "a\\nb\\tc\\rd\\\\e\\\"f"\n' > "$T/good.eigs"
    out=$($EIGS "$T/good.eigs" 2>&1); rc=$?
    if [ "$rc" -eq 0 ]; then echo "PASS: listed escapes remain accepted"; pass=$((pass + 1)); else echo "FAIL: listed escapes rejected"; fail=$((fail + 1)); fi
}
check_reject 'plain \\q' '"x\qy"'
check_reject 'plain \\0' '"a\0b"'
check_reject 'plain \\u' '"a\u212ab"'
check_reject 'f-string \\q' 'f"x\qy"'
check_reject 'f-string \\0' 'f"a\0b"'
check_reject 'lint plain \\q' '"x\qy"' lint
check_reject 'lint f-string \\0' 'f"a\0b"' lint
check_accept
printf 'unknown escape checks: pass=%d fail=%d\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
