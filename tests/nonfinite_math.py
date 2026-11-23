#!/usr/bin/env python3
"""#2444 arithmetic table, list mapping and frozen base boundaries.

Standalone: python3 tests/nonfinite_math.py --binary /absolute/eigenscript
The suite supplies its own rc_ok/rc_expect; standalone runs extract those same
functions from the runner, so sanitizer diagnostics never become an answer.
--capture-base writes only the unchanged rows and the observed list-map set.
"""
import argparse
import itertools
import json
import math
import os
import re
from pathlib import Path
import shlex
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
A1 = 'abs negative floor ceil round fround sqrt exp log sin cos tan asin acos atan'.split()
A2 = 'atan2 pow add subtract multiply divide'.split()
A4 = ['sum', 'mean', 'norm']
NF = {'inf': '9218868437227405312', '-inf': '-4503599627370496', 'nan': '9221120237041090560'}
TIERS = {'off': {'EIGS_JIT_OFF': '1'}, 'default': {},
         'osr': {'EIGS_JIT_OSR_THRESHOLD': '1'}, 'trace': {'EIGS_TRACE': '1'}}
STATES = [None, '0', '1']
DATA = ROOT / 'tests/nonfinite_math_base.json'


def rows():
    table = []
    for name in A1:
        for value in NF:
            table.append((name, [value]))
    for name in A2:
        for pos, value, partner in itertools.product(range(2), NF, ['2.0', '-2.0']):
            args = [partner, partner]
            args[pos] = value
            table.append((name, args))
        for pair in itertools.product(NF, repeat=2):
            table.append((name, list(pair)))
    for name in A4:
        for pos, value in itertools.product(range(3), NF):
            args = ['2.0', '-2.0']
            args.insert(pos, value)
            table.append((name, args))
        # These catch compensated sums when infinity precedes the finite tail.
        for pos, value in itertools.product(range(2), NF):
            args = ['1.0']
            args.insert(pos, value)
            table.append((name, args))
    table.extend([('pow', ['1.0', 'nan']), ('pow', ['nan', '0.0'])])
    assert len(table) == 15 * 3 + 6 * (2 * 3 * 2 + 9) + 3 * (3 * 3 + 2 * 3) + 2
    return table


def expr(value):
    return '(f64_from_bits of ' + NF[value] + ')' if value in NF else value


def spell(value):
    return 'nan' if math.isnan(value) else repr(value)


def call(name, args):
    return name + ' of ' + (args[0] if len(args) == 1 else '[' + ', '.join(args) + ']')


def label(name, args):
    return name + '(' + ','.join(args) + ')'


def program(name, args, direct=False, tier='off'):
    params = ['a', 'b', 'c'][:len(args)]
    if direct or tier == 'osr':
        # Keep the faulting module frame alive for its exact source excerpt.
        # Actual NF operands reach the call INSIDE the loop, after admission.
        threshold = int(re.search(r'^#define EIGS_JIT_OSR_THRESHOLD\s+(\d+)',
                        (ROOT / 'src/jit.c').read_text(), re.M).group(1))
        warm = threshold + 1 if direct and tier in ('default', 'trace') else 80
        lines = []
        for param, value in zip(params, args):
            lines.extend([param + ' is 0.5', 'target_' + param + ' is ' + expr(value)])
        lines.extend(['answer is 0.5', 'iteration is 0', 'remaining is ' + str(warm) + '.0',
                      'for iteration in range of ' + str(warm + 1) + ':',
                      '    if remaining == 0.0:'])
        lines.extend('        ' + p + ' is target_' + p for p in params)
        lines.extend(['    remaining is remaining - 1.0',
                      '    answer is ' + call(name, params), 'print of answer',
                      'flags is math_flags of null',
                      'print of [flags.overflow, flags.invalid, flags.underflow]'])
        return '\n'.join(lines) + '\n'
    # Non-strict default/trace rows also exercise hot function-entry thunks.
    body = call(name, params)
    warm = ['0.5'] * len(args)
    return ('define calculate(' + ', '.join(params) + ') as:\n    return ' + body + '\n'
            'for warmup in range of 80:\n    calculate of [' + ', '.join(warm) + ']\n'
            'answer is calculate of [' + ', '.join(map(expr, args)) + ']\n'
            'print of answer\nflags is math_flags of null\n'
            'print of [flags.overflow, flags.invalid, flags.underflow]\n')


def cold_program(name, args):
    return ('answer is ' + call(name, list(map(expr, args))) + '\nprint of answer\n'
            'flags is math_flags of null\nprint of [flags.overflow, flags.invalid, flags.underflow]\n')


def cold_location(name, args):
    source = cold_program(name, args).splitlines()[0]
    return '     1 | ' + source, '       |' + ' ' * (source.index(' of ') + 2) + '^'


def strict_location(name, args, tier):
    lines = program(name, args, direct=True, tier=tier).splitlines()
    found = [(i + 1, line) for i, line in enumerate(lines)
             if line.lstrip().startswith('answer is ' + name + ' of ')]
    assert len(found) == 1
    number, source = found[0]
    return number, f'{number:6d} | ' + source, '       |' + ' ' * (source.index(' of ') + 2) + '^'


def error_message(name, args, answer):
    values = [float(a) for a in args]
    if name == 'sqrt' and values[0] < 0:
        return 'sqrt: argument out of domain (negative)'
    if name == 'log' and not values[0] > 0:
        return 'log: argument out of domain (must be > 0)'
    if name in ('asin', 'acos') and (values[0] < -1 or values[0] > 1):
        return name + ': argument out of domain [-1, 1]'
    prefix = 'arithmetic' if name in A4 + ['add', 'subtract', 'multiply'] else name
    suffix = ('result is not a number (NaN has no defined value)' if answer == 'nan'
              else 'non-finite arithmetic result (infinity)')
    messages = [prefix + ': ' + suffix]
    if name in A4 and args == ['inf', '-inf']:
        messages.append('arithmetic: non-finite arithmetic result (infinity)')
    return messages


class Runner:
    def __init__(self, binary, scratch, mini=False):
        self.binary = str(Path(binary).resolve())
        self.scratch = scratch
        self.mini = mini
        self.passed = self.failed = self.examined = 0
        # Import the real exit classifiers; do not duplicate sanitizer policy.
        source = (ROOT / 'tests/run_all_tests.sh').read_text()
        definitions = source[source.index('rc_ok() {'):source.index('# ---- #988:')]
        self.checker = scratch / 'rc.sh'
        self.checker.write_text('. ' + shlex.quote(str(ROOT / 'tests/lsan_classify.sh')) + '\n'
                                + definitions + '\nrc_expect "$1" "$2" "$(cat "$3")"\n')

    def run(self, source, state=None, tier='off', want=0):
        p = self.scratch / 'row.eigs'
        p.write_text(source.replace('@SCRATCH@', str(self.scratch)))
        env = dict(os.environ)
        for key in ['EIGS_STRICT', 'EIGS_JIT_OFF', 'EIGS_JIT_OSR_THRESHOLD', 'EIGS_TRACE']:
            env.pop(key, None)
        if state is not None:
            env['EIGS_STRICT'] = state
        env.update(TIERS[tier])
        if tier == 'trace':
            env['EIGS_TRACE'] = str(self.scratch / 'row.eigst')
        command = [self.binary, source.replace('@SCRATCH@', str(self.scratch))] if self.mini else [self.binary, str(p)]
        try:
            r = subprocess.run(command, env=env, text=True, stdout=subprocess.PIPE,
                               stderr=subprocess.STDOUT, timeout=15)
        except subprocess.TimeoutExpired as e:
            return False, 'TIMEOUT ' + str(e), 124
        output = self.scratch / 'row.out'
        output.write_text(r.stdout)
        judged = subprocess.run(['bash', str(self.checker), str(want), str(r.returncode), str(output)],
                                text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        return judged.returncode == 0, r.stdout.rstrip(), r.returncode

    def check(self, title, ok, actual=''):
        self.examined += 1
        if ok:
            self.passed += 1
            print('PASS: ' + title, flush=True)
        else:
            self.failed += 1
            print('FAIL: ' + title + '\n' + actual, flush=True)


def reference(scratch, table):
    oracle = scratch / 'oracle'
    cc = shlex.split(os.environ.get('CC', 'cc'))
    flags = ['-Werror=implicit-function-declaration'] + (ROOT / 'tools/werror_flags.txt').read_text().split()
    subprocess.run(cc + flags + ['-O2', '-ffp-contract=off', '-fno-fast-math',
                   str(ROOT / 'tests/nonfinite_math_ref.c'), '-o', str(oracle), '-lm'], check=True)
    text = ''.join(name + ' ' + ' '.join(args + ['0.0'] * (3 - len(args))) + ' ' + str(len(args)) + '\n'
                   for name, args in table)
    r = subprocess.run([str(oracle)], input=text, text=True, capture_output=True, check=True)
    answers = [line.split('\t') for line in r.stdout.splitlines()]
    assert len(answers) == len(table) > 0
    return [(spell(float(a)), '[' + ', '.join('true' if f == '1' else 'false' for f in flags) + ']')
            for a, *flags in answers]


def math_table(runner, table, answers, tiers):
    examined = differ = 0
    for (name, args), (answer, flags) in zip(table, answers):
        for tier, state in itertools.product(tiers, [None, '0']):
            ok, actual, _ = runner.run(program(name, args, tier=tier), state, tier)
            want = answer + '\n' + flags
            matches = actual == want
            runner.check(label(name, args) + '/' + tier + '/' + str(state), ok and matches,
                         'expected ' + repr(want) + '\nactual ' + actual)
            differ += not (ok and matches)
        for tier in tiers:
            nonfinite = answer in ('nan', 'inf', '-inf')
            want_rc = 1 if nonfinite else 0
            hot_ok, hot, _ = runner.run(program(name, args, direct=True, tier=tier), '1', tier, want_rc)
            cold_ok, cold, _ = runner.run(cold_program(name, args), '1', tier, want_rc)
            if nonfinite:
                messages = error_message(name, args, answer)
                if isinstance(messages, str):
                    messages = [messages]
                path = '<embed>' if runner.mini else str(runner.scratch / 'row.eigs')
                line_number, _, _ = strict_location(name, args, tier)
                hot_expected = ['Error ' + path + ':' + str(line_number) + ': ' + m for m in messages]
                cold_expected = ['Error ' + path + ':1: ' + m for m in messages]
                matches = (hot.splitlines()[:1] and hot.splitlines()[0] in hot_expected and
                           cold.splitlines()[:1] and cold.splitlines()[0] in cold_expected)
                if not runner.mini:
                    excerpt, caret = cold_location(name, args)
                    matches = matches and cold.splitlines()[1:3] == [excerpt, caret]
            else:
                matches = hot == cold == answer + '\n' + flags
            # Native error excerpts are independently known to be omitted on
            # the base (OUT issue); test native words/line and cold exact caret.
            runner.check(label(name, args) + '/' + tier + '/strict', hot_ok and cold_ok and matches,
                         'hot ' + hot + '\ncold ' + cold)
        examined += 1
    assert examined == len(table) > 0
    print(f'nonfinite-math: rows={examined} tiers={len(tiers)} states=2 differ={differ}', flush=True)


def mixed_reductions(runner, tiers):
    table = [('sum', ['inf', '-inf']), ('mean', ['inf', '-inf']),
             ('norm', ['inf', 'nan'])]
    examined = 0
    for name, args in table:
        for tier, state in itertools.product(tiers, STATES):
            strict = state == '1'
            ok, actual, _ = runner.run(program(name, args, direct=strict, tier=tier), state, tier, int(strict))
            if strict:
                path = '<embed>' if runner.mini else str(runner.scratch / 'row.eigs')
                messages = ['non-finite arithmetic result (infinity)',
                            'result is not a number (NaN has no defined value)']
                line_number, _, _ = strict_location(name, args, tier)
                matches = actual.splitlines()[0] in [
                    'Error ' + path + ':' + str(line_number) + ': arithmetic: ' + m for m in messages]
            else:
                matches = actual.splitlines()[:1] == ['nan']
            runner.check('mixed/' + name + '/' + tier + '/' + str(state), ok and matches, actual)
        examined += 1
    assert examined == len(table) > 0
    print(f'nonfinite-mixed: rows={examined} tiers={len(tiers)} states=3')


def boundary_sources():
    table = []
    for name, value in itertools.product(A4 + ['dot'] +
            'negative sqrt exp log add subtract multiply divide pow'.split(), ['inf', 'nan']):
        setup = 'b is buf_from_list of [1.0, 2.0]\nbuf_set_bits of [b, 0, ' + NF[value] + ']\n'
        if name == 'dot':
            operation = 'print of (dot of [b, b])\n'
        elif name in A4:
            operation = 'print of (' + name + ' of b)\n'
        else:
            arg = '[b, 2.0]' if name in A2 else 'b'
            operation = ('r is ' + name + ' of ' + arg + '\n'
                         'print of [buf_get_bits of [r, 0], buf_get_bits of [r, 1]]\n')
        table.append(('buffer/' + name + '/' + value, setup + operation))
    # #2444 step two (a): softmax/log_softmax are arithmetic. Their eighteen
    # former refusal records moved to nonfinite_tensor.py's C-reference table;
    # they no longer belong in this unchanged storage/conversion population.
    calls = {
        'dot-left': 'buf_set_bits of [b, 0, 9218868437227405312]\nprint of (dot of [b, c])',
        'dot-right': 'buf_set_bits of [b, 0, 9218868437227405312]\nprint of (dot of [c, b])',
        'buffer-store': 'for i in range of 2:\n    b[i] is v',
        'copy_into': 'print of (copy_into of [b, 0, [v]])',
        'stream_write': 'stream_open of ["@SCRATCH@/stream", 1]\nprint of (stream_write of v)',
        'set_at': 'print of (set_at of [b, 0, v])',
        'buf_set': 'print of (buf_set of [b, 0, v])',
        'fill-value': 'print of (fill of [2, v])',
        'fill-count': 'print of (fill of [v, 1])',
        'json_encode': 'print of (json_encode of v)',
        'json_build': 'print of (json_build of ["k", v])',
        'f64_to_bytes': 'print of (f64_to_bytes of v)',
        'write_bytes': 'print of (write_bytes of ["@SCRATCH@/bytes", [v]])',
        'write_bytes-append': 'print of (write_bytes of ["@SCRATCH@/bytes", [65], v])',
        'index': 'xs is [1, 2]\nprint of xs[v]',
        'buffer-index': 'print of b[v]',
        'count': 'print of (range of v)',
        'bit-operand': 'print of (v & 1)',
        'bit_and': 'print of (bit_and of [v, 1])',
        'duration': 'print of (usleep of v)',
        'task_sleep': 'print of (task_sleep of v)',
        'store_update': 'st is store_open of "@SCRATCH@/store"\nk is store_put of [st, "c", {"a": 1}]\nprint of (store_update of [st, "c", k, {"a": v}])',
        'store_put': 'st is store_open of "@SCRATCH@/store"\nprint of (store_put of [st, "c", {"a": v}])',
    }
    for (name, operation), value in itertools.product(calls.items(), NF):
        setup = ('v is ' + expr(value) + '\nb is buf_from_list of [1.0, 2.0]\n'
                 'c is buf_from_list of [1.0, 2.0]\n')
        table.append(('conversion/' + name + '/' + value, setup + operation + '\n'))
    return table


def normalize(output, scratch):
    return output.replace(str(scratch), '@SCRATCH@')


def base_records(runner):
    table = boundary_sources()
    records = []
    examined = 0
    for title, source in table:
        for state in STATES:
            # Capture the exit, then adjudicate that exit with rc_expect too.
            _, actual, rc = runner.run(source, state)
            assert rc in (0, 1), (title, state, rc, actual)
            ok, actual, rc = runner.run(source, state, want=rc)
            assert ok, (title, state, actual)
            records.append(dict(title=title, source=source, state=state, rc=rc,
                                output=normalize(actual, runner.scratch)))
        examined += 1
    assert examined == len(table) > 0
    mapped = []
    map_examined = 0
    for name in A1 + A2:
        arg = ['([0.5, 0.5, 0.5, 0.5])'] if name in A1 else ['[0.5, 0.5, 0.5, 0.5]', '[0.5, 0.5, 0.5, 0.5]']
        ok, actual, _ = runner.run('print of (' + call(name, arg) + ')\n')
        if ok and actual.startswith('['):
            mapped.append(name)
        map_examined += 1
    assert map_examined == len(A1 + A2) > 0
    assert set(mapped) == set('negative sqrt exp log add subtract multiply divide pow'.split())
    DATA.write_text(json.dumps(dict(records=records, mapped=mapped), indent=2) + '\n')
    print(f'base-records: sources={examined} states=3 records={len(records)} maps={len(mapped)}')


def unchanged(runner):
    records = json.loads(DATA.read_text())['records']
    examined = 0
    for row in records:
        ok, actual, _ = runner.run(row['source'], row['state'], want=row['rc'])
        runner.check(row['title'] + '/' + str(row['state']),
                     ok and normalize(actual, runner.scratch) == row['output'], actual)
        examined += 1
    assert examined == len(records) > 0
    print(f'nonfinite-unchanged: examined={examined} declared={len(records)}')


def pass_through(runner, tiers):
    table = list(itertools.product(NF, STATES, tiers))
    examined = 0
    for value, state, tier in table:
        source = ('r is num_copy of ' + expr(value) + '\nprint of [num_type of r, r]\n'
                  'f is math_flags of null\nprint of [f.overflow, f.invalid, f.underflow]\n')
        ok, actual, _ = runner.run(source, state, tier)
        runner.check('num_copy/' + value + '/' + str(state) + '/' + tier,
                     ok and actual == '[\"float\", ' + value + ']\n[false, false, false]', actual)
        examined += 1
    assert examined == len(table) > 0


def list_maps(runner, tiers):
    mapped = json.loads(DATA.read_text())['mapped']
    table = [(name, pos, value, side) for name in mapped for pos in range(4)
             for value in NF for side in (range(2) if name in A2 else range(1))]
    examined = 0
    for name, pos, value, side in table:
        scalar_args = ['0.5'] * (2 if name in A2 else 1)
        scalar_args[side] = expr(value)
        lists = [['0.5'] * 4 for _ in scalar_args]
        lists[side][pos] = expr(value)
        list_args = ['([' + ', '.join(xs) + '])' for xs in lists]
        # Compute expected unaffected elements from the finite run, and the
        # changed element from the scalar form, in the same state/tier.
        source = ('finite is ' + call(name, ['([0.5, 0.5, 0.5, 0.5])'] * len(scalar_args)) + '\n'
                  'finite[' + str(pos) + '] is ' + call(name, scalar_args) + '\n'
                  'print of finite\nprint of (' + call(name, list_args) + ')\n')
        for tier, state in itertools.product(tiers, [None, '0']):
            ok, actual, _ = runner.run(source, state, tier)
            lines = actual.splitlines()
            runner.check('list/' + name + '/' + str(pos) + '/' + value + '/' + str(side) + '/' + tier + '/' + str(state),
                         ok and len(lines) == 2 and lines[0] == lines[1], actual)
        expected_source = ('expected is ' + call(name, ['([0.5, 0.5, 0.5, 0.5])'] * len(scalar_args)) + '\n'
                           'expected[' + str(pos) + '] is ' + call(name, scalar_args) + '\nprint of expected\n')
        actual_source = 'print of (' + call(name, list_args) + ')\n'
        def caught(source):
            return ('try:\n' + ''.join('    ' + line + '\n' for line in source.splitlines()) +
                    'catch e:\n    print of [e.kind, e.message]\n')
        for tier in tiers:
            expected_ok, expected, _ = runner.run(caught(expected_source), '1', tier)
            actual_ok, actual, _ = runner.run(caught(actual_source), '1', tier)
            runner.check('list/' + name + '/' + str(pos) + '/' + value + '/' + str(side) + '/' + tier + '/strict',
                         expected_ok and actual_ok and expected == actual,
                         'expected ' + expected + '\nactual ' + actual)
        examined += 1
    assert examined == len(table) > 0
    print(f'nonfinite-lists: rows={examined} maps={len(mapped)} tiers={len(tiers)} states=3')


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--binary', required=True)
    parser.add_argument('--tiers', default='off,default,osr,trace')
    parser.add_argument('--only', default='')
    parser.add_argument('--mini', action='store_true')
    parser.add_argument('--capture-base', action='store_true')
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix='nonfinite-math-', dir=os.environ.get('TMPDIR')) as d:
        scratch = Path(d)
        runner = Runner(args.binary, scratch, args.mini)
        table = rows()
        if args.only:
            table = [(n,a) for n,a in table if n in args.only.split(',')]
        if args.capture_base:
            base_records(runner)
            return 0
        answers = reference(scratch, table)
        math_table(runner, table, answers, args.tiers.split(','))
        if not args.only:
            mixed_reductions(runner, args.tiers.split(','))
            pass_through(runner, args.tiers.split(','))
            list_maps(runner, args.tiers.split(','))
        skipped = 0
        if not args.mini:
            unchanged(runner)
        else:
            skipped = len(json.loads(DATA.read_text())['records'])
            print(f'SKIP: frozen hosted boundary records on source-string mini runner: {skipped}')
        assert runner.examined == runner.passed + runner.failed > 0
        print(f'nonfinite-checks: examined={runner.examined} pass={runner.passed} fail={runner.failed} skipped={skipped}')
        return int(runner.failed != 0)


if __name__ == '__main__':
    raise SystemExit(main())
