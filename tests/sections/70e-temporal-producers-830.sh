# [70e] #830 — temporal reads from a producer that is NOT the bytecode compiler.
# #827's armed-name set is populated only by src/compiler.c, so once the history
# was filtered on it, the AOT (which emits C and calls trace_assign directly),
# an embedder, and vm_run_bytecode/sandbox_run descriptors all recorded nothing
# and every `prev of` / `at`-qualified read answered null. Silent wrong answer,
# shipped in v0.35.1, and the suite stayed green because this producer class had
# no coverage anywhere. The C-level twin (the AOT's exact shape) is in
# src/embed_smoke.c, gated by `make embed-smoke` in CI.
# Moved out of the runner with its own header (hq#58): inline and headerless,
# its row was credited to [70d] and kept that section's outcome nonzero while
# the RSS gate there measured nothing.
echo "[70e] Temporal reads from a non-compiler producer (#830)"
check_eigs_suite "temporal reads from a non-compiler producer (#830)" test_temporal_producers.eigs "All tests passed"
echo ""
