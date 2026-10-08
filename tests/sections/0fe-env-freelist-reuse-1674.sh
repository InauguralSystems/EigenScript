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
# process-wide counter at creation (src/eigenscript.c env_new), so a reborn env
# at a reused address always outranks any cache cached against the prior
# occupant and the IC misses instead of firing on the collision. PLANT: with
# that seed removed this row FAILS ("undefined variable 'v'"); with it, PASS.
#
# SCOPE: EIGS_ENV_FREELIST_OFF forces the per-thread ENV FREELIST off (the park
# branch in env_decref) and so exercises general env reuse and loop-env reuse on
# the default build. It does NOT disable chunk->env_cache call-env recycling —
# that recycles the SAME struct (binding_version climbs monotonically, provably
# collision-free) and is governed only by the compile-time -DEIGS_POOL_OFF, not
# by this runtime knob.
#
# #1674 round 2 widened binding_version and the EnvIC/loop-iter version fields
# to uint64 and moved the birth counter to ONE process-wide relaxed-atomic
# counter. The counter no longer wraps within any process lifetime (uint32
# wrapped at ~2^32 births, ~1.7h under this knob at ~715k births/s, reopening
# the ABA; uint64 needs ~2^64, ~8e5 years). The WRAP row below seeds the counter
# just below the old 2^32 boundary (EIGS_ENV_VERSION_SEED, a debug/test seam
# read once at thread attach) and shows behaviour stays correct as births cross
# 2^32. It is a POSITIVE check: a failing-direction uint32-wrap repro needs the
# counter to traverse a full 2^32 between caching and address reuse (billions of
# births), infeasible in a suite — the width itself has deterministic teeth in
# the vm.c _Static_asserts and jit_smoke's wide-start/wide-target rows.
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

# WRAP (#1674 round 2): same hazard, but start the process-wide env-version
# counter 6 below the old uint32 boundary so births cross 2^32 mid-run. Under
# uint64 the counter sails past; the loop var still resolves. (Positive check —
# see SCOPE note above for why the failing direction is not suite-reproducible.)
TOTAL=$((TOTAL + 1))
WRAP_OUT=$(EIGS_ENV_VERSION_SEED=4294967290 EIGS_ENV_FREELIST_OFF=1 bash "$TESTS_DIR/test_bool_fuzz.sh" ./eigenscript 2>&1); WRAP_RC=$?
if [ "$WRAP_RC" = 0 ] && grep -q "^BOOL_FUZZ: examined=.* PASS$" <<< "$WRAP_OUT"; then
    PASS=$((PASS + 1)); echo "  PASS: a loop var survives env-address reuse as the version counter crosses 2^32 ($(grep '^BOOL_FUZZ: examined' <<< "$WRAP_OUT"))"
else
    FAIL=$((FAIL + 1)); echo "  FAIL: a loop var survives env-address reuse as the version counter crosses 2^32 (rc=$WRAP_RC)"
    printf '%s\n' "$WRAP_OUT" | eigs_failure_output
fi
unset WRAP_OUT WRAP_RC
echo ""
