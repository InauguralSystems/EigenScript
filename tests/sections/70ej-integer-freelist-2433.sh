echo "[70ej] Integer freelist bounds and separation (#2433)"
check_binary_fingerprint
__if_root="$TESTS_DIR/.."
__if_variant=
for __if_c in "$__if_root"/build/*/eigenscript; do
    if [ "$__if_root/src/eigenscript" -ef "$__if_c" ]; then
        __if_variant=$(basename "$(dirname "$__if_c")"); break
    fi
done
if [ -z "$__if_variant" ]; then
    section_skip "[70ej] direct build has no reusable Make variant objects; sanitizer job runs this check"
else
    TOTAL=$((TOTAL + 1))
    __if_build=$(make --no-print-directory -C "$__if_root" pool-poison-test "POOL_POISON_VARIANT=$__if_variant" 2>&1); __if_rc=$?
    __if_bin="$__if_root/build/$__if_variant/test_pool_poison"
    if [ "$__if_rc" -ne 0 ] || [ ! -x "$__if_bin" ]; then
        FAIL=$((FAIL + 1)); echo "  FAIL: [70ej] build integer freelist reader (rc=$__if_rc)"
        printf '%s\n' "$__if_build" | sed 's/^/      /'
    else
        PASS=$((PASS + 1)); echo "  PASS: [70ej] integer freelist reader built for $__if_variant"
        for __if_mode in int-bounds number-kinds int-drain int-fresh; do
            TOTAL=$((TOTAL + 1))
            __if_out=$(ASAN_OPTIONS=detect_leaks=1 $EIGS_TMO "$__if_bin" "$__if_mode" </dev/null 2>&1); __if_rc=$?
            if [ "$__if_rc" -eq 0 ] && grep -q '^PASS:' <<< "$__if_out" &&
               ! grep -qE 'FAIL:|AddressSanitizer|LeakSanitizer|runtime error:' <<< "$__if_out"; then
                PASS=$((PASS + 1)); echo "  PASS: [70ej] $__if_mode"
            else
                FAIL=$((FAIL + 1)); echo "  FAIL: [70ej] $__if_mode (rc=$__if_rc)"
                printf '%s\n' "$__if_out" | eigs_failure_output
            fi
        done
    fi
fi
unset __if_root __if_variant __if_c __if_build __if_rc __if_bin __if_mode __if_out
echo ""
