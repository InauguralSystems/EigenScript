echo "[70g1] Generic operator exports (#2512)"
. "$TESTS_DIR/suite_variant.sh"
variant=$(suite_binary_variant)
if [ -z "$variant" ]; then
    section_skip "generic operator export test needs a make-variant binary (release/ASan lane)"
else
    suite_variant_is_asan "$variant" || variant=release
    if ! make -s -C .. GENERIC_OPS_VARIANT="$variant" generic-ops-test; then
        TOTAL=$((TOTAL + 1)); FAIL=$((FAIL + 1)); echo "  FAIL: build generic operator differential"
    else
        for strict in unset 0 1; do
            for tier in interpreter default hot osr; do
                case "$tier" in
                    interpreter) tier_env="EIGS_JIT_OFF=1" ;;
                    default) tier_env="" ;;
                    hot) tier_env="EIGS_JIT_HOT=1" ;;
                    osr) tier_env="EIGS_JIT_HOT=1 EIGS_JIT_OSR_THRESHOLD=1" ;;
                esac
                case "$strict" in unset) strict_env="env -u EIGS_STRICT" ;; *) strict_env="EIGS_STRICT=$strict" ;; esac
                TOTAL=$((TOTAL + 1))
                out=$(env $strict_env $tier_env ../build/$variant/test_generic_ops 2>&1); rc=$?
                expected="PASS: generic operator exports strict=$strict examined="
                case "$strict" in unset) expected="PASS: generic operator exports strict=unset examined=" ;; esac
                if [ "$rc" -eq 0 ] && grep -q "^$expected" <<< "$out"; then
                    PASS=$((PASS + 1)); echo "  PASS: strict=$strict tier=$tier ${out#PASS: }"
                else
                    FAIL=$((FAIL + 1)); echo "  FAIL: strict=$strict tier=$tier generic operator differential (rc=$rc)"; printf '    %s\n' "$out"
                fi
            done
        done
    fi
fi
echo ""
