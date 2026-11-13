"""Live static-prefix contract (#2356/#2357); optional binary argument for baseline runs."""
import contextlib
import http.client
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time

from http_readiness import pick_port

ROOT = Path(__file__).resolve().parents[1]
EIGS = str(Path(sys.argv[1]).resolve()) if len(sys.argv) > 1 else str(ROOT / 'src/eigenscript')
PASS = FAIL = 0


def require(ok, detail):
    if not ok:
        raise AssertionError(detail)


def row(name, work):
    global PASS, FAIL
    try:
        work()
    except Exception as exc:
        FAIL += 1
        print(f'FAIL: {name}: {exc}', flush=True)
    else:
        PASS += 1
        print(f'PASS: {name}', flush=True)


def clean(text):
    # Use the suite's classifier, including diagnostics at exit zero.
    result = subprocess.run(['bash', '-c',
        'source "$1"; lsan_classify "$(cat)"; test "$?" = 2',
        'classify', str(ROOT / 'tests/lsan_classify.sh')],
        input=text, text=True, capture_output=True, check=False)
    require(result.returncode == 0, f'sanitizer diagnostic: {text}')


def program(folder, source):
    path = folder / 'case.eigs'
    path.write_text(source)
    lint = subprocess.run([EIGS, '--lint', '--json', str(path)],
                          capture_output=True, text=True, timeout=10)
    require(lint.returncode == 0 and lint.stdout.strip() == '[]' and not lint.stderr,
            f'lint rc={lint.returncode}: {lint.stdout}{lint.stderr}')
    return path


def registration(prefix):
    return f'http_static of [{json.dumps(prefix)}, "{FILES}"]\n'


def request(port, path):
    conn = http.client.HTTPConnection('127.0.0.1', port, timeout=2)
    try:
        conn.request('GET', path)
        response = conn.getresponse()
        return response.status, response.read().decode()
    finally:
        conn.close()


@contextlib.contextmanager
def server(source):
    port = pick_port()  # below the ephemeral range, bind-probed (#760)
    with tempfile.TemporaryDirectory(prefix='static-case-') as directory:
        folder = Path(directory)
        path = program(folder, source +
            'http_route of ["GET", "/ready", "ready-2356"]\n' +
            f'http_serve of {port}\n')
        with (folder / 'server.log').open('w+') as log:
            proc = subprocess.Popen([EIGS, str(path)], stdout=log, stderr=log)
            try:
                deadline = time.monotonic() + 10
                while time.monotonic() < deadline and proc.poll() is None:
                    try:
                        if request(port, '/ready') == (200, 'ready-2356'):
                            break
                    except OSError:
                        pass
                    time.sleep(.05)
                else:
                    raise AssertionError(f'server not ready, rc={proc.poll()}')
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
                require(proc.returncode in (0, -signal.SIGTERM),
                        f'server rc={proc.returncode}: {output}')


def fetch(source, cases):
    with server(source) as port:
        for path, expected in cases:
            actual = request(port, path)
            require(actual == expected, f'{path}: got {actual!r}, want {expected!r}')


def refusal(source, kind, message, before=''):
    with tempfile.TemporaryDirectory(prefix='static-refusal-') as directory:
        path = program(Path(directory), before + 'try:\n' +
            ''.join('    ' + line + '\n' for line in source.splitlines()) +
            '    print of "REGISTERED"\ncatch e:\n'
            '    print of (json_encode of [e.kind, e.message])\n')
        result = subprocess.run([EIGS, str(path)], capture_output=True, text=True, timeout=10)
        clean(result.stdout + result.stderr)
        expected = json.dumps([kind, message], separators=(',', ':'))
        require(result.returncode == 0 and not result.stderr and
                result.stdout.strip().startswith('['),
                f'rc={result.returncode} output={result.stdout!r} stderr={result.stderr!r}; '
                f'want {expected}')
        require(json.loads(result.stdout) == json.loads(expected),
                f'got {result.stdout!r}, want {expected}')


with tempfile.TemporaryDirectory(prefix='static-prefixes-') as directory:
    FILES = Path(directory) / 'one'
    OTHER = Path(directory) / 'two'
    FILES.mkdir()
    OTHER.mkdir()
    (FILES / 'a.txt').write_text('first')
    (OTHER / 'a.txt').write_text('second')
    (FILES / 'img').mkdir()
    (FILES / 'img/a.txt').write_text('wrong-parent')
    (FILES / 'img/parent.txt').write_text('no-fallback')
    (Path(directory) / 'secret').write_text('outside')
    (FILES / 'escape').symlink_to(Path(directory) / 'secret')
    (OTHER / 'escape').symlink_to(Path(directory) / 'secret')
    for prefix, name in [('/s1', 'plain'), ('/s1/', 'trailing'), ('/s1///', 'many-trailing')]:
        row('SP2356-' + name, lambda p=prefix: fetch(registration(p), [('/s1/a.txt', (200, 'first'))]))
    for prefix, name, message in [
        ('', 'empty', 'http_static: prefix must not be empty'),
        ('/', 'root', 'http_static: prefix must name a path segment (not only slashes)'),
        ('///', 'slashes', 'http_static: prefix must name a path segment (not only slashes)'),
        ('s1', 'relative', "http_static: prefix must begin with '/'")]:
        row('SP2356-' + name, lambda p=prefix, m=message: refusal(registration(p), 'value', m))
    two = registration('/s1') + f'http_static of ["/s2", "{OTHER}"]\n'
    row('SP2357-two', lambda: fetch(two, [('/s1/a.txt', (200, 'first')), ('/s2/a.txt', (200, 'second'))]))
    parent = registration('/assets')
    child = f'http_static of ["/assets/img", "{OTHER}"]\n'
    for source, name in [(parent + child, 'nested'), (child + parent, 'nested-reversed')]:
        row('SP2357-' + name, lambda s=source: fetch(s, [('/assets/a.txt', (200, 'first')),
            ('/assets/img/a.txt', (200, 'second')), ('/assets/img/parent.txt', (404, '{"error": "not_found"}'))]))
    for first, second, name in [('/dup', '/dup', 'duplicate'), ('/dup/', '/dup///', 'normalized-duplicate')]:
        row('SP2357-' + name, lambda a=first, b=second: refusal(registration(b), 'value',
            'http_static: prefix already registered: /dup', registration(a)))
    sixteen = ''.join(registration('/p' + str(i)) for i in range(16))
    row('SP2357-sixteen', lambda: fetch(sixteen,
        [(f'/p{i}/a.txt', (200, 'first')) for i in range(16)]))
    row('SP2357-seventeenth', lambda: refusal(registration('/p16'), 'limit',
        'http_static: prefix table full (max 16 prefixes)', sixteen))
    # Confinement, missing files, segment boundaries and the freeze apply to BOTH roots.
    def safety():
        with server(two + 'http_route of ["GET", "/s1x/a.txt", "route"]\n' +
                    'http_route of ["GET", "/s2x/a.txt", "route"]\n' +
                    'http_route of ["GET", "/frozen", "code", '
                    '"try:\\n    http_static of [\\\"/late\\\", \\\".\\\"]\\ncatch e:\\n    return e.kind"]\n') as port:
            for prefix in ['/s1', '/s2']:
                for suffix, status in [('/escape', 403), ('/../secret', 403), ('//a.txt', 403), ('/missing', 404)]:
                    actual = request(port, prefix + suffix)
                    require(actual[0] == status, f'{prefix + suffix}: {actual!r}')
                require(request(port, prefix + 'x/a.txt') == (200, 'route'), 'segment boundary')
            require(request(port, '/frozen') == (200, 'value'), 'registration must stay frozen')
            require(request(port, '/s1/a.txt') == (200, 'first'), 'refusal changed table')
    row('SP2357-safety', safety)

print(f'STATIC_PREFIXES: {PASS} passed, {FAIL} failed', flush=True)
sys.exit(1 if FAIL else 0)
