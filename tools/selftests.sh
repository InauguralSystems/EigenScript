#!/usr/bin/env bash
# Checker calibration: the table owns commands, read dependencies and inherited pins.
# Each command is a separate process: never invoke a shell function under `||`.
set -eu
cd "$(dirname "$0")/.."
command -v python3 >/dev/null 2>&1 || { echo 'selftests: INSTRUMENT ERROR: python3 missing'; exit 2; }
exec python3 - "$@" <<'PY'
import fnmatch, importlib.util, json, os, re, resource, shlex, shutil, subprocess, sys, tempfile, time
from pathlib import Path

def error(message):
    print('selftests: INSTRUMENT ERROR: ' + str(message), flush=True)
    raise SystemExit(2)

def git(*args):
    return subprocess.check_output(['git', '-c', 'safe.directory=*', *args]).decode().split('\0')

def main():
    args = sys.argv[1:]
    listing = '--list' in args
    if listing:
        args.remove('--list')
        args = args or ['--all']
    if args not in (['--all'],) and not (len(args) == 2 and args[0] == '--changed'):
        error('usage: tools/selftests.sh --all | --changed <base-ref> | --list')
    # Recognise shell/Python dispatch idioms; new language idioms need extending here.
    # Calls/prose are not implementations. mutants tests the product.
    mode = r'(?:--self-?test(?:-paths)?|selftest)'
    dispatch = re.compile(r'(?:==?|\bin\b|add_argument).*?[\'\"]' + mode + r'[\'\"]|(?:^|;;)\s*' + mode + r'\)|[\'\"]' + mode + r'[\'\"]\s+in\b|^\s*if .*?=\s*--selftest\b', re.M)
    implemented = set()
    for directory in ('tools', 'tests', 'bench'):
        for path in Path(directory).rglob('*'):
            if not path.is_file() or path.as_posix() in ('tools/selftests.sh', 'tools/mutants.sh'):
                continue
            try:
                source = path.read_text()
            except UnicodeError:
                continue
            code = '\n'.join(s for s in source.splitlines() if not s.lstrip().startswith('#'))
            if dispatch.search(code):
                implemented.add(path.as_posix())
    rows, enrolled = [], set()
    for n, line in enumerate(Path('tools/selftests.txt').read_text().splitlines(), 1):
        if not line.strip() or line.startswith('#'):
            continue
        fields = [s.strip() for s in line.split(' | ')]
        if len(fields) not in (2, 3):
            error(f'selftests.txt:{n}: expected triggers | command | optional JSON pin')
        triggers, command = fields[:2]
        argv = shlex.split(command)
        if len(argv) < 4 or argv[0] != 'timeout' or not argv[1].isdigit() or int(argv[1]) < 1:
            error(f'selftests.txt:{n}: command needs timeout SECONDS')
        scripts = [s for s in argv[2:] if s.startswith(('tools/', 'tests/', 'bench/'))]
        if not scripts or any(not Path(s).is_file() for s in scripts):
            error(f'selftests.txt:{n}: command does not name an existing script')
        if not any(re.fullmatch(mode, a) for a in argv):
            error(f'selftests.txt:{n}: command lacks a self-test mode')
        target = scripts[0]
        if target in enrolled or target not in implemented:
            error(f'selftests.txt:{n}: duplicate or non-self-test command: {target}')
        enrolled.add(target)
        pins = json.loads(fields[2]) if len(fields) == 3 and fields[2] else []
        if not isinstance(pins, list) or any(not isinstance(p, dict) or not isinstance(p.get('pattern'), str) or not isinstance(p.get('count'), int) for p in pins):
            error(f'selftests.txt:{n}: pins need pattern strings and integer counts')
        for pin in pins:
            re.compile(pin['pattern'])
        rows.append((triggers.split(), command, target, pins))
    if not rows or enrolled != implemented:
        error('enrolment mismatch: missing=' + repr(sorted(implemented - enrolled)) + ' stale=' + repr(sorted(enrolled - implemented)))
    changed = set()
    if args[0] == '--changed':
        changed.update(git('diff', '--no-renames', '--name-only', '-z', args[1] + '...HEAD'))
        changed.update(git('diff', '--no-renames', '--name-only', '-z'))
        changed.update(git('diff', '--cached', '--no-renames', '--name-only', '-z'))
        changed.update(git('ls-files', '--others', '--exclude-standard', '-z'))
    all_rows = args[0] != '--changed' or bool(changed & {'tools/selftests.sh', 'tools/selftests.txt'})
    selected = [r for r in rows if all_rows or any(fnmatch.fnmatchcase(f, p) for f in changed for p in r[0])]
    print(f'selftests: enrolment {len(enrolled)}/{len(implemented)}; {len(selected)} self-tests selected', flush=True)
    if listing:
        for _, cmd, _, _ in selected:
            print(cmd)
        return 0
    failed, total, instrument = 0, 0.0, False
    with tempfile.TemporaryDirectory(prefix='eigs-selftests-') as scratch:
        for _, command, target, pins in selected:
            env = dict(os.environ)
            timeout = shutil.which('timeout') or shutil.which('gtimeout') or error('timeout/gtimeout missing')
            variant = {'tests/test_http_slowloris.sh': 'http', 'tools/gfx_strict_sweep.sh': 'gfx'}.get(target)
            cap = (lambda: resource.setrlimit(resource.RLIMIT_AS, (1536000000, 1536000000))) if variant == 'gfx' else None
            if variant:
                binary = env.get('SELFTEST_' + variant.upper())
                if not binary:
                    print(f'selftests: preparing isolated {variant} binary', flush=True)
                    tree = Path(scratch) / variant
                    tree.mkdir()
                    for name in ('src', 'lib', 'tools'):
                        shutil.copytree(name, tree / name, ignore=shutil.ignore_patterns('eigenscript*', '*.o'))
                    for name in ('Makefile', 'VERSION'):
                        shutil.copy(name, tree / name)
                    # The C source/header share the binary prefix; copy those explicitly.
                    for path in Path('src').glob('eigenscript.*'):
                        shutil.copy(path, tree / path)
                    subprocess.run([timeout, '-k', '5', '600', 'make', '-C', str(tree), variant], check=True, stdout=subprocess.DEVNULL, preexec_fn=cap)
                    binary = str(tree / 'src/eigenscript')
                env['EIGS' if variant == 'http' else 'EIGS_SWEEP_BIN'] = str(Path(binary).resolve())
            # Real consumer fixtures are used by this benchmark's calibration.
            if target == 'tools/jit_fleet_bench.sh' and not env.get('ECO'):
                local = Path.home() / 'src/InauguralSystems/EigenScriptEcosystem'
                if not (local / 'DMG').is_dir():
                    local = Path(scratch) / 'ecosystem'
                    for repo in ('DMG', 'liferaft', 'ouroboros', 'EigenMiniSat'):
                        subprocess.run([timeout, '-k', '5', '120', 'git', 'clone', '--depth=1', 'https://github.com/InauguralSystems/' + repo, str(local / repo)], check=True, stdout=subprocess.DEVNULL)
                env['ECO'] = str(local)
            # HTTP readiness's public wrapper uses src/ as cwd; call its implementation there.
            cwd = 'src' if target == 'tests/http_readiness.py' else '.'
            argv = shlex.split(command)
            argv[0] = timeout
            argv[1:1] = ['-k', '5']
            if cwd == 'src':
                argv[argv.index(target)] = '../' + target
            start = time.monotonic()
            result = subprocess.run(argv, cwd=cwd, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, preexec_fn=cap)
            instrument |= result.returncode in (2, 126, 127)
            reasons = [] if result.returncode == 0 else [f'exit {result.returncode}' + (' (timeout)' if result.returncode == 124 else '')]
            for pin in pins:
                pattern, wanted = pin['pattern'], pin['count']
                if 'without_yaml' in pin and importlib.util.find_spec('yaml') is None:
                    pattern = pin['without_yaml']
                matches = re.findall(pattern, result.stdout, re.M)
                found = (int(matches[0]) if len(matches) == 1 else -1) if pin.get('value') else len(matches)
                if (found < wanted if pin.get('floor') else found != wanted):
                    reasons.append(f'pin {pattern!r}: found {found}, wanted {wanted}')
            seconds = time.monotonic() - start
            total += seconds
            failed += bool(reasons)
            print(f'{"FAIL" if reasons else "PASS"}: {target} {seconds:.2f}s' + (': ' + '; '.join(reasons) if reasons else ''), flush=True)
            if reasons or 'SKIP' in result.stdout:
                print(result.stdout, end='', flush=True)
    print(f'selftests: {len(selected)-failed} passed, {failed} failed; total {total:.2f}s', flush=True)
    return 2 if instrument else int(bool(failed))

try:
    sys.exit(main())
except Exception as exc:
    error(exc)
PY
