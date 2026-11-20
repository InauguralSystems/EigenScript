echo "[2344] Template render linear oracle"
EIGS_JIT_OFF=1 check_eigs_suite "template render matches frozen oracle (default strictness)" \
    "test_template_render_linear.eigs" \
    "TEMPLATE ORACLE: 20 inputs and 29524 strings, zero differences"
EIGS_JIT_OFF=1 EIGS_STRICT=0 check_eigs_suite "template render matches frozen oracle (EIGS_STRICT=0)" \
    "test_template_render_linear.eigs" \
    "TEMPLATE ORACLE: 20 inputs and 29524 strings, zero differences"
echo ""
