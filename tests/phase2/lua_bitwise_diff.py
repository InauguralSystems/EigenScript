#!/usr/bin/env python3
"""N8 differential: Lua 5.4 is the value/kind/error oracle, never Python.

Usage: python3 tests/phase2/lua_bitwise_diff.py <lua-5.4> <eigenscript>
Python enumerates source literals and compares records; it does no bitwise
arithmetic. Each builtin is compared directly with Lua's matching operator.
"""
import argparse
import json
import os
from pathlib import Path
import subprocess
import tempfile

VALUES = ['0', '1', '-1', '2', '-2', '0x7F', '0xFF', '0xFFFF',
          '2147483647', '2147483648', '2147483649', '4611686018427387904',
          '9223372036854775807', '(-9223372036854775807 - 1)', '-256',
          '9007199254740993', '140737488355327', '140737488355328',
          '3.0', '3.5', '-3.0', '-3.5', '9223372036854775808.0']
COUNTS = [str(x) for x in range(-70, 71)] + ['3.0', '3.5', '-3.0', '-3.5',
          '9223372036854775807', '(-9223372036854775807 - 1)',
          '9223372036854775808.0']
OPS = [('&', '&', 'bit_and'), ('|', '|', 'bit_or'), ('^', '~', 'bit_xor'),
       ('<<', '<<', 'bit_shl'), ('>>', '>>', 'bit_shr'), ('~', '~', 'bit_not')]


def cases():
    for eigs, lua, builtin in OPS:
        pairs = [(v, '0') for v in VALUES] if eigs == '~' else [
            (a, b) for a in VALUES for b in (COUNTS if eigs in ('<<', '>>') else VALUES)]
        for a, b in pairs:
            want = f'{lua}({a})' if eigs == '~' else f'({a}) {lua} ({b})'
            for form in ('op', 'builtin'):
                got = (f'~({a})' if eigs == '~' else f'({a}) {eigs} ({b})') if form == 'op' else (
                    f'{builtin} of ({a})' if eigs == '~' else f'{builtin} of [{a}, {b}]')
                yield f'{eigs}/{form}({a}, {b})', want, got


def compare(expected, actual):
    """Exact records include both kind and integer digits (or value error)."""
    return [(i, a, b) for i, (a, b) in enumerate(zip(expected, actual)) if a != b]


def run(binary, path, env):
    proc = subprocess.run([binary, str(path)], stdin=subprocess.DEVNULL,
                          capture_output=True, text=True, timeout=120, env=env)
    if proc.returncode or proc.stderr:
        raise RuntimeError(f'{binary}: rc={proc.returncode}\n{proc.stderr}\n{proc.stdout[-2000:]}')
    return proc.stdout.splitlines()


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('lua')
    ap.add_argument('eigenscript')
    args = ap.parse_args()
    lua, eigs = (str(Path(p).resolve()) for p in (args.lua, args.eigenscript))
    version = subprocess.check_output([lua, '-v'], text=True).strip()
    if not version.startswith('Lua 5.4.'):
        ap.error('the oracle must be Lua 5.4 itself: ' + version)
    print(version, flush=True)
    env = {k: v for k, v in os.environ.items() if not k.startswith('EIGS_')}
    population = list(cases())
    mismatches = []
    agree = 0
    with tempfile.TemporaryDirectory(prefix='n8-lua-') as d:
        for start in range(0, len(population), 120):
            batch = population[start:start + 120]
            lp, ep = Path(d) / 'oracle.lua', Path(d) / 'subject.eigs'
            ls, es = [], []
            for i, (_, want, got) in enumerate(batch):
                ls += ['do', f'local ok, r = pcall(function() return {want} end)',
                       'if ok then', f'print({i} .. "\\tok\\t" .. math.type(r) .. "\\t" .. tostring(r))',
                       'elseif tostring(r):find("no integer representation", 1, true) then',
                       f'print({i} .. "\\terr\\tvalue")', 'else error(r) end', 'end']
                es += ['try:', f'    r is {got}',
                       f'    print of [{i}, "ok", num_type of r, str of r]',
                       'catch e:', f'    print of [{i}, "err", e.kind]']
            lp.write_text('\n'.join(ls) + '\n')
            ep.write_text('\n'.join(es) + '\n')
            expected = [line.split('\t') for line in run(lua, lp, env)]
            for row in expected:
                row[0] = int(row[0])
                if row[1] == 'ok' and row[2] == 'integer':
                    row[2] = 'int'
            actual = [json.loads(line) for line in run(eigs, ep, env)]
            if len(expected) != len(batch) or len(actual) != len(batch):
                raise RuntimeError(f'incomplete batch at {start}: expected={len(expected)} actual={len(actual)}')
            for i, row in enumerate(expected):
                if row[0] != i or actual[i][0] != i:
                    raise RuntimeError('missing, duplicate or reordered case id')
            bad = compare(expected, actual)
            agree += len(batch) - len(bad)
            mismatches += [(population[start + i][0], a, b) for i, a, b in bad]
    for label, want, got in mismatches[:24]:
        print(f'MISMATCH {label}: Lua={want!r} EigenScript={got!r}')
    print(f'cases={len(population)} agree={agree} mismatch={len(mismatches)}', flush=True)
    return bool(mismatches)


if __name__ == '__main__':
    raise SystemExit(main())
