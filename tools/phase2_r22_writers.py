#!/usr/bin/env python3
"""One-time R2.2 observations for R2.3; run on hosted CI, never changes writers.

Records answers and caught refusals without freezing today's incomplete writer
policy. Signals, sanitizer reports, missing completion and undefined builtins
are failed measurements. Existing phase2 reader fixtures cover DB parameters,
net_send, byte/index conversion and gfx/audio sinks under release and ASan.
"""
import argparse
import json
import hashlib
import os
from pathlib import Path
import socket
import subprocess
import tempfile
import time
import urllib.request

MARKER = 'R22-WRITER-DONE'


def valid(rc, stdout, stderr):
    return (rc == 0 and stdout.splitlines().count(MARKER) == 1 and
            'undefined_name' not in stdout and not any(x in stdout + stderr for x in
            ('AddressSanitizer', 'UndefinedBehaviorSanitizer', 'runtime error:', 'ThreadSanitizer')))


def selftest():
    cases = [(0, MARKER + '\n', '', True), (-11, '', '', False),
             (0, MARKER + '\n', 'runtime error: invalid cast', False),
             (0, 'early exit\n', '', False),
             (0, 'undefined_name\n' + MARKER + '\n', '', False)]
    for rc, out, err, want in cases:
        if valid(rc, out, err) != want:
            raise ValueError('observation classifier failed its control')
    print('R22_WRITER_SELFTEST: 5 passed, 0 failed')


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--selftest', action='store_true')
    ap.add_argument('--binary', type=Path)
    ap.add_argument('--server', type=Path)
    ap.add_argument('--output', type=Path)
    a = ap.parse_args()
    if a.selftest:
        selftest()
        return 0
    if not (a.binary and a.server and a.output):
        ap.error('--binary --server --output required')
    binary, server = a.binary.resolve(), a.server.resolve()
    a.output.parent.mkdir(parents=True, exist_ok=True)
    env = {k: v for k, v in os.environ.items() if not k.startswith('EIGS_') and
           k not in ('XAUTHORITY', 'LD_PRELOAD', 'LD_AUDIT')}
    env['PATH'] = ':'.join(p for p in env['PATH'].split(':') if p and not Path(p).expanduser().is_relative_to(Path.home() / '.local/bin'))
    env.update(EIGS_STRICT='0', DISPLAY=':99', SDL_AUDIODRIVER='dummy')
    provenance = {'head': os.environ.get('GITHUB_SHA', ''),
        'binary_sha256': hashlib.sha256(binary.read_bytes()).hexdigest(),
        'server_sha256': hashlib.sha256(server.read_bytes()).hexdigest()}
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    rows = []
    def save():
        a.output.write_text(json.dumps({'round': 'R2.2', 'provenance': provenance, 'observations': rows,
            'reader_sink_proofs': 'Hosted phase2_readers release/asan: db params, net_send, byte/index and gfx/audio consumers',
            'valid_measurements': all(r['valid'] for r in rows)}, indent=2) + '\n')
    scalar = {
        'json-scalar': 'json_encode of n', 'json-list': 'json_encode of ([n])',
        'json-dict': 'json_encode of {"n": n}', 'json-build': 'json_build of ["n", n]',
        'f64-to-bytes': 'f64_to_bytes of n', 'str-from-bytes': 'str_from_bytes of ([n])',
        'write-bytes': 'write_bytes of [p + "/bytes.bin", [n]]',
        'chr': 'chr of n', 'hex': 'hex of n', 'exit-integer': 'exit of n',
        'buffer-count': 'buffer of n'}
    with tempfile.TemporaryDirectory(prefix='r22-writers-', dir=a.output.parent) as temp:
        scratch = Path(temp)
        env['EIGS_PROBE_TMP'] = temp
        for kind, expr, start, nan in [('nan', '0.0 / 0.0', '1e308', True),
                ('inf', '1.0 / 0.0', '1e308', False), ('negative-inf', '-1.0 / 0.0', '-1e308', False)]:
            pre = f'n is {expr}\np is env_get of "EIGS_PROBE_TMP"\n'
            buffer = f'b is buf_from_list of ([{start}])\nbuf_scale_range of [b, 0, 1, 1e308]\n'
            if nan:
                buffer += 'buf_scale_range of [b, 0, 1, 0.0]\n'
            cases = {name: pre + 'try:\n    answer is ' + call + '\n    print of ["answer", type of answer, answer]\ncatch e:\n    print of ["error", e.kind, e.message]\n'
                     for name, call in scalar.items()}
            for name, call in [('pcm', 'buf_to_pcm16le of [b, 0, 1]'),
                    ('buffer-write-bytes', 'write_bytes of [p + "/buffer.bin", b]'),
                    ('buffer-json', 'json_encode of b')]:
                cases[name] = pre + buffer + 'try:\n    answer is ' + call + '\n    print of ["answer", type of answer, answer]\ncatch e:\n    print of ["error", e.kind, e.message]\n'
            for name, statement in [('buffer-index-store', 'b[0] is n'),
                    ('buf-set', 'buf_set of [b, 0, n]')]:
                cases[name] = pre + 'b is buffer of 1\nb[0] is 42.0\noutcome is "answered"\ntry:\n    ' + statement + '\ncatch e:\n    outcome is e.kind\nprint of [outcome, b[0]]\n'
            for name, value in [('store-scalar', 'n'), ('store-buffer', 'b')]:
                cases[name] = pre + buffer + f's is store_open of (p + "/{kind}-{name}.db")\ntry:\n    key is store_put of [s, "r22", {{"n": {value}}}]\n    print of ["stored", key]\n    print of ["loaded", store_get of [s, "r22", key]]\ncatch e:\n    print of ["error", e.kind, e.message]\nstore_close of s\n'
            for name, source in cases.items():
                program = scratch / 'probe.eigs'
                program.write_text(source + f'print of "{MARKER}"\n')
                try:
                    r = subprocess.run([str(binary), str(program)], env=env, capture_output=True, text=True, timeout=30)
                    rc, out, err = r.returncode, r.stdout, r.stderr
                except subprocess.TimeoutExpired as error:
                    rc, out, err = 124, str(error.stdout or ''), str(error.stderr or '')
                rows.append(dict(writer=name, value=kind, source_sha256=hashlib.sha256(program.read_bytes()).hexdigest(), rc=rc, stdout=out, stderr=err, valid=valid(rc, out, err)))
                save()
        # Standard owned HTTP fixture: observe state after the existing encoder
        # error, without repairing or asserting the R2.3 side-effect policy.
        with socket.socket() as chooser:
            chooser.bind(('127.0.0.1', 0))
            port = chooser.getsockname()[1]
        routes = []
        for kind, expr in [('nan', '0.0 / 0.0'), ('inf', '1.0 / 0.0'), ('negative-inf', '-1.0 / 0.0')]:
            code = f'shared_set of ["r22", 42]\noutcome is "answered"\ntry:\n    shared_set of ["r22", {expr}]\ncatch e:\n    outcome is e.kind\nstr of [outcome, shared_get of "r22"]'
            routes.append((kind, code))
        routes.append(('incr', 'shared_set of ["r22", 1e308]\noutcome is "answered"\ntry:\n    shared_incr of ["r22", 1e308]\ncatch e:\n    outcome is e.kind\nstr of [outcome, shared_get of "r22"]'))
        source = '\n'.join('http_route of ["GET", "/' + name + '", "code", ' + json.dumps(code) + ']' for name, code in routes)
        program = scratch / 'server.eigs'
        program.write_text(source + '\nhttp_serve of ' + str(port) + '\n')
        provenance['server_source_sha256'] = hashlib.sha256(program.read_bytes()).hexdigest()
        with (scratch / 'server.log').open('w+') as log:
            child = subprocess.Popen([str(server), str(program)], env=env, stdout=log, stderr=log)
            try:
                ready = False
                for _ in range(100):
                    if child.poll() is not None:
                        break
                    try:
                        with socket.create_connection(('127.0.0.1', port), timeout=.1):
                            ready = True
                            break
                    except OSError:
                        time.sleep(.05)
                if not ready:
                    rows.append(dict(writer='shared-state', valid=False, error='owned HTTP fixture did not become ready'))
                else:
                    for name, _ in routes:
                        try:
                            with opener.open(f'http://127.0.0.1:{port}/{name}', timeout=10) as response:
                                body = response.read().decode()
                                rows.append(dict(writer='shared-incr' if name == 'incr' else 'shared-set', value=name,
                                                 http_status=response.status, body=body, valid=response.status == 200 and 'undefined_name' not in body))
                        except Exception as error:
                            rows.append(dict(writer='shared-state', value=name, valid=False, error=str(error)))
            finally:
                if child.poll() is None:
                    child.terminate()
                else:
                    rows.append(dict(writer='shared-state-process', valid=False,
                                     rc=child.returncode, error='owned server exited before cleanup'))
                try:
                    child.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    child.kill()
                    child.wait()
                    rows.append(dict(writer='shared-state-cleanup', valid=False, error='owned PID did not terminate'))
            log.seek(0)
            text = log.read()
            if any(token in text for token in ('AddressSanitizer', 'runtime error:', 'UndefinedBehaviorSanitizer')):
                rows.append(dict(writer='shared-state-sanitizer', valid=False, stderr=text))
            save()
    for row in rows:
        print(json.dumps(row, sort_keys=True))
    print('R22_WRITERS: observations=%d valid=%s (R2.3 input; not a writer-policy approval)' %
          (len(rows), all(row['valid'] for row in rows)))
    return int(not all(row['valid'] for row in rows))


if __name__ == '__main__':
    raise SystemExit(main())
