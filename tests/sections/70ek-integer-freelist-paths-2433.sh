echo "[70ek] Integer freelist lifecycle paths (#2433)"
check_binary_fingerprint
__ifp_root="$TESTS_DIR/.."
__ifp_variant=
for __ifp_candidate in "$__ifp_root"/build/*/eigenscript; do
    if [ "$__ifp_root/src/eigenscript" -ef "$__ifp_candidate" ]; then
        __ifp_variant=$(basename "$(dirname "$__ifp_candidate")"); break
    fi
done
case "$__ifp_variant" in
    asan*) ;;
    *) section_skip "[70ek] requires the hosted asan sanitizer job (current variant: ${__ifp_variant:-direct})"
       unset __ifp_root __ifp_variant __ifp_candidate
       echo ""
       return ;;
esac

for __ifp_row in \
    "integer_freelist_paths.eigs:five language lifecycle paths" \
    "integer_freelist_threads.eigs:64-thread detach burst"; do
    __ifp_file=${__ifp_row%%:*}; __ifp_name=${__ifp_row#*:}
    TOTAL=$((TOTAL + 1))
    __ifp_out=$(suite_program_run "$__ifp_file" $EIGS_TMO "$EIGS" "$TESTS_DIR/$__ifp_file" </dev/null 2>&1); __ifp_rc=$?
    case "$__ifp_file" in
        integer_freelist_paths.eigs)
            __ifp_markers=$(printf '%s\n' "$__ifp_out" | grep -c '^PASS: boxed integer')
            __ifp_exact=$([ "$__ifp_markers" -eq 5 ] &&
                grep -qxF 'PASS: boxed integer held in global at exit' <<< "$__ifp_out" &&
                grep -qxF 'PASS: boxed integers held in list and dict at exit' <<< "$__ifp_out" &&
                grep -qxF 'PASS: boxed integer is a compiled-function constant' <<< "$__ifp_out" &&
                grep -qxF 'PASS: boxed integer created on worker and released by main after join' <<< "$__ifp_out" &&
                grep -qxF 'PASS: boxed integer released by worker immediately before exit' <<< "$__ifp_out"; echo $?) ;;
        *)  __ifp_exact=$(grep -qxF 'PASS: integer freelist 64-thread burst boxes=320000' <<< "$__ifp_out"; echo $?) ;;
    esac
    if [ "$__ifp_rc" -eq 0 ] && [ "$(lsan_classify_name "$__ifp_out")" = none ] &&
       [ "$__ifp_exact" -eq 0 ]; then
        PASS=$((PASS + 1)); echo "  PASS: [70ek] $__ifp_name (sanitizer-clean)"
    else
        FAIL=$((FAIL + 1)); echo "  FAIL: [70ek] $__ifp_name (rc=$__ifp_rc, sanitizer=$(lsan_classify_name "$__ifp_out"))"
        printf '%s\n' "$__ifp_out" | eigs_failure_output
    fi
done

TOTAL=$((TOTAL + 1))
__ifp_build=$(make --no-print-directory -C "$__ifp_root" embed-int-freelist-test "EMBED_INT_FREELIST_VARIANT=$__ifp_variant" 2>&1); __ifp_rc=$?
__ifp_bin="$__ifp_root/build/$__ifp_variant/test_embed_integer_freelist"
if [ "$__ifp_rc" -eq 0 ] && [ -x "$__ifp_bin" ]; then
    __ifp_out=$(ASAN_OPTIONS=detect_leaks=1 $EIGS_TMO "$__ifp_bin" </dev/null 2>&1); __ifp_rc=$?
else
    __ifp_out=$__ifp_build
fi
if [ "$__ifp_rc" -eq 0 ] && [ "$(lsan_classify_name "$__ifp_out")" = none ] &&
   grep -qxF 'PASS: boxed integer embedding lifecycle' <<< "$__ifp_out"; then
    PASS=$((PASS + 1)); echo "  PASS: [70ek] attached-host embedding lifecycle (sanitizer-clean)"
else
    FAIL=$((FAIL + 1)); echo "  FAIL: [70ek] attached-host embedding lifecycle (rc=$__ifp_rc, sanitizer=$(lsan_classify_name "$__ifp_out"))"
    printf '%s\n' "$__ifp_out" | eigs_failure_output
fi
unset __ifp_root __ifp_variant __ifp_candidate __ifp_row __ifp_file __ifp_name __ifp_out __ifp_rc __ifp_build __ifp_bin __ifp_markers __ifp_exact
echo ""
