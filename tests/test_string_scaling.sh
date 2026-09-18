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

    echo "== selftest $run run, $((run-bad)) passed, $bad failed =="
    [ "$bad" = 0 ] || exit 1
    exit 0
fi

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
    local out rc
    out=$( EIGS_JIT_OFF=1 $EIGS_TMO "$EIGS" "$WORK/scan.eigs" "$1" 2>&1 ); rc=$?
    [ "$rc" = 0 ] || { echo "string-scaling: probe rc=$rc at len=$1: $out" >&2; return 1; }
    case "$out" in *BAD*) echo "string-scaling: scan returned the wrong count: $out" >&2; return 1 ;; esac
    echo "$out" | tail -1
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
