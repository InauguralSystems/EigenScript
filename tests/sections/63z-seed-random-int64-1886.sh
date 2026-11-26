echo "[63z] seed_random uses the whole int64 seed (#1886)"
TOTAL=$((TOTAL + 1))
SEED64_OUT=$(EIGS="$EIGS" python3 "$TESTS_DIR/test_seed_random_int64.py" 2>&1); SEED64_RC=$?
if rc_ok "$SEED64_RC" "$SEED64_OUT" && [ "$SEED64_RC" -eq 0 ] &&
   [ "$(grep -c '^PASS:' <<< "$SEED64_OUT")" -eq 5 ]; then
    PASS=$((PASS + 1)); echo "  PASS: seeds that differ only above bit 31, 5000 pairs, each of the 64 bits, and the POSIX stream up to 2^32-1"
else
    FAIL=$((FAIL + 1)); echo "  FAIL: seed_random int64 seeds"
    printf '%s\n' "$SEED64_OUT" | sed 's/^/    /'
fi
