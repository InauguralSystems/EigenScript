echo "[0fg] Pool stale-read poisoning (#1665)"
# The two recycling pools #1665 kept (the Value NUM freelist and call-env
# recycling on chunk->env_cache) keep a parked object "allocated" to ASan, so a
# stale read of one was invisible (#1661). On ASan builds the parked object is
# now poisoned (eigenscript.h, EIGS_ASAN_POOL_POISON). tests/test_pool_poison.c
# plants one stale read per pool; each must be reported as use-after-poison AT
# THE PLANTED ADDRESS (the child prints it; no symbolizer needed): a parked
# NUM's number, a parked env's values[0], and a field of the parked Env. On an ASan
# build without the poisoning every plant prints UNDETECTED and exit 0, which
# fails here. The control runs the pools' own reuse paths (freelist pop,
# call-env take, a cycle collection that walks chunk -> parked env) and must
# stay sanitizer-clean with leaks on. Release builds compile no poisoning:
# this section announces a skip there.
check_binary_fingerprint
__pp_root="$TESTS_DIR/.."
__pp_variant=
for __pp_c in "$__pp_root"/build/*/eigenscript; do
    if [ "$__pp_root/src/eigenscript" -ef "$__pp_c" ]; then
        __pp_variant=$(basename "$(dirname "$__pp_c")"); break
    fi
done
__pp_probe=$(ASAN_OPTIONS=help=1 ./eigenscript --version 2>&1)
if ! grep -q 'AddressSanitizer' <<< "$__pp_probe"; then
    section_skip "[0fg] not an ASan build -- pool poisoning is compiled only under AddressSanitizer"
else
    case "$__pp_variant" in
    "")
        TOTAL=$((TOTAL + 1)); FAIL=$((FAIL + 1))
        echo "  FAIL: [0fg] src/eigenscript is not a hard link to any build/<variant>/eigenscript" ;;
    *pool-off*)
        section_skip "[0fg] variant $__pp_variant compiles both pools out -- nothing is parked to poison" ;;
    *)
        TOTAL=$((TOTAL + 1))
        __pp_build=$(make --no-print-directory -C "$__pp_root" pool-poison-test "POOL_POISON_VARIANT=$__pp_variant" 2>&1); __pp_rc=$?
        __pp_bin="$__pp_root/build/$__pp_variant/test_pool_poison"
        if [ "$__pp_rc" -ne 0 ] || [ ! -x "$__pp_bin" ]; then
            FAIL=$((FAIL + 1)); echo "  FAIL: [0fg] building the plants for $__pp_variant (rc=$__pp_rc)"
            printf '%s\n' "$__pp_build" | sed 's/^/      /'
        else
            PASS=$((PASS + 1)); echo "  PASS: [0fg] plants built against the $__pp_variant objects"
            for __pp_mode in num env envfield; do
                TOTAL=$((TOTAL + 1))
                __pp_out=$(ASAN_OPTIONS=detect_leaks=0 $EIGS_TMO "$__pp_bin" "$__pp_mode" </dev/null 2>&1); __pp_rc=$?
                __pp_addr=$(sed -n "s/^ARMED $__pp_mode: .*, reading \(0x[0-9a-f]*\)\$/\1/p" <<< "$__pp_out")
                if [ "$__pp_rc" -ne 0 ] && [ "$__pp_rc" -ne 124 ] && [ -n "$__pp_addr" ] &&
                   grep -q "ERROR: AddressSanitizer: use-after-poison on address $__pp_addr " <<< "$__pp_out" &&
                   ! grep -q '^UNDETECTED' <<< "$__pp_out"; then
                    PASS=$((PASS + 1)); echo "  PASS: [0fg] stale read of a parked $__pp_mode is use-after-poison at $__pp_addr"
                else
                    FAIL=$((FAIL + 1)); echo "  FAIL: [0fg] stale read of a parked $__pp_mode not reported at the planted address (rc=$__pp_rc, addr='${__pp_addr}')"
                    printf '%s\n' "$__pp_out" | sed 's/^/      /'
                fi
            done
            TOTAL=$((TOTAL + 1))
            __pp_out=$(ASAN_OPTIONS=detect_leaks=1 $EIGS_TMO "$__pp_bin" control </dev/null 2>&1); __pp_rc=$?
            if [ "$__pp_rc" -eq 0 ] && grep -q '^control: all clean$' <<< "$__pp_out" &&
               ! grep -qE 'AddressSanitizer|LeakSanitizer|runtime error:' <<< "$__pp_out"; then
                PASS=$((PASS + 1)); echo "  PASS: [0fg] pool reuse paths (pop, take, collector walk) are poison-clean"
            else
                FAIL=$((FAIL + 1)); echo "  FAIL: [0fg] pool reuse paths reported or misbehaved (rc=$__pp_rc)"
                printf '%s\n' "$__pp_out" | sed 's/^/      /'
            fi
        fi ;;
    esac
fi
unset __pp_root __pp_variant __pp_c __pp_probe __pp_build __pp_rc __pp_bin __pp_mode __pp_out __pp_addr
echo ""
