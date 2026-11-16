#!/usr/bin/env python3
"""#2373 raw-socket rows; expectations come only from Decision's byte oracle.

--row selects rows for one-time source plants; no plant is a permanent test.
"""
import argparse
from collections import Counter
from concurrent.futures import ThreadPoolExecutor
import contextlib
import hashlib
import json
import os
from pathlib import Path
import random
import re
import signal
import socket
import statistics
import subprocess
import tempfile
import threading
import time

from http_readiness import pick_port
from http_request_header_reference import (TOKEN, LONG_NAME, NAMES, NO_REQUEST,
    Refusal, answer, describe, request_header, request_headers)
from test_http_respond import clean, equal, require, main_program

ROOT = Path(__file__).resolve().parents[1]
SEED = 2373


class Skipped(Exception):
    """A row that cannot be judged here; it is counted as skipped, never as passed."""


def route(path, source, method='GET', authed=False):
    return ('http_route_authed' if authed else 'http_route') + ' of ' + json.dumps(
        [method, path, 'code', source]) + '\n'


def request(lines=(), body=b'', path=b'/fields', method=b'GET', complete=True):
    head = method + b' ' + path + b' HTTP/1.1\r\n'
    head += b''.join(line + b'\r\n' for line in lines)
    if method == b'POST':
        head += b'Content-Length: ' + str(len(body)).encode() + b'\r\n'
    return head + (b'\r\n' if complete else b'') + body


def raw(port, data):
    with socket.create_connection(('127.0.0.1', port), timeout=30) as peer:
        peer.sendall(data)
        peer.shutdown(socket.SHUT_WR)  # also exercises today's incomplete-head path
        chunks = []
        while True:
            chunk = peer.recv(65536)
            if not chunk:
                return b''.join(chunks)
            chunks.append(chunk)


def body(port, data, status=200):
    response = raw(port, data)
    require(response.startswith(f'HTTP/1.1 {status} '.encode()), f'status: {response[:300]!r}')
    head, sep, payload = response.partition(b'\r\n\r\n')
    require(bool(sep), 'response has no empty line')
    lengths = [int(line.split(b':', 1)[1]) for line in head.split(b'\r\n')
               if line.lower().startswith(b'content-length:')]
    require(lengths == [len(payload)], f'response framing {lengths}/{len(payload)}')
    return payload


SUMMARY = '''define summary(name, vals) as:
    local out is name + " " + (str of (len of vals))
    for v in vals:
        out is out + " " + (str of (len of v)) + " " + (sha256 of v)
    return out + "\\n"
'''
FIELDS = SUMMARY + '''define fields_for(name) as:
    return http_request_header of name
''' + 'out is ""\nfor name in ' + json.dumps([n.decode() for n in NAMES]) + ''':
    out is out + (summary of [name, fields_for of name])
h is http_request_headers of null
out + "head " + (str of (len of h)) + " " + (sha256 of h) + "\\n"'''
PAD = '''
pad is 0
loop while pad < 400:
    filler is "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"
    pad is pad + 1
'''


@contextlib.contextmanager
def server(binary, folder, extra='', trace=False, pid_out=None):
    folder.mkdir(parents=True, exist_ok=True)
    port = pick_port()
    source = route('/fields', FIELDS) + route('/fields', FIELDS, 'POST')
    source += route('/plain', '"plain"') + extra
    source += 'http_route of ["GET", "/ready", "ready-2373"]\n'
    source += f'http_serve of {port}\n'
    script = folder / 'server.eigs'
    script.write_text(source)
    lint = subprocess.run([binary, '--lint', '--json', str(script)], cwd=ROOT,
                          capture_output=True, text=True, timeout=20)
    require(lint.returncode == 0 and lint.stdout.strip() == '[]' and not lint.stderr,
            f'lint rc={lint.returncode}: {lint.stdout}{lint.stderr}')
    env = os.environ.copy()
    if trace:
        env['EIGS_TRACE'] = str(folder / 'trace.tape')
    with (folder / 'server.log').open('w+') as log:
        proc = subprocess.Popen([binary, str(script)], cwd=ROOT, env=env, stdout=log, stderr=log)
        try:
            deadline = time.monotonic() + 30
            while time.monotonic() < deadline and proc.poll() is None:
                try:
                    if body(port, request(path=b'/ready')) == b'ready-2373':
                        break
                except OSError:
                    pass
                time.sleep(.05)
            else:
                log.seek(0)
                raise AssertionError(f'server not ready rc={proc.poll()}: {log.read()}')
            if pid_out is not None:
                pid_out.append(proc.pid)
            yield port
            require(proc.poll() is None, f'server exited rc={proc.returncode}')
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
            clean(output)
            require(proc.returncode in (0, -signal.SIGTERM), f'server rc={proc.returncode}: {output}')


def compare(port, data, label):
    equal(body(port, data), answer(data), label)


def dealt_line(rng, kind):
    names = (b'origin', b'cookie', b'authorization', b'x-a', LONG_NAME)
    name = names[kind] if kind < 5 else rng.choice(names)
    name = rng.choice((name.lower(), name.upper(), bytes(
        c - 32 if 97 <= c <= 122 and rng.randrange(2) else c for c in name)))
    value = bytes(rng.randint(0x21, 0x7e) for _ in range(rng.randint(1, 40)))
    if kind in (9, 10, 11, 12, 13):
        value = bytes(rng.randint(0x21, 0x7e) for _ in range(rng.randint(2, 40)))
    if kind == 5:
        value = b''
    elif kind == 6:
        value = b' \t\t '
    elif kind == 7:
        ws = lambda: bytes(rng.choice(b' \t') for _ in range(rng.randint(1, 3)))
        return name + b':' + ws() + value + ws()
    elif kind == 8:
        return name + b':' + value
    elif kind == 9:
        pos = rng.randint(1, len(value) - 1)
        value = value[:pos] + bytes(rng.choice(b' \t') for _ in range(rng.randint(1, 3))) + value[pos:]
    elif 10 <= kind <= 13:
        c = (rng.randint(0x80, 0xff) if kind == 10 else
             rng.choice([c for c in range(1, 32) if c not in (9, 10, 13)] + [127]) if kind == 11 else
             13 if kind == 12 else 10)
        pos = rng.randrange(len(value) + 1)
        value = value[:pos] + bytes([c]) + value[pos:]
    elif kind == 14:
        value += b': ' + rng.choice(names)
    elif kind == 15:
        value = bytes(rng.randint(0x21, 0x7e) for _ in range(2000))
    elif kind == 16:
        name = b'z' + name
    elif kind == 17:
        name += b'z'
    elif kind == 18:
        name = name[:-1]
    elif kind == 19:
        return name + b' ' + value.replace(b':', b'x')
    elif kind == 20:
        return name
    elif kind == 21:
        name += b' '
    elif kind == 22:
        name += b'\t'
    elif kind == 23:
        name = b' ' + name
    elif kind == 24:
        name = b'\t' + name
    elif kind == 25:
        name = b''
    return name + b': ' + value


def dealt(binary, folder):
    rng = random.Random(SEED)
    kinds = list(range(26)) * 15
    rng.shuffle(kinds)
    posts = set(rng.sample(range(390), 195))
    bodies = (b'', b't' * 40, b'x\r\nOrigin: https://b.example\r\n',
              b'b' * 20 + b'\r\n\r\nCookie: a=b\r\n')
    counts = Counter()
    compared = post_count = 0
    with server(binary, folder) as port:
        for i, kind in enumerate(kinds):
            others = [dealt_line(rng, rng.randrange(26)) for _ in range(rng.randrange(11))]
            others.insert(rng.randrange(len(others) + 1), dealt_line(rng, kind))
            post = i in posts
            data = request(others, rng.choice(bodies) if post else b'', method=b'POST' if post else b'GET')
            compare(port, data, f'deal {i} kind {kind}')
            counts[kind] += 1
            compared += 1
            post_count += post
    require(compared == 390 and post_count == 195 and counts == Counter({k: 15 for k in range(26)}),
            f'dealt population {compared} POST={post_count} {counts}')
    print(f'COUNTS: dealt requests={compared}/390 POST={post_count}/195 kinds=' +
          ','.join(f'{k}:{counts[k]}' for k in range(26)), flush=True)


def name_bytes(binary, folder):
    alphabet = [c for c in range(1, 256) if c not in (10, 13, 58)]
    lines = [b'X-A' + bytes([c]) + b': v' + str(c).encode() for c in alphabet]
    code = SUMMARY + '''out is ""
for c in range of [1, 256]:
    if c != 10 and c != 13 and c != 58:
        name is "x-a" + (str_from_bytes of ([c]))
        try:
            vals is http_request_header of name
            out is out + (summary of [str of c, vals])
        catch e:
            out is out + (str of c) + " raised " + e.kind + "\\n"
out'''
    with server(binary, folder, route('/names', code)) as port:
        data = request(lines)
        compare(port, data, 'whole names')
        data = request(lines, path=b'/names')
        expected = b''
        counts = Counter()
        for c in alphabet:
            try:
                vals = request_header(data, b'x-a' + bytes([c]))
                expected += describe(str(c).encode(), vals)
                counts[len(vals)] += 1
            except Refusal as exc:
                expected += str(c).encode() + b' raised ' + exc.kind.encode() + b'\n'
                counts['raised'] += 1
        actual = body(port, data)
        equal(actual, expected, 'name byte argument sweep')
        require(len(lines) == len(actual.splitlines()) == 252 and counts == Counter({'raised': 175, 1: 25, 2: 52}),
                f'name population {len(lines)}, {counts}')
    print('COUNTS: name lines=252/252 calls=252/252 raised=175 single=25 double=52', flush=True)


def value_bytes(binary, folder):
    lines = [b'X-V: ' + bytes([c]) + b'mid' + bytes([c]) for c in range(1, 256) if c not in (10, 13)]
    with server(binary, folder) as port:
        compare(port, request(lines), 'value ends alphabet')
    require(len(lines) == 253, f'value population {len(lines)}')
    print('COUNTS: value lines=253/253', flush=True)


def named(binary, folder, which):
    cases = {
        'case-order': [request([b'oRiGiN:   https://a.example \t ']),
                       request([b'Origin: first', b'Origin: second', b'ORIGIN: third'])],
        'request-line': [request(path=b'/fields?Origin:https://a.example', method=b'POST'),
                         b'GET /fields HTTP/1.1\nOrigin: https://a.example\r\n\r\n',
                         b'GET /fields HTTP/1.1\rOrigin: https://a.example\r\n\r\n'],
        'long': [request([b'X-V: ' + b'v' * 100000]), request([b'Origin']),
                 request([b'Origin:https://a.example']), request([LONG_NAME + b'n: v']),
                 request([b'n' * 100000 + b':v', b'X-A: after'])],
        'body': [request([], b'x\r\nOrigin: https://b.example\r\n', method=b'POST')],
        'continuation': [request([b'X-A: first', b' Origin: https://c.example'])],
        'unframed': [request([b'Origin: before'], complete=False),
                     request([b'Origin: before', b'X: before\0after'])],
    }[which]
    with server(binary, folder) as port:
        for i, data in enumerate(cases):
            compare(port, data, f'{which} {i}')
        compare(port, request(), 'next request has no previous fields')
    print(f'COUNTS: {which} requests={len(cases)} next=1', flush=True)


def arguments(binary, folder):
    values = ('42', 'null', 'true', '([])', '{}', '""', json.dumps('n' * 65),
              '"x a"', '"x:a"', 'str_from_bytes of ([128])', '"x-a\\r"', '"x-a\\n"')
    code = ''
    for i, expr in enumerate(values):
        kind = 'type_mismatch' if i < 5 else 'value'
        code += f'''caught is false
try:
    http_request_header of ({expr})
catch e:
    assert of [e.kind == "{kind}", "argument {i} kind"]
    caught is true
assert of [caught, "argument {i} accepted"]
'''
    code += '"plain"'
    special = SUMMARY + 'out is ""\nfor name in ' + json.dumps(
        ['a', LONG_NAME.decode(), 'content-length', 'connection', 'set-cookie', 'transfer-encoding']) + ''':
    out is out + (summary of [name, http_request_header of name])
out'''
    with server(binary, folder, route('/arguments', code) + route('/special', special, 'POST')) as port:
        equal(raw(port, request(path=b'/arguments')), raw(port, request(path=b'/plain')), 'caught refusals leave route unchanged')
        data = request([b'a: one', LONG_NAME + b': long', b'Connection: close', b'Set-Cookie: a=b'],
                       b'abc', path=b'/special', method=b'POST')
        expected = b''.join(describe(n, request_header(data, n)) for n in
                            (b'a', LONG_NAME, b'content-length', b'connection', b'set-cookie', b'transfer-encoding'))
        equal(body(port, data), expected, 'all valid names including response-reserved names')
    print('COUNTS: argument refusals=12/12 valid names=6/6', flush=True)


def context(binary, folder):
    out = main_program(binary, folder, '''try:
    http_request_header of "x-a"
catch e:
    print of (json_encode of [e.kind, e.message])
print of (len of (http_request_headers of null))
''')
    require(out == json.dumps(['value', NO_REQUEST], separators=(',', ':')) + '\n0\n', f'main context {out!r}')
    thread = '''define child() as:
    return http_request_header of "x-a"
caught is false
try:
    thread_join of (spawn of child)
catch e:
    assert of [e.kind == "value", "child kind"]
    assert of [e.message == "http_request_header: no request is being answered", "child message"]
    caught is true
assert of [caught, "spawned thread accepted"]
"thread"'''
    task = '''define later() as:
    return http_request_header of "x-a"
x is task_join of (task_spawn of later)
json_encode of x'''
    auth = 'if len of (http_request_header of "x-a") == 0:\n    "denied"\nelse:\n    ""'
    setup = 'shared_set of ["require_auth", ' + json.dumps(auth) + ']\n"setup"'
    extra = route('/thread', thread) + route('/task', task) + route('/setup', setup)
    extra += route('/auth', 'json_encode of (http_request_header of "x-a")', authed=True)
    with server(binary, folder / 'serve', extra) as port:
        equal(body(port, request([b'X-A: own'], path=b'/thread')), b'thread', 'spawn context')
        equal(body(port, request([b'X-A: task'], path=b'/task')), b'["task"]', 'task context')
        equal(body(port, request(path=b'/setup')), b'setup', 'auth setup')
        equal(body(port, request(path=b'/auth'), 401), b'denied', 'auth sees absence')
        equal(body(port, request([b'X-A: auth'], path=b'/auth')), b'["auth"]', 'auth and route see request')
    print('COUNTS: context main=1 thread=1 task=1 auth=2', flush=True)


def sandbox(binary, folder):
    code = '''r is sandbox_run of ["return http_request_header of \\\"x-a\\\"", 10000, 2000000, 10000]
assert of [r.ok == false, "sandbox allowed HTTP"]
assert of [r.error.kind == "sandbox", "sandbox kind"]
"sandbox"'''
    with server(binary, folder, route('/sandbox', code)) as port:
        equal(body(port, request(path=b'/sandbox')), b'sandbox', 'sandbox HTTP refusal')


def concurrency(binary, folder):
    # All 16 handlers must be alive before any reads its fields. This makes
    # an accidentally process-global request pointer observable without a race
    # in the test's scheduling premise.
    barrier_source = 'shared_incr of ["arrived", 1]\nloop while (shared_get of "arrived") < 16:\n    usleep of 1000\n' + FIELDS
    with server(binary, folder, route('/parallel', barrier_source)) as port:
        barrier = threading.Barrier(16)
        def one(i):
            barrier.wait(timeout=20)
            compare(port, request([b'X-A: own-' + str(i).encode()], path=b'/parallel'), f'concurrent {i}')
        with ThreadPoolExecutor(max_workers=16) as pool:
            list(pool.map(one, range(16)))
        compare(port, request(), 'after concurrent requests')
    print('COUNTS: concurrent=16/16 next=1', flush=True)


def taped_lists(data):
    # TRACE.md value serialization: oversized N uses @encoded_bytes: and
    # immediate same-stream C chunks. These witnesses contain ASCII strings,
    # whose tape representation is also JSON; no output supplies a value.
    records, chunks = [], 0
    lines = data.splitlines()
    i = 0
    while i < len(lines):
        match = re.fullmatch(r'N ([0-9]+) http_request_header=(.*)', lines[i])
        i += 1
        if not match:
            continue
        stream, encoded = match.groups()
        if encoded.startswith('@'):
            size, encoded = encoded[1:].split(':', 1)
            size = int(size)
            while len(encoded) < size:
                require(i < len(lines), 'lookup continuation missing')
                prefix = 'C ' + stream + ' '
                require(lines[i].startswith(prefix), 'lookup continuation stream/order')
                part = lines[i][len(prefix):]
                require(0 < len(part) <= 65536, 'lookup continuation size')
                encoded += part
                chunks += 1
                i += 1
            require(len(encoded) == size, 'lookup encoded byte count')
        records.append(json.loads(encoded))
    return records, chunks


def tape(binary, folder):
    code = 'a is http_request_header of "x-a"\nb is http_request_header of "missing"\n' + PAD + '\njson_encode of [a,b]'
    refused = 'try:\n    http_request_header of 42\ncatch e:\n    assert of [e.kind == "type_mismatch", "refusal kind"]\n' + PAD + '\n"refused"'
    big = 'a is http_request_header of "x-v"\n' + PAD + '\nlen of a[0]'
    extra = route('/tape', code) + route('/refused', refused) + route('/big', big)
    with server(binary, folder, extra, trace=True) as port:
        for i in range(3):
            equal(body(port, request([f'X-A: tape-{i}'.encode()], path=b'/tape')),
                  f'[["tape-{i}"],[]]'.encode(), 'tape response')
        data = (folder / 'trace.tape').read_text()
        records = [l for l in data.splitlines() if ' http_request_header=' in l]
        require(len(records) == 6, f'lookup tape records={len(records)}, want 6')
        expected_lists = [v for i in range(3) for v in ([f'tape-{i}'], [])]
        require(taped_lists(data)[0] == expected_lists, 'taped lists differ from returned lists')
        for i in range(3):
            require(sum(f'=["tape-{i}"]' in l for l in records) == 1, f'taped list {i}')
        require(sum(l.endswith('=[]') for l in records) == 3, 'missing empty taped lists')
        equal(body(port, request(path=b'/refused')), b'refused', 'refused tape response')
        after = (folder / 'trace.tape').read_text()
        require(after.count(' http_request_header=') == 6, 'refused call wrote N')
        equal(body(port, request([b'X-V: ' + b'v' * 100000], path=b'/big')), b'100000', 'large taped response')
        after = (folder / 'trace.tape').read_text()
        require(after.count(' http_request_header=') == 7, 'large call must write one N')
        actual_lists, chunks = taped_lists(after)
        require(chunks >= 1, 'large list missing continuation C')
        require(actual_lists == expected_lists + [['v' * 100000]], 'large taped list differs from returned list')
    print('COUNTS: tape N=6/6 refused=0/0 big N=1/1 C>=1', flush=True)


def cost(binary, folder):
    code = 'len of (http_request_header of "x-a")'
    with server(binary, folder, route('/cost', code)) as port:
        shapes = []
        # Each header line is exactly 20 bytes including CR LF.
        for n in (6250, 50000):
            shapes.append(('last', n, [b'X-B: ' + b'v' * 13] * (n - 1) + [b'X-A: ' + b'v' * 13], b'1'))
        for n in (6250, 50000):
            shapes.append(('all', n, [b'X-A: ' + b'v' * 13] * n, str(n).encode()))
        for n in (125000, 1000000):
            shapes.append(('value', n, [b'X-A: ' + b'v' * n], b'1'))
        prepared = [(shape, n, request(lines, path=b'/cost'), expected) for shape, n, lines, expected in shapes]
        samples = {(shape, n): [] for shape, n, _, _ in prepared}
        rng = random.Random(SEED)
        for _ in range(7):
            order = prepared[:]
            rng.shuffle(order)
            for shape, n, data, expected in order:
                start = time.perf_counter()
                actual = body(port, data)
                elapsed = time.perf_counter() - start
                equal(actual, expected, f'cost {shape} {n}')
                samples[shape, n].append(elapsed)
        violations = []
        for shape, small, large in [('last', 6250, 50000), ('all', 6250, 50000), ('value', 125000, 1000000)]:
            a, b = statistics.median(samples[shape, small]), statistics.median(samples[shape, large])
            print(f'COST: {shape} small={a:.9f}s large={b:.9f}s ratio={b/a:.6f} samples={samples[shape,small]}/{samples[shape,large]}', flush=True)
            if b / a > 24:
                violations.append(f'{shape} cost ratio {b/a:.6f} exceeds 24')
        require(not violations, '; '.join(violations))
    print('COUNTS: cost shapes=3/3 sizes=6/6 samples=42/42', flush=True)


def leak(binary, folder):
    if not Path('/proc/self/status').exists():
        raise Skipped('requires Linux /proc RSS')
    # ASan quarantine and TSan metadata measure the detector, not live leaks.
    symbols = subprocess.run(['nm', '-D', binary], capture_output=True, text=True, timeout=20)
    require(symbols.returncode == 0, 'cannot identify sanitizer build')
    if '__asan_init' in symbols.stdout or '__tsan_init' in symbols.stdout:
        raise Skipped('RSS on a sanitizer build (the release RSS gate owns this row)')
    code = 'i is 0\nloop while i < 128:\n    vals is http_request_header of "x-a"\n    assert of [len of vals == 1, "RSS lookup must allocate a value"]\n    assert of [len of vals[0] == 64, "RSS value allocation must be 65 bytes"]\n    i is i + 1\n"ok"'
    ids = []
    with server(binary, folder, route('/leak', code), pid_out=ids) as port:
        data = request([b'X-A: ' + b'v' * 64], path=b'/leak')
        def batch(n):
            completed = 0
            for _ in range(n):
                equal(body(port, data), b'ok', 'RSS request completion')
                completed += 1
            require(completed == n, f'RSS completed {completed}/{n}')
        def rss():
            lines = Path(f'/proc/{ids[0]}/status').read_text().splitlines()
            return int(next(l.split()[1] for l in lines if l.startswith('VmRSS:')))
        batch(1000)
        samples = [rss()]
        for _ in range(3):
            batch(2000)
            samples.append(rss())
        growth = [b-a for a,b in zip(samples, samples[1:])]
        median = statistics.median(growth)
        print(f'RSS4 http_request_header: samples={samples} growth={growth} median={median} kB threshold=4096 kB; calls=128/request values=64 bytes', flush=True)
        require(median <= 4096, f'RSS4 http_request_header leaked {median} kB over 2000 requests (threshold 4096); batches={growth}')
    print('COUNTS: leak warmup=1000/1000 batches=2000/2000,2000/2000,2000/2000', flush=True)


def docs_api(binary, folder):
    proc = subprocess.run([binary, '--api'], capture_output=True, text=True, timeout=20)
    clean(proc.stdout + proc.stderr)
    require(proc.returncode == 0 and 'http_request_header' in proc.stdout.split(), '--api missing lookup')
    for path in ('docs/BUILTINS.md', 'docs/TRACE.md'):
        require('`http_request_header`' in (ROOT / path).read_text(), f'{path} missing lookup')
    proc = subprocess.run(['bash', 'tools/tape_kinds_check.sh'], cwd=ROOT, capture_output=True, text=True, timeout=30)
    require(proc.returncode == 0, f'tape kinds: {proc.stdout}{proc.stderr}')


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--binary', default=str(ROOT / 'src/eigenscript'))
    parser.add_argument('--row', action='append')
    parser.add_argument('--scratch')
    args = parser.parse_args()
    rows = [('QH01-dealt', dealt), ('QH02-name-bytes', name_bytes), ('QH03-value-bytes', value_bytes)]
    rows += [(f'QH{i:02}-{name}', lambda b,p,n=name: named(b,p,n)) for i,name in enumerate(
        ('case-order', 'request-line', 'long', 'body', 'continuation', 'unframed'), 4)]
    rows += [('QH10-arguments', arguments), ('QH11-context', context), ('QH12-sandbox', sandbox),
             ('QH13-concurrency', concurrency), ('QH14-tape', tape), ('QH15-cost', cost), ('QH16-docs-api', docs_api), ('QH17-leak', leak)]
    if args.row:
        selected = set(args.row)
        require(selected <= {n for n, _ in rows}, f'unknown rows {selected}')
        rows = [(n,f) for n,f in rows if n in selected]
    print(f'HTTP_REQUEST_HEADER seed={SEED} rows={len(rows)}', flush=True)
    def run(folder):
        passed = failed = skipped = 0
        for name, fn in rows:
            path = folder / name
            path.mkdir(parents=True, exist_ok=True)
            try:
                fn(str(Path(args.binary).resolve()), path)
            except Skipped as why:
                skipped += 1
                print(f'SKIP: {name}: {why}', flush=True)
            except Exception as exc:
                failed += 1
                print(f'FAIL: {name}: {exc}', flush=True)
            else:
                passed += 1
                print(f'PASS: {name}', flush=True)
        require(passed + failed + skipped == len(rows) > 0, 'named row accounting')
        print(f'HTTP_REQUEST_HEADER: {passed} passed, {failed} failed, {skipped} skipped', flush=True)
        return int(failed != 0)
    if args.scratch:
        return run(Path(args.scratch))
    with tempfile.TemporaryDirectory(prefix='eigs-request-header-') as directory:
        return run(Path(directory))


if __name__ == '__main__':
    raise SystemExit(main())
