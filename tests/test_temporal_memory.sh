#!/bin/bash
# Bounded-history gate for the temporal interrogatives (#827).
#
# WHAT BROKE: the per-name assignment history that backs `prev of x`,
# `<kw> is x at <line>` and `state_at` was append-only with no cap, and it
# held a REFERENCE to every assigned value. Any long-running program that so
# much as mentioned `prev of` grew linearly forever — and the whole-program
# compile flag armed it even when the `prev of` sat in a function that was
# never called. It froze a 4 GB box: ~20 minutes of thrash with no OOM kill,
# power-cycle to recover.
#
# WHAT THIS MEASURES: peak RSS of the same program at two iteration counts a
# factor of 8 apart. Both a CEILING and FLATNESS are asserted — a ceiling
# alone would pass a slow leak, and flatness alone would pass a program that
# allocated a fixed enormous block. `/usr/bin/time -f %M` under a `ulimit -v`
# cap so a regression on a small box fails the test instead of taking the box
# down with it.
#
# WHY NOT A SANITIZER: this is not a leak — every byte was reachable from the
# history table and correctly freed at exit. LeakSanitizer reported nothing
# for the whole life of the bug. Unbounded RETENTION is only visible to
# process-level memory accounting.
#
# THE FOUR PROGRAMS, and the defect each one covers:
#   base      no temporal query at all — the floor every other case must meet
#   dead      `prev of` inside a function that is NEVER CALLED (defect A:
#             arming was whole-program, so dead code taxed everything)
#   live      `prev of x` evaluated every iteration (defect B: legitimate use
#             was unbounded too — this is the half that freezes machines)
#   at_live   `what is x at <line>` — the backward-query form, which needs the
#             line-stamped history rather than just the depth-2 chain
#
# PLANTED-FAULT VALIDATION (#827): reverting the prune in prev_record_assign
# to the answer-preserving-but-weaker `> line` (keeping same-line duplicates)
# leaves every temporal answer correct and takes `live` from 2944 kB flat to
# 13952 kB / 90496 kB — this gate goes red, the semantic tests do not. That is
# the whole reason this file exists separately from test_temporal_pruning.eigs.
set -u

EIGS="${EIGS:-./eigenscript}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PASS=0
FAIL=0
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
bad()  { echo "  FAIL: $1${2:+ ($2)}"; FAIL=$((FAIL+1)); }

if ! [ -x /usr/bin/time ]; then
    echo "  SKIP: /usr/bin/time not available (peak RSS unmeasurable)"
    echo "TEMPORAL_MEM: 0 passed, 0 failed (skipped)"
    exit 0
fi

# MUST NOT run against a sanitizer build: ASan's redzones and quarantine grow
# RSS on their own, which would both raise the floor past the ceiling and
# manufacture growth between the two iteration counts. Same rationale as
# test_http_rss_growth.sh.
if grep -qa "__asan_init" "$EIGS" 2>/dev/null; then
    echo "  SKIP: sanitizer build — peak RSS is dominated by ASan overhead"
    echo "TEMPORAL_MEM: 0 passed, 0 failed (skipped)"
    exit 0
fi

cat > "$TMP/base.eigs" <<'EOF'
N is num of (env_get of "N")
x is 0
i is 0
loop while i < N:
    x is i * 1.5
    i is i + 1
print of "done"
EOF

# The `prev of` is in a function no call site reaches.
cat > "$TMP/dead.eigs" <<'EOF'
define never_called(v) as:
    return prev of v

N is num of (env_get of "N")
x is 0
i is 0
loop while i < N:
    x is i * 1.5
    i is i + 1
print of "done"
EOF

cat > "$TMP/live.eigs" <<'EOF'
N is num of (env_get of "N")
x is 0
i is 0
loop while i < N:
    x is i * 1.5
    p is prev of x
    i is i + 1
print of "done"
EOF

cat > "$TMP/at_live.eigs" <<'EOF'
N is num of (env_get of "N")
x is 0
i is 0
loop while i < N:
    x is i * 1.5
    i is i + 1
q is what is x at 5
print of "done"
EOF

N_SMALL=200000
N_BIG=1600000

# Peak RSS in KB, or empty on failure. The ulimit -v cap is the safety belt:
# a reverted fix hits it and dies instead of thrashing the box.
peak_kb() {
    local prog="$1" n="$2" out rc
    out=$( ulimit -v 1500000; N="$n" /usr/bin/time -f "PEAK_KB %M" \
               "$EIGS" "$prog" 2>&1 >/dev/null )
    rc=$?
    if [ $rc -ne 0 ]; then
        echo "" ; return 1
    fi
    echo "$out" | sed -n 's/^PEAK_KB \([0-9]*\)$/\1/p' | tail -1
}

BASE_BIG=$(peak_kb "$TMP/base.eigs" "$N_BIG")
if [ -z "$BASE_BIG" ]; then
    bad "baseline program did not run" "check $EIGS"
    echo "TEMPORAL_MEM: $PASS passed, $FAIL failed"
    exit 1
fi
echo "  baseline (no temporal query) at N=$N_BIG: ${BASE_BIG} kB"

# CEILING: the floor plus a generous allowance. The bounded history is a
# handful of entries per name, so every case should land ON the baseline; 4x
# the baseline leaves room for allocator noise while sitting far below the
# pre-fix numbers (dead 53120 kB, live 203008 kB at this N).
CEIL=$(( BASE_BIG * 4 ))
# FLATNESS: peak must not grow with iteration count. Pre-fix, an 8x iteration
# increase multiplied peak RSS ~7x; bounded, the two are identical.
SLOP=$(( BASE_BIG / 2 ))

for prog in dead live at_live; do
    SMALL=$(peak_kb "$TMP/$prog.eigs" "$N_SMALL")
    BIG=$(peak_kb "$TMP/$prog.eigs" "$N_BIG")
    if [ -z "$SMALL" ] || [ -z "$BIG" ]; then
        bad "$prog: run failed" "likely the ulimit -v cap — unbounded retention"
        continue
    fi
    echo "  $prog: N=$N_SMALL ${SMALL} kB   N=$N_BIG ${BIG} kB"
    if [ "$BIG" -le "$CEIL" ]; then
        ok "$prog peak RSS under ceiling (${BIG} <= ${CEIL} kB)"
    else
        bad "$prog peak RSS over ceiling" "${BIG} kB > ${CEIL} kB"
    fi
    GROWTH=$(( BIG - SMALL ))
    if [ "$GROWTH" -le "$SLOP" ]; then
        ok "$prog peak RSS flat in iteration count (+${GROWTH} kB over 8x)"
    else
        bad "$prog peak RSS grows with iteration count" "+${GROWTH} kB over 8x, slop ${SLOP} kB"
    fi
done

echo "TEMPORAL_MEM: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
