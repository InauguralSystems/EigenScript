#!/bin/bash
# Per-request leak gate for ext_http.c (#731, #752; dual-metric under #770).
#
# WHY NOT A SANITIZER: LeakSanitizer reports from an atexit handler, and this
# server is torn down with `kill` against no SIGTERM handler, so LSan never runs
# in the server process. `make asan-http` compiles ext_http.c under ASan and
# catches use-after-free / overflow / UB — those report at the moment of the bug
# — but a per-request LEAK is invisible to it. #731 sat in the request path of
# `shared_incr` while the ASan suite reported 32/32 green. Process-level memory
# accounting is the instrument that works on a process that dies by signal.
#
# TWO METRICS, TWO COMPLEMENTARY BLIND SPOTS — the gate checks BOTH and fails
# if EITHER trips:
#
#   HEAP LEG — mallinfo2().uordblks (live arena bytes), sampled from the
#   server itself through the heap_inuse debug builtin over a /heap_inuse
#   route. SEES: the arena class — malloc'd Values and other sub-mmap-threshold
#   allocations. Immune to resident free-heap slack, which is what blinded the
#   old RSS-only gate: #770 showed the literal #731 shape (a dropped
#   val_decref in builtin_shared_incr, 72 heap B/req) passing the RSS gate at
#   0 kB over the whole 1000 + 3x2000 window, while uordblks shows ~144 kB in
#   the very first 2000-request batch. BLIND TO: non-arena memory — direct
#   mmap allocations (at/above glibc's dynamic mmap threshold) and thread
#   stacks. Measured: a 512 kB/req direct-mmap leak moves uordblks 0/0/0 kB.
#
#   RSS LEG — VmRSS from /proc. SEES: exactly the non-arena class the heap leg
#   misses — the same 512 kB/req direct-mmap leak is ~1 GB per batch of 2000
#   (measured 1024024/1024000/1024000 kB); a plain malloc(512kB) leak is also
#   caught because glibc's dynamic mmap threshold pulls those chunks back into
#   the arena. BLIND TO: small arena-class leaks inside the heap-slack
#   absorption window (the #770 case above: 72 B/req invisible for tens of
#   thousands of requests) — that is the heap leg's job, at a 64 kB threshold.
#
# Neither leg alone covers both classes; replacing one with the other trades
# one blind spot for another. The 72 B/req Value leak and the 512 kB/req mmap
# leak each trip exactly one leg and pass the other — the blind spots are
# disjoint, so the union is what ships.
#
#   RSS1  shared_incr: the counter path the builtin exists for. Leaked two
#         Values per call (a parsed JSON Value on both the success and the
#         type-mismatch path, plus the make_num handed to eigs_json_encode).
#   RSS2  http_route_authed with a shared-store auth source: leaked the parsed
#         `require_auth` Value on every authenticated request. Same class, found
#         while auditing the other eigs_json_parse_value call sites for #731.
#
# METHOD: measure between two STEADY-STATE checkpoints, never baseline-to-end.
# The first requests against a fresh server also carry one-time live
# allocations (arena warmup, ~1.4 MB when #731 was measured; ~20 MB of
# first-request allocator setup visible in uordblks), which dwarfs the real
# leak rate and would make any baseline-to-end threshold meaningless. So: warm
# up, sample A, drive a measured batch, sample B, and assert B-A.
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

# The heap leg comes from mallinfo2().uordblks via the heap_inuse builtin —
# glibc only. The RSS leg reads VmRSS from procfs — Linux only (macOS CI legs
# skip rather than fail). Between the two, this gate is glibc-on-Linux only.
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

WARMUP=1000     # discarded: absorbs one-time live allocations (arena/setup)
MEASURE=2000    # the batch B-A is measured over
# HEAP leg threshold. Pre-fix leak rates were ~160 B/req (RSS1) and ~136 B/req
# (RSS2) — i.e. ~320 kB and ~270 kB of LIVE heap per MEASURE batch, and
# uordblks sees every byte of them from the first batch on (no slack
# absorption). The #770 planted fault (a dropped val_decref, 72 B/req) shows
# ~144 kB per batch. Post-fix all measure ~0 kB. 64 kB sits ~2x under the
# smallest fault this gate must catch and well above checkpoint jitter
# (per-checkpoint samples are single integers read between batches, with no
# request in flight).
THRESHOLD_KB=64
# RSS leg threshold. This leg exists for the NON-ARENA class the heap leg
# cannot see (direct mmap, thread stacks); per-request leaks of that class are
# megabytes per batch (a 512 kB/req direct-mmap probe: ~1,024,000 kB per
# 2000-req batch), so the threshold's only job is to stay clear of the ONE-OFF
# per-thread-arena step: ~2.7 MB, largest observed 2876 kB (CI run
# 30439602640), reproduced on a clean binary as VmRSS 28/1396/0 kB while
# uordblks read 0/0/0. The median-of-three absorbs a step landing in ONE
# batch; 4096 kB adds ~1.4x headroom over the largest observed step in case
# steps land in TWO of the three batches, while any non-arena leak above
# ~2 B/req still trips it. Do NOT lower this to sharpen the RSS leg against
# arena-class leaks — that is the heap leg's job, at 64 kB.
RSS_THRESHOLD_KB=4096

rss_of() { awk '/^VmRSS/{print $2}' "/proc/$1/status" 2>/dev/null; }

# Live heap bytes, asked of the server itself through the heap_inuse debug
# builtin (mallinfo2().uordblks). Returns a bare integer body; "null" when
# the builtin has no allocator to report (non-glibc libc).
heap_of() { curl -s "http://127.0.0.1:$1/heap_inuse" 2>/dev/null | tr -d '[:space:]'; }

# The heap leg only exists on glibc. Detect a null/unavailable heap_inuse the
# same way the gate has always handled a missing platform surface: skip, do
# not fail. $1 = label, $2 = sample value, $3 = server pid to take down on
# the way out (skip must not orphan the server it started).
heap_sample_ok() {
    case "$2" in
        ''|*[!0-9]*)
            kill "$3" 2>/dev/null || true
            wait "$3" 2>/dev/null || true
            echo "  SKIP: heap_inuse returned '$2' — mallinfo2 unavailable (non-glibc libc); $1 not measured"
            echo "HTTP_RSS: 0 passed, 0 failed (skipped)"
            exit 0
            ;;
    esac
}

# Drive a globbed batch and return the number of requests that answered 200.
# The count is load-bearing, not diagnostics: a batch that ends early (connection
# refused under the per-IP cap, dropped socket) silently shortens the interval a
# checkpoint bounds, and every number downstream becomes meaningless.
batch_200s() { # $1 = url with glob
    curl -s -o /dev/null -w '%{http_code}\n' "$1" 2>/dev/null | grep -c '^200$'
}

# IDENTITY CHECK: prove the responding server is the one this run started.
# ext_http binds with SO_REUSEPORT (ext_http.c:296), so a stale server from an
# earlier run can still hold the gate's port and SPLIT its traffic — and
# batch_200s still counts full batches, because the orphan answers the same
# routes with 200. Every measurement downstream is then silently wrong (this
# exact failure corrupted a measurement of this gate once: flat RSS over
# 20,000-request batches against a leaking server, because half the traffic
# went to a leak-free orphan). The route table carries a per-run nonce only
# this run's server can answer; probe it 20 times — traffic splitting is
# probabilistic, so a single lucky answer proves nothing. A stale server from
# an older gate run has the route but the WRONG nonce; anything else 404s.
NONCE="eigs-gate-$$-$RANDOM$RANDOM"
check_identity() { # $1 = label, $2 = port, $3 = server pid
    local i body
    for i in $(seq 1 20); do
        body=$(curl -s "http://127.0.0.1:$2/gate_nonce" 2>/dev/null)
        if [ "$body" != "$NONCE" ]; then
            kill "$3" 2>/dev/null || true
            wait "$3" 2>/dev/null || true
            fail "$1 INSTRUMENT: /gate_nonce answered '$body', not this run's nonce" \
                 "port $2 is shared (SO_REUSEPORT) with a stale listener — kill it and re-run; any measurement would be split and meaningless"
            return 1
        fi
    done
    return 0
}

# THREE consecutive measured batches, and the verdict is their MEDIAN (#768).
#
# A single warmup-then-measure is only valid if the warmup actually reached
# steady state, and it cannot tell whether it did. When it doesn't, B-A
# re-absorbs the one-time live allocations of startup (arena warmup, ~1.4 MB
# when #731 was measured) and reports them as a leak — forcing WARMUP=5 on a
# leak-free binary reproduces CI's exact figures to within ~1% on both checks
# (RSS1 2880 kB/1474 B-per-req vs 2852/1460; RSS2 1532/784 vs 1516/776).
# Whether the warmup was *truncated* or merely *too short for this machine*
# produces the identical signature, so counting requests is not enough:
# WARMUP=5 completes 5/5 and is still wrong.
#
# The discriminator is physical rather than statistical: **one-off startup
# growth happens once, a per-request leak happens in every batch.** A leak of
# N bytes/req leaks the same N in every subsequent batch, forever.
#
# #765 implemented that as "judge the SECOND batch", on the assumption that the
# one-time cost is front-loaded and therefore already spent by then. It is not.
# Each connection is served by a fresh EigsState on its own thread
# (ext_http.c:~1400), and worker setup costs land when wall-clock scheduling
# overlaps two workers' lifetimes, not at a fixed request count: the classic
# case under the old RSS metric was glibc mmap'ing a second per-thread arena
# (~2.7 MB, once) — invisible to uordblks, since a fresh arena is FREE heap,
# but the live worker allocations that come with overlapping workers are not,
# and they land wherever the scheduler puts them: measured on the dev box the
# step lands at request 400, 500, 600 and 700 across four otherwise identical
# runs, and on a slower or contended CI runner it lands past 3000 — i.e.
# inside measured batch 2, which #765 made the verdict. That is exactly how
# run 30439602640 failed (2876 kB, "first batch 0 kB") while attempt 2 of the
# same commit passed, and it is not a leak: a soak of 24,000 requests grows 0
# kB after warmup, bounding any real per-request leak at <3 B/req, versus the
# 1472 B/req the gate reported.
#
# Note the fingerprint #765 could already have used: batch 1 was 0 kB. A leak
# of 1472 B/req cannot be absent from the immediately preceding identical
# batch. So take three batches and judge the median — one-off growth, wherever
# it lands, moves at most one of the three, while a real leak moves all three
# and the median with them. This does not loosen the threshold by a single
# byte. That matters: this is the only instrument that sees per-request leaks
# at all (LSan never runs in a signal-killed server), so a gate that cries
# wolf gets quietened, and then the class goes unwatched.

median3() { printf '%s\n%s\n%s\n' "$1" "$2" "$3" | sort -n | sed -n 2p; }
max3()    { printf '%s\n%s\n%s\n' "$1" "$2" "$3" | sort -n | tail -1; }

# Verdict over three consecutive measured batches (kB each), against the
# threshold of the leg being judged ($1). Echoes the reason and returns
# 0 = clean, 1 = leak. Kept as a pure function of the four numbers so it can
# be self-tested against planted faults below without a server.
leak_verdict() {
    local thr="$1" g1="$2" g2="$3" g3="$4" med hi
    med=$(median3 "$g1" "$g2" "$g3")
    hi=$(max3 "$g1" "$g2" "$g3")
    if [ "$med" -gt "$thr" ]; then
        echo "leaked ${med} kB over ${MEASURE} reqs ($(( med * 1024 / MEASURE )) B/req; threshold ${thr} kB; batches ${g1}/${g2}/${g3} kB — the median batch grew, so this is a leak, not a one-off step)"
        return 1
    fi
    if [ "$hi" -gt "$thr" ]; then
        echo "steady-state growth ${med} kB over ${MEASURE} reqs (<= ${thr} kB; batches ${g1}/${g2}/${g3} kB — the ${hi} kB batch is one-off startup growth, absorbed by the median)"
    else
        echo "steady-state growth ${med} kB over ${MEASURE} reqs (<= ${thr} kB; batches ${g1}/${g2}/${g3} kB)"
    fi
    return 0
}

# $1 = label, $2 = route path, $3 = server script body
run_growth_check() {
    local label="$1" route="$2" body="$3"
    local port srv_file srv_pid
    port=$(( (RANDOM % 10000) + 51000 ))
    srv_file=$(mktemp /tmp/eigs_rss_srv_XXXXXX.eigs)
    printf '%s\n' "$body" | sed -e "s/__PORT__/$port/" -e "s/__NONCE__/$NONCE/" > "$srv_file"

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

    check_identity "$label" "$port" "$srv_pid" || { rm -f "$srv_file" "/tmp/eigs_rss_srv_$$.log"; return; }

    # `reason`/`rc` are declared here but assigned separately: `local x=$(f)`
    # would make $? the exit status of `local`, not of f, and the verdict would
    # always read as clean.
    #
    # TWO verdicts at the same checkpoints: the heap leg (h_*, uordblks bytes
    # via /heap_inuse, judged at THRESHOLD_KB) and the RSS leg (r_*, VmRSS kB,
    # judged at RSS_THRESHOLD_KB). Either leg tripping fails the check.
    local warm m1 m2 m3 ha hb hc hd ra rb rc_ rd
    local heap_reason heap_rc rss_reason rss_rc
    warm=$(batch_200s "http://127.0.0.1:$port$route?[1-$WARMUP]")
    ha=$(heap_of "$port"); ra=$(rss_of "$srv_pid")
    heap_sample_ok "$label" "$ha" "$srv_pid"
    m1=$(batch_200s "http://127.0.0.1:$port$route?[1-$MEASURE]")
    hb=$(heap_of "$port"); rb=$(rss_of "$srv_pid")
    m2=$(batch_200s "http://127.0.0.1:$port$route?[1-$MEASURE]")
    hc=$(heap_of "$port"); rc_=$(rss_of "$srv_pid")
    m3=$(batch_200s "http://127.0.0.1:$port$route?[1-$MEASURE]")
    hd=$(heap_of "$port"); rd=$(rss_of "$srv_pid")

    kill "$srv_pid" 2>/dev/null || true
    wait "$srv_pid" 2>/dev/null || true
    rm -f "$srv_file" "/tmp/eigs_rss_srv_$$.log"

    if [ "$warm" -ne "$WARMUP" ] || [ "$m1" -ne "$MEASURE" ] || [ "$m2" -ne "$MEASURE" ] \
       || [ "$m3" -ne "$MEASURE" ]; then
        fail "$label INSTRUMENT: batch incomplete, deltas are meaningless" \
             "warmup $warm/$WARMUP, batches $m1/$MEASURE, $m2/$MEASURE and $m3/$MEASURE — not a leak measurement"
        return
    fi

    case "$hb$hc$hd" in *[!0-9]*|'')
        fail "$label could not read live heap" "ha='$ha' hb='$hb' hc='$hc' hd='$hd'"
        return ;;
    esac
    heap_reason=$(leak_verdict "$THRESHOLD_KB" "$(( (hb - ha) / 1024 ))" "$(( (hc - hb) / 1024 ))" "$(( (hd - hc) / 1024 ))")
    heap_rc=$?
    rss_reason=$(leak_verdict "$RSS_THRESHOLD_KB" "$((rb - ra))" "$((rc_ - rb))" "$((rd - rc_))")
    rss_rc=$?
    if [ "$heap_rc" -eq 0 ] && [ "$rss_rc" -eq 0 ]; then
        ok "$label heap: $heap_reason | rss: $rss_reason"
    else
        fail "$label heap: $heap_reason | rss: $rss_reason"
    fi
}

# The /heap_inuse route is how the gate reads the server's own exact heap
# accounting (heap_inuse builtin → mallinfo2().uordblks, live bytes), and
# /gate_nonce is the identity proof against SO_REUSEPORT traffic splitting.
# Both ride in the same server script as the route under test — one process.
run_growth_check "RSS1 shared_incr" "/sinc" \
'r is http_route of ["GET", "/sinc", "code", "shared_incr of [\"counter\", 1]"]
h is http_route of ["GET", "/heap_inuse", "code", "heap_inuse of null"]
n is http_route of ["GET", "/gate_nonce", "code", "\"__NONCE__\""]
s is http_serve of [__PORT__]'

# require_auth is seeded as a source string that evaluates to "" (= allow), so
# every /secret request takes the shared-store auth branch at
# ext_http.c:1295 (the shared_find(srv, "require_auth") lookup).
PORT_A=$(( (RANDOM % 10000) + 52000 ))
AUTH_SRV=$(mktemp /tmp/eigs_rss_auth_XXXXXX.eigs)
cat > "$AUTH_SRV" <<EIGS
a is http_route of ["GET", "/asetup", "code", "shared_set of [\"require_auth\", \"\\\\\"\\\\\"\"]\n\"ok\""]
s2 is http_route_authed of ["GET", "/secret", "code", "\"top secret\""]
h is http_route of ["GET", "/heap_inuse", "code", "heap_inuse of null"]
n is http_route of ["GET", "/gate_nonce", "code", "\"$NONCE\""]
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
    if check_identity "RSS2 authed route" "$PORT_A" "$AUTH_PID"; then
    WARM=$(batch_200s "http://127.0.0.1:$PORT_A/secret?[1-$WARMUP]")
    HA=$(heap_of "$PORT_A"); RA=$(rss_of "$AUTH_PID")
    heap_sample_ok "RSS2 authed route" "$HA" "$AUTH_PID"
    M1=$(batch_200s "http://127.0.0.1:$PORT_A/secret?[1-$MEASURE]")
    HB=$(heap_of "$PORT_A"); RB=$(rss_of "$AUTH_PID")
    M2=$(batch_200s "http://127.0.0.1:$PORT_A/secret?[1-$MEASURE]")
    HC=$(heap_of "$PORT_A"); RC_=$(rss_of "$AUTH_PID")
    M3=$(batch_200s "http://127.0.0.1:$PORT_A/secret?[1-$MEASURE]")
    HD=$(heap_of "$PORT_A"); RD=$(rss_of "$AUTH_PID")
    if [ "$WARM" -ne "$WARMUP" ] || [ "$M1" -ne "$MEASURE" ] || [ "$M2" -ne "$MEASURE" ] \
       || [ "$M3" -ne "$MEASURE" ]; then
        fail "RSS2 authed route INSTRUMENT: batch incomplete, deltas are meaningless" \
             "warmup $WARM/$WARMUP, batches $M1/$MEASURE, $M2/$MEASURE and $M3/$MEASURE — not a leak measurement"
    else
        case "$HB$HC$HD" in *[!0-9]*|'')
            fail "RSS2 authed route could not read live heap" "HA='$HA' HB='$HB' HC='$HC' HD='$HD'" ;;
        *)
            HEAP_REASON=$(leak_verdict "$THRESHOLD_KB" "$(( (HB - HA) / 1024 ))" "$(( (HC - HB) / 1024 ))" "$(( (HD - HC) / 1024 ))")
            HEAP_RC=$?
            RSS_REASON=$(leak_verdict "$RSS_THRESHOLD_KB" "$((RB - RA))" "$((RC_ - RB))" "$((RD - RC_))")
            RSS_RC=$?
            if [ "$HEAP_RC" -eq 0 ] && [ "$RSS_RC" -eq 0 ]; then
                ok "RSS2 authed route heap: $HEAP_REASON | rss: $RSS_REASON"
            else
                fail "RSS2 authed route heap: $HEAP_REASON | rss: $RSS_REASON"
            fi ;;
        esac
    fi
    fi
else
    fail "RSS2 authed route did not come up" "port $PORT_A"
fi
kill "$AUTH_PID" 2>/dev/null || true
wait "$AUTH_PID" 2>/dev/null || true
rm -f "$AUTH_SRV" "/tmp/eigs_rss_auth_$$.log"

# Self-test the verdict against planted faults, in BOTH directions and on BOTH
# legs. A gate is only evidence if a real fault turns it red and a known
# non-fault does not, and neither half can be checked by watching it pass on a
# healthy binary: #765 shipped a rule that was green here and false-failed CI
# within a day. These are the real numbers — the two leak rates this gate was
# built to catch, the one-off step that produced run 30439602640's phantom
# leak, and the non-arena mmap class that is the heap leg's documented blind
# spot (#770).
st_fail=0
expect_verdict() { # $1 = threshold kB, $2 = clean|leak, $3 = label, $4 $5 $6 = batch kB
    local thr="$1" want="$2" label="$3" got
    if leak_verdict "$thr" "$4" "$5" "$6" >/dev/null 2>&1; then got=clean; else got=leak; fi
    if [ "$got" != "$want" ]; then
        echo "    verdict self-test: '$label' (thr $thr, ${4}/${5}/${6} kB) expected $want, got $got"
        st_fail=$((st_fail + 1))
    fi
}
# Heap leg (threshold 64 kB): the arena class it must catch, and the one-off
# growth it must absorb.
expect_verdict 64 clean "flat, leak-free"                          0 0 0
expect_verdict 64 clean "sub-threshold page jitter"                8 0 16
expect_verdict 64 clean "arena step in batch 1"                 2856 0 0
expect_verdict 64 clean "arena step in batch 2 (run 30439602640)"  0 2876 0
expect_verdict 64 clean "arena step in batch 3"                   0 0 2668
expect_verdict 64 clean "RSS can fall as well as rise"         -1204 0 1204
expect_verdict 64 leak  "#731 shared_incr, 160 B/req"            312 312 312
expect_verdict 64 leak  "#752 authed route, 136 B/req"           265 265 265
expect_verdict 64 leak  "a real leak WITH a step on top"         312 3000 312
expect_verdict 64 leak  "leak at 1472 B/req sustained"          2876 2876 2876
# RSS leg (threshold 4096 kB): the non-arena class it must catch, and the
# arena-step class it must NOT catch even when steps land in two batches.
expect_verdict 4096 clean "arena steps in two batches"          2876 2876 0
expect_verdict 4096 clean "sub-threshold RSS drift"             1000 2000 500
expect_verdict 4096 clean "single arena step"                      0 2856 0
expect_verdict 4096 leak  "512 kB/req direct-mmap leak (#770)"  1024000 1024000 1024000
expect_verdict 4096 leak  "mmap leak with an arena step on top" 1024000 2876 1024000
if [ "$st_fail" -eq 0 ]; then
    ok "verdict self-test: 15 planted faults classified correctly (9 clean, 6 leak)"
else
    fail "verdict self-test: $st_fail planted fault(s) misclassified" \
         "the gate's decision rule is wrong — its verdicts above are not evidence"
fi

echo "HTTP_RSS: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
