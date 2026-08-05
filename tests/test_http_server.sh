#!/bin/bash
# HTTP server integration tests: start a real server, issue requests, kill it.
# Runs only when the binary exposes http_route (gated by run_all_tests.sh).
# Requires curl on PATH.

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
    echo "HTTP_SERVER: 0 passed, 0 failed (skipped)"
    exit 0
fi

# ---- Server-start helpers (#760) ----------------------------------------
# Both defects below made a SETUP failure look like a feature failure: HS27/HS28
# reported "aggregate body budget (got 000)" when the truth was that the server
# was never reachable.
#
# 1. Pick a listen port BELOW the kernel's ephemeral range. The old
#    `(RANDOM % 10000) + 50000` window sits INSIDE it (32768-60999 on Linux),
#    and this suite's own curl clients take ephemeral ports from that window —
#    so a server could lose the bind to the test's own traffic.
# 2. Wait on a WALL-CLOCK deadline. `30 x (curl --max-time 1; sleep 0.1)` reads
#    like ~33s but is ~3.6s measured: a refused connection returns instantly, so
#    --max-time only ever bounded the case where something WAS listening.
pick_port() {
    local lo hi
    lo=$(awk '{print $1}' /proc/sys/net/ipv4/ip_local_port_range 2>/dev/null)
    case "$lo" in ''|*[!0-9]*) lo=32768 ;; esac
    hi=$((lo - 1))
    lo=$((hi - 11999))
    [ "$lo" -lt 1024 ] && lo=1024
    echo $(( (RANDOM % (hi - lo + 1)) + lo ))
}

# wait_ready <url> [deadline_seconds] -> 0 ready, 1 timed out
wait_ready() {
    local url=$1 limit=${2:-15} start=$SECONDS
    while [ $((SECONDS - start)) -lt "$limit" ]; do
        curl -s --max-time 1 "$url" >/dev/null 2>&1 && return 0
        sleep 0.1
    done
    return 1
}

# Pick a listen port below the kernel's ephemeral range (#760) — the old
# 40000-49999 window sits inside it, so this suite's own curl clients could
# hold the port the server then failed to bind.
PORT=$(pick_port)

# Static directory for static-file serving.
STATIC_DIR=$(mktemp -d /tmp/eigs_http_static_XXXXXX)
echo "static-file-marker-xyz" > "$STATIC_DIR/hello.txt"

# Write a server script.
SRV=$(mktemp /tmp/eigs_http_srv_XXXXXX.eigs)
cat > "$SRV" <<EIGS
# GET /ping -> plain text
r1 is http_route of ["GET", "/ping", "pong"]

# GET /json -> JSON (starts with '{')
r2 is http_route of ["GET", "/json", "{\"ok\":true}"]

# Static-file dir mounted under /files
s is http_static of ["/files", "$STATIC_DIR"]

# Code route: evaluates per-request in a worker EigsState. Sets a local
# var and returns it — used to check per-worker isolation (a mutation
# in one request must not be visible from a later one).
r_code is http_route of ["GET", "/codeval", "code", "x is 1\nx is x + 1\nx"]

# Code route that mutates a name with the same identifier across calls.
# Reads stdlib; never sees startup-scope globals.
r_iso is http_route of ["GET", "/iso", "code", "counter is 100\ncounter"]

# Shared-store routes: cross-worker key/value store, JSON-serialized.
# Each shared_* call is mutex-guarded; the API guarantees individual op
# atomicity, NOT read-modify-write atomicity (no CAS primitive yet).
r_sset  is http_route of ["GET", "/sset",  "code", "shared_set of [\"k\", \"hello\"]\n\"ok\""]
r_sget  is http_route of ["GET", "/sget",  "code", "shared_get of \"k\""]
r_sdict is http_route of ["GET", "/sdict", "code", "shared_set of [\"d\", {\"a\": 1, \"b\": [2, 3]}]\njson_encode of (shared_get of \"d\")"]
r_sdel  is http_route of ["GET", "/sdel",  "code", "shared_set of [\"x\", 42]\nshared_delete of \"x\"\nshared_has of \"x\""]
r_sclr  is http_route of ["GET", "/sclr",  "code", "shared_clear of null\nshared_set of [\"a\", 1]\nshared_set of [\"b\", 2]\nshared_size of null"]
# Bounds: clear, build an 8 KiB string, attempt the set — should be
# rejected (cap=4096 via env var); shared_has confirms nothing landed.
r_sbig  is http_route of ["GET", "/sbig",  "code", "shared_clear of null\ns is \"x\"\ni is 0\nloop while i < 13:\n  s is s + s\n  i is i + 1\nshared_set of [\"big\", s]\nshared_has of \"big\""]
# Atomic increment: single-lock RMW. Returns the new value.
r_sinc  is http_route of ["GET", "/sinc",  "code", "shared_incr of [\"counter\", 1]"]
# Source-based auth: the test drives this via /asetup, /aallow, /adeny.
# /asetup writes require_auth as a script that just reads auth_msg —
# empty allows, anything else becomes the 401 body.
r_asetup is http_route of ["GET", "/asetup", "code", "shared_set of [\"require_auth\", \"shared_get of \\\\\"auth_msg\\\\\"\"]\nshared_set of [\"auth_msg\", \"\"]\n\"ok\""]
r_aallow is http_route of ["GET", "/aallow", "code", "shared_set of [\"auth_msg\", \"\"]\n\"ok\""]
r_adeny  is http_route of ["GET", "/adeny",  "code", "shared_set of [\"auth_msg\", \"denied by test\"]\n\"ok\""]
r_acleanup is http_route of ["GET", "/acleanup", "code", "shared_delete of \"require_auth\"\nshared_delete of \"auth_msg\"\n\"ok\""]
# The authed route itself: returns "top secret" iff auth passes.
secret is http_route_authed of ["GET", "/secret", "code", "\"top secret\""]

# Echoes the request body back — the framing oracle for HS29/HS30.
r_echo is http_route of ["POST", "/echo", "code", "http_request_body of null"]

# Echoes the raw request header block — the injection oracle for HS32.
r_hdrs is http_route of ["POST", "/hdrs", "code", "http_request_headers of null"]

# Serve forever.
serve is http_serve of $PORT
EIGS

# Start the server in the background. The shared-store cap is squeezed
# down to 4 KiB so the HS22 bounds test can write an 8 KiB value and see
# it rejected; existing HS17–HS21 values are tens of bytes each, well
# under the cap.
EIGS_HTTP_SHARED_MAX_BYTES=4096 "$EIGS" "$SRV" > /tmp/eigs_http_srv_$$.log 2>&1 &
SRV_PID=$!

cleanup() {
    kill "$SRV_PID" 2>/dev/null || true
    wait "$SRV_PID" 2>/dev/null || true
    rm -f "$SRV" /tmp/eigs_http_srv_$$.log
    rm -rf "$STATIC_DIR"
}
trap cleanup EXIT

# Wait for the server on a wall-clock deadline (#760): the old 30-iteration
# loop was ~3.6s, not the ~33s its --max-time suggested.
wait_ready "http://127.0.0.1:$PORT/ping" 15 || true

if ! curl -s --max-time 1 "http://127.0.0.1:$PORT/ping" > /dev/null 2>&1; then
    echo "  FAIL: server never came up on port $PORT"
    cat /tmp/eigs_http_srv_$$.log | head -20
    echo "HTTP_SERVER: 0 passed, 1 failed"
    exit 1
fi

# ---- GET /ping ----
RESP=$(curl -s --max-time 2 "http://127.0.0.1:$PORT/ping")
if [ "$RESP" = "pong" ]; then
    ok "HS01 GET /ping returns 'pong'"
else
    fail "HS01 GET /ping" "got '$RESP'"
fi

# ---- Query string is request data, not part of the route identity ----
# A route on /ping must still match /ping?x=1 (regression: the request target
# was matched whole, so any query string 404'd).
STATUS=$(curl -s --max-time 2 -o /dev/null -w "%{http_code}" "http://127.0.0.1:$PORT/ping?x=1&y=2")
RESP=$(curl -s --max-time 2 "http://127.0.0.1:$PORT/ping?x=1&y=2")
if [ "$STATUS" = "200" ] && [ "$RESP" = "pong" ]; then
    ok "HS01b GET /ping?x=1 matches the /ping route (query ignored for routing)"
else
    fail "HS01b query-string routing" "status=$STATUS resp='$RESP'"
fi

# ---- Content-Type heuristic: JSON payload -> application/json ----
CT=$(curl -s --max-time 2 -D - "http://127.0.0.1:$PORT/json" -o /dev/null \
     | grep -i "^content-type:" | tr -d '\r')
if echo "$CT" | grep -qi "application/json"; then
    ok "HS02 GET /json sets Content-Type: application/json"
else
    fail "HS02 JSON content-type" "got '$CT'"
fi

# ---- Content-Type heuristic: plain payload -> text/plain ----
CT=$(curl -s --max-time 2 -D - "http://127.0.0.1:$PORT/ping" -o /dev/null \
     | grep -i "^content-type:" | tr -d '\r')
if echo "$CT" | grep -qi "text/plain"; then
    ok "HS03 GET /ping sets Content-Type: text/plain"
else
    fail "HS03 plain content-type" "got '$CT'"
fi

# ---- 404 for unknown route ----
STATUS=$(curl -s --max-time 2 -o /dev/null -w "%{http_code}" "http://127.0.0.1:$PORT/nope")
if [ "$STATUS" = "404" ]; then
    ok "HS04 unknown route returns 404"
else
    fail "HS04 unknown route" "status=$STATUS"
fi

# ---- Static file serving ----
RESP=$(curl -s --max-time 2 "http://127.0.0.1:$PORT/files/hello.txt")
if echo "$RESP" | grep -q "static-file-marker-xyz"; then
    ok "HS05 static file served under /files"
else
    fail "HS05 static file" "got '$RESP'"
fi

# ---- Static file serving tolerates a query string ----
RESP=$(curl -s --max-time 2 "http://127.0.0.1:$PORT/files/hello.txt?v=2")
if echo "$RESP" | grep -q "static-file-marker-xyz"; then
    ok "HS05b static file served with a query string"
else
    fail "HS05b static file + query" "got '$RESP'"
fi

# ---- Path traversal rejected ----
STATUS=$(curl -s --max-time 2 -o /dev/null -w "%{http_code}" \
         "http://127.0.0.1:$PORT/files/../etc/passwd")
if [ "$STATUS" = "403" ] || [ "$STATUS" = "404" ]; then
    ok "HS06 path traversal rejected (status=$STATUS)"
else
    fail "HS06 path traversal" "status=$STATUS (expected 403 or 404)"
fi

# ---- Symlink escape rejected (realpath confinement) ----
# Drop a symlink inside static_dir that points outside. A purely string-based
# path-traversal check misses this; realpath-based confinement catches it.
ln -s /etc/hostname "$STATIC_DIR/escape" 2>/dev/null || true
if [ -L "$STATIC_DIR/escape" ]; then
    STATUS=$(curl -s --max-time 2 -o /dev/null -w "%{http_code}" \
             "http://127.0.0.1:$PORT/files/escape")
    if [ "$STATUS" = "403" ] || [ "$STATUS" = "404" ]; then
        ok "HS06b symlink escape rejected (status=$STATUS)"
    else
        fail "HS06b symlink escape" "status=$STATUS (expected 403 or 404)"
    fi
else
    echo "  SKIP: HS06b (could not create symlink)"
fi

# ---- OPTIONS preflight: 204 + Allow header ----
HDRS=$(curl -s --max-time 2 -X OPTIONS -D - -o /dev/null "http://127.0.0.1:$PORT/ping")
STATUS=$(echo "$HDRS" | head -1 | awk '{print $2}')
if [ "$STATUS" = "204" ]; then
    ok "HS07 OPTIONS preflight returns 204"
else
    fail "HS07 OPTIONS preflight" "status=$STATUS"
fi
if echo "$HDRS" | grep -qi "^Allow:.*GET.*HEAD.*OPTIONS"; then
    ok "HS07b OPTIONS advertises Allow: GET, HEAD, OPTIONS"
else
    fail "HS07b OPTIONS Allow header" "headers=$(echo "$HDRS" | tr -d '\r' | head -5 | tr '\n' '|')"
fi

# ---- Negative Content-Length rejected (regression) ----
# Previously, atoi("-1") returned -1 and body_received >= content_length
# was trivially true, so the read loop exited mid-body. Fix parses with
# strtol and closes the connection on any value outside [0, MAX_BODY].
# We test the server by opening a TCP socket directly and sending a
# malformed request; the server should close the connection without
# emitting a full HTTP response.
if command -v timeout >/dev/null 2>&1; then
    CL_RESP=$(timeout 2 bash -c "
        exec 3<>/dev/tcp/127.0.0.1/$PORT
        printf 'POST /ping HTTP/1.1\r\nHost: localhost\r\nContent-Length: -1\r\n\r\nHELLO' >&3
        cat <&3
        exec 3<&-
    " 2>/dev/null || true)
    if echo "$CL_RESP" | head -1 | grep -q "400"; then
        ok "HS08 negative Content-Length: server replies 400"
    else
        fail "HS08 negative Content-Length: expected 400" "got '$(echo "$CL_RESP" | head -1)'"
    fi

    # Sanity: the server must still be alive after the malformed request.
    RESP=$(curl -s --max-time 2 "http://127.0.0.1:$PORT/ping")
    if [ "$RESP" = "pong" ]; then
        ok "HS09 server still healthy after malformed request"
    else
        fail "HS09 server health after malformed request" "got '$RESP'"
    fi
else
    echo "  SKIP: HS08/HS09 (timeout not available)"
fi

# ---- HEAD routed as GET, no body ----
HDRS=$(curl -s --max-time 2 -I "http://127.0.0.1:$PORT/ping")
STATUS=$(echo "$HDRS" | head -1 | awk '{print $2}')
BODY_LEN=$(curl -s --max-time 2 -I "http://127.0.0.1:$PORT/ping" \
           | tr -d '\r' | awk '/^Content-Length:/{print $2}')
HEAD_BODY=$(curl -s --max-time 2 -I "http://127.0.0.1:$PORT/ping" \
            | awk 'flag{print} /^\r?$/{flag=1}')
if [ "$STATUS" = "200" ] && [ "$BODY_LEN" = "4" ] && [ -z "$HEAD_BODY" ]; then
    ok "HS10 HEAD /ping returns 200 with Content-Length:4 and no body"
else
    fail "HS10 HEAD /ping" "status=$STATUS cl=$BODY_LEN body_present=$([ -n "$HEAD_BODY" ] && echo yes || echo no)"
fi

# ---- Invalid HTTP version rejected ----
if command -v timeout >/dev/null 2>&1; then
    BAD_VER=$(timeout 2 bash -c "
        exec 3<>/dev/tcp/127.0.0.1/$PORT
        printf 'GET /ping HTTP/junk\r\nHost: x\r\nConnection: close\r\n\r\n' >&3
        cat <&3
        exec 3<&-
    " 2>/dev/null || true)
    if echo "$BAD_VER" | head -1 | grep -q "400"; then
        ok "HS11 malformed HTTP version returns 400"
    else
        fail "HS11 malformed HTTP version" "got '$(echo "$BAD_VER" | head -1)'"
    fi
fi

# ---- Oversized headers -> 431 ----
# Send a single header value of 17 MiB; with default max_body=16 MiB the
# header budget caps at ~16 MiB and the server should answer 431, not 200.
if command -v timeout >/dev/null 2>&1; then
    BIG_HDR=$(timeout 8 bash -c "
        exec 3<>/dev/tcp/127.0.0.1/$PORT
        printf 'GET /ping HTTP/1.1\r\nHost: x\r\nX-Big: ' >&3
        head -c 17000000 /dev/zero | tr '\0' 'A' >&3
        printf '\r\n\r\n' >&3
        cat <&3
        exec 3<&-
    " 2>/dev/null || true)
    if echo "$BIG_HDR" | head -1 | grep -q "431"; then
        ok "HS12 oversized headers return 431"
    else
        fail "HS12 oversized headers" "got '$(echo "$BIG_HDR" | head -1)'"
    fi
fi

# ---- Concurrent slow conns must not starve a fresh GET ----
# Open 16 partial-header connections (no terminator), then issue a GET; if
# the server is single-threaded the GET hangs until the first slow conn
# times out (~5s). With per-conn threads the GET returns in well under 1s.
if command -v timeout >/dev/null 2>&1; then
    SLOW_PIDS=()
    for _ in $(seq 1 16); do
        ( timeout 8 bash -c "
            exec 3<>/dev/tcp/127.0.0.1/$PORT
            printf 'GET /ping HTTP/1.1\r\nHost: x\r\n' >&3
            sleep 6
            exec 3<&-
        " ) > /dev/null 2>&1 &
        SLOW_PIDS+=($!)
    done
    sleep 0.3
    T0=$(date +%s%N)
    RESP=$(curl -s --max-time 3 "http://127.0.0.1:$PORT/ping")
    T1=$(date +%s%N)
    ELAPSED_MS=$(( (T1 - T0) / 1000000 ))
    if [ "$RESP" = "pong" ] && [ "$ELAPSED_MS" -lt 1500 ]; then
        ok "HS13 GET served in ${ELAPSED_MS}ms during 16 slow conns"
    else
        fail "HS13 GET starved by slow conns" "resp='$RESP' elapsed=${ELAPSED_MS}ms"
    fi
    # Reap only the slow-conn subshells — bare `wait` would also block on
    # the server PID, which never exits on its own.
    for p in "${SLOW_PIDS[@]}"; do
        wait "$p" 2>/dev/null || true
    done
fi

# ---- Code routes evaluate in per-worker EigsState ----
# Each request gets a fresh worker state with stdlib + per-request HTTP
# builtins. The route source must be self-contained — no startup globals
# leak in, no mutations leak out across requests.
RESP=$(curl -s --max-time 2 "http://127.0.0.1:$PORT/codeval")
if [ "$RESP" = "2" ]; then
    ok "HS14 code route evaluates and returns final-expression value"
else
    fail "HS14 code route" "got '$RESP'"
fi

# Hit /iso N times — each call must see counter=100 (i.e. no leak from
# the previous worker into the next).
ISO_FAILS=0
for _ in $(seq 1 10); do
    RESP=$(curl -s --max-time 2 "http://127.0.0.1:$PORT/iso")
    if [ "$RESP" != "100" ]; then
        ISO_FAILS=$((ISO_FAILS+1))
    fi
done
if [ "$ISO_FAILS" -eq 0 ]; then
    ok "HS15 code routes isolated across 10 sequential requests"
else
    fail "HS15 code-route isolation" "$ISO_FAILS/10 saw stale state"
fi

# Fire 16 concurrent code-route calls. They must all 200 with "100" —
# proves per-worker states don't trample each other's globals when running
# in parallel. Each curl writes to its own file to avoid output interleave.
if command -v timeout >/dev/null 2>&1; then
    CONC_DIR=$(mktemp -d /tmp/eigs_conc_XXXXXX)
    PIDS=()
    for i in $(seq 1 16); do
        ( curl -s --max-time 3 "http://127.0.0.1:$PORT/iso" > "$CONC_DIR/r$i" 2>/dev/null ) &
        PIDS+=($!)
    done
    for p in "${PIDS[@]}"; do wait "$p" 2>/dev/null || true; done
    GOOD=0
    for i in $(seq 1 16); do
        [ "$(cat "$CONC_DIR/r$i" 2>/dev/null)" = "100" ] && GOOD=$((GOOD+1))
    done
    if [ "$GOOD" -eq 16 ]; then
        ok "HS16 16 concurrent code-route calls all returned isolated state"
    else
        fail "HS16 concurrent code routes" "only $GOOD/16 returned '100'"
    fi
    rm -rf "$CONC_DIR"
fi

# ---- Shared-store: set then get across two requests ----
# Each request runs in a fresh worker EigsState, so the only way /sset's
# write survives to /sget is through the per-Server shared store.
curl -s --max-time 2 "http://127.0.0.1:$PORT/sset" > /dev/null
RESP=$(curl -s --max-time 2 "http://127.0.0.1:$PORT/sget")
if [ "$RESP" = "hello" ]; then
    ok "HS17 shared_set/get round-trips a string across worker states"
else
    fail "HS17 shared store string round-trip" "got '$RESP'"
fi

# ---- Shared-store: dict round-trip (set in one worker, get in next) ----
RESP=$(curl -s --max-time 2 "http://127.0.0.1:$PORT/sdict")
if [ "$RESP" = '{"a":1,"b":[2,3]}' ]; then
    ok "HS18 shared store round-trips nested dict"
else
    fail "HS18 shared store dict" "got '$RESP'"
fi

# ---- Shared-store: delete clears the entry ----
RESP=$(curl -s --max-time 2 "http://127.0.0.1:$PORT/sdel")
if [ "$RESP" = "0" ]; then
    ok "HS19 shared_delete removes the key"
else
    fail "HS19 shared_delete" "got '$RESP'"
fi

# ---- Shared-store: clear then set two; size must be 2 ----
RESP=$(curl -s --max-time 2 "http://127.0.0.1:$PORT/sclr")
if [ "$RESP" = "2" ]; then
    ok "HS20 shared_clear + two sets => size 2"
else
    fail "HS20 shared_clear/size" "got '$RESP'"
fi

# ---- Shared-store: 32 concurrent reads of a seeded value ----
# Re-seed "k" (HS20 cleared it), then fire 32 parallel /sget calls.
# Every response must be the intact value — proves the mutex serializes
# the get against any concurrent set so readers never see torn state.
curl -s --max-time 2 "http://127.0.0.1:$PORT/sset" > /dev/null
if command -v timeout >/dev/null 2>&1; then
    CONC_DIR=$(mktemp -d /tmp/eigs_sread_XXXXXX)
    PIDS=()
    for i in $(seq 1 32); do
        ( curl -s --max-time 5 "http://127.0.0.1:$PORT/sget" > "$CONC_DIR/r$i" 2>/dev/null ) &
        PIDS+=($!)
    done
    for p in "${PIDS[@]}"; do wait "$p" 2>/dev/null || true; done
    GOOD=0
    for i in $(seq 1 32); do
        [ "$(cat "$CONC_DIR/r$i" 2>/dev/null)" = "hello" ] && GOOD=$((GOOD+1))
    done
    if [ "$GOOD" -eq 32 ]; then
        ok "HS21 32 concurrent shared_get reads all returned intact value"
    else
        fail "HS21 concurrent reads" "only $GOOD/32 returned 'hello'"
    fi
    rm -rf "$CONC_DIR"
fi

# ---- Shared-store: bounds (EIGS_HTTP_SHARED_MAX_BYTES) ----
# /sbig writes an 8 KiB string under a 4 KiB cap; shared_set must
# reject the write and leave the store unchanged.
RESP=$(curl -s --max-time 2 "http://127.0.0.1:$PORT/sbig")
if [ "$RESP" = "0" ]; then
    ok "HS22 shared_set rejects writes past EIGS_HTTP_SHARED_MAX_BYTES"
else
    fail "HS22 shared store bounds" "got '$RESP' (expected 0)"
fi

# ---- Shared-store: atomic increment (single-lock RMW) ----
# Fire 32 concurrent /sinc calls. Each one performs an atomic read-
# modify-write under the mutex; no update should be lost. The 32
# responses must contain every integer in 1..32, and the next call
# must return 33.
if command -v timeout >/dev/null 2>&1; then
    CONC_DIR=$(mktemp -d /tmp/eigs_sinc_XXXXXX)
    PIDS=()
    for i in $(seq 1 32); do
        ( curl -s --max-time 5 "http://127.0.0.1:$PORT/sinc" > "$CONC_DIR/r$i" 2>/dev/null ) &
        PIDS+=($!)
    done
    for p in "${PIDS[@]}"; do wait "$p" 2>/dev/null || true; done
    FINAL=$(curl -s --max-time 2 "http://127.0.0.1:$PORT/sinc")
    DISTINCT=$(sort -un "$CONC_DIR"/r* 2>/dev/null | wc -l)
    if [ "$FINAL" = "33" ] && [ "$DISTINCT" = "32" ]; then
        ok "HS23 32 concurrent shared_incr: final=33, all 32 slots distinct"
    else
        fail "HS23 shared_incr RMW" "final=$FINAL distinct=$DISTINCT/32"
    fi
    rm -rf "$CONC_DIR"
fi

# ---- Source-based auth via shared_set("require_auth", "<source>") ----
# The auth source crosses worker boundaries as a string, not a function:
# each worker tokenizes/compiles/runs it per authed request. Empty result
# = allow; any non-empty value_to_string output becomes the 401 body.

# Seed require_auth + auth_msg (initially "" = allow).
curl -s --max-time 2 "http://127.0.0.1:$PORT/asetup" > /dev/null

# Authed route returns the body when auth source evaluates to "".
STATUS=$(curl -s --max-time 2 -o /tmp/eigs_auth_body_$$ -w "%{http_code}" "http://127.0.0.1:$PORT/secret")
BODY=$(cat /tmp/eigs_auth_body_$$ 2>/dev/null)
rm -f /tmp/eigs_auth_body_$$
if [ "$STATUS" = "200" ] && [ "$BODY" = "top secret" ]; then
    ok "HS24 http_route_authed allows when auth source returns empty string"
else
    fail "HS24 authed-route allow" "status=$STATUS body='$BODY'"
fi

# Flip auth_msg to a non-empty value — authed route must 401 with that body.
curl -s --max-time 2 "http://127.0.0.1:$PORT/adeny" > /dev/null
STATUS=$(curl -s --max-time 2 -o /tmp/eigs_auth_body_$$ -w "%{http_code}" "http://127.0.0.1:$PORT/secret")
BODY=$(cat /tmp/eigs_auth_body_$$ 2>/dev/null)
rm -f /tmp/eigs_auth_body_$$
if [ "$STATUS" = "401" ] && [ "$BODY" = "denied by test" ]; then
    ok "HS25 http_route_authed denies with 401 + auth source's message"
else
    fail "HS25 authed-route deny" "status=$STATUS body='$BODY'"
fi

# Flip back to allow — same authed route should 200 again. Proves the
# auth source is re-evaluated per request, not cached at registration.
curl -s --max-time 2 "http://127.0.0.1:$PORT/aallow" > /dev/null
STATUS=$(curl -s --max-time 2 -o /tmp/eigs_auth_body_$$ -w "%{http_code}" "http://127.0.0.1:$PORT/secret")
BODY=$(cat /tmp/eigs_auth_body_$$ 2>/dev/null)
rm -f /tmp/eigs_auth_body_$$
if [ "$STATUS" = "200" ] && [ "$BODY" = "top secret" ]; then
    ok "HS26 auth source is re-evaluated per request (allow → deny → allow)"
else
    fail "HS26 auth re-evaluation" "status=$STATUS body='$BODY'"
fi

# Clean up the require_auth key so it doesn't bleed into later tests
# that may rerun with a different cap.
curl -s --max-time 2 "http://127.0.0.1:$PORT/acleanup" > /dev/null

# ---- Content-Length is matched per header line, not by substring (#715) ----
# Content-Length used to be found with strcasestr() over the whole header
# block, so the first hit anywhere won: inside another header's VALUE, as a
# suffix of another header's NAME, or in the request target. The server framed
# the body at the decoy's length and dispatched the route with an empty body.
#
# The headers and the body MUST go in separate writes. Sent as one packet the
# body is already in reqbuf when the loop breaks early, so the bug is invisible
# — the pre-fix build passes a single-write version of this test.
ECHO_BODY='HELLO-REAL-BODY-0123456789'   # 26 bytes
if command -v timeout >/dev/null 2>&1; then
    send_split() { # $1 = request target, $2 = extra header lines before Content-Length
        timeout 5 bash -c "
            exec 3<>/dev/tcp/127.0.0.1/$PORT
            printf 'POST $1 HTTP/1.1\r\nHost: localhost\r\n$2Content-Length: 26\r\n\r\n' >&3
            sleep 0.3
            printf '%s' '$ECHO_BODY' >&3
            cat <&3
            exec 3<&-
        " 2>/dev/null || true
    }

    # Control first: if the plain split-write case fails, the two decoy cases
    # below prove nothing about framing.
    GOT=$(send_split "/echo" "" | tr -d '\r' | tail -1)
    if [ "$GOT" = "$ECHO_BODY" ]; then
        ok "HS29a split-write body arrives intact (control)"
    else
        fail "HS29a split-write control" "got '$GOT'"
    fi

    FRAMED=0
    # Fields are '|'-separated: a ':' delimiter would split the target case,
    # whose whole point is that it contains a colon.
    for CASE in "value|/echo|X-Note: Content-Length: 0\r\n" \
                "name-suffix|/echo|X-Content-Length: 0\r\n" \
                "target|/echo?q=Content-Length:0|"; do
        NAME=${CASE%%|*}; REST=${CASE#*|}
        TARGET=${REST%%|*}; EXTRA=${REST#*|}
        GOT=$(send_split "$TARGET" "$EXTRA" | tr -d '\r' | tail -1)
        if [ "$GOT" != "$ECHO_BODY" ]; then
            fail "HS29 decoy Content-Length in $NAME framed the body" "got '$GOT'"
            FRAMED=1
        fi
    done
    [ "$FRAMED" -eq 0 ] && ok "HS29 decoy Content-Length (header value / name suffix / target) does not frame the body"

    # Two Content-Length headers that disagree used to let the first silently
    # win. Reject the request instead.
    GOT=$(send_split "/echo" "Content-Length: 0\r\n" | head -1)
    if echo "$GOT" | grep -q "400"; then
        ok "HS30 conflicting duplicate Content-Length rejected with 400"
    else
        fail "HS30 conflicting duplicate Content-Length" "got '$GOT'"
    fi

    # The real header must still be honoured after all that.
    RESP=$(curl -s --max-time 2 "http://127.0.0.1:$PORT/ping")
    if [ "$RESP" = "pong" ]; then
        ok "HS31 server still healthy after framing probes"
    else
        fail "HS31 server health after framing probes" "got '$RESP'"
    fi
else
    echo "  SKIP: HS29/HS30/HS31 (timeout not available)"
fi

# ---- http_post strips CR/LF from outbound header names and values (#716) ----
# hk/hv reached curl's -H verbatim, so a CR/LF in either injected additional
# headers into the outbound request. Loopback: post to /hdrs, which echoes the
# raw header block the server received, and assert the injected name never
# appears at the START of a line. (Grepping for the name alone would false-pass
# — after stripping, the text survives inside X-Test's value, on one line,
# which is exactly the point.)
# Headers go as a flat JSON ARRAY of alternating name/value — http_post only
# reads the VAL_LIST shape, and a JSON object silently delivers no headers
# at all (filed separately).
CLI=$(mktemp /tmp/eigs_http_cli_XXXXXX.eigs)
cat > "$CLI" <<EIGSCLI
hdrs is "[\"X-Test\", \"probe\\\\r\\\\nX-Injected: yes\"]"
resp is http_post of ["http://127.0.0.1:$PORT/hdrs", hdrs, "b"]
print of resp
EIGSCLI
POSTED=$("$EIGS" "$CLI" 2>/dev/null | tr -d '\r')
rm -f "$CLI"
if [ -z "$POSTED" ]; then
    fail "HS32 outbound header CRLF injection" "client got no response from /hdrs"
elif echo "$POSTED" | grep -q '^X-Injected:'; then
    fail "HS32 outbound header CRLF injection" "injected header reached the wire as its own line"
elif echo "$POSTED" | grep -q '^X-Test: probeX-Injected: yes$'; then
    ok "HS32 http_post strips CR/LF from header values (no injected header line)"
else
    fail "HS32 outbound header CRLF injection" "X-Test not delivered as expected: $(echo "$POSTED" | grep -i '^X-' | tr '\n' '|')"
fi

# ---- Summary ----
echo ""
# ---- Aggregate request-body budget (EIGS_HTTP_MAX_BODY_TOTAL) ----
# Each connection's body buffer is capped (EIGS_HTTP_MAX_BODY) and concurrency
# is capped (HTTP_MAX_CONCURRENT_CONNS) — but their PRODUCT was unbounded
# (256 x 16 MiB ~= 4 GiB held at once), an aggregate-body DoS. Uses a SEPARATE
# server with a tiny total budget (1 MiB) so the squeeze can't perturb the other
# tests (HS12's 17 MiB header probe needs the default 128 MiB budget). A single
# upload larger than the budget must be shed with 503 DURING the read (before
# routing), and the server must stay alive for the next request.
PORT2=$(pick_port)
SRV2=$(mktemp /tmp/eigs_http_srv2_XXXXXX.eigs)
cat > "$SRV2" <<EIGS2
rp is http_route of ["GET", "/ping", "pong"]
sv is http_serve of $PORT2
EIGS2
EIGS_HTTP_MAX_BODY_TOTAL=1048576 "$EIGS" "$SRV2" > /tmp/eigs_http_srv2_$$.log 2>&1 &
SRV2_PID=$!
if ! wait_ready "http://127.0.0.1:$PORT2/ping" 15; then
    # #760: say what actually happened. Reporting the budget check as failed
    # here sent a reader hunting a DoS-gate regression that did not exist.
    fail "HS27/HS28 setup: server never came up on port $PORT2" \
         "$(tail -3 /tmp/eigs_http_srv2_$$.log 2>/dev/null | tr '\n' ' ')"
fi
BIGBODY=$(mktemp /tmp/eigs_http_big_XXXXXX)
head -c 2097152 /dev/zero | tr '\0' 'a' > "$BIGBODY"   # 2 MiB > 1 MiB budget
STATUS=$(curl -s --max-time 5 -o /dev/null -w "%{http_code}" \
    --data-binary @"$BIGBODY" "http://127.0.0.1:$PORT2/ping")
rm -f "$BIGBODY"
if [ "$STATUS" = "503" ]; then
    ok "HS27 oversized aggregate body shed with 503 (not OOM)"
else
    fail "HS27 aggregate body budget" "got $STATUS (expected 503)"
fi
# Server survived the over-budget upload and still serves.
RESP=$(curl -s --max-time 2 "http://127.0.0.1:$PORT2/ping")
if [ "$RESP" = "pong" ]; then
    ok "HS28 server survives over-budget upload"
else
    fail "HS28 server survives over-budget upload" "got '$RESP'"
fi
kill "$SRV2_PID" 2>/dev/null || true
wait "$SRV2_PID" 2>/dev/null || true
rm -f "$SRV2" /tmp/eigs_http_srv2_$$.log

# ---- HS34: http_post header shapes (#755) --------------------------------
# The signature is `http_post of [url, headers, body]` and a JSON OBJECT is what
# a caller reaches for first. It used to send NO headers: the code tested
# VAL_LIST while eigs_json_parse_object returns VAL_DICT, so the loop never ran
# and the request went out bare — no error, normal-looking response. An
# Authorization header silently not sent is the worst version of that. Both
# shapes must work, and a shape that is neither must say so rather than
# quietly dropping the headers. /hdrs echoes the raw request header block.
CLI=$(mktemp /tmp/eigs_http_cli_XXXXXX.eigs)
cat > "$CLI" <<EIGSCLI
obj is http_post of ["http://127.0.0.1:$PORT/hdrs", "{\"X-Shape\": \"object\"}", "b"]
arr is http_post of ["http://127.0.0.1:$PORT/hdrs", "[\"X-Shape\", \"array\"]", "b"]
print of ("OBJ:" + (str of (contains of [obj, "X-Shape: object"])))
print of ("ARR:" + (str of (contains of [arr, "X-Shape: array"])))
EIGSCLI
SHAPES=$("$EIGS" "$CLI" 2>/dev/null | tr -d '\r')
rm -f "$CLI"
if echo "$SHAPES" | grep -q "^OBJ:1$"; then
    ok "HS34 http_post sends headers given as a JSON object"
else
    fail "HS34 http_post object headers" "header did not reach the wire ($(echo "$SHAPES" | tr '\n' ' '))"
fi
if echo "$SHAPES" | grep -q "^ARR:1$"; then
    ok "HS34 http_post still sends headers given as a flat array"
else
    fail "HS34 http_post array headers" "regressed ($(echo "$SHAPES" | tr '\n' ' '))"
fi
CLI=$(mktemp /tmp/eigs_http_cli_XXXXXX.eigs)
cat > "$CLI" <<EIGSCLI
r is http_post of ["http://127.0.0.1:$PORT/hdrs", "\"just-a-string\"", "b"]
print of "NO_ERROR"
EIGSCLI
BAD=$("$EIGS" "$CLI" 2>&1 | tr -d '\r')
rm -f "$CLI"
if echo "$BAD" | grep -q "headers must be a JSON object"; then
    ok "HS34 a headers argument of the wrong shape raises instead of dropping"
else
    fail "HS34 wrong-shape headers" "expected a type error, got: $(echo "$BAD" | head -1)"
fi

# ---- HS33: the tape survives more than one request (#739) ----------------
# Every connection worker owns its own EigsState and used to call
# trace_shutdown() when it finished — a PROCESS-wide teardown run per request.
# The first request served closed the tape, so every later request's records
# were silently dropped (measured: 1 record for 400 requests). The tape is the
# process's execution record; a worker never owns it.
#
# Observation is content-based on purpose: no /proc (macOS runs this suite too)
# and no assumption about stdio buffer size. Each request stamps a distinct
# marker from the shared store FIRST, then writes ~400 padding assignments that
# push the marker out of the buffer — so a marker on disk means that request's
# records really reached the tape.
PORT3=$(pick_port)
SRV3=$(mktemp /tmp/eigs_http_srv3_XXXXXX.eigs)
TAPE3=$(mktemp /tmp/eigs_http_tape3_XXXXXX.tape)
cat > "$SRV3" <<EIGS3
rp is http_route of ["GET", "/hit", "code", "zz is shared_incr of [\"hits\", 1]\npad is 0\nloop while pad < 400:\n    filler is \"xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx\"\n    pad is pad + 1"]
sv is http_serve of $PORT3
EIGS3
EIGS_TRACE="$TAPE3" "$EIGS" "$SRV3" > /tmp/eigs_http_srv3_$$.log 2>&1 &
SRV3_PID=$!
if ! wait_ready "http://127.0.0.1:$PORT3/hit" 15; then
    fail "HS33 setup: trace server never came up on port $PORT3" \
         "$(tail -3 /tmp/eigs_http_srv3_$$.log 2>/dev/null | tr '\n' ' ')"
else
    for _ in 1 2 3; do
        curl -s --max-time 5 "http://127.0.0.1:$PORT3/hit" > /dev/null 2>&1
    done
    sleep 0.5
    MARKERS=$(grep -c '^A zz=' "$TAPE3" 2>/dev/null || echo 0)
    # The readiness probe is request 1, so requests 2+ are what the bug ate.
    if [ "$MARKERS" -ge 3 ]; then
        ok "HS33 tape keeps recording after the first request ($MARKERS markers)"
    else
        fail "HS33 tape stopped after the first request" \
             "got $MARKERS request markers (expected >= 3)"
    fi
    if grep -q '^A zz=3' "$TAPE3" 2>/dev/null; then
        ok "HS33 a later request's records reach the tape"
    else
        fail "HS33 later request missing from tape" "no 'A zz=3' record"
    fi
fi
kill "$SRV3_PID" 2>/dev/null || true
wait "$SRV3_PID" 2>/dev/null || true
rm -f "$SRV3" "$TAPE3" /tmp/eigs_http_srv3_$$.log

# ---- #877: a callable in any route slot raises at REGISTRATION ------------
# http_route's third element is a response body, not a callback — but the
# signature names it `handler`, so reaching for it with framework habits is
# foreseeable. It used to stringify: a live endpoint answered 200 with the
# debug repr `<fn hello>`, silently and remote-visibly. VAL_FN/VAL_BUILTIN are
# the only value types with no sensible body rendering, so they are the whole
# of the class; dicts/lists/numbers must still register.
SRV4=$(mktemp /tmp/eigs_http_srv4_XXXXXX.eigs)
cat > "$SRV4" <<'EIGS'
define hello as:
    return "hi"
slots is [["GET", "/f", hello],           # 3-el body: a function
          ["GET", "/b", len],             # 3-el body: a builtin
          ["GET", "/c", "code", hello],   # 4-el code form: source
          [hello, "/m", "x"],             # method
          ["GET", hello, "x"],            # path
          ["GET", "/k", hello, "src"]]    # 4-el kind
for s in slots:
    try:
        http_route of s
        print of "REGISTERED-A-CALLABLE"
    catch e:
        print of ("raised: " + e["kind"])
# Every non-callable body still registers.
print of (http_route of ["GET", "/ok", "pong"])
print of (http_route of ["GET", "/co", "code", "return 42"])
print of (http_route of ["GET", "/d", {"a": 1}])
print of (http_route of ["GET", "/n", 42])
EIGS
OUT4=$("$EIGS" "$SRV4" 2>&1)
RAISED=$(printf '%s\n' "$OUT4" | grep -c '^raised: type_mismatch')
REGD=$(printf '%s\n' "$OUT4" | grep -c '^route registered')
if [ "$RAISED" = "6" ] && [ "$REGD" = "4" ]; then
    ok "HS35 every callable route slot raises; every valid body still registers"
else
    fail "HS35 callable route slots (#877)" \
         "raised=$RAISED (want 6) registered=$REGD (want 4); output: $OUT4"
fi
if printf '%s\n' "$OUT4" | grep -q 'REGISTERED-A-CALLABLE'; then
    fail "HS35 a callable slot registered silently" "output: $OUT4"
else
    ok "HS35 no callable slot registers silently"
fi

# The error must land at registration, before the socket is listening — so an
# uncaught one aborts the program and http_serve is never reached.
PORT4=$(pick_port)
SRV5=$(mktemp /tmp/eigs_http_srv5_XXXXXX.eigs)
cat > "$SRV5" <<EIGS
define hello as:
    return "hi"
http_route of ["GET", "/fn", hello]
print of "UNREACHABLE-SERVE"
http_serve of $PORT4
EIGS
# `timeout` is load-bearing, not belt-and-braces: if this guard ever regresses,
# http_serve IS reached and serves forever, so an unbounded run would HANG the
# suite instead of failing it. Verified against a planted fault — without the
# guard this block reports rc=124 and fails, in ~5s.
OUT5=$(timeout 5 "$EIGS" "$SRV5" 2>&1); RC5=$?
if [ "$RC5" = "124" ]; then
    fail "HS35 callable body reached http_serve — server ran until killed" "output: $OUT5"
elif [ "$RC5" != "0" ] && ! printf '%s\n' "$OUT5" | grep -q 'UNREACHABLE-SERVE'; then
    ok "HS35 an uncaught callable body aborts before http_serve (rc=$RC5)"
else
    fail "HS35 callable body did not stop startup" "rc=$RC5 output: $OUT5"
fi
rm -f "$SRV4" "$SRV5"

echo "HTTP_SERVER: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then exit 1; fi
exit 0
