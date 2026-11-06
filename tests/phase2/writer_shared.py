#!/usr/bin/env python3
"""R23-1: real HTTP shared-state callers may not mutate after encoder refusal.

Each route catches the real error and reads state back. No fault injection,
mock server, replacement encoder or changed JSON parser is used. The owned
server is terminated after observation; this test does not claim LSan exit
coverage for that process (the C writer fixture has normal state teardown).
"""
import argparse
import json
import os
from pathlib import Path
import socket
import subprocess
import tempfile
import time
import urllib.request


def cases():
    work = []
    numbers = [('nan', '0.0 / 0.0'), ('inf', '1.0 / 0.0'),
               ('negative-inf', '-1.0 / 0.0')]
    for number, expression in numbers:
        for shape in ['scalar', 'list', 'dict', 'buffer', 'nested-buffer']:
            setup = ''
            value = expression
            if shape == 'list':
                value = '[7, ' + expression + ']'
            elif shape == 'dict':
                value = '{"finite": 7, "value": ' + expression + '}'
            elif shape in ['buffer', 'nested-buffer']:
                setup = ('b is buf_from_list of ([1e308])\n'
                         'buf_scale_range of [b, 0, 1, 1e308]\n')
                if number == 'nan':
                    setup += 'buf_scale_range of [b, 0, 1, 0.0]\n'
                elif number == 'negative-inf':
                    setup += 'buf_scale_range of [b, 0, 1, -1.0]\n'
                value = 'b' if shape == 'buffer' else '[7, b]'
            code = ('shared_set of ["present", 42]\n' + setup +
                    'outcome is "answered"\ntry:\n'
                    '    shared_set of ["present", ' + value + ']\n'
                    'catch e:\n    outcome is e.kind\n'
                    'str of [outcome, (shared_get of "present") == 42]')
            work.append(('set-' + shape + '-' + number, code, ['value', True]))
        code = ('shared_delete of "absent"\noutcome is "answered"\ntry:\n'
                '    shared_set of ["absent", ' + expression + ']\n'
                'catch e:\n    outcome is e.kind\n'
                'str of [outcome, shared_has of "absent"]')
        work.append(('set-missing-' + number, code, ['value', False]))
    for number, seed in [('positive', '1e308'), ('negative', '-1e308')]:
        code = ('shared_set of ["present", ' + seed + ']\n'
                'outcome is "answered"\ntry:\n'
                '    shared_incr of ["present", ' + seed + ']\n'
                'catch e:\n    outcome is e.kind\n'
                'str of [outcome, (shared_get of "present") == ' + seed + ']')
        work.append(('incr-overflow-' + number, code, ['value', True]))
    # Already-refusing input readers and successful writes are controls.
    for number, expression in numbers:
        code = ('shared_set of ["present", 42]\noutcome is "answered"\ntry:\n'
                '    shared_incr of ["present", ' + expression + ']\n'
                'catch e:\n    outcome is e.kind\n'
                'str of [outcome, (shared_get of "present") == 42]')
        work.append(('incr-input-control-' + number, code, ['value', True]))
    work.append(('finite-control',
                 'shared_set of ["present", 42]\n'
                 'str of [(shared_incr of ["present", 1]) == 43, '
                 '(shared_get of "present") == 43]', [True, True]))
    return work


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('binary', type=Path)
    parser.add_argument('--tier', choices=['off', 'default', 'osr'], default='default')
    parser.add_argument('--evidence', type=Path)
    args = parser.parse_args()
    binary = args.binary.resolve()
    env = {k: v for k, v in os.environ.items() if not k.startswith('EIGS_')}
    env['EIGS_STRICT'] = '0'
    if args.tier == 'off':
        env['EIGS_JIT_OFF'] = '1'
    elif args.tier == 'osr':
        env['EIGS_JIT_OSR_THRESHOLD'] = '1'
    work = cases()
    observed = []
    setup_error = None
    with tempfile.TemporaryDirectory(prefix='r23-shared-', dir=os.environ.get('TMPDIR')) as temp:
        scratch = Path(temp)
        with socket.socket() as chooser:
            chooser.bind(('127.0.0.1', 0))
            port = chooser.getsockname()[1]
        program = scratch / 'server.eigs'
        source = '\n'.join('http_route of ["GET", "/' + name + '", "code", ' +
                           json.dumps(code) + ']' for name, code, _ in work)
        program.write_text(source + '\nhttp_serve of ' + str(port) + '\n')
        with (scratch / 'server.log').open('w+') as log:
            child = subprocess.Popen([str(binary), str(program)], cwd=scratch,
                                     env=env, stdout=log, stderr=log)
            try:
                deadline = time.monotonic() + 15
                ready = False
                while time.monotonic() < deadline and child.poll() is None:
                    try:
                        with socket.create_connection(('127.0.0.1', port), timeout=.1):
                            ready = True
                            break
                    except OSError:
                        time.sleep(.025)
                if not ready:
                    setup_error = 'owned server failed readiness, rc=' + str(child.poll())
                else:
                    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
                    for name, _, expected in work:
                        row = dict(case=name, expected=expected)
                        try:
                            with opener.open(f'http://127.0.0.1:{port}/{name}', timeout=10) as response:
                                body = response.read().decode()
                                actual = json.loads(body)
                                row.update(status=response.status, actual=actual,
                                           passed=response.status == 200 and actual == expected)
                        except Exception as error:
                            row.update(error=str(error), passed=False)
                        observed.append(row)
                        print('writer-shared: ' + ('PASS ' if row['passed'] else 'FAIL ') +
                              name + ' ' + json.dumps(row, sort_keys=True), flush=True)
            finally:
                if child.poll() is None:
                    child.terminate()
                else:
                    setup_error = setup_error or ('owned server exited before cleanup, rc=' + str(child.returncode))
                try:
                    child.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    child.kill()
                    child.wait()
                    setup_error = setup_error or 'owned PID did not terminate'
            log.seek(0)
            server_log = log.read()
        if any(token in server_log for token in ('AddressSanitizer', 'runtime error:',
                                                 'UndefinedBehaviorSanitizer', 'LeakSanitizer')):
            setup_error = setup_error or 'sanitizer report in owned server log'
        if setup_error:
            print('writer-shared: SETUP FAIL ' + setup_error)
            print(server_log)
        result = dict(tier=args.tier, cases=len(work), observed=len(observed),
                      passed=sum(row['passed'] for row in observed),
                      failed=sum(not row['passed'] for row in observed),
                      setup_error=setup_error, rows=observed, server_log=server_log)
        if args.evidence:
            args.evidence.parent.mkdir(parents=True, exist_ok=True)
            args.evidence.write_text(json.dumps(result, indent=2) + '\n')
        print('writer-shared: cases=%d observed=%d passed=%d failed=%d setup=%s' %
              (result['cases'], result['observed'], result['passed'], result['failed'],
               'FAIL' if setup_error else 'ok'))
        return int(bool(setup_error) or result['observed'] != len(work) or result['failed'] != 0)


if __name__ == '__main__':
    raise SystemExit(main())
