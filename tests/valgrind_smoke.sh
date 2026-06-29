#!/usr/bin/env bash
# Valgrind/Memcheck smoke over a representative spread of .eigs programs.
#
# Catches a bug class the other sanitizers miss at the system-allocator
# granularity: use-after-free, reads of uninitialised memory
# (--track-origins=yes), and definite/indirect leaks — complementing the
# ASan+UBSan and ThreadSanitizer jobs. (Caveat: without arena/freelist
# annotations Valgrind treats the custom arena as one defined block, so it
# won't see uninit reads *inside* the arena yet — that's a follow-up.)
#
# JIT is forced off: the copy-and-patch JIT emits runtime native code that
# needs --smc-check=all and muddies the signal; the interpreter path is what
# matters for memory correctness. Run from the tests/ directory.
set -u

BIN="${EIGS_BIN:-../src/eigenscript}"
VG=(valgrind --quiet --error-exitcode=1 --leak-check=full
    --errors-for-leak-kinds=definite,indirect --track-origins=yes
    --num-callers=25)

# Representative spread: closures/cycles (GC), data structures, strings,
# pattern match, recursion, JSON, modules, the observer/predicate system,
# tensors, error handling, and the full threading set (spawn/channel/cycles).
PROGS=(
  test_closures test_closure_cycles test_closure_mutation
  test_data test_dict test_list_remove_at
  test_fstrings test_large_strings
  test_match test_recursion_guard
  test_json test_json_roundtrip
  test_import test_module_cache
  test_observer_value_signal test_named_predicates test_predicate_matrix
  test_observer_park test_flat_buffer_tensor
  test_error_propagation test_default_params test_coverage_v2
  test_concurrent test_spawn_gc test_spawn_parallel
  test_channel_nb test_chan_dict_xthread
)

pass=0; fail=0
for p in "${PROGS[@]}"; do
  f="$p.eigs"
  if [ ! -f "$f" ]; then echo "  SKIP (missing): $p"; continue; fi
  log="$(mktemp)"
  if EIGS_JIT_OFF=1 "${VG[@]}" "$BIN" "$f" </dev/null >"$log" 2>&1; then
    echo "  PASS: $p"; pass=$((pass+1))
  else
    echo "  FAIL: $p — Valgrind reported errors:"
    grep -iE 'Invalid (read|write|free)|uninitialised|uninitialized|definitely lost|indirectly lost|Conditional jump|Use of uninitialised|Process terminating' "$log" | head -6
    fail=$((fail+1))
  fi
  rm -f "$log"
done

echo "============================================"
echo "  Valgrind smoke: $pass passed, $fail failed (of $((pass+fail)))"
echo "============================================"
[ "$fail" -eq 0 ]
