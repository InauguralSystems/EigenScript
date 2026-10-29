echo "[0fga] Null type label (#2183; interpreter/JIT/OSR)"
EIGS_JIT_OFF=1 check_eigs_suite "type of null: interpreter" test_null_type_2183.eigs "null type label passed"
EIGS_JIT_ENTRY_THRESHOLD=1 check_eigs_suite "type of null: JIT" test_null_type_2183.eigs "null type label passed"
EIGS_JIT_OSR_THRESHOLD=1 check_eigs_suite "type of null: OSR" test_null_type_2183.eigs "null type label passed"
TOTAL=$((TOTAL + 1))
if ./eigenscript --api | grep -q '^type-label null null$' &&
   grep -q 'type of value — return its runtime label; null is labeled `null`.' ../src/lsp_builtin_index.h; then
    PASS=$((PASS + 1)); echo "  PASS: --api and LSP label null as null"
else
    FAIL=$((FAIL + 1)); echo "  FAIL: --api or LSP null type label is stale"
fi
