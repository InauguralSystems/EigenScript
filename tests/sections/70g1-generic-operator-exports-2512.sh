echo "[70g1] Generic operator exports (#2512)"
. "$TESTS_DIR/suite_variant.sh"
variant=$(suite_binary_variant)
if [ -z "$variant" ]; then
    section_skip "generic operator exports: did not check C differential or program oracle because src/eigenscript is not a make-variant binary (covered by zlib and sanitizer lanes)"
else
    if ! make -s -C .. GENERIC_OPS_VARIANT="$variant" generic-ops-test; then
        section_skip "generic operator C differential: variant '$variant' cannot build the C test (program oracle still checked)"
    else
        # The C differential runs in the default tier and under forced OSR: its
        # eigs_eval_string side goes through the JIT, and the round-4 SIGSEGV
        # showed first under EIGS_JIT_OSR_THRESHOLD=1.
        for ctier in default osr; do
            case "$ctier" in default) ctier_env="" ;; osr) ctier_env="EIGS_JIT_OSR_THRESHOLD=1" ;; esac
            for strict in unset 0 1; do
                case "$strict" in unset) strict_env="-u EIGS_STRICT" ;; *) strict_env="EIGS_STRICT=$strict" ;; esac
                TOTAL=$((TOTAL + 1))
                out=$(env $strict_env $ctier_env ../build/$variant/test_generic_ops 2>&1); rc=$?
                expected="PASS: generic operator exports strict=$strict examined="
                line=$(grep "^$expected" <<< "$out")
                if rc_ok "$rc" "$out" && [ -n "$line" ]; then
                    PASS=$((PASS + 1)); echo "  PASS: tier=$ctier strict=$strict ${line#PASS: }"
                else
                    FAIL=$((FAIL + 1)); echo "  FAIL: tier=$ctier strict=$strict generic operator differential (rc=$rc)"; printf '    %s\n' "$out"
                fi
            done
        done
    fi
        for tier in interpreter default hot osr; do
            case "$tier" in
                interpreter) tier_env="EIGS_JIT_OFF=1" ;;
                default) tier_env="" ;;
                hot) tier_env="EIGS_JIT_HOT=1" ;;
                osr) tier_env="EIGS_JIT_HOT=1 EIGS_JIT_OSR_THRESHOLD=1" ;;
            esac
            TOTAL=$((TOTAL + 1))
            out=$(env $tier_env python3 ../tests/generic_ops_expected.py --program-check "$EIGS" 2>&1); rc=$?
            if rc_ok "$rc" "$out" && grep -q '^PASS: generic operator program oracle rows=' <<< "$out"; then
                PASS=$((PASS + 1)); echo "  PASS: program tier=$tier ${out#PASS: }"
            else
                FAIL=$((FAIL + 1)); echo "  FAIL: tier=$tier generic operator program oracle (rc=$rc)"; printf '    %s\n' "$out"
            fi
        done
fi
echo ""
