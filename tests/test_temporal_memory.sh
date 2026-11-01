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
#
# SKIP POLICY (hq#58). The peak-RSS half needs GNU time, Linux /proc
# accounting, and an uninstrumented binary. The dev/CI image had no GNU time,
# so this half printed SKIP and exited 0 in every container lane and on macOS
# (only the release dry-run measured it), and the runner counted no skip. The
# same silent skip hid #1709's slot-rehearsal growth from its builder. Now a
# skip of the RSS half is allowed only when its key is listed, with a reason,
# in tests/temporal_memory_skip_allowlist.txt; any other skip is a FAIL. The
# four #868 window checks need none of the three and run first, everywhere.
set -u

EIGS="${EIGS:-./eigenscript}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# TMEM_GNU_TIME and TMEM_SKIP_ALLOWLIST exist for the skip-policy test
# (tests/sections/70d1-temporal-memory-skips-hq58.sh); nothing else sets them.
GNU_TIME="${TMEM_GNU_TIME:-/usr/bin/time}"
ALLOWLIST="${TMEM_SKIP_ALLOWLIST:-$(cd "$(dirname "$0")" && pwd)/temporal_memory_skip_allowlist.txt}"

PASS=0
FAIL=0
SKIPPED=0
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
bad()  { echo "  FAIL: $1${2:+ ($2)}"; FAIL=$((FAIL+1)); }
summary() { echo "TEMPORAL_MEM: $PASS passed, $FAIL failed, $SKIPPED skipped"; }

# ---- #868: the window boundary. No GNU time, /proc or uninstrumented binary
# needed, so these run before the RSS probes, on every platform and build.
#
# The ring is bounded, so an old-enough ordinal is genuinely gone. It must NOT
# come back as null: null already means "that assignment has not happened",
# and answering an evicted ordinal the same way turns a dropped fact into a
# confident wrong answer. Evicted raises; past-the-end stays null.
cat > "$TMP/evict.eigs" <<'EOF'
x is 0
i is 0
loop while i < 1000:
    x is i
    i is i + 1
print of ("newest " + (str of (what is x when 1001)))
print of ("oldest-retained-ok " + (str of (what is x when 900)))
print of ("past-end " + (str of (what is x when 5000)))
print of ("evicted " + (str of (what is x when 5)))
EOF

EV_OUT=$("$EIGS" "$TMP/evict.eigs" 2>&1); EV_RC=$?
if [ "$EV_RC" -ne 0 ] && echo "$EV_OUT" | grep -q "outside the retained window"; then
    ok "an evicted ordinal raises instead of answering null"
else
    bad "evicted ordinal did not raise" "rc=$EV_RC"
fi
if echo "$EV_OUT" | grep -q "^past-end null"; then
    ok "an ordinal past the end is null (has not happened yet)"
else
    bad "past-the-end ordinal was not null" "$(echo "$EV_OUT" | grep past-end)"
fi
if echo "$EV_OUT" | grep -q "^newest 999"; then
    ok "the newest ordinal is retained"
else
    bad "newest ordinal wrong" "$(echo "$EV_OUT" | grep newest)"
fi

# The window is configurable, and widening it makes the same ordinal readable —
# which is what proves the raise above was the BOUND and not a lookup bug.
EV2_OUT=$(EIGS_OCC_WINDOW=2000 "$EIGS" "$TMP/evict.eigs" 2>&1); EV2_RC=$?
if [ "$EV2_RC" -eq 0 ] && echo "$EV2_OUT" | grep -q "^evicted 3"; then
    ok "EIGS_OCC_WINDOW widens the retained window (same ordinal now reads 3)"
else
    bad "EIGS_OCC_WINDOW did not widen the window" "rc=$EV2_RC"
fi

# ---- the peak-RSS half: decline only with an allowlisted key.
# rss_unmeasurable <key> <reason>: an allowlisted key is a counted SKIP; any
# other key is a FAIL, because a skip nobody reviewed is the gate measuring
# nothing while the run stays green.
rss_unmeasurable() {
    local key="$1" why="$2" reason
    reason=$(awk -F '\t' -v k="$key" '$1 == k && NF >= 2 && $2 ~ /[^[:space:]]/ { print $2; exit }' \
        "$ALLOWLIST" 2>/dev/null)
    if [ -n "$reason" ]; then
        echo "  SKIP: peak-RSS half not measured: $why [allowlisted: $key]"
        SKIPPED=$((SKIPPED+1))
        summary
        [ "$FAIL" -eq 0 ]
        exit $?
    fi
    bad "peak-RSS half not measured: $why" "skip '$key' is not in $(basename "$ALLOWLIST"); a skip there needs a reviewed reason"
    summary
    exit 1
}

# Linux only: the thresholds below are calibrated against Linux VmRSS
# accounting, and `ulimit -v` (the safety belt that turns a regression into a
# failed test instead of a dead box) is a no-op on macOS. Same platform
# reasoning as test_http_rss_growth.sh. Probed first so that macOS reports the
# platform, not its BSD `time`.
if [ ! -r /proc/self/status ]; then
    rss_unmeasurable no-procfs "/proc not available (RSS accounting differs on this platform)"
fi

# MUST NOT run against a sanitizer build: ASan's redzones and quarantine grow
# RSS on their own, which would both raise the floor past the ceiling and
# manufacture growth between the two iteration counts. Same rationale as
# test_http_rss_growth.sh.
if grep -qa "__asan_init" "$EIGS" 2>/dev/null; then
    rss_unmeasurable sanitizer "sanitizer build — peak RSS is dominated by ASan overhead"
fi

# GNU time only. BSD/macOS `/usr/bin/time` has no `-f` and no `%M`, and its
# maxrss units differ, so probe the exact invocation rather than the platform
# name. On Linux this is a FAIL, not an allowlisted skip: the dev/CI image
# installs `time` (tools/install_release_test_dependencies.sh linux).
if ! "$GNU_TIME" -f "PEAK_KB %M" true >/dev/null 2>&1; then
    rss_unmeasurable no-gnu-time "GNU $GNU_TIME -f not available (peak RSS unmeasurable; install the 'time' package)"
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

# #868: the occurrence ring. `when <N>` is the one temporal form that must keep
# per-iteration state, so it is the form most able to reintroduce this bug —
# it deliberately survives the #827 pruning that bounds every case above. Its
# bound is a different mechanism (a fixed-size ring per armed name, not
# reachability), so it needs its own row in this gate.
cat > "$TMP/when_live.eigs" <<'EOF'
N is num of (env_get of "N")
x is 0
i is 0
loop while i < N:
    x is [i, i, i, i]
    i is i + 1
# Address the NEWEST ordinal, not a fixed small one: with N up at 1.6M a
# literal `when 3` is correctly evicted and raises, which this harness would
# read as the ulimit cap firing. The point here is retention, not lookup.
q is what is x when (when is x)
print of "done"
EOF

N_SMALL=200000
N_BIG=1600000

# Peak RSS in KB, or empty on failure. The ulimit -v cap is the safety belt:
# a reverted fix hits it and dies instead of thrashing the box.
peak_kb() {
    local prog="$1" n="$2" out rc
    out=$( ulimit -v 1500000 2>/dev/null || true
           N="$n" "$GNU_TIME" -f "PEAK_KB %M" "$EIGS" "$prog" 2>&1 >/dev/null )
    rc=$?
    if [ $rc -ne 0 ]; then
        echo "" ; return 1
    fi
    echo "$out" | sed -n 's/^PEAK_KB \([0-9]*\)$/\1/p' | tail -1
}

BASE_BIG=$(peak_kb "$TMP/base.eigs" "$N_BIG")
if [ -z "$BASE_BIG" ]; then
    bad "baseline program did not run" "check $EIGS"
    summary
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

for prog in dead live at_live when_live; do
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

summary
[ "$FAIL" -eq 0 ]
