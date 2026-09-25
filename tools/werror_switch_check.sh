#!/bin/sh
# Static claims only. tools/cc_guard.sh checks actual compiler invocations in CI.
set -eu
cd "$(dirname "$0")/.."
python3 - "${1:-}" <<'PY'
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile

HOME = 'tools/werror_flags.txt'
FLAGS = ('-Werror=switch', '-Werror=comment', '-Werror=misleading-indentation')
LITERAL = re.compile(r'-Werror=(?:switch|comment|misleading-indentation)(?![\w-])')
ABS_CC = re.compile(r'(?<![\w/])/(?:[\w.+-]+/)*(?:gcc|cc|clang|emcc)(?=\s|["\']|$)')
CHECK = 'tools/werror_switch_check.sh'
GUARD = 'tools/cc_guard.sh'


def check(files, home):
    errors = []
    if home.split() != list(FLAGS):
        errors.append('home must hold exactly the three whole warning flags')
    for path, source in files.items():
        if path == CHECK:
            continue
        for number, line in enumerate(source.splitlines(), 1):
            if path not in (HOME, GUARD) and LITERAL.search(line):
                errors.append(f'{path}:{number}: literal warning flag outside home')
            if path != HOME and not line.lstrip().startswith('#') and ABS_CC.search(line):
                errors.append(f'{path}:{number}: absolute compiler path bypasses guard')
    return errors


def selftest():
    good = ' '.join(FLAGS)
    cases = [('missing home flag', {}, good.replace(FLAGS[1], ''), True),
             ('switch-enum is not switch', {}, good.replace(FLAGS[0], '-Werror=switch-enum'), True),
             ('literal in Python', {'tools/probe.py': f'cc {FLAGS[0]} -c a.c'}, good, True),
             ('absolute compiler', {'tools/probe.sh': '/usr/bin/cc -c a.c'}, good, True),
             ('honest text', {'Makefile': '$(CC) $(CFLAGS) -c a.c'}, good, False)]
    for name, files, home, red in cases:
        if bool(check(files, home)) != red:
            sys.exit(f'SELFTEST FAIL: {name}')
        print(f'SELFTEST PASS: {name}')
    with tempfile.TemporaryDirectory(prefix='cc-guard-selftest-') as temp:
        root = Path(temp); guard = root/'guard'; real = root/'real'
        guard.mkdir(); real.mkdir()
        (guard/'cc').symlink_to((Path.cwd()/'tools/cc_guard.sh').resolve())
        compiler = real/'cc'; compiler.write_text('#!/bin/sh\nexit 0\n'); compiler.chmod(0o755)
        env = {**os.environ, 'PATH': f'{guard}:{real}:'+os.environ['PATH'], 'CC_GUARD_LOG': str(root/'count')}
        probe = root/'a.c'; probe.write_text('int a;\n')
        runs = [('compile without trio', ['-c', str(probe)], True),
                ('link only', ['a.o', '-o', 'a'], False),
                ('compile with trio', [*FLAGS, '-c', str(probe)], False),
                ('stdin -x c without trio', ['-x', 'c', '-'], True),
                ('switch-enum only', ['-Werror=switch-enum', *FLAGS[1:], '-c', str(probe)], True),
                ('preprocess only', ['-E', str(probe)], False)]
        for name, args, red in runs:
            p = subprocess.run([str(guard/'cc'), *args], env=env, capture_output=True, text=True)
            if (p.returncode != 0) != red or (red and 'cc-guard: compile without' not in p.stderr):
                sys.exit(f'SELFTEST FAIL: {name}: {p.stderr}')
            print(f'SELFTEST PASS: {name}')
        bin_dir = root/'bin'; bin_dir.mkdir()
        (bin_dir/'bash').symlink_to('/bin/bash')
        env['PATH'] = f'{guard}:{bin_dir}'
        p = subprocess.run([str(guard/'cc'), 'a.o'], env=env, capture_output=True, text=True)
        if p.returncode == 0 or 'real compiler cc not found' not in p.stderr:
            sys.exit('SELFTEST FAIL: guard never execs itself')
        print('SELFTEST PASS: guard never execs itself')
        (root/'count').write_text('')
        env['PATH'] = os.environ['PATH']
        p = subprocess.run(['/bin/bash', 'tools/cc_guard.sh', '--report'], env=env, capture_output=True, text=True)
        if p.returncode == 0 or 'examined=0' not in p.stderr:
            sys.exit('SELFTEST FAIL: zero guard count')
        print('SELFTEST PASS: zero guard count')
    print('SELFTEST: 13 cases passed')


if sys.argv[1] == '--selftest':
    selftest(); sys.exit(0)
if sys.argv[1]:
    sys.exit('usage: tools/werror_switch_check.sh [--selftest]')
paths = subprocess.check_output(['git', '-c', "safe.directory=*", 'ls-files', '-z', '--',
    'Makefile', '*.mk', '*.sh', '*.py', '.github/workflows/*.yml']).decode().split('\0')
files = {p: Path(p).read_text() for p in paths if p and Path(p).is_file()}
if not files:
    sys.exit('werror flags: no tracked build files examined')
home = Path(HOME)
if not home.is_file():
    sys.exit(f'werror flags: missing home {HOME}')
errors = check(files, home.read_text())
print(f'examined={len(files)}')
if errors:
    for error in errors:
        print('werror flags: FAIL:', error)
    sys.exit(1)
print(f'werror flags: OK — one home {HOME}, {len(files)} tracked build files checked; compiler enforced in CI')
PY
