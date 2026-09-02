#!/usr/bin/env bash
# [99y] Boolean env flags share ONE convention (#1032): non-empty and not
# "0" enables; "0", empty, and unset disable. Before this, jit.c read
# EIGS_JIT_OFF by PRESENCE, so EIGS_JIT_OFF=0 turned the JIT off -- the
# documented "off" spelling doing the opposite -- and tools/jit_diff.sh's
# first version compared the interpreter to itself for that reason.
# Oracle: EIGS_JIT_STATS=1 prints a `compiled=N` line to stderr when the
# JIT compiled anything. A planted revert to presence-testing fails check 2.
set -u
TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
EIGS="$TESTS_DIR/../src/eigenscript"
PROG="$TESTS_DIR/bench_idxset.eigs"
compiled() { env "$@" EIGS_JIT_STATS=1 "$EIGS" "$PROG" 2>&1 >/dev/null | grep -o 'compiled=[0-9]*' | head -1; }
c_on=$(compiled -u EIGS_JIT_OFF)
c_zero=$(compiled EIGS_JIT_OFF=0)
c_empty=$(compiled EIGS_JIT_OFF=)
c_off=$(compiled EIGS_JIT_OFF=1)
# macOS arm64 is interpreter-only (the ARM64 JIT is unbuilt), so the three
# JIT_OFF checks cannot discriminate there: name that and skip them, but
# only on that platform -- anywhere else compiled=0 is a real failure.
case "$c_on" in
  compiled=0|"")
    case "$(uname -m)" in
      arm64|aarch64) echo "PASS: JIT_OFF checks not applicable on $(uname -s) $(uname -m) (interpreter-only: $c_on)"; c_on="";;
      *) echo "FAIL: the JIT compiled nothing with the flag unset ($c_on) -- the probe program is not JIT-shaped, checks below are vacuous";;
    esac;;
  *) echo "PASS: JIT on when EIGS_JIT_OFF is unset ($c_on)";;
esac
if [ -n "$c_on" ]; then
if [ "$c_zero" = "$c_on" ] && [ -n "$c_on" ]; then echo "PASS: EIGS_JIT_OFF=0 leaves the JIT on ($c_zero)"; else echo "FAIL: EIGS_JIT_OFF=0 changed the JIT ($c_zero vs $c_on) -- presence-testing is back"; fi
if [ "$c_empty" = "$c_on" ] && [ -n "$c_on" ]; then echo "PASS: EIGS_JIT_OFF= (empty) leaves the JIT on"; else echo "FAIL: EIGS_JIT_OFF= (empty) changed the JIT ($c_empty vs $c_on)"; fi
# the stats line still prints with the JIT off -- it reports compiled=0
case "$c_off" in ""|compiled=0) echo "PASS: EIGS_JIT_OFF=1 disables the JIT (${c_off:-no stats line})";; *) echo "FAIL: EIGS_JIT_OFF=1 did not disable the JIT ($c_off)";; esac
fi
# the stats flag itself follows the convention: =0 prints nothing
s_zero=$(env EIGS_JIT_STATS=0 "$EIGS" "$PROG" 2>&1 >/dev/null | grep -c 'compiled=')
if [ "$s_zero" = "0" ]; then echo "PASS: EIGS_JIT_STATS=0 prints no stats"; else echo "FAIL: EIGS_JIT_STATS=0 printed stats"; fi
