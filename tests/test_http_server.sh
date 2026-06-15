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

# Pick a random high port to avoid collisions in CI.
PORT=$(( (RANDOM % 10000) + 40000 ))

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

# Wait for server to accept connections (up to ~3 seconds).
for _ in $(seq 1 30); do
    if curl -s --max-time 1 "http://127.0.0.1:$PORT/ping" > /dev/null 2>&1; then
        break
    fi
    sleep 0.1
done

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

# ---- Summary ----
echo ""
echo "HTTP_SERVER: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then exit 1; fi
exit 0
