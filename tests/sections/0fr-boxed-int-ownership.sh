# #1758 R1.3: an int outside the SMI range is a BOXED heap value with a
# refcount, so every path that used to carry only immediate numbers can now
# leak or over-release one. The R1.3 memory review planted two such faults
# (an overflow raise that skips a decref; an append that stores without an
# incref) and the whole ASan suite stayed green. Each program here pushes boxed
# ints through one family of those paths, and each check is rc 0, strictly
# leak-clean (no rc_ok tolerance, like [87] and [0fn]) and its exact PASS line
# with its check count.
#   test_boxed_int_arith.eigs       VM arithmetic and its raise paths
#   test_boxed_int_containers.eigs  container stores, copies, json, sort
echo "[0fr] Boxed-int ownership (#1758 R1.3)"
check_binary_fingerprint
for __bio in "test_boxed_int_arith.eigs:boxed int arith: PASS checks=41" \
             "test_boxed_int_containers.eigs:boxed int containers: PASS checks=10"; do
    __bio_f=${__bio%%:*}
    __bio_m=${__bio#*:}
    TOTAL=$((TOTAL + 1))
    BIO_OUTPUT=$(suite_program_run "$__bio_f" $EIGS_TMO ./eigenscript "$TESTS_DIR/$__bio_f" </dev/null 2>&1); BIO_RC=$?
    if [ "$BIO_RC" -eq 0 ] &&
       [ "$(lsan_classify_name "$BIO_OUTPUT")" = none ] &&
       grep -Fxq "$__bio_m" <<< "$BIO_OUTPUT"; then
        PASS=$((PASS + 1))
        echo "  PASS: $__bio_f: boxed ints keep exact reference counts (leak-clean)"
    else
        FAIL=$((FAIL + 1))
        echo "  FAIL: $__bio_f (rc=$BIO_RC, sanitizer=$(lsan_classify_name "$BIO_OUTPUT") — must exit 0, leak-clean, with '$__bio_m')"
        printf '%s\n' "$BIO_OUTPUT" | eigs_failure_output
    fi
done
unset __bio __bio_f __bio_m
echo ""
