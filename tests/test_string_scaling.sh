#!/usr/bin/env bash
# test_string_scaling.sh -- string operations must scale LINEARLY in the
# string's length, not quadratically.
#
# EigenScript#1183: `VAL_STR` carries a bare `char *` and no length, while
# every other sequence type in the same union caches one (lists `count`,
# buffers and text_builder `len`). So each `s[i]` calls strlen(3) on the whole
# string -- indexing is O(n) and a character scan is O(n^2). Measured on main
# before the fix: 20k chars 30.8 ms, 40k 121.9, 80k 436.3, 160k 1581.5, i.e.
# ~4x per doubling. 39% of ouroboros's runtime (a LEXER, which scans source
# text character by character) was __strlen_sse2.
#
#   bash tests/test_string_scaling.sh            # the gate
#   bash tests/test_string_scaling.sh --selftest # prove it can FAIL
#
# WHY A RATIO AND NOT A DURATION: a wall-clock budget is a claim about the
# MACHINE, not the mechanism (mechanical-gates 120) -- it passes on a fast box
# and flakes on a loaded one. A doubling RATIO is a claim about the algorithm's
# shape and is stable across machines: linear work ~2x per doubling, quadratic
# ~4x. The threshold sits between them with room for constant-factor noise.
#
# WHAT THIS GATE DOES NOT COVER: it measures the SHAPE of the growth, not the
# absolute speed, and it measures only the operations exercised below (index,
# `len of`, concat-in-loop is deliberately excluded -- see the note at build
# time). A change that makes every operation uniformly 10x slower passes this
# gate; the fleet bench and bench_perf are where absolute cost is judged.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
EIGS="${EIGS:-$ROOT/src/eigenscript}"
SELFTEST=0
[ "${1:-}" = "--selftest" ] && SELFTEST=1

# Ratio a DOUBLING may reach before the growth is called superlinear.
# linear = 2.0, quadratic = 4.0. 2.60 leaves headroom for constant factors
# and cache effects without admitting the quadratic shape.
MAX_RATIO=2.60
# Lengths: large enough that the O(n^2) term dominates start-up, small enough
# that a healthy build finishes in well under a second per point.
LENS="20000 40000 80000"
# Repetitions per length, median taken. ONE sample per point flakes against
# the threshold: the same patched binary produced 1.94 2.05 2.07 2.01 2.59
# and 2.93 on an idle box. Each point costs ~10-70 ms, so this is cheap.
REPS="${REPS:-5}"

fail() { echo "string-scaling: FAIL: $*" >&2; exit 1; }

if [ "$SELFTEST" = 1 ]; then
    # This gate's planted fault needs no synthetic mutant: the tree BEFORE the
    # fix is the fault. The selftest asserts the threshold actually separates
    # the two shapes, using the measured pre-fix numbers from #1183 and a
    # synthetic linear series -- so a threshold edited up to swallow a
    # regression fails here.
    echo "== string-scaling selftest =="
    bad=0; run=0
    chk() { run=$((run+1)); if [ "$2" = "$3" ]; then echo "   ok   $1"; else echo "   MISS $1 (got $2 want $3)"; bad=$((bad+1)); fi; }

    # Quadratic shape, measured on main at #1183: must be REJECTED.
    q=$(awk -v m="$MAX_RATIO" 'BEGIN{
        split("30.8 121.9 436.3 1581.5", t, " "); w=0
        for (i=2; i<=4; i++) { r=t[i]/t[i-1]; if (r>w) w=r }
        print (w > m+0) ? "reject" : "accept" }')
    chk "the measured PRE-FIX (quadratic) series is rejected" "$q" "reject"

    # Linear shape with a 30% constant-factor wobble: must be ACCEPTED.
    l=$(awk -v m="$MAX_RATIO" 'BEGIN{
        split("10.0 21.0 40.0 84.0", t, " "); w=0
        for (i=2; i<=4; i++) { r=t[i]/t[i-1]; if (r>w) w=r }
        print (w > m+0) ? "reject" : "accept" }')
    chk "a linear series with constant-factor noise is accepted" "$l" "accept"

    # The threshold must sit strictly between the two shapes.
    chk "threshold is between linear and quadratic" \
        "$(awk -v m="$MAX_RATIO" 'BEGIN{ print (m+0 > 2.2 && m+0 < 3.5) ? "yes" : "no" }')" "yes"

fi   # stage two runs after the functions it exercises

[ -x "$EIGS" ] || fail "no runtime at $EIGS (set EIGS=)"

# BSD mktemp has no -p and its -t takes a prefix, not a template, so a full
# path template is the only portable spelling (macOS runners ship BSD
# userland; this cost three CI rounds on a sibling gate).
WORK=$(mktemp -d "$ROOT/build/strscale.XXXXXX") || fail "cannot make a scratch dir"
trap 'rm -rf "$WORK"' EXIT

# The probe times the SCAN ONLY. Building the string with `s is s + base` is
# quadratic on its own (concat), and the first version of this measurement had
# it inside the timed region -- it would have measured concatenation and called
# it indexing.
cat > "$WORK/scan.eigs" <<'EOF'
define scan(s, n) as:
    i is 0
    acc is 0
    loop while i < n:
        c is s[i]
        acc is acc + 1
        i is i + 1
    return acc

argv is args of null
target is floor of (num of argv[0])
base is "abcdefghij"
s is ""
k is 0
loop while k < (target / 10):
    s is s + base
    k is k + 1
n is len of s
t0 is monotonic_ns of null
r is scan of [s, n]
t1 is monotonic_ns of null
if r != n:
    print of f"BAD scan returned {r} want {n}"
print of f"{n} {(t1 - t0) / 1000000}"
EOF

# macOS runners ship no coreutils `timeout`; a suite child that calls it bare
# dies rc 127 there (PR #1077). Probe the way tests/run_all_tests.sh does, and
# accept running unbounded rather than failing on a missing tool.
if command -v timeout >/dev/null 2>&1; then EIGS_TMO="timeout 300"
elif command -v gtimeout >/dev/null 2>&1; then EIGS_TMO="gtimeout 300"
else EIGS_TMO=""; fi

measure_once() {  # $1 = target length -> prints "len ms"
    # stdout and stderr are kept SEPARATE, and the reading is matched by SHAPE
    # rather than taken as "the last line". Bought by a blind critic, round 2:
    # the probe merged 2>&1 and used `tail -1`, so any stray diagnostic on
    # stderr became the measurement. With EIGS_JIT_STATS=1 the runtime's
    # `[jit] scanned=... compiled=...` line landed last, `ms` parsed as 0, the
    # ratio collapsed to 0.00, and the gate reported PASS **on the unfixed,
    # quadratic binary** — a false green, which is worse than no gate.
    #   EIGS_JIT_STATS=1 EIGS=<old binary> bash tests/test_string_scaling.sh
    #   -> worst doubling ratio: 0.00  PASS      (before this fix)
    local out err rc line
    err="$WORK/err.$1.$$"
    # SANITIZED ENVIRONMENT. The gate must control what it measures: an
    # inherited EIGS_* variable can change what the runtime does or prints.
    # A blind critic passed the UNFIXED binary at ratio 1.00 by exporting
    # EIGS_REPLAY with a 10-character tape — replay supplied argv and both
    # clock readings, so every "sample" returned the same recorded numbers.
    out=$( for __v in $(env | sed -n 's/^\(EIGS_[A-Za-z0-9_]*\)=.*/\1/p'); do unset "$__v"; done
           EIGS_JIT_OFF=1 $EIGS_TMO "$EIGS" "$WORK/scan.eigs" "$1" 2>"$err" ); rc=$?
    if [ "$rc" != 0 ]; then
        echo "string-scaling: probe rc=$rc at len=$1" >&2
        echo "  stdout: $out" >&2; echo "  stderr: $(cat "$err" 2>/dev/null)" >&2
        rm -f "$err"; return 1
    fi
    case "$out" in *BAD*) echo "string-scaling: scan returned the wrong count: $out" >&2; rm -f "$err"; return 1 ;; esac
    # Exactly one line of the shape "<digits> <number>"; anything else is a
    # parse failure and a FAIL, never a silently-zero reading.
    line=$(printf '%s\n' "$out" | awk '/^[0-9]+ [0-9.eE+-]+$/ { n++; last=$0 } END { if (n==1) print last }')
    if [ -z "$line" ]; then
        echo "string-scaling: could not parse a single 'len ms' line at len=$1" >&2
        echo "  stdout was: $out" >&2
        rm -f "$err"; return 1
    fi
    # VALIDATE THE VALUES, not just the shape. Matching `<digits> <number-ish>`
    # accepted every one of these from a blind critic's stubs, each of which
    # made the gate report PASS on a binary that is still quadratic:
    #   "20000 e"    -- `e` matches the number character class
    #   "20000 -1"   -- negative time
    #   "20000 0"    -- zero time (ratios become 0/0 or 0)
    #   "10 1"       -- a reading for a DIFFERENT length than was requested
    # The length the probe reports must be the length it was ASKED for, and the
    # time must be a finite number strictly greater than zero. This one check
    # closes all four, and also the EIGS_REPLAY fault above, whose tape reports
    # length 10 for every requested size.
    local got_len got_ms
    got_len=${line%% *}; got_ms=${line##* }
    if [ "$got_len" != "$1" ]; then
        echo "string-scaling: probe reported length $got_len but was asked for $1" >&2
        echo "  (a reading for a different length is not a measurement of this one)" >&2
        rm -f "$err"; return 1
    fi
    if ! awk -v m="$got_ms" 'BEGIN{ exit !(m+0 > 0 && m+0 < 1e12 && m ~ /^[0-9]+([.][0-9]+)?([eE][-+]?[0-9]+)?$/) }'; then
        echo "string-scaling: probe reported a non-positive or malformed time: '$got_ms' at len=$1" >&2
        rm -f "$err"; return 1
    fi
    rm -f "$err"
    printf '%s\n' "$line"
}

measure() {  # $1 = target length -> prints "len median_ms" over REPS samples
    local i line len ms samples=""
    for i in $(seq 1 "$REPS"); do
        line=$(measure_once "$1") || return 1
        len=${line%% *}; ms=${line##* }
        samples="$samples$ms\n"
    done
    printf "%s %s\n" "$len" "$(printf "$samples" | sort -n | awk '{a[NR]=$1} END{print a[int((NR+1)/2)]}')"
}

run_gate() {
    local prev_len=0 prev_ms=0 worst=0 rows=0 line len ms ratio
    echo "  len        scan_ms    ratio_vs_half"
    for L in $LENS; do
        line=$(measure "$L") || return 1
        len=${line%% *}; ms=${line##* }
        rows=$((rows+1))
        if [ "$prev_ms" != 0 ]; then
            ratio=$(awk -v a="$ms" -v b="$prev_ms" 'BEGIN{ if (b+0<=0) print "nan"; else printf "%.2f", a/b }')
            printf "  %-10s %-10s %s\n" "$len" "$ms" "$ratio"
            worst=$(awk -v w="$worst" -v r="$ratio" 'BEGIN{ printf "%.2f", (r+0>w+0)?r:w }')
        else
            printf "  %-10s %-10s %s\n" "$len" "$ms" "-"
        fi
        prev_len=$len; prev_ms=$ms
    done
    # A run that compared nothing is a FAIL, never a pass: with one row there
    # is no ratio and the gate would print a clean table having tested nothing
    # (mechanical-gates 121).
    [ "$rows" -ge 3 ] || { echo "string-scaling: examined $rows lengths, need >= 3" >&2; return 1; }
    echo "$worst"
}

if [ "$SELFTEST" = 1 ]; then
    # The reading must come from the program's STDOUT and must be matched by
    # SHAPE. Planted against a stub "runtime" rather than a real binary, so
    # these cases need no build and run in milliseconds.
    STUB_DIR=$(mktemp -d "${TMPDIR:-/tmp}/strscale-stub.XXXXXX")
    # (a) a diagnostic on stderr must NOT become the measurement. This is the
    #     defect a blind critic found: EIGS_JIT_STATS=1 put `[jit] scanned=...`
    #     last, the merged-stderr `tail -1` read it as the timing, the ratio
    #     collapsed to 0.00, and the gate PASSED the unfixed quadratic binary.
    cat > "$STUB_DIR/noisy" <<'STUB'
#!/bin/sh
echo "[jit] scanned=9 compiled=9 cache_used=1234" >&2
echo "20000 5.0"
STUB
    # (b) two reading-shaped lines is ambiguous and must be refused, never
    #     silently resolved by taking one of them.
    cat > "$STUB_DIR/ambiguous" <<'STUB'
#!/bin/sh
echo "20000 5.0"
echo "20000 9.0"
STUB
    chmod +x "$STUB_DIR/noisy" "$STUB_DIR/ambiguous"
    WORK="$STUB_DIR"; : > "$WORK/scan.eigs"
    EIGS_TMO=""
    EIGS="$STUB_DIR/noisy";     a=$(measure_once 20000 2>/dev/null)
    chk "a stderr diagnostic does not become the reading" "$a" "20000 5.0"
    EIGS="$STUB_DIR/ambiguous"; measure_once 20000 >/dev/null 2>&1
    chk "two reading-shaped lines are refused" "$?" "1"

    # VALUES, not just shape. Each of these made the gate report PASS on a
    # still-quadratic binary until the values were validated (blind critic,
    # round 3). The stub echoes whatever reading it is told to.
    for case in "20000 e:malformed" "20000 -1:negative" "20000 0:zero" "10 1:wrong-length"; do
        reading=${case%%:*}; name=${case##*:}
        printf '#!/bin/sh\necho "%s"\n' "$reading" > "$STUB_DIR/v"; chmod +x "$STUB_DIR/v"
        EIGS="$STUB_DIR/v"; measure_once 20000 >/dev/null 2>&1
        chk "a $name reading is refused" "$?" "1"
    done

    # A reading for the CORRECT length with a sane time is still accepted, so
    # the four rows above are rejecting the fault and not simply everything.
    printf '#!/bin/sh\necho "20000 5.0"\n' > "$STUB_DIR/v"; chmod +x "$STUB_DIR/v"
    EIGS="$STUB_DIR/v"; g=$(measure_once 20000 2>/dev/null)
    chk "an honest reading is still accepted" "$g" "20000 5.0"

    # The probe's environment is the GATE's to control: an inherited EIGS_*
    # must not reach it. The stub reports which branch it took.
    cat > "$STUB_DIR/envcheck" <<'STUB'
#!/bin/sh
if [ -n "${EIGS_REPLAY:-}" ]; then echo "10 1.0"; else echo "$2 5.0"; fi
STUB
    chmod +x "$STUB_DIR/envcheck"
    EIGS="$STUB_DIR/envcheck"; g=$(EIGS_REPLAY=/some/tape measure_once 20000 2>/dev/null)
    chk "an inherited EIGS_* does not reach the probe" "$g" "20000 5.0"
    rm -rf "$STUB_DIR"

    echo "== selftest $run run, $((run-bad)) passed, $bad failed =="
    [ "$bad" = 0 ] || exit 1
    exit 0
fi

echo "string-scaling: index/scan growth (EigenScript#1183)"
echo "runtime: $EIGS"
worst=$(run_gate) || fail "could not measure"
worst_ratio=$(echo "$worst" | tail -1)
verdict=$(awk -v w="$worst_ratio" -v m="$MAX_RATIO" 'BEGIN{ print (w+0 <= m+0) ? "PASS" : "FAIL" }')
echo "worst doubling ratio: $worst_ratio  (max $MAX_RATIO; linear ~2.0, quadratic ~4.0)"
if [ "$verdict" = PASS ]; then
    echo "PASS: string scan scales linearly"
else
    echo "FAIL: string scan is superlinear -- indexing is O(n), see EigenScript#1183"
    exit 1
fi
