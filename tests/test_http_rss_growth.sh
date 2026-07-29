#!/bin/bash
# Per-request leak gate for ext_http.c, by RSS growth (EigenScript #731, #752).
#
# WHY NOT A SANITIZER: LeakSanitizer reports from an atexit handler, and this
# server is torn down with `kill` against no SIGTERM handler, so LSan never runs
# in the server process. `make asan-http` compiles ext_http.c under ASan and
# catches use-after-free / overflow / UB — those report at the moment of the bug
# — but a per-request LEAK is invisible to it. #731 sat in the request path of
# `shared_incr` while the ASan suite reported 32/32 green. RSS growth is the
# instrument that works on a process that dies by signal.
#
#   RSS1  shared_incr: the counter path the builtin exists for. Leaked two
#         Values per call (a parsed JSON Value on both the success and the
#         type-mismatch path, plus the make_num handed to eigs_json_encode).
#   RSS2  http_route_authed with a shared-store auth source: leaked the parsed
#         `require_auth` Value on every authenticated request. Same class, found
#         while auditing the other eigs_json_parse_value call sites for #731.
#
# METHOD: measure between two STEADY-STATE checkpoints, never baseline-to-end.
# The first requests against a fresh server also carry one-time arena/heap
# warmup (+1.4 MB when #731 was measured), which is ~18x the real leak rate and
# would make any baseline-to-end threshold meaningless. So: warm up, sample A,
# drive a measured batch, sample B, and assert B-A.
#
# Requests are driven with curl's [1-N] globbing — one process, one connection,
# ~1.1s per 500 requests. The query string differs per request but the router
# matches on path, so every one hits the route under test.
set -u
TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC_DIR="$(cd "$TESTS_DIR/.." && pwd)/src"
EIGS="$SRC_DIR/eigenscript"

PASS=0
FAIL=0
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1${2:+ ($2)}"; FAIL=$((FAIL+1)); }

if ! command -v curl >/dev/null 2>&1; then
    echo "  SKIP: curl not available"
    echo "HTTP_RSS: 0 passed, 0 failed (skipped)"
    exit 0
fi

# VmRSS comes from procfs — Linux only. macOS CI legs skip rather than fail.
if [ ! -r /proc/self/status ]; then
    echo "  SKIP: /proc not available (VmRSS unreadable on this platform)"
    echo "HTTP_RSS: 0 passed, 0 failed (skipped)"
    exit 0
fi

# MUST NOT run against a sanitizer build. ASan's redzones, quarantine and
# allocator metadata make RSS climb on their own: the FIXED binary measures
# 0 kB growth built with `make http` and 1108 kB (567 B/req) built with
# `make asan-http`. That is instrument overhead, not a leak, and it would
# false-fail this gate in CI's asan-http step. RSS growth is only meaningful
# on a release build.
if grep -qa "__asan_init" "$EIGS" 2>/dev/null; then
    echo "  SKIP: sanitizer build — RSS growth is dominated by ASan overhead, not leaks"
    echo "HTTP_RSS: 0 passed, 0 failed (skipped)"
    exit 0
fi

WARMUP=1000     # discarded: absorbs arena/heap warmup
MEASURE=2000    # the batch B-A is measured over
# Pre-fix rates were ~160 B/req (RSS1) and ~136 B/req (RSS2), i.e. ~320 kB and
# ~270 kB over MEASURE. Post-fix both measure exactly 0 kB. 64 kB sits ~5x under
# the fault and well above page-granularity noise.
THRESHOLD_KB=64

rss_of() { awk '/^VmRSS/{print $2}' "/proc/$1/status" 2>/dev/null; }

# Drive a globbed batch and return the number of requests that answered 200.
# The count is load-bearing, not diagnostics: a batch that ends early (connection
# refused under the per-IP cap, dropped socket) silently shortens the interval a
# checkpoint bounds, and every number downstream becomes meaningless.
batch_200s() { # $1 = url with glob
    curl -s -o /dev/null -w '%{http_code}\n' "$1" 2>/dev/null | grep -c '^200$'
}

# THREE consecutive measured batches, and the verdict is their MEDIAN (#768).
#
# A single warmup-then-measure is only valid if the warmup actually reached
# steady state, and it cannot tell whether it did. When it doesn't, B-A
# re-absorbs the ~1.4 MB of one-time arena growth and reports it as a leak —
# forcing WARMUP=5 on a leak-free binary reproduces CI's exact figures to within
# ~1% on both checks (RSS1 2880 kB/1474 B-per-req vs 2852/1460; RSS2 1532/784 vs
# 1516/776). Whether the warmup was *truncated* or merely *too short for this
# machine* produces the identical signature, so counting requests is not enough:
# WARMUP=5 completes 5/5 and is still wrong.
#
# The discriminator is physical rather than statistical: **a one-off allocator
# step happens once, a per-request leak happens in every batch.** A leak of N
# bytes/req leaks the same N in every subsequent batch, forever.
#
# #765 implemented that as "judge the SECOND batch", on the assumption that the
# one-time cost is front-loaded and therefore already spent by then. It is not.
# Each connection is served by a fresh EigsState on its own thread
# (ext_http.c:~1400), so the first time two workers' lifetimes overlap, glibc
# allocates a second per-thread malloc arena and RSS steps by one worker's
# footprint — ~2.7 MB, once, after which arenas are recycled and RSS is flat
# forever. That overlap is governed by wall-clock scheduling, not by request
# count: measured on the dev box the step lands at request 400, 500, 600 and 700
# across four otherwise identical runs, and on a slower or contended CI runner it
# lands past 3000 — i.e. inside measured batch 2, which #765 made the verdict.
# That is exactly how run 30439602640 failed (2876 kB, "first batch 0 kB") while
# attempt 2 of the same commit passed, and it is not a leak: a soak of 24,000
# requests grows 0 kB after warmup, bounding any real per-request leak at
# <3 B/req, versus the 1472 B/req the gate reported.
#
# Note the fingerprint #765 could already have used: batch 1 was 0 kB. A leak of
# 1472 B/req cannot be absent from the immediately preceding identical batch. So
# take three batches and judge the median — one step, wherever it lands, moves
# at most one of the three, while a real leak moves all three and the median with
# them. This does not loosen the threshold by a single byte. That matters: this
# is the only instrument that sees per-request leaks at all (LSan never runs in a
# signal-killed server), so a gate that cries wolf gets quietened, and then the
# class goes unwatched.

median3() { printf '%s\n%s\n%s\n' "$1" "$2" "$3" | sort -n | sed -n 2p; }
max3()    { printf '%s\n%s\n%s\n' "$1" "$2" "$3" | sort -n | tail -1; }

# Verdict over three consecutive measured batches (kB each). Echoes the reason
# and returns 0 = clean, 1 = leak. Kept as a pure function of the three numbers
# so it can be self-tested against planted faults below without a server.
leak_verdict() {
    local g1="$1" g2="$2" g3="$3" med hi
    med=$(median3 "$g1" "$g2" "$g3")
    hi=$(max3 "$g1" "$g2" "$g3")
    if [ "$med" -gt "$THRESHOLD_KB" ]; then
        echo "leaked ${med} kB over ${MEASURE} reqs ($(( med * 1024 / MEASURE )) B/req; threshold ${THRESHOLD_KB} kB; batches ${g1}/${g2}/${g3} kB — the median batch grew, so this is a leak, not a one-off step)"
        return 1
    fi
    if [ "$hi" -gt "$THRESHOLD_KB" ]; then
        echo "steady-state growth ${med} kB over ${MEASURE} reqs (<= ${THRESHOLD_KB} kB; batches ${g1}/${g2}/${g3} kB — the ${hi} kB batch is a one-off allocator step, absorbed by the median)"
    else
        echo "steady-state growth ${med} kB over ${MEASURE} reqs (<= ${THRESHOLD_KB} kB; batches ${g1}/${g2}/${g3} kB)"
    fi
    return 0
}

# $1 = label, $2 = route path, $3 = server script body
run_growth_check() {
    local label="$1" route="$2" body="$3"
    local port srv_file srv_pid a b growth
    port=$(( (RANDOM % 10000) + 51000 ))
    srv_file=$(mktemp /tmp/eigs_rss_srv_XXXXXX.eigs)
    printf '%s\n' "$body" | sed "s/__PORT__/$port/" > "$srv_file"

    "$EIGS" "$srv_file" > "/tmp/eigs_rss_srv_$$.log" 2>&1 &
    srv_pid=$!

    # Wait for the listener rather than sleeping a fixed interval.
    local tries=0
    until curl -s -o /dev/null "http://127.0.0.1:$port$route" 2>/dev/null; do
        tries=$((tries + 1))
        if [ "$tries" -gt 100 ] || ! kill -0 "$srv_pid" 2>/dev/null; then
            fail "$label server never came up" "port $port"
            kill "$srv_pid" 2>/dev/null || true
            rm -f "$srv_file"
            return
        fi
        sleep 0.1
    done

    # `reason` and `rc` are declared here but assigned separately: `local x=$(f)`
    # would make $? the exit status of `local`, not of f, and the verdict would
    # always read as clean.
    local warm m1 m2 m3 d reason rc
    warm=$(batch_200s "http://127.0.0.1:$port$route?[1-$WARMUP]")
    a=$(rss_of "$srv_pid")
    m1=$(batch_200s "http://127.0.0.1:$port$route?[1-$MEASURE]")
    b=$(rss_of "$srv_pid")
    m2=$(batch_200s "http://127.0.0.1:$port$route?[1-$MEASURE]")
    c=$(rss_of "$srv_pid")
    m3=$(batch_200s "http://127.0.0.1:$port$route?[1-$MEASURE]")
    d=$(rss_of "$srv_pid")

    kill "$srv_pid" 2>/dev/null || true
    wait "$srv_pid" 2>/dev/null || true
    rm -f "$srv_file" "/tmp/eigs_rss_srv_$$.log"

    if [ "$warm" -ne "$WARMUP" ] || [ "$m1" -ne "$MEASURE" ] || [ "$m2" -ne "$MEASURE" ] \
       || [ "$m3" -ne "$MEASURE" ]; then
        fail "$label INSTRUMENT: batch incomplete, RSS deltas are meaningless" \
             "warmup $warm/$WARMUP, batches $m1/$MEASURE, $m2/$MEASURE and $m3/$MEASURE — not a leak measurement"
        return
    fi

    if [ -z "$a" ] || [ -z "$b" ] || [ -z "$c" ] || [ -z "$d" ]; then
        fail "$label could not read VmRSS" "a='$a' b='$b' c='$c' d='$d'"
        return
    fi
    reason=$(leak_verdict "$((b - a))" "$((c - b))" "$((d - c))"); rc=$?
    if [ "$rc" -eq 0 ]; then
        ok "$label $reason"
    else
        fail "$label $reason"
    fi
}

run_growth_check "RSS1 shared_incr" "/sinc" \
'r is http_route of ["GET", "/sinc", "code", "shared_incr of [\"counter\", 1]"]
s is http_serve of [__PORT__]'

# require_auth is seeded as a source string that evaluates to "" (= allow), so
# every /secret request takes the shared-store auth branch at ext_http.c:~1170.
PORT_A=$(( (RANDOM % 10000) + 52000 ))
AUTH_SRV=$(mktemp /tmp/eigs_rss_auth_XXXXXX.eigs)
cat > "$AUTH_SRV" <<EIGS
a is http_route of ["GET", "/asetup", "code", "shared_set of [\"require_auth\", \"\\\\\"\\\\\"\"]\n\"ok\""]
s2 is http_route_authed of ["GET", "/secret", "code", "\"top secret\""]
s is http_serve of [$PORT_A]
EIGS
"$EIGS" "$AUTH_SRV" > "/tmp/eigs_rss_auth_$$.log" 2>&1 &
AUTH_PID=$!
tries=0
until curl -s -o /dev/null "http://127.0.0.1:$PORT_A/asetup" 2>/dev/null; do
    tries=$((tries + 1))
    if [ "$tries" -gt 100 ] || ! kill -0 "$AUTH_PID" 2>/dev/null; then break; fi
    sleep 0.1
done

if curl -s "http://127.0.0.1:$PORT_A/asetup" | grep -q "ok" \
   && curl -s "http://127.0.0.1:$PORT_A/secret" | grep -q "top secret"; then
    WARM=$(batch_200s "http://127.0.0.1:$PORT_A/secret?[1-$WARMUP]")
    A=$(rss_of "$AUTH_PID")
    M1=$(batch_200s "http://127.0.0.1:$PORT_A/secret?[1-$MEASURE]")
    B=$(rss_of "$AUTH_PID")
    M2=$(batch_200s "http://127.0.0.1:$PORT_A/secret?[1-$MEASURE]")
    C=$(rss_of "$AUTH_PID")
    M3=$(batch_200s "http://127.0.0.1:$PORT_A/secret?[1-$MEASURE]")
    D=$(rss_of "$AUTH_PID")
    if [ "$WARM" -ne "$WARMUP" ] || [ "$M1" -ne "$MEASURE" ] || [ "$M2" -ne "$MEASURE" ] \
       || [ "$M3" -ne "$MEASURE" ]; then
        fail "RSS2 authed route INSTRUMENT: batch incomplete, RSS deltas are meaningless" \
             "warmup $WARM/$WARMUP, batches $M1/$MEASURE, $M2/$MEASURE and $M3/$MEASURE — not a leak measurement"
    else
        REASON=$(leak_verdict "$((B - A))" "$((C - B))" "$((D - C))"); RC=$?
        if [ "$RC" -eq 0 ]; then
            ok "RSS2 authed route $REASON"
        else
            fail "RSS2 authed route $REASON"
        fi
    fi
else
    fail "RSS2 authed route did not come up" "port $PORT_A"
fi
kill "$AUTH_PID" 2>/dev/null || true
wait "$AUTH_PID" 2>/dev/null || true
rm -f "$AUTH_SRV" "/tmp/eigs_rss_auth_$$.log"

# Self-test the verdict against planted faults, in BOTH directions. A gate is
# only evidence if a real fault turns it red and a known non-fault does not, and
# neither half can be checked by watching it pass on a healthy binary: #765
# shipped a rule that was green here and false-failed CI within a day. These are
# the real numbers — the two leak rates this gate was built to catch, and the
# one-off step that produced run 30439602640's phantom leak, in each of the three
# positions it can land in.
st_fail=0
expect_verdict() { # $1 = clean|leak, $2 = label, $3 $4 $5 = batch kB
    local want="$1" label="$2" got
    if leak_verdict "$3" "$4" "$5" >/dev/null 2>&1; then got=clean; else got=leak; fi
    if [ "$got" != "$want" ]; then
        echo "    verdict self-test: '$label' (${3}/${4}/${5} kB) expected $want, got $got"
        st_fail=$((st_fail + 1))
    fi
}
expect_verdict clean "flat, leak-free"                        0 0 0
expect_verdict clean "sub-threshold page jitter"              8 0 16
expect_verdict clean "arena step in batch 1"               2856 0 0
expect_verdict clean "arena step in batch 2 (run 30439602640)"  0 2876 0
expect_verdict clean "arena step in batch 3"                  0 0 2668
expect_verdict clean "RSS can fall as well as rise"       -1204 0 1204
expect_verdict leak  "#731 shared_incr, 160 B/req"          312 312 312
expect_verdict leak  "#752 authed route, 136 B/req"         265 265 265
expect_verdict leak  "a real leak WITH a step on top"       312 3000 312
expect_verdict leak  "leak at 1472 B/req sustained"        2876 2876 2876
if [ "$st_fail" -eq 0 ]; then
    ok "verdict self-test: 10 planted faults classified correctly (6 clean, 4 leak)"
else
    fail "verdict self-test: $st_fail planted fault(s) misclassified" \
         "the gate's decision rule is wrong — its verdicts above are not evidence"
fi

echo "HTTP_RSS: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
