#!/usr/bin/env python3
"""#2375 outbound exchange: independent byte references and raw-peer comparisons.

The references below were written from BAR.md before the client C. They do not
import runtime code or derive expected values from the candidate. --row selects
rows for the one-time source plants; plants are not a permanent self-test.
"""
import argparse
from collections import Counter
from concurrent.futures import ThreadPoolExecutor
import contextlib
import hashlib
import json
import math
import os
from pathlib import Path
import random
import re
import shutil
import signal
import socket
import statistics
import subprocess
import sys
import tempfile
import threading
import time

from http_readiness import pick_port

ROOT = Path(__file__).resolve().parents[1]
SEED = 2375
TOKEN = b"!#$%&'*+-.^_`|~0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"
AUTHORITY = b"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-_:[]"
METHODS = ('GET', 'HEAD', 'POST', 'PUT', 'PATCH', 'DELETE')
HEADER_LIMIT = 65536
HEADER_LINE_LIMIT = 4096
DEFAULT_BODY_LIMIT = 16777216
CONNECTION_WRITTEN = ('Connection', 'Keep-Alive', 'Proxy-Connection', 'TE', 'Upgrade')
CONNECTION_NAMES = tuple(name.lower().encode() for name in CONNECTION_WRITTEN)
# The names the library's HTTP source looks for in a caller's headers (8.14.1
# and 8.18.0), less the refused ones and Host, User-Agent and Accept.
THIRTEEN = ('Accept-Encoding', 'Alt-Used', 'Authorization', 'Content-Range', 'Content-Type', 'Cookie', 'Date',
            'If-Modified-Since', 'If-Unmodified-Since', 'Last-Modified', 'Proxy-Authorization', 'Range', 'Referer')
ID_NAMES = tuple(name + '-Id' for name in ('Content-Length', 'Transfer-Encoding', 'Expect') + CONNECTION_WRITTEN)
OTHER_NAMES = ('X-Connection', 'Trailer', 'Via', 'Origin', 'Sec-X')
RUNTIME_TMP = None


class Refusal(Exception):
    def __init__(self, kind, message=None):
        self.kind, self.message = kind, message
        super().__init__(kind + (': ' + message if message else ''))


def request_reference(argument, version):
    """Decision/The request and What is sent, independent of curl and C.

    Return the request line, unordered lines, caller order and byte body. Only
    argument refusals have no exact message: the contract requires a prefix and
    the broken rule, while transport errors below have fixed whole messages.
    """
    if not isinstance(argument, dict):
        raise Refusal('type_mismatch')
    if set(argument) - {'url', 'method', 'headers', 'body', 'timeout'}:
        raise Refusal('value')
    if 'url' not in argument:
        raise Refusal('value')
    for key in ('url', 'method', 'body'):
        if key in argument and not isinstance(argument[key], str):
            raise Refusal('type_mismatch')
    headers = argument.get('headers', {})
    if not isinstance(headers, dict):
        raise Refusal('type_mismatch')
    if any(not isinstance(v, str) for v in headers.values()):
        raise Refusal('type_mismatch')
    limit = argument.get('timeout', 15)
    if type(limit) not in (int, float):
        raise Refusal('type_mismatch')
    if not math.isfinite(limit) or not .001 <= limit <= 300:
        raise Refusal('value')
    url = argument['url'].encode('latin1')
    prefix = 7 if url.startswith(b'http://') else 8 if url.startswith(b'https://') else 0
    if not prefix or any(c < 0x21 or c > 0x7e for c in url):
        raise Refusal('value')
    endpoint = min((url.find(c, prefix) for c in (b'/', b'?', b'#') if c in url[prefix:]), default=len(url))
    authority = url[prefix:endpoint]
    if not authority or any(c not in AUTHORITY for c in authority):
        raise Refusal('value')
    method = argument.get('method', 'GET')
    if method not in METHODS:
        raise Refusal('value')
    body = argument.get('body', '').encode('latin1')
    if method in ('GET', 'HEAD') and body:
        raise Refusal('value')
    names, caller, size = set(), [], 0
    for key, value in headers.items():
        key, value = key.encode('latin1'), value.encode('latin1')
        lower = key.lower()
        if not 1 <= len(key) <= 64 or any(c not in TOKEN for c in key):
            raise Refusal('value')
        if lower in names or lower in (b'content-length', b'transfer-encoding', b'expect'):
            raise Refusal('value')
        # The connection is the runtime's: these five raise as well.
        if lower in CONNECTION_NAMES:
            raise Refusal('value')
        if any(c not in (9, 32) and not 0x21 <= c <= 0x7e for c in value):
            raise Refusal('value')
        if value[:1] in (b' ', b'\t') or value[-1:] in (b' ', b'\t'):
            raise Refusal('value')
        names.add(lower)
        caller.append((key, value))
        size += len(key) + len(value) + 4
    if size > HEADER_LIMIT:
        raise Refusal('limit')
    target = url[endpoint:].split(b'#', 1)[0]
    if not target.startswith(b'/'):
        target = b'/' + target
    host = next(((k, v) for k, v in caller if k.lower() == b'host'), (b'Host', authority))
    lines = [host] + [(k, v) for k, v in caller if k.lower() != b'host']
    if b'user-agent' not in names:
        lines.append((b'User-Agent', b'EigenScript/' + version.encode('ascii')))
    if b'accept' not in names:
        lines.append((b'Accept', b'*/*'))
    if method in ('POST', 'PUT', 'PATCH') or (method == 'DELETE' and body):
        lines.append((b'Content-Length', str(len(body)).encode()))
    # Exactly once in every request; its place is the library's, so the
    # comparison below takes the lines as a multiset.
    lines.append((b'Connection', b'close'))
    return {'line': method.encode() + b' ' + target + b' HTTP/1.1',
            'headers': lines, 'caller': [(k, v) for k, v in caller if k.lower() != b'host'],
            'body': body, 'header_bytes': size}


def answer_reference(wire, method='GET', body_limit=DEFAULT_BODY_LIMIT, reset=False):
    """Decision/The answer, Errors and Limits, from peer bytes alone.

    Count complete header lines, including interim lines and trailers. A NUL
    body refusal is last: completeness and both byte limits have precedence.
    Unknown malformed-HTTP combinations have no fixed oracle and are not dealt.
    """
    def fail(kind, suffix):
        raise Refusal(kind, 'http_fetch: ' + suffix)
    def early():
        fail('io', 'the answer ended early')
    def body_over():
        fail('limit', f"the answer's body is longer than {body_limit} bytes (EIGS_HTTP_FETCH_MAX_BODY)")
    def header_line(line):
        # Both header limits count every header line of the exchange (interim,
        # final, trailers); no status line, no empty line. Bytes are looked at
        # first, so a line that passes both reports bytes.
        nonlocal total, lines
        total += len(line) + 2
        lines += 1
        if total > HEADER_LIMIT:
            fail('limit', "the answer's headers are longer than 65536 bytes")
        if lines > HEADER_LINE_LIMIT:
            fail('limit', 'the answer has more than 4096 header lines')
    pos, total, lines, final_headers, status = 0, 0, 0, {}, None
    while True:
        end = wire.find(b'\r\n', pos)
        if end < 0:
            early()
        match = re.fullmatch(rb'HTTP/1\.[01] ([0-9]{3})(?: .*)?', wire[pos:end])
        if not match:
            early()
        status = int(match.group(1))
        pos = end + 2
        headers = {}
        while True:
            end = wire.find(b'\r\n', pos)
            if end < 0:
                early()
            line = wire[pos:end]
            pos = end + 2
            if not line:
                break
            if b'\0' in line:
                fail('io', 'curl failed (curl error 8)')
            header_line(line)
            name, sep, value = line.partition(b':')
            if not sep:
                raise ValueError('oracle received unspecified malformed header')
            name = name.lower().decode('latin1')
            value = value.strip(b' \t').decode('latin1')
            headers[name] = headers[name] + ', ' + value if name in headers else value
        if status == 101:
            early()
        if not 100 <= status <= 199:
            final_headers = headers
            break
    if method == 'HEAD' or status in (204, 304):
        body = b''
    elif 'chunked' in final_headers.get('transfer-encoding', '').lower():
        pieces, count = [], 0
        while True:
            end = wire.find(b'\r\n', pos)
            if end < 0:
                early()
            n = int(wire[pos:end].split(b';', 1)[0], 16)
            pos = end + 2
            if n == 0:
                while True:
                    end = wire.find(b'\r\n', pos)
                    if end < 0:
                        early()
                    line = wire[pos:end]
                    pos = end + 2
                    if not line:
                        break
                    header_line(line)
                break
            available = min(n, len(wire) - pos)
            count += available
            if count > body_limit:
                body_over()
            if available < n or wire[pos+n:pos+n+2] != b'\r\n':
                early()
            pieces.append(wire[pos:pos+n])
            pos += n + 2
        body = b''.join(pieces)
    elif 'content-length' in final_headers:
        n = int(final_headers['content-length'])
        body = wire[pos:pos+n]
        if len(body) > body_limit:
            body_over()
        if len(body) < n:
            early()
    else:
        body = wire[pos:]
        if len(body) > body_limit:
            body_over()
    if reset:
        early()
    if b'\0' in body:
        fail('io', 'the answer holds a NUL byte, which text cannot carry')
    return {'status': status, 'headers': final_headers, 'body': body}


# References end here. Harness and cases below consume them; they never revise
# them from a runtime answer.
from http_fetch_peer import Peer, Plan


class Skipped(Exception):
    pass


def require(condition, message):
    if not condition:
        raise AssertionError(message)


def equal(got, want, label):
    require(got == want, f'{label}: got {str(got)[:900]!r}; wanted {str(want)[:900]!r}')


def clean(output):
    result = subprocess.run(['bash', '-c',
        'source "$1"; lsan_classify "$(cat)"; test "$?" = 2',
        'classify', str(ROOT/'tests/lsan_classify.sh')], input=output,
        capture_output=True, check=False)
    require(result.returncode == 0, 'sanitizer diagnostic:\n' + output.decode('latin1'))


def environment(extra=None):
    env = os.environ.copy()
    for key in ('http_proxy', 'https_proxy', 'all_proxy', 'no_proxy',
                'HTTP_PROXY', 'HTTPS_PROXY', 'ALL_PROXY', 'NO_PROXY',
                'CURL_CA_BUNDLE', 'SSL_CERT_FILE', 'SSL_CERT_DIR',
                'EIGS_TRACE', 'EIGS_REPLAY', 'EIGS_HTTP_FETCH_MAX_BODY'):
        env.pop(key, None)
    # Each child has controlled library configuration; never mutate the
    # parent's environment. Runtime code must leave these variables alone.
    for key in list(env):
        if key in ('SSLKEYLOGFILE', 'HOSTALIASES', 'LOCALDOMAIN', 'RES_OPTIONS') or key.startswith(('OPENSSL_', 'GNUTLS_', 'NETTLE_', 'P11_KIT_')):
            env.pop(key, None)
    if RUNTIME_TMP is not None:
        env['TMPDIR'] = str(RUNTIME_TMP)
    env['EIGS_STRICT'] = '0'
    env.update(extra or {})
    return env


def eigs(value):
    if value is None:
        return 'null'
    if value is True:
        return 'true'
    if value is False:
        return 'false'
    if isinstance(value, str):
        # Language strings are bytes. JSON's Unicode escapes are not EigenScript
        # escapes; byte controls use chr and source bytes remain Latin-1.
        chunks, run = [], ''
        for char in value:
            if ord(char) < 32 and char not in '\r\n\t':
                if run:
                    chunks.append(json.dumps(run, ensure_ascii=False)); run = ''
                require(ord(char) != 0, 'program argument cannot carry NUL text')
                chunks.append('(chr of ' + str(ord(char)) + ')')
            else:
                run += char
        if run or not chunks:
            chunks.append(json.dumps(run, ensure_ascii=False))
        if len(chunks) > 120:
            # A long byte string is data, not hundreds of source operators.
            # JSON escapes controls; raw bytes128..255 stay literal Latin-1.
            return '(json_decode of ' + eigs(json.dumps(value,ensure_ascii=False)) + ')'
        def balanced(parts):
            if len(parts) == 1: return parts[0]
            mid = len(parts)//2
            return '(' + balanced(parts[:mid]) + ' + ' + balanced(parts[mid:]) + ')'
        return balanced(chunks)
    if isinstance(value, dict):
        if len(value) > 512:
            return '(json_decode of ' + eigs(json.dumps(value,ensure_ascii=False)) + ')'
        return '{' + ', '.join(eigs(k) + ': ' + eigs(v) for k, v in value.items()) + '}'
    if isinstance(value, list):
        return '[' + ', '.join(eigs(x) for x in value) + ']'
    if isinstance(value, float) and not math.isfinite(value):
        return '(0.0 / 0.0)' if math.isnan(value) else '(1.0 / 0.0)'
    return repr(value)


DESCRIBE = '''define fetch_describe_2375(answer) as:
    assert of [(type of answer) == "dict", "answer is a dict"]
    assert of [(len of (keys of answer)) == 3, "answer has exactly three keys"]
    assert of [(has_key of [answer, "status"]) and (has_key of [answer, "headers"]) and (has_key of [answer, "body"]), "answer keys"]
    assert of [(type of answer.headers) == "dict" and (type of answer.body) == "str", "answer field types"]
    local names is keys of answer.headers
    local vals is [answer.headers[k] for k in names]
    return ["answer", answer.status, num_type of answer.status, names, vals, len of answer.body, sha256 of answer.body]
'''


def lint_program(binary,path):
    lint = subprocess.run([binary, '--lint', '--json', '--lint-level', 'error', str(path)],
                          cwd=ROOT, env=environment(), capture_output=True, timeout=30)
    clean(lint.stdout + lint.stderr)
    require(lint.returncode == 0 and lint.stdout.strip() == b'[]' and not lint.stderr,
            f'program lint rc={lint.returncode}: {(lint.stdout+lint.stderr)[-3000:].decode("latin1")}')


def program(binary, folder, source, extra=None, timeout=30, name='call'):
    path = folder/(name + '.eigs')
    path.write_bytes(source.encode('latin1'))
    lint_program(binary,path)
    proc = subprocess.run([binary, str(path)], cwd=ROOT, env=environment(extra),
                          capture_output=True, timeout=timeout)
    clean(proc.stdout + proc.stderr)
    require(proc.returncode == 0 and not proc.stderr,
            f'program rc={proc.returncode}: {(proc.stdout+proc.stderr)[-3000:].decode("latin1")}')
    return proc.stdout


def call_source(argument, legacy=False):
    expr = ('http_post' if legacy else 'http_fetch') + ' of (' + eigs(argument) + ')'
    if legacy:
        desc = '["body", len of answer, sha256 of answer]'
    else:
        desc = 'fetch_describe_2375 of answer'
    return 'try:\n    answer is ' + expr + '\n    print of (json_encode of (' + desc + '))\ncatch problem:\n    print of (json_encode of ["error", problem.kind, problem.message])\n'


def run_calls(binary, folder, arguments, extra=None, legacy=False, timeout=30):
    source = DESCRIBE + ''.join(call_source(arg, legacy) for arg in arguments)
    output = program(binary, folder, source, extra, timeout)
    lines = [json.loads(line.decode('latin1')) for line in output.splitlines()]
    equal(len(lines), len(arguments), 'number of builtin results')
    return lines


def expect_answer(got, expected):
    headers = expected['headers']
    equal(got, ['answer', expected['status'], 'int', list(headers), list(headers.values()),
                len(expected['body']), hashlib.sha256(expected['body']).hexdigest()], 'answer reference')


def expect_error(got, kind, suffix=None, prefix='http_fetch'):
    equal(got[:2], ['error', kind], 'error kind')
    require(len(got) == 3 and got[2].startswith(prefix + ': '), f'error prefix: {got}')
    if suffix is not None:
        equal(got[2], prefix + ': ' + suffix, 'whole error message')



def check_refusal_message(got,name,argument):
    # BAR deliberately leaves argument-error wording open, but requires the
    # broken rule to be named. Accept common names; a bare/generic prefix is
    # not a diagnostic of any of the five fields or argument shape.
    if name=='unknown-key': words=('key','member','field','unknown','unexpected')
    elif name=='missing-url': words=('url','address','required','missing')
    elif name.startswith(('url-','authority-')) or name in ('userinfo','empty-authority'): words=('url','http','scheme','authority','host','credential')
    elif name.startswith('argument-'): words=('request','dict','object','mapping','argument')
    elif name.startswith('method-'): words=('method','get','head','post','put','patch','delete')
    elif name.startswith('timeout-'): words=('timeout','time limit','seconds','duration','finite','0.001','300')
    elif name.startswith('body-'): words=('body','payload','content','data','get','head')
    else: words=('header','value','field','token','ascii','framing','content-length','transfer-encoding','expect')
    text=got[2][len('http_fetch: '):].lower()
    if name.startswith('connection-'):
        # The message names the reserved names.
        for reserved in CONNECTION_WRITTEN:
            require(re.search(r'(?<![-\w])'+re.escape(reserved.lower())+r'(?![-\w])',text) is not None,f'{name}: error does not name {reserved}: {got[2]!r}')
    require(any(re.search(r'\b'+word+r'\b',text) if word in ('get','head','post','put','patch','delete') else word in text
                for word in words),f'{name}: error does not name its rule: {got[2]!r}')
    if isinstance(argument,dict):
        sensitive=[argument.get('url'),argument.get('body')]
        headers=argument.get('headers')
        if isinstance(headers,dict): sensitive.extend(headers.values())
        for value in sensitive:
            if isinstance(value,str) and len(value)>8:
                require(value not in got[2],f'{name}: diagnostic contains request data')


def check_wire(got, expected):
    equal(got['line'], expected['line'], 'request line')
    equal(Counter(got['headers']), Counter(expected['headers']), 'whole header multiset')
    # Each line exactly once: no name stands twice, in any case.
    names = Counter(k.lower() for k, _ in got['headers'])
    equal(sorted(n for n, c in names.items() if c > 1), [], 'header names that stand more than once')
    caller_names = {k.lower() for k, _ in expected['caller']}
    observed = [(k, v) for k, v in got['headers'] if k.lower() in caller_names]
    equal(observed, expected['caller'], 'caller header order and spelling')
    require(got['headers'][0][0].lower() == b'host', 'Host is not first')
    equal(got['body'], expected['body'], 'request body bytes')


def response(body=b'ok', status=200, headers=(), framing='length', interim=b'', version='1.1', reason='OK', chunks=None, trailers=()):
    lines = list(headers)
    if framing == 'length':
        lines.append((b'Content-Length', str(len(body)).encode()))
    elif framing == 'chunked':
        lines.append((b'Transfer-Encoding', b'chunked'))
    head = f'HTTP/{version} {status} {reason}\r\n'.encode()
    head += b''.join(k+b': '+v+b'\r\n' for k, v in lines) + b'\r\n'
    if framing == 'chunked':
        chunks = chunks or [len(body)]
        payload, pos = b'', 0
        for size in chunks:
            piece = body[pos:pos+size]
            if piece:
                payload += f'{len(piece):x}\r\n'.encode()+piece+b'\r\n'
            pos += size
        if pos < len(body):
            piece = body[pos:]
            payload += f'{len(piece):x}\r\n'.encode()+piece+b'\r\n'
        payload += b'0\r\n'+b''.join(k+b': '+v+b'\r\n' for k,v in trailers)+b'\r\n'
    else:
        payload = body
    return interim + head + payload


def one_request(binary, folder, argument, version, plan=None, extra=None, legacy=False):
    with Peer([plan or Plan()]) as peer:
        arg = dict(argument) if not legacy else list(argument)
        if legacy:
            arg[0] = peer.url + arg[0]
        else:
            arg['url'] = peer.url + arg.get('url', '/')
        got = run_calls(binary, folder, [arg], extra, legacy)[0]
        if legacy:
            require(got[0] == 'body', f'legacy call: {got}')
        else:
            expect_answer(got, answer_reference((plan or Plan()).wire, arg.get('method', 'GET')))
        equal(len(peer.requests), 1, 'listener request count')
        if not legacy:
            check_wire(peer.requests[0], request_reference(arg, version))
        require(not peer.errors, f'listener errors: {peer.errors}')
        return peer.requests[0], got


@contextlib.contextmanager
def runtime_server(binary, folder, code, extra=None):
    port = pick_port()
    path = folder/'server.eigs'
    path.write_bytes(('http_route of ["GET", "/call", "code", ' + eigs(code) + ']\n'
                      'http_route of ["GET", "/ready", "ready-2375"]\n'
                      f'http_serve of {port}\n').encode('latin1'))
    route_path=folder/'route.eigs'
    route_path.write_bytes(code.encode('latin1'))
    lint_program(binary,route_path)
    lint_program(binary,path)
    log = (folder/'server.log').open('w+b')
    proc = subprocess.Popen([binary, str(path)], cwd=ROOT, env=environment(extra), stdout=log, stderr=log)
    try:
        deadline = time.monotonic() + 20
        while time.monotonic() < deadline and proc.poll() is None:
            try:
                if raw_runtime(port, '/ready').endswith(b'ready-2375'):
                    break
            except OSError:
                pass
            time.sleep(.03)
        else:
            log.seek(0)
            raise AssertionError('runtime server not ready: ' + log.read().decode('latin1'))
        yield proc, port
        require(proc.poll() is None, f'runtime server exited {proc.returncode}')
    finally:
        if proc.poll() is None:
            proc.terminate()
        try:
            proc.wait(5)
        except subprocess.TimeoutExpired:
            proc.kill(); proc.wait()
        log.seek(0)
        output = log.read()
        log.close()
        clean(output)
        require(proc.returncode in (0, -signal.SIGTERM), f'server exit {proc.returncode}: {output[-2000:]}')


def raw_runtime(port, path='/call'):
    with socket.create_connection(('127.0.0.1', port), 5) as sock:
        sock.settimeout(25)
        sock.sendall(b'GET '+path.encode()+b' HTTP/1.1\r\nHost: test\r\nConnection: close\r\n\r\n')
        output = b''
        while True:
            data = sock.recv(65536)
            if not data:
                return output
            output += data


def post_sizes(binary, folder, version):
    sizes = (16383, 16384, 1000000)
    failures=[]
    compared=0
    for framing in ('length', 'chunked'):
        plans = [Plan(response(b'x'*n, framing=framing, chunks=[8191]*((n//8191)+1))) for n in sizes]
        with Peer(plans) as peer:
            got = run_calls(binary, folder, [[peer.url+'/', '{}', 'x'] for _ in sizes], legacy=True)
            for size, value in zip(sizes, got):
                want=['body',size,hashlib.sha256(b'x'*size).hexdigest()]
                if value!=want: failures.append(f'{framing} size={size} got={value} wanted={want}')
                compared+=1
            equal(len(peer.requests), len(sizes), '#2353 number requests')
    equal(compared,6,'legacy answer-size comparisons')
    require(not failures,'#2353 '+ '; '.join(failures))


def post_headers(binary, folder, version):
    failures=[]
    compared=0
    for n in (1000, 8000):
        with Peer() as peer:
            got = run_calls(binary, folder, [[peer.url+'/', json.dumps({'X-Long': 'v'*n}), 'x']], legacy=True)
            equal(got[0][0], 'body', 'post result')
            actual=[(k,v) for k,v in peer.requests[0]['headers'] if k == b'X-Long']
            if actual!=[(b'X-Long',b'v'*n)]: failures.append(f'value bytes={n} got lengths={[len(v) for k,v in actual]}')
            compared+=1
    headers = {f'X-{i:02}': f'v{i}' for i in range(40)}
    with Peer() as peer:
        run_calls(binary, folder, [[peer.url+'/', json.dumps(headers), 'x']], legacy=True)
        actual=[(k,v) for k,v in peer.requests[0]['headers'] if k.startswith(b'X-')]
        if actual!=[(k.encode(),v.encode()) for k,v in headers.items()]: failures.append(f'40 ordered headers got={actual}')
        compared+=1
    equal(compared,3,'legacy whole-header comparisons')
    require(not failures,'#2358 '+ '; '.join(failures))


def post_body(binary, folder, version):
    body = bytes(range(1,256)) + b'\r\n'
    with Peer() as peer:
        run_calls(binary, folder, [[peer.url+'/', '{}', body.decode('latin1')]], legacy=True)
        equal(hashlib.sha256(peer.requests[0]['body']).hexdigest(), hashlib.sha256(body).hexdigest(), '#2359 257-byte body sha256')


def post_closed(binary, folder, version):
    port = pick_port()
    got = run_calls(binary, folder, [[f'http://127.0.0.1:{port}/', '{}', 'x']], legacy=True)[0]
    expect_error(got, 'io', 'could not connect (curl error 7)', 'http_post')


def curlrc(binary, folder, version, legacy=False):
    config = folder/'config'; config.mkdir(exist_ok=True)
    (config/'.curlrc').write_text('header = "X-From-Curlrc: yes"\n')
    (config/'.netrc').write_text('machine 127.0.0.1 login hidden password hidden\n')
    (config/'.netrc').chmod(0o600)
    extra = {k: str(config) for k in ('HOME', 'CURL_HOME', 'XDG_CONFIG_HOME')}
    with Peer() as peer:
        arg = [peer.url+'/', '{}', 'x'] if legacy else {'url': peer.url+'/'}
        run_calls(binary, folder, [arg], extra, legacy)
        names = [k.lower() for k,v in peer.requests[0]['headers']]
        require(b'x-from-curlrc' not in names and b'authorization' not in names,
                f'curl configuration leaked into request: {names}')


def no_children(binary, folder, version, legacy=False):
    if not Path('/proc/self/task').exists():
        raise Skipped('Linux /proc is unavailable')
    with Peer([Plan(delay=2), Plan(delay=2)]) as peer:
        arg = [peer.url+'/', '{"Authorization":"marker-2375"}', 'x'] if legacy else {
            'url': peer.url+'/', 'headers': {'Authorization': 'marker-2375'}}
        code = ('http_post' if legacy else 'http_fetch') + ' of (' + eigs(arg) + ')\n"done"'
        with runtime_server(binary, folder, code) as (proc, port):
            with ThreadPoolExecutor(max_workers=2) as pool:
                calls = [pool.submit(raw_runtime, port) for _ in range(2)]
                deadline = time.monotonic()+4
                while len(peer.requests) != 2 and time.monotonic()<deadline:
                    time.sleep(.01)
                equal(len(peer.requests), 2, 'two held calls')
                require(all(not future.done() for future in calls),'calls completed before child inspection')
                pids = set()
                for task in Path(f'/proc/{proc.pid}/task').iterdir():
                    pids.update((task/'children').read_text().split())
                require(not pids, f'#2354 child process(es): {sorted(pids)}')
                for future in calls:
                    require(future.result().endswith(b'done'), 'held call body')


def baseline_cost(binary, folder, version):
    with Peer([Plan(response(b'x'*100))], repeat=True) as peer:
        source = 'times is []\ni is 0\nloop while i < 200:\n'
        source += '    started is monotonic_ns of null\n    answer is http_post of [' + eigs(peer.url+'/') + ', "{}", "x"]\n'
        source += '    append of [times, (monotonic_ns of null) - started]\n    assert of [(len of answer) == 100, "post 100-byte cost answer"]\n    i is i + 1\nprint of (json_encode of times)\n'
        times = json.loads(program(binary, folder, source).decode())
        equal(len(times), 200, '200-call cost count')
        equal(len(peer.requests), 200, '200-call cost requests')
        print(f'COST post200x100 median_ns={statistics.median(times)} min_ns={min(times)} max_ns={max(times)} count=200', flush=True)


BASE_ROWS = [
    ('POST-2353-answer-sizes', post_sizes),
    ('POST-2358-header-sizes-order', post_headers),
    ('POST-2359-body-bytes', post_body),
    ('POST-closed-port', post_closed),
    ('POST-curlrc', lambda *a: curlrc(*a, legacy=True)),
    ('POST-2354-no-child', lambda *a: no_children(*a, legacy=True)),
    ('POST-cost200x100', baseline_cost),
]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--binary', default=str(ROOT/'src/eigenscript'))
    parser.add_argument('--row', action='append', default=[])
    parser.add_argument('--base', action='store_true')
    parser.add_argument('--leak', action='store_true')
    parser.add_argument('--list', action='store_true')
    args = parser.parse_args()
    binary = str(Path(args.binary).resolve())
    version = subprocess.check_output([binary, '--version'],env=environment()).decode().strip()
    print(f'HTTP_FETCH seed={SEED} arrives_seed={SEED} refused_seed={SEED+1} answers_seed={SEED+2} binary={binary} version={version}', flush=True)
    rows = BASE_ROWS if args.base else LEAK_ROWS if args.leak else ROWS
    if args.list:
        print('\n'.join(name for name, _ in rows))
        return 0
    selected = [(name, fn) for name, fn in rows if not args.row or any(re.search(p, name) for p in args.row)]
    require(bool(selected), 'empty selected row population')
    passed = failed = skipped = 0
    with tempfile.TemporaryDirectory(prefix='eigs-fetch-') as tmp:
        root = Path(tmp)
        global RUNTIME_TMP
        RUNTIME_TMP = root/'runtime-tmp'
        RUNTIME_TMP.mkdir()
        for index, (name, fn) in enumerate(selected):
            folder = root/str(index); folder.mkdir()
            try:
                fn(binary, folder, version)
            except Skipped as exc:
                skipped += 1
                print(f'  SKIP: {name}: {exc}', flush=True)
            except Exception as exc:
                failed += 1
                print(f'  FAIL: {name}: {exc}', flush=True)
            else:
                passed += 1
                print(f'  PASS: {name}', flush=True)
        RUNTIME_TMP = None
    print(f'HTTP_FETCH: {passed} passed, {failed} failed, {skipped} skipped', flush=True)
    return 1 if failed else 0


def dealt_arrives(binary, folder, version):
    rng = random.Random(SEED)
    marker = folder/'at-file'; marker.write_bytes(b'NOT THE BODY')
    at_body = '@'+str(marker)
    body_kinds = ['', 'a', bytes(range(1,256)).decode('latin1'), None, at_body, '<data>']
    targets = ['/a/../b', '/a/./b', '//double', '/g{a,b}', '/g[1-3]', '/%00', '/%zz', '/?a?b', '/frag#not-sent', '', '?q=only']
    special = [(n, spelling) for n in ('Host', 'User-Agent', 'Accept') for spelling in (str.lower, str.upper, lambda x:x)]
    token, visible = TOKEN.decode(), ''.join(chr(i) for i in range(33,127))
    arguments, counts = [], Counter()
    def schedule(population):
        values=(list(population)*((600+len(population)-1)//len(population)))[:600]
        rng.shuffle(values)
        return values
    methods=schedule(METHODS); bodies=schedule(range(6)); target_kinds=schedule(range(11))
    header_kinds=schedule(range(5)); specials=schedule(range(9)); many_flags=schedule(range(17))
    name_first=schedule(token); name_last=schedule(token)
    value_first=schedule(visible); value_last=schedule(visible)
    eligible=[i for i,k in enumerate(target_kinds) if k not in (7,8,9,10)]
    # Deal required byte edges across eligible targets explicitly, then shuffle
    # companions. Each of the185 path/query byte kinds gets at least two.
    pdraw=([c for c in visible if c not in '?#']*((len(eligible)+91)//92))[:len(eligible)]
    qdraw=([c for c in visible if c != '#']*((len(eligible)+92)//93))[:len(eligible)]
    rng.shuffle(pdraw); rng.shuffle(qdraw)
    byte_draws={index:(p,q) for index,p,q in zip(eligible,pdraw,qdraw)}
    # Names a library or a build could treat as its own (amendment 3): each
    # of the thirteen, with a value and empty, once as the first of the
    # caller's headers and once between two of them; the rest anywhere.
    named=[(n,vk,place) for n in THIRTEEN for vk in ('value','empty') for place in ('first','middle')]
    named+=[(n,'value','any') for n in ID_NAMES+OTHER_NAMES for _ in range(2)]
    not_host=[i for i in range(600) if special[specials[i]][0]!='Host']
    first_calls=rng.sample(not_host,sum(place=='first' for _,_,place in named))
    rest=rng.sample([i for i in range(600) if i not in first_calls],len(named)-len(first_calls))
    calls=iter(first_calls+rest)
    named_at={next(calls):item for item in sorted(named,key=lambda item:item[2]!='first')}
    with Peer([Plan() for _ in range(600)]) as peer:
        for i in range(600):
            method = methods[i]
            bkind = bodies[i]
            body = body_kinds[bkind]
            if body is None:
                body = ''.join(chr(rng.randint(1,255)) for _ in range(2000))
            if method in ('GET', 'HEAD'):
                body, bkind = '', 0
            target_kind = target_kinds[i]
            target = targets[target_kind]
            if target_kind not in (7,8,9,10):
                pathchar, querychar = byte_draws[i]
                # ? and # delimit, so omit those as path bytes; # also delimits
                # queries. Other visible bytes occur literally in both places.
                if pathchar not in '?#':
                    target += '/byte'+pathchar
                    counts['path-'+str(ord(pathchar))] += 1
                if querychar != '#':
                    target += ('&' if '?' in target else '?')+'byte='+querychar
                    counts['query-'+str(ord(querychar))] += 1
            name = name_first[i] + f'N{i}' + name_last[i]
            value = value_first[i]+' middle \t '+value_last[i]
            headers = {name: value}
            counts['name-first-'+str(ord(name[0]))] += 1
            counts['name-last-'+str(ord(name[-1]))] += 1
            counts['value-first-'+str(ord(value[0]))] += 1
            counts['value-last-'+str(ord(value[-1]))] += 1
            counts['value-inside-space'] += 1
            counts['value-inside-tab'] += 1
            hkind = header_kinds[i]
            hval = ('', 'x'*1000, 'x'*8000, '@not-a-file', '"quoted\\value')[hkind]
            headers['X-Facet'] = hval
            counts['header-'+str(hkind)] += 1
            if many_flags[i] == 0:
                headers.update({f'X-Many-{j}': str(j) for j in range(37)})
                counts['40-headers'] += 1
            base, spelling = special[specials[i]]
            custom = spelling(base)
            entries = list(headers.items())
            entries.insert(rng.randint(0,len(entries)), (custom, 'example.test' if base == 'Host' else 'caller'))
            headers = dict(entries)
            counts['special-'+base+'-'+custom] += 1
            if i in named_at:
                extra_name,vk,place=named_at[i]
                entries=list(headers.items())
                outside=[j for j,(k,_) in enumerate(entries) if k.lower()!='host']
                at=0 if place=='first' else rng.randint(outside[0]+1,outside[-1]) if place=='middle' else rng.randint(0,len(entries))
                entries.insert(at,(extra_name,'' if vk=='empty' else 'v'+str(rng.randrange(1000000))))
                headers=dict(entries)
            # Counted from the argument as built, not from the deal.
            for extra_name in THIRTEEN+ID_NAMES+OTHER_NAMES:
                if extra_name in headers:
                    kind='named-'+extra_name+('-empty' if headers[extra_name]=='' else '-value')
                    counts[kind]+=1
                    keys=[k for k in headers if k.lower()!='host']
                    at=keys.index(extra_name)
                    if at==0 and len(headers)>=3 and next(iter(headers))==extra_name: counts[kind+'-first']+=1
                    if 0<at<len(keys)-1: counts[kind+'-middle']+=1
            counts['method-'+method] += 1
            counts['body-'+str(bkind)] += 1
            counts['target-'+str(target_kind)] += 1
            arguments.append({'url': peer.url+target, 'method': method, 'headers': headers, 'body': body})
        floors = {**{'method-'+m:20 for m in METHODS},
                  **{'body-'+str(i):20 for i in range(6)},
                  **{'target-'+str(i):20 for i in range(11)},
                  **{'header-'+str(i):20 for i in range(5)}, '40-headers':20}
        for base, spelling in special:
            floors['special-'+base+'-'+spelling(base)] = 20
        for c in range(33,127):
            if chr(c) not in '?#': floors['path-'+str(c)] = 2
            if chr(c) != '#': floors['query-'+str(c)] = 2
            floors['value-first-'+str(c)] = floors['value-last-'+str(c)] = 2
        for c in TOKEN:
            floors['name-first-'+str(c)] = floors['name-last-'+str(c)] = 2
        floors['value-inside-space'] = floors['value-inside-tab'] = 2
        places={}
        for name in THIRTEEN:
            for vk in ('value','empty'):
                floors['named-'+name+'-'+vk]=2
                places['named-'+name+'-'+vk+'-first']=places['named-'+name+'-'+vk+'-middle']=1
        for name in ID_NAMES+OTHER_NAMES:
            floors['named-'+name+'-value']=2
        equal(len(places),52,'arrivals declared place population')
        for kind, floor in list(floors.items())+list(places.items()):
            require(counts[kind] >= floor, f'arrivals dealt {kind}={counts[kind]} < {floor}')
        expected = [request_reference(arg,version) for arg in arguments]
        got = run_calls(binary, folder, arguments, timeout=120)
        equal(len(got),600,'arrivals compared calls')
        equal(len(peer.requests),600,'arrivals listener calls')
        for i,(record,want,result) in enumerate(zip(peer.requests,expected,got)):
            try:
                check_wire(record,want)
                expect_answer(result, answer_reference(Plan().wire,arguments[i]['method']))
            except AssertionError as exc:
                raise AssertionError(f'arrivals call {i}: {exc}') from exc
        require(not peer.errors, f'arrivals peer errors: {peer.errors}')
    equal(len(floors),606,'arrivals declared kind population')
    print('DEALT arrives calls=600 kinds='+str(len(floors))+' counts='+json.dumps(dict(sorted(counts.items())), separators=(',',':')),flush=True)


def refusal_arguments(url,rng=None):
    """Exactly one broken rule per kind; count fixed by BAR's 120 kinds."""
    rng=rng or random.Random(SEED+1)
    base = {'url':url+'?draw='+str(rng.randrange(1000000)), 'method':rng.choice(('POST','PUT','PATCH','DELETE')), 'body':'body-marker-'+str(rng.randrange(1000000)), 'headers':{'X-Seed':'header-marker-'+str(rng.randrange(1000000))}}
    kinds = []
    def add(name, key=None, value=None, argument=None):
        arg = dict(base) if argument is None else argument
        if key is not None:
            arg[key] = value
        kinds.append((name,arg))
    add('unknown-key','mystery',1)
    missing = dict(base); del missing['url']; add('missing-url',argument=missing)
    for prefix in ('ftp://','HTTP://','-'):
        add('url-prefix-'+prefix,'url',prefix+'127.0.0.1/')
    for char in (' ',chr(127),chr(128)):
        add('url-byte-'+str(ord(char)),'url',url+'bad'+char)
    add('empty-authority','url','http:///path')
    bad_authority = [chr(c) for c in range(33,127) if c not in AUTHORITY and chr(c) not in '/?#']
    equal(len(bad_authority),23,'bad authority byte population')
    for char in bad_authority:
        add('authority-'+str(ord(char)),'url','http://a'+char+'b/')
    add('userinfo','url','http://user:pw@127.0.0.1/')
    for method in ('get','OPTIONS',''):
        add('method-'+method,'method',method)
    add('header-empty','headers',{'':'x'})
    add('header-65','headers',{'X'*65:'x'})
    bad_token = [chr(c) for c in range(33,127) if c not in TOKEN]
    equal(len(bad_token),17,'bad header byte population')
    for char in bad_token+[' ']:
        add('header-byte-'+str(ord(char)),'headers',{'X'+char+'Y':'right'})
    for char in ('\r','\n',chr(1),chr(127),chr(128)):
        add('value-byte-'+str(ord(char)),'headers',{'X-A':'x'+char+'y'})
    for edge in (' x','\tx','x ','x\t'):
        add('value-edge-'+repr(edge),'headers',{'X-A':edge})
    add('duplicate','headers',{'X-A':'1','x-a':'2'})
    for name in ('Content-Length','Transfer-Encoding','Expect'):
        for spelling in (name.lower(),name.upper(),name):
            add('reserved-'+spelling,'headers',{spelling:'1'})
    for name in CONNECTION_WRITTEN:
        mixed=''
        while mixed in ('',name.lower(),name.upper()):
            mixed=''.join(c.upper() if rng.random()<.5 else c.lower() for c in name)
        for label,spelling in (('lower',name.lower()),('upper',name.upper()),('mixed',mixed)):
            add('connection-'+label+'-'+name,'headers',{spelling:'v'+str(rng.randrange(10))})
        add('connection-empty-'+name,'headers',{name:''})
    for method in ('GET','HEAD'):
        add('body-with-'+method,'method',method)
    for value in (0,.0009,300.0001,-1,float('inf'),float('nan')):
        add('timeout-'+repr(value),'timeout',value)
    for value in ([], 'bad', 7):
        add('argument-type-'+type(value).__name__,argument=value)
    for key in ('url','method','body'):
        for value in (7,None):
            add(key+'-type-'+repr(value),key,value)
    for value in ([],None):
        add('headers-type-'+repr(value),'headers',value)
    for value in (7,[],None):
        add('header-value-type-'+repr(value),'headers',{'X-A':value})
    for value in (True,'15',None):
        add('timeout-type-'+repr(value),'timeout',value)
    equal(len(kinds),120,'refusal kind population')
    equal(len({name for name,arg in kinds}),120,'distinct refusal kind population')
    return kinds


def dealt_refused(binary,folder,version):
    rng=random.Random(SEED+1)
    with Peer() as peer:
        dealt=[]
        for _ in range(4): dealt.extend(refusal_arguments(peer.url+'/',rng))
        rng.shuffle(dealt)
        counts=Counter(name for name,arg in dealt)
        equal(set(counts.values()),{4},'refusal dealt kind counts')
        equal(len(dealt),480,'refusal dealt calls')
        expected=[]
        for name,arg in dealt:
            try: request_reference(arg,version)
            except Refusal as exc: expected.append(exc.kind)
            else: raise AssertionError('refusal oracle accepted '+name)
        keylog=folder/'refused-keylog.log'
        got=run_calls(binary,folder,[arg for name,arg in dealt],{'SSLKEYLOGFILE':str(keylog)},timeout=60)
        equal(len(got),480,'refusal compared calls')
        for (name,arg),value,kind in zip(dealt,got,expected):
            try:
                expect_error(value,kind)
                check_refusal_message(value,name,arg)
            except AssertionError as exc: raise AssertionError(name+': '+str(exc)) from exc
        equal(peer.accepted,0,'refused listener connections')
        require(not keylog.exists(),'argument-only refusals initialized the curl/TLS library')
    print('DEALT refused calls=480 kinds=120 counts='+json.dumps(dict(sorted(counts.items())),separators=(',',':')),flush=True)


def dealt_answers(binary,folder,version):
    rng=random.Random(SEED+2)
    cases=[]
    def add(label,wire,method='GET',limit=DEFAULT_BODY_LIMIT,reset=False,tags=(),piece=0,drip=0):
        cases.append((label,Plan(wire,reset=reset,piece=piece,drip=drip),method,limit,set(tags)|{label}))
    def normal(i,status):
        framing=('length','chunked','close')[i%3]
        n=(0,1,3000)[(i//3)%3]
        body=(bytes(range(1,256))*12)[:n]
        headers=[(b'X-MiXeD',b'value'),(b'X-Trim',b' \ttrim \t '),(b'X-Empty',b''),(b'X-High',b'\x80\xff')]
        duplicates=2+i%3
        dupname=b'Set-Cookie' if i%2 else b'X-Dup'
        headers.extend((dupname,str(j).encode()) for j in range(duplicates))
        tags={'framing-'+framing,'body-'+str(n),'mixed-name','trim','empty-value','high-value','duplicates-'+str(duplicates)}
        if i%10==0:
            headers.extend((f'X-{j}'.encode(),b'v') for j in range(100-len(headers)-(framing != 'close')))
            tags.add('100-lines')
        if i%10==1:
            headers.append((b'X-Long',b'x'*7990)); tags.add('8000-line')
        interim=b''
        if i%4 in (0,1):
            code=(100,103)[i%4]
            interim=f'HTTP/1.1 {code} Interim\r\nX-Interim: 1\r\n\r\n'.encode();tags.add('interim-'+str(code))
        trailers=[(b'X-T',b'tail')] if framing=='chunked' else []
        if trailers: tags.add('trailer')
        reason='' if i%2==0 else 'three words here'
        tags.add('reason-empty' if not reason else 'reason-three')
        version='1.0' if i%2==0 else '1.1'
        if version=='1.0': tags.add('http10')
        if status in (204,304):
            wire=interim+f'HTTP/1.1 {status} {reason}\r\n'.encode()+b'Content-Length: 5000\r\n\r\n'
            tags={'status-'+str(status)}
        else:
            wire=response(body,status,headers,framing,interim,version,reason,[rng.randint(1,100) for _ in range(40)],trailers)
        add('status-'+str(status),wire,tags=tags)
    companions=list(range(400)); rng.shuffle(companions)
    for i,status in zip(companions,range(200,600)):
        normal(i,status)
    for i in range(20):
        for placement,body in [('first',b'\0ab'),('middle',b'a\0b'),('last',b'ab\0')]:
            add('nul-'+placement,response(body))
        for framing in ('length','chunked','close'):
            for n in (1000,1001):
                add('limit-'+framing+'-'+str(n),response(b'x'*n,framing=framing,chunks=[rng.randint(1,150) for _ in range(20)]),limit=1000)
        add('limit-5000',response(b'x'*5000),limit=1000)
        add('limit-nul',response(b'x'*500+b'\0'+b'x'*500),limit=1000,piece=256,drip=.01)
        for nul in (False,True):
            add('partial-nul' if nul else 'partial',b'HTTP/1.1 200 OK\r\nContent-Length: 100\r\n\r\n'+(b'x'*9+b'\0' if nul else b'x'*10))
        add('empty-peer',b'')
        add('reset',b'HTTP/1.1 200 OK\r\nContent-Length: 100\r\n\r\n'+b'x'*10,reset=True)
        head=b'HTTP/1.1 200 OK\r\nX-A: one\r\nX-B: two\r\n\r\n'
        cut=rng.randrange(len(b'HTTP/1.1 200 OK\r\n'),len(head))
        add('cut-header',head[:cut])
        for status in (204,304):
            add('status-'+str(status),f'HTTP/1.1 {status} OK\r\nContent-Length: 5000\r\n\r\n'.encode())
        add('head-length',b'HTTP/1.1 200 OK\r\nContent-Length: 5000\r\n\r\n',method='HEAD')
    while len(cases)<1000:
        normal(len(cases),rng.choice([200,404,429,500]))
    equal(len(cases),1000,'answer dealt calls')
    counts=Counter(tag for _,_,_,_,tags in cases for tag in tags)
    floors={**{'status-'+str(code):1 for code in range(200,600)},
        **{name:20 for name in ('framing-length','framing-chunked','framing-close','http10','reason-empty','reason-three','interim-100','interim-103','trailer','status-204','status-304','head-length','mixed-name','duplicates-2','duplicates-3','duplicates-4','trim','empty-value','high-value','100-lines','8000-line','body-0','body-1','body-3000','nul-first','nul-middle','nul-last','limit-length-1000','limit-length-1001','limit-chunked-1000','limit-chunked-1001','limit-close-1000','limit-close-1001','limit-5000','limit-nul','partial','partial-nul','empty-peer','reset','cut-header')}}
    equal(len(floors),438,'answers declared kind population')
    for name,n in floors.items(): require(counts[name]>=n,f'answers dealt {name}={counts[name]} < {n}')
    compared=0
    for limit in (DEFAULT_BODY_LIMIT,1000):
        group=[c for c in cases if c[3]==limit]
        rng.shuffle(group)
        with Peer([plan for label,plan,method,lim,tags in group]) as peer:
            arguments=[{'url':peer.url+'/', 'method':method} for label,plan,method,lim,tags in group]
            extra={'EIGS_HTTP_FETCH_MAX_BODY':str(limit)}
            got=run_calls(binary,folder,arguments,extra,timeout=120)
            for (label,plan,method,lim,tags),value in zip(group,got):
                try:
                    try: want=answer_reference(plan.wire,method,lim,plan.reset)
                    except Refusal as exc:
                        expect_error(value,exc.kind,exc.message.removeprefix('http_fetch: '))
                    else: expect_answer(value,want)
                except AssertionError as exc:
                    raise AssertionError(f'answers {label}: {exc}') from exc
                compared+=1
            equal(len(peer.requests),len(group),'answer listener requests')
            require(not peer.errors,f'answer peer errors: {peer.errors}')
    equal(compared,1000,'answer compared calls')
    print('DEALT answers calls=1000 kinds='+str(len(floors))+' counts='+json.dumps(dict(sorted(counts.items())),separators=(',',':')),flush=True)


def defaults(binary,folder,version):
    compared=0
    for method in METHODS:
        for body in ('','x') if method not in ('GET','HEAD') else ('',):
            record,_=one_request(binary,folder,{'method':method,'body':body},version)
            names=['Host','User-Agent','Accept','Connection']
            if method in ('POST','PUT','PATCH') or body: names.append('Content-Length')
            equal(sorted(k.decode().lower() for k,v in record['headers']),sorted(n.lower() for n in names),f'{method} {body!r}: header names')
            equal([v for k,v in record['headers'] if k.lower()==b'connection'],[b'close'],f'{method} {body!r}: the Connection line')
            compared+=1
    equal(compared,10,'default header/method/body comparisons')


def target_literal(binary,folder,version):
    one_request(binary,folder,{'method':'DELETE','url':'/a/../b{x,y}?q=[1-3]&s="y\\z#frag'},version)


def host_order(binary,folder,version):
    record,_=one_request(binary,folder,{'headers':{'X-A':'1','Host':'example.test','X-B':'2'}},version)
    equal([k for k,v in record['headers'] if k.lower() in (b'host',b'x-a',b'x-b')],[b'Host',b'X-A',b'X-B'],'caller Host first')


def one_connection_each(binary,folder,version):
    # A listener that keeps each connection open and takes one at a time:
    # when it accepts the next, a read on the one before must return its end.
    port=pick_port()
    listener=socket.socket()
    listener.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1)
    listener.bind(('127.0.0.1',port));listener.listen(8);listener.settimeout(20)
    records,problems,held=[],[],[]
    def serve():
        try:
            for index in range(3):
                try: sock,_=listener.accept()
                except socket.timeout:
                    problems.append(f'connection {index+1} never came'); return
                if held:
                    held[-1].settimeout(5)
                    try: rest=held[-1].recv(65536)
                    except socket.timeout: rest=None
                    if rest!=b'': problems.append(f'connection {index}: no end before connection {index+1} (read {rest!r})')
                held.append(sock)
                sock.settimeout(20)
                wire=b''
                while b'\r\n\r\n' not in wire:
                    data=sock.recv(65536)
                    if not data: break
                    wire+=data
                head,_,body=wire.partition(b'\r\n\r\n')
                lines=head.split(b'\r\n')
                length=[int(l.split(b':',1)[1]) for l in lines[1:] if l.split(b':',1)[0].lower()==b'content-length']
                while length and len(body)<length[0]:
                    data=sock.recv(65536)
                    if not data: break
                    body+=data
                records.append(lines)
                sock.sendall(b'HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok')
            # A request sent again on a kept connection would wait here.
            listener.settimeout(1)
            try:
                extra,_=listener.accept();extra.close();problems.append('a fourth connection')
            except socket.timeout: pass
        except OSError as exc:
            problems.append('listener: '+str(exc))
    thread=threading.Thread(target=serve,daemon=True);thread.start()
    try:
        url=f'http://127.0.0.1:{port}/'
        source=DESCRIBE+call_source({'url':url,'timeout':5})+call_source({'url':url,'timeout':5})+call_source([url,'{}','x'],True)
        output=program(binary,folder,source)
        thread.join(30)
        require(not thread.is_alive(),'listener did not finish')
        for sock in held:
            # A second request on a kept connection is read here.
            sock.settimeout(.2)
            try: late=sock.recv(65536)
            except (socket.timeout,OSError): late=b''
            if late: problems.append(f'a second request on one connection: {late[:60]!r}')
        require(not problems,'; '.join(problems))
        values=[json.loads(line) for line in output.splitlines()]
        equal(len(values),3,'one connection each: calls')
        equal(values[2],['body',2,hashlib.sha256(b'ok').hexdigest()],'one connection each: http_post')
        for value in values[:2]: equal(value[:2],['answer',200],'one connection each: http_fetch')
        equal(len(records),3,'one connection each: connections with a request')
        for index,lines in enumerate(records):
            connection=[l for l in lines[1:] if l.split(b':',1)[0].lower()==b'connection']
            equal(connection,[b'Connection: close'],f'request {index+1}: the Connection line')
    finally:
        listener.close()
        for sock in held:
            with contextlib.suppress(OSError): sock.close()


def request_body(binary,folder,version):
    marker=folder/'body-file';marker.write_text('must not be read')
    bodies=[bytes(range(1,256))+b'\r\n',b'x'*2000000,('@'+str(marker)).encode()]
    for body in bodies:
        record,_=one_request(binary,folder,{'method':'POST','body':body.decode('latin1')},version)
        equal(hashlib.sha256(record['body']).hexdigest(),hashlib.sha256(body).hexdigest(),'request body sha256')
        require(not any(k.lower()==b'expect' for k,v in record['headers']),'unexpected Expect')


def request_headers(binary,folder,version):
    for n in (1000,8000):
        one_request(binary,folder,{'headers':{'X-Long':'v'*n}},version)
    one_request(binary,folder,{'headers':{f'X-{i}':str(i) for i in range(40)}},version)


def request_limit(binary,folder,version):
    rng=random.Random(SEED+3)
    shapes=[]
    shapes.append({'X':'v'*(65536-5)})
    shapes.append({f'X-{i:04}':'v'*6 for i in range(4096)})  # six-byte name + six-byte value + 4
    many={f'X-{i}':'v'*rng.randint(1,100) for i in range(99)}
    size=sum(len(k)+len(v)+4 for k,v in many.items())
    many['X-Final']='v'*(65536-size-len('X-Final')-4)
    shapes.append(many)
    shapes.append({f'X-{i:010}':'' for i in range(4096)})  # twelve-byte name, empty value
    compared=0
    for index,headers in enumerate(shapes):
        equal(sum(len(k)+len(v)+4 for k,v in headers.items()),65536,'request limit fixture count')
        with Peer() as peer:
            good={'url':peer.url+'/','headers':headers}
            got=run_calls(binary,folder,[good])[0]
            expect_answer(got,answer_reference(Plan().wire))
            equal(len(peer.requests),1,'request limit accepted connection')
            check_wire(peer.requests[0],request_reference(good,version))
        bad=dict(headers)
        if index==3:
            bad['Z']=''
        else:
            first=next(iter(bad));bad[first]+='x'
        with Peer() as peer:
            got=run_calls(binary,folder,[{'url':peer.url+'/','headers':bad}])[0]
            expect_error(got,'limit')
            equal(peer.accepted,0,'over-limit request sent nothing')
        compared+=2
    equal(compared,8,'request limit comparisons')


def userinfo(binary,folder,version):
    with Peer() as peer:
        argument={'url':peer.url.replace('://','://user:pw@')+'/'}
        got=run_calls(binary,folder,[argument])[0]
        expect_error(got,'value')
        equal(peer.accepted,0,'userinfo sent nothing')


def statuses(binary,folder,version):
    plans=[]
    for code in (200,204,301,404,429,500):
        headers=[(b'Location',b'/redirected')] if code==301 else []
        plans.append(Plan(response(b'' if code==204 else b'body-'+str(code).encode(),code,headers)))
    with Peer(plans) as peer:
        got=run_calls(binary,folder,[{'url':peer.url+'/'} for _ in plans])
        for value,plan in zip(got,plans): expect_answer(value,answer_reference(plan.wire))
        equal(peer.accepted,6,'statuses no redirect request')
        equal(len(peer.requests),6,'status comparisons')


def join_order(binary,folder,version):
    wire=b'HTTP/1.1 200 OK\r\nX-A: 1\r\nX-Dup:  one  \r\nX-B: 2\r\nX-Dup: two\r\nContent-Length: 2\r\n\r\nok'
    with Peer([Plan(wire)]) as peer:
        value=run_calls(binary,folder,[{'url':peer.url+'/'}])[0]
        expect_answer(value,answer_reference(wire))
        equal(value[3],['x-a','x-dup','x-b','content-length'],'answer header first arrival order')
        equal(value[4][1],'one, two','duplicate joined value')


def interim_trailer(binary,folder,version):
    plans=[Plan(response(b'final',interim=b'HTTP/1.1 100 Continue\r\nX-Interim: 1\r\n\r\n')),
           Plan(response(b'whole',framing='chunked',chunks=[1,2,1],trailers=[(b'X-T',b'tail')]))]
    with Peer(plans) as peer:
        got=run_calls(binary,folder,[{'url':peer.url+'/'} for _ in plans])
        for value,plan in zip(got,plans):
            expect_answer(value,answer_reference(plan.wire))
            require('x-interim' not in value[3] and 'x-t' not in value[3],'non-final header escaped')


def answer_sizes(binary,folder,version):
    for framing in ('length','chunked'):
        plans=[Plan(response(b'x'*n,framing=framing,chunks=[16384]*(n//16384+1)),piece=16384) for n in (16383,16384,1000000)]
        with Peer(plans) as peer:
            got=run_calls(binary,folder,[{'url':peer.url+'/'} for _ in plans])
            for value,plan in zip(got,plans): expect_answer(value,answer_reference(plan.wire))


def answer_header_limit(binary,folder,version):
    exact=b'X: '+b'v'*(65536-5)+b'\r\n'
    many=b''.join(f'X{i:04}: '.encode()+b'v'*7+b'\r\n' for i in range(4096))
    equal(len(many),65536,'answer many-lines fixture count')
    compared=0
    for lines in (exact,many):
        for over in (False,True):
            adjusted=lines.replace(b'\r\n',b'x\r\n',1) if over else lines
            wire=b'HTTP/1.1 200 OK\r\n'+adjusted+b'\r\n'
            with Peer([Plan(wire)]) as peer:
                value=run_calls(binary,folder,[{'url':peer.url+'/'}])[0]
                if over: expect_error(value,'limit',"the answer's headers are longer than 65536 bytes")
                else: expect_answer(value,answer_reference(wire))
            compared+=1
    interim=b'HTTP/1.1 100 Continue\r\n'+exact+b'X-Extra: x\r\n\r\n'+response()
    with Peer([Plan(interim)]) as peer:
        expect_error(run_calls(binary,folder,[{'url':peer.url+'/'}])[0],'limit',"the answer's headers are longer than 65536 bytes")
    # Trailers are excluded from the returned dict but included in the same
    # header-byte budget. Pin both exact and over-limit trailer edges.
    framing=b'Transfer-Encoding: chunked\r\n'
    trailer=b'X-T: v\r\n'
    padding=b'X: '+b'v'*(65536-len(framing)-len(trailer)-5)+b'\r\n'
    for over in (False,True):
        tail=trailer.replace(b'v',b'vv',1) if over else trailer
        wire=b'HTTP/1.1 200 OK\r\n'+framing+padding+b'\r\n0\r\n'+tail+b'\r\n'
        with Peer([Plan(wire)]) as peer:
            value=run_calls(binary,folder,[{'url':peer.url+'/'}])[0]
            if over: expect_error(value,'limit',"the answer's headers are longer than 65536 bytes")
            else: expect_answer(value,answer_reference(wire))
        compared+=1
    interim_line=b'X-I: '+b'v'*(32768-7)+b'\r\n'
    length=b'Content-Length: 0\r\n'
    final_line=b'X-F: '+b'v'*(32768-len(length)-7)+b'\r\n'
    equal(len(interim_line),32768,'interim aggregate fixture bytes')
    equal(len(final_line)+len(length),32768,'final aggregate fixture bytes')
    for over in (False,True):
        line=final_line.replace(b'\r\n',b'x\r\n',1) if over else final_line
        wire=b'HTTP/1.1 100 Continue\r\n'+interim_line+b'\r\nHTTP/1.1 200 OK\r\n'+line+length+b'\r\n'
        with Peer([Plan(wire)]) as peer:
            value=run_calls(binary,folder,[{'url':peer.url+'/'}])[0]
            if over: expect_error(value,'limit',"the answer's headers are longer than 65536 bytes")
            else: expect_answer(value,answer_reference(wire))
        compared+=1
    equal(compared+1,9,'answer header limit comparisons')


LINES_MESSAGE='the answer has more than 4096 header lines'
BYTES_MESSAGE="the answer's headers are longer than 65536 bytes"


def header_block(n,width=8,start=0):
    # n header lines of exactly `width` bytes each (CR LF counted), distinct
    # three-byte names; nothing else in the block.
    names=short_names(start+n)[start:]
    block=b''.join(name.encode()+b': '+b'v'*(width-7)+b'\r\n' for name in names)
    equal(len(block),n*width,'line-limit fixture bytes')
    return block


def line_shape(binary,folder,cases,legacy_over=None):
    """Each case: (label, wire, None for returned or the limit message).
    The stated outcome is checked against the second reference first, then
    the runtime against both. legacy_over: a wire http_post must refuse."""
    compared=0
    for label,wire,message in cases:
        try:
            want=answer_reference(wire)
        except Refusal as exc:
            equal((exc.kind,exc.message),('limit','http_fetch: '+str(message)),f'{label}: reference outcome')
            want=None
        else:
            equal(message,None,f'{label}: reference returned an answer')
        with Peer([Plan(wire)]) as peer:
            value=run_calls(binary,folder,[{'url':peer.url+'/'}])[0]
            try:
                if want is None: expect_error(value,'limit',message)
                else: expect_answer(value,want)
            except AssertionError as exc: raise AssertionError(f'{label}: {exc}') from exc
            equal(peer.accepted,1,f'{label}: one connection')
            require(not peer.errors,f'{label}: peer errors {peer.errors}')
        compared+=1
    if legacy_over is not None:
        with Peer([Plan(legacy_over)]) as peer:
            value=run_calls(binary,folder,[[peer.url+'/','{}','x']],legacy=True)[0]
            expect_error(value,'limit',LINES_MESSAGE,'http_post')
        compared+=1
    equal(compared,len(cases)+(legacy_over is not None),'line-limit comparisons')


def answer_lines_edge(binary,folder,version):
    status=b'HTTP/1.1 200 OK\r\n'
    over=status+header_block(4097)+b'\r\n'
    line_shape(binary,folder,[('4096x8',status+header_block(4096)+b'\r\n',None),
                              ('4097x8',over,LINES_MESSAGE)],legacy_over=over)


def answer_lines_6000(binary,folder,version):
    # Above the library's own 5000 from release 8.14.0: the runtime's limit
    # must be the one reached, never curl error 100.
    line_shape(binary,folder,[('6000x8',b'HTTP/1.1 200 OK\r\n'+header_block(6000)+b'\r\n',LINES_MESSAGE)])


def answer_lines_both(binary,folder,version):
    # Line 4097 takes bytes (65544) and lines past at once: bytes is reported.
    wire=b'HTTP/1.1 200 OK\r\n'+header_block(4096,16)+header_block(1,8,4096)+b'\r\n'
    line_shape(binary,folder,[('4096x16+1x8',wire,BYTES_MESSAGE)])


def answer_lines_interim(binary,folder,version):
    def wire(interim,final):
        return (b'HTTP/1.1 100 Continue\r\n'+header_block(interim)+b'\r\n'
                +b'HTTP/1.1 200 OK\r\n'+header_block(final,8,interim)+b'\r\n')
    line_shape(binary,folder,[('2048+2048',wire(2048,2048),None),
                              ('2048+2049',wire(2048,2049),LINES_MESSAGE),
                              ('3000+3000',wire(3000,3000),LINES_MESSAGE)])


def answer_lines_trailer(binary,folder,version):
    framing=b'Transfer-Encoding: chunked\r\n'
    def wire(trailers):
        return (b'HTTP/1.1 200 OK\r\n'+framing+header_block(4094)+b'\r\n'
                +b'2\r\nok\r\n0\r\n'+header_block(trailers,8,4094)+b'\r\n')
    line_shape(binary,folder,[('4095+1 trailer',wire(1),None),
                              ('4095+2 trailers',wire(2),LINES_MESSAGE)])


# A header line that begins with HTTP/ is a header line: only the first line
# of the exchange, or the line after an empty line, is a status line.
def status_like_many(binary,folder,version):
    wire=b'HTTP/1.1 200 OK\r\n'+b'HTTP/9: v\r\n'*6000+b'\r\n'
    line_shape(binary,folder,[('6000 HTTP/9 lines',wire,LINES_MESSAGE)])


def status_like_wide(binary,folder,version):
    wire=b'HTTP/1.1 200 OK\r\n'+(b'HTTP/9: '+b'v'*60+b'\r\n')*1000+b'X-B: 2\r\nContent-Length: 2\r\n\r\nhi'
    line_shape(binary,folder,[('1000 HTTP/9 lines of 70 bytes',wire,BYTES_MESSAGE)])


def status_like_neighbours(binary,folder,version):
    # What comes back for a name that is not a token is the library's (the
    # bar's "Not decided here"): pin the status and the lines around it only.
    wire=b'HTTP/1.1 200 OK\r\nSet-Cookie: a=1\r\nHTTP/1.1 599 x: y\r\nX-B: 2\r\nContent-Length: 2\r\n\r\nhi'
    with Peer([Plan(wire)]) as peer:
        value=run_calls(binary,folder,[{'url':peer.url+'/'}])[0]
        equal(value[:3],['answer',200,'int'],'HTTP/ header line: status')
        got=dict(zip(value[3],value[4]))
        equal((got.get('set-cookie'),got.get('x-b'),got.get('content-length')),('a=1','2','2'),'HTTP/ header line: neighbours kept')
        equal(value[5],2,'HTTP/ header line: body length')


def immediate_limit_head(binary,folder,version):
    wire=b'HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n'
    with Peer([Plan(wire,endless=True,drip=.001)]) as peer:
        start=time.monotonic()
        value=run_calls(binary,folder,[{'url':peer.url+'/'}],{'EIGS_HTTP_FETCH_MAX_BODY':'1000'})[0]
        elapsed=time.monotonic()-start
        expect_error(value,'limit',"the answer's body is longer than 1000 bytes (EIGS_HTTP_FETCH_MAX_BODY)")
        require(elapsed<5,f'endless limit waited {elapsed}s')
    head=b'HTTP/1.1 200 OK\r\nContent-Length: 5000\r\n\r\n'
    with Peer([Plan(head,hold=5)]) as peer:
        start=time.monotonic()
        value=run_calls(binary,folder,[{'url':peer.url+'/','method':'HEAD'}],{'EIGS_HTTP_FETCH_MAX_BODY':'1000'})[0]
        require(time.monotonic()-start<3,'HEAD waited for announced body')
        expect_answer(value,answer_reference(head,'HEAD',1000))


BODY_ENV_VALUES=('1000','1','2147483647','0000001000','','0','2147483648','00000001000','+1000','1000 ',' 1000','1e3','0x10','1000abc','abc')


def body_environment(binary,folder,version,setting):
    print('BODY_ENV value='+repr(setting),flush=True)
    parsed=int(setting) if setting in ('1000','1','2147483647','0000001000') else DEFAULT_BODY_LIMIT
    for n in (1001,16777217):
        wire=response(b'x'*n)
        with Peer([Plan(wire,piece=16384)]) as peer:
            value=run_calls(binary,folder,[{'url':peer.url+'/'}],{'EIGS_HTTP_FETCH_MAX_BODY':setting},timeout=60)[0]
            try: want=answer_reference(wire,body_limit=parsed)
            except Refusal as exc: expect_error(value,exc.kind,exc.message.removeprefix('http_fetch: '))
            else: expect_answer(value,want)


def connection_errors(binary,folder,version):
    port=pick_port()
    cases=[(f'http://127.0.0.1:{port}/','could not connect (curl error 7)'),
           ('http://eigs2375-does-not-exist.invalid/','could not resolve the host (curl error 6)'),
           ('http://127.0.0.1:99999/','curl failed (curl error 3)'),
           ('http://abcdefghijklmnopqrstuvwxyz.ABCDEFGHIJKLMNOPQRSTUVWXYZ.0123456789-_a.invalid:80/','could not resolve the host (curl error 6)'),
           (f'http://[::1]:{port}/','could not connect (curl error 7)')]
    got=run_calls(binary,folder,[{'url':url} for url,msg in cases])
    for value,(_,message) in zip(got,cases): expect_error(value,'io',message)


def timeouts(binary,folder,version):
    plans=[Plan(b'',hold=7),Plan(b'',hold=7),Plan(b'HTTP/1.1 200 OK\r\nContent-Length: 10000\r\n\r\n'+b'x'*20,piece=1,drip=.2,drip_body=True)]
    for limit,plan in zip((1,.5,1),plans):
        with Peer([plan]) as peer:
            start=time.monotonic()
            value=run_calls(binary,folder,[{'url':peer.url+'/','timeout':limit}])[0]
            elapsed=time.monotonic()-start
            expect_error(value,'io','timed out (curl error 28)')
            require(limit<=elapsed<limit+5,f'timeout {limit}: elapsed={elapsed}')


def default_timeouts(binary,folder,version):
    with Peer([Plan(b'',hold=21),Plan(b'',hold=21)]) as peer:
        def attempt(legacy):
            own=folder/str(legacy);own.mkdir()
            argument=[peer.url+'/','{}','x'] if legacy else {'url':peer.url+'/'}
            start=time.monotonic()
            result=run_calls(binary,own,[argument],legacy=legacy)[0]
            elapsed=time.monotonic()-start
            expect_error(result,'io','timed out (curl error 28)','http_post' if legacy else 'http_fetch')
            require(15<=elapsed<20,f'default timeout {legacy}: elapsed={elapsed}')
        with ThreadPoolExecutor(max_workers=2) as pool:
            futures=[pool.submit(attempt,legacy) for legacy in (False,True)]
            for future in futures: future.result()


def early_answers(binary,folder,version):
    partial=b'HTTP/1.1 200 OK\r\nContent-Length: 100\r\n\r\n'+b'x'*10
    plans=[Plan(partial),Plan(b''),Plan(partial,reset=True)]
    status=b'HTTP/1.1 200 OK\r\n'
    incomplete=[status,status+b'X-A: 1',status+b'X-A: 1\r\n',
        b'HTTP/1.1 100 Continue\r\n\r\n'+status,status+b'X-A: '+b'x'*70000]
    plans += [Plan(wire) for wire in incomplete]
    plans += [Plan(status+b'X-A: 1'),Plan(b'HTTP/1.1 101 Switching Protocols\r\n\r\n'+response())]
    methods=['GET']*8+['HEAD','GET']
    equal(len(plans),10,'early-answer fixture population')
    with Peer(plans) as peer:
        got=run_calls(binary,folder,[{'url':peer.url+'/','method':m} for m in methods])
        for i,value in enumerate(got):
            try: expect_error(value,'io','the answer ended early')
            except AssertionError as exc: raise AssertionError(f'early case {i}: {exc}') from exc


def nul_body(binary,folder,version):
    import gzip
    encoded=gzip.compress(b'plain text',mtime=0)
    require(b'\0' in encoded,'gzip fixture must carry a NUL as raw bytes')
    plans=[Plan(response(b'a\0b')),Plan(response(encoded,headers=[(b'Content-Encoding',b'gzip')]))]
    with Peer(plans) as peer:
        values=run_calls(binary,folder,[{'url':peer.url+'/'} for _ in plans])
        for value in values:
            # Compression is not undone. The gzip bytes hold NUL even though
            # their decoded text does not, so decoding cannot hide this error.
            expect_error(value,'io','the answer holds a NUL byte, which text cannot carry')
        equal(peer.record_count,2,'raw and compressed NUL-body comparisons')


def curl_version_text():
    # The library itself, by the names the runtime loads it by.
    import ctypes
    names=('libcurl.4.dylib','libcurl.dylib') if sys.platform=='darwin' else ('libcurl.so.4','libcurl.so')
    lib=None
    for name in names:
        try: lib=ctypes.CDLL(name);break
        except OSError: pass
    require(lib is not None,'curl library not found for fixture version check')
    lib.curl_version.restype=ctypes.c_char_p
    return lib.curl_version().decode()


def curl_version():
    return int(re.search(r'libcurl/(\d+)',curl_version_text()).group(1))


def nul_header(binary,folder,version):
    if curl_version()<8: raise Skipped('header NUL error number fixed by BAR for curl 8+')
    with Peer([Plan(b'HTTP/1.1 200 OK\r\nX-Nul: a\0b\r\nContent-Length: 0\r\n\r\n')]) as peer:
        expect_error(run_calls(binary,folder,[{'url':peer.url+'/'}])[0],'io','curl failed (curl error 8)')


def timeout_edges(binary,folder,version):
    port=pick_port()
    value=run_calls(binary,folder,[{'url':f'http://127.0.0.1:{port}/','timeout':.001}])[0]
    # "Taken" means the attempt was made: an io error of the attempt, never the
    # argument's value error. Which of the two comes first, the refused connect
    # or the 1 ms limit, is a race (28 in 4 of 20 runs on the TSan build).
    equal(value[:2],['error','io'],'0.001 taken: attempt error kind')
    require(value[2] in ('http_fetch: could not connect (curl error 7)','http_fetch: timed out (curl error 28)'),
            f'0.001 taken: attempt message {value[2]!r}')
    for timeout in (300,300.0): one_request(binary,folder,{'timeout':timeout},version)


def https_certificates(binary,folder,version):
    if not shutil.which('openssl'): raise Skipped('openssl is unavailable')
    import ssl
    first=folder/'first.pem';key=folder/'key.pem';second=folder/'second.pem'
    for cert,outkey,subject,san in [(first,key,'127.0.0.1','IP:127.0.0.1'),(second,folder/'second.key','second.example','DNS:second.example')]:
        cfg=folder/(cert.stem+'.cnf')
        cfg.write_text('[req]\ndistinguished_name=dn\nx509_extensions=ext\nprompt=no\n[dn]\nCN='+subject+'\n[ext]\nsubjectAltName='+san+'\nbasicConstraints=critical,CA:TRUE\n')
        process=subprocess.run(['openssl','req','-x509','-newkey','rsa:2048','-nodes','-days','1','-config',str(cfg),'-keyout',str(outkey),'-out',str(cert)],capture_output=True,timeout=30)
        require(process.returncode==0,f'openssl certificate generation: {process.stderr.decode()}')
    trusted=folder/'certs';trusted.mkdir()
    hashed=subprocess.check_output(['openssl','x509','-hash','-noout','-in',str(first)]).decode().strip()
    shutil.copyfile(first,trusted/(hashed+'.0'))
    tls=ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER);tls.load_cert_chain(first,key)
    cases=[({},60),({'CURL_CA_BUNDLE':str(first)},None),({'SSL_CERT_FILE':str(first)},None),
        ({'CURL_CA_BUNDLE':'','SSL_CERT_FILE':str(first)},None),
        ({'CURL_CA_BUNDLE':str(folder/'missing.pem'),'SSL_CERT_FILE':str(first)},77),
        ({'SSL_CERT_DIR':str(trusted)},None),
        ({'SSL_CERT_FILE':str(second),'SSL_CERT_DIR':str(trusted)},None),
        ({'CURL_CA_BUNDLE':str(second),'SSL_CERT_DIR':str(trusted)},60)]
    compared=0
    for extra,error in cases:
        wire=response(b'trusted')
        with Peer([Plan(wire)],tls=tls) as peer:
            value=run_calls(binary,folder,[{'url':peer.url+'/'}],extra)[0]
            if error is not None: expect_error(value,'io',f'curl failed (curl error {error})')
            else: expect_answer(value,answer_reference(wire))
            require(not peer.errors,f'TLS peer errors: {peer.errors}')
        compared+=1
    equal(compared,8,'TLS certificate environment comparisons')


def compile_shim(folder,name,source):
    path=folder/(name+'.c');path.write_text(source)
    out=folder/(name+'.so')
    flags=(ROOT/'tools/werror_flags.txt').read_text().split()
    proc=subprocess.run([os.environ.get('CC','cc'),'-shared','-fPIC','-Wall','-Wextra',*flags,str(path),'-o',str(out),'-ldl'],capture_output=True,timeout=30)
    require(proc.returncode==0 and not proc.stderr,f'shim compile rc={proc.returncode}: {(proc.stdout+proc.stderr).decode()}')
    return out


NO_CURL_SHIM=r'''#define _GNU_SOURCE
#include <dlfcn.h>
#include <string.h>
void *dlopen(const char *name,int flags) {
    if(name && strstr(name,"libcurl")) return 0;
    void *(*real_open)(const char *,int)=0;
    *(void **)(&real_open)=dlsym(RTLD_NEXT,"dlopen");
    return real_open(name,flags);
}
'''
OPTION_SHIM=r'''#include <stdlib.h>
#include <stdarg.h>
struct curl_slist { char *data; struct curl_slist *next; };
int curl_global_init(long flags) { (void)flags; return 0; }
void *curl_easy_init(void) { return malloc(1); }
void curl_easy_cleanup(void *p) { free(p); }
int curl_easy_setopt(void *p,int option,...) {
    (void)p;
    /* CURLOPT_TIMEOUT_MS=155, curl7.16.2: ceil(0.0011*1000)=2. */
    va_list args; va_start(args,option);
    if(option==155) {
        long milliseconds=va_arg(args,long); va_end(args);
        return milliseconds==2 ? 48 : 43;
    }
    va_end(args); return 0;
}
int curl_easy_perform(void *p) { (void)p; return 7; }
int curl_easy_getinfo(void *p,int info,...) { (void)p; (void)info; return 0; }
struct curl_slist *curl_slist_append(struct curl_slist *p,const char *s) {
    size_t n=0; while(s[n]) n++;
    struct curl_slist *node=malloc(sizeof *node);
    if(!node) return 0;
    node->data=malloc(n+1);
    if(!node->data) { free(node); return 0; }
    for(size_t i=0;i<=n;i++) node->data[i]=s[i];
    node->next=0;
    if(!p) return node;
    struct curl_slist *tail=p; while(tail->next) tail=tail->next;
    tail->next=node; return p;
}
void curl_slist_free_all(struct curl_slist *p) {
    while(p) { struct curl_slist *next=p->next; free(p->data); free(p); p=next; }
}
'''


def no_library(binary,folder,version):
    if sys.platform!='linux': raise Skipped('Linux loader shim row')
    shim=compile_shim(folder,'no-curl',NO_CURL_SHIM)
    with Peer() as peer:
        got=run_calls(binary,folder,[{'url':peer.url+'/'}]*2,{'LD_PRELOAD':preload_for(binary,shim)})
        for value in got: expect_error(value,'io','could not load the curl library')
        equal(peer.accepted,0,'missing-library sent nothing')
    missing=compile_shim(folder,'missing-name',OPTION_SHIM.replace('int curl_easy_getinfo(', 'int absent_getinfo('))
    shutil.copyfile(missing,folder/'libcurl.so.4')
    with Peer() as peer:
        got=run_calls(binary,folder,[{'url':peer.url+'/'}]*2,{'LD_LIBRARY_PATH':str(folder)})
        for value in got: expect_error(value,'io','could not load the curl library')
        equal(peer.accepted,0,'missing-symbol sent nothing')


def refused_option(binary,folder,version):
    if sys.platform!='linux': raise Skipped('Linux loader shim row')
    shim=compile_shim(folder,'libcurl',OPTION_SHIM)
    shutil.copyfile(shim,folder/'libcurl.so.4')
    with Peer() as peer:
        value=run_calls(binary,folder,[{'url':peer.url+'/','timeout':.0011}],{'LD_LIBRARY_PATH':str(folder)})[0]
        expect_error(value,'io','curl failed (curl error 48)')
        equal(peer.accepted,0,'refused option sent nothing')


def concurrent_calls(binary,folder,version):
    for count,delay in ((8,2),(16,0)):
        own=folder/str(count);own.mkdir()
        with Peer([Plan(delay=delay,echo_target=True)],repeat=True) as peer:
            code='number is (http_request_header of "X-Number")\n'
            # The request's path number is taken from the incoming header, so
            # no shared store or global request identity participates.
            code='number is http_request_header of "x-number"\nanswer is http_fetch of {"url": '+eigs(peer.url+'/number/')+' + number[0]}\nanswer.body'
            # A route used by raw_runtime has no extra headers. Here the
            # client below sends them itself, preserving each caller's ID.
            with runtime_server(binary,own,code) as (proc,port):
                def request_number(number):
                    with socket.create_connection(('127.0.0.1',port),5) as sock:
                        sock.settimeout(15)
                        sock.sendall(f'GET /call HTTP/1.1\r\nHost: test\r\nX-Number: {number}\r\nConnection: close\r\n\r\n'.encode())
                        output=b''
                        while True:
                            data=sock.recv(65536)
                            if not data: break
                            output+=data
                        return output
                start=time.monotonic()
                with ThreadPoolExecutor(max_workers=count) as pool:
                    values=list(pool.map(request_number,range(count)))
                elapsed=time.monotonic()-start
                if delay: require(elapsed<4,f'eight calls serialized: {elapsed}s')
                for number,value in enumerate(values):
                    equal(value.split(b'\r\n\r\n',1)[1],f'/number/{number}'.encode(),'concurrent caller identity')
                equal(len(peer.requests),count,'concurrent listener call count')


def tape_program(binary,folder,source,plans,extra=None,expected_records=None):
    trace=folder/'calls.tape'
    with Peer(plans) as peer:
        source=source.replace('PEER_URL',peer.url)
        recorded=program(binary,folder,source,{**(extra or {}),'EIGS_TRACE':str(trace)},name='record')
        equal(peer.record_count,0 if expected_records==0 else len(plans),'tape peer request count')
    if expected_records is not None:
        lines=trace.read_bytes().splitlines()
        equal(sum(b' http_fetch=' in line for line in lines),expected_records,'http_fetch tape record count')
    shim=None
    if sys.platform=='linux': shim=compile_shim(folder,'replay-no-curl',NO_CURL_SHIM)
    replay_env={**(extra or {}),'EIGS_REPLAY':str(trace)}
    if shim: replay_env['LD_PRELOAD']=preload_for(binary,shim)
    replayed=program(binary,folder,source,replay_env,name='replay')
    equal(replayed,recorded,'tape output byte-for-byte')
    return recorded,source,trace


def tape_three(binary,folder,version):
    if sys.platform!='linux': raise Skipped('Linux loader shim for stopped-listener replay')
    closed=pick_port()
    source=DESCRIBE+call_source({'url':'PEER_URL/ok'})+call_source({'url':'PEER_URL/not-found'})+call_source({'url':f'http://127.0.0.1:{closed}/'})
    output,_,_=tape_program(binary,folder,source,[Plan(response(b'yes')),Plan(response(b'no',404))],expected_records=3)
    values=[json.loads(line) for line in output.splitlines()]
    expect_answer(values[0],answer_reference(response(b'yes')))
    expect_answer(values[1],answer_reference(response(b'no',404)))
    expect_error(values[2],'io','could not connect (curl error 7)')


def tape_refusals(binary,folder,version):
    kinds=refusal_arguments('PEER_URL/')
    require(any(name.startswith('connection-') and any(k.lower()=='connection' for k in arg['headers']) for name,arg in kinds),'tape refusals: no call gives a Connection')
    source=DESCRIBE+''.join(call_source(arg) for name,arg in kinds)
    output,_,_=tape_program(binary,folder,source,[Plan()],expected_records=0)
    equal(len(output.splitlines()),120,'argument-only refusal tape calls')


def tape_large(binary,folder,version):
    for n,limit in ((1000000,DEFAULT_BODY_LIMIT),(1001,1000)):
        own=folder/str(n);own.mkdir()
        count=128 if n>limit else 1
        source=DESCRIBE+call_source({'url':'PEER_URL/'})*count
        output,_,_=tape_program(binary,own,source,[Plan(response(b'x'*n)) for _ in range(count)],{'EIGS_HTTP_FETCH_MAX_BODY':str(limit)},expected_records=count)
        values=[json.loads(line) for line in output.splitlines()]
        equal(len(values),count,'large/limit tape compared calls')
        for value in values:
            if n>limit: expect_error(value,'limit',f"the answer's body is longer than {limit} bytes (EIGS_HTTP_FETCH_MAX_BODY)")
            else: expect_answer(value,answer_reference(response(b'x'*n)))


def tape_kinds_docs(binary,folder,version):
    proc=subprocess.run(['bash',str(ROOT/'tools/tape_kinds_check.sh')],cwd=ROOT,capture_output=True,timeout=60)
    clean(proc.stdout+proc.stderr)
    require(proc.returncode==0,f'tape kinds exit={proc.returncode}: {(proc.stdout+proc.stderr).decode()}')
    text=(ROOT/'docs/TRACE.md').read_text()
    require('`http_fetch`' in text and '`http_post`' in text,'TRACE docs names')
    require('kind' in text and 'error' in text,'TRACE docs error records')


def post_content_type(binary,folder,version):
    for headers,expected in [({},'application/x-www-form-urlencoded'),({'content-type':'custom/type'},'custom/type')]:
        with Peer() as peer:
            run_calls(binary,folder,[[peer.url+'/',json.dumps(headers),'x']],legacy=True)
            equal([(k.lower(),v) for k,v in peer.requests[0]['headers'] if k.lower()==b'content-type'],[(b'content-type',expected.encode())],'legacy Content-Type')


def post_glob(binary,folder,version):
    with Peer() as peer:
        run_calls(binary,folder,[[peer.url+'/g{a,b}','{}','x']],legacy=True)
        equal(len(peer.requests),1,'post glob one request')
        equal(peer.requests[0]['line'],b'POST /g{a,b} HTTP/1.1','post literal glob')


def post_arguments_tape(binary,folder,version):
    good=[['ftp://x/','','b'],['ftp://x/',5,'b'],['http://127.0.0.1:1/']]
    bad=[['http://127.0.0.1:1/',5,'b'],['http://127.0.0.1:1/','{}',7],
         ['http://127.0.0.1:1/','"just-a-string"','b'],['http://127.0.0.1:1/','["X-A","1","X-B"]','b']]
    # The connection's names, refused from the argument alone (amendment 3).
    connection=['{"Connection": "close"}','["connection", ""]','{"Keep-Alive": "timeout=1"}',
                '["proxy-connection", "close"]','{"TE": "trailers"}','["upgrade", "h2c"]']
    with Peer() as peer:
        bad+=[[peer.url+'/',text,'b'] for text in connection]
        source=DESCRIBE+''.join(call_source(arg,True) for arg in good+bad)
        trace=folder/'post.tape'
        out=program(binary,folder,source,{'EIGS_TRACE':str(trace)},name='record')
        values=[json.loads(line) for line in out.splitlines()]
        equal(len(values),len(good)+len(bad),'post argument compared calls')
        for value in values[:3]: equal(value,['body',0,hashlib.sha256(b'').hexdigest()],'post legacy empty')
        for value,kind in zip(values[3:],('type_mismatch','type_mismatch','type_mismatch','value')+('value',)*6): expect_error(value,kind,prefix='http_post')
        equal(sum(b' http_post=' in line for line in trace.read_bytes().splitlines()),3,'legacy malformed calls tape count')
        equal(program(binary,folder,source,{'EIGS_REPLAY':str(trace)},name='replay'),out,'post argument replay')
        equal(peer.accepted,0,'post connection names: listener connections')
    with Peer() as peer:
        extra=[peer.url+'/','{}','x','ignored']
        value=run_calls(binary,folder,[extra],legacy=True)[0]
        equal(value,['body',2,hashlib.sha256(b'ok').hexdigest()],'post ignores surplus default argument')
        strict=run_calls(binary,folder,[extra],{'EIGS_STRICT':'1'},legacy=True)[0]
        equal(strict[:2],['error','type_mismatch'],'post surplus strict argument kind')
        equal(peer.accepted,1,'strict surplus sends nothing')


def post_integer_header(binary,folder,version):
    with Peer() as peer:
        run_calls(binary,folder,[[peer.url+'/','{"X-Int":9007199254740993}','x']],legacy=True)
        equal([(k,v) for k,v in peer.requests[0]['headers'] if k==b'X-Int'],[(b'X-Int',b'9007199254740993')],'JSON int preserves every digit')
    variants=[('{"X-True":true,"X-Null":null,"X-List":[1,2]}',[(b'X-True',b'true'),(b'X-Null',b'null'),(b'X-List',b'[1, 2]')]),
        ('[123,true,"X-B",null]',[(b'123',b'true'),(b'X-B',b'null')]),
        ('{"X-First":"old","X-B":"2","X-First":"new"}',[(b'X-First',b'new'),(b'X-B',b'2')]),
        ('{"X\\r\\nA":"v\\r\\nv"}',[(b'XA',b'vv')])]
    for encoded,expected in variants:
        with Peer() as peer:
            run_calls(binary,folder,[[peer.url+'/',encoded,'x']],legacy=True)
            wanted={k.lower() for k,v in expected}
            equal([(k,v) for k,v in peer.requests[0]['headers'] if k.lower() in wanted],expected,'post JSON conversion/sanitization/order')


def sandbox(binary,folder,version):
    contract=(ROOT/'tests/test_vm_run_bytecode.eigs').read_text()
    call=int(re.search(r'^CALL is (\d+)$',contract,re.M).group(1))
    with Peer([Plan(),Plan()]) as peer:
        arguments=[{'url':peer.url+'/'},[peer.url+'/','{}','x']]
        source='sandbox_args is '+eigs(arguments)+'\n'
        source+='names is ["http_fetch", "http_post"]\nidx is 0\nloop while idx < 2:\n'
        source+='    name is names[idx]\n    desc is [1, [25,0,0, 0,1,0, '+str(call)+',1,0, 40], [name, sandbox_args[idx]]]\n'
        source+='    result is sandbox_run of [desc, 1000]\n    print of (json_encode of [name, result.ok])\n    idx is idx + 1\n'
        # Same descriptors and argument shapes through safe names prove the
        # refusal is the HTTP capability, not an invalid descriptor/call.
        source+='for pair in [["keys", sandbox_args[0]], ["len", sandbox_args[1]]]:\n'
        source+='    control is sandbox_run of [[1, [25,0,0, 0,1,0, '+str(call)+',1,0, 40], pair], 1000]\n'
        source+='    assert of [control.ok, "sandbox descriptor control"]\n'
        equal([json.loads(line) for line in program(binary,folder,source).splitlines()],[['http_fetch',False],['http_post',False]],'sandbox outbound capability refusal')
        equal(peer.accepted,0,'sandbox opens no connection')


def documentation_api(binary,folder,version):
    api=subprocess.check_output([binary,'--api']).decode()
    require(re.search(r'\bhttp_fetch\b',api) is not None,'http_fetch absent from --api')
    docs=(ROOT/'docs/BUILTINS.md').read_text()
    for word in ('http_fetch','http_post','EIGS_HTTP_FETCH_MAX_BODY','CURL_CA_BUNDLE','SSL_CERT_FILE','SSL_CERT_DIR','libcurl.so','libcurl.4.dylib','SSLKEYLOGFILE','OPENSSL_CONF','OPENSSL_FORCE_FIPS_MODE','OPENSSL_FIPS_MODE_SWITCH_PATH','OPENSSL_ia32cap','GNUTLS_','NETTLE_','P11_KIT_','HOSTALIASES','LOCALDOMAIN','RES_OPTIONS','GNUTLS_DEBUG_LEVEL','NETTLE_FAT_VERBOSE','P11_KIT_DEBUG'):
        require(word in docs,'BUILTINS docs missing '+word)
    security=(ROOT/'SECURITY.md').read_text()
    for word in ('http_fetch','http_post','127.1','0x7f.0.0.1','2130706433','SSLKEYLOGFILE','HOSTALIASES'):
        require(word in security,'SECURITY docs missing '+word)


def short_names(n):
    digits='0123456789abcdefghijklmnopqrstuvwxyz'
    return [digits[i//1296]+digits[(i//36)%36]+digits[i%36] for i in range(n)]


def cost_pair(binary,folder,kind):
    if kind=='body':
        smallplan=Plan(response(b'x'*1000000),piece=16384)
        largeplan=Plan(response(b'x'*16000000),piece=16384)
        smallarg={};largearg={};bound=48
    elif kind=='request-headers':
        smallplan=largeplan=Plan()
        smallarg={'headers':{name:'' for name in short_names(1170)}}
        largearg={'headers':{name:'' for name in short_names(9362)}};bound=16
    else:
        duplicate=kind=='answer-duplicates'
        def wire(n):
            names=['dup']*n if duplicate else short_names(n)
            head=b''.join(name.encode()+b': x\r\n' for name in names)
            equal(len(head),n*8,'cost response header fixture bytes')
            return b'HTTP/1.1 200 OK\r\n'+head+b'Content-Length: 0\r\n\r\n'
        # 4,000 lines (and Content-Length) stay under the runtime's 4,096 and
        # under the 5,000 of the curl library from 8.14.0.
        smallplan=Plan(wire(500));largeplan=Plan(wire(4000))
        smallarg={};largearg={};bound=None if duplicate else 10
    with Peer([smallplan],repeat=True) as smallpeer,Peer([largeplan],repeat=True) as largepeer:
        smallarg['url']=smallpeer.url+'/';largearg['url']=largepeer.url+'/'
        source='small is '+eigs(smallarg)+'\nlarge is '+eigs(largearg)+'\nsmall_times is []\nlarge_times is []\ni is 0\nloop while i < 7:\n'
        for parity in (0,1):
            source+=('    if' if parity==0 else '    else')+(' i % 2 == 0:\n' if parity==0 else ':\n')
            for label in (('small','large') if parity==0 else ('large','small')):
                source+='        started is monotonic_ns of null\n        answer is http_fetch of '+label+'\n'
                source+='        append of ['+label+'_times, (monotonic_ns of null) - started]\n'
                source+='        assert of [answer.status == 200, "cost answer status"]\n'
                # Pin the work after the elapsed sample has been stored, so
                # an incomplete answer cannot make a cost row look fast.
                large_case=label=='large'
                if kind=='body':
                    size=16000000 if large_case else 1000000
                    digest=hashlib.sha256(b'x'*size).hexdigest()
                    source+='        assert of [(len of answer.body) == '+str(size)+', "cost body length"]\n'
                    source+='        assert of [(sha256 of answer.body) == '+eigs(digest)+', "cost body SHA256"]\n'
                elif kind=='request-headers':
                    source+='        assert of [answer.body == "ok" and (len of (keys of answer.headers)) == 1 and answer.headers["content-length"] == "2", "cost request-header answer"]\n'
                else:
                    n=4000 if large_case else 500
                    source+='        assert of [answer.body == "" and answer.headers["content-length"] == "0", "cost answer framing"]\n'
                    if kind=='answer-duplicates':
                        digest=hashlib.sha256(b', '.join([b'x']*n)).hexdigest()
                        source+='        assert of [(len of (keys of answer.headers)) == 2 and (len of answer.headers.dup) == '+str(3*n-2)+', "cost duplicate header count/length"]\n'
                        source+='        assert of [(sha256 of answer.headers.dup) == '+eigs(digest)+', "cost duplicate header SHA256"]\n'
                    else:
                        source+='        assert of [(len of (keys of answer.headers)) == '+str(n+1)+', "cost distinct header count"]\n'
                        source+='        for field_name in (keys of answer.headers):\n            if field_name != "content-length":\n                assert of [answer.headers[field_name] == "x", "cost distinct header value"]\n'
        source+='    i is i + 1\nprint of (json_encode of [small_times,large_times])\n'
        small,large=json.loads(program(binary,folder,source,timeout=180).decode())
        equal(len(small),7,'cost small sample count');equal(len(large),7,'cost large sample count')
        equal(len(smallpeer.requests),7,'cost small requests');equal(len(largepeer.requests),7,'cost large requests')
        if kind=='request-headers':
            version=subprocess.check_output([binary,'--version'],env=environment()).decode().strip()
            for record in smallpeer.requests: check_wire(record,request_reference(smallarg,version))
            for record in largepeer.requests: check_wire(record,request_reference(largearg,version))
        ratio=statistics.median(large)/statistics.median(small)
        print(f'COST {kind} small_ns={statistics.median(small)} large_ns={statistics.median(large)} ratio={ratio:.9f} small_samples={small} large_samples={large}',flush=True)
        if bound is not None: require(ratio<=bound,f'{kind} ratio={ratio} > {bound}')


def rss_kb(pid):
    text=Path(f'/proc/{pid}/status').read_text()
    return int(re.search(r'^VmRSS:\s*(\d+) kB$',text,re.M).group(1))


def leak_row(binary,folder,version,failure=False):
    if not Path('/proc/self/status').is_file(): raise Skipped('Linux RSS requires /proc')
    raw=Path(binary).read_bytes()
    if b'__asan_init' in raw or b'__tsan_init' in raw: raise Skipped('RSS is not judged on sanitizer builds')
    headers={f'X-{i:03}':f'v{i:03}' for i in range(8)}
    post_headers={f'X-{i:02}'+('N'*60):'v'*64 for i in range(8)}
    require(all(len(k)==64 and len(v)==64 for k,v in post_headers.items()),'RSS legacy header sizes')
    normal=response(b'x',headers=[(f'X-{i:03}'.encode(),b'four') for i in range(16)])
    nul=response(b'\0',headers=[(f'X-{i:03}'.encode(),b'four') for i in range(16)])
    def choose(record):
        return nul if record['line'].split(b' ')[1]==b'/nul' else normal
    spool=folder/'peer-requests.bin'
    with Peer([Plan(normal)],repeat=True,record_path=spool,responder=choose) as peer:
        destination=f'http://127.0.0.1:{pick_port()}/' if failure else peer.url+'/'
        request={'url':destination,'headers':headers}
        attempts=1500 if failure else 66
        code='local req is '+eigs(request)+'\nlocal idx is 0\nloop while idx < '+str(attempts)+':\n'
        if failure:
            code+='    try:\n        http_fetch of req\n        throw of "RSS connect unexpectedly succeeded"\n    catch problem:\n'
            code+='        assert of [problem.kind == "io" and problem.message == "http_fetch: could not connect (curl error 7)", "RSS error kind/message"]\n'
        else:
            code+='    reply is http_fetch of req\n    assert of [reply.status == 200 and reply.body == "x", "RSS fetch answer"]\n'
        code+='    idx is idx + 1\n'
        if not failure:
            postarg=[peer.url+'/',json.dumps(post_headers),'x']
            code+='idx is 0\nloop while idx < 9:\n    reply is http_post of ('+eigs(postarg)+')\n    assert of [reply == "x", "RSS post answer"]\n    idx is idx + 1\n'
            code+='idx is 0\nloop while idx < 2:\n    try:\n        http_fetch of {"url": '+eigs(peer.url+'/nul')+'}\n        throw of "RSS NUL unexpectedly succeeded"\n    catch problem:\n'
            code+='        assert of [problem.kind == "io" and problem.message == "http_fetch: the answer holds a NUL byte, which text cannot carry", "RSS NUL error"]\n    idx is idx + 1\n'
            wrong_shape=json.dumps('x'*8192)
            odd=json.dumps(['abcdefgh']*1001)
            overflow='{"pad":'+json.dumps('x'*8192)+',"n":1e400}'
            malformed='{"pad":'+json.dumps('x'*8192)+'} trailing-junk'
            for encoded,kind in ((wrong_shape,'type_mismatch'),(odd,'value'),(overflow,'value')):
                arg=[peer.url+'/',encoded,'x']
                code+='try:\n    http_post of ('+eigs(arg)+')\n    throw of "RSS malformed argument unexpectedly succeeded"\ncatch problem:\n    assert of [problem.kind == '+eigs(kind)+', "RSS malformed argument kind"]\n'
            code+='reply is http_post of ('+eigs([peer.url+'/',malformed,'x'])+')\nassert of [reply == "x", "RSS malformed JSON no-header fallback"]\n'
        code+='"ok"'
        extra={'EIGS_TRACE':'/dev/null'} if failure else None
        with runtime_server(binary,folder,code,extra) as (proc,port):
            initial=rss_kb(proc.pid)
            for index in range(100):
                equal(raw_runtime(port).split(b'\r\n\r\n',1)[1],b'ok','RSS warmup answer')
                if (index+1)%10==0:
                    growth=rss_kb(proc.pid)-initial
                    print(f'RSS_PROGRESS fetch-{"error" if failure else "success"} warmup={index+1}/100 growth_kb={growth}',flush=True)
                    require(growth<=65536,f'HTTP fetch RSS warmup grew {growth} kB > 65536 kB after {index+1} requests')
            before=rss_kb(proc.pid)
            for index in range(2000):
                equal(raw_runtime(port).split(b'\r\n\r\n',1)[1],b'ok','RSS measured answer')
                if (index+1)%20==0:
                    growth=rss_kb(proc.pid)-before
                    if (index+1)%100==0:
                        print(f'RSS_PROGRESS fetch-{"error" if failure else "success"} measured={index+1}/2000 growth_kb={growth}',flush=True)
                    require(growth<=8192,f'HTTP fetch RSS grew {growth} kB > 8192 kB early bound after {index+1} measured requests')
            after=rss_kb(proc.pid)
            growth=after-before
            print(f'RSS fetch-{"error" if failure else "success"} before_kb={before} after_kb={after} growth_kb={growth} requests=2000 threshold_kb=4096',flush=True)
            require(growth<=4096,f'HTTP fetch {"error" if failure else "success"} RSS grew {growth} kB > 4096 kB')
        equal(peer.record_count,0 if failure else 78*2100,'RSS raw peer recorded call count')
        require(not peer.errors,f'RSS peer errors: {peer.errors}')


def preload_for(binary,shim):
    # ASan requires its runtime first even when a test interposes dlopen.
    # Inspect the actual candidate linkage; compiler selection may differ.
    proc=subprocess.run(['ldd',binary],capture_output=True,text=True,timeout=10)
    require(proc.returncode==0,'ldd could not inspect shim candidate: '+proc.stderr)
    runtimes=re.findall(r'^\s*lib(?:asan|tsan)[^ ]* => ([^ ]+)',proc.stdout,re.M)
    return ':'.join(runtimes+[str(shim)])


def keylog(binary,folder,version):
    if not shutil.which('openssl'): raise Skipped('openssl is unavailable')
    import ssl
    cert=folder/'listener.pem';key=folder/'listener.key';config=folder/'listener.cnf'
    config.write_text('[req]\ndistinguished_name=dn\nx509_extensions=ext\nprompt=no\n[dn]\nCN=127.0.0.1\n[ext]\nsubjectAltName=IP:127.0.0.1\nbasicConstraints=critical,CA:TRUE\n')
    proc=subprocess.run(['openssl','req','-x509','-newkey','rsa:2048','-nodes','-days','1','-config',str(config),'-keyout',str(key),'-out',str(cert)],capture_output=True,timeout=30)
    require(proc.returncode==0,'keylog certificate generation: '+proc.stderr.decode())
    tls=ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER);tls.load_cert_chain(cert,key)
    statuses=[]
    for i in range(5):
        audit=folder/f'keylog-run-{i}'
        audit.mkdir()
        extra={'HOME':str(audit),'CURL_CA_BUNDLE':str(cert)}
        if i in (0,4): extra['SSLKEYLOGFILE']=str(audit/'secrets.log')
        if i==2: extra['SSLKEYLOGFILE']=''
        if i==3: extra['SSLKEYLOGFILE']=str(audit/'absent'/'secrets.log')
        if i==4:
            equal(program(binary,folder,'print of "no call"\n',extra,name='keylog-no-call'),b'no call\n','keylog no-call program')
        else:
            with Peer([Plan(response(b'trusted'))],tls=tls) as peer:
                source='answer is http_fetch of {"url": '+eigs(peer.url+'/')+'}\nprint of answer.status\n'
                statuses.append(program(binary,folder,source,extra,name=f'keylog-call-{i}'))
                equal(len(peer.requests),1,'keylog TLS listener request')
                require(not peer.errors,f'keylog TLS peer errors: {peer.errors}')
        if i==0:
            equal(sorted(p.name for p in audit.iterdir()),['secrets.log'],'keylog sole output file')
            lines=(audit/'secrets.log').read_bytes().splitlines()
            require(len(lines)>0,'TLS key log contains no lines')
            print(f'KEYLOG fresh_process={i+1} lines={len(lines)} files=1',flush=True)
        else:
            equal(list(audit.iterdir()),[],f'keylog fresh process {i+1} creates no file')
            print(f'KEYLOG fresh_process={i+1} files=0',flush=True)
        shutil.rmtree(audit)
    equal(statuses,[b'200\n']*4,'keylog first four runs have same status')


def no_temp_files(binary,folder,version):
    # Also perform one exchange when selected alone for a source plant.
    one_request(binary,folder,{},version)
    equal(list(RUNTIME_TMP.iterdir()),[],'whole-run runtime TMPDIR remains empty')


ROWS=[
    ('dealt-arrives',dealt_arrives),('dealt-refused',dealt_refused),('dealt-answers',dealt_answers),
    ('defaults',defaults),('target-literal',target_literal),('host-order',host_order),
    ('one-connection-each',one_connection_each),
    ('request-body',request_body),('request-headers',request_headers),('request-limit',request_limit),
    ('curlrc',curlrc),('userinfo',userinfo),('statuses-no-redirect',statuses),
    ('answer-join-order',join_order),('interim-trailer',interim_trailer),('answer-body-sizes',answer_sizes),
    ('answer-header-limit',answer_header_limit),
    ('answer-lines-edge',answer_lines_edge),('answer-lines-6000',answer_lines_6000),('answer-lines-both',answer_lines_both),
    ('answer-lines-interim',answer_lines_interim),('answer-lines-trailer',answer_lines_trailer),
    ('answer-status-like-many',status_like_many),('answer-status-like-wide',status_like_wide),
    ('answer-status-like-neighbours',status_like_neighbours),
    ('limit-endless-and-head',immediate_limit_head),
]+[(f'body-env-{i:02}',lambda *args,s=setting:body_environment(*args,s)) for i,setting in enumerate(BODY_ENV_VALUES)]+[
    ('keylog',keylog),('https-certificates',https_certificates),('connection-errors',connection_errors),('timeouts',timeouts),
    ('default-timeouts',default_timeouts),('early-answers',early_answers),('nul-body',nul_body),('nul-header',nul_header),
    ('no-library',no_library),('refused-option',refused_option),('timeout-edges',timeout_edges),
    ('no-child',no_children),('concurrent-calls',concurrent_calls),('tape-three',tape_three),
    ('tape-refusals',tape_refusals),('tape-large-limit',tape_large),('tape-kinds-docs',tape_kinds_docs),
]+[row for row in BASE_ROWS if row[0]!='POST-cost200x100']+[
    ('POST-content-type',post_content_type),('POST-literal-glob',post_glob),('POST-arguments-tape',post_arguments_tape),
    ('POST-integer-header',post_integer_header),('sandbox',sandbox),('documentation-api',documentation_api),
    ('cost-body',lambda b,f,v:cost_pair(b,f,'body')),
    ('cost-request-headers',lambda b,f,v:cost_pair(b,f,'request-headers')),
    ('cost-answer-headers',lambda b,f,v:cost_pair(b,f,'answer-headers')),
    ('cost-answer-duplicates',lambda b,f,v:cost_pair(b,f,'answer-duplicates')),
    ('POST-cost200x100',baseline_cost),('no-temp-files',no_temp_files),
]
LEAK_ROWS=[('leak-success',leak_row),('leak-error',lambda *a:leak_row(*a,failure=True))]

if __name__ == '__main__':
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(143))
    sys.exit(main())
