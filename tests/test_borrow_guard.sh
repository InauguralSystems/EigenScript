#!/bin/bash
# Borrow-scan guard tests (#548): in sanitizer builds vm_borrow_scan keeps
# scanning past VM_BORROW_SCAN_CAP and aborts, naming the builtin, when a
# builtin returns a borrowed direct child the capped scan missed (a silent
# lifetime-dependent UAF in release). Validated with a planted fault: the
# __borrow_guard_selftest builtin (ASan builds + EIGS_BORROW_GUARD_SELFTEST
# only) deliberately violates the invariant.
#
# Run directly or from run_all_tests.sh. Prints PASS:/FAIL: lines (or one
# SKIP: line on non-sanitizer builds, where the guard is compiled out).
# Exit code: 0 if all pass or skipped, 1 if any fail.

set -u
TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$TESTS_DIR/.." && pwd)"
EIGS="$ROOT/src/eigenscript"

PASS=0
FAIL=0
TMPDIR=$(mktemp -d -t eigs_borrow_guard.XXXXXX)
trap 'rm -rf "$TMPDIR"' EXIT

ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1${2:+ ($2)}"; FAIL=$((FAIL+1)); }

printf 'r is __borrow_guard_selftest of [1,2,3]\nprint of "WITHIN_CAP_OK"\n' > "$TMPDIR/within.eigs"
printf 'r is __borrow_guard_selftest of [1,2,3,4,5,6,7,8,9,10]\nprint of r\n' > "$TMPDIR/past.eigs"

# Build-type probe: the selftest builtin exists only when the guard is
# compiled in (sanitizer builds). On release, skip — the guard is
# deliberately zero-cost there, so there is nothing to exercise.
probe=$(EIGS_BORROW_GUARD_SELFTEST=1 "$EIGS" "$TMPDIR/within.eigs" 2>&1)
if echo "$probe" | grep -q "undefined variable '__borrow_guard_selftest'"; then
    echo "  SKIP: non-sanitizer build — borrow guard compiled out (release is zero-cost by design)"
    exit 0
fi

# 1. Within-cap call is compensated normally: no abort, clean exit.
if echo "$probe" | grep -q "WITHIN_CAP_OK"; then
    ok "within-cap borrow runs clean (no abort)"
else
    fail "within-cap borrow runs clean" "got: $(echo "$probe" | head -1)"
fi

# 2. Past-cap violation aborts (SIGABRT), never a silent success.
out=$(EIGS_BORROW_GUARD_SELFTEST=1 "$EIGS" "$TMPDIR/past.eigs" 2>&1)
rc=$?
if [ "$rc" -ne 0 ]; then
    ok "past-cap borrow aborts (rc=$rc)"
else
    fail "past-cap borrow aborts" "exited 0 — guard did not fire"
fi

# 3. The abort names the offending builtin and the cap.
if echo "$out" | grep -q "borrow-scan guard (#548)" \
   && echo "$out" | grep -q "__borrow_guard_selftest" \
   && echo "$out" | grep -q "VM_BORROW_SCAN_CAP"; then
    ok "abort message names the builtin and the cap"
else
    fail "abort message names the builtin and the cap" "got: $(echo "$out" | head -1)"
fi

# 4. The planted fault is opt-in: without EIGS_BORROW_GUARD_SELFTEST the
# builtin is not registered (fuzzers must never reach a deliberate abort).
out=$("$EIGS" "$TMPDIR/past.eigs" 2>&1)
if echo "$out" | grep -q "undefined variable '__borrow_guard_selftest'"; then
    ok "selftest builtin absent without the opt-in env var"
else
    fail "selftest builtin absent without the opt-in env var" "got: $(echo "$out" | head -1)"
fi

echo ""
echo "borrow-guard: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
