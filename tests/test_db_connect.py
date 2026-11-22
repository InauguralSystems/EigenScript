"""DATABASE_URL contract (#2355). libpq itself supplies the parser/error oracle.

Live rows need DATABASE_URL and never silently skip an unreachable configured DB.
Each interpreter connects once; connection replacement is a separate issue.
"""
import ctypes as C
import ctypes.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import shlex
from urllib.parse import quote

ROOT = Path(__file__).resolve().parents[1]
EIGS = str(Path(sys.argv[1]).resolve()) if len(sys.argv) > 1 else str(ROOT / 'src/eigenscript')
PASS = FAIL = SKIP = 0
pq = C.CDLL(ctypes.util.find_library('pq'))


class Option(C.Structure):
    _fields_ = [(name, C.c_char_p) for name in
                ['keyword', 'envvar', 'compiled', 'val', 'label', 'dispchar']] + [('dispsize', C.c_int)]


pq.PQconninfoParse.argtypes = [C.c_char_p, C.POINTER(C.c_void_p)]
pq.PQconninfoParse.restype = C.POINTER(Option)
pq.PQconninfoFree.argtypes = [C.POINTER(Option)]
pq.PQfreemem.argtypes = [C.c_void_p]
pq.PQconnectdb.argtypes = [C.c_char_p]
pq.PQconnectdb.restype = C.c_void_p
pq.PQerrorMessage.argtypes = [C.c_void_p]
pq.PQerrorMessage.restype = C.c_char_p
pq.PQstatus.argtypes = [C.c_void_p]
pq.PQfinish.argtypes = [C.c_void_p]


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


def parse(url):
    error = C.c_void_p()
    options = pq.PQconninfoParse(url.encode(), C.byref(error))
    if not options:
        try:
            return None, C.string_at(error).decode()
        finally:
            pq.PQfreemem(error)
    try:
        values = {}
        i = 0
        while options[i].keyword:
            if options[i].val is not None:
                values[options[i].keyword.decode()] = options[i].val.decode()
            i += 1
        return values, None
    finally:
        pq.PQconninfoFree(options)


def keyword(values):
    def escape(value):
        return "'" + value.replace('\\', '\\\\').replace("'", "\\'") + "'"
    return ' '.join(key + '=' + escape(value) for key, value in values.items())


def uri(values):
    # Query parameters also support Unix socket directories and quoted values.
    return 'postgresql:///?' + '&'.join(quote(k, safe='') + '=' + quote(v, safe='')
                                      for k, v in values.items())


def runtime(url, query=None, extra_env=None):
    with tempfile.TemporaryDirectory(prefix='db-connect-') as directory:
        path = Path(directory) / 'case.eigs'
        path.write_text('print of (db_connect of null)\n' +
            (f'print of (json_encode of (db_query_value of {json.dumps(query)}))\n' if query else ''))
        env = dict(os.environ, DATABASE_URL=url)
        env.update(extra_env or {})
        lint = subprocess.run([EIGS, '--lint', '--json', str(path)], env=env,
                              capture_output=True, text=True, timeout=10)
        require(lint.returncode == 0 and lint.stdout.strip() == '[]' and not lint.stderr,
                f'lint: {lint.stdout}{lint.stderr}')
        result = subprocess.run([EIGS, str(path)], env=env,
                                capture_output=True, text=True, timeout=15)
        require(result.returncode == 0 and not result.stderr,
                f'rc={result.returncode}: {result.stdout}{result.stderr}')
        return [json.loads(line) for line in result.stdout.splitlines()]


def connected(url, app=None):
    rows = runtime(url, "SELECT current_setting('application_name')" if app else 'SELECT 2355')
    require(rows == [{'status': 'connected', 'driver': 'libpq'}, app if app else 2355],
            f'got {rows!r}')


def refused():
    _, error = parse('app')
    rows = runtime('app')
    require(rows == [{'status': 'error', 'error': error}], f'got {rows!r}, want libpq error {error!r}')


row('DB2355-refused', refused)
url = os.environ.get('DATABASE_URL')
names = ['uri', 'keyword', 'uri-timeout', 'keyword-timeout', 'uri-long', 'keyword-long', 'default-timeout']
if not url:
    for name in names:
        print(f'SKIP: DB2355-{name}: DATABASE_URL is not set', flush=True)
        SKIP += 1
else:
    values, error = parse(url)
    require(values is not None, f'configured DATABASE_URL refused: {error}')
    values.pop('connect_timeout', None)
    def default_timeout():
        # Observe the production call, then delegate to the real libpq/server.
        # No permanent mutation train: calibration is recorded when this row changes.
        with tempfile.TemporaryDirectory(prefix='db-connect-trace-') as directory:
            directory = Path(directory)
            library = directory / 'trace.so'
            flags = (ROOT / 'tools/werror_flags.txt').read_text().split()
            command = shlex.split(os.environ.get('CC', 'cc')) + [
                '-Wall', '-Wextra', '-Werror=implicit-function-declaration',
                '-I/usr/include/postgresql'] + flags
            if sys.platform == 'darwin':
                command += ['-dynamiclib', '-undefined', 'dynamic_lookup']
                variable = 'DYLD_INSERT_LIBRARIES'
            else:
                command += ['-shared', '-fPIC']
                variable = 'LD_PRELOAD'
            command += [str(ROOT / 'tests/db_connect_trace.c'), '-o', str(library)]
            if sys.platform != 'darwin':
                command += ['-ldl']
            built = subprocess.run(command, capture_output=True, text=True, timeout=30)
            require(built.returncode == 0 and not built.stderr, f'trace build: {built.stdout}{built.stderr}')
            trace = directory / 'params'
            preload = str(library) + (':' + os.environ[variable] if os.environ.get(variable) else '')
            extra = {variable: preload, 'EIGS_DB_CONNECT_TRACE': str(trace)}
            if sys.platform == 'darwin':
                extra['DYLD_FORCE_FLAT_NAMESPACE'] = '1'
            for encode in [uri, keyword]:
                for supplied in [None, '7', '']:
                    trace.unlink(missing_ok=True)
                    params = dict(values)
                    if supplied is not None:
                        params['connect_timeout'] = supplied
                    result = runtime(encode(params), extra_env=extra)
                    require(result == [{'status': 'connected', 'driver': 'libpq'}], f'got {result!r}')
                    actual = trace.read_text() if trace.exists() else '<no PQconnectdbParams call>'
                    wanted = '3' if supplied is None else supplied
                    require(actual == f'timeout={wanted}\ncount=1 expand_dbname=0\n',
                            f'{encode.__name__} supplied={supplied!r}: got {actual!r}')
    row('DB2355-default-timeout', default_timeout)
    for encoder, name in [(uri, 'uri'), (keyword, 'keyword')]:
        row('DB2355-' + name, lambda e=encoder: connected(e(values)))

        def timeout_kept(encode=encoder):
            # Valid caller timeout connects. An invalid sentinel then witnesses the
            # exact supplied value at libpq, without depending on wall-clock timing.
            connected(encode(dict(values, connect_timeout='7')))
            bad_url = encode(dict(values, connect_timeout='eigs-timeout-2355'))
            conn = pq.PQconnectdb(bad_url.encode())
            require(conn, 'libpq allocation failed')
            try:
                require(pq.PQstatus(conn) != 0, 'sentinel unexpectedly accepted by libpq')
                error = pq.PQerrorMessage(conn).decode()
            finally:
                pq.PQfinish(conn)
            require('eigs-timeout-2355' in error and 'connect_timeout' in error,
                    f'libpq did not reach timeout validation: {error}')
            actual = runtime(bad_url)
            require(actual == [{'status': 'error', 'error': error}], f'got {actual!r}, want {error!r}')
        row('DB2355-' + name + '-timeout', timeout_kept)

        def long_string(encode=encoder):
            # A final override must survive beyond the old 4096-byte buffer.
            base = encode(dict(values, application_name='x' * 4200))
            suffix = '&application_name=serving-small-2355' if encode == uri else " application_name='serving-small-2355'"
            connected(base + suffix, 'serving-small-2355')
        row('DB2355-' + name + '-long', long_string)

print(f'DB_CONNECT: {PASS} passed, {FAIL} failed, {SKIP} skipped', flush=True)
sys.exit(1 if FAIL else 0)
