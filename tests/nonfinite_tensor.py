#!/usr/bin/env python3
"""#2444 step two (a): seven tensor functions against a C IEEE reference.

The table runs every row in four execution configurations and all three
EIGS_STRICT states. Each call records its exact result bits (all NaNs compare
as NaN), writer flags, result shape, and input bits before and after a caught
raise. The C reference supplies only arithmetic results, independently of
container conversion, strict errors, and the untouched storage boundaries.
"""
import argparse
from dataclasses import dataclass
import itertools
import json
import os
from pathlib import Path
import shlex
import struct
import subprocess
import tempfile

from nonfinite_math import NF, ROOT, Runner, STATES, TIERS, expr

UNARY = ('softmax', 'log_softmax', 'relu', 'leaky_relu')
MATRIX = ('matmul', 'matmul_at', 'matmul_bt')
FORMS = ('scalar', 'list', 'buffer')


@dataclass(frozen=True)
class Row:
    name: str
    form: str
    case: str
    a: tuple
    b: tuple = ()
    tensor: bool = False

    @property
    def title(self):
        return self.name + '/' + self.form + '/' + self.case


def transposed(matrix):
    return tuple(zip(*matrix))


def rows():
    table = []
    for name in UNARY:
        for value in NF:
            table.append(Row(name, 'scalar', value, ((value,),)))
        vectors = []
        for position, value in itertools.product(range(2), NF):
            values = ['0.0', '-1.0']
            values[position] = value
            vectors.append(('position' + str(position) + '-' + value, (tuple(values),), False))
        for pair in [('inf', 'inf'), ('-inf', '-inf'), ('inf', '-inf')]:
            vectors.append(('pair-' + ','.join(pair), (pair,), False))
        for value in NF:
            vectors.append(('second-row-' + value, (('1.0', '-1.0'), ('0.0', value)), True))
        for form, (case, values, tensor) in itertools.product(('list', 'buffer'), vectors):
            table.append(Row(name, form, case, values, tensor=tensor))
    for form, value in itertools.product(('list', 'buffer'), ('-30.0', '-740.0', '-745.0', '-746.0', '-800.0', '-1000.0')):
        table.append(Row('log_softmax', form, 'finite-' + value, (('0.0', value),)))
    for form, (case, values) in itertools.product(
            ('list', 'buffer'),
            (('finite-basic', (('1.0', '2.0', '3.0'),)),
             ('finite-large-spread', (('1000.0', '0.0', '-1000.0'),)))):
        table.append(Row('softmax', form, case, values))
    for name in MATRIX:
        cases = []
        for position, value in itertools.product(range(4), NF):
            cells = ['2.0', '-1.0', '3.0', '4.0']
            cells[position] = value
            cases.append(('cell' + str(position) + '-' + value, (tuple(cells[:2]),),
                          ((cells[2],), (cells[3],))))
        cases.append(('inf-times-zero', (('inf', '1.0'),), (('0.0',), ('1.0',))))
        for pair in [('inf', 'inf'), ('-inf', '-inf'), ('inf', '-inf')]:
            cases.append(('pair-' + ','.join(pair), (pair,), (('1.0',), ('1.0',))))
        for value in NF:
            cases.append(('second-row-' + value, (('1.0', '-1.0'), ('0.0', value)),
                          (('1.0',), ('1.0',))))
        for form, (case, a, b) in itertools.product(('list', 'buffer'), cases):
            # Deal the mathematical A.B case to the physical transpose form.
            table.append(Row(name, form, case, transposed(a) if name == 'matmul_at' else a,
                             transposed(b) if name == 'matmul_bt' else b, True))
    assert len(table) == 238
    assert len({row.title for row in table}) == len(table)
    return table


def flattened(matrix):
    return [value for row in matrix for value in row]


def bits(value):
    return int(NF[value]) if value in NF else struct.unpack('q', struct.pack('d', float(value)))[0]


def normalized_bits(value):
    unsigned = value & ((1 << 64) - 1)
    if unsigned & 0x7ff0000000000000 == 0x7ff0000000000000 and unsigned & 0xfffffffffffff:
        return 'nan'
    return value


def dimensions(matrix):
    return (len(matrix), len(matrix[0])) if matrix else (0, 0)


def shape(row):
    if row.form == 'scalar':
        return []
    ar, ac = dimensions(row.a)
    br, bc = dimensions(row.b)
    if row.name in MATRIX:
        m = ac if row.name == 'matmul_at' else ar
        n = br if row.name == 'matmul_bt' else bc
        return [m, n] if row.form == 'buffer' or row.name == 'matmul_at' or m != 1 else [n]
    return [ar, ac] if row.tensor else [ac]


def setup(variable, matrix, form, tensor):
    values = flattened(matrix)
    if form == 'buffer':
        lines = [variable + ' is buffer of ' + str(len(values))]
        lines.extend('buf_set_bits of [' + variable + ', ' + str(i) + ', ' + str(bits(value)) + ']'
                     for i, value in enumerate(values))
        if tensor:
            ar, ac = dimensions(matrix)
            lines.append(variable + ' is reshape of [' + variable + ', ' + str(ar) + ', ' + str(ac) + ']')
        return lines
    if form == 'scalar':
        source = expr(values[0])
    elif tensor:
        source = '[' + ', '.join('[' + ', '.join(map(expr, r)) + ']' for r in matrix) + ']'
    else:
        source = '[' + ', '.join(map(expr, values)) + ']'
    return [variable + ' is ' + source]


def bit_expressions(variable, matrix, form, tensor):
    if form == 'buffer':
        return ['buf_get_bits of [' + variable + ', ' + str(i) + ']'
                for i in range(len(flattened(matrix)))]
    if form == 'scalar':
        return ['f64_bits of ' + variable]
    if tensor:
        return ['f64_bits of ' + variable + '[' + str(r) + '][' + str(c) + ']'
                for r in range(len(matrix)) for c in range(len(matrix[0]))]
    return ['f64_bits of ' + variable + '[' + str(i) + ']'
            for i in range(len(flattened(matrix)))]


def array(expressions):
    return '[' + ', '.join(expressions) + ']'


def program(row, tier):
    lines = setup('operand_a', row.a, row.form, row.tensor)
    snapshots = bit_expressions('operand_a', row.a, row.form, row.tensor)
    safe_a = tuple(tuple('0.5' for _ in r) for r in row.a)
    lines += setup('warm_a', safe_a, row.form, row.tensor)
    if row.b:
        lines += setup('operand_b', row.b, row.form, True)
        snapshots += bit_expressions('operand_b', row.b, row.form, True)
        safe_b = tuple(tuple('0.5' for _ in r) for r in row.b)
        lines += setup('warm_b', safe_b, row.form, True)
    lines += ['input_before is ' + array(snapshots), 'answer is null',
              'error_kind is ""', 'error_message is ""']
    params = '[arg_a, arg_b]' if row.b else 'arg_a'
    lines += ['define calculate(arg_a' + (', arg_b' if row.b else '') + ') as:',
              '    return ' + row.name + ' of ' + params]
    arguments = '[active_a, active_b]' if row.b else 'active_a'
    warm = '[warm_a, warm_b]' if row.b else 'warm_a'
    if tier == 'osr':
        # A while loop avoids the for-binder's unsupported LOOP_ENV_CLEAR.
        # TRY_BEGIN stays outside the OSR prefix; only the last trip uses
        # the target operands, after the native loop has been admitted.
        lines += ['remaining is 80.0', 'try:', '    loop while remaining >= 0.0:',
                  '        active_a is warm_a']
        if row.b:
            lines.append('        active_b is warm_b')
        lines += ['        if remaining == 0.0:', '            active_a is operand_a', '            answer is null']
        if row.b:
            lines.append('            active_b is operand_b')
        lines += ['        remaining is remaining - 1.0',
                  '        answer is ' + row.name + ' of ' + arguments,
                  'catch caught:', '    error_kind is caught.kind',
                  '    error_message is caught.message']
    else:
        lines += ['for warmup in range of 80:', '    calculate of ' + warm,
                  'try:', '    answer is calculate of ' + ('[operand_a, operand_b]' if row.b else 'operand_a'),
                  'catch caught:', '    error_kind is caught.kind', '    error_message is caught.message']
    out_shape = shape(row)
    if row.form == 'buffer':
        result_bits = ['buf_get_bits of [answer, ' + str(i) + ']'
                       for i in range((out_shape[0] * out_shape[1]) if len(out_shape) == 2 else out_shape[0])]
    elif row.form == 'scalar':
        result_bits = ['f64_bits of answer']
    elif len(out_shape) == 2:
        result_bits = ['f64_bits of answer[' + str(r) + '][' + str(c) + ']'
                       for r in range(out_shape[0]) for c in range(out_shape[1])]
    else:
        result_bits = ['f64_bits of answer[' + str(i) + ']' for i in range(out_shape[0])]
    lines += ['print of [error_kind, error_message]', 'if error_kind == "":',
              '    print of [type of answer, shape of answer]',
              '    print of (' + array(result_bits) + ')', 'else:',
              '    print of ["no-result", []]', '    print of (answer == null)',
              'status_flags is math_flags of null',
              'print of [status_flags.overflow, status_flags.invalid, status_flags.underflow]',
              'print of input_before', 'print of (' + array(snapshots) + ')']
    return '\n'.join(lines) + '\n'


def reference(scratch, table):
    executable = scratch / 'tensor_reference'
    flags = ['-Werror=implicit-function-declaration'] + (ROOT / 'tools/werror_flags.txt').read_text().split()
    subprocess.run(shlex.split(os.environ.get('CC', 'cc')) + flags +
                   ['-O2', '-ffp-contract=off', '-fno-fast-math',
                    str(ROOT / 'tests/nonfinite_tensor_ref.c'), '-o', str(executable), '-lm'], check=True)
    source = []
    for row in table:
        ar, ac = dimensions(row.a)
        br, bc = dimensions(row.b)
        source.append(' '.join([row.name, str(ar), str(ac), str(br), str(bc)] +
                               flattened(row.a) + flattened(row.b)))
    result = subprocess.run([str(executable)], input='\n'.join(source) + '\n', text=True,
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=True)
    answers = []
    for line in result.stdout.splitlines():
        fields = line.split('\t')
        count = int(fields[0])
        assert len(fields) == count + 5
        values = ['nan' if x == 'nan' else int(x) for x in fields[1:count + 1]]
        flags = [bool(int(x)) for x in fields[count + 1:count + 4]]
        answers.append((values, flags, fields[-1]))
    assert len(answers) == len(table) > 0
    return answers


def check_table(runner, table, answers, tiers):
    for row, (values, flags, first) in zip(table, answers):
        input_bits = [bits(x) for x in flattened(row.a) + flattened(row.b)]
        for tier, state in itertools.product(tiers, STATES):
            strict_error = state == '1' and first != 'finite'
            if strict_error:
                who = 'arithmetic' if row.name in ('matmul_at', 'matmul_bt') else row.name
                suffix = ('result is not a number (NaN has no defined value)' if first == 'nan'
                          else 'non-finite arithmetic result (infinity)')
                expected_error = ['value', who + ': ' + suffix]
                expected_type = ['no-result', []]
                expected_values = True  # The failed assignment leaves the sentinel.
                expected_flags = [first == 'infinity', first == 'nan', False]
            else:
                expected_error = ['', '']
                expected_type = ['num' if row.form == 'scalar' else row.form, shape(row)]
                expected_values = values
                expected_flags = flags
            expected = [expected_error, expected_type, expected_values, expected_flags, input_bits, input_bits]
            ok, actual, _ = runner.run(program(row, tier), state, tier)
            try:
                observed = [json.loads(line) for line in actual.splitlines()]
                if len(observed) == 6 and isinstance(observed[2], list):
                    observed[2] = [normalized_bits(x) for x in observed[2]]
            except (TypeError, ValueError):
                observed = None
            runner.check(row.title + '/' + tier + '/' + ('unset' if state is None else 's' + state),
                         ok and observed == expected,
                         'expected ' + repr(expected) + '\nactual ' + actual)
    print(f'nonfinite-tensor-table: rows={len(table)} tiers={len(tiers)} states=3 checks={len(table) * len(tiers) * 3}', flush=True)


def boundaries(runner, tiers, unchanged_only=False):
    examined = 0
    for value, tier, state in itertools.product(NF, tiers, STATES):
        path = runner.scratch / 'must-not-exist.tensor'
        if path.exists():
            path.unlink()
        source = ('operand is [' + expr(value) + ', 0.0]\n'
                  'before is [f64_bits of operand[0], f64_bits of operand[1]]\n'
                  'try:\n    tensor_save of [operand, "@SCRATCH@/must-not-exist.tensor"]\n'
                  '    print of "answered"\ncatch caught:\n    print of [caught.kind, caught.message]\n'
                  'print of before\nprint of [f64_bits of operand[0], f64_bits of operand[1]]\n')
        ok, actual, _ = runner.run(source, state, tier)
        expected = ['["value", "tensor_save: expected a finite number"]',
                    json.dumps([bits(value), 0]), json.dumps([bits(value), 0])]
        runner.check('boundary/tensor_save/' + value + '/' + tier + '/' + str(state),
                     ok and actual.splitlines() == expected and not path.exists(), actual)
        examined += 1
    # A raw buffer with inf is available in every state. The arithmetic
    # result is additionally checked in unset/s0; s1 must raise at its writer,
    # before any non-finite seven-function result can reach indexing.
    for tier, state in itertools.product(tiers, STATES):
        for source_name, result in [('stored-cell', 'operand'), ('relu-result', 'relu of operand')]:
            if unchanged_only and source_name == 'relu-result' and state == '1':
                continue  # rule 3 now raises at relu, so no result reaches indexing
            source = ('operand is buffer of 2\nbuf_set_bits of [operand, 0, ' + NF['inf'] + ']\n'
                      'try:\n    result is ' + result + '\n    print of result[0]\n'
                      'catch caught:\n    print of [caught.kind, caught.message]\n'
                      'print of [buf_get_bits of [operand, 0], buf_get_bits of [operand, 1]]\n')
            ok, actual, _ = runner.run(source, state, tier)
            message = ('relu: non-finite arithmetic result (infinity)'
                       if source_name == 'relu-result' and state == '1'
                       else 'buffer_read_f64: expected a finite number')
            expected = [json.dumps(['value', message]), json.dumps([bits('inf'), 0])]
            runner.check('boundary/index/' + source_name + '/' + tier + '/' + str(state),
                         ok and actual.splitlines() == expected, actual)
            examined += 1
    assert examined == 5 * len(tiers) * 3 - (len(tiers) if unchanged_only else 0)
    print(f'nonfinite-tensor-boundaries: rows=5 tiers={len(tiers)} states=3 unchanged_only={unchanged_only} checks={examined}', flush=True)
    return examined


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', required=True, help='candidate EigenScript binary')
    parser.add_argument('--tiers', default=','.join(TIERS), help='comma-separated off,default,osr,trace')
    parser.add_argument('--only', default='', help='comma-separated function names; excludes boundary rows')
    parser.add_argument('--form', choices=FORMS, help='one container form; excludes boundary rows')
    parser.add_argument('--case', default='', help='case-name substring; excludes boundary rows')
    parser.add_argument('--boundaries-only', action='store_true', help='run unchanged storage/read rows only')
    parser.add_argument('--unchanged-only', action='store_true',
                        help='boundary rows only, omitting relu-result s1 (which now raises at the writer)')
    args = parser.parse_args()
    tiers = args.tiers.split(',')
    if len(set(tiers)) != len(tiers) or any(t not in TIERS for t in tiers):
        parser.error('--tiers must select distinct known tiers')
    if args.only and any(name not in UNARY + MATRIX for name in args.only.split(',')):
        parser.error('--only contains an unknown function')
    with tempfile.TemporaryDirectory(prefix='nonfinite-tensor-', dir=os.environ.get('TMPDIR')) as d:
        scratch = Path(d)
        runner = Runner(args.binary, scratch)
        filtered = args.only or args.form or args.case
        boundary_only = args.boundaries_only or args.unchanged_only
        if not boundary_only:
            table = [r for r in rows() if (not args.only or r.name in args.only.split(','))
                     and (not args.form or r.form == args.form) and args.case in r.case]
            if not table:
                parser.error('selection contains no arithmetic rows')
            answers = reference(scratch, table)
            check_table(runner, table, answers, tiers)
        boundary_checks = boundaries(runner, tiers, args.unchanged_only) if boundary_only or not filtered else 0
        declared = (len(table) * len(tiers) * 3 if not boundary_only else 0) + boundary_checks
        assert runner.examined == declared == runner.passed + runner.failed > 0
        print(f'nonfinite-tensor-checks: examined={runner.examined} declared={declared} pass={runner.passed} fail={runner.failed}', flush=True)
        return int(runner.failed != 0)


if __name__ == '__main__':
    raise SystemExit(main())
