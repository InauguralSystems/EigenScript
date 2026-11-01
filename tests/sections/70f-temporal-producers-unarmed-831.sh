# [70f] #831 — the other half: a descriptor must turn recording ON itself.
# [70e] proves reads work once recording is on, but its own source contains the
# `prev of` that arms it. Here the host program has NO temporal query anywhere,
# so every answer exists only if the descriptor assembler's bytecode walk
# (chunk_arm_temporal) armed the chunk's names — pre-fix, all of these were
# null, on every version back to v0.34.0. Moved out of the runner with its
# own header for the same reason as [70e] (hq#58).
echo "[70f] Descriptor arms its own history recording (#831)"
check_eigs_suite "descriptor arms its own history recording (#831)" test_temporal_producers_unarmed.eigs "All tests passed"
echo ""
