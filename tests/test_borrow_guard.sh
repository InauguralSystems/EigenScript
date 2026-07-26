#!/bin/bash
# Borrow protocol tests.
#
# Part A (#720) — every call site that invokes a builtin must compensate a
# borrowed return. Builtins may return a borrow of their argument with no
# incref (`num` returns its arg for VAL_NUM; `append`/`sort`/`dict_set`
# return their target). The VM's three sites did this; the out-of-VM ones
# (call_eigs_fn, builtin_dispatch, thread_entry) returned the raw result, so
# `sort_by of [xs, num]` freed every element of xs while the list still
# pointed at them — garbage output in release, heap-use-after-free under
# ASan. Runs on every build: the wrong answers are visible without a
# sanitizer, and rc is gated so an ASan report fails too.
#
# Part B (#548) — in sanitizer builds vm_borrow_scan keeps scanning past
# VM_BORROW_SCAN_CAP and aborts, naming the builtin, when a builtin returns a
# borrowed direct child the capped scan missed. Validated with a planted
# fault: the __borrow_guard_selftest builtin (ASan builds +
# EIGS_BORROW_GUARD_SELFTEST only) deliberately violates the invariant.
#
# Run directly or from run_all_tests.sh. Prints PASS:/FAIL: lines (Part B
# prints one SKIP: line on non-sanitizer builds, where the guard is compiled
# out). Exit code: 0 if all pass or skipped, 1 if any fail.

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

# expect_out <name> <file> <expected-stdout-line>
# Gates BOTH the value and the exit code: pre-#720 these printed garbage in
# release and exited nonzero under ASan, and either alone would let the
# other half regress silently.
expect_out() {
    local name="$1" file="$2" want="$3" got rc
    got=$(ASAN_OPTIONS=detect_leaks=1 "$EIGS" "$file" 2>&1)
    rc=$?
    if [ "$rc" -ne 0 ]; then
        fail "$name" "rc=$rc: $(echo "$got" | grep -m1 ERROR || echo "$got" | head -1)"
    elif [ "$got" = "$want" ]; then
        ok "$name"
    else
        fail "$name" "want '$want', got '$(echo "$got" | head -1)'"
    fi
}

echo "  -- borrow protocol at out-of-VM call sites (#720) --"

# A1: call_eigs_fn — sort_by hands the key fn a BORROWED list element, and
# `num` hands it straight back. Uncompensated, sort_by's own decref dropped
# the list's reference to every element.
printf 'xs is [3, 1, 2]\nr is sort_by of [xs, num]\nprint of r\n' > "$TMPDIR/sortby.eigs"
expect_out "sort_by of [xs, num] sorts (call_eigs_fn borrow)" "$TMPDIR/sortby.eigs" "[1, 2, 3]"

# A2: thread_entry — the worker owns bin_arg and drops it after the call, so
# a returned direct child needs the same compensation the VM does, and
# `result == bin_arg` must transfer rather than be decrefed.
printf 'xs is [3, 1, 2]\nh is spawn of [append, xs, 5]\nr is thread_join of h\nprint of r\n' \
    > "$TMPDIR/spawn_child.eigs"
expect_out "spawn of [append, xs, 5] joins its target (thread_entry borrow)" \
    "$TMPDIR/spawn_child.eigs" "[3, 1, 2, 5]"
printf 'h is spawn of [num, 42]\nr is thread_join of h\nprint of r\n' > "$TMPDIR/spawn_id.eigs"
expect_out "spawn of [num, 42] joins 42 (thread_entry identity transfer)" \
    "$TMPDIR/spawn_id.eigs" "42"

# A3: builtin_dispatch — the C fallback reached when `dispatch` is called
# indirectly (a direct call compiles to OP_DISPATCH, which was already
# correct). The inner builtin's borrow of fn_arg is a GRANDCHILD of
# dispatch's own arg vector, one level deeper than any caller's direct-child
# scan can see, so dispatch must own it before returning.
printf 'd is dispatch\ntbl is [append]\nr is d of [tbl, 0, ([([3, 1, 2]), 5])]\nprint of r\n' \
    > "$TMPDIR/dispatch_indirect.eigs"
expect_out "indirect dispatch owns a grandchild borrow (builtin_dispatch)" \
    "$TMPDIR/dispatch_indirect.eigs" "[3, 1, 2, 5]"
# The OP_DISPATCH path must stay correct — and must not double-incref now
# that the builtin path compensates (that would be a leak, caught by rc).
printf 'tbl is [append]\nr is dispatch of [tbl, 0, ([([3, 1, 2]), 5])]\nprint of r\n' \
    > "$TMPDIR/dispatch_op.eigs"
expect_out "direct dispatch stays correct (OP_DISPATCH)" \
    "$TMPDIR/dispatch_op.eigs" "[3, 1, 2, 5]"

# A4: free_val is the one CONSUMING builtin — it drops a reference rather
# than returning one. At the out-of-VM sites the argument is only borrowed,
# so the ref it consumed was the caller's: xs was left pointing at freed
# elements. The sites now lend it a reference of their own. Both programs
# raise (free_val returns null, which is not a sort key and not a number) —
# what is gated is that the raise is clean, not a use-after-free.
printf 'xs is [3, 1, 2]\ntry:\n    r is sort_by of [xs, free_val]\ncatch e:\n    print of "caught"\nprint of xs\n' \
    > "$TMPDIR/freeval_sortby.eigs"
expect_out "sort_by of [xs, free_val] does not free the caller's elements" \
    "$TMPDIR/freeval_sortby.eigs" "caught
[3, 1, 2]"
printf 'd is dispatch\ntbl is [free_val]\nxs is [3, 1, 2]\nr is d of [tbl, 0, xs]\nprint of xs\n' \
    > "$TMPDIR/freeval_dispatch.eigs"
expect_out "indirect dispatch to free_val does not free its arg vector's child" \
    "$TMPDIR/freeval_dispatch.eigs" "[3, 1, 2]"

echo "  -- borrow-scan guard (#548) --"

printf 'r is __borrow_guard_selftest of [1,2,3]\nprint of "WITHIN_CAP_OK"\n' > "$TMPDIR/within.eigs"
printf 'r is __borrow_guard_selftest of [1,2,3,4,5,6,7,8,9,10]\nprint of r\n' > "$TMPDIR/past.eigs"

# Build-type probe: the selftest builtin exists only when the guard is
# compiled in (sanitizer builds). On release, skip — the guard is
# deliberately zero-cost there, so there is nothing to exercise.
probe=$(EIGS_BORROW_GUARD_SELFTEST=1 "$EIGS" "$TMPDIR/within.eigs" 2>&1)
if echo "$probe" | grep -q "undefined variable '__borrow_guard_selftest'"; then
    echo "  SKIP: non-sanitizer build — borrow guard compiled out (release is zero-cost by design)"
    echo ""
    echo "borrow-guard: $PASS passed, $FAIL failed"
    [ "$FAIL" -eq 0 ] || exit 1
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
