echo "[0fe] Env freelist reuse: stale inline-cache read (#1674, #1661 family)"
# Regression gate for #1674. The default build PARKS dead envs on the per-thread
# freelist, bumping binding_version to invalidate inline caches, so a freed
# env's address is never handed to a different env with a colliding version —
# which is exactly what hid the stale IC read. EIGS_ENV_FREELIST_OFF=1 forces
# every dead env to be free()d instead, so a later env lands on a freed address
# (the hazard #1665's env-off measurement build exposes), reachable on THIS
# default build without a separate binary.
#
# bool_fuzz_gen.eigs builds its probes inside `for v in [...]:` with a nested
# `for stmt in [...]:`; under the freelist-off hazard an unfixed tree
# mis-resolves the outer loop var `v` as `undefined variable` (the generator
# step fails). The fix seeds each env's binding_version from a monotonic
# per-thread counter at creation (src/eigenscript.c env_new), so a reborn env
# at a reused address always outranks any cache cached against the prior
# occupant and the IC misses instead of firing on the collision. PLANT: with
# that seed removed this row FAILS ("undefined variable 'v'"); with it, PASS.
check_binary_fingerprint
TOTAL=$((TOTAL + 1))
ENVFL_OUT=$(EIGS_ENV_FREELIST_OFF=1 bash "$TESTS_DIR/test_bool_fuzz.sh" ./eigenscript 2>&1); ENVFL_RC=$?
if [ "$ENVFL_RC" = 0 ] && grep -q "^BOOL_FUZZ: examined=.* PASS$" <<< "$ENVFL_OUT"; then
    PASS=$((PASS + 1)); echo "  PASS: a loop var survives env-address reuse under the freelist-off hazard ($(grep '^BOOL_FUZZ: examined' <<< "$ENVFL_OUT"))"
else
    FAIL=$((FAIL + 1)); echo "  FAIL: a loop var survives env-address reuse under the freelist-off hazard (rc=$ENVFL_RC)"
    printf '%s\n' "$ENVFL_OUT" | eigs_failure_output
fi
unset ENVFL_OUT ENVFL_RC
echo ""
