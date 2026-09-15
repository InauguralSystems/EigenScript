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

# --full (#1160): the nightly lane runs the WHOLE runnable corpus, not this
# fixed smoke spread. The list is DERIVED from tests/*.eigs rather than written
# out, because a second hand-written list is a second thing to drift.
#
# The corpus contains fixtures that are *supposed* to exit non-zero (error
# demos, guard self-tests) and fixtures that need arguments; valgrinding those
# would report a program failure as a memory finding. So a pre-pass runs each
# candidate under the plain binary with no arguments and keeps only the ones
# that exit 0 — visibly counted, never silently dropped.
#
# Two floors, in both directions (a derived population shrinks quietly):
#   * the derived corpus must be at least as large as the smoke spread;
#   * every smoke program must survive the pre-pass, because the spread is
#     known-good — one of them being excluded means the pre-pass is wrong,
#     not that the program is.
FULL=0
[ "${1:-}" = "--full" ] && FULL=1

# `timeout` is GNU; the macOS runners ship neither it nor gtimeout by default.
# This file is ubuntu-only today, but the suite's own probe costs one line and
# keeps that from becoming a trap later (see .claude/rules/test-suite.md).
VG_TMO=""
PRE_TMO=""
if command -v timeout >/dev/null 2>&1; then VG_TMO="timeout 600"; PRE_TMO="timeout 60"
elif command -v gtimeout >/dev/null 2>&1; then VG_TMO="gtimeout 600"; PRE_TMO="gtimeout 60"; fi

if [ "$FULL" -eq 1 ]; then
  SMOKE=("${PROGS[@]}")
  CANDIDATES=()
  for f in test_*.eigs; do
    [ -f "$f" ] || continue
    CANDIDATES+=("${f%.eigs}")
  done
  if [ "${#CANDIDATES[@]}" -lt "${#SMOKE[@]}" ]; then
    echo "FAIL: derived corpus (${#CANDIDATES[@]}) is smaller than the smoke spread (${#SMOKE[@]}) — tests/*.eigs did not enumerate"
    exit 1
  fi
  KEPT=(); EXCLUDED=()
  for p in "${CANDIDATES[@]}"; do
    if EIGS_JIT_OFF=1 $PRE_TMO "$BIN" "$p.eigs" </dev/null >/dev/null 2>&1; then
      KEPT+=("$p")
    else
      EXCLUDED+=("$p")
    fi
  done
  missing=""
  for s in "${SMOKE[@]}"; do
    case " ${KEPT[*]} " in
      *" $s "*) ;;
      *) [ -f "$s.eigs" ] && missing="$missing $s" ;;
    esac
  done
  if [ -n "$missing" ]; then
    echo "FAIL: the pre-pass excluded known-good smoke program(s):$missing"
    echo "      a smoke program that no longer exits 0 under the plain binary is a"
    echo "      real failure or a broken pre-pass — either way this is not a corpus"
    exit 1
  fi
  if [ "${#KEPT[@]}" -lt "${#SMOKE[@]}" ]; then
    echo "FAIL: only ${#KEPT[@]} program(s) survived the pre-pass, below the smoke floor ${#SMOKE[@]}"
    exit 1
  fi
  PROGS=("${KEPT[@]}")
  echo "valgrind-full: corpus=${#PROGS[@]} of ${#CANDIDATES[@]} candidates; ${#EXCLUDED[@]} excluded (non-zero exit under the plain binary, no arguments)"
  echo "valgrind-full: excluded: ${EXCLUDED[*]}"
fi

# The size of the spread is DERIVED, never written down: nightly.yml, docs/CI.md
# (three places) and the CHANGELOG all said a literal count while PROGS held
# 27 (#1160 round 4). A number in prose is a number that drifts.
echo "valgrind: programs=${#PROGS[@]} mode=$( [ "$FULL" -eq 1 ] && echo full-corpus || echo smoke-spread )"

pass=0; fail=0
for p in "${PROGS[@]}"; do
  f="$p.eigs"
  if [ ! -f "$f" ]; then echo "  SKIP (missing): $p"; continue; fi
  log="$(mktemp)"
  if EIGS_JIT_OFF=1 $VG_TMO "${VG[@]}" "$BIN" "$f" </dev/null >"$log" 2>&1; then
    echo "  PASS: $p"; pass=$((pass+1))
  else
    echo "  FAIL: $p — Valgrind reported errors:"
    grep -iE 'Invalid (read|write|free)|uninitialised|uninitialized|definitely lost|indirectly lost|Conditional jump|Use of uninitialised|Process terminating' "$log" | head -6
    fail=$((fail+1))
  fi
  rm -f "$log"
done

echo "============================================"
if [ "$FULL" -eq 1 ]; then
  echo "  Valgrind FULL corpus: $pass passed, $fail failed (of $((pass+fail)))"
else
  echo "  Valgrind smoke: $pass passed, $fail failed (of $((pass+fail)))"
fi
echo "============================================"
# A run that valgrinded NOTHING must not report success: "0 failed" and "never
# ran" are the same line otherwise.
if [ "$((pass+fail))" -eq 0 ]; then
  echo "FAIL: valgrind examined zero programs — that is a broken harness, not a clean run"
  exit 1
fi
[ "$fail" -eq 0 ]
