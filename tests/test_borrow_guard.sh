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
# fault: a test-only environment trigger lowers the scan cap for an ordinary
# coalesce call; it adds no user-visible builtin.
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

echo "  -- borrow-scan guard (#548) --"

# The test-only environment switch lowers the scan cap to zero; coalesce then
# returns its first non-null direct child past that planted cap. No builtin is
# added to the language surface. Release builds compile the guard out.
printf 'r is coalesce of [null, 7]\nprint of r\n' > "$TMPDIR/past.eigs"

out=$(EIGS_BORROW_GUARD_PLANT=1 "$EIGS" "$TMPDIR/past.eigs" 2>&1)
rc=$?
if [ "$rc" -eq 0 ]; then
    echo "  SKIP: non-sanitizer build — borrow guard compiled out (release is zero-cost by design)"
elif echo "$out" | grep -q "borrow-scan guard (#548)" \
   && echo "$out" | grep -q "coalesce" \
   && echo "$out" | grep -q "VM_BORROW_SCAN_CAP"; then
    ok "planted past-cap borrow aborts and names the builtin and cap (rc=$rc)"
else
    fail "planted past-cap borrow diagnostic" "rc=$rc got: $(echo "$out" | head -1)"
fi

# Without the plant the same ordinary builtin call must remain clean.
out=$("$EIGS" "$TMPDIR/past.eigs" 2>&1); rc=$?
if [ "$rc" -eq 0 ] && [ "$out" = "7" ]; then
    ok "borrow plant is opt-in; ordinary coalesce remains clean"
else
    fail "borrow plant opt-in control" "rc=$rc got: $out"
fi

echo ""
echo "borrow-guard: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
