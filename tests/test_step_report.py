#!/usr/bin/env python3
"""#294/#418: stepper p/t labels equal live report at the same moment."""
import argparse
import json
import os
import platform
from pathlib import Path
import re
import subprocess
import tempfile


def checked(argv, env, **kwargs):
    r = subprocess.run(argv, env=env, capture_output=True, text=True, timeout=30, **kwargs)
    if r.returncode or r.stderr:
        raise AssertionError((argv, r.returncode, r.stdout, r.stderr))
    return r.stdout


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('binary', type=Path)
    ap.add_argument('--out', type=Path)
    ap.add_argument('--diagnostics', type=Path)
    ap.add_argument('--require-native', action='store_true')
    args = ap.parse_args()
    binary = str(args.binary.resolve())
    base = {k: v for k, v in os.environ.items() if not k.startswith('EIGS_')}
    native_required = args.require_native or platform.machine().lower() in ('x86_64', 'amd64')
    rows, recordings = [], []
    with tempfile.TemporaryDirectory(prefix='step-report-') as tmp:
        tmp = Path(tmp)
        for fixture, step, count in [('nonzero', '1 + conv / 2', 40), ('halving', 'conv / 2', 60)]:
            source = ('osc is 1\nconv is 1024\nmsg is "hello"  # lint: allow W001 -- stepper fixture\nseed is random of null  # lint: allow W001 -- nondeterministic fixture\n'
                      f'for i in range of {count}:\n    osc is 0 - osc\n    conv is {step}\nprint of conv\n')
            twin = '\n'.join(line + ('\n' + line[:len(line)-len(line.lstrip())] +
                'print of (report of conv)' if re.match(r'\s*conv is ', line) else '')
                for line in source.splitlines()[:-1]) + '\n'
            p, live = tmp/'fixture.eigs', tmp/'live.eigs'
            p.write_text(source); live.write_text(twin)
            # The 40-step fixture is colder than the default 5000 OSR threshold.
            # Require native tape coverage for this short loop.
            for tier, extra in [('jit', {'EIGS_JIT_OSR_THRESHOLD': '1'}), ('off', {'EIGS_JIT_OFF': '1'})]:
                env = base | extra
                for code in [p, live]:
                    lint = subprocess.run([binary, '--lint', '--json', str(code)], env=env,
                                          capture_output=True, text=True, timeout=30)
                    assert lint.returncode == 0, lint.stdout + lint.stderr
                labels = checked([binary, str(live)], env).splitlines()
                assert len(labels) == count + 1
                tape = tmp/'fixture.tape'
                recorded = subprocess.run([binary, '--trace', str(tape), str(p)],
                    env=env | {'EIGS_JIT_STATS': '1', 'EIGS_JIT_DEBUG': '1'},
                    capture_output=True, text=True, timeout=30)
                assert recorded.returncode == 0, (recorded.returncode, recorded.stdout, recorded.stderr)
                assert all(line.startswith('[jit]') for line in recorded.stderr.splitlines()), recorded.stderr
                stat = re.search(r'^\[jit\] scanned=\d+ compiled=(\d+)', recorded.stderr, re.M)
                compiled = int(stat[1]) if stat else None
                if native_required:
                    assert stat, ('missing native coverage diagnostic', recorded.stderr)
                if tier == 'jit' and native_required:
                    assert compiled > 0 and re.search(r'^\[jit\] compiled .* entry=[1-9][0-9]* .* bytes native$', recorded.stderr, re.M), ('native trace did not compile', recorded.stderr)
                elif tier == 'off':
                    assert compiled in (None, 0), ('interpreter tape compiled native code', recorded.stderr)
                recordings.append(dict(fixture=fixture, tier=tier, off=tier == 'off',
                    compiled=compiled, rc=recorded.returncode, stderr=recorded.stderr, source=source))
                stops, moments = 0, []
                for line in tape.read_text().splitlines():
                    if line.startswith('L '): stops += 1
                    if re.match(r'A \d+ conv=', line): moments.append(stops)
                assert len(moments) == len(labels)
                for n, (stop, label) in enumerate(zip(moments, labels)):
                    out = checked([binary, '--step', str(tape), str(p)], env,
                                  input=f's {stop-1}\np conv\nt conv\nq\n')
                    pv = re.findall(r'^conv = .*\[([a-z]+)\]', out, re.M)
                    tv = re.findall(r'^\s+#' + str(n+1) + r'\s+.*\[([a-z]+)\]', out, re.M)
                    assert pv == [label] and tv == [label], (fixture, tier, n, label, pv, tv, out)
                    rows.append(dict(fixture=fixture, tier=tier, update=n, live=label, p=pv[0], t=tv[0]))
                expected = {20: 'improving', 29: 'improving', 30: 'converged', 40: 'converged'} if fixture == 'nonzero' else {40: 'improving', 41: 'converged', 60: 'converged'}
                for n, label in expected.items(): assert labels[n] == label, (fixture, tier, n, labels[n])
    if args.out: args.out.write_text(json.dumps(rows, indent=2) + '\n')
    if args.diagnostics: args.diagnostics.write_text(json.dumps(dict(contract_rows=len(rows), p_and_t_comparisons=2*len(rows), native_required=native_required, trace_recordings=recordings), indent=2) + '\n')
    print(f'PASS: step-report rows={len(rows)} p={len(rows)} t={len(rows)} tiers=2 mismatches=0')


if __name__ == '__main__':
    main()
