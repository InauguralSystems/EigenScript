echo "[70e9] Evaluation order is identical across native tiers (#2165)"
if [ "$(uname -m)" != x86_64 ]; then
    section_skip "JIT not built on $(uname -m): evaluation-order native witnesses need the x86-64 JIT"
else
    EO_DIR=$(mktemp -d "${TMPDIR:-/tmp}/eigs-eval-order-2165.XXXXXX")
    for EO_TIER in ref jit osr; do
        case "$EO_TIER" in
            ref) EO_ENV="EIGS_JIT_OFF=1" ;;
            jit) EO_ENV="" ;;
            osr) EO_ENV="EIGS_JIT_OSR_THRESHOLD=1" ;;
        esac
        env $EO_ENV EIGS_JIT_STATS=1 EIGS_JIT_HOT=1 $EIGS_TMO ./eigenscript \
            ../tests/test_evaluation_order_2165.eigs </dev/null \
            >"$EO_DIR/$EO_TIER.out" 2>"$EO_DIR/$EO_TIER.err"
        EO_RC=$?
        TOTAL=$((TOTAL + 1))
        EO_OK=false
        case "$EO_TIER" in
            ref)
                if rc_ok "$EO_RC" "$(cat "$EO_DIR/$EO_TIER.out")" &&
                   grep -q '^All tests passed\.$' "$EO_DIR/$EO_TIER.out" &&
                   grep -qE '^\[jit\] scanned=[0-9]+ compiled=0 ' "$EO_DIR/$EO_TIER.err"; then
                    EO_OK=true
                fi
                ;;
            jit)
                if rc_ok "$EO_RC" "$(cat "$EO_DIR/$EO_TIER.out")" &&
                   grep -q '^All tests passed\.$' "$EO_DIR/$EO_TIER.out" &&
                   grep -qE '^\[jit\] scanned=[0-9]+ compiled=[1-9][0-9]* ' "$EO_DIR/$EO_TIER.err" &&
                   awk '$1 ~ /^evaluation_order_probe_/ { found++; if ($3 == "yes") native++ }
                        END { exit !(found == 9 && native == found) }' "$EO_DIR/$EO_TIER.err"; then
                    EO_OK=true
                fi
                ;;
            osr)
                if rc_ok "$EO_RC" "$(cat "$EO_DIR/$EO_TIER.out")" &&
                   grep -q '^All tests passed\.$' "$EO_DIR/$EO_TIER.out" &&
                   grep -qE '^\[jit\] scanned=[0-9]+ compiled=[1-9][0-9]* ' "$EO_DIR/$EO_TIER.err" &&
                   awk '$1 ~ /^evaluation_order_probe_/ { found++; if ($9 == "yes" && $14+0 > 0) entered++ }
                        END { exit !(found == 9 && entered == found) }' "$EO_DIR/$EO_TIER.err"; then
                    EO_OK=true
                fi
                ;;
        esac
        if $EO_OK; then
            PASS=$((PASS + 1))
            echo "  PASS: evaluation order: $EO_TIER tier has its required execution witness"
        else
            FAIL=$((FAIL + 1))
            echo "  FAIL: evaluation order: $EO_TIER tier lacks its required execution witness (rc=$EO_RC)"
            cat "$EO_DIR/$EO_TIER.out" "$EO_DIR/$EO_TIER.err" | eigs_failure_output
        fi
    done

    TOTAL=$((TOTAL + 1))
    if cmp -s "$EO_DIR/ref.out" "$EO_DIR/jit.out" && cmp -s "$EO_DIR/ref.out" "$EO_DIR/osr.out"; then
        PASS=$((PASS + 1)); echo "  PASS: interpreter, JIT and OSR evaluation-order outputs agree"
    else
        FAIL=$((FAIL + 1)); echo "  FAIL: interpreter, JIT and OSR evaluation-order outputs differ"
        diff -u "$EO_DIR/ref.out" "$EO_DIR/jit.out" || true
        diff -u "$EO_DIR/ref.out" "$EO_DIR/osr.out" || true
    fi
    rm -rf "$EO_DIR"
    unset EO_DIR EO_TIER EO_ENV EO_RC EO_OK
fi
