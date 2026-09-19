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
# WHAT THIS GATE DOES NOT COVER, exactly, because the list was once wrong.
#
# It measures the SHAPE of the growth, not absolute speed, and for exactly ONE
# operation: **indexing, `s[i]`**, which is the only string operation in the
# timed loop. A change that makes every operation uniformly 10x slower passes
# here; the fleet bench and bench_perf judge absolute cost.
#
# `len of` IS NOT COVERED, and cannot be by this gate. The header used to
# claim it while the probe hoisted the call out of the loop, and a blind
# critic proved the consequence: reverting ONLY `builtin_len`'s
# `val_str_len(arg)` to `strlen(arg->data.strv.ptr)` -- half of the #1183
# regression, one line -- left this gate GREEN at 2.01. Putting the call in
# the loop condition does catch it (that build then reads 3.68 / 3.36), and
# was tried. It cannot stay: under EIGS_STR_LEN_CHECK `len of` is O(n) BY
# DESIGN, so the asan lanes went 2.56-2.98 against this 2.90 threshold --
# 2 false reds in 5 under load -- while the lowest unhealthy reading is 3.36.
# There is no threshold separating those, so the coverage and the sanitizer
# lanes cannot both be had here. Tracked as #1192, with the measurements.
#
# Concat is excluded too: building the string is quadratic on its own and
# would swamp the signal (see the note at build time).
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
EIGS="${EIGS:-$ROOT/src/eigenscript}"
SELFTEST=0
[ "${1:-}" = "--selftest" ] && SELFTEST=1

# Ratio a DOUBLING may reach before the growth is called superlinear.
# linear = 2.0, quadratic = 4.0, and the threshold is placed from MEASURED
# spreads rather than taste. Every figure below was taken on this box, the
# loaded ones under two CPU hogs on two cores:
#
#   release build, idle or loaded      1.80 - 2.06
#   asan build, loaded                 2.35 - 2.50   (see the note below)
#   the pre-#1185 binary               4.27 - 4.64
#   a mildly superlinear shape, n^1.58 3.00
#
# 2.90 sits 16% above the highest healthy reading and 32% below the lowest
# unhealthy one, and still rejects the n^1.58 shape -- which the selftest
# pins, so the number cannot drift upward without a row going red.
#
# THE ASAN ROW IS NOT NOISE. EIGS_STR_LEN_CHECK (asan, valgrind and poison --
# see the Makefile) re-derives every cached length with strlen(3) at every
# read, which is the O(n) index #1183 removed, so those builds really are
# nearer the quadratic shape and their readings are systematically higher.
# An earlier cut tried to DECLINE them, probing for the check by grepping the
# binary for the diagnostic string val_str_len() prints. A blind critic
# relinked the ordinary release objects with an object carrying that string
# in a non-allocated `.ident` section -- .text byte-for-byte identical -- and
# the gate skipped a perfectly good release binary, exit 0, reported as
# SKIPPED. Content presence is not evidence of compiled behaviour
# (mechanical-gates §135); the flag has no behavioural signature other than
# the timing this gate measures, so there is no sound cheap probe for it. A
# gate that can be talked into skipping is worse than one that measures a
# build it is mildly pessimistic about, because SKIPPED reads like good news.
# So every build is measured, and the band accommodates the honest spread of
# both. The RELEASE lane remains the authority for the shipped algorithm.
MAX_RATIO=2.90
# THE STATISTIC, and why it is this one (#1189, round 2).
#
# Three designs were measured against four subjects -- a healthy binary, a
# healthy binary under CPU contention, a quadratic binary, and an ADVERSARIAL
# one whose scan is quadratic on 85% of invocations and linear on the rest.
# P(gate says RED), 600 trials each:
#
#   design                          healthy  +load   quadratic  85% quadratic
#   block order, median of 5             0%    40%        100%           100%
#   block order, min of 5 + 3x confirm   0%     0%        100%            11%   <-- false GREEN
#   interleaved rounds, lower tertile    0%     0%        100%           100%
#
# The middle row was this gate's round-1 answer to the load flake, and a blind
# critic broke it: taking the MINIMUM selects the rare fast path, and
# confirming with MORE samples makes that selection likelier, so the
# confirmation was biased toward green by construction. It passed a subject
# that was quadratic 51 times out of 60.
#
# What works instead is structural, not statistical. Each ROUND measures every
# length back to back and yields its own doubling ratios, so a stall is
# confined to the round it landed in instead of contaminating a per-length
# aggregate that the ratio then divides. The verdict per doubling is the
# MEDIAN of those round ratios, which needs half the rounds inflated before it
# moves. Measured on this box under two CPU hogs: 0 false reds in 14 runs,
# every reading between 1.80 and 2.06 against a 2.60 threshold.
#
# AND THERE IS NO SECOND PASS. Round 2 re-measured before failing on a red,
# which sounds conservative and is not: a re-measurement is a second chance
# for any subject whose badness is intermittent, and the same critic walked
# three of them through it -- including one that was quadratic on five
# invocations in nine. A gate that re-rolls until it likes the answer has a
# different false-negative rate than the one it reports. One pass, with
# enough rounds in it, and the verdict stands.
ROUNDS="${ROUNDS:-15}"
# Which order statistic of the ROUNDS ratios is the verdict, as a quantile.
ROUND_RATIO_Q="${ROUND_RATIO_Q:-0.50}"
# Lengths: large enough that the O(n^2) term dominates start-up, small enough
# that a healthy build finishes in well under a second per point.
LENS="20000 40000 80000"

# AN INSTRUMENT FAILURE IS NOT A VERDICT, AND MUST NOT SHARE ITS EXIT CODE.
#
#   exit 1 = this gate MEASURED the scan and it is superlinear.
#   exit 2 = this gate could not measure at all (no runtime, no scratch dir,
#            an unparsable reading). Nothing is being claimed about the scan.
#
# Bought by a blind critic: both used to be exit 1, so a subject that made
# the gate die as "could not measure" was indistinguishable, by exit status,
# from one the gate had judged quadratic -- and a selftest row asserting
# "this must be RED" was satisfied by having broken the instrument. The suite
# section treats any nonzero as a failed section either way, so nothing
# downstream loosens; what changes is that a row can now require the verdict
# and never be handed a malfunction instead.
fail() { echo "string-scaling: FAIL: $*" >&2; exit 2; }

if [ "$SELFTEST" = 1 ]; then
    # This gate's planted fault needs no synthetic mutant: the tree BEFORE the
    # fix is the fault. The selftest asserts the threshold actually separates
    # the two shapes, using the measured pre-fix numbers from #1183 and a
    # synthetic linear series -- so a threshold edited up to swallow a
    # regression fails here.
    echo "== string-scaling selftest =="
    bad=0; run=0
    # AN EMPTY OBSERVATION IS NEVER A PASS, whatever it is compared against.
    #
    # Three consecutive blind-critic rounds found the same shape: a row that
    # passes while its subject never ran. The last one (#1197) compared two
    # md5sum digests, and with md5sum off PATH both sides were the empty
    # string -- equal, green, nothing measured. Every expectation in this
    # selftest is a non-empty literal, so an empty OBSERVED value can only
    # mean the subject, the tool that read it, or the plumbing between them
    # did not run. Refusing it here closes the class for every row at once
    # instead of one row per round (§121 at the assertion, not the
    # enumeration).
    chk() {
        run=$((run+1))
        if [ -z "$2" ]; then
            echo "   MISS $1 (observed NOTHING -- the subject or its reader did not run; wanted $3)"
            bad=$((bad+1))
        elif [ "$2" = "$3" ]; then
            echo "   ok   $1"
        else
            echo "   MISS $1 (got $2 want $3)"
            bad=$((bad+1))
        fi
    }

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

    # The threshold must sit strictly between the two shapes -- and the band
    # is NARROW on purpose. A blind critic widened MAX_RATIO from 2.60 to 3.40
    # and every row here still passed, because the old band admitted anything
    # under 3.5 and the pre-fix series it checks against is ~3.96. A threshold
    # that can be moved halfway to the quadratic shape without a test noticing
    # is not pinned (mechanical-gates §5).
    chk "threshold is between linear and quadratic" \
        "$(awk -v m="$MAX_RATIO" 'BEGIN{ print (m+0 > 2.2 && m+0 < 3.0) ? "yes" : "no" }')" "yes"

    # ...and a series that is only MILDLY superlinear must still be rejected.
    # 3.0 per doubling is n^1.58 -- far from quadratic, and exactly the region
    # a widened threshold would start admitting.
    chk "a mildly superlinear series (3.0x per doubling) is rejected" \
        "$(awk -v m="$MAX_RATIO" 'BEGIN{
            split("10.0 30.0 90.0 270.0", t, " "); w=0
            for (i=2; i<=4; i++) { r=t[i]/t[i-1]; if (r>w) w=r }
            print (w > m+0) ? "reject" : "accept" }')" "reject"

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
    # The bound is HOISTED, and that is a real limit of this gate rather than
    # an oversight -- see "WHAT THIS GATE DOES NOT COVER" in the header.
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

measure_round() {  # prints one "ratio ratio ..." line: each doubling, this round
    # ONE ROUND TOUCHES EVERY LENGTH, back to back. That is what confines a
    # scheduling stall to the round it landed in: a per-length aggregate taken
    # in block order lets a burst of contention land entirely on one point and
    # be divided straight into the verdict.
    local L line prev=0 ms out=""
    for L in $LENS; do
        line=$(measure_once "$L") || return 1
        ms=${line##* }
        if [ "$prev" != 0 ]; then
            out="$out $(awk -v a="$ms" -v b="$prev" 'BEGIN{ if (b+0<=0) print "nan"; else printf "%.4f", a/b }')"
        fi
        prev=$ms
    done
    printf '%s\n' "${out# }"
}

run_gate() {
    # Collect ROUNDS interleaved rounds, then take the MEDIAN of each
    # doubling's ratios (ROUND_RATIO_Q) and report the worst of those.
    local r rows="" line n_doublings=0
    echo "  round      ratios per doubling"
    for r in $(seq 1 "$ROUNDS"); do
        line=$(measure_round) || return 1
        printf "  %-10s %s\n" "$r" "$line"
        rows="$rows$line\n"
        n_doublings=$(printf '%s\n' "$line" | wc -w | tr -d ' ')
    done
    # A run that compared nothing is a FAIL, never a pass (mechanical-gates
    # 121): with fewer than two doublings there is no growth to judge, and
    # with no rounds there is nothing at all.
    [ "$n_doublings" -ge 2 ] || { echo "string-scaling: $n_doublings doubling(s) measured, need >= 2" >&2; return 1; }
    printf "$rows" | awk -v q="$ROUND_RATIO_Q" -v want="$ROUNDS" '
        { n++; for (i = 1; i <= NF; i++) v[i, n] = $i; cols = NF }
        END {
            if (n != want) { printf "string-scaling: collected %d round(s), expected %d\n", n, want > "/dev/stderr"; exit 1 }
            worst = 0
            for (i = 1; i <= cols; i++) {
                for (j = 1; j <= n; j++) a[j] = v[i, j]
                # insertion sort: n is ROUNDS, 15 by default
                for (j = 2; j <= n; j++) { t = a[j]; k = j - 1; while (k >= 1 && a[k] > t) { a[k+1] = a[k]; k-- } a[k+1] = t }
                idx = int(q * (n - 1) + 0.5) + 1
                if (a[idx] > worst) worst = a[idx]
            }
            printf "%.2f\n", worst
        }'
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

    # ---- #1189: the statistic, the structure, and the absence of a retry ---
    # Round 1 answered the load flake with the MINIMUM of each point's samples
    # plus a confirmation run of THREE TIMES the samples. A blind critic broke
    # it in one pass: the minimum selects a rare fast path and a bigger
    # confirmation makes that selection likelier, so the gate PASSED a subject
    # that was quadratic on 51 invocations out of 60. It also showed that a
    # one-sample confirmation cleared every row then present -- the design's
    # load-bearing property was pinned by nothing. These six rows pin the
    # replacement: interleaved rounds, the MEDIAN of the round ratios, and no
    # second pass at all.
    mkdir -p "$STUB_DIR"
    CNT="$STUB_DIR/calls"

    # NO ROW MANUFACTURES ITS OWN VERDICT. Every end-to-end row goes through
    # this one helper, which reports what the GATE said rather than what the
    # row concluded from an exit code.
    #
    # Bought three times. #1193: rows asserted rc alone. #1195: a broken
    # fixture made the gate exit 1 for "could not measure" and the rc-only
    # rows passed -- and combined with a padded production boundary, 23/23
    # again. #1198: a row wrote `chk "..." "ok" "ok"` inside an `if rc != 0`
    # branch, so it SYNTHESISED the literal `ok` from a bare nonzero exit;
    # deleting its subject passed, and combining that with median->tertile
    # gave 23/23 in the selftest AND 3/3 in the extracted [99zc]. Refusing an
    # empty observation in `chk` could not help, because the row never handed
    # `chk` the observation -- it handed it a literal.
    #
    # So: the observed value is always the gate's own words. `$1` is the stub,
    # `$2` is PASS or FAIL, `$3` (optional) the worst ratio it must report.
    gate_says() {
        # STREAMS SEPARATED, AND THE EXIT CODE READ EXACTLY.
        #
        # The first cut merged them with 2>&1 and searched the merged text.
        # A blind critic then wrote a fixture that exits 23 with no timing
        # reading at all but emits the verdict lines inside a multiline
        # diagnostic: the gate relays that diagnostic, dies as "could not
        # measure", and the helper read the relayed copy as a completed
        # superlinear verdict -- 23/23 with median->tertile also planted.
        # Exact copies of the real lines worked too, so anchoring alone
        # cannot fix it. This is #1186's defect (a diagnostic becoming the
        # reading) in the selftest rather than the probe.
        #
        # The gate prints its VERDICT on stdout and its DIAGNOSTICS on
        # stderr, so only stdout is searched; and `fail` now exits 2, so a
        # malfunction can never satisfy a row that requires rc 1.
        local out err rc want_line
        err="$STUB_DIR/gate_says.err.$$"
        out=$(EIGS="$STUB_DIR/$1" bash "$0" 2>"$err"); rc=$?
        rm -f "$err"
        case "$2" in
            PASS) want_line="^PASS: string scan scales linearly"
                  [ "$rc" = 0 ] || { printf 'rc=%s expected 0 (2 = the gate could not measure)\n' "$rc"; return; } ;;
            FAIL) want_line="^FAIL: string scan is superlinear"
                  [ "$rc" = 1 ] || { printf 'rc=%s expected 1 (2 = the gate could not measure)\n' "$rc"; return; } ;;
        esac
        if ! printf '%s\n' "$out" | grep -q "$want_line"; then
            printf 'no %s verdict line on STDOUT; last=%s\n' "$2" "$(printf '%s\n' "$out" | tail -1)"
            return
        fi
        if [ -n "${3:-}" ] && ! printf '%s\n' "$out" | grep -q "^worst doubling ratio: $3 "; then
            printf 'ratio was %s, expected %s\n' \
                   "$(printf '%s\n' "$out" | sed -n 's/^worst doubling ratio: \([^ ]*\) .*/\1/p' | tail -1)" "$3"
            return
        fi
        echo "$2"
    }

    # (i) the per-doubling verdict is the MEDIAN of the ROUND ratios, not a
    #     ratio of per-length aggregates and not an extreme. Fifteen rounds,
    #     five of them stalled 10x on the largest length: the median must read
    #     the clean 2.00, which a mean or a maximum could not.
    cat > "$STUB_DIR/stalled_rounds" <<STUB
#!/bin/sh
n=\$2
c=\$(cat "$CNT.\$n" 2>/dev/null || echo 0); c=\$((c+1)); echo \$c > "$CNT.\$n"
base=\$(awk -v n="\$n" 'BEGIN{ printf "%.4f", n/2000 }')
if [ "\$n" = 80000 ] && [ "\$c" -le 5 ]; then
    awk -v b="\$base" -v n="\$n" 'BEGIN{ printf "%s %.4f\n", n, b*10 }'
else
    echo "\$n \$base"
fi
STUB
    chmod +x "$STUB_DIR/stalled_rounds"
    rm -f "$CNT".*
    WORK="$STUB_DIR"; : > "$WORK/scan.eigs"; EIGS_TMO=""
    st_rounds="$ROUNDS"; ROUNDS=15
    EIGS="$STUB_DIR/stalled_rounds"; t=$(run_gate 2>/dev/null | tail -1)
    ROUNDS="$st_rounds"
    chk "the per-doubling verdict is the MEDIAN of the round ratios" "$t" "2.00"

    # (ii) ...and end to end through the real entry point, those same stalled
    #      rounds do not fail the gate.
    rm -f "$CNT".*
    chk "stalled rounds do not fail the gate, and it reads the clean 2.00" \
        "$(gate_says stalled_rounds PASS 2.00)" "PASS"

    # (iii) a quadratic series fails.
    cat > "$STUB_DIR/quadratic" <<'STUB'
#!/bin/sh
n=$2
awk -v n="$n" 'BEGIN{ printf "%s %.4f\n", n, (n/20000)*(n/20000)*10 }'
STUB
    chmod +x "$STUB_DIR/quadratic"
    chk "a quadratic series is RED at 4.00" "$(gate_says quadratic FAIL 4.00)" "FAIL"

    # (iv) THE CRITIC'S SUBJECT. Quadratic on four invocations in five, linear
    #      on the fifth -- the shape that walked through round 1's
    #      minimum-plus-bigger-confirmation, and the reason the statistic
    #      changed. It must be RED.
    cat > "$STUB_DIR/mostly_quadratic" <<STUB
#!/bin/sh
n=\$2
c=\$(cat "$CNT.mm.\$n" 2>/dev/null || echo 0); c=\$((c+1)); echo \$c > "$CNT.mm.\$n"
if [ "\$((c % 5))" = 0 ]; then
    awk -v n="\$n" 'BEGIN{ printf "%s %.4f\n", n, n/2000 }'
else
    awk -v n="\$n" 'BEGIN{ printf "%s %.4f\n", n, (n/20000)*(n/20000)*10 }'
fi
STUB
    chmod +x "$STUB_DIR/mostly_quadratic"
    rm -f "$CNT".mm.*
    chk "a runtime that is quadratic 4 invocations in 5 is still RED" \
        "$(gate_says mostly_quadratic FAIL)" "FAIL"

    # (v) THERE IS NO SECOND CHANCE. A red run measures exactly as much as a
    #     green one: ROUNDS x len(LENS) probe invocations, no more. Pinned by
    #     COUNTING, because the property is about how much was measured and no
    #     message can be trusted to describe that. Round 2's re-measurement
    #     would double this number, and a subject that is only sometimes bad
    #     escapes through exactly that door (mechanical-gates §116).
    cat > "$STUB_DIR/counting" <<STUB
#!/bin/sh
n=\$2
echo x >> "$CNT.total"
awk -v n="\$n" 'BEGIN{ printf "%s %.4f\n", n, (n/20000)*(n/20000)*10 }'
STUB
    chmod +x "$STUB_DIR/counting"
    rm -f "$CNT.total"
    EIGS="$STUB_DIR/counting" bash "$0" >/dev/null 2>&1
    n_calls=$(wc -l < "$CNT.total" 2>/dev/null | tr -d ' ')
    n_lens=$(printf '%s\n' $LENS | grep -c .)
    chk "a RED run measures no more than a green one -- there is no retry" \
        "$n_calls" "$((ROUNDS * n_lens))"

    # (vi) the rounds are INTERLEAVED, not blocked. This is the structural
    #      half of the fix -- it is what confines a stall to one round -- and
    #      nothing above would notice if the probe were driven in block order
    #      instead. The stub records the length of every call; the sequence
    #      must cycle through LENS, never repeat a length before the others.
    cat > "$STUB_DIR/ordering" <<STUB
#!/bin/sh
n=\$2
echo "\$n" >> "$CNT.order"
awk -v n="\$n" 'BEGIN{ printf "%s %.4f\n", n, n/2000 }'
STUB
    chmod +x "$STUB_DIR/ordering"
    rm -f "$CNT.order"
    EIGS="$STUB_DIR/ordering" bash "$0" >/dev/null 2>&1
    # COMPARED DIRECTLY, NOT THROUGH A HASH. The first cut ran both sides
    # through `md5sum`, and a blind critic removed md5sum from PATH: both
    # sides became the empty string, the row passed, and the subject had
    # never run -- 23/23 with a production block-order mutant in place
    # (#1197). A digest was only ever there to keep the failure message
    # short. The sequence is 45 tokens; compare it, and make the absent case
    # impossible to mistake for agreement: `want` is built from $LENS and can
    # never be empty, `got` says so in words when the file is missing.
    want_cycle=$(i=0; while [ "$i" -lt "$ROUNDS" ]; do printf '%s\n' $LENS; i=$((i+1)); done | tr '\n' ' ')
    got_cycle=$(tr '\n' ' ' < "$CNT.order" 2>/dev/null)
    chk "the rounds are INTERLEAVED: the probe cycles through the lengths" \
        "${got_cycle:-<the ordering subject never ran>}" "$want_cycle"
    # (vii) the MEDIAN specifically, not merely "a low order statistic". A
    #       blind critic mutated the median to the lower tertile and every
    #       row above still passed -- the choice was unpinned, and a tertile
    #       is exactly the kind of "a bit more robust" edit someone makes on
    #       a flaky morning. This subject is linear for 6 of its 15 rounds
    #       and quadratic for the other 9: the 8th-of-15 (median) reads
    #       quadratic and must go RED, while the 6th-of-15 (tertile) reads
    #       linear and would not.
    cat > "$STUB_DIR/six_linear_rounds" <<STUB
#!/bin/sh
n=\$2
c=\$(cat "$CNT.sl.\$n" 2>/dev/null || echo 0); c=\$((c+1)); echo \$c > "$CNT.sl.\$n"
if [ "\$c" -le 6 ]; then
    awk -v n="\$n" 'BEGIN{ printf "%s %.4f\n", n, n/2000 }'
else
    awk -v n="\$n" 'BEGIN{ printf "%s %.4f\n", n, (n/20000)*(n/20000)*10 }'
fi
STUB
    chmod +x "$STUB_DIR/six_linear_rounds"
    rm -f "$CNT".sl.*
    chk "9 quadratic rounds of 15 is RED at 4.00 -- the verdict is the MEDIAN, not a lower quantile" \
        "$(gate_says six_linear_rounds FAIL 4.00)" "FAIL"
    rm -f "$CNT".sl.*

    # (viii)-(x) THE PRODUCTION DECISION BOUNDARY, DRIVEN THROUGH THE REAL
    # ENTRY POINT. The two threshold rows near the top of this selftest
    # compute the comparison THEMSELVES in awk, so they say what the numbers
    # mean and nothing about what the gate does with them. A blind critic
    # showed the cost: changing only the production verdict expression from
    # `w+0 <= m+0` to `w+0 <= m+0.30` -- moving the real boundary to 3.20
    # while MAX_RATIO still reads 2.90 -- left all 19 rows green
    # (mechanical-gates §124: driving the internals, or a reimplementation of
    # them, proves nothing about the command CI runs). A second one-token
    # survivor set the aggregation's `cols = NF` to `cols = 1`, judging only
    # the first doubling while still collecting every length and satisfying
    # the invocation count. These three rows drive real subjects through
    # `bash "$0"` instead.
    mk_series() {  # $1 name, $2..$4 ms for 20k/40k/80k
        cat > "$STUB_DIR/$1" <<STUB
#!/bin/sh
case "\$2" in
    20000) echo "20000 $2" ;;
    40000) echo "40000 $3" ;;
    80000) echo "80000 $4" ;;
esac
STUB
        chmod +x "$STUB_DIR/$1"
    }
    # A NONZERO EXIT IS NOT THIS ROW PASSING (mechanical-gates §19). The first
    # cut of these three rows asserted rc alone, and a blind critic broke the
    # FIXTURE instead of the gate -- `case "$2"` to `case "$1"`, so the stub
    # matched on the script path rather than the length and emitted nothing.
    # The gate then exited 1 for "could not measure", every row passed, and
    # 23/23 held. Worse, combining that broken fixture with the +0.30
    # production-boundary mutant ALSO gave 23/23: a broken fixture hid exactly
    # the defect these rows exist to pin. So each row now requires the gate's
    # own superlinear verdict AND the ratio it should have computed -- which
    # also pins that the right doubling was judged.
    series_verdict() {  # $1 = stub name, $2 = the worst ratio it must report
        local out rc
        # Same provenance rule as gate_says: stdout only, rc exactly 1.
        local err="$STUB_DIR/series.err.$$"
        out=$(EIGS="$STUB_DIR/$1" bash "$0" 2>"$err"); rc=$?
        rm -f "$err"
        if [ "$rc" = 1 ] \
           && printf '%s\n' "$out" | grep -q "^FAIL: string scan is superlinear" \
           && printf '%s\n' "$out" | grep -q "^worst doubling ratio: $2 "; then
            echo ok
        else
            printf 'rc=%s last=%s\n' "$rc" "$(printf '%s\n' "$out" | tail -1)"
        fi
    }

    # A uniformly 3.0x series -- n^1.58, mildly superlinear -- must be RED at
    # the REAL boundary. This is what a widened MAX_RATIO or a padded verdict
    # expression lets through.
    mk_series mild 10 30 90
    chk "a 3.0x series is RED through the real entry point (the boundary, not a copy of it)" \
        "$(series_verdict mild 3.00)" "ok"

    # ...and the first doubling alone being bad is RED: 4.0 then 2.0.
    mk_series first_bad 10 40 80
    chk "a series bad on only the FIRST doubling is RED" "$(series_verdict first_bad 4.00)" "ok"

    # ...and so is the second alone: 2.0 then 4.0. This is the row that dies
    # if the aggregation stops looking at every doubling.
    mk_series second_bad 10 20 80
    chk "a series bad on only the SECOND doubling is RED" "$(series_verdict second_bad 4.00)" "ok"

    # (xi) the doubling FLOOR. With three lengths there are always two
    #      doublings, so the `>= 2` guard cannot bind on the shipped
    #      configuration and a critic lowered it to 1 with nothing noticing.
    #      It exists for the day someone shortens LENS, so the row shortens
    #      LENS: one doubling is not a growth curve and must be refused.
    st_lens="$LENS"; LENS="20000 40000"
    EIGS="$STUB_DIR/mild"; floor_out=$(run_gate 2>&1); floor_rc=$?
    LENS="$st_lens"
    # ...and refused FOR THAT REASON, not because the stub happened to break.
    if [ "$floor_rc" = 1 ] && printf '%s\n' "$floor_out" | grep -q "doubling(s) measured, need >= 2"; then
        floor_got=ok
    else
        floor_got="rc=$floor_rc last=$(printf '%s\n' "$floor_out" | tail -1)"
    fi
    chk "a LENS with only one doubling is REFUSED, and says why" "$floor_got" "ok"

    # (xii) A MALFUNCTION IS NOT A VERDICT. The subject here exits 23 with no
    #       reading at all while printing exact copies of the verdict and
    #       ratio lines -- the critic's spoof. The gate must die as "could
    #       not measure" (exit 2), and a row asking for a superlinear verdict
    #       must NOT be satisfied by it. Without both halves of the fix --
    #       stdout-only, and exit 2 for a malfunction -- this reads FAIL.
    cat > "$STUB_DIR/spoof" <<'STUB'
#!/bin/sh
echo "worst doubling ratio: 4.00  (max 2.90; linear ~2.0, quadratic ~4.0)"
echo "FAIL: string scan is superlinear -- indexing is O(n), see EigenScript#1183"
exit 23
STUB
    chmod +x "$STUB_DIR/spoof"
    chk "a subject that only PRINTS a verdict cannot supply one" \
        "$(gate_says spoof FAIL 4.00)" "rc=2 expected 1 (2 = the gate could not measure)"

    rm -f "$CNT" "$CNT".* "$CNT.total" "$CNT.order"

    echo "== selftest $run run, $((run-bad)) passed, $bad failed =="
    # A marker line, in the suite's own vocabulary. tests/run_all_tests.sh
    # wraps every `bash tests/test_*.sh` in an accounting function that reads
    # the child's output for a `PASS:`/`FAIL:`/`SKIP:` line and ledgers a child
    # that exited 0 while reporting nothing as VACUOUS (#988). Without this the
    # selftest -- whose own summary speaks a different dialect -- would enrol
    # as a silent child the first time the suite dispatched it.
    if [ "$bad" = 0 ]; then
        echo "PASS: string-scaling selftest ($run planted faults and controls, all correct)"
        exit 0
    fi
    echo "FAIL: string-scaling selftest: $bad of $run case(s) missed"
    exit 1
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
