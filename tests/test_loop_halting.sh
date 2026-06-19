#!/bin/bash
# Opt-in observer loop-halting (the load-bearing classifier).
#
# A `loop while` gets the observer-stall (auto-halt on convergence) ONLY when
# its condition is observer-based (references a predicate). Plain loops emit
# OP_LOOP_CAP_CHECK (iteration cap only) and are never auto-halted by the global
# observer. This classifier is the single point where the whole fix can go
# wrong, so it is tested at the boundary; the interpreter and JIT must agree
# (they key off the compile-time opcode), verified by running a representative
# case both ways. Prints PASS:/FAIL: lines for run_all_tests.sh.
set -u
TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
EIGS="$(cd "$TESTS_DIR/.." && pwd)/src/eigenscript"
TMP=$(mktemp -d -t eigs_loophalt.XXXXXX)
trap 'rm -rf "$TMP"' EXIT

# ---- classifier: condition shape -> emitted opcode ----
classify() {  # $1 = condition, $2 = expected opcode tag (STALL|CAP)
    printf 'i is 0\nloop while %s:\n    i is i + 1\n    break\n' "$1" > "$TMP/c.eigs"
    local got
    got=$(EIGS_DUMP_BC=1 "$EIGS" "$TMP/c.eigs" 2>&1 | grep -oE 'LOOP_(STALL|CAP)_CHECK' | head -1)
    if [ "$got" = "LOOP_${2}_CHECK" ]; then
        echo "PASS: classify [$1] -> $got"
    else
        echo "FAIL: classify [$1] -> got '$got', expected LOOP_${2}_CHECK"
    fi
}
# observer-based (predicate anywhere in the boolean/comparison/unary structure)
classify "not converged"               STALL
classify "converged"                   STALL
classify "improving"                   STALL
classify "(not converged) and (i < 10)" STALL
classify "(i < 10) or oscillating"     STALL
# plain (no predicate in the condition structure)
classify "i < 10"                      CAP
classify "i"                           CAP
classify "not (i < 10)"                CAP
classify "(i < 10) and (i > 0)"        CAP

# ---- behavior: convergence idiom still halts ----
cat > "$TMP/conv.eigs" <<'EOF'
e is 5
loop while not converged:
    e is e * 0.5
print of f"{converged}"
EOF
if [ "$("$EIGS" "$TMP/conv.eigs" 2>/dev/null | tail -1)" = "1" ]; then
    echo "PASS: observer loop (loop while not converged) still halts"
else
    echo "FAIL: observer loop did not halt as before"
fi

# ---- behavior: a plain loop is never auto-halted, even when a settled value
# is observed each iteration (this is exactly the cross-talk that used to
# truncate it). Must run all N iterations. ----
cat > "$TMP/plain.eigs" <<'EOF'
n is 0
i is 0
loop while i < 5000:
    i is i + 1
    n is n + 1
    settled is 0.5
print of f"{n}"
EOF
plain_jit=$("$EIGS" "$TMP/plain.eigs" 2>/dev/null | tail -1)
plain_noj=$(EIGS_JIT_OFF=1 "$EIGS" "$TMP/plain.eigs" 2>/dev/null | tail -1)
if [ "$plain_jit" = "5000" ]; then
    echo "PASS: plain loop runs full 5000 (no observer-stall truncation)"
else
    echo "FAIL: plain loop truncated at $plain_jit / 5000"
fi
# ---- interpreter and JIT must agree ----
if [ "$plain_jit" = "$plain_noj" ]; then
    echo "PASS: plain-loop result identical JIT on ($plain_jit) and off ($plain_noj)"
else
    echo "FAIL: JIT/interpreter disagree: on=$plain_jit off=$plain_noj"
fi
