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

# Serve forever.
serve is http_serve of $PORT
EIGS

# Start the server in the background.
"$EIGS" "$SRV" > /tmp/eigs_http_srv_$$.log 2>&1 &
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

# ---- CORS headers on OPTIONS ----
STATUS=$(curl -s --max-time 2 -X OPTIONS -o /dev/null -w "%{http_code}" \
         "http://127.0.0.1:$PORT/ping")
if [ "$STATUS" = "200" ]; then
    ok "HS07 OPTIONS preflight returns 200"
else
    fail "HS07 OPTIONS preflight" "status=$STATUS"
fi

# ---- Summary ----
echo ""
echo "HTTP_SERVER: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then exit 1; fi
exit 0
