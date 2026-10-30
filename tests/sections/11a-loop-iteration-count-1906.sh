echo "[11a] Per-loop published iteration count (#1906; interpreter/default/OSR)"
LI_EXPECTED='["nested-two", 5]
["nested-three", 4]
["break", 4]
["catch", 3]
["return", 3]
["stall-limit", 1, "stalled", false, 5]
["budget", false, 2, true]
["frame", true]
["recursive", true]
["eval", 5, 5]
["load-file", 5, 5]'
for tier in "EIGS_JIT_OFF=1" "" "EIGS_JIT_OSR_THRESHOLD=1"; do
    LI_OUTPUT=$(env $tier ./eigenscript ../tests/test_loop_iterations_per_loop.eigs 2>&1)
    LI_RC=$?
    TOTAL=$((TOTAL + 1))
    if rc_ok "$LI_RC" "$LI_OUTPUT" && [ "$LI_OUTPUT" = "$LI_EXPECTED" ]; then
        echo "  PASS: ${tier:-default}: loop counts and fresh per-frame sandbox budgets"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: ${tier:-default}: per-loop counts or sandbox budget (rc=$LI_RC)"
        printf '%s\n' "$LI_OUTPUT" | eigs_failure_output
        FAIL=$((FAIL + 1))
    fi
done
unset LI_EXPECTED LI_OUTPUT LI_RC

# Sequential loops consume operand-stack space only while active: source size
# and repeated dynamic compilation cannot exhaust environment-local slots.
LI_TMP=$(mktemp "${TMPDIR:-/tmp}/eigs-loop-counter-XXXXXX.eigs")
python3 - "$LI_TMP" <<'PY'
import sys
with open(sys.argv[1], "w", encoding="utf-8") as f:
    for _ in range(1000):
        f.write("loop while false:\n    unused is 1\n")
    for i in range(600):
        f.write(f"binding_{i} is {i}\n")
    f.write("repeat is 0\nloop while repeat < 1000:\n")
    f.write("    repeat is repeat + 1\n")
    f.write('    eval of "inner is 0\\nloop while inner < 1:\\n    inner is inner + 1"\n')
    f.write('print of ["capacity", repeat, __loop_iterations__]\n')
PY
for tier in "EIGS_JIT_OFF=1" "" "EIGS_JIT_OSR_THRESHOLD=1"; do
    LI_OUTPUT=$(env $tier ./eigenscript "$LI_TMP" 2>&1)
    LI_RC=$?
    TOTAL=$((TOTAL + 1))
    if rc_ok "$LI_RC" "$LI_OUTPUT" && [ "$LI_OUTPUT" = '["capacity", 1000, 1000]' ]; then
        echo "  PASS: ${tier:-default}: 1,000 sequential loops and eval with 600 bindings"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: ${tier:-default}: stack counter capacity regression (rc=$LI_RC)"
        printf '%s\n' "$LI_OUTPUT" | eigs_failure_output
        FAIL=$((FAIL + 1))
    fi
done
rm -f "$LI_TMP"
unset LI_TMP LI_OUTPUT LI_RC
echo ""
