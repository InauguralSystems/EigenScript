#!/bin/sh
# Source-text guard for the shared compile warning flags. Real builds remain
# the expansion oracle. This check cannot infer compiles assembled at runtime.
set -eu
cd "$(dirname "$0")/.."
python3 - "${1:-}" <<'PY'
import pathlib
import re
import subprocess
import sys

HOME = 'tools/werror_flags.txt'
FLAGS = ('-Werror=switch', '-Werror=comment', '-Werror=misleading-indentation')
FLOOR = 35  # Measured from the source-text population; drops below this are red.
LITERAL = re.compile(r'-Werror=(?:switch|comment|misleading-indentation)(?![\w-])')
COMPILER = re.compile(
    r'(?<![\w./])(?:["\']?)(?:\$\$?\(CC\)|\$\{[A-Z_]*CC(?:[^}]*)\}'
    r'|\$[A-Z_]*CC|gcc|clang|cc|emcc)(?:\.exe)?(?:["\']?)(?=\s)')
SOURCE = re.compile(r'(?<!\S)-c(?=\s|$)|\.c(?=["\']?(?:\s|$))|'
                    r'\$(?:\([A-Z_]*SOURCES\)|\{[A-Z_]*SOURCES(?:\[@\])?\}|[A-Z_]*SOURCES\b|[A-Z_]*SRC\b)')
REFERENCE = re.compile(r'\$(?:\$?\(WERROR_FLAGS\)|\{WERROR_FLAGS\}|WERROR_FLAGS\b)')
SPLIT = re.compile(r'&&|\|\||;|(?<!\|)\|(?!\|)')
CONTROL = re.compile(r'[-+@]?\s*(?:(?:if|then|do|!|time|command|env)\s*|\(\s*)*')
ASSIGN = re.compile(r'[A-Za-z_][A-Za-z0-9_]*=\$\(\s*')


def logical_lines(text):
    pending = ''
    for line in text.splitlines():
        if line.lstrip().startswith('#'):
            continue
        pending += line.rstrip().removesuffix('\\') + ' '
        if not line.rstrip().endswith('\\'):
            yield pending
            pending = ''
    if pending:
        yield pending


def check(files, home, floor):
    errors, examined = [], 0
    words = home.split()
    if len(words) != 3 or set(words) != set(FLAGS):
        errors.append('home must define exactly the three whole warning flags')
    for path, content in files.items():
        if path == 'tools/werror_switch_check.sh':
            continue  # This checker contains patterns and planted faults as data.
        for number, line in enumerate(content.splitlines(), 1):
            if LITERAL.search(line):
                errors.append(f'{path}:{number}: literal warning flag outside home')
        if path != 'Makefile' and not path.endswith('.sh'):
            continue
        for line in logical_lines(content):
            for segment in SPLIT.split(line):
                match = COMPILER.search(segment)
                if not match or not SOURCE.search(segment[match.end():]):
                    continue
                prefix = segment[:match.start()].strip()
                if not (CONTROL.fullmatch(prefix) or ASSIGN.fullmatch(prefix)):
                    continue  # Compiler names in printed advice and fixture strings are data.
                examined += 1
                if not REFERENCE.search(segment[match.end():]):
                    errors.append(f'{path}: compile lacks WERROR_FLAGS: {segment.strip()[:110]}')
    if examined < floor:
        errors.append(f'examined={examined} below floor={floor}')
    return errors, examined


def selftest():
    good_home = ' '.join(FLAGS)
    base = {'Makefile': '\t$(CC) $(WERROR_FLAGS) -c src/vm.c -o vm.o\n',
            'tests/probe.sh': 'gcc $WERROR_FLAGS -c src/vm.c -o vm.o\n'}
    cases = [
        ('recipe compile without variable', {**base, 'Makefile': '\t$(CC) -c src/vm.c -o vm.o\n'}, good_home, True),
        ('script compile without variable', {**base, 'tests/probe.sh': 'gcc -c src/vm.c -o vm.o\n'}, good_home, True),
        ('literal switch flag in script', {**base, 'tests/probe.sh': 'gcc $WERROR_FLAGS -Werror=switch -c src/vm.c\n'}, good_home, True),
        ('home missing comment flag', base, good_home.replace(FLAGS[1], ''), True),
        ('switch-enum is not switch', base, good_home.replace(FLAGS[0], '-Werror=switch-enum'), True),
        ('honest control', base, good_home, False),
    ]
    for name, files, home, should_fail in cases:
        errors, n = check(files, home, 2)
        if bool(errors) != should_fail or n != 2:
            print(f'SELFTEST FAIL: {name}: examined={n}, errors={errors}')
            return 1
        print(f'SELFTEST PASS: {name}')
    print('SELFTEST: 6 cases passed')
    return 0


if len(sys.argv) > 1 and sys.argv[1] == '--selftest':
    sys.exit(selftest())
if len(sys.argv) > 1 and sys.argv[1]:
    sys.exit('usage: tools/werror_switch_check.sh [--selftest]')
paths = subprocess.check_output(
    ['git', 'ls-files', '-z', '--', 'Makefile', '*.sh', '.github/workflows/*.yml']).decode().split('\0')
files = {p: pathlib.Path(p).read_text() for p in paths if p and pathlib.Path(p).is_file()}
if len(files) < 1:
    sys.exit('werror flags: no tracked source files examined')
home = pathlib.Path(HOME)
if not home.is_file():
    sys.exit(f'werror flags: missing home {HOME}')
errors, examined = check(files, home.read_text(), FLOOR)
print(f'examined={examined}')
if errors:
    for error in errors:
        print('werror flags: FAIL:', error)
    sys.exit(1)
print(f'werror flags: OK — one home {HOME}, {examined} compile invocations use it')
PY
