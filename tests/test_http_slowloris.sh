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
# Suite runner exports EIGS at the binary under test (#1188). A default is
# only for a standalone invocation.
EIGS="${EIGS:-$SRC_DIR/eigenscript}"
# Cold-start budget (#1165). Shared CI runners were losing a 3 s poll;
# 30 s is generous and the poll is 100 ms so a fast server costs nothing.
READY_SECS="${EIGS_SLOWLORIS_READY_SECS:-30}"

PASS=0
FAIL=0
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1${2:+ ($2)}"; FAIL=$((FAIL+1)); }

# Plants drive the REAL script (this file without --self-test), so gutting
# wait_server would turn them red. Inner FAIL: lines stay in the capture.
sl_selftest() {
    local script real stub_never stub_exit3 stub_late out rc t0 t1 dt busy_port
    local st_fail=0
    script="$TESTS_DIR/test_http_slowloris.sh"
    real="$EIGS"
    # Not `local`: bash 3 function locals can vanish before an EXIT trap runs.
    SLST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/eigs-sl-st-XXXXXX")
    mkdir -p "$SLST_ROOT/tmp" "$SLST_ROOT/stubs"
    export TMPDIR="$SLST_ROOT/tmp"
    # ONE EXIT trap: it REPLACES, it does not accumulate (mechanical-gates §7).
    # SL_BUSY_PID is plant 4's port holder; guarded because set -u is on.
    SL_BUSY_PID=""
    trap 'if [ -n "${SL_BUSY_PID:-}" ]; then kill "$SL_BUSY_PID" 2>/dev/null; fi; rm -rf -- "${SLST_ROOT:-}"' EXIT

    stub_never="$SLST_ROOT/stubs/never_bind"
    # `exec` is load-bearing: without it dash keeps the wrapper shell as the
    # pid the test knows about, cleanup kills only that shell, and `sleep`
    # is reparented to init and runs for 999 s after EVERY suite run
    # (measured: one orphan per --self-test invocation).
    printf '%s\n' '#!/bin/sh' 'exec sleep 999' > "$stub_never"
    chmod +x "$stub_never"

    stub_exit3="$SLST_ROOT/stubs/exit3"
    printf '%s\n' '#!/bin/sh' 'exit 3' > "$stub_exit3"
    chmod +x "$stub_exit3"

    stub_late="$SLST_ROOT/stubs/late"
    printf '%s\n' '#!/bin/sh' 'sleep 5' "exec \"${real}\" \"\$@\"" > "$stub_late"
    chmod +x "$stub_late"

    # Plant 1: candidate that never binds → deadline failure by name, rc 1,
    # HTTP_SLOWLORIS: 0 passed, 1 failed. Bound is 1 s so the plant is cheap;
    # production READY_SECS is 30.
    out="$SLST_ROOT/plant1.out"
    t0=$(date +%s)
    EIGS="$stub_never" EIGS_SLOWLORIS_READY_SECS=1 command bash "$script" >"$out" 2>&1
    rc=$?
    t1=$(date +%s)
    dt=$((t1 - t0))
    if [ "$rc" -eq 1 ] \
       && grep -q 'FAIL: server not ready within 1 s' "$out" \
       && grep -q 'HTTP_SLOWLORIS: 0 passed, 1 failed' "$out"; then
        echo "  PASS: plant 1 never-bind hits deadline by name (${dt}s)"
    else
        echo "  FAIL: plant 1 never-bind did not print the deadline failure by name (rc=$rc dt=${dt}s)"
        sed 's/^/      /' "$out" | tail -20
        st_fail=$((st_fail + 1))
    fi

    # Plant 2: stub that exits 3 immediately → "exited rc=3" by name, fast.
    out="$SLST_ROOT/plant2.out"
    t0=$(date +%s)
    EIGS="$stub_exit3" command bash "$script" >"$out" 2>&1
    rc=$?
    t1=$(date +%s)
    dt=$((t1 - t0))
    if [ "$rc" -eq 1 ] \
       && grep -q 'FAIL: server exited rc=3 before it was ready' "$out" \
       && [ "$dt" -lt 2 ]; then
        echo "  PASS: plant 2 exit-3 is named and fast (${dt}s)"
    else
        echo "  FAIL: plant 2 exit-3 did not print the exited-rc failure by name (rc=$rc dt=${dt}s)"
        sed 's/^/      /' "$out" | tail -20
        st_fail=$((st_fail + 1))
    fi

    # Plant 3 (control): real binary wrapped so the server starts 5 s late.
    # The 30 s budget must still let the 4 live checks PASS.
    out="$SLST_ROOT/plant3.out"
    EIGS="$stub_late" command bash "$script" >"$out" 2>&1
    rc=$?
    if [ "$rc" -eq 0 ] \
       && grep -q 'HTTP_SLOWLORIS: 4 passed, 0 failed' "$out"; then
        echo "  PASS: plant 3 late-start (sleep 5) still PASSes 4 checks"
    else
        echo "  FAIL: plant 3 late-start did not keep the 4 live checks green (rc=$rc)"
        sed 's/^/      /' "$out" | tail -30
        st_fail=$((st_fail + 1))
    fi

    # Plant 4 (#1231): the port the script picks is ALREADY BOUND. Round 1's
    # fixed-range RANDOM port lost this race on a shared CI runner and plant 3
    # went red for a reason unrelated to its claim. A holder process binds a
    # real port and keeps it; EIGS_SLOWLORIS_PORT hands that port to the FIRST
    # attempt only. The retry must ask the kernel, print the retry, and land
    # the four live checks green — so this plant measures the recovery, not
    # just the diagnosis.
    out="$SLST_ROOT/plant4.out"
    python3 -c 'import socket, sys, time
s = socket.socket()
s.bind(("127.0.0.1", 0))
s.listen(1)
sys.stdout.write("%d\n" % s.getsockname()[1])
sys.stdout.flush()
time.sleep(300)' > "$SLST_ROOT/busy.port" 2>/dev/null &
    SL_BUSY_PID=$!
    busy_port=""
    t0=$(date +%s)
    while [ -z "$busy_port" ]; do
        busy_port=$(head -1 "$SLST_ROOT/busy.port" 2>/dev/null)
        case "${busy_port:-}" in ''|*[!0-9]*) busy_port="" ;; esac
        [ -n "$busy_port" ] && break
        [ $(( $(date +%s) - t0 )) -ge 10 ] && break
        sleep 0.1
    done
    if [ -z "$busy_port" ]; then
        echo "  FAIL: plant 4 could not bind a port to hold — the plant never ran, so nothing was proved"
        st_fail=$((st_fail + 1))
    else
        EIGS_SLOWLORIS_PORT="$busy_port" command bash "$script" >"$out" 2>&1
        rc=$?
        if [ "$rc" -eq 0 ] \
           && grep -q "NOTE: port $busy_port was already in use — retrying once on a fresh port" "$out" \
           && grep -q 'HTTP_SLOWLORIS: 4 passed, 0 failed' "$out"; then
            echo "  PASS: plant 4 a bound port is retried once on a fresh one and the 4 checks still pass"
        else
            echo "  FAIL: plant 4 did not recover from a bound port (rc=$rc, held port $busy_port)"
            sed 's/^/      /' "$out" | tail -20
            st_fail=$((st_fail + 1))
        fi
    fi
    kill "$SL_BUSY_PID" 2>/dev/null
    wait "$SL_BUSY_PID" 2>/dev/null
    SL_BUSY_PID=""

    if [ "$st_fail" -eq 0 ]; then
        echo "HTTP_SLOWLORIS_SELFTEST: 4 passed, 0 failed"
        return 0
    fi
    echo "HTTP_SLOWLORIS_SELFTEST: $((4 - st_fail)) passed, $st_fail failed"
    return 1
}

if [ "${1:-}" = "--self-test" ] || [ "${1:-}" = "--selftest" ]; then
    sl_selftest
    exit $?
fi

if ! command -v python3 >/dev/null 2>&1; then
    echo "  SKIP: python3 not available"
    echo "HTTP_SLOWLORIS: 0 passed, 0 failed (skipped)"
    exit 0
fi

# PORT SELECTION (#1231). Round 1 drew the port from `(RANDOM % 10000) + 50000`
# and plant 3 runs this whole script a SECOND time while the live section's
# server is up, so two servers drew from the same range on one runner.
# Measured on PR #1225's head 1b5c64d, first CI pass: both `extensions` jobs
# failed inside [45b]'s own self-test with `bind: Address already in use` on
# port 53632, while the four LIVE checks were green — a control going red for
# a reason unrelated to its claim. The kernel knows which ports are free, so
# ask it instead of guessing. Bind-then-close is still a race against any
# other process, so the start is RETRIED ONCE on EADDRINUSE and the retry is
# printed: a flake nobody sees is a flake nobody fixes.
# Prints the port and nothing else.
pick_port() {
    local p
    p=$(python3 -c 'import socket
s = socket.socket()
s.bind(("127.0.0.1", 0))
print(s.getsockname()[1])
s.close()' 2>/dev/null)
    case "${p:-}" in
        ''|*[!0-9]*) p=$(( (RANDOM % 10000) + 50000 )) ;;
    esac
    printf '%s\n' "$p"
}

SRV=$(mktemp "${TMPDIR:-/tmp}/eigs_sl_srv_XXXXXX.eigs")
LOG="${TMPDIR:-/tmp}/eigs_sl_srv_$$.log"
PORT=""
SRV_PID=""
SRV_RC=0
cleanup() {
    if [ -n "$SRV_PID" ]; then
        kill "$SRV_PID" 2>/dev/null || true
        wait "$SRV_PID" 2>/dev/null || true
    fi
    rm -f "$SRV" "$LOG"
}
trap cleanup EXIT

# Readiness: poll every 100 ms up to READY_SECS. Fail BY NAME in each of the
# two ways — process gone, or deadline. A duration budget is not the witness;
# the named line is.
#
# kill -0 is not enough: an `exit 3` stub is a zombie until we wait, and
# kill -0 on a zombie succeeds, so plant 2 would wait out the deadline and
# print the wrong name. ps -o stat= reports Z on both Linux and Darwin.
server_gone() {
    if ! kill -0 "$1" 2>/dev/null; then
        return 0
    fi
    case "$(ps -o stat= -p "$1" 2>/dev/null || true)" in
        *Z*) return 0 ;;
    esac
    return 1
}
# The bound is a WALL-CLOCK deadline, not an iteration count. An iteration
# count of READY_SECS*10 assumes each round costs exactly the 0.1 s sleep;
# measured, a refused-connection round costs ~0.155 s (curl spawn + sleep), so
# a 30 s budget took 47 s and the failure line named a number that was not
# true. A `date`-based deadline makes the printed bound the bound.
# Starts the server on a port and waits for readiness. Returns 0 = ready,
# 1 = the server exited (its status in SRV_RC), 2 = the deadline expired.
# It prints NOTHING: the caller owns the verdict, because attempt 1 of 2 must
# not print a failure the retry then disproves.
start_and_wait() {
    local deadline
    # EIGS_SLOWLORIS_PORT is a SELF-TEST hook and nothing else: it pins the
    # FIRST attempt's port so plant 4 can hand this script a port it has
    # already bound. The RETRY always asks the kernel, which is the half the
    # plant measures.
    if [ -n "${EIGS_SLOWLORIS_PORT:-}" ] && [ "$SL_ATTEMPT" -eq 1 ]; then
        PORT="$EIGS_SLOWLORIS_PORT"
    else
        PORT=$(pick_port)
    fi
    cat > "$SRV" <<EIGS
r is http_route of ["GET", "/ping", "pong"]
serve is http_serve of $PORT
EIGS
    : > "$LOG"
    # Per-IP cap squeezed to 4 so the cap is testable from a single loopback
    # address. Header timeout/min-rate left at defaults (10s / 256 B/s).
    EIGS_HTTP_MAX_CONN_PER_IP=4 "$EIGS" "$SRV" > "$LOG" 2>&1 &
    SRV_PID=$!
    deadline=$(( $(date +%s) + READY_SECS ))
    while :; do
        if server_gone "$SRV_PID"; then
            wait "$SRV_PID"
            SRV_RC=$?
            SRV_PID=""
            return 1
        fi
        if curl -s --max-time 1 "http://127.0.0.1:$PORT/ping" >/dev/null 2>&1; then
            return 0
        fi
        # Deadline tested AFTER the probe, so the budget always buys at least
        # one full attempt even at READY_SECS=1 (the self-test's cheap bound).
        [ "$(date +%s)" -ge "$deadline" ] && return 2
        sleep 0.1
    done
}

SL_ATTEMPT=1
while :; do
    start_and_wait
    sl_start_rc=$?
    [ "$sl_start_rc" -eq 0 ] && break
    # ONE retry, and only for the one cause a retry can fix. Anything else —
    # a server that exited for its own reason, a deadline with a live server —
    # is the failure this section exists to report, by name, first time.
    if [ "$SL_ATTEMPT" -eq 1 ] && [ -f "$LOG" ] \
       && grep -qi 'address already in use' "$LOG"; then
        echo "  NOTE: port $PORT was already in use — retrying once on a fresh port (#1231)"
        if [ -n "$SRV_PID" ]; then
            kill "$SRV_PID" 2>/dev/null || true
            wait "$SRV_PID" 2>/dev/null || true
            SRV_PID=""
        fi
        SL_ATTEMPT=2
        continue
    fi
    if [ "$sl_start_rc" -eq 1 ]; then
        echo "  FAIL: server exited rc=$SRV_RC before it was ready"
    else
        echo "  FAIL: server not ready within ${READY_SECS} s"
    fi
    [ -f "$LOG" ] && head -20 "$LOG"
    echo "HTTP_SLOWLORIS: 0 passed, 1 failed"
    exit 1
done

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
