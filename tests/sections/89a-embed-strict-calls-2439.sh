echo "[89a] Per-state embedding strict calls (#2439)"
TOTAL=$((TOTAL + 1))
variant=release
if [ -e ../build/asan/eigenscript ] && [ ./eigenscript -ef ../build/asan/eigenscript ]; then variant=asan; fi
if make -s -C .. EMBED_STRICT_VARIANT="$variant" embed-strict-calls-test &&
   env -u EIGS_STRICT ../build/$variant/test_embed_strict_calls &&
   EIGS_STRICT=0 ../build/$variant/test_embed_strict_calls &&
   EIGS_STRICT=1 ../build/$variant/test_embed_strict_calls; then
    PASS=$((PASS + 1)); echo "  PASS: strict-call transitions and fourth combination"
else
    FAIL=$((FAIL + 1)); echo "  FAIL: strict-call transition regression"
fi
