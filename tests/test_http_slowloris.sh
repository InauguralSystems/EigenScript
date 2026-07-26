#!/bin/bash
# Slow-loris hardening (ext_http.c): a directly-exposed thread-per-connection
# server must not let a single source hold every worker slot, and must not let a
# byte-per-second trickle hold a slot for the full request deadline. Three
# checks, driven from loopback against a server tuned with a low per-IP cap:
#
#   SL1  per-IP connection cap: with the cap at 4, a 5th concurrent connection
#        from the same address is shed with 503 (the global 256 cap is not the
#        only gate).
#   SL2  minimum header data-rate: a partial-header-then-trickle connection is
#        dropped in a few seconds (408), not held to the 30s total deadline.
#   SL3  no false positive: a normal, fast, complete request still succeeds —
#        the header-phase bounds never fire for a real client.
#
# This is the regression gate for the live-verified finding (EigenScript #718).
set -u
TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC_DIR="$(cd "$TESTS_DIR/.." && pwd)/src"
EIGS="$SRC_DIR/eigenscript"

PASS=0
FAIL=0
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1${2:+ ($2)}"; FAIL=$((FAIL+1)); }

if ! command -v python3 >/dev/null 2>&1; then
    echo "  SKIP: python3 not available"
    echo "HTTP_SLOWLORIS: 0 passed, 0 failed (skipped)"
    exit 0
fi

PORT=$(( (RANDOM % 10000) + 50000 ))
SRV=$(mktemp /tmp/eigs_sl_srv_XXXXXX.eigs)
cat > "$SRV" <<EIGS
r is http_route of ["GET", "/ping", "pong"]
serve is http_serve of $PORT
EIGS

# Per-IP cap squeezed to 4 so the cap is testable from a single loopback
# address. Header timeout/min-rate left at defaults (10s / 256 B/s).
EIGS_HTTP_MAX_CONN_PER_IP=4 "$EIGS" "$SRV" > /tmp/eigs_sl_srv_$$.log 2>&1 &
SRV_PID=$!
cleanup() {
    kill "$SRV_PID" 2>/dev/null || true
    wait "$SRV_PID" 2>/dev/null || true
    rm -f "$SRV" /tmp/eigs_sl_srv_$$.log
}
trap cleanup EXIT

for _ in $(seq 1 30); do
    curl -s --max-time 1 "http://127.0.0.1:$PORT/ping" >/dev/null 2>&1 && break
    sleep 0.1
done
if ! curl -s --max-time 1 "http://127.0.0.1:$PORT/ping" >/dev/null 2>&1; then
    echo "  FAIL: server never came up on port $PORT"
    head -20 /tmp/eigs_sl_srv_$$.log
    echo "HTTP_SLOWLORIS: 0 passed, 1 failed"
    exit 1
fi

RESULT=$(PORT="$PORT" python3 - <<'PY'
import socket, time, os
PORT = int(os.environ["PORT"]); HOST = "127.0.0.1"

def status_line(resp):
    return resp.split(b"\r\n", 1)[0].decode("latin1") if resp else ""

def recv_all(s, budget=5.0):
    # Drain until the server closes (it sends "Connection: close") or budget
    # expires. A single recv can catch only the header segment — send_response
    # writes header and body as separate writes — so read in a loop.
    s.settimeout(budget); out = b""; t0 = time.time()
    while time.time() - t0 < budget:
        try:
            chunk = s.recv(4096)
        except socket.timeout:
            break
        if not chunk:
            break
        out += chunk
    return out

# ---- SL1: per-IP cap (cap=4) ----
holders = []
for _ in range(4):
    s = socket.socket(); s.settimeout(8); s.connect((HOST, PORT))
    s.sendall(b"GET /ping HTTP/1.1\r\n")   # partial header, holds a worker
    holders.append(s)
time.sleep(0.5)   # let the accept loop register all four as live workers
# 5th connection from the same address — must be shed by the per-IP cap. The
# reject path close()s without draining the request, so the client may read the
# 503 OR get an RST (ECONNRESET); either proves the connection was refused
# (an unpatched server accepts it and returns 200 "pong").
try:
    p = socket.socket(); p.settimeout(4); p.connect((HOST, PORT))
    p.sendall(b"GET /ping HTTP/1.1\r\nHost: x\r\n\r\n")
    r = recv_all(p, 4.0); p.close()
    refused = ("503" in status_line(r)) or (r == b"")
    print("SL1", refused, status_line(r) or "reset/empty")
except (ConnectionResetError, BrokenPipeError):
    print("SL1", True, "connection reset (refused)")
except Exception as e:
    print("SL1", False, f"exc:{e}")
for s in holders:
    try: s.close()
    except Exception: pass
time.sleep(6)   # let the held workers time out and free their slots

# ---- SL2: trickle dropped fast by the min-rate floor ----
t0 = time.time(); verdict = ("SL2", False, "no-close")
try:
    s = socket.socket(); s.settimeout(15); s.connect((HOST, PORT))
    s.sendall(b"GET /ping HTTP/1.1\r\n")   # start headers, then trickle
    got = b""
    while time.time() - t0 < 12:
        try:
            s.sendall(b"X")                # ~1 byte/sec, never terminate
        except (BrokenPipeError, ConnectionResetError):
            break
        s.settimeout(1.2)
        try:
            chunk = s.recv(256)
            if chunk:
                got = chunk; break         # server answered (expect 408) + will close
            else:
                break                      # clean EOF: server closed on us
        except socket.timeout:
            continue
    dt = time.time() - t0
    sl = status_line(got)
    # Pass if the server let go quickly (well under the 30s total deadline),
    # ideally with a 408. Either a 408 or an early close counts as "dropped".
    dropped_fast = dt < 9.0
    is_408 = "408" in sl
    verdict = ("SL2", dropped_fast and (is_408 or got == b""), f"{dt:.1f}s status={sl or 'closed'}")
    s.close()
except Exception as e:
    verdict = ("SL2", False, f"exc:{e}")
print(*verdict)

# ---- SL3: a normal fast request is unaffected ----
try:
    s = socket.socket(); s.settimeout(4); s.connect((HOST, PORT))
    s.sendall(b"GET /ping HTTP/1.1\r\nHost: x\r\n\r\n")
    r = recv_all(s, 4.0); s.close()
    ok200 = "200" in status_line(r) and b"pong" in r
    print("SL3", ok200, status_line(r))
except Exception as e:
    print("SL3", False, f"exc:{e}")
PY
)

echo "$RESULT" | while read -r tag good detail; do :; done  # (no-op; parse below)

check() {  # tag human-text
    line=$(echo "$RESULT" | grep "^$1 ")
    if echo "$line" | grep -q "^$1 True"; then
        ok "$1 $2"
    else
        fail "$1 $2" "$(echo "$line" | cut -d' ' -f3-)"
    fi
}
check SL1 "5th concurrent conn from one IP shed with 503 (per-IP cap)"
check SL2 "partial-then-trickle dropped in seconds, not held to the deadline"
check SL3 "normal fast request unaffected by header-phase bounds"

# Server must still be healthy after the battery.
if curl -s --max-time 2 "http://127.0.0.1:$PORT/ping" | grep -q pong; then
    ok "SL4 server healthy after slow-loris battery"
else
    fail "SL4 server health after battery"
fi

echo "HTTP_SLOWLORIS: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
