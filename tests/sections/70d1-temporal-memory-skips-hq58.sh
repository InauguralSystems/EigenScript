echo "[70d1] Temporal memory gate skips are allowlisted and counted (hq#58)"
check_binary_fingerprint
# Half 1, the child: a skip of [70d]'s peak-RSS half needs an allowlisted key
# with a reason (tests/temporal_memory_skip_allowlist.txt), or it FAILS.
TOTAL=$((TOTAL + 1))
TMSK_OUT=$(EIGS=./eigenscript bash "$TESTS_DIR/test_temporal_memory_skips_hq58.sh" 2>&1); TMSK_RC=$?
if [ "$TMSK_RC" -eq 0 ] && grep -qx 'temporal-memory skips: 5 passed, 0 failed' <<< "$TMSK_OUT"; then
    PASS=$((PASS + 1)); echo "  PASS: [70d] RSS-half skips need an allowlisted key with a reason"
else
    FAIL=$((FAIL + 1)); echo "  FAIL: [70d] skip policy (rc=$TMSK_RC)"
    printf '%s\n' "$TMSK_OUT" | sed 's/^/      /'
fi

# Half 2, the runner: an allowlisted skip must reach RESULTS. Pre-hq#58 the
# [70d] block relayed the child's SKIP line and counted nothing, so every
# container lane printed "0 skipped" over a gate that measured no RSS. This
# runs the REAL [70d] block, read from the runner, in a subshell with this
# runner's own helpers (section_skip, the `bash` child accounting), GNU time
# hidden, and a scratch allowlist naming this host's key. Counters move only
# inside the subshell; the deltas come back as one line.
TOTAL=$((TOTAL + 1))
TMSK_WORK=$(mktemp -d "${TMPDIR:-/tmp}/eigs_70d1.XXXXXX")
TMSK_BLOCK=$(sed -n '/^echo "\[70d\] /,/^echo ""$/p' "$TESTS_DIR/run_all_tests.sh")
if [ ! -r /proc/self/status ]; then TMSK_KEY=no-procfs
elif grep -qa "__asan_init" ./eigenscript 2>/dev/null; then TMSK_KEY=sanitizer
else TMSK_KEY=no-gnu-time
fi
printf '%s\tscratch reason for the accounting check\n' "$TMSK_KEY" > "$TMSK_WORK/allow.txt"
TMSK_ACCT=$(
    CHILD_LEDGER="$TMSK_WORK/ledger"; : > "$CHILD_LEDGER"
    __EIGS_SEC_LABEL=""; EIGS_SECTION_TIME=0
    TMEM_GNU_TIME="$TMSK_WORK/no-such-gnu-time"; TMEM_SKIP_ALLOWLIST="$TMSK_WORK/allow.txt"
    export TMEM_GNU_TIME TMEM_SKIP_ALLOWLIST
    t0=$TOTAL; p0=$PASS; f0=$FAIL; s0=$SKIPPED
    eval "$TMSK_BLOCK" > "$TMSK_WORK/block.out" 2>&1
    builtin printf 'total=%d pass=%d fail=%d skipped=%d\n' \
        "$((TOTAL - t0))" "$((PASS - p0))" "$((FAIL - f0))" "$((SKIPPED - s0))"
)
TMSK_RELAYED=$(grep -c '^  SKIP:' "$TMSK_WORK/block.out" 2>/dev/null)
if grep -q 'test_temporal_memory.sh' <<< "$TMSK_BLOCK" \
   && [ "$TMSK_ACCT" = "total=4 pass=4 fail=0 skipped=1" ] && [ "${TMSK_RELAYED:-0}" -eq 1 ]; then
    PASS=$((PASS + 1)); echo "  PASS: the [70d] block counts an allowlisted skip ($TMSK_KEY: $TMSK_ACCT)"
else
    FAIL=$((FAIL + 1))
    echo "  FAIL: the [70d] block did not count one allowlisted skip ($TMSK_KEY: ${TMSK_ACCT:-no deltas}, skip lines printed ${TMSK_RELAYED:-0})"
    sed 's/^/      /' "$TMSK_WORK/block.out" 2>/dev/null | tail -12
fi
rm -rf "$TMSK_WORK"
echo ""
