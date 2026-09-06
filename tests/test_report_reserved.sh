#!/usr/bin/env bash
# #1102: language-level reservation, through the real compile entry points.
# Every rejection checks status, diagnostic identity/location, and absence of
# executed statements. Controls ensure the source templates are valid programs.
set -eu
TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
python3 - "$TESTS_DIR/../src/eigenscript" <<'PY'
import json
import pathlib
import re
import subprocess
import sys
import tempfile

binary = str(pathlib.Path(sys.argv[1]).resolve())
passed = failed = 0

def check(label, ok, result=None):
    global passed, failed
    if ok:
        passed += 1
        print('PASS: ' + label)
    else:
        failed += 1
        print('FAIL: ' + label)
        if result is not None:
            print(f'  rc={result.returncode} stdout={result.stdout[:180]!r} stderr={result.stderr[:300]!r}')

def run(args, stdin=None):
    return subprocess.run([binary, *args], input=stdin, text=True,
                          stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                          cwd=work, timeout=30)

def clean(r):
    return not re.search(r'AddressSanitizer|LeakSanitizer|runtime error:|UndefinedBehaviorSanitizer', r.stdout + r.stderr)

# Tuple = construct, valid source with NAME substituted, offending source line.
# Anchored to parser binding families: FUNC, LAMBDA, ASSIGN/LOCAL, FOR,
# TRY, LISTCOMP, destructuring, IMPORT; match patterns are expression
# reads, not binders. Additional
# shapes exercise lookahead, multiline positions, and nonexecuted branches.
shapes = [
    ('define', 'define NAME(v) as:\n    return "mine"\nx is 1\nx is 2\nprint of (NAME of x)\nprint of (NAME of 5)\n', 1),
    ('implicit parameter define', 'define NAME as:\n    return n\n', 1),
    ('assignment', 'NAME is 5\n', 1),
    ('local', 'local NAME is 5\n', 1),
    ('compound assignment', 'NAME += 1\n', 1),
    ('parameter', 'define f(NAME) as:\n    return 0\n', 1),
    ('second parameter', 'define f(a, NAME) as:\n    return 0\n', 1),
    ('default parameter', 'define f(NAME is 3) as:\n    return 0\n', 1),
    ('multiline parameter', 'define f(\n    a,\n    NAME\n) as:\n    return 0\n', 3),
    ('lambda parameter', 'f is (NAME) => 0\n', 1),
    ('second lambda parameter', 'f is (a, NAME) => 0\n', 1),
    ('multiline lambda parameter', 'f is (a,\n    NAME) => 0\n', 2),
    ('for binder', 'for NAME in [1, 2]:\n    0\n', 1),
    ('catch binder', 'try:\n    0\ncatch NAME:\n    0\n', 3),
    ('list match name', 'match [1, 2]:\n    case [NAME, tail]:\n        0\n', 2),
    ('second list match name', 'match [1, 2]:\n    case [head, NAME]:\n        0\n', 2),
    ('comprehension binder', 'xs is [0 for NAME in [1, 2]]\n', 1),
    ('filtered comprehension binder', 'xs is [0 for NAME in [1, 2] if 1]\n', 1),
    ('destructure first', '[NAME, tail] is [1, 2]\n', 1),
    ('destructure second', '[head, NAME] is [1, 2]\n', 1),
    ('import binder', 'import NAME\n', 1),
    ('cold branch', 'if 0:\n    NAME is 5\n', 2),
    ('nested local', 'define f(x) as:\n    local NAME is 5\n', 2),
    ('unobserved', 'unobserved:\n    NAME is 5\n', 2),
]

with tempfile.TemporaryDirectory(prefix='eigs_report_reserved_') as tmp:
    work = pathlib.Path(tmp)
    (work / 'user_report.eigs').write_text('value is 1\n')
    source_file = work / 'program.eigs'
    for label, template, line in shapes:
        control = template.replace('NAME', 'user_report')
        if 'list match name' in label:
            control = 'user_report is 1\nhead is 1\ntail is 2\n' + control
        if label == 'compound assignment':
            control = 'user_report is 0\n' + control
        source_file.write_text(control)
        r = run([str(source_file)])
        check('control ' + label, r.returncode == 0 and clean(r), r)
        for name in ('report', 'report_value'):
            src = 'print of "EXECUTED"\n' + template.replace('NAME', name)
            source_file.write_text(src)
            for mode, args in [('file', [str(source_file)]), ('-e', ['-e', src]),
                               ('lint', ['--lint', '--json', str(source_file)])]:
                r = run(args)
                ok = r.returncode == 1 and clean(r)
                if mode == 'lint':
                    try:
                        ds = json.loads(r.stdout)
                        ok &= len(ds) == 1 and ds[0]['code'] == 'E005' and ds[0]['severity'] == 'error'
                        ok &= ds[0]['line'] == line + 1 and f"'{name}' is a reserved observer form" in ds[0]['message']
                    except (ValueError, KeyError, TypeError, IndexError):
                        ok = False
                else:
                    ok &= r.stdout == '' and re.search(rf'^Parse error line {line + 1}:\d+: \'{name}\' is a reserved observer form.*\[E005\]$', r.stderr, re.M) is not None
                check(f'{name}: {label} / {mode}', ok, r)

    # All RHS shapes other than an optionally parenthesized identifier are
    # errors, including bare call arg lists at every cardinality.
    for name in ('report', 'report_value'):
        for operand in ('5', '(x + 1)', 'x[0]', 'd.key', '[x]', '[]', '[x, x]',
                        '([x])', '(len of x)', '"literal"', 'null', '((x + 0))'):
            src = f'print of "EXECUTED"\nx is [1, 2]\nd is {{"key": 1}}\nprint of ({name} of {operand})\n'
            r = run(['-e', src])
            check(f'{name}: operand {operand}', r.returncode == 1 and r.stdout == '' and clean(r)
                  and f"'{name}' is a reserved observer form; requires a variable name operand" in r.stderr
                  and '[E005]' in r.stderr, r)
        for expr in (name, f'({name})', f'5 |> {name}'):
            r = run(['-e', f'print of "EXECUTED"\nf is {expr}\n'])
            check(f'{name}: cannot take first-class form {expr}', r.returncode == 1 and r.stdout == '' and clean(r)
                  and 'reserved observer form' in r.stderr and '[E005]' in r.stderr, r)

        inner = f'print of "EXECUTED"\n{name} is 4\n'
        (work / 'badmodule.eigs').write_text(inner)
        for label, outer in [('eval', 'eval of ' + json.dumps(inner)),
                             ('load_file', 'load_file of "badmodule.eigs"'),
                             ('import', 'import badmodule')]:
            source_file.write_text(outer + '\n')
            r = run([str(source_file)])
            check(f'{name}: {label}', r.returncode == 1 and r.stdout == '' and clean(r)
                  and re.search(rf'^Parse error line 2:\d+: \'{name}\' is a reserved observer form.*\[E005\]$', r.stderr, re.M) is not None, r)
        # REPL accepts another unit after a rejected unit (its exit status is
        # 0 for other reserved-word syntax errors too).
        r = run([], f'{name} is 4\nprint of "RECOVERED"\nexit\n')
        check(f'{name}: REPL rejection and recovery', r.returncode == 0 and clean(r)
              and 'reserved observer form' in r.stderr and '[E005]' in r.stderr
              and 'RECOVERED' in r.stdout, r)

    # Pin the unchanged name/slot operands, precedence and opaque band. Fields
    # named after keywords are still data keys, never lexical bindings.
    valid = '''x is 1
x is 2
print of (report of x)
print of (report_value of x)
print of (report of (x))
print of (report_value of ((x)))
print of (report of x + "!")
define f(v) as:
    v is 1
    v is 2
    print of (report of v)
    print of (report_value of v)
f of 0
print of (report of f)
print of (report_value of f)
d is {"report": 7, "report_value": 8}
print of d.report
print of d.report_value
d.report is 9
d.report_value += 2
print of d.report
print of d.report_value
print of f"{report of x}:{report_value of x}"
load_file of "lib/eigen.eigs"
print of (eigen_run of "report of 5")
print of (eigen_run of "report of print")
'''
    expected = 'moving\nmoving\nmoving\nmoving\nmoving!\nmoving\nmoving\nopaque\nopaque\n7\n8\n9\n10\nmoving:moving\nequilibrium\nopaque\n'
    source_file.write_text(valid)
    r = run([str(source_file)])
    check('identifier operands and field keys', r.returncode == 0 and r.stdout == expected and clean(r), r)
    r = run(['--fmt', str(source_file)])
    ok = r.returncode == 0 and clean(r)
    source_file.write_text(r.stdout)
    rr = run([str(source_file)])
    check('formatted observer forms run unchanged', ok and rr.returncode == 0 and rr.stdout == expected and clean(rr), rr)
    rr = run(['--fmt', str(source_file)])
    check('formatter is idempotent', ok and rr.returncode == 0 and rr.stdout == r.stdout and clean(rr), rr)

print(f'RESULTS: {passed}/{passed + failed} passed, {failed} failed (reserved observer forms)')
sys.exit(bool(failed))
PY
