echo "[70g1] Generic operator exports (#2512)"
. "$TESTS_DIR/suite_variant.sh"
variant=$(suite_binary_variant)
if [ -z "$variant" ]; then
    section_skip "generic operator export test needs a make-variant binary"
else
    suite_variant_is_asan "$variant" || variant=release
    TOTAL=$((TOTAL + 1))
    if make -s -C .. GENERIC_OPS_VARIANT="$variant" generic-ops-test &&
       out=$(../build/$variant/test_generic_ops 2>&1) &&
       grep -q '^PASS: generic operator exports examined=' <<<"$out"; then
        PASS=$((PASS + 1)); echo "  $out"
    else
        FAIL=$((FAIL + 1)); echo "  FAIL: generic operator export differential"; printf '%s\n' "$out"
    fi
fi
echo ""
