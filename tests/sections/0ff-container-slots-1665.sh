echo "[0ff] Container slot API (#1665 B0, slot storage B10)"
# #1783: find the variant the suite binary IS (asan or asan-server in CI)
# through the shared build-system predicate; anything else is release.
. "$TESTS_DIR/suite_variant.sh"
variant=$(suite_binary_variant)
if [ -z "$variant" ]; then
    if [ "${EIGS_ACTIVE_VARIANT_RC:-unset}" = 1 ]; then
        section_skip "container slot API needs a make-variant binary (linux/gcc and linux/clang use build.sh)"
    else
        TOTAL=$((TOTAL + 1)); FAIL=$((FAIL + 1))
        echo "  FAIL: suite binary variant is missing or ambiguous; refusing a release fallback"
    fi
    echo ""
    return
fi
suite_variant_is_asan "$variant" || variant=release
echo "  test binary variant: $variant"
TOTAL=$((TOTAL + 1))
if make -s -C .. SLOT_TEST_VARIANT="$variant" container-slot-test && \
   ../build/$variant/test_container_slots; then
    # Planted fault: a builtin result that is a numeric view must abort in
    # the real builtin-return compensation path (vm_borrow_scan).
    # Capture the expected abort without touching shell options: this file is
    # SOURCED into the runner, so a `set -e` here would arm errexit for every
    # later section (the macOS merge-queue suite died silently after [47i]).
    rc=0
    ../build/$variant/test_container_slots --escape-view >/tmp/eigs-slot-escape.$$ 2>&1 || rc=$?
    if [ "$rc" -gt 128 ] && grep -q 'escaped numeric view' /tmp/eigs-slot-escape.$$; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1)); echo "  FAIL: escaped view plant rc=$rc"; cat /tmp/eigs-slot-escape.$$
    fi
    rm -f /tmp/eigs-slot-escape.$$
else
    FAIL=$((FAIL + 1)); echo "  FAIL: container slot API"
fi
echo ""
