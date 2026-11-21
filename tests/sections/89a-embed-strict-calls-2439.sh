echo "[89a] Per-state embedding strict calls (#2439)"
# #1783: the test program is built in the variant the suite binary IS (asan or
# asan-server in CI's sanitizer shards), found through the shared predicate;
# anything else is release.
. "$TESTS_DIR/suite_variant.sh"
variant=$(suite_binary_variant)
if [ -z "$variant" ]; then
    if [ "${EIGS_ACTIVE_VARIANT_RC:-unset}" = 1 ]; then
        section_skip "embedding strict calls need a make-variant binary (linux/gcc and linux/clang use build.sh)"
    else
        TOTAL=$((TOTAL + 1)); FAIL=$((FAIL + 1))
        echo "  FAIL: suite binary variant is missing or ambiguous; refusing a release fallback"
    fi
else
    suite_variant_is_asan "$variant" || variant=release
    echo "  test binary variant: $variant"
    TOTAL=$((TOTAL + 1))
    strict_calls_bad=""
    if make -s -C .. EMBED_STRICT_VARIANT="$variant" embed-strict-calls-test; then
        # Each run's whole output goes through rc_ok: a sanitizer's hard
        # diagnostic fails the run at any exit code, and the program itself
        # must exit 0 (a leak-only nonzero exit is not accepted here).
        for strict_env in unset empty 0 1; do
            strict_rc=0
            if [ "$strict_env" = unset ]; then
                strict_out=$(env -u EIGS_STRICT ../build/$variant/test_embed_strict_calls 2>&1) || strict_rc=$?
            elif [ "$strict_env" = empty ]; then
                strict_out=$(EIGS_STRICT= ../build/$variant/test_embed_strict_calls 2>&1) || strict_rc=$?
            else
                strict_out=$(EIGS_STRICT=$strict_env ../build/$variant/test_embed_strict_calls 2>&1) || strict_rc=$?
            fi
            # ... and it must have said so itself: its summary line and the
            # line of its matrix, whole (a program that prints nothing and
            # exits 0 has shown nothing).
            if [ "$strict_rc" != 0 ] || ! rc_ok "$strict_rc" "$strict_out" ||
               ! grep -qxF 'embed-strict-calls: PASS transitions=12 fourth=20 failures=0' <<< "$strict_out" ||
               ! grep -qxF 'PASS: matrix of 192 cells (3 calls, 4 kinds of state, 4 start positions, 4 values)' <<< "$strict_out"; then
                strict_calls_bad="$strict_calls_bad $strict_env"
                echo "  EIGS_STRICT $strict_env: rc=$strict_rc"
                printf '%s\n' "$strict_out" | tail -5
            fi
        done
    else
        strict_calls_bad=" build"
    fi
    if [ -z "$strict_calls_bad" ]; then
        PASS=$((PASS + 1)); echo "  PASS: strict-call transitions and fourth combination"
    else
        FAIL=$((FAIL + 1)); echo "  FAIL: strict-call transition regression (${strict_calls_bad# })"
    fi
fi
echo ""
