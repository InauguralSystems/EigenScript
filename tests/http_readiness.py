"""HTTP readiness oracle. No binary rebuilds in --selftest.

Response cases have independent status/type/body oracles, then the header arm is
compared byte-for-byte with the no-header arm (including all original headers).
Selftest drives the SAME curl/parser/checker through a loopback fake server for
old-200, missing/replaced headers, changed framing/body/type, and timing faults.
Validation cases use the SAME process/loud-error/listener checker on bad results.
"""
import contextlib
import dataclasses
import io
import os
from pathlib import Path
import random
import select
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import threading
import time

ROOT = Path(__file__).resolve().parents[1]
EIGS = Path(os.environ['EIGS_BIN']) if os.environ.get('EIGS_BIN') else ROOT / 'src/eigenscript'
HEADERS = {'x-eigen-release': 'build-readiness-1128', 'x-test-id': 'second value\twith tab'}
PASS = FAIL = 0
REQUIRE_EVALS = 0
# Must match HTTP_MAX_CONCURRENT_CONNS in src/ext_http.c — the init table
# and the serving accept loop shed at this number.
INIT_CAP = 256
HTTP_INIT_DEADLINE = 1.0


def require(ok, message):
    global REQUIRE_EVALS
    REQUIRE_EVALS += 1
    if not ok:
        raise AssertionError(message)


def run_check(name, fn):
    global PASS, FAIL, REQUIRE_EVALS
    before = REQUIRE_EVALS
    try:
        fn()
        if REQUIRE_EVALS <= before:
            raise AssertionError('check evaluated zero requirements')
    except Exception as exc:
        print(f'  FAIL: {name}: {exc}', flush=True)
        FAIL += 1
    else:
        print(f'  PASS: {name}', flush=True)
        PASS += 1


def require_population(work):
    before = PASS + FAIL
    work()
    require(PASS + FAIL > before, 'zero checks executed in production population')


def require_filled(holders, n, what):
    require(n > 0, f'{what}: want empty population')
    require(len(holders) == n, f'{what}: filled {len(holders)} want {n}')


def for_each_holder(holders, fn, what='holders'):
    require(len(holders) > 0, f'{what}: empty population')
    n = 0
    for item in holders:
        fn(item)
        n += 1
    require(n == len(holders) and n > 0, f'{what}: examined {n} of {len(holders)}')


def cases_for_phase(phase):
    return [c for c in CASES if c.phase == phase]


def invalid_rows():
    return list(INVALID)


def max_header_rows(which):
    if which == 'init':
        return [CASES[0], CASES[2]]
    return [c for c in CASES if c.name in ['R1-ready-page', 'R3-options']]


def global_cap_rows():
    return [c for c in CASES if c.phase == 'global-cap']


def empty_production_control():
    # Plant the actual deletion, not just zero inputs to the final reporter.
    # The old setup wrapper counted itself as a PASS when BOTH workers were
    # replaced with no-ops (measured: 1 passed, 0 failed, rc=0).
    global live_cases, invalid_cases, PASS, FAIL
    saved = live_cases, invalid_cases, PASS, FAIL, sys.argv
    output = io.StringIO()
    try:
        live_cases = invalid_cases = lambda directory: None
        PASS = FAIL = 0
        sys.argv = ['http_readiness.py']
        with contextlib.redirect_stdout(output):
            try:
                rc = main()
            except AssertionError as exc:
                require('zero checks' in str(exc), f'empty gate failed for wrong reason: {exc}')
                rc = 1
        require(rc != 0, 'deleting both production populations passed the real entry point')
    finally:
        live_cases, invalid_cases, PASS, FAIL, sys.argv = saved
    expect_red(lambda: finish(0, 0), 'zero final count')


def finish(passed, failed, label='HTTP_READINESS'):
    require(passed + failed > 0, 'zero checks executed')
    print(f'{label}: {passed} passed, {failed} failed', flush=True)
    return int(failed != 0)


def pick_port():
    # #760: below the ephemeral range; a bind probe also rejects occupied ports.
    try:
        high = int(Path('/proc/sys/net/ipv4/ip_local_port_range').read_text().split()[0]) - 1
    except OSError:
        high = 32767
    for _ in range(100):
        port = random.randint(max(1024, high - 11999), high)
        with socket.socket() as s:
            try:
                s.bind(('127.0.0.1', port))
                return port
            except OSError:
                pass
    raise AssertionError('SETUP no free port below ephemeral range')


def wait_ready(test, process, seconds=15):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        require(process.poll() is None, f'SETUP server exited rc={process.returncode}')
        if test():
            return
        time.sleep(.025)
    raise AssertionError('SETUP wall-clock readiness deadline expired')


@dataclasses.dataclass
class Response:
    status: int
    headers: dict
    body: bytes
    rc: int = 0


def parse_response(raw, body, rc=0):
    lines = raw.split(b'\r\n')
    require(lines and lines[0].startswith(b'HTTP/1.1 '), 'missing HTTP/1.1 status')
    headers = {}
    for line in lines[1:]:
        if not line:
            continue
        require(b':' in line, f'malformed header {line!r}')
        k, v = line.split(b':', 1)
        headers.setdefault(k.decode('ascii').lower(), []).append(v.decode('ascii').strip(' \t'))
    return Response(int(lines[0].split()[1]), headers, body, rc)


def case_named(name):
    return next(c for c in CASES if c.name == name)


def curl(port, method, path, directory, extra=(), max_time=1):
    h, b = directory/'headers', directory/'body'
    h.write_bytes(b''); b.write_bytes(b'')
    cmd = ['curl', '--noproxy', '*', '-sS', '--max-time', str(max_time), '-D', str(h), '-o', str(b)]
    cmd += ['-I'] if method == 'HEAD' else ['-X', method]
    p = subprocess.run(cmd + list(extra) + [f'http://127.0.0.1:{port}{path}'],
                       capture_output=True, timeout=max(3, float(max_time) + 2))
    # -I duplicates the headers into curl's body output; HEAD wire-body is also
    # checked over a raw socket below, never inferred from curl -I alone.
    return parse_response(h.read_bytes(), b'' if method == 'HEAD' else b.read_bytes(), p.returncode)


def _recv_until(sock, data, pred):
    while not pred(data):
        try:
            chunk = sock.recv(65536)
        except ConnectionResetError:
            break
        if not chunk:
            break
        data += chunk
    return data


def recv_http_truncated(sock, timeout=3):
    """Old reader: body is only the bytes that arrived with the header CRLF.
    Planted in --selftest; must not be used on the production path."""
    sock.settimeout(timeout)
    data = _recv_until(sock, b'', lambda d: b'\r\n\r\n' in d)
    require(b'\r\n\r\n' in data, f'incomplete raw response ({len(data)} bytes empty-EOF={int(not data)})')
    header, body = data.split(b'\r\n\r\n', 1)
    return parse_response(header, body)


def recv_http(sock, timeout=3, head=False):
    sock.settimeout(timeout)
    data = _recv_until(sock, b'', lambda d: b'\r\n\r\n' in d)
    require(b'\r\n\r\n' in data, f'incomplete raw response ({len(data)} bytes empty-EOF={int(not data)})')
    header, body = data.split(b'\r\n\r\n', 1)
    parsed = parse_response(header, body)
    cl = parsed.headers.get('content-length')
    if head or cl is None:
        body = _recv_until(sock, body, lambda _d: False)
        return parse_response(header, body)
    want = int(cl[0])
    while len(body) < want:
        try:
            chunk = sock.recv(65536)
        except ConnectionResetError:
            chunk = b''
        if not chunk:
            require(False, f'short body: got {len(body)} want {want}')
        body += chunk
    return parse_response(header, body[:want])


def raw_request(port, request, timeout=2):
    head = bool(request) and request.startswith(b'HEAD ')
    with socket.create_connection(('127.0.0.1', port), timeout) as s:
        s.settimeout(timeout)
        if request:
            s.sendall(request)
        return recv_http(s, timeout, head=head)


@dataclasses.dataclass(frozen=True)
class Case:
    name: str
    method: str
    path: str
    status: int
    ctype: str | None
    body: bytes
    phase: str = 'ready'
    extra: tuple = ()


CASES = [
    Case('R1-init-page', 'GET', '/', 503, 'text/plain', b'Server initializing\n', 'init'),
    Case('R1-init-static', 'GET', '/static/asset.txt', 503, 'text/plain', b'Server initializing\n', 'init'),
    Case('R2-live-get', 'GET', '/livez', 200, 'text/plain', b'OK', 'init'),
    Case('R2-live-head', 'HEAD', '/livez', 200, 'text/plain', b'OK', 'init'),
    *[Case('R2-exact-'+str(i), m, p, 503, 'text/plain', b'Server initializing\n', 'init')
      for i, (m, p) in enumerate([('GET','/livez/'), ('GET','/livezz'), ('GET','/livez?x=1'),
                                 ('POST','/livez'), ('OPTIONS','/'), ('HEAD','/'), ('DELETE','/'), ('PATCH','/static/asset.txt')])],
    Case('R1-ready-page', 'GET', '/', 200, 'text/plain', b'real-page'),
    Case('R1-ready-static', 'GET', '/static/asset.txt', 200, 'application/octet-stream', b'real-asset\n'),
    Case('R3-file', 'GET', '/file', 200, 'application/octet-stream', b'real-asset\n'),
    Case('R3-code', 'GET', '/code', 200, 'text/plain', b'code-body'),
    Case('R3-authed', 'GET', '/authed', 200, 'text/plain', b'authed-body'),
    Case('R3-head', 'HEAD', '/static/asset.txt', 200, 'application/octet-stream', b'real-asset\n'),
    Case('R3-options', 'OPTIONS', '/', 204, None, b''),
    Case('R3-413', 'GET', '/static/huge', 413, 'text/plain', b'File too large'),
    Case('R3-403', 'GET', '/static//x', 403, 'text/plain', b'Forbidden'),
    Case('R3-500', 'GET', '/needauth', 500, 'application/json',
         b'{"error": "require_auth not defined or not callable"}'),
    Case('R3-401', 'GET', '/denied', 401, 'application/json', b'denied', 'auth'),
    Case('R3-408', 'GET', '/', 408, 'text/plain', b'Request header timeout', 'timeout'),
    Case('R3-431', 'GET', '/', 431, 'text/plain', b'Headers too large', 'oversize'),
    Case('R3-404', 'GET', '/missing', 404, 'application/json', b'{"error": "not_found"}'),
    Case('R2-live-retired', 'GET', '/livez', 404, 'application/json', b'{"error": "not_found"}'),
    Case('R3-400', 'POST', '/', 400, 'text/plain', b'Invalid Content-Length', extra=('-H','Content-Length: -1')),
    Case('R3-global-cap', 'GET', '/', 503, 'text/plain', b'', 'global-cap'),
    Case('R3-global-cap-head', 'HEAD', '/', 503, 'text/plain', b'', 'global-cap'),
    Case('R3-ip-cap', 'GET', '/', 503, 'text/plain', b'', 'cap'),
    Case('R3-ip-cap-head', 'HEAD', '/', 503, 'text/plain', b'', 'cap'),
    Case('R2-init-capacity-shed', 'GET', '/not-live', 503, 'text/plain', b'Server initializing\n', 'init'),
]


def check_response(case, got, registered, baseline=None, inside=True):
    require(got.rc == 0, f'curl rc={got.rc} (framing/timeout)')
    require(got.status == case.status, f'status {got.status} expected {case.status}')
    require(got.headers.get('content-type') == (None if case.ctype is None else [case.ctype]), 'Content-Type changed')
    require(got.headers.get('content-length') == (None if case.status == 204 else [str(len(case.body))]), 'Content-Length changed')
    require(got.body == (b'' if case.method == 'HEAD' else case.body), f'body bytes changed: {got.body[:80]!r}')
    for key, value in registered.items():
        require(got.headers.get(key) == [value], f'{key} missing, duplicated or wrong value')
    if case.phase == 'init':
        require(inside, 'request was not proved inside init window')
        if case.status == 503:
            require(got.headers.get('retry-after') == ['1'], '503 missing Retry-After: 1')
    if baseline:
        require(got.status == baseline.status and got.body == baseline.body, 'baseline status/body differ')
        rest = {k: v for k, v in got.headers.items() if k not in registered}
        require(rest == baseline.headers, 'non-registered headers differ from baseline')


@contextlib.contextmanager
def server(directory, with_headers=False, live=True, cors=True, delay=5, prelude='', max_headers=False, early='number', per_ip=4, header_min_rate=None, header_timeout=None, extra='', max_body=None, delay_spawn=True, ld_preload=None):
    port = pick_port()
    script, log_path = directory/'server.eigs', directory/'server.log'
    header1 = 'http_response_header of ["X-Eigen-Release", "old"]\n' if with_headers else ''
    header2 = ('http_response_header of ["x-eigen-release", "build-readiness-1128"]\n'
               'http_response_header of ["X-Test-Id", "second value\\twith tab"]\n') if with_headers else ''
    if max_headers:
        header1 = ''.join(f'http_response_header of ["{str(i).zfill(64)}", "'+ 'v'*1024 +'"]\n' for i in range(16))
        # Replacement at capacity must succeed, preserving a single field.
        header2 = f'http_response_header of ["{str(0).zfill(64)}", "'+ 'v'*1024 +'"]\n'
    bindarg = f'[{port}, "/livez"]' if live else ('null' if early == 'null' else str(port))
    script.write_text(prelude + ('http_cors of "*"\n' if cors else '') + header1 +
                      f'http_early_bind of {bindarg}\n' + header2 + 'print of "INIT-CONFIGURED"\n' +
                      (f'exec_capture of ["sleep", "{delay}"]\n' if delay_spawn
                       else f'usleep of {int(float(delay) * 1000000)}\n') +
                      'http_route of ["GET", "/", "real-page"]\n' +
                      f'http_static of ["/static", "{directory}"]\n' +
                      f'http_route of ["GET", "/file", "file", "{directory}/asset.txt"]\n' +
                      'http_route of ["GET", "/code", "code", "\\\"code-body\\\""]\n' +
                      'http_route_authed of ["GET", "/authed", "authed-body"]\n' +
                      'http_route_authed of ["GET", "/needauth", "code", "\\\"ok\\\""]\n' +
                      extra +
                      f'http_serve of {port}\n')
    (directory/'asset.txt').write_bytes(b'real-asset\n')
    with (directory/'huge').open('wb') as huge:
        huge.truncate(64 * 1024 * 1024 + 1)  # sparse; reaches 413 without allocating a body
    env = dict(os.environ, EIGS_HTTP_MAX_CONN_PER_IP=str(per_ip))
    if header_min_rate is not None:
        env['EIGS_HTTP_HEADER_MIN_RATE'] = str(header_min_rate)
    if header_timeout is not None:
        env['EIGS_HTTP_HEADER_TIMEOUT'] = str(header_timeout)
    if max_body is not None:
        env['EIGS_HTTP_MAX_BODY'] = str(max_body)
    env.pop('PORT', None)
    if early == 'null':
        env['PORT'] = str(port)
    if ld_preload:
        prev = env.get('LD_PRELOAD', '')
        env['LD_PRELOAD'] = str(ld_preload) + ((':' + prev) if prev else '')
    with log_path.open('w') as log:
        proc = subprocess.Popen([str(EIGS), str(script)], cwd=ROOT/'src', env=env, stdout=log, stderr=log)
        try:
            wait_ready(lambda: 'INIT-CONFIGURED' in log_path.read_text(), proc)
            yield port, proc, log_path
        finally:
            proc.terminate()
            try:
                proc.wait(timeout=4)
            except subprocess.TimeoutExpired:
                proc.kill(); proc.wait()
            output = log_path.read_text()
            require(not any(x in output for x in ['AddressSanitizer', 'runtime error:', 'ThreadSanitizer']), output[-2000:])


@contextlib.contextmanager
def held_connections(port, count, payload=b'', keepalive=False):
    holders = []
    stop = threading.Event()
    drip = None
    try:
        for _ in range(count):
            sock = socket.create_connection(('127.0.0.1', port), 2)
            holders.append(sock)
            if payload:
                sock.sendall(payload)
        if keepalive:
            def _drip():
                while not stop.wait(1.0):
                    for sock in list(holders):
                        try:
                            sock.sendall(b'X')
                        except OSError:
                            pass
            drip = threading.Thread(target=_drip, daemon=True)
            drip.start()
        yield holders
    finally:
        stop.set()
        if drip is not None:
            drip.join(timeout=1)
        for sock in holders:
            sock.close()


def require_shed_wire(got, method):
    require(got.status == 503,
            f'status {got.status} expected 503 (liveness shed at cap; 200 means admitted past cap)')
    require(got.body == b'', f'shed {method} wire body {got.body!r} want empty')
    require(got.headers.get('content-length') == ['0'], 'shed Content-Length is not 0')
    require(got.headers.get('content-type') == ['text/plain'], 'shed Content-Type changed')
    require(got.headers.get('retry-after') == ['1'], '503 missing Retry-After: 1')
    for key, value in HEADERS.items():
        require(got.headers.get(key) == [value], f'{key} missing, duplicated or wrong value')


def check_capacity_livez_shed(port, inside, method='HEAD'):
    before = inside()
    start = time.monotonic()
    req = f'{method} /livez HTTP/1.1\r\nHost: x\r\n\r\n'.encode()
    with socket.create_connection(('127.0.0.1', port), 2) as sock:
        sock.sendall(req)
        got = recv_http(sock, head=(method == 'HEAD'))
    elapsed = time.monotonic() - start
    require_shed_wire(got, method)
    require(elapsed < .5, f'capacity shed delayed /livez by {elapsed:.3f}s (limit 0.5s)')
    require(before and inside(), 'request was not proved inside init window')
    print(f'    init-cap shed {method} /livez: {elapsed:.3f}s status={got.status} body={len(got.body)}', flush=True)


def check_init_latency(port, directory, case, inside):
    # The wall-clock bound is independent of status/framing: an eventual 200
    # after serial idle-client waits must be RED, even before curl's timeout.
    before = inside()
    start = time.monotonic()
    try:
        got = curl(port, case.method, case.path, directory, max_time=4)
    except AssertionError as exc:
        raise AssertionError(f'init probe failed after {time.monotonic()-start:.3f}s: {exc}') from exc
    elapsed = time.monotonic() - start
    check_response(case, got, HEADERS, inside=before and inside())
    require(elapsed < .5, f'other idle clients delayed {case.path} by {elapsed:.3f}s (limit 0.5s)')
    print(f'    init-idle latency {case.path}: {elapsed:.3f}s', flush=True)


def init_idle_cases(directory):
    live = case_named('R2-live-get')
    unready = case_named('R1-init-page')
    with server(directory, with_headers=True, delay=8) as (port, proc, log):
        inside = lambda: 'Starting HTTP server' not in log.read_text()
        with held_connections(port, 16) as holders:
            require_filled(holders, 16, 'idle')
            run_check('R2-liveness-under-idle-connections',
                      lambda: check_init_latency(port, directory, live, inside))
            run_check('R2-unready-under-idle-connections',
                      lambda: check_init_latency(port, directory, unready, inside))
            # A fragmented client retains its own read budget, while another
            # connection still answers promptly. A tiny serial read budget
            # cannot satisfy this control by dropping incomplete requests.
            def fragmented():
                before = inside()
                with socket.create_connection(('127.0.0.1', port), 2) as sock:
                    sock.settimeout(2)
                    sock.sendall(b'GET /li')
                    time.sleep(.12)
                    check_init_latency(port, directory, unready, inside)
                    sock.sendall(b'vez HTTP/1.1\r\nHost: x\r\n\r\n')
                    data = b''
                    while True:
                        chunk = sock.recv(65536)
                        if not chunk:
                            break
                        data += chunk
                require(b'\r\n\r\n' in data, 'incomplete fragmented liveness response')
                h, body = data.split(b'\r\n\r\n', 1)
                check_response(live, parse_response(h, body), HEADERS,
                               inside=before and inside())
            run_check('R2-init-fragmented-with-16-idle', fragmented)


def init_staller_cases(directory):
    live = case_named('R2-live-get')
    unready = case_named('R1-init-page')
    with server(directory, with_headers=True, delay=8) as (port, proc, log):
        inside = lambda: 'Starting HTTP server' not in log.read_text()
        holders = []
        try:
            for _ in range(32):
                holders.append(socket.create_connection(('127.0.0.1', port), 2))
            for _ in range(32):
                sock = socket.create_connection(('127.0.0.1', port), 2)
                sock.sendall(b'GET /li')
                holders.append(sock)
            require_filled(holders, 64, '64-stallers')
            run_check('R2-liveness-under-64-stallers',
                      lambda: check_init_latency(port, directory, live, inside))
            run_check('R2-unready-under-64-stallers',
                      lambda: check_init_latency(port, directory, unready, inside))
        finally:
            for sock in holders:
                sock.close()
    with server(directory, with_headers=True, delay=8) as (port, proc, log):
        inside = lambda: 'Starting HTTP server' not in log.read_text()
        filled = time.monotonic()
        with held_connections(port, INIT_CAP) as holders:
            require(time.monotonic() - filled < 0.8,
                    f'took {time.monotonic()-filled:.3f}s to hold {INIT_CAP} stallers; table may have expired')
            require_filled(holders, INIT_CAP, 'init-cap')
            require(not select.select(holders, [], [], 0)[0],
                    'init-cap holder already responded before shed probe')
            run_check('R2-init-capacity-shed',
                      lambda: check_capacity_livez_shed(port, inside, 'HEAD'))
            run_check('R2-init-capacity-shed-get',
                      lambda: check_capacity_livez_shed(port, inside, 'GET'))
            time.sleep(HTTP_INIT_DEADLINE + 0.2)
            run_check('R2-init-deadline-frees-slot',
                      lambda: check_init_latency(port, directory, live, inside))


def handoff_drain_cases(directory):
    # Incomplete request line (no CRLF) so the 1s deadline is the only other
    # reply; connect late in the init window so deadline has not fired when
    # http_serve joins the responder.
    case = Case('R2-handoff-drain', 'GET', '/', 503, 'text/plain', b'Server initializing\n', 'init')
    with server(directory, with_headers=True, delay=2) as (port, proc, log):
        holders = []
        try:
            time.sleep(1.3)
            require('Starting HTTP server' not in log.read_text(), 'handoff already happened before holders')
            for _ in range(16):
                sock = socket.create_connection(('127.0.0.1', port), 2)
                sock.sendall(b'GET / HTTP/1.1')
                holders.append(sock)
            require_filled(holders, 16, 'handoff-fill')
            wait_ready(lambda: 'accepting on pre-bound' in log.read_text(), proc)
            def one(sock):
                check_response(case, recv_http(sock), HEADERS, inside=True)
            for_each_holder(holders, one, 'handoff')
        finally:
            for sock in holders:
                sock.close()


def teardown_drain_cases(directory):
    port = pick_port()
    script, log_path = directory/'teardown.eigs', directory/'teardown.log'
    script.write_text(
        'http_response_header of ["x-eigen-release", "build-readiness-1128"]\n'
        'http_response_header of ["X-Test-Id", "second value\\twith tab"]\n'
        f'http_early_bind of [{port}, "/livez"]\n'
        'print of "INIT-CONFIGURED"\n'
        'exec_capture of ["sleep", "3"]\n'
    )
    env = dict(os.environ, EIGS_HTTP_MAX_CONN_PER_IP='4')
    env.pop('PORT', None)
    case = Case('R2-teardown-drain', 'HEAD', '/', 503, 'text/plain', b'Server initializing\n', 'init')
    with log_path.open('w') as log:
        proc = subprocess.Popen([str(EIGS), str(script)], cwd=ROOT/'src', env=env, stdout=log, stderr=log)
        holders = []
        try:
            wait_ready(lambda: 'INIT-CONFIGURED' in log_path.read_text(), proc)
            # Connect in the last ~0.7s of the 3s sleep so the 1s client
            # deadline cannot reply before destroy drains the table.
            time.sleep(2.3)
            for _ in range(16):
                sock = socket.create_connection(('127.0.0.1', port), 2)
                sock.sendall(b'HEAD / HTTP/1.1')
                holders.append(sock)
            require_filled(holders, 16, 'teardown-fill')
            try:
                rc = proc.wait(timeout=8)
            except subprocess.TimeoutExpired:
                proc.kill(); proc.wait()
                raise AssertionError('teardown script did not exit')
            require(rc == 0, f'teardown script rc={rc} log={log_path.read_text()[-400:]}')
            def one(sock):
                check_response(case, recv_http(sock, head=True), HEADERS, inside=True)
            for_each_holder(holders, one, 'teardown')
            require(not is_listening(port), 'port is still listening after natural exit')
        finally:
            if proc.poll() is None:
                proc.terminate()
                try:
                    proc.wait(timeout=4)
                except subprocess.TimeoutExpired:
                    proc.kill(); proc.wait()
            for sock in holders:
                sock.close()
            output = log_path.read_text()
            require(not any(x in output for x in ['AddressSanitizer', 'runtime error:', 'ThreadSanitizer']), output[-2000:])


def error_site_cases(directory):
    # 403/500 ride the default ready server via CASES. 401 needs a published
    # deny source; 408/431 need timeout/body-cap overrides.
    baseline = {}
    extra = ('shared_set of ["require_auth", "\\\"denied\\\""]\n'
             'http_route_authed of ["GET", "/denied", "code", "\\\"ok\\\""]\n')
    for headers in (False, True):
        with server(directory, with_headers=headers, delay=.05, extra=extra) as (port, proc, log):
            wait_ready(lambda: 'accepting on pre-bound' in log.read_text(), proc)
            case = case_named('R3-401')
            def check():
                got = curl(port, case.method, case.path, directory)
                check_response(case, got, HEADERS if headers else {},
                               baseline.get(case.name) if headers else None)
                if not headers:
                    baseline[case.name] = got
            run_check(case.name + ('-headers' if headers else '-baseline'), check)
    for headers in (False, True):
        with server(directory, with_headers=headers, delay=.05, header_timeout=1,
                    header_min_rate=0) as (port, proc, log):
            wait_ready(lambda: 'accepting on pre-bound' in log.read_text(), proc)
            case = case_named('R3-408')
            def check():
                # Read blocks up to 5s (SO_RCVTIMEO); a second byte after the
                # 1s header deadline wakes it so the 408 path is evaluated.
                with socket.create_connection(('127.0.0.1', port), 2) as sock:
                    sock.settimeout(4)
                    sock.sendall(b'GET / HTTP/1.1\r\nHost: x\r\n')
                    time.sleep(1.15)
                    sock.sendall(b'X')
                    got = recv_http(sock, timeout=4)
                check_response(case, got, HEADERS if headers else {},
                               baseline.get(case.name) if headers else None)
                if not headers:
                    baseline[case.name] = got
            run_check(case.name + ('-headers' if headers else '-baseline'), check)
    for headers in (False, True):
        with server(directory, with_headers=headers, delay=.05, max_body=1) as (port, proc, log):
            wait_ready(lambda: 'accepting on pre-bound' in log.read_text(), proc)
            case = case_named('R3-431')
            def check():
                got = raw_request(port, b'GET / HTTP/1.1\r\nHost: x\r\nX: ' + b'a' * 70000)
                check_response(case, got, HEADERS if headers else {},
                               baseline.get(case.name) if headers else None)
                if not headers:
                    baseline[case.name] = got
            run_check(case.name + ('-headers' if headers else '-baseline'), check)


def sigpipe_init_case(directory):
    # Delay with usleep (no spawn). exec_capture would install SIG_IGN itself
    # and hide deletion of the early-bind signal(SIGPIPE, SIG_IGN).
    with server(directory, with_headers=True, delay=5, delay_spawn=False) as (port, proc, log):
        script = (directory/'server.eigs').read_text()
        require('exec_capture' not in script, 'SIGPIPE case spawned')
        require('usleep of' in script, 'SIGPIPE case did not use usleep')
        for _ in range(64):
            sock = socket.create_connection(('127.0.0.1', port), 2)
            sock.sendall(b'GET / HTTP/1.1\r\n\r\n')
            sock.close()
        require(proc.poll() is None, 'init responder died (SIGPIPE?)')
        got = curl(port, 'GET', '/livez', directory)
        check_response(case_named('R2-live-get'), got, HEADERS, inside=True)


# Built once under build/; wraps accept/accept4 so a shed write can fill the
# send buffer. Production does not shrink SO_SNDBUF (#1136 witness).
_SNDBUF_INTERPOSER_C = r'''#define _GNU_SOURCE
#include <dlfcn.h>
#include <sys/socket.h>

static void shrink_sndbuf(int fd) {
    if (fd < 0) return;
    int size = 1024;
    setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &size, sizeof(size));
}

int accept(int fd, struct sockaddr *address, socklen_t *len) {
    int (*real_accept)(int, struct sockaddr *, socklen_t *) = dlsym(RTLD_NEXT, "accept");
    int result = real_accept(fd, address, len);
    shrink_sndbuf(result);
    return result;
}

int accept4(int fd, struct sockaddr *address, socklen_t *len, int flags) {
    int (*real_accept4)(int, struct sockaddr *, socklen_t *, int) = dlsym(RTLD_NEXT, "accept4");
    int result = real_accept4(fd, address, len, flags);
    shrink_sndbuf(result);
    return result;
}
'''
_SNDBUF_SO = None


def small_sndbuf_so():
    """Compile the accept() SO_SNDBUF interposer once into build/. None if
    this platform cannot LD_PRELOAD it (no cc, or not Linux)."""
    global _SNDBUF_SO
    if _SNDBUF_SO is not None:
        return _SNDBUF_SO
    if sys.platform != 'linux' or not shutil.which('cc'):
        return None
    dest = ROOT / 'build' / 'http_readiness_sndbuf'
    dest.mkdir(parents=True, exist_ok=True)
    src, so = dest / 'small_sndbuf.c', dest / 'small_sndbuf.so'
    if not src.exists() or src.read_text() != _SNDBUF_INTERPOSER_C:
        src.write_text(_SNDBUF_INTERPOSER_C)
    if not so.exists() or so.stat().st_mtime < src.stat().st_mtime:
        subprocess.check_call(['cc', '-shared', '-fPIC', '-o', str(so), str(src), '-ldl'])
    _SNDBUF_SO = so
    return so


def shed_backpressure_case(directory):
    # 256 idle holders, sixteen max-size registered headers, a shed peer that
    # stops reading. LD_PRELOAD shrinks accept-side SO_SNDBUF so SO_SNDTIMEO
    # can fire; production does not change the send buffer. The 503 is
    # witnessed via MSG_PEEK without draining (#1136).
    so = small_sndbuf_so()
    require(so is not None, 'backpressure case ran without an interposer')
    with server(directory, max_headers=True, delay=.5, delay_spawn=False, cors=False,
                ld_preload=so) as (port, proc, log):
        started = time.monotonic()
        with held_connections(port, INIT_CAP) as holders:
            require_filled(holders, INIT_CAP, 'backpressure-holders')
            require(not select.select(holders, [], [], 0)[0],
                    'backpressure holder already responded')
            blocker = socket.socket()
            try:
                blocker.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 1024)
                blocker.settimeout(2)
                blocker.connect(('127.0.0.1', port))
                blocker.sendall(b'HEAD /livez HTTP/1.1\r\nHost: x\r\n\r\n')
                time.sleep(.1)
                peek = blocker.recv(64, socket.MSG_PEEK)
                require(b'HTTP/1.1 503' in peek,
                        f'shed 503 not witnessed via MSG_PEEK: {peek!r}')
                deadline = started + 2.8
                while 'accepting on pre-bound' not in log.read_text() and time.monotonic() < deadline:
                    require(proc.poll() is None, 'init responder died under backpressure')
                    time.sleep(.025)
                require('accepting on pre-bound' in log.read_text(),
                        f'server not ready within 2.8s while non-reading shed peer open '
                        f'({time.monotonic()-started:.2f}s)')
                require(proc.poll() is None, 'process died under backpressure')
            finally:
                blocker.close()


def empty_value_case(directory):
    prelude = 'http_response_header of ["X-Empty", ""]\n'
    registered = {**HEADERS, 'x-empty': ''}
    case = case_named('R1-ready-page')
    def check():
        with server(directory, with_headers=True, delay=.05, prelude=prelude) as (port, proc, log):
            wait_ready(lambda: 'accepting on pre-bound' in log.read_text(), proc)
            got = curl(port, case.method, case.path, directory)
            check_response(case, got, registered)
            require(got.headers.get('x-empty') == [''], 'empty header value missing')
    run_check('R3-empty-value', check)


def global_cap_cases(directory):
    # Per-IP cap is disabled so the 257th hits the global 256 cap; header
    # min-rate 0 keeps incomplete holders from 408-ing. HEAD and GET must
    # both see a bodyless 503 (the accept loop sheds before reading).
    baseline = {}
    rows = global_cap_rows()
    for headers in (False, True):
        with server(directory, with_headers=headers, delay=.05, per_ip=0,
                    header_min_rate=0, header_timeout=30) as (port, proc, log):
            wait_ready(lambda: 'accepting on pre-bound' in log.read_text(), proc)
            # No request is sent by the 257th socket: shedding precedes reads.
            # All holders have incomplete headers, so no worker may finish.
            with held_connections(port, 256, b'GET / HTTP/1.1\r\n', keepalive=True) as holders:
                time.sleep(.2)
                def one(case):
                    def check():
                        require_filled(holders, 256, 'global-cap')
                        req = (b'HEAD / HTTP/1.1\r\nHost: x\r\n\r\n'
                               if case.method == 'HEAD' else b'')
                        got = raw_request(port, req)
                        # Pin the setup too: a prior slot being shed/timed out must
                        # not masquerade as 256 held connections.
                        require(not select.select(holders, [], [], 0)[0],
                                'global-cap holder already responded/closed')
                        check_response(case, got, HEADERS if headers else {},
                                       baseline.get(case.name) if headers else None)
                        if not headers:
                            baseline[case.name] = got
                    run_check(case.name + ('-headers' if headers else '-baseline'), check)
                for_each_holder(rows, one, 'global-cap cases')


def live_cases(directory):
    baseline = {}
    for headers in [False, True]:
        with server(directory, headers) as (port, proc, log):
            for phase in ['init', 'ready', 'cap']:
                if phase == 'ready':
                    wait_ready(lambda: 'accepting on pre-bound' in log.read_text(), proc)
                holders = []
                try:
                    if phase == 'cap':
                        time.sleep(.15)
                        for _ in range(4):
                            sock = socket.create_connection(('127.0.0.1', port), 2)
                            sock.sendall(b'GET / HTTP/1.1\r\n')
                            holders.append(sock)
                        time.sleep(.15)
                    def one(case):
                        def check():
                            before = 'Starting HTTP server' not in log.read_text()
                            if case.phase == 'cap':
                                # Shed replies before reading. HEAD still sends a
                                # request line so the method is on the wire; GET
                                # keeps the empty-write that avoids RST on the
                                # unread buffer.
                                req = (f'HEAD {case.path} HTTP/1.1\r\nHost: x\r\n\r\n'.encode()
                                       if case.method == 'HEAD' else b'')
                                got = raw_request(port, req)
                            elif case.method == 'HEAD':
                                got = raw_request(port, f'HEAD {case.path} HTTP/1.1\r\nHost: x\r\n\r\n'.encode())
                            else:
                                got = curl(port, case.method, case.path, directory, case.extra)
                            inside = before and 'Starting HTTP server' not in log.read_text()
                            check_response(case, got, HEADERS if headers else {}, baseline.get(case.name) if headers else None, inside)
                            if not headers:
                                baseline[case.name] = got
                        run_check(case.name + ('-headers' if headers else '-baseline'), check)
                    for_each_holder(cases_for_phase(phase), one, f'{phase} cases')
                finally:
                    for sock in holders:
                        sock.close()
    # Both old spellings configure NO implicit liveness path, including PORT override.
    spellings = ['number', 'null']
    def one_spelling(early):
        with server(directory, live=False, cors=False, early=early) as (port, proc, log):
            def one_path(path):
                case = Case('R2-no-live-'+early+path, 'GET', path, 503, 'text/plain', b'Server initializing\n', 'init')
                run_check(case.name, lambda: check_response(case, curl(port, 'GET', path, directory), {}, inside='Starting HTTP server' not in log.read_text()))
            for_each_holder(['/', '/livez'], one_path, f'no-live-{early} paths')
    for_each_holder(spellings, one_spelling, 'no-live spellings')
    with server(directory, cors=False, max_headers=True) as (port, proc, log):
        huge = {str(i).zfill(64): 'v'*1024 for i in range(16)}
        def one_init(case):
            run_check('R3-max-16x1088-'+case.name, lambda: check_response(case, curl(port, case.method, case.path, directory), huge, inside='Starting HTTP server' not in log.read_text()))
        for_each_holder(max_header_rows('init'), one_init, 'max-headers-init')
        wait_ready(lambda: 'accepting on pre-bound' in log.read_text(), proc)
        def one_ready(case):
            run_check('R3-max-16x1088-'+case.name, lambda: check_response(case, curl(port, case.method, case.path, directory), huge))
        for_each_holder(max_header_rows('ready'), one_ready, 'max-headers-ready')
    require_population(lambda: init_idle_cases(directory))
    require_population(lambda: init_staller_cases(directory))
    require_population(lambda: global_cap_cases(directory))
    require_population(lambda: error_site_cases(directory))
    require_population(lambda: empty_value_case(directory))
    run_check('R2-init-sigpipe-safe', lambda: sigpipe_init_case(directory))
    run_check('R2-handoff-drain', lambda: handoff_drain_cases(directory))
    run_check('R2-teardown-drain', lambda: teardown_drain_cases(directory))
    if small_sndbuf_so() is None:
        why = 'no cc' if not shutil.which('cc') else 'LD_PRELOAD not usable on ' + sys.platform
        print(f'  SKIP: R2-init-shed-write-deadline: {why} for accept SO_SNDBUF interposer', flush=True)
    else:
        run_check('R2-init-shed-write-deadline', lambda: shed_backpressure_case(directory))


# (label, script, builtin, diagnostic rule). All are runtime errors, not parse failures.
INVALID = [
    ('shape', 'http_response_header of null', 'http_response_header', 'requires'),
    ('name-type', 'http_response_header of [42, "x"]', 'http_response_header', 'strings'),
    ('value-type', 'http_response_header of ["X", 42]', 'http_response_header', 'strings'),
    ('cr', 'http_response_header of ["X", "bad\\rvalue"]', 'http_response_header', 'ASCII'),
    ('lf', 'http_response_header of ["X", "bad\\nvalue"]', 'http_response_header', 'ASCII'),
    ('control', 'http_response_header of ["X", chr of 1]', 'http_response_header', 'ASCII'),
    ('del', 'http_response_header of ["X", chr of 127]', 'http_response_header', 'ASCII'),
    ('high-byte', 'http_response_header of ["X", chr of 255]', 'http_response_header', 'ASCII'),
    ('name-cr', 'http_response_header of ["X\\rY", "1"]', 'http_response_header', 'token'),
    ('name-lf', 'http_response_header of ["X\\nY", "1"]', 'http_response_header', 'token'),
    ('name-space', 'http_response_header of ["X Y", "1"]', 'http_response_header', 'token'),
    ('name-control', 'http_response_header of [chr of 1, "1"]', 'http_response_header', 'token'),
    ('name-del', 'http_response_header of [chr of 127, "1"]', 'http_response_header', 'token'),
    ('name-high-byte', 'http_response_header of [chr of 255, "1"]', 'http_response_header', 'token'),
    ('name-lparen', 'http_response_header of ["X(Y", "1"]', 'http_response_header', 'token'),
    ('name-at', 'http_response_header of ["X@Y", "1"]', 'http_response_header', 'token'),
    ('name-slash', 'http_response_header of ["X/Y", "1"]', 'http_response_header', 'token'),
    ('name-lbracket', 'http_response_header of ["X[Y", "1"]', 'http_response_header', 'token'),
    ('name-semi', 'http_response_header of ["X;Y", "1"]', 'http_response_header', 'token'),
    ('name-eq', 'http_response_header of ["X=Y", "1"]', 'http_response_header', 'token'),
    ('name-quote', 'http_response_header of ["X\\"Y", "1"]', 'http_response_header', 'token'),
    ('token', 'http_response_header of ["bad:name", "x"]', 'http_response_header', 'token'),
    ('empty-name', 'http_response_header of ["", "x"]', 'http_response_header', '1..64'),
    ('long-name', 'http_response_header of ["'+'x'*65+'", "x"]', 'http_response_header', '1..64'),
    *[(name, f'http_response_header of ["{name}", "x"]', 'http_response_header', 'owned') for name in
      ['cOnTeNt-LeNgTh', 'CONTENT-TYPE', 'Transfer-Encoding', 'connection',
       'cAcHe-CoNtRoL', 'rEtRy-AfTeR', 'AlLoW',
       'aCcEsS-cOnTrOl-AlLoW-oRiGiN', 'ACCESS-CONTROL-ALLOW-METHODS',
       'access-control-allow-headers']],
    ('17th', '\n'.join(f'http_response_header of ["X-{i}", "v"]' for i in range(17)), 'http_response_header', '16'),
    ('long-value', 'http_response_header of ["X", "'+'x'*1025+'"]', 'http_response_header', '1024'),
    *[('live-'+str(i), f'http_early_bind of [PORTNUM, "{path}"]', 'http_early_bind', 'absolute') for i,path in enumerate(['', 'livez', '/a b', '/a\\t', '/a\\r', '/a\\n'])],
]


def check_rejection(rc, output, listening, builtin, rule):
    require(rc is not None and rc > 0, f'script did not die loudly rc={rc}')
    require(builtin in output and rule in output, f'diagnostic must name {builtin} and {rule}: {output[-300:]}')
    require(not listening, 'port is still listening after rejected configuration')


def is_listening(port):
    try:
        with socket.create_connection(('127.0.0.1', port), .1):
            return True
    except OSError:
        return False


def invalid_cases(directory):
    def one(row):
        name, text, builtin, rule = row
        def check():
            port = pick_port()
            script = directory/'invalid.eigs'
            script.write_text(text.replace('PORTNUM', str(port)) + f'\nhttp_serve of {port}\n')
            env = dict(os.environ); env.pop('PORT', None)
            try:
                p = subprocess.run([str(EIGS), str(script)], cwd=ROOT/'src', env=env, capture_output=True, timeout=2)
            except subprocess.TimeoutExpired:
                raise AssertionError('rejected script started server / hung')
            check_rejection(p.returncode, (p.stdout+p.stderr).decode(), is_listening(port), builtin, rule)
        run_check('R4-'+name, check)
    for_each_holder(invalid_rows(), one, 'INVALID')
    # A caught error must not allow a partially configured server to start.
    port = pick_port()
    script = directory/'caught.eigs'
    script.write_text(f'http_early_bind of {port}\ntry:\n    http_response_header of ["Content-Length", "1"]\ncatch e:\n    print of e.message\nhttp_serve of {port}\n')
    def caught():
        env = dict(os.environ); env.pop('PORT', None)
        p = subprocess.run([str(EIGS), str(script)], env=env, capture_output=True, timeout=3)
        check_rejection(p.returncode, (p.stdout+p.stderr).decode(), is_listening(port), 'http_response_header', 'rejected')
    run_check('R4-caught-poisons-start-and-closes-early-listener', caught)
    # Violation caught BEFORE early bind: early bind itself must raise and
    # the port must never listen. Dropping the rejected-flag check from
    # http_early_bind lets /livez 200 in the init window.
    def caught_then_bind():
        port = pick_port()
        script = directory/'caught-before-bind.eigs'
        script.write_text(
            'try:\n'
            '    http_response_header of ["Content-Length", "1"]\n'
            'catch e:\n'
            '    print of e.message\n'
            f'http_early_bind of [{port}, "/livez"]\n'
            f'http_serve of {port}\n')
        env = dict(os.environ); env.pop('PORT', None)
        try:
            p = subprocess.run([str(EIGS), str(script)], cwd=ROOT/'src', env=env,
                               capture_output=True, timeout=3)
        except subprocess.TimeoutExpired:
            raise AssertionError('rejected script started server / hung')
        check_rejection(p.returncode, (p.stdout+p.stderr).decode(), is_listening(port),
                        'http_early_bind', 'rejected')
    run_check('R4-caught-header-then-early-bind', caught_then_bind)


@contextlib.contextmanager
def fake_server(response):
    with socket.socket() as listener:
        listener.bind(('127.0.0.1', 0)); listener.listen()
        port = listener.getsockname()[1]
        def serve():
            conn, _ = listener.accept()
            with conn:
                conn.settimeout(2)
                data = b''
                while b'\r\n\r\n' not in data:
                    part = conn.recv(4096)
                    if not part:
                        break
                    data += part
                raw = f'HTTP/1.1 {response.status} Test\r\n'.encode()
                for k, vs in response.headers.items():
                    for v in vs:
                        raw += f'{k}: {v}\r\n'.encode()
                conn.sendall(raw + b'\r\n' + response.body)
        thread = threading.Thread(target=serve, daemon=True); thread.start()
        try:
            yield port
        finally:
            thread.join(timeout=3)
            require(not thread.is_alive(), 'fake server failed to finish')


@contextlib.contextmanager
def split_write_server(status, headers, body, pause=0.005):
    """Send headers, pause, then body — the load that truncated recv_http."""
    with socket.socket() as listener:
        listener.bind(('127.0.0.1', 0)); listener.listen()
        port = listener.getsockname()[1]
        def serve():
            conn, _ = listener.accept()
            with conn:
                conn.settimeout(2)
                while b'\r\n\r\n' not in (conn.recv(4096) or b'\r\n\r\n'):
                    pass
                raw = f'HTTP/1.1 {status} Test\r\n'.encode()
                for k, vs in headers.items():
                    for v in vs:
                        raw += f'{k}: {v}\r\n'.encode()
                conn.sendall(raw + b'\r\n')
                time.sleep(pause)
                conn.sendall(body)
        thread = threading.Thread(target=serve, daemon=True); thread.start()
        try:
            yield port
        finally:
            thread.join(timeout=3)
            require(not thread.is_alive(), 'split-write server failed to finish')


def expect_red(fn, name):
    try:
        fn()
    except AssertionError as exc:
        return str(exc)
    raise AssertionError(f'planted {name} survived the production checker')


def _fake_init_reply(conn, request):
    live = request.startswith(b'GET /livez HTTP/')
    body = b'OK' if live else b'Server initializing\n'
    raw = (f'HTTP/1.1 {200 if live else 503} Test\r\n'
           f'Content-Type: text/plain\r\nContent-Length: {len(body)}\r\n').encode()
    if not live:
        raw += b'Retry-After: 1\r\n'
    for k, v in HEADERS.items():
        raw += f'{k}: {v}\r\n'.encode()
    conn.sendall(raw + b'\r\n' + body)


@contextlib.contextmanager
def fake_init_scheduler(concurrent):
    # Serial arm: 100ms on EACH idle connection, then a fully correct
    # response. Only the production latency bound can reject it. Concurrent
    # arm answers a live probe immediately on its own thread.
    stop = threading.Event()
    workers, errors = [], []
    stall = 0.10
    with socket.socket() as listener:
        listener.bind(('127.0.0.1', 0)); listener.listen(32); listener.settimeout(.05)
        def handle(conn):
            try:
                with conn:
                    ready, _, _ = select.select([conn], [], [], stall)
                    request = b''
                    if ready:
                        conn.settimeout(.05)
                        try:
                            request = conn.recv(8192)
                        except socket.timeout:
                            request = b''
                    if not request:
                        _fake_init_reply(conn, b'')
                        return
                    _fake_init_reply(conn, request)
            except (BrokenPipeError, ConnectionResetError):
                pass
            except Exception as exc:
                errors.append(exc)
        def accept_loop():
            while not stop.is_set():
                try:
                    conn, _ = listener.accept()
                except socket.timeout:
                    continue
                if concurrent:
                    worker = threading.Thread(target=handle, args=(conn,))
                    workers.append(worker); worker.start()
                else:
                    handle(conn)
        thread = threading.Thread(target=accept_loop); thread.start()
        try:
            yield listener.getsockname()[1]
        finally:
            stop.set(); thread.join(timeout=3)
            for worker in workers:
                worker.join(timeout=1)
            require(not thread.is_alive() and not any(w.is_alive() for w in workers), 'fake scheduler did not stop')
            require(not errors, f'fake scheduler errors: {errors}')


def plant_table_gutting(helper_name, label):
    """Slice a production table to empty and invoke the live entry point."""
    global PASS, FAIL
    saved_fn = globals()[helper_name]
    saved_argv, saved_p, saved_f = sys.argv, PASS, FAIL
    output = io.StringIO()
    try:
        globals()[helper_name] = lambda *a, _orig=saved_fn, **k: _orig(*a, **k)[:0]
        PASS = FAIL = 0
        sys.argv = ['http_readiness.py']
        with contextlib.redirect_stdout(output):
            try:
                rc = main()
            except AssertionError as exc:
                print(f'  FAIL: {label}: {exc}', flush=True)
                rc = 1
        text = output.getvalue()
        require(rc != 0, f'{label} gutting survived rc=0:\n{text[-2000:]}')
        require('empty population' in text or 'examined 0' in text or 'FAIL:' in text,
                f'{label} gutting red for wrong reason:\n{text[-2000:]}')
    finally:
        globals()[helper_name] = saved_fn
        sys.argv, PASS, FAIL = saved_argv, saved_p, saved_f


def selftest(directory):
    # Every enrolled response row is driven through curl + the real checker,
    # with a positive control and independent faults in each response field.
    def one_case(case):
        h = {k: [v] for k, v in HEADERS.items()}
        if case.ctype is not None:
            h.update({'content-type': [case.ctype], 'content-length': [str(len(case.body))]})
        if case.phase == 'init' and case.status == 503:
            h['retry-after'] = ['1']
        good = Response(case.status, h, b'' if case.method == 'HEAD' else case.body)
        def exercise(response, inside=True):
            with fake_server(response) as port:
                got = (raw_request(port, f'HEAD {case.path} HTTP/1.1\r\nHost: x\r\n\r\n'.encode())
                       if case.method == 'HEAD' else curl(port, case.method, case.path, directory))
            check_response(case, got, HEADERS, inside=inside)
        run_check('SELF-control-'+case.name, lambda: exercise(good))
        mutants = [('status', dataclasses.replace(good, status=200 if case.status != 200 else 503))]
        for key in HEADERS:
            mutants.append(('omit-'+key, dataclasses.replace(good, headers={k:v for k,v in h.items() if k != key})))
            mutants.append(('wrong-'+key, dataclasses.replace(good, headers={**h, key:['wrong']})))
        mutants.append(('length', dataclasses.replace(good, headers={**h, 'content-length':['999']})))
        mutants.append(('type', dataclasses.replace(good, headers={**h, 'content-type':['wrong']})))
        if case.method == 'HEAD':
            mutants.append(('head-body', dataclasses.replace(good, body=case.body or b'x')))
        if case.method != 'HEAD' and case.status != 204:
            if good.body:
                mutants.append(('body', dataclasses.replace(good, body=b'x'*len(good.body))))
            else:
                mutants.append(('body', dataclasses.replace(good, body=b'x',
                    headers={**h, 'content-length': ['1']})))
        if case.phase == 'init' and case.status == 503:
            mutants.append(('retry', dataclasses.replace(good, headers={k:v for k,v in h.items() if k != 'retry-after'})))
        for name, mutant in mutants:
            run_check('SELF-red-'+case.name+'-'+name, lambda: expect_red(lambda: exercise(mutant), name))
        if case.phase == 'init':
            run_check('SELF-red-'+case.name+'-outside-window', lambda: expect_red(lambda: exercise(good, False), 'outside window'))
    for_each_holder(list(CASES), one_case, 'SELF-CASES')
    for case in (case_named('R2-live-get'), case_named('R1-init-page')):
        def idle_control(serial, probe=case):
            with fake_init_scheduler(not serial) as port:
                with held_connections(port, 16):
                    check = lambda: check_init_latency(port, directory, probe, lambda: True)
                    if serial:
                        message = expect_red(check, 'serial init starvation')
                        require('idle clients delayed' in message, message)
                    else:
                        check()
        label = 'R2-liveness-under-idle-connections' if case.status == 200 else 'R2-unready-under-idle-connections'
        run_check('SELF-control-'+label, lambda probe=case: idle_control(False, probe))
        run_check('SELF-red-serial-'+label, lambda probe=case: idle_control(True, probe))
    def one_invalid(row):
        name, _, builtin, rule = row
        run_check('SELF-control-R4-'+name, lambda: check_rejection(3, f'{builtin}: {rule}', False, builtin, rule))
        for bad, args in [('soft', (0, f'{builtin}: {rule}', False)), ('silent', (3, '', False)), ('listening', (3, f'{builtin}: {rule}', True))]:
            run_check('SELF-red-R4-'+name+'-'+bad, lambda: expect_red(lambda: check_rejection(*args, builtin, rule), name))
    for_each_holder(invalid_rows(), one_invalid, 'SELF-INVALID')
    run_check('SELF-red-zero-checks', empty_production_control)
    run_check('SELF-red-differential', lambda: expect_red(lambda: check_response(case_named('R3-ip-cap'), Response(503, {'content-type':['text/plain'], 'content-length':['0'], **{k:[v] for k,v in HEADERS.items()}}, b''), HEADERS, Response(503, {'content-type':['text/plain'], 'content-length':['0'], 'extra':['changed']}, b'')), 'baseline'))
    def planted_zero_require():
        global PASS, FAIL
        saved = PASS, FAIL
        output = io.StringIO()
        try:
            with contextlib.redirect_stdout(output):
                run_check('planted-no-require', lambda: None)
            require(FAIL == saved[1] + 1, f'zero-require check scored PASS={PASS} FAIL={FAIL}')
            require('zero requirements' in output.getvalue(), output.getvalue())
        finally:
            PASS, FAIL = saved
    run_check('SELF-red-zero-requires', planted_zero_require)
    run_check('SELF-red-zero-examined', lambda: expect_red(
        lambda: for_each_holder([1, 2, 3][:0], lambda _x: None, 'holders'), 'zero loop'))
    empty_good = Response(200, {**{k: [v] for k, v in HEADERS.items()},
                                'x-empty': [''], 'content-type': ['text/plain'],
                                'content-length': ['9']}, b'real-page')
    def empty_value_check(response):
        with fake_server(response) as port:
            got = curl(port, 'GET', '/', directory)
        check_response(case_named('R1-ready-page'), got, {**HEADERS, 'x-empty': ''})
        require(got.headers.get('x-empty') == [''], 'empty header value missing')
    run_check('SELF-control-R3-empty-value', lambda: empty_value_check(empty_good))
    omitted = dataclasses.replace(empty_good, headers={k: v for k, v in empty_good.headers.items() if k != 'x-empty'})
    run_check('SELF-red-R3-empty-value-omit', lambda: expect_red(lambda: empty_value_check(omitted), 'omit empty'))
    body408 = b'Request header timeout'
    h408 = {**{k: [v] for k, v in HEADERS.items()},
            'content-type': ['text/plain'], 'content-length': [str(len(body408))]}
    def split_read(reader):
        with split_write_server(408, h408, body408) as port:
            with socket.create_connection(('127.0.0.1', port), 2) as sock:
                sock.sendall(b'GET / HTTP/1.1\r\nHost: x\r\n\r\n')
                return reader(sock)
    run_check('SELF-control-split-write-body', lambda: require(
        split_read(recv_http).body == body408, 'split-write body not assembled'))
    run_check('SELF-red-truncated-reader', lambda: expect_red(
        lambda: require(split_read(recv_http_truncated).body == body408, 'truncated body'),
        'truncated body'))
    shed_ok = Response(503, {**{k: [v] for k, v in HEADERS.items()},
                             'content-type': ['text/plain'], 'content-length': ['0'],
                             'retry-after': ['1']}, b'')
    shed_body = dataclasses.replace(shed_ok, body=b'Server initializing\n',
                                    headers={**shed_ok.headers, 'content-length': ['20']})
    run_check('SELF-control-shed-bodyless', lambda: require_shed_wire(shed_ok, 'HEAD'))
    run_check('SELF-red-shed-with-body', lambda: expect_red(
        lambda: require_shed_wire(shed_body, 'HEAD'), 'shed body'))
    dead = type('P', (), {'poll': lambda self: 1})()
    run_check('SELF-red-sigpipe-dead', lambda: expect_red(
        lambda: require(dead.poll() is None, 'init responder died (SIGPIPE?)'), 'dead proc'))
    run_check('SELF-red-gut-CASES', lambda: plant_table_gutting('cases_for_phase', 'CASES'))
    run_check('SELF-red-gut-INVALID', lambda: plant_table_gutting('invalid_rows', 'INVALID'))
    run_check('SELF-red-gut-max-headers', lambda: plant_table_gutting('max_header_rows', 'max-headers'))


def main():
    require(sys.argv[1:] in ([], ['--selftest']), 'usage: test_http_readiness.sh [--selftest]')
    # Children cannot survive interruption; context managers own all PIDs/sockets.
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(143))
    with tempfile.TemporaryDirectory(prefix='eigs-readiness-', dir=ROOT/'tests') as tmp:
        directory = Path(tmp)
        if '--selftest' in sys.argv:
            selftest(directory)
        else:
            require(len(cases_for_phase('init')) > 0, 'init cases: empty population')
            require(len(cases_for_phase('ready')) > 0, 'ready cases: empty population')
            require(len(cases_for_phase('cap')) > 0, 'cap cases: empty population')
            require(len(invalid_rows()) > 0, 'INVALID: empty population')
            require(len(max_header_rows('init')) > 0, 'max-headers-init: empty population')
            require(len(max_header_rows('ready')) > 0, 'max-headers-ready: empty population')
            require_population(lambda: invalid_cases(directory))
            run_check('SETUP-and-response-matrix', lambda: require_population(lambda: live_cases(directory)))
    return finish(PASS, FAIL, 'HTTP_READINESS_SELFTEST' if '--selftest' in sys.argv else 'HTTP_READINESS')


if __name__ == '__main__':
    try:
        sys.exit(main())
    except Exception as exc:
        print(f'  FAIL: HTTP_READINESS harness: {exc}', flush=True)
        sys.exit(1)
