echo "[2344] Template render linear oracle"
EIGS_JIT_OFF=1 check_eigs_suite "template render matches frozen oracle" \
    "test_template_render_linear.eigs" "TEMPLATE ORACLE: 21 inputs, zero differences"
echo ""
