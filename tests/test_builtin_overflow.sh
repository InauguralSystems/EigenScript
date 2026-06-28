#!/bin/bash
# Regression: integer-overflow in builtin length/offset arithmetic must never
# corrupt memory. str_replace computed result length and buf_copy computed
# offset bounds in `int`, which overflowed on adversarial sizes — undersizing
# an allocation (then overrunning it) or slipping a huge offset past the bounds
# check into an out-of-bounds memmove. Both now compute in wide/size_t math:
# str_replace caps the result with a catchable error; buf_copy returns null.
set -u
TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
BIN="$(cd "$TESTS_DIR/.." && pwd)/src/eigenscript"

run_case() {
    local name="$1" prog="$2" want="$3"
    local f; f=$(mktemp /tmp/eigs_bo_XXXXXX.eigs)
    printf '%s\n' "$prog" > "$f"
    local out rc
    out=$("$BIN" "$f" 2>&1); rc=$?
    rm -f "$f"
    if [ $rc -eq 139 ] || [ $rc -eq 134 ]; then
        echo "  FAIL: $name (crash rc=$rc)"
        echo "$out" | tail -2
    elif echo "$out" | grep -qF "$want"; then
        echo "  PASS: $name (rc=$rc)"
    else
        echo "  FAIL: $name (missing '$want', rc=$rc)"
        echo "$out" | tail -2
    fi
}

# str_replace: 5000 matches × 60000-char replacement ≈ 300 MB result — over the
# cap. Pre-fix this overflowed int32 to a small malloc and overran it (SIGSEGV);
# now it raises a catchable error before allocating.
run_case "str_replace expansion overflow → catchable" \
'src is join of [fill of [5000, "a"], ""]
rep is join of [fill of [60000, "b"], ""]
caught is 0
try:
    out is str_replace of [src, "a", rep]
catch e:
    caught is 1
print of caught' "1"

# A normal str_replace still works (guards the size_t refactor).
run_case "str_replace normal correctness" \
'print of (str_replace of ["banana", "a", "X"])' "bXnXnX"

# buf_copy: huge offsets/count that overflowed the int bounds check. Now the
# subtraction-form check rejects them and it returns null — no OOB memmove.
run_case "buf_copy offset/count overflow → null" \
'a is buffer of 4
b is buffer of 4
buf_copy of [a, 2000000000, b, 2000000000, 2000000000]
print of "survived"' "survived"

# matmul: the result element count ar*bc overflowed int into a tiny allocation
# while the kernel wrote ar*bc doubles (a 65536x1 by 1x65536 product). Now the
# product is computed in 64-bit and rejected over the 10M cap — no heap overflow.
run_case "flat-buffer matmul result overflow → no OOB" \
'base is buffer of 65536
a is reshape of [base, 65536, 1]
b is reshape of [base, 1, 65536]
c is matmul of [a, b]
print of "survived"' "survived"

# A normal matmul still produces the right answer (guards the cap refactor).
run_case "matmul normal correctness" \
'print of (matmul of [[[1.0, 2.0], [3.0, 4.0]], [[5.0, 6.0], [7.0, 8.0]]])' \
'[[19, 22], [43, 50]]'

echo ""
