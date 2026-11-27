#!/usr/bin/env python3
"""#2374: lib/auth reads the bearer token from the request's ONE Authorization
header field (http_request_header), not from a scan of the request's text.

One row per line of the issue's table, each written to a socket as raw bytes
against a real server whose routes call lib/auth's require_auth and
auth_check. Rows 1, 4, 5 and 6 pass with the right token; rows 2, 3 and 7 are
refused, with the answer the library gives for a missing token. Before #2374
the scan passed rows 2 and 3 and refused rows 4, 5 and 6.

Run from the repository root: python3 tests/test_auth_header_2374.py
(EIGS_BIN selects the binary). The binary must be built with HTTP; suite
section [45k] probes for that and skips otherwise.
"""
import os
from pathlib import Path
import signal
import socket
import subprocess
import sys
import tempfile
import time

sys.path.insert(0, str(Path(__file__).resolve().parent))
from http_readiness import pick_port  # noqa: E402
from test_http_respond import clean, require  # noqa: E402

ROOT = Path(__file__).resolve().parents[1]
EIGS = Path(os.environ['EIGS_BIN']) if os.environ.get('EIGS_BIN') else ROOT / 'src/eigenscript'
TOKEN = b'eigen_good'
REFUSED_REQUIRE = b'{"error": "invalid or missing token"}'
REFUSED_CHECK = b'{"status": "error", "error": "invalid token"}'
OK_CHECK = b'{"status": "ok"}'

# (label, header lines, body, want pass). Row 3 is refused before any route:
# the server's door (#2370) answers 400 to a line that begins with a space,
# so it never reaches lib/auth; the row accepts that 400 and says so.
ROWS = [
    ('1 Authorization: Bearer good', [b'Authorization: Bearer ' + TOKEN], b'', True),
    ('2 no such header, the line in the body',
     [], b'x\r\nAuthorization: Bearer ' + TOKEN + b'\r\n', False),
    ('3 a line beginning with a space (a folded continuation)',
     [b'X-Other: a', b' Authorization: Bearer ' + TOKEN], b'', False),
    ('4 Authorization:Bearer good, nothing after the colon',
     [b'Authorization:Bearer ' + TOKEN], b'', True),
    ('5 Authorization:, two spaces, Bearer good',
     [b'Authorization:  Bearer ' + TOKEN], b'', True),
    ('6 Authorization:, a tab, Bearer good',
     [b'Authorization:\tBearer ' + TOKEN], b'', True),
    ('7 two Authorization fields',
     [b'Authorization: Bearer ' + TOKEN, b'Authorization: Bearer second'], b'', False),
]
# Controls the table implies: another scheme, the wrong token, the scheme in
# another case, several spaces after the scheme, no field at all.
CONTROLS = [
    ('C1 another scheme (Basic)', [b'Authorization: Basic ' + TOKEN], b'', False),
    ('C2 the wrong token', [b'Authorization: Bearer wrong'], b'', False),
    ('C3 bEaReR in mixed case', [b'Authorization: bEaReR ' + TOKEN], b'', True),
    ('C4 three spaces after the scheme', [b'Authorization: Bearer   ' + TOKEN], b'', True),
    ('C5 no Authorization field', [], b'', False),
]


def request(path, lines, body):
    method = b'POST' if body else b'GET'
    head = method + b' ' + path + b' HTTP/1.1\r\nHost: 127.0.0.1\r\n'
    head += b''.join(line + b'\r\n' for line in lines)
    if body:
        head += b'Content-Length: ' + str(len(body)).encode() + b'\r\n'
    return head + b'Connection: close\r\n\r\n' + body


DOOR_REFUSED = object()


def exchange(port, data, door_ok=False):
    with socket.create_connection(('127.0.0.1', port), timeout=30) as peer:
        peer.sendall(data)
        peer.shutdown(socket.SHUT_WR)
        chunks = []
        while True:
            chunk = peer.recv(65536)
            if not chunk:
                break
            chunks.append(chunk)
    response = b''.join(chunks)
    if door_ok and response.startswith(b'HTTP/1.1 400 '):
        return DOOR_REFUSED
    require(response.startswith(b'HTTP/1.1 200 '), f'status: {response[:300]!r}')
    head, sep, payload = response.partition(b'\r\n\r\n')
    require(bool(sep), f'response has no empty line: {response[:300]!r}')
    return payload


def route(method, path, code):
    import json
    return 'http_route of ' + json.dumps([method, path, 'code', code]) + '\n'


def main():
    port = pick_port()
    # A code route runs in a fresh env on the worker, so each request loads
    # the library and logs in the token itself.
    login = 'load_file of "lib/auth.eigs"\n_auth_token is "' + TOKEN.decode() + '"\n'
    source = ''
    for method in ('GET', 'POST'):
        source += route(method, '/require', login + 'answer is require_auth of null\nif answer == "":\n    answer is "PASSED"\nanswer')
        source += route(method, '/check', login + 'auth_check of null')
    source += 'http_route of ["GET", "/ready", "ready-2374"]\n'
    source += f'http_serve of {port}\n'
    passed = failed = 0
    with tempfile.TemporaryDirectory(prefix='eigs_auth_2374_') as tmp:
        script = Path(tmp) / 'server.eigs'
        script.write_text(source)
        env = os.environ.copy()
        env.pop('ADMIN_PASSWORD', None)
        with (Path(tmp) / 'server.log').open('w+') as log:
            proc = subprocess.Popen([str(EIGS), str(script)], cwd=ROOT, env=env,
                                    stdout=log, stderr=log)
            try:
                deadline = time.monotonic() + 30
                while True:
                    try:
                        if exchange(port, request(b'/ready', [], b'')) == b'ready-2374':
                            break
                    except (OSError, AssertionError):
                        pass
                    if time.monotonic() > deadline or proc.poll() is not None:
                        log.seek(0)
                        print(f'FAIL: server not ready rc={proc.poll()}: {log.read()}')
                        print('AUTH_HEADER_2374: 0 passed, 1 failed, 0 skipped')
                        return 1
                    time.sleep(.05)
                for label, lines, body, want in ROWS + CONTROLS:
                    try:
                        door_ok = label.startswith('3 ')
                        got_require = exchange(port, request(b'/require', lines, body), door_ok)
                        got_check = exchange(port, request(b'/check', lines, body), door_ok)
                        if got_require is DOOR_REFUSED or got_check is DOOR_REFUSED:
                            require(got_require is DOOR_REFUSED and got_check is DOOR_REFUSED,
                                    f'the door refused one route only: {got_require!r} {got_check!r}')
                            passed += 1
                            print(f'  PASS: row {label}: refused by the server with 400 before lib/auth')
                            continue
                        if want:
                            require(got_require == b'PASSED', f'require_auth refused: {got_require!r}')
                            require(got_check == OK_CHECK, f'auth_check refused: {got_check!r}')
                        else:
                            require(got_require == REFUSED_REQUIRE,
                                    f'require_auth did not refuse as for a missing token: {got_require!r}')
                            require(got_check == REFUSED_CHECK,
                                    f'auth_check did not refuse as for a missing token: {got_check!r}')
                        passed += 1
                        print(f'  PASS: row {label}: {"passes" if want else "refused"}')
                    except (AssertionError, OSError) as exc:
                        failed += 1
                        print(f'  FAIL: row {label}: {exc}')
            finally:
                if proc.poll() is None:
                    proc.terminate()
                try:
                    proc.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    proc.kill()
                    proc.wait()
                log.seek(0)
                output = log.read()
                try:
                    clean(output)
                    require(proc.returncode in (0, -signal.SIGTERM), f'server rc={proc.returncode}: {output}')
                except AssertionError as exc:
                    failed += 1
                    print(f'  FAIL: server exit: {exc}')
    print(f'AUTH_HEADER_2374: {passed} passed, {failed} failed, 0 skipped')
    return 1 if failed else 0


if __name__ == '__main__':
    sys.exit(main())
