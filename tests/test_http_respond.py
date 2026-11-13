#!/usr/bin/env python3
"""#2351 response contract, checked against a separately written byte oracle.

All HTTP peers below use raw sockets, including HEAD and large header sets.
--row selects named rows for one-time source fault plants. No plants run here.
"""
import argparse
from collections import Counter
from concurrent.futures import ThreadPoolExecutor
import contextlib
import itertools
import json
import os
from pathlib import Path
import random
import signal
import socket
import subprocess
import tempfile
import threading
import time

from http_readiness import pick_port
from http_respond_reference import PHRASES, response_bytes

ROOT = Path(__file__).resolve().parents[1]
CORS = (("Access-Control-Allow-Origin", "https://a.example"),
        ("Access-Control-Allow-Methods", "GET, POST, OPTIONS"),
        ("Access-Control-Allow-Headers", "Content-Type"))
REGISTERED = (("X-Frame-Options", "DENY"), ("X-Registered", "registered"))
NO_REQUEST = "http_respond: no request is being answered"
SEED = 2351


def require(condition, detail):
    if not condition:
        raise AssertionError(detail)


def equal(actual, expected, label):
    if actual != expected:
        index = next((i for i, (a, b) in enumerate(zip(actual, expected)) if a != b),
                     min(len(actual), len(expected)))
        raise AssertionError(f"{label}: byte {index}, lengths {len(actual)}/{len(expected)}; "
                             f"got {actual[max(0,index-60):index+120]!r}, "
                             f"want {expected[max(0,index-60):index+120]!r}")


def clean(output):
    # Same sanitizer decision as the suite; diagnostics are fatal even at rc=0.
    result = subprocess.run(["bash", "-c",
        'source "$1"; lsan_classify "$(cat)"; test "$?" = 2',
        "classify", str(ROOT / "tests/lsan_classify.sh")], input=output,
        text=True, capture_output=True, check=False)
    require(result.returncode == 0, "sanitizer diagnostic:\n" + output)


def eigs_string(text):
    return json.dumps(text, ensure_ascii=False)


def route(path, source, authed=False):
    return ("http_route_authed" if authed else "http_route") + " of " + json.dumps(
        ["GET", path, "code", source], ensure_ascii=False) + "\n"


def raw_request(port, path, body="", method="GET"):
    data = body.encode("utf-8")
    request = (f"{method} {path} HTTP/1.1\r\nHost: localhost\r\n"
               f"Content-Length: {len(data)}\r\nConnection: close\r\n\r\n").encode("ascii") + data
    with socket.create_connection(("127.0.0.1", port), timeout=15) as peer:
        peer.sendall(request)
        chunks = []
        while True:
            chunk = peer.recv(65536)
            if not chunk:
                return b"".join(chunks)
            chunks.append(chunk)


def describe(port, calls=(), body="body", method="GET", path="/describe"):
    return raw_request(port, path, json.dumps({"calls": calls, "body": body},
                                             ensure_ascii=False), method)


DESCRIBE = '''define respond(item) as:
    return http_respond of item
d is json_decode of (http_request_body of null)
for item in d.calls:
    r is respond of item
    assert of [r == null, "http_respond returns null"]
d.body'''
REFUSE = '''d is json_decode of (http_request_body of null)
caught is false
try:
    http_respond of (d.call)
catch e:
    assert of [e.kind == d.kind, "wrong refusal kind"]
    caught is true
assert of [caught, "call was not refused"]
d.body'''
SEQUENCE = '''d is json_decode of (http_request_body of null)
for item in d.calls:
    http_respond of item
caught is false
try:
    http_respond of (d.refused)
catch e:
    assert of [e.kind == "limit", "wrong limit kind"]
    caught is true
assert of [caught, "limit was not enforced"]
d.body'''

SWEEP = '''d is json_decode of (http_request_body of null)
out is ""
for item in d.calls:
    kind is "ok"
    try:
        http_respond of item
    catch e:
        kind is e.kind
    out is out + kind + ","
out'''


@contextlib.contextmanager
def server(binary, folder, extra="", configured=False, trace=False):
    folder.mkdir(parents=True, exist_ok=True)
    port = pick_port()  # below the ephemeral range, bind-probed (#760)
    config = ''
    if configured:
        config = 'http_cors of "https://a.example"\n' + ''.join(
            'http_response_header of ' + json.dumps([name, val]) + '\n'
            for name, val in REGISTERED)
    source = config + route("/describe", DESCRIBE) + route("/refuse", REFUSE)
    source += route("/sequence", SEQUENCE) + route("/sweep", SWEEP) + route("/plain", '"plain"')
    source += extra + 'http_route of ["GET", "/ready", "ready-2351"]\n'
    source += f"http_serve of {port}\n"
    path = folder / 'server.eigs'
    path.write_text(source)
    lint = subprocess.run([binary, '--lint', '--json', str(path)], cwd=ROOT,
                          capture_output=True, text=True, timeout=15)
    require(lint.returncode == 0 and lint.stdout.strip() == '[]' and not lint.stderr,
            f"server lint rc={lint.returncode}: {lint.stdout}{lint.stderr}")
    env = os.environ.copy()
    if trace:
        env['EIGS_TRACE'] = str(folder / 'trace.tape')
    with (folder / 'server.log').open('w+') as log:
        proc = subprocess.Popen([binary, str(path)], cwd=ROOT, env=env,
                                stdout=log, stderr=log)
        try:
            deadline = time.monotonic() + 20
            while time.monotonic() < deadline and proc.poll() is None:
                try:
                    if raw_request(port, '/ready').endswith(b'\r\n\r\nready-2351'):
                        break
                except OSError:
                    pass
                time.sleep(.05)
            else:
                log.seek(0)
                raise AssertionError(f"server not ready rc={proc.poll()}: {log.read()}")
            yield port
            require(proc.poll() is None, f"server exited rc={proc.returncode}")
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
            require(proc.returncode in (0, -signal.SIGTERM),
                    f"server rc={proc.returncode}: {output}")


def main_program(binary, folder, source):
    path = folder / 'main.eigs'
    path.write_text(source)
    lint = subprocess.run([binary, '--lint', '--json', str(path)], cwd=ROOT,
                          capture_output=True, text=True, timeout=15)
    require(lint.returncode == 0 and lint.stdout.strip() == '[]' and not lint.stderr,
            f"main lint rc={lint.returncode}: {lint.stdout}{lint.stderr}")
    proc = subprocess.run([binary, str(path)], cwd=ROOT, capture_output=True,
                          text=True, timeout=20)
    clean(proc.stdout + proc.stderr)
    require(proc.returncode == 0 and not proc.stderr,
            f"main rc={proc.returncode}: {proc.stdout}{proc.stderr}")
    return proc.stdout


def generated_descriptions():
    rng = random.Random(SEED)
    names = ["Content-Type", "Cache-Control", "cache-control", "X-Frame-Options",
             "x-frame-options", "Access-Control-Allow-Origin", "Access-Control-Allow-Methods",
             "Access-Control-Allow-Headers", "Allow", "X" * 64, "X-Empty", "X-Inside"]
    values = ["text/html; charset=utf-8", "no-store", "private", "SAMEORIGIN",
              "SAMEORIGIN", "https://b.example", "GET", "X-Test", "GET", "long-name", "", "a\tb c"]
    statuses = list(PHRASES) + [299, 599]
    call_counts = [1] * 150 + [2] * 150
    rng.shuffle(call_counts)
    no_status = set(rng.sample([i for i, n in enumerate(call_counts) if n == 1], 30))
    second_status = set(rng.sample([i for i, n in enumerate(call_counts) if n == 2], 75))
    for i in range(300):
        calls = [{} for _ in range(call_counts[i])]
        if i not in no_status:
            calls[0]['status'] = statuses[i % len(statuses)]
            if i in second_status:
                calls[1]['status'] = rng.choice(statuses)
        for call in calls:
            count = rng.randrange(7)
            chosen = rng.sample(range(len(names)), count)
            # A call itself has no case-fold duplicate; repetition across calls is legal.
            headers = {}
            for index in chosen:
                if names[index].lower() not in {name.lower() for name in headers}:
                    headers[names[index]] = values[index]
            if i % 3 == 0:
                index = (i // 3) % len(names)
                headers = {names[index]: values[index]}
                # The cycle puts each listed edge into one third of the draws.
                headers.update({f"X-Draw-{j}": f"v{rng.randrange(100000)}" for j in range(count)})
                headers = dict(list(headers.items())[:6])
            call['headers'] = headers
            call['cookies'] = [f"draw{i}_{j}={rng.randrange(100000)}; HttpOnly"
                               for j in range(rng.randrange(4))]
        if len(calls) == 2 and i % 3 == 0 and calls[0]['headers']:
            key = next(iter(calls[0]['headers']))
            repeated = key.swapcase()
            calls[1]['headers'] = {repeated: "replaced", **{
                k: v for k, v in calls[1]['headers'].items() if k.lower() != key.lower()}}
            calls[1]['headers'] = dict(list(calls[1]['headers'].items())[:6])
        size = rng.randrange(6, 2001) if i % 3 == 0 else rng.randrange(2001)
        if i % 10 == 1 and i % 3:
            size = 0
        if not size:
            body = ''
        else:
            first = rng.choice(['{', '[', '<', 'a'])
            unit = 'é界' if i % 3 == 0 else 'x'
            body = first + unit * ((size - 1) // len(unit.encode()))
            body += 'x' * (size - len(body.encode()))
        yield calls, body, rng.choice(['GET', 'HEAD'])


def refusal_cases():
    """Exactly the 59 separately named rules from Done when, six variants each."""
    rng = random.Random(SEED ^ 354)
    factories = []
    def add(name, kind, apply):
        factories.append((name, kind, apply))
    for name, bad in [('list', [1, 2]), ('string', 'x'), ('number', 5)]:
        add('argument-' + name, 'type_mismatch', lambda good, bad=bad: bad)
    add('unknown-key', 'value', lambda good: {**good, 'other': 1})
    for name, bad in [('199', 199), ('600', 600), ('fraction', 404.5), ('text', '404'),
                      ('bool', True), ('null', None), ('list', []), ('dict', {})]:
        add('status-' + name, 'value' if name in ('199', '600', 'fraction') else 'type_mismatch',
            lambda good, bad=bad: {**good, 'status': bad})
    for key, wrong in [('headers', [('list', []), ('string', 'x'), ('null', None)]),
                       ('cookies', [('dict', {}), ('string', 'x'), ('null', None)])]:
        for name, bad in wrong:
            add(key + '-' + name, 'type_mismatch', lambda good, k=key, bad=bad: {**good, k: bad})
    for name, bad in [('empty', ''), ('65-bytes', 'X' * 65), ('space', 'X Bad'),
                      ('colon', 'X:Bad'), ('non-ascii', 'Xé')]:
        add('header-name-' + name, 'value', lambda good, bad=bad:
            {**good, 'headers': {**good['headers'], bad: 'valid'}})
    for name, bad in [('number', 9), ('list', []), ('dict', {}), ('null', None)]:
        add('header-value-type-' + name, 'type_mismatch', lambda good, bad=bad:
            {**good, 'headers': {**good['headers'], 'X-Bad': bad}})
    bad_bytes = [('cr', 'a\rb'), ('lf', 'a\nb'), ('non-ascii', 'aéb'), ('control', 'a\x01b'),
                 ('leading-space', ' a'), ('leading-tab', '\ta'),
                 ('trailing-space', 'a '), ('trailing-tab', 'a\t')]
    for name, bad in bad_bytes:
        add('header-value-' + name, 'value', lambda good, bad=bad:
            {**good, 'headers': {**good['headers'], 'X-Bad': bad}})
    add('duplicate-case', 'value', lambda good:
        {**good, 'headers': {**good['headers'], 'X-Dup': 'one', 'x-dup': 'two'}})
    for forbidden in ['Content-Length', 'Transfer-Encoding', 'Connection', 'Set-Cookie']:
        for label, spelling in [('own', forbidden), ('lower', forbidden.lower()), ('upper', forbidden.upper())]:
            add('forbidden-' + forbidden + '-' + label, 'value', lambda good, key=spelling:
                {**good, 'headers': {**good['headers'], key: 'valid'}})
    for name, bad in [('empty', ''), ('number', 9), ('list', [])] + bad_bytes:
        add('cookie-' + name, 'type_mismatch' if name in ('number', 'list') else 'value',
            lambda good, bad=bad: {**good, 'cookies': good['cookies'] + [bad]})
    require(len(factories) == 59 and len({name for name, _, _ in factories}) == 59,
            f'refusal rule population: {len(factories)}')
    for name, kind, mutate in factories:
        for _ in range(6):
            good = {'status': rng.choice(list(PHRASES)),
                    'headers': {f'X-Good-{rng.randrange(100000)}': f'v{rng.randrange(100000)}'},
                    'cookies': [f'one={rng.randrange(100000)}', f'two={rng.randrange(100000)}']}
            yield name, kind, mutate(good), f'body-{rng.randrange(100000)}'


def generated(binary, folder):
    cases = list(generated_descriptions())
    require(len(cases) == 300, f'description population {len(cases)}')
    count = 0
    for configured in (False, True):
        with server(binary, folder / str(configured), configured=configured) as port:
            for index, (calls, body, method) in enumerate(cases):
                equal(describe(port, calls, body, method), response_bytes(calls, body, method,
                    CORS if configured else (), REGISTERED if configured else ()),
                    f'draw {index} configured={configured} method={method}')
                count += 1
    require(count == 600, f'comparison count {count}, declared 600')
    print(f'COUNTS: generated responses={count}/600 seed={SEED}', flush=True)


def refusals(binary, folder):
    count = Counter()
    with server(binary, folder) as port:
        for name, kind, call, body in refusal_cases():
            payload = json.dumps({'call': call, 'kind': kind, 'body': body}, ensure_ascii=False)
            equal(raw_request(port, '/refuse', payload), response_bytes([], body), name)
            count[name] += 1
        body = 'atomic'
        payload = {'call': {'status': 404, 'headers': {'X Bad': 'x'}}, 'kind': 'value', 'body': body}
        equal(raw_request(port, '/refuse', json.dumps(payload)), response_bytes([], body), 'atomic-status')
    require(len(count) == 59 and sum(count.values()) == 354 and all(n == 6 for n in count.values()),
            f'refusal counts {count}')
    for name, n in count.items():
        print(f'COUNTS: refusal {name}={n}/6', flush=True)
    print('COUNTS: generated refusals=354/354 rules=59/59; atomic-status=1', flush=True)


def ordinary(binary, folder, name):
    configured = name in ('overrides', 'order', 'cors', 'head')
    with server(binary, folder, configured=configured) as port:
        def check(calls, body='body', method='GET'):
            equal(describe(port, calls, body, method), response_bytes(calls, body, method,
                CORS if configured else (), REGISTERED if configured else ()), name)
        if name == 'statuses':
            for status in list(PHRASES) + [299, 599, 404.0]:
                check([{'status': status}])
            # Both return-value-null and final-body semantics are asserted in /describe.
        elif name == 'types':
            check([{'headers': {'Content-Type': 'text/html; charset=utf-8'}}], '<h1>hi</h1>')
            for body in ('{json}', '[array]', '<html>', 'letter', ''):
                check([], body)
        elif name == 'redirect':
            check([{'status': 303, 'headers': {'Location': '/account'}}])
        elif name == 'overrides':
            check([{'headers': {'Cache-Control': 'no-store', 'X-Long': 'x' * 8000,
                               'X-Frame-Options': 'SAMEORIGIN'}}])
            equal(raw_request(port, '/plain'), response_bytes([], 'plain', cors_lines=CORS,
                  registered=REGISTERED), 'next request registered defaults')
        elif name == 'order':
            check([{'headers': {'X-B': '1', 'X-A': '2'}, 'cookies': ['a=1', 'b=2']},
                   {'cookies': ['c=3']}])
        elif name == 'cors':
            check([{'headers': {'Access-Control-Allow-Origin': 'https://b.example'}}])
            check([{'status': 204}])
        elif name == 'replace':
            check([{'status': 400, 'headers': {'X-A': '1'}},
                   {'status': 409, 'headers': {'x-a': '2'}}])
        elif name == 'noentity':
            for status in (204, 304):
                check([{'status': status, 'headers': {'Content-Type': 'text/html'}}], 'ignored')
            check([{'status': 204, 'headers': {'Allow': 'GET'}}])
        elif name == 'head':
            calls = [{'status': 404, 'headers': {'X-A': 'one'}, 'cookies': ['head=1']}]
            check(calls, 'payload')
            check(calls, 'payload', 'HEAD')


def limits(binary, folder):
    headers = {f'X-{i:03d}': 'x' * 491 for i in range(130)}
    require(sum(len(k) + len(v) + 4 for k, v in headers.items()) == 65000, 'limit fixture 65000')
    calls = [{'headers': headers}, {'headers': {'X-More': 'y' * 526}},
             {'headers': {'X-000': 'z' * 491}}]
    with server(binary, folder) as port:
        payload = {'calls': calls, 'refused': {'status': 404, 'headers': {'X-Over': 'v'}}, 'body': 'limit'}
        equal(raw_request(port, '/sequence', json.dumps(payload)), response_bytes(calls, 'limit'), '65536 accepted, replace, atomic limit')
        call = {'headers': {'X-Tall': 'x' * 65527}}
        require(sum(len(k) + len(v) + 4 for k, v in call['headers'].items()) == 65537,
                'overflow fixture 65537')
        equal(raw_request(port, '/sequence', json.dumps({'calls': [], 'refused': call, 'body': 'refused'})),
              response_bytes([], 'refused'), '65537 refused atomically')
        pending = [{'status': 204, 'headers': headers}]
        hidden = {'headers': {'Content-Type': 'x' * 521}}
        require(65000 + len('Content-Type') + 4 + 521 == 65537, '204 suppressed-line fixture')
        equal(raw_request(port, '/sequence', json.dumps({'calls': pending, 'refused': hidden, 'body': 'hidden'})),
              response_bytes(pending, 'hidden'), '204 still counts suppressed Content-Type')
        # A cookie line counts as "Set-Cookie: " + cookie + CR LF: 14 bytes and the cookie.
        cookies = [{'cookies': ['c%02d=' % i + 'x' * 1006 for i in range(64)]}]
        require(sum(len(c) + 14 for c in cookies[0]['cookies']) == 65536, 'cookie fixture 65536')
        equal(raw_request(port, '/sequence', json.dumps({'calls': cookies, 'refused': {'cookies': ['a']}, 'body': 'cookies'})),
              response_bytes(cookies, 'cookies'), '65536 bytes of cookies taken, one more cookie refused')
        mixed = [{'headers': headers}, {'cookies': ['m=' + 'y' * 520]}]
        require(65000 + 14 + 522 == 65536, 'mixed fixture 65536')
        equal(raw_request(port, '/sequence', json.dumps({'calls': mixed, 'refused': {'headers': {'X': ''}}, 'body': 'mixed'})),
              response_bytes(mixed, 'mixed'), 'headers and a cookie reach 65536, a 5-byte header line refused')
        lone = {'cookies': ['x' * 65523]}
        require(len(lone['cookies'][0]) + 14 == 65537, 'lone cookie fixture 65537')
        equal(raw_request(port, '/sequence', json.dumps({'calls': [], 'refused': lone, 'body': 'lone'})),
              response_bytes([], 'lone'), 'one cookie line of 65537 bytes refused')


TOKEN = set("!#$%&'*+-.^_`|~0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz")
# A string of this language cannot hold a NUL (chr of 0 raises), so the sweep starts at 1.
SWEEP_CHARS = [chr(c) for c in range(1, 128)] + ['\u0080', '\u00e9', '\u00ff', '\u754c', '\U0001f600']


def alphabet(binary, folder):
    """Every character from 0x01 to 0x7F and five beyond, at each place of a header
    name, a header value and a cookie: taken exactly when the Decision's rule takes it."""
    def value_ok(ch, place):
        return '!' <= ch <= '~' or (ch in ' \t' and place == 'middle')
    places = {'start': lambda ch: ch + 'a', 'middle': lambda ch: 'a' + ch + 'b',
              'end': lambda ch: 'a' + ch, 'alone': lambda ch: ch}
    groups = {'name': [], 'value': [], 'cookie': []}
    for ch in SWEEP_CHARS:
        code = ord(ch)
        for place, text in (('start', ch + 'X'), ('middle', 'X' + ch + 'Y'), ('end', 'X' + ch)):
            groups['name'].append(({'headers': {text: f'n{code}{place}'}}, ch in TOKEN))
        for place, build in places.items():
            text = build(ch)
            groups['value'].append(({'headers': {f'V-{code}-{place}': text}}, value_ok(ch, place)))
            groups['cookie'].append(({'cookies': [text]}, value_ok(ch, place)))
    want = {'name': (396, 231), 'value': (528, 378), 'cookie': (528, 378)}
    with server(binary, folder) as port:
        for group, cases in groups.items():
            taken = [call for call, ok in cases if ok]
            require((len(cases), len(taken)) == want[group],
                    f'{group} sweep population {len(cases)}/{len(taken)}, declared {want[group]}')
            body = ''.join('ok,' if ok else 'value,' for _, ok in cases)
            payload = json.dumps({'calls': [call for call, _ in cases]}, ensure_ascii=False)
            equal(raw_request(port, '/sweep', payload), response_bytes(taken, body), f'{group} sweep')
            print(f'COUNTS: alphabet {group}={len(cases)} calls, {len(taken)} taken', flush=True)


def many_names(binary, folder):
    """As many distinct names as the limit holds with one-byte values, set and then every
    one replaced in another spelling: by two calls, and by a call for each name. The
    response is exact, and the cost does not grow with the square of the number of names:
    seven times the names must not take thirty times as long. (Comparing every pair of
    names in one call took 77 times as long; sorting every name again on each call of
    17,058 did not answer inside the client's 15 seconds.)"""
    letters = "!#$%&'*+-.^_`|~0123456789abcdefghijklmnopqrstuvwxyz"
    def pool(limit):
        names, left = [], limit
        for size in (1, 2, 3):
            for combo in itertools.product(letters, repeat=size):
                if left < size + 5:
                    return names
                names.append(''.join(combo))
                left -= size + 5
        return names
    shapes = {
        'two calls': lambda names: [{'headers': {n: 'a' for n in names}},
                                    {'headers': {n.upper(): 'b' for n in names}}],
        'a call for each name': lambda names: ([{'headers': {n: 'a'}} for n in names] +
                                               [{'headers': {n.upper(): 'b'}} for n in names]),
    }
    big, small = pool(65536), pool(65536 // 8)
    require((len(big), len(small)) == (8529, 1177), f'name populations {len(big)}/{len(small)}')
    with server(binary, folder) as port:
        def best_of_three(calls, label):
            want, best = response_bytes(calls, 'many'), None
            for _ in range(3):
                start = time.monotonic()
                actual = describe(port, calls, 'many')
                spent = time.monotonic() - start
                equal(actual, want, label)
                best = spent if best is None else min(best, spent)
            return best
        for shape, build in shapes.items():
            t_small = best_of_three(build(small), f'{len(small)} names, {shape}')
            t_big = best_of_three(build(big), f'{len(big)} names, {shape}')
            ratio = t_big / max(t_small, 1e-4)
            require(ratio < 30, f'{shape}: {len(big)} names took {t_big:.3f}s and {len(small)} names '
                                f'{t_small:.3f}s: ratio {ratio:.1f}, declared under 30')
            print(f'COUNTS: many names, {shape}: {len(big)} set and {len(big)} replaced; {t_big:.3f}s '
                  f'against {t_small:.3f}s for {len(small)}, ratio {ratio:.1f}', flush=True)


def exceptional(binary, folder, name):
    if name == 'raise':
        source = 'http_respond of {"status": 409, "headers": {"X-Must-Disappear": "x"}, "cookies": ["must=disappear"]}\nthrow of "failed"'
        with server(binary, folder, route('/raise', source)) as port:
            expected = response_bytes([{'status': 500}], '{"error": "internal error"}')
            equal(raw_request(port, '/raise'), expected, 'raise clears all response state')
            equal(raw_request(port, '/plain'), response_bytes([], 'plain'), 'after raise')
    elif name == 'exit':
        with server(binary, folder, route('/exit', 'http_respond of {"status": 404}\nexit of 0')) as port:
            actual = raw_request(port, '/exit')
            # Exit's body is whatever the existing route evaluator's final value is.
            head, body = actual.split(b'\r\n\r\n', 1)
            require(head.startswith(b'HTTP/1.1 404 Not Found\r\n'), f'exit status: {actual!r}')
            equal(actual, response_bytes([{'status': 404}], body.decode()), 'exit response')
            equal(raw_request(port, '/plain'), response_bytes([], 'plain'), 'after exit')
    elif name == 'auth':
        auth = 'http_respond of {"status": 403, "headers": {"X-Auth": "1"}, "cookies": ["auth=1"]}\nhttp_request_body of null'
        setup = 'shared_set of ["require_auth", ' + eigs_string(auth) + ']\n"setup"'
        extra = route('/setup', setup) + route('/authed', '"plain"', True)
        extra += route('/own', 'http_respond of {"status": 404}\n"own"', True)
        with server(binary, folder, extra) as port:
            equal(raw_request(port, '/setup'), response_bytes([], 'setup'), 'auth setup')
            equal(raw_request(port, '/authed', 'denied'), response_bytes([{'status': 401, 'headers': {'Content-Type': 'application/json'}}], 'denied'), 'auth refusal')
            equal(raw_request(port, '/authed'), response_bytes([], 'plain'), 'auth allowed clears state')
            equal(raw_request(port, '/own'), response_bytes([{'status': 404}], 'own'), 'route after auth applies')
    elif name == 'context':
        out = main_program(binary, folder, '''try:
    http_respond of {"status": 404}
catch e:
    print of (json_encode of [e.kind, e.message])
''')
        require(json.loads(out) == ['value', NO_REQUEST], f'main context refusal {out!r}')
        source = '''define child() as:
    http_respond of {"status": 404}
caught is false
try:
    thread_join of (spawn of child)
catch e:
    assert of [e.kind == "value", "child error kind"]
    assert of [e.message == "http_respond: no request is being answered", "child error message"]
    caught is true
assert of [caught, "spawned thread must refuse"]
"plain"'''
        task = '''define later() as:
    http_respond of {"status": 404}
task_spawn of later
"task"'''
        with server(binary, folder / 'serve', route('/thread', source) + route('/task', task)) as port:
            equal(raw_request(port, '/thread'), response_bytes([], 'plain'), 'spawned thread context')
            equal(raw_request(port, '/task'), response_bytes([{'status': 404}], 'task'), 'task runs after route final statement')
    elif name == 'concurrency':
        source = '''n is json_decode of (http_request_body of null)
http_respond of {"status": n, "cookies": [f"request={n}"]}
"parallel"'''
        extra = route('/parallel', source)
        with server(binary, folder, extra) as port:
            barrier = threading.Barrier(16)
            def concurrent(status):
                barrier.wait(timeout=15)
                equal(raw_request(port, '/parallel', str(status)), response_bytes(
                    [{'status': status, 'cookies': [f'request={status}']}], 'parallel'), f'parallel {status}')
            with ThreadPoolExecutor(max_workers=16) as pool:
                list(pool.map(concurrent, range(400, 416)))
            equal(describe(port, [{'status': 404}], 'first'), response_bytes([{'status': 404}], 'first'), 'sequential first')
            equal(raw_request(port, '/plain'), response_bytes([], 'plain'), 'sequential second')
    elif name == 'liberror':
        source = 'load_file of "lib/http.eigs"\nerror_response of [404, "gone"]'
        expected_body = '{"error": "gone", "code": 404}'
        out = main_program(binary, folder, source.replace('error_response of [404, "gone"]', 'print of (error_response of [404, "gone"])'))
        require(out == expected_body + '\n', f'error_response main {out!r}')
        with server(binary, folder / 'serve', route('/liberror', source)) as port:
            equal(raw_request(port, '/liberror'), response_bytes([], expected_body), 'error_response leaves status 200')
    elif name == 'sandbox':
        source = '''r is sandbox_run of ["return http_respond of {}", 10000, 2000000, 10000]
assert of [r.ok == false, "sandbox allowed HTTP capability"]
assert of [r.error.kind == "sandbox", "sandbox error kind"]
"sandbox"'''
        with server(binary, folder, route('/sandbox', source)) as port:
            equal(raw_request(port, '/sandbox'), response_bytes([], 'sandbox'), 'sandbox refuses http_respond')


def tape(binary, folder):
    source = '''http_respond of {"status": 404, "headers": {"X-Tape": "yes"}, "cookies": ["tape=1"]}
request_marker is http_request_body of null
pad is 0
loop while pad < 400:
    filler is "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"
    pad is pad + 1
request_marker'''
    with server(binary, folder, route('/tape', source), trace=True) as port:
        for i in range(3):
            body = f'tape-request-{i}'
            equal(raw_request(port, '/tape', body), response_bytes([{'status': 404,
                'headers': {'X-Tape': 'yes'}, 'cookies': ['tape=1']}], body), f'tape request {i}')
        data = (folder / 'trace.tape').read_text()
        records = [line for line in data.splitlines() if ' http_request_body=' in line]
        require(len(records) == 3, f'http_request_body tape records={len(records)}, want 3')
        for i in range(3):
            require(any(f'tape-request-{i}' in line for line in records), f'missing taped body {i}')
        require(' http_respond=' not in data, 'http_respond wrote a nondeterministic tape record')
    print('COUNTS: tape request_body=3/3 http_respond=0/0', flush=True)


def docs_api(binary, folder):
    result = subprocess.run([binary, '--api'], cwd=ROOT, capture_output=True, text=True, timeout=15)
    clean(result.stdout + result.stderr)
    require(result.returncode == 0 and not result.stderr, f'api rc={result.returncode}: {result.stderr}')
    require(any('http_respond' in line for line in result.stdout.splitlines()), '--api omits http_respond')
    for path in ('docs/BUILTINS.md', 'docs/STDLIB.md', 'docs/TRACE.md'):
        require('http_respond' in (ROOT / path).read_text(), f'{path} omits http_respond')


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--binary', default=str(ROOT / 'src/eigenscript'))
    parser.add_argument('--row', action='append', help='run only this named row (repeatable)')
    parser.add_argument('--scratch', help='keep fixtures/logs in this directory')
    args = parser.parse_args()
    binary = str(Path(args.binary).resolve())
    rows = [('HR01-generated', generated), ('HR02-statuses', lambda b, p: ordinary(b,p,'statuses')),
            ('HR03-types', lambda b, p: ordinary(b,p,'types')), ('HR04-redirect', lambda b,p: ordinary(b,p,'redirect')),
            ('HR05-overrides', lambda b,p: ordinary(b,p,'overrides')), ('HR06-order', lambda b,p: ordinary(b,p,'order')),
            ('HR07-cors', lambda b,p: ordinary(b,p,'cors')), ('HR08-replace', lambda b,p: ordinary(b,p,'replace')),
            ('HR09-noentity', lambda b,p: ordinary(b,p,'noentity')), ('HR10-head', lambda b,p: ordinary(b,p,'head')),
            ('HR11-raise', lambda b,p: exceptional(b,p,'raise')), ('HR12-exit', lambda b,p: exceptional(b,p,'exit')),
            ('HR13-auth', lambda b,p: exceptional(b,p,'auth')), ('HR14-refusals', refusals), ('HR15-limit', limits),
            ('HR16-context', lambda b,p: exceptional(b,p,'context')),
            ('HR17-concurrency', lambda b,p: exceptional(b,p,'concurrency')),
            ('HR18-liberror', lambda b,p: exceptional(b,p,'liberror')),
            ('HR19-sandbox', lambda b,p: exceptional(b,p,'sandbox')),
            ('HR20-tape', tape), ('HR21-docs-api', docs_api), ('HR22-alphabet', alphabet),
            ('HR23-many-names', many_names)]
    if args.row:
        selected = set(args.row)
        require(selected <= {name for name, _ in rows}, f'unknown rows {selected - {name for name, _ in rows}}')
        rows = [(name, fn) for name, fn in rows if name in selected]
    print(f'HTTP_RESPOND seed={SEED} rows={len(rows)}', flush=True)
    def run(folder):
        passed = failed = 0
        for name, fn in rows:
            path = folder / name
            path.mkdir(parents=True, exist_ok=True)
            try:
                fn(binary, path)
            except Exception as exc:
                failed += 1
                print(f'FAIL: {name}: {exc}', flush=True)
            else:
                passed += 1
                print(f'PASS: {name}', flush=True)
        require(passed + failed == len(rows), 'named row accounting')
        print(f'HTTP_RESPOND: {passed} passed, {failed} failed', flush=True)
        return int(failed != 0)
    if args.scratch:
        return run(Path(args.scratch))
    with tempfile.TemporaryDirectory(prefix='eigs-http-respond-') as directory:
        return run(Path(directory))


if __name__ == '__main__':
    raise SystemExit(main())
