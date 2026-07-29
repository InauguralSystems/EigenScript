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

# TWO consecutive measured batches, and the verdict is the SECOND one (#765).
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
# The discriminator is physical rather than statistical: **one-time warmup
# decays, a per-request leak does not.** A leak of N bytes/req leaks the same N
# in every subsequent batch, forever; arena warmup is spent and does not recur.
# So run two identical measured batches and judge the second. By then WARMUP +
# MEASURE requests have run, so any warmup tail is behind us — and a real leak is
# entirely unaffected by which batch you measure it in.
#
# This is why a slow or contended runner can no longer produce a phantom leak,
# and it does not loosen the threshold by a single byte. That matters: this is
# the only instrument that sees per-request leaks at all (LSan never runs in a
# signal-killed server), so a gate that cries wolf gets quietened, and then the
# class goes unwatched.

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

    local warm m1 m2 c growth1
    warm=$(batch_200s "http://127.0.0.1:$port$route?[1-$WARMUP]")
    a=$(rss_of "$srv_pid")
    m1=$(batch_200s "http://127.0.0.1:$port$route?[1-$MEASURE]")
    b=$(rss_of "$srv_pid")
    m2=$(batch_200s "http://127.0.0.1:$port$route?[1-$MEASURE]")
    c=$(rss_of "$srv_pid")

    kill "$srv_pid" 2>/dev/null || true
    wait "$srv_pid" 2>/dev/null || true
    rm -f "$srv_file" "/tmp/eigs_rss_srv_$$.log"

    if [ "$warm" -ne "$WARMUP" ] || [ "$m1" -ne "$MEASURE" ] || [ "$m2" -ne "$MEASURE" ]; then
        fail "$label INSTRUMENT: batch incomplete, RSS deltas are meaningless" \
             "warmup $warm/$WARMUP, batches $m1/$MEASURE and $m2/$MEASURE — not a leak measurement"
        return
    fi

    if [ -z "$a" ] || [ -z "$b" ] || [ -z "$c" ]; then
        fail "$label could not read VmRSS" "a='$a' b='$b' c='$c'"
        return
    fi
    growth1=$((b - a))
    growth=$((c - b))
    if [ "$growth" -le "$THRESHOLD_KB" ]; then
        # growth1 is reported only when it disagrees — that is the fingerprint of
        # a warmup that had not finished, and it is worth seeing in the log
        # before someone re-diagnoses it as an intermittent leak (#765).
        if [ "$growth1" -gt "$THRESHOLD_KB" ]; then
            ok "$label steady-state growth ${growth} kB over $MEASURE reqs (<= ${THRESHOLD_KB} kB; first batch ${growth1} kB = unfinished warmup, decayed as expected)"
        else
            ok "$label steady-state growth ${growth} kB over $MEASURE reqs (<= ${THRESHOLD_KB} kB)"
        fi
    else
        fail "$label leaked ${growth} kB over $MEASURE reqs" \
             "$(( growth * 1024 / MEASURE )) B/req; threshold ${THRESHOLD_KB} kB; first batch ${growth1} kB — growth did NOT decay, so this is a leak, not warmup"
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
    GROWTH1=$((B - A))
    GROWTH=$((C - B))
    if [ "$WARM" -ne "$WARMUP" ] || [ "$M1" -ne "$MEASURE" ] || [ "$M2" -ne "$MEASURE" ]; then
        fail "RSS2 authed route INSTRUMENT: batch incomplete, RSS deltas are meaningless" \
             "warmup $WARM/$WARMUP, batches $M1/$MEASURE and $M2/$MEASURE — not a leak measurement"
    elif [ "$GROWTH" -le "$THRESHOLD_KB" ]; then
        if [ "$GROWTH1" -gt "$THRESHOLD_KB" ]; then
            ok "RSS2 authed route steady-state growth ${GROWTH} kB over $MEASURE reqs (<= ${THRESHOLD_KB} kB; first batch ${GROWTH1} kB = unfinished warmup, decayed as expected)"
        else
            ok "RSS2 authed route steady-state growth ${GROWTH} kB over $MEASURE reqs (<= ${THRESHOLD_KB} kB)"
        fi
    else
        fail "RSS2 authed route leaked ${GROWTH} kB over $MEASURE reqs" \
             "$(( GROWTH * 1024 / MEASURE )) B/req; first batch ${GROWTH1} kB — growth did NOT decay, so this is a leak, not warmup"
    fi
else
    fail "RSS2 authed route did not come up" "port $PORT_A"
fi
kill "$AUTH_PID" 2>/dev/null || true
wait "$AUTH_PID" 2>/dev/null || true
rm -f "$AUTH_SRV" "/tmp/eigs_rss_auth_$$.log"

echo "HTTP_RSS: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
