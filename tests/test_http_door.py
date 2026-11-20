#!/usr/bin/env python3
"""#2370: the server reads every request through llhttp.

Every expectation comes from tests/http_door_reference.c, the reference of the
issue's Decision, compiled here from the vendored parser; its decisions for the
109 named rows are held against the issue's table (tests/http_door_rows.txt)
before any server is asked. No server output supplies an expectation.

--row selects rows (for one-time plants); --record prints what a server
answers for the named rows without judging it (the base-commit table).
"""
import argparse
import ast
import atexit
from collections import Counter
import contextlib
import hashlib
import json
import os
from pathlib import Path
import random
import select
import shutil
import socket
import statistics
import subprocess
import tempfile
import threading
import time

from http_readiness import pick_port
from http_request_header_reference import request_header

ROOT = Path(__file__).resolve().parents[1]
VENDOR = ROOT / 'src/vendor/llhttp'
SEED_DEFAULT = 2370
FIELDS = (b'host', b'cookie', b'x-a', b'content-length')
HEAD_DEFAULT, BODY_DEFAULT = 65536, 16 * 1024 * 1024


class Skipped(Exception):
    """A row that cannot be judged here; counted as skipped, never as passed."""


def require(condition, detail):
    if not condition:
        raise AssertionError(detail)


def clean(output):
    result = subprocess.run(['bash', '-c', 'source "$1"; lsan_classify "$(cat)"; test "$?" = 2',
                             'classify', str(ROOT / 'tests/lsan_classify.sh')],
                            input=output, text=True, capture_output=True, check=False)
    require(result.returncode == 0, 'sanitizer diagnostic:\n' + output[-4000:])


# ---------------------------------------------------------------- reference

class Decision:
    def __init__(self, line):
        f = line.split()
        self.line = line
        self.kind = f[0]
        self.status = self.cause = self.index = None
        if self.kind == 'refused':
            self.status, self.cause = int(f[1]), int(f[2])
            self.index = None if f[3] == 'stopped' else int(f[3])
        elif self.kind == 'served':
            self.method = f[1]
            self.target = b'' if f[2] == '-' else bytes.fromhex(f[2])
            self.head_start, self.head_len = int(f[3]), int(f[4])
            self.body = b'' if f[5] == '-' else bytes.fromhex(f[5])
            self.count = int(f[6])
        else:
            require(self.kind == 'none' and len(f) == 1, f'reference printed {line!r}')

    def head(self, data):
        return data[self.head_start:self.head_start + self.head_len]


class Reference:
    def __init__(self, folder):
        flags = (ROOT / 'tools/werror_flags.txt').read_text().split()
        self.binary = folder / 'http_door_reference'
        sources = [ROOT / 'tests/http_door_reference.c'] + [VENDOR / n for n in ('llhttp.c', 'api.c', 'http.c')]
        cc = subprocess.run(['cc', '-Wall', '-Wextra', *flags, '-Wno-unused-parameter', '-O2',
                             '-I', str(VENDOR), '-o', str(self.binary), *map(str, sources)],
                            capture_output=True, text=True, timeout=300)
        require(cc.returncode == 0, f'reference does not compile: {cc.stderr}')
        self.input = folder / 'reference.in'
        self.cache = {}
        self.lock = threading.Lock()

    def decide(self, data, head=HEAD_DEFAULT, body=BODY_DEFAULT):
        with self.lock:
            return self._decide(data, head, body)

    def _decide(self, data, head, body):
        key = (data, head, body)
        if key not in self.cache:
            self.input.write_bytes(data)
            out = subprocess.run([str(self.binary), str(self.input), str(head), str(body)],
                                 capture_output=True, text=True, timeout=300)
            require(out.returncode == 0 and out.stdout.count('\n') == 1, f'reference rc={out.returncode} {out.stdout!r} {out.stderr!r}')
            self.cache[key] = Decision(out.stdout.strip())
        return self.cache[key]


_SHARED = []
_SHARED_LOCK = threading.Lock()


def shared_reference():
    """One reference for a test that judges other rows by #2370's decision,
    compiled once for the process whichever thread asks first."""
    with _SHARED_LOCK:
        if not _SHARED:
            folder = Path(tempfile.mkdtemp(prefix='eigs-door-ref-'))
            atexit.register(shutil.rmtree, folder, True)
            _SHARED.append(Reference(folder))
        return _SHARED[0]


def named_rows():
    rows = []
    for line in (ROOT / 'tests/http_door_rows.txt').read_text().splitlines():
        if line.startswith('#'):
            continue
        name, decision, literal, description = line.split('\t')
        rows.append((name, decision, ast.literal_eval(literal), description))
    require(len(rows) == 109, f'named rows {len(rows)}, want 109')
    return rows


def table_holds(text, d):
    """The issue's table text for a row, against a reference decision."""
    if text == 'no answer':
        return d.kind == 'none'
    if text.isdigit():
        return d.kind == 'refused' and d.status == int(text)
    if d.kind != 'served' or not text.startswith('served'):
        return False
    if 'a body of' in text:
        return len(d.body) == int(text.split('a body of ')[1].split()[0])
    if 'the head starts' in text:
        return d.head_start == int(text.split('starts ')[1].split()[0])
    if '(method ' in text:
        return d.method == text.split('(method ')[1].rstrip(')')
    return text == 'served' and d.head_start == 0


# ---------------------------------------------------------------- server

ROUTE = '''shared_incr of ["served", 1]
define hashes(name) as:
    local out is name
    for v in (http_request_header of name):
        out is out + " " + (sha256 of v)
    return out + "\\n"
h is http_request_headers of null
b is http_request_body of null
"head " + (sha256 of h) + "\\nbody " + (sha256 of b) + "\\n" + (hashes of "host") + (hashes of "cookie") + (hashes of "x-a") + (hashes of "content-length")'''
ROUTE_METHODS = ('GET', 'POST', 'PUT', 'PATCH', 'DELETE')
REGISTERED = ('X-Door', '2370')


def route(method, path, source, authed=False):
    return ('http_route_authed' if authed else 'http_route') + ' of ' + json.dumps(
        [method, path, 'code', source]) + '\n'


def door_routes(authed=False):
    text = ''.join(route(m, '/v', ROUTE, authed) for m in ROUTE_METHODS)
    return text + route('CONNECT', 'h:443', ROUTE, authed)


def expected_answer(data, d):
    head = d.head(data)
    lines = [b'head ' + hashlib.sha256(head).hexdigest().encode(),
             b'body ' + hashlib.sha256(d.body).hexdigest().encode()]
    for name in FIELDS:
        lines.append(b' '.join([name] + [hashlib.sha256(v).hexdigest().encode()
                                          for v in request_header(head, name)]))
    return b'\n'.join(lines) + b'\n'


def has_route(d):
    path = d.target.split(b'?', 1)[0]
    if d.method == 'CONNECT':
        return d.target == b'h:443'
    return d.method in ROUTE_METHODS + ('HEAD',) and path == b'/v'


@contextlib.contextmanager
def server(binary, folder, env=None, extra='', routes=None, pid_out=None):
    folder.mkdir(parents=True, exist_ok=True)
    port = pick_port()
    source = 'http_response_header of ' + json.dumps(list(REGISTERED)) + '\n'
    source += door_routes() if routes is None else routes
    source += route('GET', '/count', 'json_encode of [shared_get of "served", shared_get of "auth"]')
    source += 'http_route of ["GET", "/ready", "ready-2370"]\n' + extra
    source += f'http_serve of {port}\n'
    script = folder / 'server.eigs'
    script.write_text(source)
    environ = os.environ.copy()
    for key in ('EIGS_HTTP_MAX_HEAD', 'EIGS_HTTP_MAX_BODY', 'EIGS_HTTP_HEADER_MIN_RATE'):
        environ.pop(key, None)
    environ.update(env or {})
    with (folder / 'server.log').open('w+') as log:
        proc = subprocess.Popen([binary, str(script)], cwd=ROOT, env=environ, stdout=log, stderr=log)
        try:
            deadline = time.monotonic() + 60
            while True:
                require(proc.poll() is None and time.monotonic() < deadline,
                        f'server not ready rc={proc.poll()}: {log_text(log)}')
                try:
                    r = exchange(port, b'GET /ready HTTP/1.1\r\nHost: h\r\n\r\n', wait=5)
                    if r and r[0] == 200 and r[2] == b'ready-2370':
                        break
                except OSError:
                    pass
                time.sleep(.05)
            if pid_out is not None:
                pid_out.append(proc.pid)
            yield port
            require(proc.poll() is None, f'server exited rc={proc.returncode}')
        finally:
            if proc.poll() is None:
                proc.terminate()
            try:
                proc.wait(timeout=10)
            except subprocess.TimeoutExpired:
                proc.kill()
                proc.wait()
            output = log_text(log)
            clean(output)


def log_text(log):
    log.flush()
    log.seek(0)
    return log.read()


def parse(raw):
    """(status, headers, body) of one response; None for no answer."""
    if not raw:
        return None
    head, sep, rest = raw.partition(b'\r\n\r\n')
    require(bool(sep), f'response has no empty line: {raw[:200]!r}')
    lines = head.split(b'\r\n')
    require(lines[0].startswith(b'HTTP/1.1 '), f'status line {lines[0]!r}')
    status = int(lines[0].split()[1])
    headers = {}
    for line in lines[1:]:
        k, _, v = line.partition(b':')
        headers.setdefault(k.strip().lower(), []).append(v.strip())
    length = headers.get(b'content-length')
    if length is not None:
        require(len(length) == 1 and len(rest) == int(length[0]),
                f'response framing {length} / {len(rest)}')
    return status, headers, rest


def send_way(peer, data, way, cuts):
    if way == 0:
        peer.sendall(data)
    elif way in (1, 3):
        a, b = cuts
        for part in (data[:a], data[a:b], data[b:]):
            if part:
                peer.sendall(part)
                if way == 3:
                    time.sleep(.05)
    else:
        for i in range(len(data)):
            peer.sendall(data[i:i + 1])


def exchange(port, data, way=0, cuts=None, keep_open=False, wait=30):
    """Write a request, then read one answer. Returns parse(...) of it."""
    with socket.create_connection(('127.0.0.1', port), timeout=wait) as peer:
        peer.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        try:
            send_way(peer, data, way, cuts)
            if not keep_open:
                peer.shutdown(socket.SHUT_WR)
        except (BrokenPipeError, ConnectionResetError):
            pass
        return parse(read_all(peer))


def exchange_named(label, *args, **kwargs):
    try:
        return exchange(*args, **kwargs)
    except AssertionError as exc:
        raise AssertionError(f'{label}: {exc}') from None


def read_all(peer):
    chunks = []
    while True:
        try:
            chunk = peer.recv(65536)
        except ConnectionResetError:
            break
        except TimeoutError:
            raise AssertionError(f'the server neither answered nor closed within {peer.gettimeout()} s '
                                 f'({sum(map(len, chunks))} bytes read)') from None
        if not chunk:
            break
        chunks.append(chunk)
    return b''.join(chunks)


def read_answer(peer, bound):
    """Bytes of one answer, read until its head and the Content-Length bytes
    after it are in, the stream ends, or `bound` seconds have passed."""
    got, until = b'', time.monotonic() + bound
    while True:
        head, sep, rest = got.partition(b'\r\n\r\n')
        if sep:
            length = [l.split(b':', 1)[1] for l in head.split(b'\r\n')[1:]
                      if l.lower().startswith(b'content-length:')]
            if len(length) == 1 and len(rest) >= int(length[0]):
                return got
        left = until - time.monotonic()
        if left <= 0 or not select.select([peer], [], [], left)[0]:
            return got
        chunk = peer.recv(1 << 20)
        if not chunk:
            return got
        got += chunk


def judge(data, d, r, label):
    """The server's answer r against the reference decision d."""
    if d.kind == 'none':
        require(r is None, f'{label}: wanted no answer, got {r and r[0]}')
        return
    require(r is not None, f'{label}: no answer; reference: {d.line[:120]}')
    status, headers, body = r
    if d.kind == 'refused':
        require(status == d.status, f'{label}: status {status}, reference {d.status} (cause {d.cause})')
        require(headers.get(REGISTERED[0].lower().encode()) == [REGISTERED[1].encode()],
                f'{label}: refusal without the registered header')
        return
    if not has_route(d):
        want = 204 if d.method == 'OPTIONS' else 404
        require(status == want, f'{label}: no route, status {status}, want {want}')
        return
    require(status == 200, f'{label}: status {status} body {body[:200]!r}, reference served')
    want = expected_answer(data, d)
    require(body == want, f'{label}: route read\n{body.decode(errors="replace")}\nreference\n{want.decode(errors="replace")}')


def count_of(port):
    r = exchange(port, b'GET /count HTTP/1.1\r\nHost: h\r\n\r\n')
    require(r and r[0] == 200, f'/count answered {r and r[0]}')
    served, auth = json.loads(r[2])
    return served or 0, auth or 0


def sanitizer(binary):
    symbols = subprocess.run(['nm', '-D', binary], capture_output=True, text=True, timeout=30)
    require(symbols.returncode == 0, 'cannot read the binary symbols')
    return '__asan_init' in symbols.stdout or '__tsan_init' in symbols.stdout


# ---------------------------------------------------------------- the grammar

NAMES = (b'Cookie', b'X-A', b'X-B', b'Accept', b'User-Agent', b'Referer', b'X-Request-Id', b'Accept-Language')
VALUE = bytes([9] + list(range(0x20, 0x7f)) + list(range(0x80, 0x100)))
EDGE = bytes(c for c in VALUE if c not in (9, 32))
require(len(VALUE) == 224, 'value alphabet')


def value(rng):
    n = rng.randint(0, 300)
    if n == 0:
        return b''
    if n == 1:
        return bytes([rng.choice(EDGE)])
    return bytes([rng.choice(EDGE)]) + bytes(rng.choice(VALUE) for _ in range(n - 2)) + bytes([rng.choice(EDGE)])


def field(rng):
    return rng.choice(NAMES) + b': ' + value(rng) + b'\r\n'


def target(rng):
    if rng.randrange(2):
        return b'/v?' + bytes(rng.randint(0x21, 0x7e) for _ in range(rng.randint(1, 200)))
    return b'/v'


def chunked(rng, body):
    if not body:
        return b'0\r\n\r\n'
    n = rng.randint(1, min(20, len(body)))
    cuts = sorted(rng.sample(range(1, len(body)), n - 1)) if n > 1 else []
    out, last = b'', 0
    for cut in cuts + [len(body)]:
        part = body[last:cut]
        out += (b'%x' if rng.randrange(2) else b'%X') % len(part) + b'\r\n' + part + b'\r\n'
        last = cut
    return out + b'0\r\n\r\n'


def well_formed(rng, kind):
    """kind: GET, POST (Content-Length) or CHUNKED. Returns the request bytes."""
    method = b'GET' if kind == 'GET' else b'POST'
    head = method + b' ' + target(rng) + b' HTTP/1.1\r\nHost: h\r\n'
    head += b''.join(field(rng) for _ in range(rng.randint(0, 6)))
    if kind == 'GET':
        return head + b'\r\n'
    body = bytes(rng.randint(1, 255) for _ in range(rng.randint(0, 2000)))
    if kind == 'POST':
        return head + b'Content-Length: ' + str(len(body)).encode() + b'\r\n\r\n' + body
    return head + b'Transfer-Encoding: chunked\r\n\r\n' + chunked(rng, body)


SHAPE_ROWS = (['A%d' % i for i in list(range(1, 14)) + list(range(19, 24))] +
              ['B%d' % i for i in list(range(1, 14)) + list(range(15, 28)) + [29, 30, 31]] +
              ['C%d' % i for i in list(range(1, 28)) + list(range(31, 38)) + list(range(40, 55))])
BODY_ROWS = ['A%d' % i for i in (1, 2, 3, 4, 5, 6, 7, 8, 11, 12, 13)]
CHUNKED_ROWS = {'B31', 'C11', 'C12', 'C20', 'C21', 'C22', 'C33', 'C49', 'C50', 'C51'}
require(len(SHAPE_ROWS) == 96 and len(BODY_ROWS) == 11, 'shape row lists')


def head_lines(data):
    """Places after the request line where a whole line may go, and the place
    of the empty line: every place just after a CR LF of the head."""
    start = 0
    while data[start:start + 1] in (b'\r', b'\n'):
        start += 1
    line_end = data.index(b'\r\n', start) + 2
    empty = data.find(b'\r\n\r\n', start)
    empty = line_end - 2 if data[line_end - 2:line_end + 2] == b'\r\n\r\n' else empty + 2
    places = [line_end]
    i = line_end
    while i < empty:
        i = data.index(b'\r\n', i) + 2
        places.append(i)
    return places


def dealt_shape(rng, data):
    places = head_lines(data)
    out = data
    for _ in range(rng.randint(0, 6)):
        p = rng.choice(head_lines(out)[:len(places) + 6])
        out = out[:p] + field(rng) + out[p:]
    return out


def row_field_line(data):
    return data[data.index(b'Host: h\r\n') + 9:-2]


def deal(rng):
    rows = {r[0]: r for r in named_rows()}
    population = []
    for name in SHAPE_ROWS:
        for _ in range(6):
            population.append((name, dealt_shape(rng, rows[name][2]), name in CHUNKED_ROWS))
    for name in BODY_ROWS:
        line = row_field_line(rows[name][2])
        for _ in range(6):
            body = b''.join(field(rng) for _ in range(rng.randint(0, 3))) + line
            body += b''.join(field(rng) for _ in range(rng.randint(0, 3)))
            head = b'POST /v HTTP/1.1\r\nHost: h\r\nContent-Length: ' + str(len(body)).encode() + b'\r\n\r\n'
            population.append(('body-' + name, head + body, False))
    for kind in ('GET', 'POST', 'CHUNKED'):
        for _ in range(100):
            population.append(('well-' + kind, well_formed(rng, kind), kind == 'CHUNKED'))
    for _ in range(60):
        data = well_formed(rng, rng.choice(('GET', 'POST', 'CHUNKED')))
        population.append(('cut', data[:rng.randint(1, len(data) - 1)], False))
    return population


def cuts_for(rng, data):
    if len(data) < 3:
        return (min(1, len(data)), len(data))
    return tuple(sorted(rng.sample(range(1, len(data)), 2)))


# ---------------------------------------------------------------- rows

def row_reference(ctx):
    counts, at_byte, stopped = Counter(), 0, 0
    for name, text, data, _ in named_rows():
        d = ctx.ref.decide(data)
        require(table_holds(text, d), f'{name}: the issue says {text!r}, the reference {d.line[:100]!r}')
        counts['served' if d.kind == 'served' else 'none' if d.kind == 'none' else d.status] += 1
        if d.kind == 'refused':
            at_byte += d.index is not None
            stopped += d.index is None
    want = Counter({400: 64, 413: 2, 501: 3, 505: 5, 'none': 1, 'served': 34})
    require(counts == want and at_byte == 69 and stopped == 5,
            f'reference over the named rows: {counts} at a byte {at_byte} stopped {stopped}')
    print(f'COUNTS: named=109/109 400=64 413=2 501=3 505=5 none=1 served=34 at-byte=69 stopped=5', flush=True)


def row_named(ctx):
    problems = []
    with server(ctx.binary, ctx.folder / 'named') as port:
        compared = 0
        for name, text, data, _ in named_rows():
            try:
                judge(data, ctx.ref.decide(data), exchange(port, data), name)
            except AssertionError as exc:
                problems.append((name, str(exc)))
            compared += 1
    require(not problems, f'{len(problems)} named row(s) not answered as the reference: ' +
            ' '.join(n for n, _ in problems) + '; first: ' + problems[0][1][:300] if problems else '')
    require(compared == 109, f'compared {compared}')
    print('COUNTS: named rows answered as the reference=109/109', flush=True)


def row_at_byte(ctx):
    with server(ctx.binary, ctx.folder / 'at-byte') as port:
        timed = 0
        for name, text, data, _ in named_rows():
            d = ctx.ref.decide(data)
            if d.kind != 'refused' or d.index is None:
                continue
            start = time.monotonic()
            r = exchange_named(name, port, data[:d.index + 1], keep_open=True, wait=2)
            took = time.monotonic() - start
            require(r is not None and r[0] == d.status and took < 2,
                    f'{name}: sent through byte {d.index}, got {r and r[0]} after {took:.2f}s, want {d.status} within 2s')
            timed += 1
    require(timed == 69, f'refused at a byte: {timed}, want 69')
    print('COUNTS: refused at their byte within 2 s=69/69', flush=True)


def row_population(ctx):
    """The dealt population and the sweep in one server, then its counter."""
    seed = ctx.seed
    rng = random.Random(seed)
    print(f'DEALT: seed={seed}', flush=True)
    rows = {r[0]: r for r in named_rows()}
    population = deal(rng)
    ways, shapes, chunked_served = Counter(), Counter(), 0
    routed = 0
    results = {}
    with open(ctx.folder / 'dealt.txt', 'w') as out, server(ctx.binary, ctx.folder / 'population') as port:
        problems = []
        for n, (name, data, is_chunked) in enumerate(population):
            way = n % 3
            ways[way] += 1
            out.write(f'{n}\t{name}\tway{way}\t{data!r}\n')
            d = ctx.ref.decide(data)
            if name in rows:
                shapes[name] += 1
                own = ctx.ref.decide(rows[name][2])
                same = (d.kind == own.kind and d.status == own.status and
                        (d.kind != 'served' or (d.method == own.method and d.body == own.body)))
                if not same:
                    problems.append(f'dealt {n} of {name}: {d.line[:80]} is not the row\'s {own.line[:80]}')
            elif name.startswith('body-') or name.startswith('well-'):
                if d.kind != 'served':
                    problems.append(f'dealt {n} {name}: the reference says {d.line[:80]}')
            elif name == 'cut':
                if not (d.kind == 'refused' and d.status == 400):
                    problems.append(f'dealt {n} cut: the reference says {d.line[:80]}')
            chunked_served += is_chunked and d.kind == 'served'
            routed += d.kind == 'served' and has_route(d)
            try:
                judge(data, d, exchange(port, data, way, cuts_for(rng, data)), f'dealt {n} {name} way {way}')
            except AssertionError as exc:
                problems.append(str(exc))
        dealt_ok = (not problems and len(population) == 1002 and set(shapes.values()) == {6} and
                    len(shapes) == 96 and ways == Counter({0: 334, 1: 334, 2: 334}) and chunked_served == 160)
        results['dealt'] = (dealt_ok, f'{len(problems)} problems, first: {problems[:3]}; dealt={len(population)} '
                            f'shapes={len(shapes)}x{set(shapes.values())} ways={dict(ways)} chunked served={chunked_served}')
        print(f'COUNTS: dealt={len(population)}/1002 shapes={len(shapes)}/96 ways={ways[0]},{ways[1]},{ways[2]} '
              f'chunked-served={chunked_served}/160 problems={len(problems)}', flush=True)

        places = [(b'name', lambda c: b'X' + c + b'A: 1', 78), (b'colon', lambda c: b'X-A' + c + b': 1', 78),
                  (b'value', lambda c: b'X-A: a' + c + b'b', 224), (b'first', lambda c: b'X-A:' + c + b'1', 224),
                  (b'last', lambda c: b'X-A: 1' + c, 224)]
        problems, served_at = [], []
        for place, line, want in places:
            served = 0
            for c in range(256):
                data = b'GET /v HTTP/1.1\r\nHost: h\r\n' + line(bytes([c])) + b'\r\n\r\n'
                d = ctx.ref.decide(data)
                served += d.kind == 'served'
                routed += d.kind == 'served' and has_route(d)
                try:
                    judge(data, d, exchange(port, data), f'sweep {place.decode()} 0x{c:02x}')
                except AssertionError as exc:
                    problems.append(str(exc))
            served_at.append(served)
        served = 0
        for c in range(256):
            data = b'GET /v?a' + bytes([c]) + b'b HTTP/1.1\r\nHost: h\r\nX-A: 1\r\n\r\n'
            d = ctx.ref.decide(data)
            served += d.kind == 'served'
            routed += d.kind == 'served' and has_route(d)
            try:
                judge(data, d, exchange(port, data), f'sweep query 0x{c:02x}')
            except AssertionError as exc:
                problems.append(str(exc))
        served_at.append(served)
        results['sweep'] = (not problems and served_at == [78, 78, 224, 224, 224, 94],
                            f'{len(problems)} problems, first: {problems[:3]}; served at each place {served_at}')
        print(f'COUNTS: sweep=1536/1536 served at each place={served_at} (want [78, 78, 224, 224, 224, 94])', flush=True)
        counter, _ = count_of(port)
        results['counter'] = (counter == routed, f'the route ran {counter} times; the reference serves {routed} with a route')
        print(f'COUNTS: route runs={counter} reference-served-with-route={routed}', flush=True)
    return results


def head_shapes(limit):
    """The nine shapes at a count of exactly `limit`, as (name, bytes(count))."""
    def long_target(k):
        base = b'GET /v? HTTP/1.1\r\nHost: h\r\n\r\n'
        return b'GET /v?' + b'a' * (k - len(base)) + b' HTTP/1.1\r\nHost: h\r\n\r\n'

    def long_value(k):
        base = b'GET /v HTTP/1.1\r\nHost: h\r\nX-A: \r\n\r\n'
        return b'GET /v HTTP/1.1\r\nHost: h\r\nX-A: ' + b'v' * (k - len(base)) + b'\r\n\r\n'

    def lines20(k):
        base = b'GET /v HTTP/1.1\r\nHost: h\r\n'
        room = k - len(base) - 2
        n, rest = divmod(room, 20)
        body = b'X-B: vvvvvvvvvvvvv\r\n' * n
        if rest:
            body = body[:-20] + b'X-B: ' + b'v' * (13 + rest) + b'\r\n'
        return base + body + b'\r\n'

    def crlf100(k):
        base = b'\r\n' * 100 + b'GET /v HTTP/1.1\r\nHost: h\r\nX-A: \r\n\r\n'
        return b'\r\n' * 100 + b'GET /v HTTP/1.1\r\nHost: h\r\nX-A: ' + b'v' * (k - len(base)) + b'\r\n\r\n'

    def head_then_body(k):
        base = b'POST /v HTTP/1.1\r\nHost: h\r\nContent-Length: 1000\r\nX-A: \r\n\r\n'
        return (b'POST /v HTTP/1.1\r\nHost: h\r\nContent-Length: 1000\r\nX-A: ' + b'v' * (k - len(base)) +
                b'\r\n\r\n' + bytes(range(1, 251)) * 4)

    head57 = b'POST /v HTTP/1.1\r\nHost: h\r\nTransfer-Encoding: chunked\r\n\r\n'
    require(len(head57) == 57, 'the head of 57 bytes')

    def extension(k):
        return head57 + b'4;e=' + b'x' * (k - 57 - 3) + b'\r\nBODY\r\n0\r\n\r\n'

    def trailer(k):
        return head57 + b'4\r\nBODY\r\n0\r\nX-T: ' + b't' * (k - 57 - 7) + b'\r\n\r\n'

    def zeros(k):
        return head57 + b'0' * (k - 57) + b'0000000000000004\r\nBODY\r\n0\r\n\r\n'

    def ten_and_trailer(k):
        chunks = b''.join(b'1;e=' + b'x' * 97 + b'\r\n' + bytes([65 + i]) + b'\r\n' for i in range(10))
        return head57 + chunks + b'0\r\nX-T: ' + b't' * (k - 57 - 1000 - 7) + b'\r\n\r\n'

    return [('target', long_target), ('value', long_value), ('lines', lines20), ('crlf', crlf100),
            ('head-and-body', head_then_body), ('extension', extension), ('trailer', trailer),
            ('zeros', zeros), ('ten-and-trailer', ten_and_trailer)]


def edge_check(ctx, port, limit, problems):
    checked = 0
    for name, make in head_shapes(limit):
        for k, want in ((limit, 'served'), (limit + 1, 431)):
            data = make(k)
            d = ctx.ref.decide(data, head=limit)
            if want == 'served':
                if not (d.kind == 'served' and d.count == limit):
                    problems.append(f'{name} at {limit}: the reference says {d.line[:80]}')
            elif not (d.kind == 'refused' and d.status == 431):
                problems.append(f'{name} at {limit}+1: the reference says {d.line[:80]}')
            try:
                judge(data, d, exchange(port, data), f'{name} count {k}')
            except AssertionError as exc:
                problems.append(str(exc))
            checked += 1
    # Not complete: the 431 comes at its byte, with the connection kept open.
    for name, data in (('no empty line', b'GET /v HTTP/1.1\r\nHost: h\r\nX-A: ' + b'v' * limit),
                       ('extension not ended', b'POST /v HTTP/1.1\r\nHost: h\r\nTransfer-Encoding: chunked\r\n\r\n4;e=' + b'x' * limit)):
        d = ctx.ref.decide(data, head=limit)
        if not (d.kind == 'refused' and d.status == 431):
            problems.append(f'{name}: the reference says {d.line[:80]}')
            continue
        start = time.monotonic()
        r = exchange_named(f'{name} at {limit}', port, data[:d.index + 1], keep_open=True, wait=2)
        if not (r and r[0] == 431 and time.monotonic() - start < 2):
            problems.append(f'{name} at {limit}: got {r and r[0]} after {time.monotonic() - start:.2f}s')
        checked += 1
    return checked


def two_causes(ctx, port, problems):
    def padded(first, extra, total):
        base = first + b'Host: h\r\nX-A: \r\n' + extra + b'\r\n'
        return first + b'Host: h\r\nX-A: ' + b'v' * (total - len(base)) + b'\r\n' + extra + b'\r\n'
    cases = []
    for total, want in ((4097, 431), (4096, 505)):
        cases.append((f'HTTP/2.0 head of {total}', padded(b'GET /v HTTP/2.0\r\n', b'', total), want))
    for total, want in ((4097, 431), (4096, 400)):
        cases.append((f'gzip head of {total}', padded(b'GET /v HTTP/1.1\r\n', b'Transfer-Encoding: gzip\r\n', total), want))
    for at, want in ((4097, 431), (4096, 400)):
        data = b'GET /v HTTP/1.1\r\nHost: h\r\nX-A: '
        data += b'v' * (at - 1 - len(data)) + b'\0' + b'v' * 10 + b'\r\n\r\n'
        cases.append((f'NUL as byte {at}', data, want))
    for label, data, want in cases:
        d = ctx.ref.decide(data, head=4096)
        if not (d.kind == 'refused' and d.status == want):
            problems.append(f'{label}: the reference says {d.line[:80]}, the issue {want}')
            continue
        try:
            judge(data, d, exchange(port, data), label)
        except AssertionError as exc:
            problems.append(str(exc))
    return len(cases)


def head_limit_of(ctx, value, limit):
    """Is the server's limit `limit` when EIGS_HTTP_MAX_HEAD is `value`?"""
    shape = head_shapes(limit)[1][1]
    with server(ctx.binary, ctx.folder / f'head-var-{abs(hash(value))}', {'EIGS_HTTP_MAX_HEAD': value}) as port:
        a = exchange(port, shape(limit))
        b = exchange(port, shape(limit + 1))
    return a is not None and a[0] == 200 and b is not None and b[0] == 431


def row_head_limit(ctx):
    problems, checked = [], 0
    with server(ctx.binary, ctx.folder / 'head-default') as port:
        checked += edge_check(ctx, port, HEAD_DEFAULT, problems)
    with server(ctx.binary, ctx.folder / 'head-4096', {'EIGS_HTTP_MAX_HEAD': '4096'}) as port:
        checked += edge_check(ctx, port, 4096, problems)
        checked += two_causes(ctx, port, problems)
    for value in ('abc', '0', '-5', '+4096', '4096x', ' 4096', '4096 ', '0000004096', '4096000000', ''):
        if not head_limit_of(ctx, value, HEAD_DEFAULT):
            problems.append(f'EIGS_HTTP_MAX_HEAD={value!r}: the limit is not 65536')
        checked += 1
    if not head_limit_of(ctx, '0004096', 4096):
        problems.append('EIGS_HTTP_MAX_HEAD=0004096: the limit is not 4096')
    checked += 1
    with server(ctx.binary, ctx.folder / 'head-1e8', {'EIGS_HTTP_MAX_HEAD': '100000000'}) as port:
        data = head_shapes(HEAD_DEFAULT + 1)[1][1](HEAD_DEFAULT + 1)
        r = exchange(port, data)
        if not (r and r[0] == 200):
            problems.append(f'EIGS_HTTP_MAX_HEAD=100000000: a head of 65537 bytes got {r and r[0]}')
    checked += 1
    require(not problems, '; '.join(problems[:6]) + f' ({len(problems)} problems)')
    require(checked == 18 * 2 + 4 + 6 + 10 + 2, f'head-limit checks {checked}')
    print(f'COUNTS: head limit checks={checked}/{18 * 2 + 4 + 6 + 10 + 2}', flush=True)


def chunks_of(body, n):
    size = -(-len(body) // n)
    parts = [body[i:i + size] for i in range(0, len(body), size)]
    require(len(parts) == n, f'{len(parts)} chunks')
    lines = [b'%x\r\n' % len(p) + p + b'\r\n' for p in parts]
    return lines


def linger_held(port, data):
    """D07's linger check: `data` is served on a second connection while the
    first, answered with bytes after its request and its client open, lingers.
    The first's answer is written before its head and body are given back
    (#2412), so a 503 of the second is tried again 100 ms later while within
    1 s of that answer; the second must be served within 1.5 s of it, while the
    first still lingers (2 s). Returns (ok, detail)."""
    with socket.create_connection(('127.0.0.1', port), timeout=10) as first:
        first.sendall(data + b'GET /v HTTP/1.1\r\n')
        r1 = parse(read_answer(first, 5))
        answered, seconds = time.monotonic(), []
        while True:
            r2 = exchange(port, data, wait=5)
            seconds.append(f'{r2 and r2[0]}@{time.monotonic() - answered:.2f}s')
            if not (r2 and r2[0] == 503) or time.monotonic() - answered > 1:
                break
            time.sleep(.1)
        late = time.monotonic() - answered
        more = read_all(first)
    ok = r1 and r1[0] == 200 and r2 and r2[0] == 200 and late < 1.5 and more == b''
    return ok, f'held during the linger: first {r1 and r1[0]}, second {seconds}, after the bytes {len(more)}'


def row_body_limit(ctx):
    limit = 65536
    problems, checked = [], 0
    rng = random.Random(ctx.seed + 1)
    with server(ctx.binary, ctx.folder / 'body', {'EIGS_HTTP_MAX_BODY': str(limit)}) as port:
        def served(label, data):
            d = ctx.ref.decide(data, body=limit)
            if d.kind != 'served':
                problems.append(f'{label}: the reference says {d.line[:80]}')
                return
            try:
                judge(data, d, exchange(port, data), label)
            except AssertionError as exc:
                problems.append(str(exc))

        def refused_when(label, sent):
            d = ctx.ref.decide(sent, body=limit)
            if not (d.kind == 'refused' and d.status == 413 and d.index == len(sent) - 1):
                problems.append(f'{label}: the reference says {d.line[:80]} for {len(sent)} bytes')
                return
            start = time.monotonic()
            r = exchange_named(label, port, sent, keep_open=True, wait=2)
            if not (r and r[0] == 413 and time.monotonic() - start < 2):
                problems.append(f'{label}: got {r and r[0]} after {time.monotonic() - start:.2f}s')

        body = bytes(rng.randint(1, 255) for _ in range(limit))
        served('announced 65536', b'POST /v HTTP/1.1\r\nHost: h\r\nContent-Length: 65536\r\n\r\n' + body)
        refused_when('announced 65537', b'POST /v HTTP/1.1\r\nHost: h\r\nContent-Length: 65537\r\n\r\n')
        head = b'POST /v HTTP/1.1\r\nHost: h\r\nTransfer-Encoding: chunked\r\n\r\n'
        served('chunked 65536 in 7', head + b''.join(chunks_of(body, 7)) + b'0\r\n\r\n')
        lines = chunks_of(body + b'x', 7)
        seventh = head + b''.join(lines[:6]) + lines[6].split(b'\r\n', 1)[0] + b'\r\n'
        refused_when('chunked 65537 in 7', seventh)
        refused_when('first chunk 10001', head + b'10001\r\n')
        ones = head + b''.join(b'1\r\n' + body[i:i + 1] + b'\r\n' for i in range(limit)) + b'0\r\n\r\n'
        require(len(ones) - len(head) == 393221, 'one-byte chunks')
        served('65536 chunks of 1 byte', ones)
        checked = 6
        # A complete request with nothing after it is closed at once, with no
        # linger, though the client keeps its side open: after the answer the
        # socket is closed, so a byte the client sends then is refused (a
        # lingering server would read it and drop it).
        with socket.create_connection(('127.0.0.1', port), timeout=5) as peer:
            peer.sendall(b'GET /v HTTP/1.1\r\nHost: h\r\n\r\n')
            r = parse(read_all(peer))
            refused = False
            for _ in range(10):
                time.sleep(.1)
                try:
                    peer.sendall(b'x')
                except (BrokenPipeError, ConnectionResetError):
                    refused = True
                    break
        if not (r and r[0] == 200 and refused):
            problems.append(f'no bytes after: the server still read after its answer ({r and r[0]})')
        checked += 1
    # What a request held is released before the linger: with a budget for
    # what all connections hold of 120,000 bytes, a request whose body room
    # is 65,536 bytes (82,944 bytes held in all) is served while the one before
    # it lingers (bytes after it, its client open), and it would be 503 if the
    # lingering one still held its head and body.
    with server(ctx.binary, ctx.folder / 'linger', {'EIGS_HTTP_MAX_BODY_TOTAL': '120000'}) as port:
        body = bytes(rng.randint(1, 255) for _ in range(40000))
        data = b'POST /v HTTP/1.1\r\nHost: h\r\nContent-Length: 40000\r\n\r\n' + body
        ok, detail = linger_held(port, data)
        if not ok:
            problems.append(detail)
        checked += 1
    require(not problems, '; '.join(problems[:6]))
    print(f'COUNTS: body limit checks={checked}/8', flush=True)


def vm_hwm(pid):
    for line in Path(f'/proc/{pid}/status').read_text().splitlines():
        if line.startswith('VmHWM:'):
            return int(line.split()[1])
    raise AssertionError('no VmHWM')


def row_held(ctx):
    if ctx.sanitizer:
        raise Skipped('peak resident size on a sanitizer build (the make http build judges this row)')
    if not Path('/proc/self/status').exists():
        raise Skipped('requires Linux /proc')
    head = b'POST /v HTTP/1.1\r\nHost: h\r\nTransfer-Encoding: chunked\r\n\r\n'

    def request(n):
        body = bytes((i * 7) % 255 + 1 for i in range(n))
        return body, head + b''.join(b'%016x\r\n' % 1 + body[i:i + 1] + b'\r\n' for i in range(n)) + b'0\r\n\r\n'
    ids = []
    with server(ctx.binary, ctx.folder / 'held', {'EIGS_HTTP_MAX_BODY': '1048576'}, pid_out=ids) as port:
        small_body, small = request(1024)
        d = ctx.ref.decide(small, body=1048576)
        for i in range(100):
            judge(small, d, exchange(port, small), f'small {i}')
        before = vm_hwm(ids[0])
        body, big = request(1048576)
        require(len(big) - len(head) == 22020101, f'{len(big) - len(head)} bytes after the head')
        d = ctx.ref.decide(big, body=1048576)
        require(d.kind == 'served' and d.body == body, f'the reference says {d.line[:80]}')
        judge(big, d, exchange(port, big), '1 MiB in 1-byte chunks')
        after = vm_hwm(ids[0])
    print(f'HELD: VmHWM after 100 small={before} kB after the 22,020,101-byte request={after} kB '
          f'growth={after - before} kB bound=12288 kB', flush=True)
    require(after - before <= 12288, f'peak resident size grew {after - before} kB')


def row_no_route(ctx, counter_result):
    ok, detail = counter_result
    require(ok, detail)


def row_authed_static(ctx):
    rows = named_rows()
    problems = []
    auth = 'shared_incr of ["auth", 1]\n""'
    setup = 'shared_set of ["require_auth", ' + json.dumps(auth) + ']\n"setup"'
    with server(ctx.binary, ctx.folder / 'authed', routes=door_routes(authed=True),
                extra=route('GET', '/setup', setup)) as port:
        r = exchange(port, b'GET /setup HTTP/1.1\r\nHost: h\r\n\r\n')
        require(r and r[0] == 200, 'auth setup')
        want = 0
        for name, text, data, _ in rows:
            d = ctx.ref.decide(data)
            want += d.kind == 'served' and has_route(d)
            try:
                judge(data, d, exchange(port, data), 'authed ' + name)
            except AssertionError as exc:
                problems.append(str(exc))
        served, auth_calls = count_of(port)
        if not (served == want and auth_calls == want):
            problems.append(f'authed: the route ran {served}, the auth source {auth_calls}, the reference serves {want}')
    folder = ctx.folder / 'static-root'
    folder.mkdir(parents=True, exist_ok=True)
    (folder / 'f.txt').write_bytes(b'static-2370')
    static = 'http_static of ["/s", ' + json.dumps(str(folder)) + ']\n'
    with server(ctx.binary, ctx.folder / 'static', routes='', extra=static) as port:
        hits = refused = 0
        for name, text, data, _ in rows:
            data = data.replace(b' /v ', b' /s/f.txt ', 1)
            d = ctx.ref.decide(data)
            r = exchange(port, data)
            if d.kind == 'refused':
                refused += 1
                if not (r and r[0] == d.status):
                    problems.append(f'static {name}: {r and r[0]}, reference {d.status}')
            elif d.kind == 'served' and d.target == b'/s/f.txt' and d.method == 'GET':
                hits += 1
                if not (r and r[0] == 200 and r[2] == b'static-2370'):
                    problems.append(f'static {name}: served {r and r[0]}')
        if refused != 74 or hits == 0:
            problems.append(f'static: refused {refused}, served the file {hits}')
    require(not problems, '; '.join(problems[:6]))
    print(f'COUNTS: authed route=109 requests auth calls={auth_calls}/{want}; static refused={refused}/74 file served={hits}', flush=True)


def row_framings(ctx):
    rows = {r[0]: r for r in named_rows()}
    one = 'shared_incr of ["served", 1]\njson_encode of (http_request_header of "cookie")'
    many = 'shared_incr of ["served", 1]\nhttp_request_headers of null'
    for label, source in (('http_request_header', one), ('http_request_headers', many)):
        routes = route('POST', '/v', source) + route('GET', '/v', source)
        with server(ctx.binary, ctx.folder / f'framing-{label}', routes=routes) as port:
            for name in ('A16', 'A15'):
                r = exchange(port, rows[name][2])
                require(r and r[0] == 400, f'{name} with {label}: {r and r[0]}')
            require(count_of(port)[0] == 0, f'a route ran for A15 or A16 ({label})')
    print('COUNTS: framings=2 rows x 2 routes, route runs=0', flush=True)


def row_time(ctx):
    if ctx.sanitizer:
        raise Skipped('time limits on a sanitizer build (the make http build judges this row)')
    results = []
    with server(ctx.binary, ctx.folder / 'time', {'EIGS_HTTP_HEADER_MIN_RATE': '0'}) as port:
        def timed(parts, gap, label, lo, hi, from_first=False):
            with socket.create_connection(('127.0.0.1', port), timeout=60) as peer:
                first = time.monotonic()
                last = first
                for i, part in enumerate(parts):
                    # Wait the gap, but stop sending once an answer is there.
                    if i and select.select([peer], [], [], gap)[0]:
                        break
                    peer.sendall(part)
                    last = time.monotonic()
                r = parse(read_all(peer))
                took = time.monotonic() - (first if from_first else last)
            results.append(f'{label}: {r and r[0]} after {took:.2f}s')
            print(f'TIME: {label}: status {r and r[0]} after {took:.3f}s (bound {lo}..{hi})', flush=True)
            require(r and r[0] == 408 and lo <= took <= hi, results[-1])
        timed([b'GET /v HT'], 0, 'half a request line', 4.5, 8)
        timed([b'POST /v HTTP/1.1\r\nHost: h\r\nContent-Length: 9\r\n\r\nBODY'], 0, 'four of nine body bytes', 4.5, 8)
        head = b'POST /v HTTP/1.1\r\nHost: h\r\nContent-Length: 20\r\n\r\n'
        timed([head + b'a'] + [b'a'] * 12, 3, 'one byte every 3 s', 29, 35, from_first=True)
        require(count_of(port)[0] == 0, 'a route ran for a request that timed out')


def row_cost(ctx):
    def head(size, lines):
        base = b'GET /v HTTP/1.1\r\nHost: h\r\n'
        n = (size - len(base) - 2) // 20
        rest = size - len(base) - 2 - 20 * n
        body = [b'X-B: vvvvvvvvvvvvv\r\n'] * n
        if rest:
            body[-1] = b'X-B: ' + b'v' * (13 + rest) + b'\r\n'
        out = [base] + body + [b'\r\n']
        require(len(b''.join(out)) == size, 'cost head size')
        return out if lines else [b''.join(out)]
    samples = {}
    with server(ctx.binary, ctx.folder / 'cost') as port:
        def once(parts):
            with socket.create_connection(('127.0.0.1', port), timeout=60) as peer:
                peer.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
                start = time.perf_counter()
                for part in parts:
                    peer.sendall(part)
                r = parse(read_all(peer))
                took = time.perf_counter() - start
            require(r and r[0] == 200, f'cost request answered {r and r[0]}')
            return took
        shapes = [(size, lines) for lines in (False, True) for size in (8192, 65536)]
        for _ in range(5):
            for size, lines in shapes:
                samples.setdefault((size, lines), []).append(once(head(size, lines)))
    bad = []
    for lines in (False, True):
        a = statistics.median(samples[8192, lines])
        b = statistics.median(samples[65536, lines])
        way = 'one write for each line' if lines else 'one write'
        print(f'COST: {way}: 8192={a:.6f}s 65536={b:.6f}s ratio={b / a:.3f} (bound 24) '
              f'samples={[round(x, 6) for x in samples[8192, lines]]}/{[round(x, 6) for x in samples[65536, lines]]}', flush=True)
        if b / a > 24:
            bad.append(f'{way} ratio {b / a:.3f}')
    require(not bad, '; '.join(bad))


BUDGET_HEAD, BUDGET_BODY, BUDGET_READ = 4096, 65536, 16384


def budget_request(body, framing):
    """#2370 "The budget": the request, announced or in 7 chunks (the first
    six of one seventh of the body's size rounded down)."""
    if framing == 'announced':
        return b'POST /v HTTP/1.1\r\nHost: h\r\nContent-Length: %d\r\n\r\n' % len(body) + body
    size = len(body) // 7
    parts = [body[i * size:(i + 1) * size] for i in range(6)] + [body[6 * size:]]
    return (b'POST /v HTTP/1.1\r\nHost: h\r\nTransfer-Encoding: chunked\r\n\r\n' +
            b''.join(b'%x\r\n' % len(p) + p + b'\r\n' for p in parts) + b'0\r\n\r\n')


def budget_try(port, data, way=0, cuts=None):
    """One try on a connection of its own, read to the end of the stream and
    closed. Returns the status, or a word for no answer."""
    try:
        r = exchange(port, data, way=way, cuts=cuts, wait=30)
    except (AssertionError, OSError) as exc:
        return f'error {exc}'[:120]
    return r[0] if r else 'no answer'


def budget_served(port, data, want_body, way=0, cuts=None):
    """Served: tries again 500 ms after closing a failed try, for 10 s at
    most. Returns (ok, the answers with their times)."""
    start, answers = time.monotonic(), []
    while True:
        try:
            r = exchange(port, data, way=way, cuts=cuts, wait=30)
            said = r[0] if r else 'no answer'
            ok = bool(r) and r[0] == 200 and r[2] == want_body
        except (AssertionError, OSError) as exc:
            said, ok = f'error {exc}'[:120], False
        answers.append(f'{said}@{time.monotonic() - start:.2f}s')
        if ok or time.monotonic() - start + .5 > 10:
            return ok, answers
        time.sleep(.5)


def budget_refused(port, data, way=0, cuts=None):
    """503: each of five tries, 100 ms apart, is answered 503."""
    answers = []
    for i in range(5):
        if i:
            time.sleep(.1)
        answers.append(budget_try(port, data, way, cuts))
    return all(a == 503 for a in answers), answers


def row_budget(ctx):
    """#2370 "The budget": what a connection is charged against
    EIGS_HTTP_MAX_BODY_TOTAL: 16,384 bytes it reads into, and a room for its
    head and one for its body, each 1,024 doubled until the bytes held and one
    more fit, cut at the limit and one byte."""
    if ctx.sanitizer:
        raise Skipped('the budget on a sanitizer build (the make http build judges this row)')
    rng = random.Random(ctx.seed + 3)
    body = bytes(rng.randint(1, 255) for _ in range(BUDGET_BODY))
    small = b'GET /v HTTP/1.1\r\nHost: h\r\n'
    routes = (route('POST', '/v', 'len of (http_request_body of null)') +
              route('GET', '/v', '"small"'))
    limits = {'EIGS_HTTP_MAX_HEAD': str(BUDGET_HEAD), 'EIGS_HTTP_MAX_BODY': str(BUDGET_BODY)}
    lines, failed, servers = [], 0, [0]

    def at(total, label):
        servers[0] += 1
        env = dict(limits, EIGS_HTTP_MAX_BODY_TOTAL=str(total))
        return server(ctx.binary, ctx.folder / f'budget-{servers[0]}-{label}', env, routes=routes)

    def verdict(ok, what):
        nonlocal failed
        failed += not ok
        line = f'{"PASS" if ok else "FAIL"}: budget {what}'
        lines.append(line)
        print(line, flush=True)

    def served_and_refused(name, part, framing, room):
        data = budget_request(part, framing)
        charge = BUDGET_READ + 1024 + room
        d = ctx.ref.decide(data, head=BUDGET_HEAD, body=BUDGET_BODY)
        require(d.kind == 'served' and d.body == part, f'{name}: the reference says {d.line[:80]}')
        way, cuts = 0, None
        if name == 'under its room' and framing == 'announced':
            # Hold 16,383 body bytes before the final 16,384: the last read
            # makes bytes-held-plus-one exactly 32,768.
            head = data.index(b'\r\n\r\n') + 4
            way, cuts = 3, (head + 16383, len(data))
        with at(charge, 'served') as port:
            ok1, got1 = budget_served(port, data, str(len(part)).encode(), way, cuts)
        with at(charge - 1, 'refused') as port:
            ok2, got2 = budget_refused(port, data, way, cuts)
        verdict(ok1 and ok2, f'{name} ({framing}, body {len(part)}): {charge} served {got1}; '
                             f'{charge - 1} answered {got2}')

    for framing in ('announced', 'chunked'):
        served_and_refused('at the limit', body, framing, BUDGET_BODY + 1)
    for framing in ('announced', 'chunked'):
        served_and_refused('under its room', body[:32767], framing, 32768)

    pad = BUDGET_HEAD - len(small) - len(b'X-Pad: \r\n\r\n')
    padded = small + b'X-Pad: ' + b'p' * pad + b'\r\n\r\n'
    require(len(padded) == BUDGET_HEAD, f'padded head {len(padded)}')
    d = ctx.ref.decide(padded, head=BUDGET_HEAD, body=BUDGET_BODY)
    require(d.kind == 'served' and d.head_len == BUDGET_HEAD, f'padded head: the reference says {d.line[:80]}')
    with at(BUDGET_READ + BUDGET_HEAD + 1, 'head') as port:
        ok, got = budget_served(port, padded, b'small')
    verdict(ok, f'the head\'s room (head {len(padded)}): {BUDGET_READ + BUDGET_HEAD + 1} served {got}')

    full = BUDGET_READ + 1024 + BUDGET_BODY + 1
    data = budget_request(body, 'announced')
    refused = [(n, r) for n, _, r, _ in named_rows()]
    refused = [(n, r, ctx.ref.decide(r, head=BUDGET_HEAD, body=BUDGET_BODY)) for n, r in refused]
    refused = [(n, r, d) for n, r, d in refused if d.kind == 'refused']
    require(refused, 'no named row is refused under the budget\'s limits')
    bad = []
    with at(full, 'refusal') as port:
        for name, row, d in refused:
            got = budget_try(port, row)
            ok, answers = budget_served(port, data, str(BUDGET_BODY).encode())
            if got != d.status or not ok:
                bad.append(f'{name}: {got} (reference {d.status}), then {answers}')
                break       # the charge is not given back: the rows after it say nothing more
    verdict(not bad, f'given back after a refusal: {full}, ' + (f'stopped at the first failure: {bad[0]}' if bad else
                     f'{len(refused)}/{len(refused)} refused rows each followed by the request served'))

    cut = data.index(b'\r\n\r\n') + 4 + 40000
    bad = []
    with at(full, 'drop') as port:
        for i in range(20):
            with socket.create_connection(('127.0.0.1', port), timeout=10) as peer:
                peer.sendall(data[:cut])
            ok, answers = budget_served(port, data, str(BUDGET_BODY).encode())
            if not ok:
                bad.append(f'drop {i}: then {answers}')
                break
    verdict(not bad, f'given back after a drop: {full}, ' + (f'stopped at the first failure: {bad[0]}' if bad else
                     f'20/20 drops of {cut} bytes each followed by the request served'))

    require(len(lines) == 7, f'budget lines {len(lines)}, want 7')
    require(failed == 0, f'{failed} of 7 budget checks failed: ' + ' | '.join(l for l in lines if l.startswith('FAIL'))[:900])
    print(f'COUNTS: budget checks=7/7 refused rows={len(refused)} servers={servers[0]}', flush=True)


def row_leak(ctx):
    """RSS5 of tests/test_http_rss_growth.sh. Counting the requests of each
    batch anew from 0, request i is: when i is even, the refused named row
    i/2 (the 74 in the table's order, again from the first after the last);
    when i leaves 1 on division by 4, a chunked request of 2,000 bytes; when
    it leaves 3, one of 60,000 bytes; each body in chunks of 8 bytes. RSS leg
    only: on this branch the heap sample fixtures read 0 (#2364)."""
    if not Path('/proc/self/status').exists():
        raise Skipped('requires Linux /proc RSS')
    if ctx.sanitizer:
        raise Skipped('RSS on a sanitizer build (the release RSS gate owns this row)')
    refused = [(r[2], ctx.ref.decide(r[2])) for r in named_rows()]
    refused = [(data, d) for data, d in refused if d.kind == 'refused']
    require(len(refused) == 74, f'refused rows {len(refused)}')
    rng = random.Random(ctx.seed + 2)
    chunked = {}
    for size in (2000, 60000):
        body = bytes(rng.randint(1, 255) for _ in range(size))
        data = (b'POST /v HTTP/1.1\r\nHost: h\r\nTransfer-Encoding: chunked\r\n\r\n' +
                b''.join(chunks_of(body, size // 8)) + b'0\r\n\r\n')
        d = ctx.ref.decide(data)
        require(d.kind == 'served' and d.body == body, f'chunked {size}: the reference says {d.line[:80]}')
        chunked[size] = (data, d)
    ids = []
    with server(ctx.binary, ctx.folder / 'leak', pid_out=ids) as port:
        def batch(n):
            counts = Counter()
            for i in range(n):
                if i % 2 == 0:
                    data, d = refused[(i // 2) % len(refused)]
                    kind = 'refused'
                else:
                    kind = 2000 if i % 4 == 1 else 60000
                    data, d = chunked[kind]
                judge(data, d, exchange(port, data), f'leak {kind}')
                counts[kind] += 1
            require(sum(counts.values()) == n, f'batch {counts}/{n}')
            return f'refused={counts["refused"]} chunked2000={counts[2000]} chunked60000={counts[60000]}'

        def rss():
            for line in Path(f'/proc/{ids[0]}/status').read_text().splitlines():
                if line.startswith('VmRSS:'):
                    return int(line.split()[1])
        print(f'RSS5 warm-up: {batch(1000)}', flush=True)
        samples = [rss()]
        for k in range(3):
            print(f'RSS5 batch {k + 1}: {batch(2000)}', flush=True)
            samples.append(rss())
    growth = [b - a for a, b in zip(samples, samples[1:])]
    median = statistics.median(growth)
    print(f'RSS5 door: samples={samples} growth={growth} median={median} kB threshold=4096 kB', flush=True)
    require(median <= 4096, f'RSS5 door grew {median} kB over 2000 requests (threshold 4096); batches={growth}')


def row_record(ctx):
    """Not a check: what a server answers for each named row (the base table)."""
    show = 'h is http_request_headers of null\nb is http_request_body of null\njson_encode of [len of h, len of b, b]'
    routes = ''.join(route(m, '/v', show) for m in ROUTE_METHODS) + route('CONNECT', 'h:443', show)
    with server(ctx.binary, ctx.folder / 'record', routes=routes) as port:
        for name, text, data, _ in named_rows():
            start = time.monotonic()
            try:
                r = exchange(port, data, wait=15)
            except OSError as exc:
                r = ('error', str(exc))
            took = time.monotonic() - start
            if r is None:
                said = 'no answer'
            elif r[0] == 'error':
                said = r[1]
            else:
                said = f'{r[0]} ' + ' | '.join(l.decode(errors='replace') for l in r[2].split(b'\n') if l)[:300]
            print(f'RECORD\t{name}\t{text}\t{took:.2f}s\t{said}', flush=True)


# ---------------------------------------------------------------- main

class Context:
    pass


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--binary', default=str(ROOT / 'src/eigenscript'))
    parser.add_argument('--row', action='append')
    parser.add_argument('--scratch')
    parser.add_argument('--seed', type=int)
    parser.add_argument('--record', action='store_true')
    args = parser.parse_args()
    ctx = Context()
    ctx.binary = str(Path(args.binary).resolve())
    ctx.seed = args.seed if args.seed is not None else int.from_bytes(os.urandom(3), 'big')

    population = {}

    def population_part(part):
        def run(c):
            if not population:
                population.update(row_population(c))
            ok, detail = population[part]
            require(ok, detail)
        return run

    rows = [('D01-reference', row_reference), ('D02-named', row_named), ('D03-at-byte', row_at_byte),
            ('D04-dealt', population_part('dealt')), ('D05-sweep', population_part('sweep')),
            ('D06-head-limit', row_head_limit), ('D07-body-limit', row_body_limit), ('D08-held', row_held),
            ('D09-no-route', population_part('counter')), ('D10-authed-static', row_authed_static),
            ('D11-framings', row_framings), ('D12-time', row_time), ('D13-cost', row_cost),
            ('D15-budget', row_budget)]
    # RSS5 of tests/test_http_rss_growth.sh runs this row; the section does not.
    by_name = rows + [('D14-leak', row_leak)]
    if args.record:
        rows = [('record', row_record)]
    elif args.row:
        selected = set(args.row)
        require(selected <= {n for n, _ in by_name}, f'unknown rows {selected - {n for n, _ in by_name}}')
        rows = [(n, f) for n, f in by_name if n in selected]
    print(f'HTTP_DOOR seed={ctx.seed} rows={len(rows)}', flush=True)

    def run(folder):
        ctx.folder = folder
        ctx.ref = Reference(folder)
        ctx.sanitizer = sanitizer(ctx.binary)
        passed = failed = skipped = 0
        for name, fn in rows:
            started = time.monotonic()
            try:
                fn(ctx)
            except Skipped as why:
                skipped += 1
                print(f'SKIP: {name}: {why}', flush=True)
            except Exception as exc:
                failed += 1
                print(f'FAIL: {name}: {type(exc).__name__}: {exc}', flush=True)
            else:
                passed += 1
                print(f'PASS: {name} ({time.monotonic() - started:.1f}s)', flush=True)
        require(passed + failed + skipped == len(rows) > 0, 'row accounting')
        print(f'HTTP_DOOR: {passed} passed, {failed} failed, {skipped} skipped', flush=True)
        return int(failed != 0)
    if args.scratch:
        Path(args.scratch).mkdir(parents=True, exist_ok=True)
        return run(Path(args.scratch))
    with tempfile.TemporaryDirectory(prefix='eigs-door-') as directory:
        return run(Path(directory))


if __name__ == '__main__':
    raise SystemExit(main())
